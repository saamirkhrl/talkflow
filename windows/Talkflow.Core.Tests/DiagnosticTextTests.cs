using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>A diagnostics file never carries dictated text.</summary>
public class DiagnosticTextTests
{
    [Fact]
    public void RedactsTranscriptsFromTheLog()
    {
        var log = "2026-10-06 10:00:00.000 recording started\n" +
                  "2026-10-06 10:00:03.000 transcribed 2 sentences in 0.82s: my bank password is hunter2\n" +
                  "2026-10-06 10:00:03.100 typed into notepad [-0 +31]";
        var redacted = DiagnosticText.Redact(log);
        Assert.DoesNotContain("hunter2", redacted);
        Assert.Contains("transcribed 2 sentences in 0.82s: [dictated text removed]", redacted);
        Assert.Contains("recording started", redacted);
        Assert.Contains("typed into notepad [-0 +31]", redacted);
        // Without transcripts the line is left as it is.
        Assert.Equal("x transcribed 1 sentence in 0.40s", DiagnosticText.Redact("x transcribed 1 sentence in 0.40s"));
    }

    [Fact]
    public void RedactsTranscriptsWrittenWithADecimalComma()
    {
        // A German or French Windows writes the time as 0,82s.
        var redacted = DiagnosticText.Redact("2026-10-06 10:00:03.000 transcribed 2 sentences in 0,82s: my bank password is hunter2");
        Assert.DoesNotContain("hunter2", redacted);
        Assert.Contains("in 0,82s: [dictated text removed]", redacted);
    }

    [Fact]
    public void KeepsOnlyTheEnginesOwnLines()
    {
        var log = "whisper_init_from_file_with_params_no_state: loading model from 'ggml-small.en.bin'\n" +
                  "load_backend: loaded CPU backend from ggml-cpu-haswell.dll\n" +
                  "system_info: n_threads = 7 / 8 | AVX = 1\n" +
                  "whisper server listening at http://127.0.0.1:8178\n" +
                  "Received request: audio.wav\n" +
                  " And so my fellow Americans, there was an error in the report.\n" +
                  "error: failed to open model\n";
        var kept = DiagnosticText.EngineLines(log);
        Assert.Contains("loading model", kept);
        Assert.Contains("ggml-cpu-haswell.dll", kept);
        Assert.Contains("system_info", kept);
        Assert.Contains("listening", kept);
        Assert.Contains("error: failed to open model", kept);
        Assert.DoesNotContain("fellow Americans", kept);
        Assert.Contains("(1 other lines omitted", kept);
    }

    static readonly DateTime When = new(2026, 10, 8, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void ReportsTheSpeedTestsAndTheFinalPassVerdict()
    {
        var text = DiagnosticText.DeviceLines(new[]
        {
            ("ggml-small.en.bin|engine 1@2|Intel(R) Iris(R) Xe Graphics", new DeviceEntry(1.29, 6.79, false, null, When)),
            ("ggml-large-v3-turbo-q5_0.bin|engine 1@2|Intel(R) Iris(R) Xe Graphics", new DeviceEntry(4.69, null, null, true, When)),
        });
        Assert.Contains("ggml-small.en.bin on Intel(R) Iris(R) Xe Graphics: a 1 s clip took 1.29 s, 6.79 s on the CPU; runs on the GPU", text);
        Assert.Contains("ggml-large-v3-turbo-q5_0.bin on Intel(R) Iris(R) Xe Graphics: a 1 s clip took 4.69 s, too slow (budget 2.00 s), so it is not used", text);
        Assert.Equal("  nothing measured yet", DiagnosticText.DeviceLines(Array.Empty<(string, DeviceEntry)>()));
    }

    [Fact]
    public void KeepsTheDecisionLinesAndNothingTyped()
    {
        var log = string.Join("\n",
            "2026-10-08 12:02:49.055 microphone opened in 717 ms: Microphone Array (WASAPI, device format 48000 Hz, 2 ch)",
            "2026-10-08 12:02:49.830 recording: 18 buffers, first after 631 ms, peak level 0.00, 0 ms of sound, 1200 ms of silence first",
            "2026-10-08 12:02:59.877 typed into talkflow [-0 +5]",
            "2026-10-08 12:03:19.991 pill: Hold the shortcut a moment longer, the microphone was still starting.",
            "2026-10-08 12:03:20.087 transcribed 5 chars / 1 words in 6.39s: [dictated text removed]",
            "2026-10-08 12:04:38.383 finish: stop recorder 262 ms, (total 3631 ms): too quiet to be speech");
        var kept = DiagnosticText.RecentDecisions(log);
        Assert.Contains("microphone opened in 717 ms", kept);
        Assert.Contains("0 ms of sound", kept);
        Assert.Contains("still starting", kept);
        Assert.Contains("too quiet to be speech", kept);
        Assert.DoesNotContain("typed into", kept);
        Assert.DoesNotContain("transcribed", kept);
        Assert.Equal(2, DiagnosticText.RecentDecisions(log, 2).Split('\n').Length);
    }
}
