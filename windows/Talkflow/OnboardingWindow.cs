using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace Talkflow;

/// <summary>
/// First-run setup (Onboarding.swift): microphone access, the speech engine,
/// the model download, a box to try it in, and starting with Windows. Opens
/// again whenever something required is missing. Each step re-checks itself
/// every couple of seconds, so flipping a switch in Windows Settings shows up
/// here without a restart.
/// </summary>
sealed class OnboardingWindow : Window
{
    readonly App _app;
    readonly DispatcherTimer _poll;
    readonly Step _mic, _engine, _model;
    readonly ProgressBar _progress = new() { Height = 6, Minimum = 0, Maximum = 1, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
    readonly Button _download, _openPrivacy, _retryEngine, _done;
    readonly TextBox _tryIt;
    readonly TextBlock _tryHint;
    CancellationTokenSource? _downloading;

    sealed record Step(TextBlock Mark, TextBlock Status);

    public OnboardingWindow(App app)
    {
        _app = app;
        Title = "talkflow setup";
        Ui.Style(this, 560, 680);

        var panel = new StackPanel { Margin = new Thickness(32, 28, 32, 24) };
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        brand.Children.Add(new Image { Source = Ui.AppIcon, Width = 36, Height = 36, Margin = new Thickness(0, 0, 12, 0) });
        var name = Ui.Numeral("Set up talkflow", 26);
        name.VerticalAlignment = VerticalAlignment.Center;
        brand.Children.Add(name);
        panel.Children.Add(brand);
        var lead = Ui.Text($"Hold {_app.Hotkey.Spec.Describe()}, speak, let go: your words are typed where your cursor is. Everything runs on this PC.", 13, Ui.Graphite);
        lead.Margin = new Thickness(0, 0, 0, 22);
        panel.Children.Add(lead);

        _openPrivacy = Ui.Button("Open privacy settings", Microphone.OpenSettings);
        _mic = AddStep(panel, "1", "Microphone", _openPrivacy);

        _retryEngine = Ui.Button("Try again", () => { _ = _app.StartEngine(); Refresh(); });
        _engine = AddStep(panel, "2", "Speech engine", _retryEngine);

        _download = Ui.Button("Download (488 MB)", StartDownload, primary: true);
        _model = AddStep(panel, "3", "English speech model", _download);
        panel.Children.Add(_progress);

        var tryTitle = Ui.Title("4   Try it");
        tryTitle.Margin = new Thickness(0, 18, 0, 6);
        panel.Children.Add(tryTitle);
        _tryHint = Ui.Detail($"Click in the box, hold {_app.Hotkey.Spec.Describe()}, say a sentence, let go.");
        panel.Children.Add(_tryHint);
        _tryIt = Ui.TextField();
        _tryIt.Height = 90;
        _tryIt.TextWrapping = TextWrapping.Wrap;
        _tryIt.AcceptsReturn = true;
        _tryIt.Margin = new Thickness(0, 8, 0, 0);
        _tryIt.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        panel.Children.Add(_tryIt);

        var startup = new CheckBox
        {
            Content = Ui.Text("Start talkflow when I sign in to Windows", 13),
            IsChecked = StartupEntry.IsEnabled || !_app.HasRunBefore,
            Margin = new Thickness(0, 18, 0, 0),
            Foreground = Ui.Ink,
        };
        startup.Checked += (_, _) => StartupEntry.Set(true);
        startup.Unchecked += (_, _) => StartupEntry.Set(false);
        if (startup.IsChecked == true) StartupEntry.Set(true);
        panel.Children.Add(startup);

        _done = Ui.Button("Done", Close, primary: true);
        _done.HorizontalAlignment = HorizontalAlignment.Right;
        _done.Margin = new Thickness(0, 20, 0, 0);
        panel.Children.Add(_done);

        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        _poll = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => Refresh(), Dispatcher);
        _poll.Start();
        _app.EngineChanged += Refresh;
        Closed += (_, _) =>
        {
            _poll.Stop();
            _app.EngineChanged -= Refresh;
        };
        Refresh();
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

    static Step AddStep(Panel panel, string number, string title, UIElement? action)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = Ui.Text(number, 14, Ui.Graphite, FontWeights.SemiBold, wrap: false);
        grid.Children.Add(mark);
        var text = new StackPanel();
        text.Children.Add(Ui.Title(title));
        var status = Ui.Detail("Checking...");
        status.Margin = new Thickness(0, 3, 12, 0);
        text.Children.Add(status);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (action is not null)
        {
            Grid.SetColumn(action, 2);
            if (action is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Top;
            grid.Children.Add(action);
        }
        panel.Children.Add(grid);
        return new Step(mark, status);
    }

    static void Mark(Step step, bool ok, string status, bool error = false)
    {
        step.Mark.Text = ok ? "✓" : step.Mark.Text is "✓" or "!" ? "•" : step.Mark.Text;
        if (!ok && error) step.Mark.Text = "!";
        step.Mark.Foreground = ok ? Ui.Good : error ? Ui.Bad : Ui.Graphite;
        step.Status.Text = status;
        step.Status.Foreground = error ? Ui.Bad : Ui.Graphite;
    }

    void Refresh()
    {
        var mic = Microphone.Check();
        Mark(_mic, mic == Microphone.State.Allowed, Microphone.Describe(mic), mic != Microphone.State.Allowed);
        _openPrivacy.Visibility = mic == Microphone.State.Allowed ? Visibility.Collapsed : Visibility.Visible;

        bool engine = SpeechEngine.EngineInstalled;
        bool model = SpeechEngine.Small.ModelIsComplete;
        bool failed = false;
        if (!engine) Mark(_engine, false, "whisper-server.exe is missing from the install folder. Reinstall talkflow.", true);
        else if (!model) Mark(_engine, false, "Installed. Starts once the model is downloaded.");
        else if (_app.EngineReady) Mark(_engine, true, "Running on this PC (whisper.cpp).");
        else if (_app.EngineStarting) Mark(_engine, false, "Starting...");
        else if (_app.EngineError is { } error)
        {
            // Said once and left there: retrying by itself every few seconds
            // would hide the reason. The log has the engine's own output.
            Mark(_engine, false, error + $" Details are in {Log.FilePath}.", true);
            failed = true;
        }
        else
        {
            Mark(_engine, false, "Starting...");
            _ = _app.StartEngine();
        }
        _retryEngine.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;

        if (_downloading is null)
        {
            Mark(_model, model, model ? "small.en is downloaded." : "Downloads once from Hugging Face (488 MB), then works offline.");
            _download.Visibility = model ? Visibility.Collapsed : Visibility.Visible;
        }

        bool ready = mic == Microphone.State.Allowed && engine && model && _app.EngineReady;
        _done.Content = ready ? "Done" : "Finish later";
        _tryIt.IsEnabled = ready;
        _tryHint.Text = ready
            ? $"Click in the box, hold {_app.Hotkey.Spec.Describe()}, say a sentence, let go."
            : "Available once the steps above are done.";
    }

    async void StartDownload()
    {
        if (_downloading is not null) return;
        _downloading = new CancellationTokenSource();
        _download.IsEnabled = false;
        _progress.Visibility = Visibility.Visible;
        var progress = new Progress<double>(p =>
        {
            _progress.Value = p;
            Mark(_model, false, $"Downloading... {p * 100:F0}%");
        });
        try
        {
            await Task.Run(() => SpeechEngine.Download(SpeechEngine.Small, progress, _downloading.Token));
            Mark(_model, true, "small.en is downloaded.");
            await _app.StartEngine();
        }
        catch (Exception e)
        {
            Log.Write($"model download failed: {e.Message}");
            Mark(_model, false, "Download failed: " + e.Message, true);
            _download.IsEnabled = true;
        }
        finally
        {
            _downloading = null;
            _progress.Visibility = Visibility.Collapsed;
            Refresh();
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        _downloading?.Cancel();
        base.OnClosed(e);
    }
}
