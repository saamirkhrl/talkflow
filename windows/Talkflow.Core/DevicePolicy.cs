using System.Globalization;
using System.Text.Json;

namespace Talkflow.Core;

/// <summary>What to do about the optional large-v3-turbo final pass on this PC.</summary>
public enum FinalPassAction
{
    /// <summary>The setting is off.</summary>
    Off,
    /// <summary>A test on this PC (same model, engine and device) already found it too slow: do not download, start or test it again.</summary>
    SkipKnownSlow,
    /// <summary>small.en is already so slow here that large-v3-turbo cannot meet the budget: do not even download it.</summary>
    SkipPredictedSlow,
    /// <summary>A test on this PC found it fast enough: start it without testing again.</summary>
    StartTrusted,
    /// <summary>Nothing is known: download if needed, start, time a 1 s clip, and keep the verdict.</summary>
    StartAndMeasure,
}

/// <summary>
/// How the speech engine is tuned to this PC, from what was measured on it:
/// the thread count, whether live previews run, and whether the big
/// final-pass model is worth downloading. Pure, so each rule is tested.
/// </summary>
public static class DevicePolicy
{
    /// <summary>The longest a 1 s clip may take on large-v3-turbo for the final pass to be used.</summary>
    public const double FinalPassBudgetSeconds = 2.0;

    /// <summary>
    /// How many times slower large-v3-turbo (q5_0) is than small.en for the
    /// same 1 s clip, as a floor. Whisper always encodes a 30 s window, and the
    /// large model's encoder is 32 layers of width 1280 against small.en's 12
    /// of 768: about 7 times the arithmetic. One real PC measured 3.6 (Intel
    /// Iris Xe: 4.69 s against 1.29 s). The floor is set under that, so a PC
    /// is only skipped when it could not have passed; a PC where the large
    /// model would be fast has a small.en that is fast too.
    /// </summary>
    public const double LargeToSmallRatio = 2.5;

    /// <summary>
    /// A 1 s clip taking this long or more on small.en marks a slow PC: a live
    /// preview there costs as much as the final text and would queue ahead of
    /// it, so the previews are off.
    /// </summary>
    public const double SlowSmallSeconds = 1.0;

    /// <summary>A measurement older than this is made again (drivers and the OS change underneath).</summary>
    public static readonly TimeSpan MeasurementMaxAge = TimeSpan.FromDays(30);

    /// <summary>The least large-v3-turbo can take for a 1 s clip on a PC where small.en takes <paramref name="smallSeconds"/>.</summary>
    public static double PredictedLargeSeconds(double smallSeconds) => smallSeconds * LargeToSmallRatio;

    public static bool IsSlow(double? smallSeconds) => smallSeconds is { } s && s >= SlowSmallSeconds;

    /// <summary>Live previews run unless this PC is slow (or has not been measured).</summary>
    public static bool LivePreviews(double? smallSeconds) => !IsSlow(smallSeconds);

    /// <param name="enabled">Settings > Accurate final pass.</param>
    /// <param name="verdict">An earlier test on this PC, if there is a current one.</param>
    /// <param name="smallSeconds">small.en's 1 s clip time on this PC, if measured.</param>
    public static FinalPassAction DecideFinalPass(bool enabled, DeviceEntry? verdict, double? smallSeconds)
    {
        if (!enabled) return FinalPassAction.Off;
        if (verdict?.TooSlow is { } tooSlow) return tooSlow ? FinalPassAction.SkipKnownSlow : FinalPassAction.StartTrusted;
        if (smallSeconds is { } s && PredictedLargeSeconds(s) > FinalPassBudgetSeconds) return FinalPassAction.SkipPredictedSlow;
        return FinalPassAction.StartAndMeasure;
    }

    /// <summary>
    /// Threads for whisper's CPU work: the physical cores, one fewer on a
    /// chip with more than four so the app being typed into keeps a core. Not
    /// the logical processors: two hyperthreads share one core's math units, so
    /// whisper's threads only fight over them (7 threads on a 4-core, 8-thread
    /// laptop). Without a core count, the logical count less one as before.
    /// </summary>
    public static int Threads(int logicalProcessors, int? physicalCores)
    {
        int cores = physicalCores is > 0 ? Math.Min(physicalCores.Value, logicalProcessors) : logicalProcessors;
        int threads = physicalCores is > 0 ? (cores > 4 ? cores - 1 : cores) : cores - 1;
        return Math.Clamp(threads, 1, 8);
    }

    /// <summary>How long a microphone that worked stays open after a hold, for the next one.</summary>
    public const int FastOpenKeepMs = 4000;
    public const int SlowOpenKeepMs = 120_000;
    /// <summary>A device that took this long to open is cold-start-slow (an array behind a driver, a Bluetooth headset).</summary>
    public const int SlowOpenMs = 250;
    /// <summary>An open this slow is a Bluetooth headset switching to its hands-free profile: kept open, it stays in that low-quality mode and the music it was playing stays degraded.</summary>
    public const int BluetoothLikeOpenMs = 1000;

