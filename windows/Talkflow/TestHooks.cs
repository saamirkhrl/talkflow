using System;
using System.IO;

namespace Talkflow;

/// <summary>
/// Switches for the end-to-end test (windows/tests/e2e.ps1), read once from
/// environment variables. Each one is off unless its variable is set, so a
/// normal launch behaves exactly as before; when any is on, the log says so.
///
///  - TALKFLOW_TEST_AUDIO=path.wav: the recorder plays this 16 kHz mono WAV in
///    real time instead of opening the microphone (CI machines have none).
///  - TALKFLOW_TEST_SILENT_MIC=1: the recorder "opens" a microphone that never
///    delivers a buffer, as one real USB microphone did. Wins over the WAV.
///  - TALKFLOW_TEST_HANGING_MIC=1: the first microphone opened sends nothing
///    and then never finishes closing, as one real USB microphone did; every
///    later one plays the WAV.
///  - TALKFLOW_TEST_SLOW_MIC=700: with the WAV, a microphone that takes this
///    many milliseconds to open and then sends ColdSilenceMs of near-silence
///    before the recording, as an Intel Smart Sound array did.
///  - TALKFLOW_TEST_SLOW_ENGINE=1500: every request to the speech engine takes
///    this many milliseconds longer, as on a slow PC (the speed tests see it too).
///  - TALKFLOW_TEST_INJECTED_KEYS=1: the shortcut also reacts to key events
///    another program injected with SendInput, so a test can hold the keys
///    like a person. talkflow's own injected keystrokes are still ignored.
///  - TALKFLOW_TEST_MODEL=path.bin: small.en's server loads this model instead
///    (a test uses the much smaller tiny.en).
/// </summary>
static class TestHooks
{
    public static readonly string? AudioFile = Existing("TALKFLOW_TEST_AUDIO");
    public static readonly bool SilentMicrophone = Environment.GetEnvironmentVariable("TALKFLOW_TEST_SILENT_MIC") == "1";
    public static readonly bool HangingMicrophone = Environment.GetEnvironmentVariable("TALKFLOW_TEST_HANGING_MIC") == "1";
    public static readonly int SlowMicrophoneMs = Milliseconds("TALKFLOW_TEST_SLOW_MIC");
    public static readonly int SlowEngineMs = Milliseconds("TALKFLOW_TEST_SLOW_ENGINE");
    /// <summary>Near-silence a slow test microphone sends after it opens.</summary>
    public const int ColdSilenceMs = 300;
    public static readonly bool AcceptInjectedKeys = Environment.GetEnvironmentVariable("TALKFLOW_TEST_INJECTED_KEYS") == "1";
    public static readonly string? Model = Existing("TALKFLOW_TEST_MODEL");

    public static bool Any => AudioFile is not null || SilentMicrophone || HangingMicrophone || AcceptInjectedKeys || Model is not null
        || SlowMicrophoneMs > 0 || SlowEngineMs > 0;

    public static string Describe() =>
        $"test hooks on: audio={AudioFile ?? "-"}, silent microphone={SilentMicrophone}, hanging microphone={HangingMicrophone}, slow microphone={SlowMicrophoneMs} ms, slow engine={SlowEngineMs} ms, injected keys={AcceptInjectedKeys}, model={Model ?? "-"}";

    /// <summary>
    /// Added to what is measured on this PC, so a test run never reads
    /// another run's saved speed tests (device.json) and a slow-engine run
    /// never leaves its numbers behind for a real one.
    /// </summary>
    public static string MeasurementTag => SlowEngineMs > 0 || Model is not null ? $" (test: model {(Model is null ? "-" : Path.GetFileName(Model))}, slow engine {SlowEngineMs} ms)" : "";

    static int Milliseconds(string variable) =>
        int.TryParse(Environment.GetEnvironmentVariable(variable), out int ms) && ms > 0 ? ms : 0;

    static string? Existing(string variable) =>
        Environment.GetEnvironmentVariable(variable) is { Length: > 0 } path && File.Exists(path) ? Path.GetFullPath(path) : null;
}
