using System.Net;
using System.Net.Sockets;
using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>The setup window's decisions and the download progress words.</summary>
public class SetupTests
{
    [Theory]
    [InlineData(false, SpeechPhase.Ready, SetupStage.Microphone)]
    [InlineData(false, SpeechPhase.Downloading, SetupStage.Microphone)]
    [InlineData(true, SpeechPhase.Downloading, SetupStage.Speech)]
    [InlineData(true, SpeechPhase.DownloadFailed, SetupStage.Speech)]
    [InlineData(true, SpeechPhase.Starting, SetupStage.Speech)]
    [InlineData(true, SpeechPhase.EngineFailed, SetupStage.Speech)]
    [InlineData(true, SpeechPhase.Ready, SetupStage.TryIt)]
    public void CurrentStepIsTheFirstUnfinishedOne(bool mic, SpeechPhase speech, SetupStage expected) =>
        Assert.Equal(expected, SetupFlow.Current(mic, speech));

    [Fact]
    public void SpeechPhaseFollowsTheDownloadThenTheServer()
    {
        // Arguments: installed, modelComplete, downloading, downloadFailed, ready, starting, engineFailed.
        Assert.Equal(SpeechPhase.EngineMissing, SetupFlow.Speech(false, true, false, false, true, false, false));
        Assert.Equal(SpeechPhase.Ready, SetupFlow.Speech(true, true, false, false, true, false, false));
        Assert.Equal(SpeechPhase.Downloading, SetupFlow.Speech(true, false, true, false, false, false, true));
        Assert.Equal(SpeechPhase.DownloadFailed, SetupFlow.Speech(true, false, false, true, false, false, true));
        // The engine's own "model missing" failure never hides the download starting.
        Assert.Equal(SpeechPhase.Preparing, SetupFlow.Speech(true, false, false, false, false, false, true));
        Assert.Equal(SpeechPhase.Starting, SetupFlow.Speech(true, true, false, false, false, true, false));
        Assert.Equal(SpeechPhase.EngineFailed, SetupFlow.Speech(true, true, false, false, false, false, true));
        // Model there, nothing started or failed yet: it is about to start.
        Assert.Equal(SpeechPhase.Starting, SetupFlow.Speech(true, true, false, false, false, false, false));
    }

    [Fact]
    public void DoneIsPrimaryOnlyAfterTryingIt()
    {
        Assert.Equal(("Finish later", false), SetupFlow.Footer(SetupStage.Microphone, false));
        Assert.Equal(("Finish later", false), SetupFlow.Footer(SetupStage.Speech, true));
        Assert.Equal(("Done", false), SetupFlow.Footer(SetupStage.TryIt, false));
        Assert.Equal(("Done", true), SetupFlow.Footer(SetupStage.TryIt, true));
    }

    [Fact]
    public void TryItWordsNameTheShortcut()
    {
        Assert.Equal("Hold Ctrl + Win and say something", SetupFlow.TryPrompt("Ctrl + Win"));
        Assert.Equal("That's it. Hold Ctrl + Win anywhere.", SetupFlow.TrySuccess("Ctrl + Win"));
    }

    [Fact]
    public void SizesUseTheTotalsUnit()
    {
        Assert.Equal("212 MB of 488 MB", DownloadText.Sizes(212_000_000, 487_601_967));
        Assert.Equal("0 MB of 488 MB", DownloadText.Sizes(0, 487_601_967));
        Assert.Equal("0.5 GB of 1.6 GB", DownloadText.Sizes(500_000_000, 1_600_000_000));
        Assert.Equal("12 MB downloaded", DownloadText.Sizes(12_000_000, null));
    }

    [Fact]
    public void PercentNeverReachesHundredBeforeTheEnd()
    {
        Assert.Equal(0, DownloadText.Percent(0, 1000));
        Assert.Equal(43, DownloadText.Percent(439, 1000));
        Assert.Equal(99, DownloadText.Percent(1000, 1000));
        Assert.Null(DownloadText.Percent(5, null));
        Assert.Null(DownloadText.Percent(5, 0));
    }

