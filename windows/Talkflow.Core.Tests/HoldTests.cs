using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>
/// The speech gate and the hold classification, with the levels from a real
/// Windows PC's diagnostics (Intel Smart Sound Technology array). The
/// recorder's "level" in talkflow.log is a buffer's RMS times 8, so a level L
/// is an RMS of L / 8.
/// </summary>
public class HoldTests
{
    const int Rate = SpeechGate.SampleRate;

    static short[] Silence(int ms) => new short[ms * Rate / 1000];

    /// <summary>Steady noise at an RMS (full scale = 1), the same every run.</summary>
    static short[] Noise(double rms, int ms, int seed = 1)
    {
        var random = new Random(seed);
        var samples = new short[ms * Rate / 1000];
        for (int i = 0; i < samples.Length; i++)
        {
            double gaussian = Math.Sqrt(-2 * Math.Log(1 - random.NextDouble())) * Math.Cos(2 * Math.PI * random.NextDouble());
            samples[i] = (short)Math.Clamp(gaussian * rms * 32768, -32768, 32767);
        }
        return samples;
    }

    /// <summary>A voiced stretch: a 200 Hz tone at an RMS, as loud as the log's buffer level says.</summary>
    static short[] Tone(double rms, int ms)
    {
        var samples = new short[ms * Rate / 1000];
        for (int i = 0; i < samples.Length; i++)
            samples[i] = (short)(Math.Sin(2 * Math.PI * 200 * i / Rate) * rms * Math.Sqrt(2) * 32768);
        return samples;
    }

    static short[] Join(params short[][] parts) => parts.SelectMany(p => p).ToArray();

    static double LevelToRms(double level) => level / 8;

    static SpeechGate.Analysis Analyze(short[] samples) => SpeechGate.Analyze(samples);

    // MARK: - The gate, with the log's levels

    [Theory]
    [InlineData(0.00)]   // cold-open silence: "peak level 0.00" (shown rounded, so up to 0.005)
    [InlineData(0.004)]
    public void ColdOpenSilenceIsNotSpeech(double level)
    {
        // The two holds that cost 5.3 s and 3.4 s in the log: 18 and 11 buffers of silence.
        Assert.False(Analyze(Noise(LevelToRms(level), 1200)).HasSpeech);
        Assert.False(Analyze(Noise(LevelToRms(level), 900)).HasSpeech);
        Assert.False(Analyze(Silence(1200)).HasSpeech);
    }

    [Fact]
    public void TheDiagnosticsIdleTestIsNotSpeech()
    {
        // "one second ... waveIn: peak 0.003" is a sample peak: steady noise whose largest sample is 0.003.
        Assert.False(Analyze(Noise(0.003 / 4, 1000)).HasSpeech);
        // "WASAPI: peak 0.018" came from the first buffers of a cold open: a short burst, then nothing.
        var burst = Join(Silence(200), Noise(0.018 / 3, 40), Silence(760));
        Assert.False(Analyze(burst).HasSpeech);
    }

    [Theory]
    [InlineData(0.20)]
    [InlineData(0.21)]
    [InlineData(0.31)]
    [InlineData(0.32)]
    [InlineData(0.38)]
    [InlineData(0.53)]
    [InlineData(0.54)]
    public void TheLogsSpeechPeaksAreSpeech(double level)
    {
        // Half a second of voiced sound at the buffer level, in a hold that is otherwise quiet.
        var hold = Join(Silence(400), Tone(LevelToRms(level), 500), Noise(0.0003, 500));
        Assert.True(Analyze(hold).HasSpeech);
    }

    [Fact]
    public void AQuietOneWordHoldStillPasses()
    {
        // The 0.5 s hold that was transcribed as one word peaked at level 0.05 (RMS 0.006).
        Assert.True(Analyze(Join(Noise(0.0003, 150), Tone(LevelToRms(0.05), 250), Noise(0.0003, 100))).HasSpeech);
    }

    [Fact]
    public void QuietAndFarFieldSpeakersPass()
    {
        // Half the quietest speech seen, and a far-field laptop microphone at about -48 dBFS.
        Assert.True(Analyze(Tone(0.003, 300)).HasSpeech);
        Assert.True(Analyze(Join(Noise(0.001, 300), Tone(0.004, 400), Noise(0.001, 300))).HasSpeech);
    }

    [Fact]
    public void AThumpIsNotSpeech()
    {
        // The loudest possible single frame is not a word: it takes a stretch of sound.
        var thump = Join(Silence(500), Tone(0.5, 20), Silence(500));
        var result = Analyze(thump);
        Assert.False(result.HasSpeech);
        Assert.True(result.LoudestRms > 0.4);
    }

    [Fact]
    public void ABufferSizeDoesNotMatter()
    {
        // The decision reads the samples, not the microphone's buffers: the same sound split any way is the same.
        var hold = Join(Silence(300), Tone(0.03, 200));
        Assert.Equal(Analyze(hold), SpeechGate.Analyze(hold.AsSpan()));
    }

    // MARK: - Trimming the cold start

