using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Talkflow;

/// <summary>
/// The small pill at the bottom of the screen while the shortcut is held:
/// level bars that move with your voice, the live caption above it (settled
/// words solid, words whisper may still revise dimmed), and short messages.
/// It never takes focus and clicks pass through it, so the app you are
/// dictating into keeps the keyboard.
/// </summary>
sealed class OverlayWindow : Window
{
    const int BarCount = 9;
    readonly Rectangle[] _bars = new Rectangle[BarCount];
    readonly double[] _levels = new double[BarCount];
    readonly Border _pill;
    readonly Border _bubble;
    readonly TextBlock _caption;
    readonly DispatcherTimer _messageTimer;
    bool _holding;
    /// <summary>Audio has arrived this hold; until then the pill is dim (a Bluetooth headset takes about a second).</summary>
    bool _heard;

    static readonly Brush Ink = new SolidColorBrush(Color.FromRgb(0x1F, 0x1E, 0x22));
    static readonly Brush Paper = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF3));
    static readonly Brush Dim = new SolidColorBrush(Color.FromArgb(0x99, 0xF5, 0xF5, 0xF3));
    static readonly Brush ErrorText = new SolidColorBrush(Color.FromRgb(0xFF, 0x9B, 0x8F));

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

        var bars = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        for (int i = 0; i < BarCount; i++)
        {
            _bars[i] = new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Fill = Paper, Margin = new Thickness(1.5, 0, 1.5, 0), VerticalAlignment = VerticalAlignment.Center };
            bars.Children.Add(_bars[i]);
        }
        _pill = new Border
        {
            Background = Ink,
            CornerRadius = new CornerRadius(14),
            Height = 28,
            MinWidth = 72,
            Padding = new Thickness(12, 0, 12, 0),
            Child = bars,
            HorizontalAlignment = HorizontalAlignment.Center,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
        };

        _caption = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxWidth = 520, FontSize = 13, Foreground = Paper, FontFamily = new FontFamily("Segoe UI") };
        _bubble = new Border
        {
            Background = Ink,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 8, 12, 8),
            Margin = new Thickness(0, 0, 0, 8),
            Child = _caption,
            HorizontalAlignment = HorizontalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };

        var stack = new StackPanel { Margin = new Thickness(8) };
        stack.Children.Add(_bubble);
        stack.Children.Add(_pill);
        Content = stack;

        _messageTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        _messageTimer.Tick += (_, _) =>
        {
            _messageTimer.Stop();
            if (!_holding) base.Hide();
            else _bubble.Visibility = Visibility.Collapsed;
        };

        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int style = Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(hwnd, Native.GWL_EXSTYLE, style | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TRANSPARENT);
        };
        SizeChanged += (_, _) => Place();
    }

    /// <summary>Bottom centre of the screen the user is working on.</summary>
    void Place()
    {
        var screen = System.Windows.Forms.Screen.FromHandle(Native.GetForegroundWindow());
        var area = screen.WorkingArea;
        double scale = 1;
        var source = PresentationSource.FromVisual(this);
        if (source?.CompositionTarget is { } target) scale = target.TransformToDevice.M11;
        Left = area.Left / scale + (area.Width / scale - ActualWidth) / 2;
        Top = area.Bottom / scale - ActualHeight - 24;
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
        _messageTimer.Stop();
        _bubble.Visibility = Visibility.Collapsed;
        _pill.Visibility = Visibility.Visible;
        _pill.Opacity = WaitingOpacity;
        _heard = false;
        Array.Clear(_levels);
        foreach (var bar in _bars) bar.Height = 4;
        if (!IsVisible) base.Show();
        Place();
    }

    public new void Hide()
    {
        _holding = false;
        if (!_messageTimer.IsEnabled) base.Hide();
    }

    /// <summary>Release: the caption stays while the final text is worked out.</summary>
    public void ShowWorking()
    {
        _heard = true;
        _pill.Opacity = 0.6;
    }

    const double WaitingOpacity = 0.4;

    public void PushLevel(float level)
    {
        if (!_holding) return;
        if (!_heard)
        {
            _heard = true;
            _pill.Opacity = 1; // the microphone is listening: speak now
        }
        Array.Copy(_levels, 1, _levels, 0, BarCount - 1);
        _levels[BarCount - 1] = level;
        for (int i = 0; i < BarCount; i++)
        {
            // Centre bars tallest, edges shorter, like the Mac pill.
            double shape = 1 - Math.Abs(i - (BarCount - 1) / 2.0) / BarCount;
            _bars[i].Height = 4 + 14 * Math.Min(1, _levels[i] * 1.6) * shape;
        }
    }

    public void ShowCaption(string settled, string pending)
    {
        if (!_holding) return;
        _caption.Inlines.Clear();
        _caption.Inlines.Add(new Run(settled) { Foreground = Paper });
        _caption.Inlines.Add(new Run(pending) { Foreground = Dim });
        _bubble.Visibility = settled.Length + pending.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public void ShowError(string message) => ShowMessage(message, ErrorText);

    public void ShowNotice(string message) => ShowMessage(message, Paper);

    void ShowMessage(string message, Brush color)
    {
        Log.Write($"pill: {message}");
        _caption.Inlines.Clear();
        _caption.Inlines.Add(new Run(message) { Foreground = color });
        _bubble.Visibility = Visibility.Visible;
        if (!_holding) _pill.Visibility = Visibility.Collapsed;
        if (!IsVisible) base.Show();
        Place();
        _messageTimer.Stop();
        _messageTimer.Start();
    }
}
