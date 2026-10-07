using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Talkflow.Core;
using Talkflow.Core.Text;

namespace Talkflow;

/// <summary>
/// The tray app. One instance per user: a second launch (the Start menu
/// shortcut while talkflow is already running) asks the first one to open
/// the dashboard and exits.
/// </summary>
sealed class App : Application
{
    public SettingsStore Settings { get; private set; } = null!;
    public StatsStore Stats { get; private set; } = null!;
    public WindowsPrefs Prefs { get; private set; } = null!;
    public HotkeyListener Hotkey { get; private set; } = null!;
    public OverlayWindow Overlay { get; private set; } = null!;
    public TrayIcon Tray { get; private set; } = null!;
    public Updater Updater { get; } = new();
    public bool HasRunBefore { get; private set; }

    public bool EngineReady { get; private set; }
    public bool FinalPassReady { get; private set; }

    Dictation _dictation = null!;
    DashboardWindow? _dashboard;
    OnboardingWindow? _onboarding;
    DispatcherTimer? _updateTimer;
    Action<HotkeySpec?>? _onRecorded;
    bool _finalPassStarting;

    public bool IsTryItFocused => _onboarding?.TryItFocused == true;

    // MARK: - Entry point

    [STAThread]
    public static int Main(string[] args)
    {
        if (RunCommand(args) is { } code) return code;

        using var instance = new Mutex(initiallyOwned: true, @"Local\talkflow-app", out bool first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\talkflow-show");
        if (!first)
        {
            show.Set();
            return 0;
        }

        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += (_, _) => app.Start(background: args.Contains("--background"), show);
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write($"unhandled: {e.Exception}");
            e.Handled = true;
        };
        return app.Run();
    }

    /// <summary>
    /// Command-line modes that do one thing and exit, for tests and the
    /// installer. Output goes to stdout when there is a console, and to a file
    /// in %TEMP% either way (a GUI exe has no console of its own).
    /// </summary>
    static int? RunCommand(string[] args)
    {
        int Write(string name, string text)
        {
            File.WriteAllText(Path.Combine(Path.GetTempPath(), name), text, new UTF8Encoding(false));
            if (AttachConsole(-1))
            {
                var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
                stdout.Write(text);
            }
            return 0;
        }

        int index;
        if ((index = Array.IndexOf(args, "--formattest")) >= 0)
        {
            // The exact formatting chain the shortcut uses, without a microphone.
            var raw = index + 1 < args.Length ? args[index + 1] : "";
            if (raw.StartsWith('@') && File.Exists(raw[1..])) raw = File.ReadAllText(raw[1..]);
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var final = Render.Text(raw, "", structure: true);
            return Write("talkflow-formattest.txt", $"{watch.Elapsed.TotalSeconds:F3}s\n{final}");
        }
        if (args.Contains("--uninstall-cleanup"))
        {
            // Run by the uninstaller (Windows "Apps > Uninstall") before it deletes the files.
            Uninstaller.Cleanup(null);
            return 0;
        }
        if (args.Contains("--uninstallplan"))
        {
            var plan = Uninstaller.Plan().Select((step, i) => $"{i + 1}. {step}");
            return Write("talkflow-uninstallplan.txt", string.Join(Environment.NewLine, plan) + Environment.NewLine);
        }
        if (args.Contains("--enginecheck"))
            return Write("talkflow-enginecheck.txt", Diagnostics.EngineReport());
        if (args.Contains("--diagnostics"))
        {
            // The same zip as "Report a problem..." in the tray menu, for when the app will not start.
            var zip = Diagnostics.Create();
            return Write("talkflow-diagnostics.txt", zip + Environment.NewLine);
        }
        return null;
    }

    [DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);

    // MARK: - Startup

    void Start(bool background, EventWaitHandle show)
    {
        Paths.EnsureCreated();
        HasRunBefore = File.Exists(Paths.SettingsFile);
        Log.Write($"launched {Updater.CurrentVersion} ({RuntimeInformation.ProcessArchitecture}), pid {Environment.ProcessId}");

        Settings = new SettingsStore(Paths.SettingsFile);
        Settings.BackUp();
        Stats = new StatsStore(Paths.StatsFile);
        Prefs = new WindowsPrefs();
        ScreenText.IsName = word =>
            !CommonWords.Contains(Chars.Lower(word)) && SpellCheck.IsKnown(Chars.Lower(word)) != true;
        StartupEntry.Refresh();

        Overlay = new OverlayWindow();
        Hotkey = new HotkeyListener(Prefs.Hotkey, action => Dispatcher.BeginInvoke(action));
        Tray = new TrayIcon(this);
        _dictation = new Dictation(this);
        Hotkey.Pressed += _dictation.Begin;
        Hotkey.Released += _dictation.Finish;
        Hotkey.Interrupted += _dictation.Abandon;
        Hotkey.Recorded += keys =>
        {
            var callback = _onRecorded;
            _onRecorded = null;
            callback?.Invoke(keys.Count == 0 ? null : HotkeySpec.FromRecorded(keys));
        };
        if (!Hotkey.IsInstalled) Overlay.ShowError("talkflow could not listen for its shortcut. Restart talkflow.");

        // A second launch asks this one to show itself.
        new Thread(() =>
        {
            while (show.WaitOne()) Dispatcher.BeginInvoke(() => ShowDashboard());
        }) { IsBackground = true, Name = "talkflow activation" }.Start();

        Updater.Changed += OnUpdaterChanged;
        // Shortly after launch, then every six hours. Offline is fine: it tries again later.
        var first = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        first.Tick += (_, _) => { first.Stop(); _ = Updater.Check(); };
        first.Start();
        _updateTimer = new DispatcherTimer { Interval = TimeSpan.FromHours(6) };
        _updateTimer.Tick += (_, _) => _ = Updater.Check();
        _updateTimer.Start();

        _ = StartEngine();
        if (NeedsSetup) ShowOnboarding();
        else if (!background) ShowDashboard();
    }

