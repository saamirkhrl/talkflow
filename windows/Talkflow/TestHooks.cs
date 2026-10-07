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
///  - TALKFLOW_TEST_INJECTED_KEYS=1: the shortcut also reacts to key events
///    another program injected with SendInput, so a test can hold the keys
///    like a person. talkflow's own injected keystrokes are still ignored.
///  - TALKFLOW_TEST_MODEL=path.bin: small.en's server loads this model instead
///    (a test uses the much smaller tiny.en).
/// </summary>
static class TestHooks
{
    public static readonly string? AudioFile = Existing("TALKFLOW_TEST_AUDIO");
    public static readonly bool AcceptInjectedKeys = Environment.GetEnvironmentVariable("TALKFLOW_TEST_INJECTED_KEYS") == "1";
    public static readonly string? Model = Existing("TALKFLOW_TEST_MODEL");

    public static bool Any => AudioFile is not null || AcceptInjectedKeys || Model is not null;

    public static string Describe() =>
        $"test hooks on: audio={AudioFile ?? "-"}, injected keys={AcceptInjectedKeys}, model={Model ?? "-"}";

    static string? Existing(string variable) =>
        Environment.GetEnvironmentVariable(variable) is { Length: > 0 } path && File.Exists(path) ? Path.GetFullPath(path) : null;
}
