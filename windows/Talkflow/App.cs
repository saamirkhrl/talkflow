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
    /// <summary>What was measured on this PC (device.json).</summary>
    DeviceStore _store = null!;
    public WindowsPrefs Prefs { get; private set; } = null!;
    public HotkeyListener Hotkey { get; private set; } = null!;
    public OverlayWindow Overlay { get; private set; } = null!;
    public TrayIcon Tray { get; private set; } = null!;
    public Updater Updater { get; } = new();
    public bool HasRunBefore { get; private set; }
    /// <summary>The model download; lives here so it survives closing the setup window.</summary>
    public ModelDownload ModelDownload { get; private set; } = null!;

    public bool EngineReady { get; private set; }
    public bool FinalPassReady { get; private set; }
    /// <summary>
    /// large-v3-turbo is loaded but too slow on this PC to wait for (a 1 s
    /// clip took over DevicePolicy.FinalPassBudgetSeconds); the final text comes from small.en.
    /// </summary>
    public bool FinalPassTooSlow { get; private set; }
    public bool FinalPassUsable => FinalPassReady && !FinalPassTooSlow;
    /// <summary>How long small.en takes for a 1 s clip on this PC; null until measured.</summary>
    public double? SmallSeconds { get; private set; }
    /// <summary>Live captions (and typing while speaking) run unless this PC is too slow for them to keep up with the final text.</summary>
    public bool LivePreviews => DevicePolicy.LivePreviews(SmallSeconds);
    /// <summary>Whether small.en's server is being started right now.</summary>
    public bool EngineStarting => _engineStart is { IsCompleted: false };
    /// <summary>Why the speech engine is not running, for the pill and setup; null while it runs or starts.</summary>
    public string? EngineError => EngineReady || EngineStarting ? null : SpeechEngine.Small.LastError;
    /// <summary>The engine started, stopped or failed; raised on the UI thread.</summary>
    public event Action? EngineChanged;

    Dictation _dictation = null!;
    DashboardWindow? _dashboard;
    OnboardingWindow? _onboarding;
    DispatcherTimer? _updateTimer;
    Action<HotkeySpec?>? _onRecorded;
    bool _finalPassStarting;
    Task<bool>? _engineStart;

    public bool IsTryItFocused => _onboarding?.TryItFocused == true;
    public bool OnboardingOpen => _onboarding is not null;

    /// <summary>What is around the caret when the dictation is into talkflow's own window: the Try it box, or nothing.</summary>
    public ScreenContext.Snapshot OwnFieldSnapshot()
    {
        var name = System.Diagnostics.Process.GetCurrentProcess().ProcessName;
        if (_onboarding is not { TryItFocused: true } onboarding) return new ScreenContext.Snapshot(name, null, null);
        var (before, field) = onboarding.TryItText;
        return new ScreenContext.Snapshot(name, before.Length > 300 ? before[^300..] : before, field.Length > 4000 ? field[^4000..] : field);
    }

    // MARK: - Entry point

    [STAThread]
    public static int Main(string[] args)
    {
        if (RunCommand(args) is { } code) return code;

        using var instance = new Mutex(initiallyOwned: true, @"Local\talkflow-app", out bool first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\talkflow-show");
        using var setup = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\talkflow-setup");
        if (!first)
        {
            // `talkflow.exe --setup` while it runs opens setup; otherwise the dashboard.
            (args.Contains("--setup") ? setup : show).Set();
            return 0;
        }

        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources[typeof(System.Windows.Controls.Primitives.ScrollBar)] = Ui.ThinScrollBar();
        app.Startup += (_, _) => app.Start(background: args.Contains("--background"), show, setup);
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

    void Start(bool background, EventWaitHandle show, EventWaitHandle setup)
    {
        Paths.EnsureCreated();
        HasRunBefore = File.Exists(Paths.SettingsFile);
        Log.Write($"launched {Updater.DisplayVersion} ({RuntimeInformation.ProcessArchitecture}) on {Environment.OSVersion.VersionString}, pid {Environment.ProcessId}");
        if (TestHooks.Any) Log.Write(TestHooks.Describe());
        UiWatchdog.Start(Dispatcher);

        ModelDownload = new ModelDownload(this);
        Settings = new SettingsStore(Paths.SettingsFile);
        Settings.BackUp();
        Stats = new StatsStore(Paths.StatsFile);
        _store = new DeviceStore(Paths.DeviceFile);
        Prefs = new WindowsPrefs();
        ScreenText.IsName = word =>
            !CommonWords.Contains(Chars.Lower(word)) && SpellCheck.IsKnown(Chars.Lower(word)) != true;
        StartupEntry.Refresh();

        Overlay = new OverlayWindow();
        // The first show of the pill and the first window that uses Ui's
        // shared resources each cost a second or two on a slow PC. Pay both
        // now, after startup, instead of during the first hold or setup.
        Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () => { UiWatchdog.Step = "prewarm: pill"; Overlay.Prewarm(); UiWatchdog.Step = "idle"; });
        Task.Run(WarmImageDecoding);
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
            var signals = new WaitHandle[] { show, setup };
            while (true)
            {
                if (WaitHandle.WaitAny(signals) == 0) Dispatcher.BeginInvoke(() => ShowDashboard());
                else Dispatcher.BeginInvoke(ShowOnboarding);
            }
        }) { IsBackground = true, Name = "talkflow activation" }.Start();

        Updater.Changed += OnUpdaterChanged;
        // Shortly after launch, then every six hours. Offline is fine: it tries again later.
        var first = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        first.Tick += (_, _) => { first.Stop(); _ = Updater.Check(); };
        first.Start();
        _updateTimer = new DispatcherTimer { Interval = TimeSpan.FromHours(6) };
        _updateTimer.Tick += (_, _) => _ = Updater.Check();
        _updateTimer.Start();
        // Release builds only: one empty POST, once per install (docs/telemetry.md).
        var count = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        count.Tick += (_, _) => { count.Stop(); _ = CountInstall(); };
        count.Start();

        _ = StartEngine();
        if (NeedsSetup) ShowOnboarding();
        else if (!background) ShowDashboard();
    }

    /// <summary>
    /// Sends the install counter's one request if this install hasn't been
    /// counted. Silent either way (nothing in the log, so diagnostics carry
    /// nothing new); a failure is retried on the next launch.
    /// </summary>
    async Task CountInstall()
    {
        var url = InstallCounter.ConfiguredUrl(typeof(App).Assembly);
        if (url is null) return;
        using var http = new System.Net.Http.HttpMessageInvoker(InstallCounter.Handler());
        await InstallCounter.CountOnce(url, Prefs, TestHooks.Any, Environment.GetEnvironmentVariable("CI"), http);
    }

    /// <summary>
    /// Decodes the app icon once in the background, so the image codec is
    /// loaded before the first window needs it (setup's first open held the
    /// UI thread for 1.7 s there). Never throws: it only saves time.
    /// </summary>
    static void WarmImageDecoding()
    {
        try
        {
            var image = new System.Windows.Media.Imaging.BitmapImage();
            image.BeginInit();
            image.UriSource = new Uri("pack://application:,,,/talkflow;component/Assets/talkflow-256.png");
            image.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
            image.EndInit();
            image.Freeze();
        }
        catch (Exception e)
        {
            Log.Write($"image decoding warm-up skipped: {e.Message}");
        }
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

    /// <summary>
    /// Starts small.en (and the final-pass model when wanted). Safe to call
    /// again: while a start is under way, every caller gets that same start.
    /// Call on the UI thread.
    /// </summary>
    public Task<bool> StartEngine()
    {
        if (_engineStart is { IsCompleted: false } running) return running;
        var start = _engineStart = StartEngineNow();
        // After the assignment, so a listener already sees EngineStarting (and no stale EngineError).
        EngineChanged?.Invoke();
        return start;
    }

    async Task<bool> StartEngineNow()
    {
        bool up = await Task.Run(() => SpeechEngine.Small.Start(TimeSpan.FromSeconds(60)));
        EngineReady = up;
        Log.Write(up ? "speech engine ready" : $"speech engine is not running: {SpeechEngine.Small.LastError}");
        EngineChanged?.Invoke();
        if (up)
        {
            await ChooseDevice();
            StartFinalPass();
        }
        return up;
    }

    bool _deviceChosen;
    /// <summary>ChooseDevice is done: SmallSeconds and the device name are known (or could not be measured).</summary>
    bool _speedKnown;
    /// <summary>The GPU small.en started on, or "CPU only"; names the device in what is measured on this PC.</summary>
    string _deviceLabel = "CPU only";

    string MeasurementKey(WhisperServer server) =>
        DeviceStore.Key(Path.GetFileName(server.ModelPath), SpeechEngine.Stamp + TestHooks.MeasurementTag, _deviceLabel);

    /// <summary>
    /// GPU or CPU, decided by measuring this PC, once per PC (the result is
    /// kept in device.json for this engine build and device). whisper
    /// runs on the GPU when the engine has a GPU backend and the driver offers
    /// a device (as the Mac runs on Metal), but a weak integrated GPU can be
    /// slower than a good CPU. So small.en times a 1 s clip where it runs, a
    /// CPU-only copy on a spare port times the same clip, and the slower one
    /// loses. The time of the winner is what marks a slow PC (see
    /// DevicePolicy). Never while a dictation is in flight. The final-pass
    /// model starts after this, on the same device.
    /// </summary>
    async Task ChooseDevice()
    {
        if (_deviceChosen) return;
        _deviceChosen = true;
        var small = SpeechEngine.Small;
        _deviceLabel = small.OnGpu ? small.DeviceName : "CPU only";
        var key = MeasurementKey(small);
        if (_store.Get(key) is { Seconds: { } known } earlier)
        {
            SmallSeconds = known;
            Log.Write($"device: {_deviceLabel}: a 1 s clip took {Seconds(known)}" + (earlier.CpuSeconds is { } c ? $" ({Seconds(c)} on the CPU)" : "")
                + $" when measured on {earlier.At.ToLocalTime():yyyy-MM-dd}; using the {(earlier.UseCpu == true || !small.OnGpu ? "CPU" : "GPU")} (not measured again)");
            if (earlier.UseCpu == true) await SwitchToCpu();
            ReportSpeed();
            return;
        }
        if (!small.OnGpu)
        {
            Log.Write($"device: {small.DeviceName}" + (SpeechEngine.HasGpuBackend ? " (no GPU offered by the driver)" : " (this engine has no GPU backend)"));
            double? alone = await TimeClipWhenIdle(small.InferenceUrl);
            SmallSeconds = alone;
            Log.Write($"device: a 1 s clip took {Seconds(alone)} on the CPU");
            Remember(key, alone, null, useCpu: false);
            ReportSpeed();
            return;
        }
        double? gpu = await TimeClipWhenIdle(small.InferenceUrl);
        await WaitUntilIdle();
        var probe = new WhisperServer("small.en CPU check", 8180, "ggml-small.en.bin", small.DownloadUrl.ToString(), 1, small.ModelPath);
        probe.UseCpu();
        double? cpu = null;
        try
        {
            if (await Task.Run(() => probe.Start(TimeSpan.FromSeconds(60)))) cpu = await TimeClipWhenIdle(probe.InferenceUrl);
        }
        finally
        {
            probe.Stop();
        }
        // The CPU has to win clearly: the GPU leaves the CPU to the app being typed into.
        bool useCpu = gpu is null || cpu is not null && cpu < gpu * 0.8;
        SmallSeconds = useCpu ? cpu : gpu;
        Log.Write($"device: a 1 s clip took {Seconds(gpu)} on {small.DeviceName}, {Seconds(cpu)} on the CPU; using the {(useCpu ? "CPU" : "GPU")}");
        Remember(key, SmallSeconds, cpu, useCpu);
        if (useCpu) await SwitchToCpu();
        ReportSpeed();
    }

    /// <summary>Keeps a speed test for the next launch, unless it got no answer.</summary>
    void Remember(string key, double? seconds, double? cpuSeconds, bool useCpu)
    {
        if (seconds is null) return;
        _store.Set(key, new DeviceEntry(seconds, cpuSeconds, useCpu, null, DateTime.UtcNow));
    }

    async Task SwitchToCpu()
    {
        SpeechEngine.Small.UseCpu();
        SpeechEngine.Large.UseCpu();
        while (_dictation.InFlight) await Task.Delay(500); // never pull the engine out from under a hold
        EngineReady = false;
        EngineChanged?.Invoke();
        SpeechEngine.Small.Stop();
        EngineReady = await Task.Run(() => SpeechEngine.Small.Start(TimeSpan.FromSeconds(60)));
        Log.Write(EngineReady ? "speech engine ready on the CPU" : $"speech engine is not running: {SpeechEngine.Small.LastError}");
        EngineChanged?.Invoke();
    }

    /// <summary>Says in the log what the speed means for this PC: slow ones run no live captions (Dictation reads LivePreviews).</summary>
    void ReportSpeed()
    {
        _speedKnown = true;
        Log.Write(DevicePolicy.IsSlow(SmallSeconds)
            ? $"slow PC: small.en needs {Seconds(SmallSeconds)} for a 1 s clip (limit {DevicePolicy.SlowSmallSeconds:F1}s), so live captions are off and the final text never queues behind one"
            : $"live captions are on: small.en needs {Seconds(SmallSeconds)} for a 1 s clip");
        EngineChanged?.Invoke();
    }

    static string Seconds(double? s) => s is { } v ? $"{v:F2}s" : "(no answer)";

    /// <summary>Waits for the hold and its text to be finished: a speed test or a model start taking the CPU in the middle of one would slow it and read as the PC's speed.</summary>
    async Task WaitUntilIdle()
    {
        while (_dictation.InFlight) await Task.Delay(500);
    }

    /// <summary>
    /// <see cref="TimeClip"/> when no dictation is in flight, and only counted
    /// if none started or ended during it (then it is done again, three times
    /// at most): a number measured while a dictation shared the engine would
    /// be kept as this PC's speed.
    /// </summary>
    async Task<double?> TimeClipWhenIdle(Uri server)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            await WaitUntilIdle();
            int activity = _dictation.Activity;
            double? seconds = await TimeClip(server);
            if (_dictation.Activity == activity && !_dictation.InFlight) return seconds;
            Log.Write("speed test: a dictation overlapped it, so it is done again");
        }
        Log.Write("speed test: not counted, a dictation overlapped every try");
        return null;
    }

    /// <summary>The second of two runs of a 1 s clip of silence: the first loads whatever the device loads lazily.</summary>
    static async Task<double?> TimeClip(Uri server)
    {
        var clip = Wav.FromSamples(new short[Recorder.SampleRate], Recorder.SampleRate);
        double? last = null;
        for (int run = 0; run < 2; run++)
        {
            var (result, _) = await Transcriber.Transcribe(clip, server, TimeSpan.FromSeconds(30), "");
            last = result?.Elapsed;
            if (last is null) break;
        }
        return last;
    }

    /// <summary>A transcription found nothing listening: the server died. Starts it again.</summary>
    public void EngineLost()
    {
        if (!EngineReady) return;
        EngineReady = false;
        Log.Write("the speech engine stopped answering; starting it again");
        EngineChanged?.Invoke();
        _ = StartEngine();
    }

    /// <summary>What was decided about the final pass on this PC; the Settings page words it.</summary>
    public FinalPassAction FinalPassPlan { get; private set; } = FinalPassAction.StartAndMeasure;
    double? _largeSeconds;

    public string FinalPassStatus => Settings.AccurateFinalPass
        ? FinalPassText.Describe(FinalPassPlan, SmallSeconds, _largeSeconds, FinalPassUsable, SpeechEngine.Large.ModelIsComplete)
        : "Downloads 574 MB once, if this PC can use it.";

    /// <summary>
    /// large-v3-turbo for the final pass: downloaded in the background on
    /// first use, but only on a PC that can use it. Decided from what is
    /// already known (DevicePolicy.DecideFinalPass): a verdict kept from an
    /// earlier launch, or small.en's own speed, which says the large model
    /// cannot meet the budget before 574 MB are downloaded for it. Otherwise
    /// it is downloaded, started once no dictation is in flight, timed, and
    /// stopped again if too slow.
    /// </summary>
    public async void StartFinalPass()
    {
        // Not before the device is chosen and small.en timed: the decision rests on both.
        if (!Settings.AccurateFinalPass || _finalPassStarting || FinalPassReady || !SpeechEngine.EngineInstalled || !_speedKnown) return;
        _finalPassStarting = true;
        try
        {
            var key = MeasurementKey(SpeechEngine.Large);
            FinalPassPlan = DevicePolicy.DecideFinalPass(true, _store.Get(key), SmallSeconds);
            _largeSeconds = _store.Get(key)?.Seconds;
            switch (FinalPassPlan)
            {
                case FinalPassAction.SkipKnownSlow:
                    FinalPassTooSlow = true;
                    Log.Write($"final-pass model: skipped, an earlier test on this PC took {Seconds(_largeSeconds)} for a 1 s clip (budget {DevicePolicy.FinalPassBudgetSeconds:F1}s); not downloaded or started");
                    EngineChanged?.Invoke();
                    return;
                case FinalPassAction.SkipPredictedSlow:
                    FinalPassTooSlow = true;
                    Log.Write($"final-pass model: skipped, small.en needs {Seconds(SmallSeconds)} for a 1 s clip, so large-v3-turbo would need at least {Seconds(DevicePolicy.PredictedLargeSeconds(SmallSeconds!.Value))} (budget {DevicePolicy.FinalPassBudgetSeconds:F1}s); not downloaded or started");
                    EngineChanged?.Invoke();
                    return;
            }
            EngineChanged?.Invoke();
            if (!SpeechEngine.Large.ModelIsComplete)
            {
                Log.Write("downloading the final-pass model in the background");
                await Task.Run(() => SpeechEngine.Download(SpeechEngine.Large, null, CancellationToken.None));
            }
            await WaitUntilIdle();
            FinalPassReady = await Task.Run(() => SpeechEngine.Large.Start(TimeSpan.FromSeconds(60)));
            Log.Write(FinalPassReady ? "final-pass model ready" : "final-pass server did not answer; using small.en");
            if (FinalPassReady && FinalPassPlan == FinalPassAction.StartAndMeasure) await MeasureFinalPass(key);
            EngineChanged?.Invoke();
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

    /// <summary>
    /// Times large-v3-turbo on a 1 s clip of silence. Whisper encodes a full
    /// 30 s window whatever the length, so this is about the least any final
    /// pass costs; on a PC where that is seconds, every dictation would wait.
    /// The second of two runs counts: on a GPU the first one also prepares
    /// its programs (7.6 s, then 0.13 s, on an RTX 4070). A model that is too
    /// slow is stopped at once (it held 570 MB of graphics memory and a second
    /// process for nothing) and the verdict is kept, so the next launch does
    /// not download, start and time it again.
    /// </summary>
    async Task MeasureFinalPass(string key)
    {
        double? elapsed = await TimeClipWhenIdle(SpeechEngine.Large.InferenceUrl);
        if (elapsed is not { } seconds)
        {
            Log.Write("final-pass model: the speed test got no answer; using it anyway");
            return;
        }
        _largeSeconds = seconds;
        FinalPassTooSlow = seconds > DevicePolicy.FinalPassBudgetSeconds;
        _store.Set(key, new DeviceEntry(seconds, null, null, FinalPassTooSlow, DateTime.UtcNow));
        if (!FinalPassTooSlow)
        {
            Log.Write($"final-pass model: a 1 s clip took {seconds:F2}s, using it for the final text");
            return;
        }
        FinalPassReady = false;
        await Task.Run(SpeechEngine.Large.Stop);
        Log.Write($"final-pass model: a 1 s clip took {seconds:F2}s (budget {DevicePolicy.FinalPassBudgetSeconds:F1}s), too slow on this PC; stopped it, and the final text comes from small.en");
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