    void OnUpdaterChanged() => Dispatcher.BeginInvoke(() =>
    {
        Tray.Refresh();
        if (Updater.State == Updater.Phase.Available && Updater.Available is { } release && Prefs.NotifiedVersion != release.Version)
        {
            Prefs.NotifiedVersion = release.Version;
            Tray.Notify("talkflow update available", $"Version {release.Version} is ready. Open talkflow to update.");
        }
    });

    /// <summary>Something required is missing: microphone access, the engine, or the model.</summary>
    public bool NeedsSetup =>
        Microphone.Check() != Microphone.State.Allowed || !SpeechEngine.EngineInstalled || !SpeechEngine.Small.ModelIsComplete;

    /// <summary>Starts small.en (and the final-pass model when wanted). Safe to call again.</summary>
    public async Task StartEngine()
    {
        bool up = await Task.Run(() => SpeechEngine.Small.Start(TimeSpan.FromSeconds(60)));
        EngineReady = up;
        Log.Write(up ? "speech engine ready" : "speech engine is not running (setup incomplete or failed to start)");
        if (up) StartFinalPass();
    }

    /// <summary>large-v3-turbo for the final pass: downloaded in the background on first use.</summary>
    public async void StartFinalPass()
    {
        if (!Settings.AccurateFinalPass || _finalPassStarting || FinalPassReady || !SpeechEngine.EngineInstalled) return;
        _finalPassStarting = true;
        try
        {
            if (!SpeechEngine.Large.ModelIsComplete)
            {
                Log.Write("downloading the final-pass model in the background");
                await Task.Run(() => SpeechEngine.Download(SpeechEngine.Large, null, CancellationToken.None));
            }
            FinalPassReady = await Task.Run(() => SpeechEngine.Large.Start(TimeSpan.FromSeconds(60)));
            Log.Write(FinalPassReady ? "final-pass model ready" : "final-pass server did not answer; using small.en");
        }
        catch (Exception e)
        {
            Log.Write($"final-pass model: {e.Message}");
        }
        finally
        {
            _finalPassStarting = false;
        }
    }

    // MARK: - Windows

    public void ShowDashboard(bool settings = false)
    {
        if (_dashboard is null)
        {
            _dashboard = new DashboardWindow(this);
            _dashboard.Closed += (_, _) => _dashboard = null;
        }
        _dashboard.ShowPage(settings);
        _ = Updater.CheckIfStale();
        Bring(_dashboard);
    }

    public void ShowOnboarding()
    {
        if (_onboarding is null)
        {
            _onboarding = new OnboardingWindow(this);
            _onboarding.Closed += (_, _) => _onboarding = null;
        }
        Bring(_onboarding);
    }

    static void Bring(Window window)
    {
        if (!window.IsVisible) window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        window.Topmost = true;
        window.Topmost = false;
        window.Focus();
    }

    // MARK: - Actions

    public void SetHotkey(HotkeySpec spec)
    {
        Prefs.Hotkey = spec;
        Hotkey.Spec = spec;
        Tray.Refresh();
        Log.Write($"shortcut is now {spec.Describe()}");
    }

    public void RecordHotkey(Action<HotkeySpec?> done)
    {
        _onRecorded = done;
        Hotkey.StartRecording();
    }

    public void InstallUpdate()
    {
        if (Updater.Available is null)
        {
            ShowDashboard();
            return;
        }
        _ = Updater.Install(Quit);
    }

    /// <summary>Tray menu and Settings: saves the diagnostics zip to the Desktop and shows it.</summary>
    public async void ReportProblem()
    {
        try
        {
            // Off the UI thread: the report asks both speech servers, which can take seconds.
            var path = await Task.Run(Diagnostics.Create);
            Diagnostics.Reveal(path);
            Tray.Notify("Diagnostics saved", $"{Path.GetFileName(path)} is on your Desktop. Attach it to an issue or an email. It has no dictated text.");
        }
        catch (Exception e)
        {
            Log.Write($"could not save diagnostics: {e}");
            MessageBox.Show($"Could not save the diagnostics file: {e.Message}", "talkflow");
        }
    }

    public void Uninstall()
    {
        if (!Uninstaller.Run(this))
            MessageBox.Show("talkflow's files were not removed because this copy was not installed by the installer. Its keys, models, logs and startup entry were removed.", "talkflow");
        Quit();
    }

    public void Quit()
    {
        Hotkey?.Dispose();
        Tray?.Dispose();
        SpeechEngine.Small.Stop();
        SpeechEngine.Large.Stop();
        Shutdown();
    }
}