    [Theory]
    [InlineData(1, "a few seconds left")]
    [InlineData(23, "about 25 seconds left")]
    [InlineData(54, "about 55 seconds left")]
    [InlineData(57, "about 1 minute left")]
    [InlineData(100, "about 2 minutes left")]
    [InlineData(1500, "about 25 minutes left")]
    [InlineData(6000, "more than an hour left")]
    public void TimeLeftIsRounded(double seconds, string expected) => Assert.Equal(expected, DownloadText.TimeLeft(seconds));

    [Fact]
    public void ProgressLineIsHonestAboutTheTime()
    {
        // No measured speed yet: no made-up estimate.
        Assert.Equal("5 MB of 488 MB, working out the time left", DownloadText.Progress(5_000_000, 487_601_967, null));
        Assert.Equal("5 MB of 488 MB, working out the time left", DownloadText.Progress(5_000_000, 487_601_967, 0));
        Assert.Equal("40 MB of 488 MB, about 2 minutes left", DownloadText.Progress(40_000_000, 487_601_967, 4_000_000));
        Assert.Equal("12 MB downloaded", DownloadText.Progress(12_000_000, null, 4_000_000));
    }

    [Fact]
    public void MeterShowsNoTimeUntilItHasWarmedUp()
    {
        var meter = new DownloadMeter();
        meter.Report(0, 487_601_967, 0);
        meter.Report(2_000_000, 487_601_967, 0.5);
        meter.Report(4_000_000, 487_601_967, 1.0);
        Assert.Null(meter.BytesPerSecond);
        Assert.Contains("working out the time left", meter.Describe());
    }

    [Fact]
    public void MeterSettlesOnTheSteadySpeed()
    {
        var meter = new DownloadMeter();
        const long total = 487_601_967;
        for (int i = 0; i <= 50; i++) meter.Report(i * 800_000L, total, i * 0.2); // 4 MB/s for 10 s
        Assert.InRange(meter.BytesPerSecond ?? 0, 3_900_000, 4_100_000);
        Assert.Equal(8, meter.Percent);
        Assert.Equal("40 MB of 488 MB, about 2 minutes left", meter.Describe());
    }

    [Fact]
    public void MeterFollowsASpeedChangeWithoutJumping()
    {
        var meter = new DownloadMeter();
        long written = 0;
        double t = 0;
        for (; t <= 10; t += 0.5) { meter.Report(written, 400_000_000, t); written += 2_000_000; } // 4 MB/s
        var before = meter.BytesPerSecond!.Value;
        for (; t <= 12; t += 0.5) { meter.Report(written, 400_000_000, t); written += 1_000_000; } // 2 MB/s
        var after = meter.BytesPerSecond!.Value;
        Assert.True(after < before && after > 2_000_000, $"{before} then {after}");
    }

    [Fact]
    public void ResetStartsOver()
    {
        var meter = new DownloadMeter();
        meter.Report(0, 100, 0);
        meter.Report(50, 100, 4);
        meter.Reset();
        Assert.Equal(0, meter.Written);
        Assert.Null(meter.Total);
        Assert.Null(meter.BytesPerSecond);
    }

    [Fact]
    public void FailuresReadAsSentences()
    {
        Assert.Contains("internet connection", DownloadText.Failure(new HttpRequestException("No such host is known.")));
        Assert.Contains("internet connection", DownloadText.Failure(new IOException("reset", new SocketException())));
        Assert.Contains("stalled", DownloadText.Failure(new TaskCanceledException()));
        Assert.Contains("disk space", DownloadText.Failure(new IOException("full") { HResult = unchecked((int)0x80070070) }));
        Assert.Contains("models folder", DownloadText.Failure(new UnauthorizedAccessException()));
        // A server error already carries its own words.
        Assert.Equal("The download server answered HTTP 503.", DownloadText.Failure(new IOException("The download server answered HTTP 503.")));
        Assert.Equal("boom", DownloadText.Failure(new InvalidOperationException("boom")));
        // An HTTP error status is a server answer, not a missing connection.
        Assert.Equal("Response status code does not indicate success: 404 (Not Found).",
            DownloadText.Failure(new HttpRequestException("Response status code does not indicate success: 404 (Not Found).", null, HttpStatusCode.NotFound)));
    }
}
