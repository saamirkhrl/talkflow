using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Talkflow.Core.Text;

namespace Talkflow;

enum TrayState { Idle, Recording, Processing }

/// <summary>
/// The notification-area icon and its menu: the app's only presence, since
/// talkflow has no taskbar window (StatusBar.swift on the Mac).
/// </summary>
sealed class TrayIcon : IDisposable
{
    readonly App _app;
    readonly NotifyIcon _icon;
    readonly Icon _idle, _recording, _processing;
    readonly ToolStripMenuItem _update;
    readonly ToolStripMenuItem[] _styles;
    readonly ToolStripMenuItem _hint;

    public TrayIcon(App app)
    {
        _app = app;
        using (var stream = typeof(TrayIcon).Assembly.GetManifestResourceStream("talkflow.ico")!)
            _idle = new Icon(stream, SystemInformation.SmallIconSize);
        _recording = WithDot(_idle, Color.FromArgb(0xE5, 0x48, 0x4D));
        _processing = WithDot(_idle, Color.FromArgb(0xF5, 0xA5, 0x24));

        var menu = new ContextMenuStrip();
        _hint = new ToolStripMenuItem { Enabled = false };
        menu.Items.Add(_hint);
        menu.Items.Add(new ToolStripSeparator());
        _update = new ToolStripMenuItem("Update available", null, (_, _) => _app.InstallUpdate()) { Visible = false, Font = new Font(menu.Font, FontStyle.Bold) };
        menu.Items.Add(_update);
        menu.Items.Add("Open talkflow", null, (_, _) => _app.ShowDashboard());
        menu.Items.Add("Settings", null, (_, _) => _app.ShowDashboard(settings: true));
        menu.Items.Add("Setup...", null, (_, _) => _app.ShowOnboarding());
        menu.Items.Add("Report a problem...", null, (_, _) => _app.ReportProblem());

        var style = new ToolStripMenuItem("Writing style");
        _styles = new ToolStripMenuItem[WritingStyles.All.Length];
        for (int i = 0; i < WritingStyles.All.Length; i++)
        {
            var value = WritingStyles.All[i];
            _styles[i] = new ToolStripMenuItem(value.Title(), null, (_, _) => { _app.Settings.WritingStyle = value; Refresh(); });
            style.DropDownItems.Add(_styles[i]);
        }
        menu.Items.Add(style);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit talkflow", null, (_, _) => _app.Quit());
        menu.Opening += (_, _) => Refresh();

        _icon = new NotifyIcon { Icon = _idle, Text = "talkflow", ContextMenuStrip = menu, Visible = true };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) _app.ShowDashboard(); };
        _icon.BalloonTipClicked += (_, _) => _app.ShowDashboard();
        Refresh();
    }

    public void Refresh()
    {
        _hint.Text = $"Hold {_app.Hotkey.Spec.Describe()} to dictate";
        var current = _app.Settings.WritingStyle;
        for (int i = 0; i < _styles.Length; i++) _styles[i].Checked = WritingStyles.All[i] == current;
        if (_app.Updater.Available is { } release)
        {
            _update.Text = $"Update to {release.Version}...";
            _update.Visible = true;
        }
        else
        {
            _update.Visible = false;
        }
    }

    public void SetState(TrayState state)
    {
        _icon.Icon = state switch { TrayState.Recording => _recording, TrayState.Processing => _processing, _ => _idle };
        _icon.Text = state switch { TrayState.Recording => "talkflow: listening", TrayState.Processing => "talkflow: writing", _ => "talkflow" };
    }

    /// <summary>A Windows notification, shown once per new version.</summary>
    public void Notify(string title, string text) => _icon.ShowBalloonTip(8000, title, text, ToolTipIcon.Info);

    static Icon WithDot(Icon source, Color color)
    {
        using var bitmap = source.ToBitmap();
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            int d = Math.Max(6, bitmap.Width / 2);
            using var brush = new SolidBrush(color);
            using var pen = new Pen(Color.White, Math.Max(1, bitmap.Width / 16f));
            var rect = new Rectangle(bitmap.Width - d - 1, bitmap.Height - d - 1, d, d);
            g.FillEllipse(brush, rect);
            g.DrawEllipse(pen, rect);
        }
        return Icon.FromHandle(bitmap.GetHicon());
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
