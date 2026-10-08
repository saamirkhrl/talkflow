using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// First-run setup (Onboarding.swift): three steps, one main action at a time.
/// Microphone: a check mark, or the one Settings page to open. Speech engine:
/// the model downloads by itself the moment this opens and the engine starts
/// when it is done (the download belongs to <see cref="App.ModelDownload"/>, so
/// closing this window does not stop it). Try it: the box takes the keyboard
/// when everything works. Opens again whenever something required is missing.
/// Everything re-checks itself every couple of seconds and whenever the window
/// is activated, so flipping a switch in Windows Settings shows up here
/// without a restart. Nothing here waits on the UI thread: the checks run on
/// the thread pool and only their results are applied here.
/// </summary>
sealed class OnboardingWindow : Window
{
    sealed record Facts(Microphone.State Mic, bool EngineInstalled, bool ModelComplete);

    readonly App _app;
    readonly DispatcherTimer _poll;
    readonly TextBlock _lead;
    readonly Border _micCard, _speechCard, _tryCard;
    readonly TextBlock _micStatus, _micHint, _speechStatus, _speechDetail, _speechNote;
    readonly Button _micButton, _retry, _done;
    readonly ProgressBar _progress = Ui.Progress();
    readonly TextBox _tryIt;
    readonly TextBlock _tryPrompt, _placeholder, _successText;
    readonly FrameworkElement _success;

    Facts? _facts;
    SpeechPhase _phase = SpeechPhase.Preparing;
    Action _micAction = Microphone.OpenSettings;
    bool _checking, _recheck, _closed, _tried, _wasReady, _kickedEngine;

