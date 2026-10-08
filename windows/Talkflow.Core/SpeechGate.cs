namespace Talkflow.Core;

/// <summary>
/// Decides from a recording's samples whether it holds any speech, so a hold
/// of silence never reaches the speech engine (whisper always encodes a full
/// 30 s window, so even an empty clip costs 3 to 5 s on a slow PC). Pure
/// functions over 16 kHz mono 16-bit samples; the recorder calls them.
///
/// The decision is made from frame energy, not from a single peak: a clip
/// counts as speech when at least <see cref="MinVoicedMs"/> of it is made of
/// 20 ms frames whose RMS is at least <see cref="VoicedRms"/>. A thump or a
/// click is one or two loud frames and does not pass; a quiet word is a few
/// dozen frames and does.
///
/// Calibrated against a real Windows PC (Intel Smart Sound Technology array).
/// The recorder's level is a buffer's RMS times 8 (Recorder.OnSamples), and in
/// that log: cold-open silence read 0.00 (RMS below 0.0006), a quiet one-word
/// hold that was transcribed peaked at 0.05 (RMS 0.006), and ordinary speech
/// peaked at 0.2 to 0.54 (RMS 0.025 to 0.07). The threshold sits between
/// silence and the quietest speech seen, closer to the silence, because the
/// two mistakes are not equal: letting a silent clip through costs seconds,
/// dropping a quiet speaker loses their words. A noisy far-field microphone
/// whose floor is above the threshold is simply sent to the engine, as before.
/// </summary>
public static class SpeechGate
{
    public const int SampleRate = 16000;
    const int FrameMs = 20;
    const int FrameSamples = SampleRate * FrameMs / 1000;

    /// <summary>A frame at or above this RMS (0..1 of full scale, about -54 dBFS) counts as sound.</summary>
    public const double VoicedRms = 0.002;
    /// <summary>Sound-level frames needed, in total, for a clip to count as speech.</summary>
    public const int MinVoicedMs = 80;
    /// <summary>Silence kept in front of the first sound when a cold start's lead-in is trimmed.</summary>
    public const int LeadInMs = 200;
    /// <summary>Lead-in shorter than this is left alone: nothing to gain.</summary>
    public const int MinTrimMs = 300;

    /// <summary>What a recording holds: how much of it is sound-level, how loud its loudest frame is, how long it starts silent.</summary>
    public readonly record struct Analysis(int VoicedMs, double LoudestRms, int LeadSilenceMs, bool AllZero)
    {
        public bool HasSpeech => VoicedMs >= MinVoicedMs;
    }

    public static Analysis Analyze(ReadOnlySpan<short> samples)
    {
        int voiced = 0, firstVoiced = -1;
        double loudest = 0;
        bool allZero = true;
        for (int at = 0; at < samples.Length; at += FrameSamples)
        {
            var frame = samples.Slice(at, Math.Min(FrameSamples, samples.Length - at));
            double sum = 0;
            foreach (short s in frame)
            {
                if (s != 0) allZero = false;
                double f = s / 32768.0;
                sum += f * f;
            }
            double rms = Math.Sqrt(sum / frame.Length);
            loudest = Math.Max(loudest, rms);
            if (rms < VoicedRms) continue;
            voiced++;
            if (firstVoiced < 0) firstVoiced = at;
        }
        int lead = firstVoiced < 0 ? samples.Length * 1000 / SampleRate : firstVoiced * 1000 / SampleRate;
        return new Analysis(voiced * FrameMs, loudest, lead, allZero);
    }

    /// <summary>
    /// Drops the near-silence in front of the first sound, keeping
    /// <see cref="LeadInMs"/> of it: a cold microphone delivers a few hundred
    /// milliseconds of nothing first, which only invites whisper to invent
    /// words. Returns the samples unchanged when there is no sound at all (the
    /// gate decides that case) or the lead-in is short.
    /// </summary>
    public static ReadOnlySpan<short> TrimLeading(ReadOnlySpan<short> samples, Analysis analysis)
    {
        if (analysis.VoicedMs == 0 || analysis.LeadSilenceMs <= MinTrimMs) return samples;
        int start = (analysis.LeadSilenceMs - LeadInMs) * SampleRate / 1000;
        return samples[Math.Min(start, samples.Length)..];
    }
}
