using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Talkflow;

/// <summary>
/// The floating pill (Overlay.swift), drawn to the Mac's measurements: a
/// 150 x 40 black bar, bottom centre of the screen, with a pulsing red dot and
/// nine thin bars that move with the microphone level. Above it, the live
/// caption (settled words solid, words whisper may still revise dimmed), and
/// above that, short notices. The dot stays red for as long as the pill is up,
/// recording or finishing; there is no separate "working" look.
///
/// One window holds all three, bottom-anchored; the pill keeps its space when
/// hidden so a notice sits where it does on the Mac. It never takes focus and
/// clicks pass through it, so the app you are dictating into keeps the keyboard.
/// </summary>
sealed class OverlayWindow : Window
{
    // Overlay.swift
    const double PillWidth = 150, PillHeight = 40;
    const int BarCount = 9;
    const double DotSize = 10, SidePadding = 16;
    const double BarWidth = 2.5, BarSpacing = 3.5, BarMinHeight = 4, BarMaxHeight = PillHeight * 0.7;
    /// <summary>The pill's bottom edge above the bottom of the screen.</summary>
    const double BottomOffset = 70;
    const double CaptionMaxWidth = 560, CaptionPadding = 14;
    const int CaptionMaxCharacters = 240;
    const double NoticeMaxTextWidth = 480;

    readonly Rectangle[] _bars = new Rectangle[BarCount];
    readonly double[] _levels = new double[BarCount];
    readonly Border _pill;
    readonly Border _bubble;
    readonly TextBlock _caption;
    readonly Border _notice;
    readonly Ellipse _noticeDot;
    readonly TextBlock _noticeText;
    readonly DispatcherTimer _noticeTimer;
    bool _holding;