    public OnboardingWindow(App app)
    {
        _app = app;
        Title = "talkflow setup";
        Ui.Style(this, 560, 720);

        // Header.
        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 22) };
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        brand.Children.Add(new Image { Source = Ui.AppIcon, Width = 40, Height = 40, Margin = new Thickness(0, 0, 14, 0) });
        var name = Ui.Numeral("Set up talkflow", 30);
        name.VerticalAlignment = VerticalAlignment.Center;
        brand.Children.Add(name);
        header.Children.Add(brand);
        _lead = Ui.Text("", 13, Ui.Graphite);
        header.Children.Add(_lead);

        // 1. Microphone.
        _micButton = Ui.Button("Open microphone settings", () => _micAction(), primary: true);
        _micButton.Visibility = Visibility.Collapsed;
        _micCard = BuildCard("Microphone", _micButton, out var micBody);
        _micStatus = Ui.Detail("Checking...");
        _micStatus.Margin = new Thickness(0, 4, 0, 0);
        micBody.Children.Add(_micStatus);
        _micHint = Ui.Detail("");
        _micHint.Margin = new Thickness(0, 4, 0, 0);
        _micHint.Visibility = Visibility.Collapsed;
        micBody.Children.Add(_micHint);

        // 2. Speech engine.
        _retry = Ui.Button("Try again", RetrySpeech);
        _retry.Visibility = Visibility.Collapsed;
        _speechCard = BuildCard("Speech engine", _retry, out var speechBody);
        _speechStatus = Ui.Detail("Checking...");
        _speechStatus.Margin = new Thickness(0, 4, 0, 0);
        speechBody.Children.Add(_speechStatus);
        _progress.Margin = new Thickness(0, 10, 0, 0);
        _progress.Visibility = Visibility.Collapsed;
        speechBody.Children.Add(_progress);
        _speechDetail = Ui.Detail("");
        _speechDetail.Margin = new Thickness(0, 8, 0, 0);
        _speechDetail.Visibility = Visibility.Collapsed;
        speechBody.Children.Add(_speechDetail);
        _speechNote = Ui.Text("", 11, Ui.Graphite);
        _speechNote.Margin = new Thickness(0, 4, 0, 0);
        _speechNote.Visibility = Visibility.Collapsed;
        speechBody.Children.Add(_speechNote);

        // 3. Try it.
        _tryCard = BuildCard("Try it", null, out var tryBody);
        _tryPrompt = Ui.Text("", 12, Ui.Graphite);
        _tryPrompt.Margin = new Thickness(0, 4, 0, 0);
        tryBody.Children.Add(_tryPrompt);
        _tryIt = Ui.TextField();
        _tryIt.Height = 76;
        _tryIt.TextWrapping = TextWrapping.Wrap;
        _tryIt.AcceptsReturn = true;
        _tryIt.Padding = new Thickness(10, 8, 10, 8);
        _tryIt.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        AutomationProperties.SetName(_tryIt, "Try it");
        _placeholder = Ui.Text("Your words appear here", 12, Ui.Ink_(0.4));
        _placeholder.Margin = new Thickness(13, 10, 13, 0);
        _placeholder.IsHitTestVisible = false;
        _placeholder.VerticalAlignment = VerticalAlignment.Top;
        var box = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        box.Children.Add(_tryIt);
        box.Children.Add(_placeholder);
        tryBody.Children.Add(box);
        var successRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0), Visibility = Visibility.Collapsed };
        successRow.Children.Add(new Path
        {
            Data = Geometry.Parse("M 1,7 L 5,11 L 12,2"),
            Stroke = Ui.Good,
            StrokeThickness = 2,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Margin = new Thickness(0, 4, 10, 0),
            VerticalAlignment = VerticalAlignment.Top,
        });
        _successText = Ui.Text("", 13, Ui.Ink, FontWeights.SemiBold);
        successRow.Children.Add(_successText);
        _success = successRow;
        tryBody.Children.Add(successRow);
        _tryIt.TextChanged += (_, _) => OnTryText();

        var body = new StackPanel { Margin = new Thickness(32, 28, 32, 8) };
        body.Children.Add(header);
        body.Children.Add(_micCard);
        body.Children.Add(_speechCard);
        body.Children.Add(_tryCard);
        var scroll = new ScrollViewer
        {
            Content = body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };

        // Footer, always in view: start with Windows, and Done.
        var startup = Ui.Switch(StartupEntry.IsEnabled || !_app.HasRunBefore, StartupEntry.Set);
        AutomationProperties.SetName(startup, "Start talkflow when I sign in to Windows");
        if (startup.IsChecked == true) StartupEntry.Set(true);
        var startRow = Ui.Row("Start with Windows", "", startup);
        startRow.Margin = new Thickness(0, 0, 0, 14);
        _done = Ui.Button("Finish later", Close);
        _done.HorizontalAlignment = HorizontalAlignment.Right;
        _done.Padding = new Thickness(22, 7, 22, 7);
        var footer = new StackPanel { Margin = new Thickness(32, 0, 32, 22) };
        footer.Children.Add(new Border { Height = 1, Background = Ui.Line, Margin = new Thickness(0, 0, 0, 16) });
        footer.Children.Add(startRow);
        footer.Children.Add(_done);

        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(scroll);
        Content = root;
        SetOpacity(root, 1, from: 0, milliseconds: 220);

        _poll = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => _ = RefreshAsync(), Dispatcher);
        _poll.Start();
        _app.EngineChanged += Apply;
        _app.ModelDownload.Changed += OnDownloadChanged;
        Activated += (_, _) =>
        {
            _ = RefreshAsync();
            if (_wasReady && !_tried) FocusTryIt();
        };
        Closed += (_, _) =>
        {
            _closed = true;
            _poll.Stop();
            _app.EngineChanged -= Apply;
            _app.ModelDownload.Changed -= OnDownloadChanged;
        };
        Apply();
        _ = RefreshAsync();
    }

    /// <summary>The "try it" box: dictating into talkflow's own window is allowed only here.</summary>
    public bool TryItFocused => IsActive && _tryIt.IsKeyboardFocused;

    /// <summary>The Try it box's text around the caret, read directly (never through UI Automation).</summary>
    public (string Before, string Field) TryItText
    {
        get
        {
            var text = _tryIt.Text;
            int caret = Math.Clamp(_tryIt.CaretIndex, 0, text.Length);
            return (text[..caret], text);
        }
    }

    // MARK: - Building blocks

    static Border BuildCard(string title, UIElement? action, out StackPanel body)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body = new StackPanel();
        body.Children.Add(Ui.Title(title));
        grid.Children.Add(body);
        if (action is not null)
        {
            Grid.SetColumn(action, 1);
            if (action is FrameworkElement element)
            {
                element.VerticalAlignment = VerticalAlignment.Top;
                element.Margin = new Thickness(16, 0, 0, 0);
            }
            grid.Children.Add(action);
        }
        var card = Ui.Card(grid, new Thickness(18, 14, 18, 16));
        card.Margin = new Thickness(0, 0, 0, 12);
        return card;
    }

    // MARK: - Transitions (about 180 ms; none when Windows has animations off)

    static void SetOpacity(UIElement element, double to, double? from = null, int milliseconds = 180)
    {
        element.BeginAnimation(OpacityProperty, null);
        double start = from ?? element.Opacity;
        element.Opacity = to;
        if (!SystemParameters.ClientAreaAnimation || Math.Abs(start - to) < 0.01) return;
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(start, to, TimeSpan.FromMilliseconds(milliseconds)));
    }

    /// <summary>Shows or collapses; showing fades in.</summary>
    static void Show(UIElement element, bool visible)
    {
        if ((element.Visibility == Visibility.Visible) == visible) return;
        element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (visible) SetOpacity(element, 1, from: 0);
    }

    /// <summary>Dims a step that is not reached yet; the first call sets it without a transition.</summary>
    static void Dim(UIElement element, double opacity)
    {
        bool first = element.GetValue(FrameworkElement.TagProperty) is not double;
        if (!first && (double)element.GetValue(FrameworkElement.TagProperty) == opacity) return;
        element.SetValue(FrameworkElement.TagProperty, opacity);
        if (first) element.Opacity = opacity;
        else SetOpacity(element, opacity);
    }

    static void SetText(TextBlock text, string value, Brush color)
    {
        if (text.Text != value) text.Text = value;
        text.Foreground = color;
    }

    // MARK: - Checking

    /// <summary>Reads the microphone setting and the files off the UI thread, then applies what it found.</summary>
    async Task RefreshAsync()
    {
        if (_closed) return;
        if (_checking)
        {
            _recheck = true;
            return;
        }
        _checking = true;
        try
        {
            do
            {
                _recheck = false;
                var facts = await Task.Run(() => new Facts(Microphone.Check(), SpeechEngine.EngineInstalled, SpeechEngine.Small.ModelIsComplete));
                if (_closed) return;
                _facts = facts;
                // The moment setup opens with the model missing, it starts downloading. A failure waits for Try again.
                if (facts.EngineInstalled && !facts.ModelComplete && !_app.EngineReady) _app.ModelDownload.StartIfNeeded();
                Apply();
            } while (_recheck);
        }
        catch (Exception e)
        {
            Log.Write($"setup check failed: {e.Message}");
        }
        finally
        {
            _checking = false;
        }
    }

    void OnDownloadChanged()
    {
        // While bytes arrive, only redraw; when it ends, look at the disk again.
        if (_app.ModelDownload.Downloading) Apply();
        else _ = RefreshAsync();
    }

    void RetrySpeech()
    {
        if (_phase == SpeechPhase.DownloadFailed) _app.ModelDownload.Retry();
        else _ = _app.StartEngine();
        Apply();
    }

    // MARK: - Showing it

    /// <summary>Draws the window from what is known now. Cheap and safe to call from any event on the UI thread.</summary>
    void Apply()
    {
        if (_closed) return;
        string shortcut = _app.Hotkey.Spec.Describe();
        _lead.Text = $"Hold {shortcut}, speak, let go.";
        if (_facts is not { } facts) return;

        var download = _app.ModelDownload;
        bool micOk = facts.Mic == Microphone.State.Allowed;
        _phase = SetupFlow.Speech(facts.EngineInstalled, facts.ModelComplete || _app.EngineReady, download.Downloading, download.Error is not null,
            _app.EngineReady, _app.EngineStarting, _app.EngineError is not null);
        var stage = SetupFlow.Current(micOk, _phase);
        bool ready = stage == SetupStage.TryIt;

        ApplyMicrophone(facts.Mic, stage);
        ApplySpeech(download, stage);
        ApplyTryIt(ready, shortcut);

        bool[] done = { micOk, _phase == SpeechPhase.Ready, ready && _tried };
        foreach (var (card, index) in new[] { (_micCard, 0), (_speechCard, 1), (_tryCard, 2) })
        {
            bool current = (int)stage == index;
            card.BorderBrush = current ? Ui.Ink : Ui.Line;
            Dim(card, current || done[index] ? 1 : 0.55);
        }

        var (label, primary) = SetupFlow.Footer(stage, _tried);
        _done.Content = label;
        Ui.SetPrimary(_done, primary);

        // A server that was never asked to start (not failed, not starting): start it, once, after this pass.
        if (_phase == SpeechPhase.Starting && !_app.EngineStarting && _app.EngineError is null)
        {
            if (!_kickedEngine)
            {
                _kickedEngine = true;
                Dispatcher.BeginInvoke(() => _ = _app.StartEngine());
            }
        }
        else _kickedEngine = false;
    }

    void ApplyMicrophone(Microphone.State mic, SetupStage stage)
    {
        if (mic == Microphone.State.Allowed)
        {
            SetText(_micStatus, "On.", Ui.Graphite);
            Show(_micHint, false);
            Show(_micButton, false);
            return;
        }
        bool none = mic == Microphone.State.NoDevice;
        SetText(_micStatus, none ? "No microphone found." : "Windows is blocking the microphone.", Ui.Bad);
        SetText(_micHint, Microphone.Hint(mic), Ui.Graphite);
        _micButton.Content = none ? "Open sound settings" : "Open microphone settings";
        _micAction = none ? Microphone.OpenSoundSettings : Microphone.OpenSettings;
        Ui.SetPrimary(_micButton, stage == SetupStage.Microphone);
        Show(_micHint, true);
        Show(_micButton, true);
    }

    void ApplySpeech(ModelDownload download, SetupStage stage)
    {
        string status = "", detail = "", note = "";
        var statusColor = Ui.Graphite;
        var detailColor = Ui.Graphite;
        bool bar = false, retry = false;
        switch (_phase)
        {
            case SpeechPhase.EngineMissing:
                status = "Some files are missing. Reinstall talkflow.";
                statusColor = Ui.Bad;
                break;
            case SpeechPhase.Preparing:
                status = "Getting ready...";
                note = "One-time download, 488 MB.";
                break;
            case SpeechPhase.Downloading:
                var meter = download.Meter;
                status = meter.Percent is { } percent ? $"Downloading... {percent}%" : "Downloading...";
                detail = meter.Describe();
                bar = true;
                _progress.Value = meter.Total is > 0 ? Math.Min(1, (double)meter.Written / meter.Total.Value) : 0;
                break;
            case SpeechPhase.DownloadFailed:
                status = "The download did not finish.";
                statusColor = Ui.Bad;
                detail = download.Error ?? "";
                detailColor = Ui.Bad;
                retry = true;
                break;
            case SpeechPhase.Starting:
                status = "Starting...";
                break;
            case SpeechPhase.EngineFailed:
                // Said once and left there: retrying by itself every few seconds would hide the reason.
                status = _app.EngineError ?? "The speech engine did not start.";
                statusColor = Ui.Bad;
                detail = $"Details are in {Log.FilePath}.";
                retry = true;
                break;
            case SpeechPhase.Ready:
                status = "Ready.";
                break;
        }
        SetText(_speechStatus, status, statusColor);
        SetText(_speechDetail, detail, detailColor);
        SetText(_speechNote, note, Ui.Graphite);
        Show(_progress, bar);
        Show(_speechDetail, detail.Length > 0);
        Show(_speechNote, note.Length > 0);
        Ui.SetPrimary(_retry, stage == SetupStage.Speech);
        Show(_retry, retry);
    }

    void ApplyTryIt(bool ready, string shortcut)
    {
        _tryIt.IsEnabled = ready;
        if (!ready)
        {
            SetText(_tryPrompt, "Available after setup.", Ui.Graphite);
            _tryPrompt.FontFamily = Ui.Sans;
            _tryPrompt.FontSize = 12;
        }
        else
        {
            _tryPrompt.FontFamily = Ui.Serif;
            _tryPrompt.FontSize = 20;
            SetText(_tryPrompt, SetupFlow.TryPrompt(shortcut), Ui.Ink);
        }
        Show(_tryPrompt, !_tried);
        _successText.Text = SetupFlow.TrySuccess(shortcut);
        Show(_success, _tried);

        if (ready && !_wasReady) FocusTryIt();
        _wasReady = ready;
    }

    /// <summary>Puts the caret in the Try it box, after the box has been enabled and laid out.</summary>
    void FocusTryIt() => Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
    {
        if (_closed || !_tryIt.IsEnabled || !IsVisible) return;
        _tryIt.Focus();
        Keyboard.Focus(_tryIt);
    });

    void OnTryText()
    {
        _placeholder.Visibility = _tryIt.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_tried || !_tryIt.IsEnabled || _tryIt.Text.Trim().Length == 0) return;
        _tried = true;
        Log.Write("setup: the first words arrived in the Try it box");
        Apply();
    }
}
