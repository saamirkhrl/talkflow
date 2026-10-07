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
}