    /// <summary>
    /// A microphone that opens in an instant is only kept for a few seconds;
    /// one that takes a quarter of a second or more (it took 300 to 717 ms on the
    /// PC this was fixed for, each hold losing the start of the first words)
    /// stays open for two minutes, so a pause between dictations does not
    /// cost the next one. The price is that Windows' "microphone in use"
    /// indicator stays lit for that long after each hold. An open of a second
    /// or more is left at the short window: that is a headset, and holding its
    /// microphone open keeps it in hands-free mode, which degrades its sound.
    /// </summary>
    public static int KeepOpenMs(long openMs) => openMs is >= SlowOpenMs and < BluetoothLikeOpenMs ? SlowOpenKeepMs : FastOpenKeepMs;
}

/// <summary>What the Settings page and the diagnostics say about the final pass on this PC.</summary>
public static class FinalPassText
{
    static string Seconds(double s) => s.ToString("F1", CultureInfo.InvariantCulture) + " s";

    /// <param name="action">What was decided for this PC.</param>
    /// <param name="smallSeconds">small.en's 1 s clip time, if measured.</param>
    /// <param name="largeSeconds">large-v3-turbo's, if measured.</param>
    /// <param name="running">The large server is up and in use.</param>
    /// <param name="downloaded">The model file is on disk.</param>
    public static string Describe(FinalPassAction action, double? smallSeconds, double? largeSeconds, bool running, bool downloaded)
    {
        string budget = Seconds(DevicePolicy.FinalPassBudgetSeconds);
        return action switch
        {
            FinalPassAction.Off => "Off",
            FinalPassAction.SkipKnownSlow when largeSeconds is { } l => $"Not used on this PC: a 1 s clip took {Seconds(l)} (budget {budget}). The final text comes from small.en.",
            FinalPassAction.SkipKnownSlow => $"Not used on this PC: an earlier test found it too slow (budget {budget}). The final text comes from small.en.",
            FinalPassAction.SkipPredictedSlow when smallSeconds is { } s =>
                $"Not used on this PC: small.en alone needs {Seconds(s)} for a 1 s clip, so this model would need about {Seconds(DevicePolicy.PredictedLargeSeconds(s))} (budget {budget})." + (downloaded ? "" : " Nothing is downloaded."),
            FinalPassAction.SkipPredictedSlow => $"Not used on this PC: too slow for the {budget} budget.",
            _ when running && largeSeconds is { } l => $"In use: a 1 s clip takes {Seconds(l)} on this PC.",
            _ when running => "In use.",
            _ when !downloaded => "Downloads 574 MB once, then is tested on this PC.",
            _ => "Starting...",
        };
    }
}

/// <summary>One thing measured on this PC.</summary>
/// <param name="Seconds">A 1 s clip's time on the device the engine runs on.</param>
/// <param name="CpuSeconds">The same clip on the CPU alone, when the GPU was compared against it.</param>
/// <param name="UseCpu">The CPU won clearly, so the engine runs on it.</param>
/// <param name="TooSlow">For the final-pass model: over the budget.</param>
public sealed record DeviceEntry(double? Seconds, double? CpuSeconds, bool? UseCpu, bool? TooSlow, DateTime At);

/// <summary>
/// What was measured on this PC, in device.json in the machine's own folder
/// (%LOCALAPPDATA%, never the roaming one), so a launch does not download,
/// start and time the models again. An entry belongs to one model, one engine
/// build and one device (<see cref="Key"/>), so a new engine, a different
/// GPU or a PC the folder was copied to measures afresh; and it expires.
/// </summary>
public sealed class DeviceStore
{
    readonly string _path;
    readonly Func<DateTime> _now;
    readonly object _lock = new();
    Dictionary<string, DeviceEntry> _entries = new();

    public DeviceStore(string path, Func<DateTime>? now = null)
    {
        _path = path;
        _now = now ?? (() => DateTime.UtcNow);
        Load();
    }

    /// <summary>"ggml-small.en.bin|engine 1234567@638...|Intel(R) Iris(R) Xe Graphics".</summary>
    public static string Key(string modelFile, string engine, string device) => $"{modelFile}|{engine}|{device}";

    public DeviceEntry? Get(string key)
    {
        lock (_lock)
            return _entries.TryGetValue(key, out var entry) && _now() - entry.At < DevicePolicy.MeasurementMaxAge ? entry : null;
    }

    public void Set(string key, DeviceEntry entry)
    {
        lock (_lock)
        {
            _entries[key] = entry;
            Save();
        }
    }

    /// <summary>Every current entry, newest first, for the diagnostics.</summary>
    public IReadOnlyList<(string Key, DeviceEntry Entry)> All()
    {
        lock (_lock)
            return _entries.Where(p => _now() - p.Value.At < DevicePolicy.MeasurementMaxAge)
                .OrderByDescending(p => p.Value.At).Select(p => (p.Key, p.Value)).ToList();
    }

    void Load()
    {
        try
        {
            if (File.Exists(_path) && JsonSerializer.Deserialize<Dictionary<string, DeviceEntry>>(File.ReadAllText(_path)) is { } loaded)
                _entries = loaded;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            _entries = new();
        }
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_entries, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A measurement that cannot be kept is made again next launch.
        }
    }
}