    static readonly Brush Panel = Frozen(Color.FromArgb(0xE0, 0, 0, 0)); // black, 0.88
    static readonly Brush White = Brushes.White;
    static readonly Brush Dim = Frozen(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)); // white, 0.55
    static readonly Brush Red = Frozen(Color.FromRgb(0xFF, 0x3B, 0x30)); // systemRed
    static readonly Brush RedBorder = Frozen(Color.FromArgb(0x99, 0xFF, 0x3B, 0x30));
    static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");

    static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    static Effect Shadow() => new DropShadowEffect { BlurRadius = 14, ShadowDepth = 2, Direction = 270, Opacity = 0.35, Color = Colors.Black };

    public OverlayWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Title = "talkflow";

        // The pill: dot on the left, a tight cluster of bars centred in the rest.
        var canvas = new Canvas { Width = PillWidth, Height = PillHeight };
        var dot = new Ellipse { Width = DotSize, Height = DotSize, Fill = Red };
        Canvas.SetLeft(dot, SidePadding);
        Canvas.SetTop(dot, (PillHeight - DotSize) / 2);
        canvas.Children.Add(dot);
        dot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, TimeSpan.FromSeconds(0.6))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
        });
        double regionStart = SidePadding + DotSize + 14, regionEnd = PillWidth - SidePadding;
        double cluster = BarCount * BarWidth + (BarCount - 1) * BarSpacing;
        double clusterStart = regionStart + (regionEnd - regionStart - cluster) / 2;
        for (int i = 0; i < BarCount; i++)
        {
            _bars[i] = new Rectangle { Width = BarWidth, Height = BarMinHeight, RadiusX = BarWidth / 2, RadiusY = BarWidth / 2, Fill = White };
            Canvas.SetLeft(_bars[i], clusterStart + i * (BarWidth + BarSpacing));
            Canvas.SetTop(_bars[i], (PillHeight - BarMinHeight) / 2);
            canvas.Children.Add(_bars[i]);
        }
        _pill = new Border
        {
            Background = Panel,
            CornerRadius = new CornerRadius(PillHeight / 2),
            Width = PillWidth,
            Height = PillHeight,
            Child = canvas,
            HorizontalAlignment = HorizontalAlignment.Center,
            Effect = Shadow(),
            Visibility = Visibility.Hidden,
        };

        _caption = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = CaptionMaxWidth - 2 * CaptionPadding,
            FontSize = 15,
            FontWeight = FontWeights.Medium,
            FontFamily = Font,
            Foreground = White,
        };
        _bubble = new Border
        {
            Background = Panel,
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(CaptionPadding, CaptionPadding - 4, CaptionPadding, CaptionPadding - 2),
            Margin = new Thickness(0, 0, 0, 10),
            Child = _caption,
            HorizontalAlignment = HorizontalAlignment.Center,
            Effect = Shadow(),
            Visibility = Visibility.Collapsed,
        };

        _noticeDot = new Ellipse { Width = 8, Height = 8, Fill = Red, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        _noticeText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = NoticeMaxTextWidth,
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            FontFamily = Font,
            Foreground = White,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var noticeRow = new StackPanel { Orientation = Orientation.Horizontal };
        noticeRow.Children.Add(_noticeDot);
        noticeRow.Children.Add(_noticeText);
        _notice = new Border
        {
            Background = Panel,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            BorderBrush = RedBorder,
            MinHeight = 32,
            Padding = new Thickness(14, 7, 14, 7),
            Margin = new Thickness(0, 0, 0, 10),
            Child = noticeRow,
            HorizontalAlignment = HorizontalAlignment.Center,
            Effect = Shadow(),
            Visibility = Visibility.Collapsed,
        };

        // Room around the panels for their shadows.
        var stack = new StackPanel { Margin = new Thickness(16, 16, 16, 8) };
        stack.Children.Add(_notice);
        stack.Children.Add(_bubble);
        stack.Children.Add(_pill);
        Content = stack;

        _noticeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _noticeTimer.Tick += (_, _) =>
        {
            _noticeTimer.Stop();
            _notice.Visibility = Visibility.Collapsed;
            if (!_holding) base.Hide();
        };

        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int style = Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(hwnd, Native.GWL_EXSTYLE, style | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TRANSPARENT);
        };
        SizeChanged += (_, _) => Place();
    }

    /// <summary>Bottom centre of the screen the user is working on, the pill BottomOffset above its bottom edge.</summary>
    void Place()
    {
        var screen = System.Windows.Forms.Screen.FromHandle(Native.GetForegroundWindow());
        double scale = 1;
        var source = PresentationSource.FromVisual(this);
        if (source?.CompositionTarget is { } target) scale = target.TransformToDevice.M11;
        var bounds = screen.Bounds;
        // Clear of a taskbar taller than the Mac's dock gap, too.
        double bottom = Math.Min(bounds.Bottom / scale - BottomOffset, screen.WorkingArea.Bottom / scale - 16);
        Left = bounds.Left / scale + (bounds.Width / scale - ActualWidth) / 2;
        Top = bottom - ActualHeight + 8; // the stack's bottom margin
    }

    /// <summary>
    /// Shows the window once, invisible and off screen, then hides it. The
    /// first show of a WPF window builds its render target, which held the UI
    /// thread for about two seconds on a Windows on Arm machine; done at
    /// launch, the first hold's pill appears at once.
    /// </summary>
    public void Prewarm()
    {
        if (IsVisible) return;
        var opacity = Opacity;
        Opacity = 0;
        Left = -32000;
        Top = -32000;
        base.Show();
        base.Hide();
        Opacity = opacity;
    }

    public new void Show()
    {
        _holding = true;
        _bubble.Visibility = Visibility.Collapsed;
        _pill.Visibility = Visibility.Visible;
        Array.Clear(_levels);
        RenderBars();
        if (!IsVisible) base.Show();
        Place();
    }

    public new void Hide()
    {
        _holding = false;
        _pill.Visibility = Visibility.Hidden;
        _bubble.Visibility = Visibility.Collapsed;
        if (_notice.Visibility != Visibility.Visible) base.Hide();
    }

    /// <summary>Release. The Mac pill does not change while the final text is worked out, and neither does this one.</summary>
    public void ShowWorking() { }

    public void PushLevel(float level)
    {
        if (!_holding) return;
        Array.Copy(_levels, 1, _levels, 0, BarCount - 1);
        _levels[BarCount - 1] = level;
        RenderBars();
    }

    void RenderBars()
    {
        for (int i = 0; i < BarCount; i++)
        {
            double h = BarMinHeight + Math.Clamp(_levels[i], 0, 1) * (BarMaxHeight - BarMinHeight);
            _bars[i].Height = h;
            Canvas.SetTop(_bars[i], (PillHeight - h) / 2);
        }
    }

    /// <summary>What has been heard so far; only the end of a long dictation, as on the Mac.</summary>
    public void ShowCaption(string settled, string pending)
    {
        if (!_holding) return;
        string full = settled + pending;
        if (full.Trim().Length == 0) return;
        int cut = Math.Max(0, full.Length - CaptionMaxCharacters);
        if (cut > 0)
        {
            int space = full.IndexOf(' ', cut);
            if (space >= 0) cut = space + 1;
        }
        string settledShown = settled[Math.Min(cut, settled.Length)..];
        string pendingShown = pending[Math.Clamp(cut - settled.Length, 0, pending.Length)..];
        _caption.Inlines.Clear();
        if (cut > 0) _caption.Inlines.Add(new Run("... ") { Foreground = Dim });
        _caption.Inlines.Add(new Run(settledShown.Replace('\n', ' ')) { Foreground = White });
        _caption.Inlines.Add(new Run(pendingShown.Replace('\n', ' ')) { Foreground = Dim });
        _bubble.Visibility = Visibility.Visible;
    }

    public void ShowError(string message) => ShowMessage(message, error: true);

    public void ShowNotice(string message) => ShowMessage(message, error: false);

    /// <summary>A short message above the pill. It outlives Hide: the pill goes the moment the text is in, and the message must still be readable.</summary>
    void ShowMessage(string message, bool error)
    {
        Log.Write($"pill: {message}");
        _noticeText.Text = message;
        _noticeDot.Fill = error ? Red : White;
        _notice.BorderBrush = error ? RedBorder : Brushes.Transparent;
        _notice.Visibility = Visibility.Visible;
        if (!IsVisible) base.Show();
        Place();
        _noticeTimer.Stop();
        _noticeTimer.Start();
    }
}
