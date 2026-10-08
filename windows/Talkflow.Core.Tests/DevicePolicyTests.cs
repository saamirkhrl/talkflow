using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>
/// What the engine does on a slow PC, with the numbers from the real one: an
/// Intel Iris Xe laptop (4 cores, 8 logical processors) where small.en took
/// 1.29 s for a 1 s clip on the GPU and 6.79 s on the CPU, and large-v3-turbo
/// took 4.69 s (budget 2.0 s).
/// </summary>
public class DevicePolicyTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "talkflow-tests-" + Guid.NewGuid().ToString("N"));

    public DevicePolicyTests() => Directory.CreateDirectory(_dir);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    static readonly DateTime Now = new(2026, 10, 8, 12, 0, 0, DateTimeKind.Utc);

    static DeviceEntry Verdict(bool tooSlow, double seconds = 1) => new(seconds, null, null, tooSlow, Now);

    // MARK: - The final pass

    [Fact]
    public void TheLogsPcNeverDownloadsTheLargeModel()
    {
        // small.en 1.29 s: even at the floor ratio large-v3-turbo needs 3.2 s, over the 2.0 s budget.
        Assert.Equal(FinalPassAction.SkipPredictedSlow, DevicePolicy.DecideFinalPass(true, null, 1.29));
        Assert.True(DevicePolicy.PredictedLargeSeconds(1.29) > DevicePolicy.FinalPassBudgetSeconds);
        // What was measured (4.69 s) is above the floor, so the floor never skips a PC that could pass.
        Assert.True(DevicePolicy.PredictedLargeSeconds(1.29) < 4.69);
    }

    [Theory]
    [InlineData(0.05, FinalPassAction.StartAndMeasure)]  // a good GPU
    [InlineData(0.5, FinalPassAction.StartAndMeasure)]
    [InlineData(0.8, FinalPassAction.StartAndMeasure)]   // 2.0 s predicted: exactly the budget, not over it
    [InlineData(0.81, FinalPassAction.SkipPredictedSlow)]
    [InlineData(6.79, FinalPassAction.SkipPredictedSlow)] // the same PC's CPU
    public void ThePredictionCutoffComesFromTheBudgetAndTheRatio(double small, FinalPassAction expected) =>
        Assert.Equal(expected, DevicePolicy.DecideFinalPass(true, null, small));

    [Fact]
    public void UnknownSpeedStillMeasures() =>
        Assert.Equal(FinalPassAction.StartAndMeasure, DevicePolicy.DecideFinalPass(true, null, null));

    [Fact]
    public void ASettingThatIsOffDoesNothing()
    {
        Assert.Equal(FinalPassAction.Off, DevicePolicy.DecideFinalPass(false, null, 0.05));
        Assert.Equal(FinalPassAction.Off, DevicePolicy.DecideFinalPass(false, Verdict(tooSlow: true), 5));
    }

    [Fact]
    public void AnEarlierVerdictIsNotMeasuredAgain()
    {
        Assert.Equal(FinalPassAction.SkipKnownSlow, DevicePolicy.DecideFinalPass(true, Verdict(tooSlow: true, 4.69), 0.05));
        Assert.Equal(FinalPassAction.StartTrusted, DevicePolicy.DecideFinalPass(true, Verdict(tooSlow: false, 0.13), 0.05));
        // A fast verdict was measured, so it wins over a slow small.en reading.
        Assert.Equal(FinalPassAction.StartTrusted, DevicePolicy.DecideFinalPass(true, Verdict(tooSlow: false, 0.13), 3));
    }

    [Fact]
    public void TheSettingsPageSaysWhatHappened()
    {
        var predicted = FinalPassText.Describe(FinalPassAction.SkipPredictedSlow, 1.29, null, running: false, downloaded: false);
        Assert.Contains("1.3 s", predicted);
        Assert.Contains("Nothing is downloaded", predicted);
        Assert.Contains("Not used on this PC", FinalPassText.Describe(FinalPassAction.SkipKnownSlow, 1.29, 4.69, false, true));
        Assert.Contains("4.7 s", FinalPassText.Describe(FinalPassAction.SkipKnownSlow, 1.29, 4.69, false, true));
        Assert.Equal("In use: a 1 s clip takes 0.1 s on this PC.", FinalPassText.Describe(FinalPassAction.StartAndMeasure, 0.05, 0.13, running: true, downloaded: true));
        Assert.StartsWith("Downloads 574 MB once", FinalPassText.Describe(FinalPassAction.StartAndMeasure, null, null, false, false));
    }

    // MARK: - Previews and threads

    [Theory]
    [InlineData(0.1, true)]
    [InlineData(0.99, true)]
    [InlineData(1.0, false)]
    [InlineData(1.29, false)]  // the log's GPU
    [InlineData(6.79, false)]  // the log's CPU
    public void SlowPcsGetNoLivePreviews(double small, bool previews) =>
        Assert.Equal(previews, DevicePolicy.LivePreviews(small));

    [Fact]
    public void AnUnmeasuredPcKeepsItsPreviews() => Assert.True(DevicePolicy.LivePreviews(null));

    [Theory]
    [InlineData(8, 4, 4)]    // the log's laptop: 4 cores, 8 logical processors (was 7)
    [InlineData(4, 2, 2)]    // a 2-core, 4-thread CI runner (was 3)
    [InlineData(12, 6, 5)]   // leaves a core for the app being typed into
    [InlineData(16, 8, 7)]
    [InlineData(32, 16, 8)]  // capped
    [InlineData(4, 4, 4)]    // no hyperthreading (Windows on Arm)
    [InlineData(2, 1, 1)]
    public void ThreadsFollowThePhysicalCores(int logical, int cores, int expected) =>
        Assert.Equal(expected, DevicePolicy.Threads(logical, cores));

    [Theory]
    [InlineData(8, 7)]
    [InlineData(2, 1)]
    [InlineData(1, 1)]
    [InlineData(32, 8)]
    public void WithoutACoreCountItIsAsBefore(int logical, int expected) =>
        Assert.Equal(expected, DevicePolicy.Threads(logical, null));

    [Fact]
    public void ANonsenseCoreCountIsIgnored()
    {
        Assert.Equal(7, DevicePolicy.Threads(8, 0));
        Assert.Equal(7, DevicePolicy.Threads(8, 99)); // more cores than logical processors cannot be: capped at them
    }

    // MARK: - Keeping the microphone open

    [Theory]
    [InlineData(5, 4000)]
    [InlineData(249, 4000)]
    [InlineData(250, 120_000)]
    [InlineData(305, 120_000)]   // the log's fastest SST open
    [InlineData(717, 120_000)]   // its slowest
    [InlineData(999, 120_000)]
    [InlineData(1000, 4000)]     // a Bluetooth headset: never held in hands-free mode
    [InlineData(1500, 4000)]
    public void ASlowToOpenMicrophoneStaysOpenLonger(long openMs, int keepMs) =>
        Assert.Equal(keepMs, DevicePolicy.KeepOpenMs(openMs));

    [Fact]
    public void TheLongKeepOpenOutlastsThePausesInTheLog()
    {
        // The friend paused 73 s and 40 s between dictations; the old 4 s window missed all of them.
        Assert.True(DevicePolicy.SlowOpenKeepMs > 73_000);
        Assert.True(DevicePolicy.FastOpenKeepMs < 73_000);
    }

    // MARK: - The per-PC store

    [Fact]
    public void AVerdictIsKeyedOnModelEngineAndDevice()
    {
        var path = Path.Combine(_dir, "device.json");
        var store = new DeviceStore(path, () => Now);
        var key = DeviceStore.Key("ggml-large-v3-turbo-q5_0.bin", "engine 1@2", "Intel(R) Iris(R) Xe Graphics");
        store.Set(key, Verdict(tooSlow: true, 4.69));

        var again = new DeviceStore(path, () => Now.AddDays(1)); // a later launch
        Assert.True(again.Get(key)?.TooSlow);
        Assert.Equal(4.69, again.Get(key)?.Seconds);
        Assert.Null(again.Get(DeviceStore.Key("ggml-large-v3-turbo-q5_0.bin", "engine 1@3", "Intel(R) Iris(R) Xe Graphics"))); // a new engine
        Assert.Null(again.Get(DeviceStore.Key("ggml-large-v3-turbo-q5_0.bin", "engine 1@2", "NVIDIA GeForce RTX 4070")));      // another GPU
        Assert.Null(again.Get(DeviceStore.Key("ggml-small.en.bin", "engine 1@2", "Intel(R) Iris(R) Xe Graphics")));            // another model
    }

    [Fact]
    public void AMeasurementExpires()
    {
        var path = Path.Combine(_dir, "device.json");
        new DeviceStore(path, () => Now).Set("k", Verdict(true));
        Assert.NotNull(new DeviceStore(path, () => Now.AddDays(29)).Get("k"));
        Assert.Null(new DeviceStore(path, () => Now.AddDays(31)).Get("k"));
        Assert.Empty(new DeviceStore(path, () => Now.AddDays(31)).All());
    }

    [Fact]
    public void ACorruptFileIsJustEmpty()
    {
        var path = Path.Combine(_dir, "device.json");
        File.WriteAllText(path, "{ not json");
        var store = new DeviceStore(path, () => Now);
        Assert.Null(store.Get("k"));
        store.Set("k", Verdict(false));
        Assert.NotNull(new DeviceStore(path, () => Now).Get("k"));
    }

    [Fact]
    public void TheSmallModelBenchmarkIsKept()
    {
        var path = Path.Combine(_dir, "device.json");
        var key = DeviceStore.Key("ggml-small.en.bin", "e", "Intel(R) Iris(R) Xe Graphics");
        new DeviceStore(path, () => Now).Set(key, new DeviceEntry(1.29, 6.79, false, null, Now));
        var entry = new DeviceStore(path, () => Now).Get(key)!;
        Assert.Equal((1.29, 6.79, false), (entry.Seconds, entry.CpuSeconds, entry.UseCpu));
    }
}