    [Fact]
    public void ALongColdStartIsTrimmedToTheLeadIn()
    {
        var speech = Tone(0.03, 500);
        var hold = Join(Noise(0.0003, 700), speech);
        var kept = SpeechGate.TrimLeading(hold, Analyze(hold));
        Assert.Equal(SpeechGate.LeadInMs * Rate / 1000 + speech.Length, kept.Length);
        Assert.True(Analyze(kept.ToArray()).HasSpeech);
    }

    [Fact]
    public void AShortLeadInIsLeftAlone()
    {
        var hold = Join(Silence(250), Tone(0.03, 500));
        Assert.Equal(hold.Length, SpeechGate.TrimLeading(hold, Analyze(hold)).Length);
    }

    [Fact]
    public void NothingIsTrimmedWhenThereIsNoSound()
    {
        var quiet = Noise(0.0003, 2000);
        Assert.Equal(quiet.Length, SpeechGate.TrimLeading(quiet, Analyze(quiet)).Length);
    }

    // MARK: - What became of the hold

    static HoldCheck.Facts Hold(double seconds, int buffers, short[] samples) =>
        new(seconds, buffers, samples.Length / (double)Rate, Analyze(samples));

    [Fact]
    public void ATapIsDroppedWhateverArrived()
    {
        Assert.Equal(HoldOutcome.TooShort, HoldCheck.Classify(Hold(0.12, 8, Tone(0.03, 300))));
        Assert.Equal(HoldOutcome.TooShort, HoldCheck.Classify(Hold(0.22, 0, [])));
    }

    [Fact]
    public void ReleasedBeforeTheMicrophoneOpenedIsStillStarting()
    {
        // 12:03:19 in the log: held 0.4 s, the device finished opening 0.5 s after the press. The microphone was fine.
        var outcome = HoldCheck.Classify(Hold(0.4, 0, []));
        Assert.Equal(HoldOutcome.StillStarting, outcome);
        Assert.False(HoldCheck.IsError(outcome));
        Assert.DoesNotContain("Sound", HoldCheck.Message(outcome, null));
        Assert.Contains("moment longer", HoldCheck.Message(outcome, null));
    }

    [Fact]
    public void StillStartingEndsWhereTheDeadLineBegins()
    {
        Assert.Equal(HoldOutcome.StillStarting, HoldCheck.Classify(Hold(1.49, 0, [])));
        Assert.Equal(HoldOutcome.NoAudio, HoldCheck.Classify(Hold(1.5, 0, [])));
    }

    [Fact]
    public void ANeverOpenedMicrophoneSendsYouToSoundSettings()
    {
        // A USB microphone that opens and never sends a buffer (the e2e test's silent microphone, held 2.5 s).
        var outcome = HoldCheck.Classify(Hold(2.5, 0, []));
        Assert.Equal(HoldOutcome.NoAudio, outcome);
        Assert.True(HoldCheck.IsError(outcome));
        Assert.Equal("No sound came from the microphone. Check Settings > System > Sound > Input.", HoldCheck.Message(outcome, null));
        Assert.StartsWith("No sound came from Microphone Array", HoldCheck.Message(outcome, "Microphone Array"));
    }

    [Fact]
    public void AnOpenButSilentMicrophoneIsFriendlyNotAnError()
    {
        // 12:02:48 and 12:04:33 in the log: tiny, nonzero samples that went to whisper and cost 5.3 s and 3.4 s.
        foreach (var hold in new[] { Hold(1.0, 18, Noise(0.0003, 1200)), Hold(0.6, 11, Noise(0.0003, 900)) })
        {
            var outcome = HoldCheck.Classify(hold);
            Assert.Equal(HoldOutcome.NoSpeech, outcome);
            Assert.False(HoldCheck.IsError(outcome));
            Assert.Equal("Didn't catch that", HoldCheck.Message(outcome, "x"));
        }
    }

    [Fact]
    public void LongExactSilenceIsAMutedMicrophone()
    {
        Assert.Equal(HoldOutcome.Muted, HoldCheck.Classify(Hold(3, 30, Silence(3000))));
        // The first buffers of a cold open can be exact zeros: a short run says nothing.
        Assert.Equal(HoldOutcome.NoSpeech, HoldCheck.Classify(Hold(1, 10, Silence(1200))));
        Assert.True(HoldCheck.IsError(HoldOutcome.Muted));
    }

    [Fact]
    public void RealSpeechGoesToTheEngine()
    {
        Assert.Equal(HoldOutcome.Speech, HoldCheck.Classify(Hold(2.3, 50, Join(Noise(0.0003, 500), Tone(0.04, 1500)))));
        Assert.Null(HoldCheck.Message(HoldOutcome.Speech, "x"));
        Assert.Null(HoldCheck.Message(HoldOutcome.TooShort, "x"));
    }

    [Fact]
    public void ColdStartSpeechIsTrimmedButStillSpeech()
    {
        // A 700 ms cold open (near-zero samples), then a sentence: it is speech, with its lead-in cut.
        var hold = Join(Noise(0.0003, 700), Tone(0.04, 1500));
        var sound = Analyze(hold);
        Assert.Equal(HoldOutcome.Speech, HoldCheck.Classify(new HoldCheck.Facts(2.4, 40, 2.2, sound)));
        Assert.InRange(sound.LeadSilenceMs, 680, 720);
    }
}
