namespace Talkflow.Core;

/// <summary>What became of one hold of the shortcut, decided before anything is sent to the speech engine.</summary>
public enum HoldOutcome
{
    /// <summary>Let go within <see cref="HoldCheck.MinHoldSeconds"/>: an accidental tap, dropped without a word.</summary>
    TooShort,
    /// <summary>Let go before the microphone delivered anything, and sooner than <see cref="HoldCheck.DeadMs"/>: it was still starting.</summary>
    StillStarting,
    /// <summary>Held for <see cref="HoldCheck.DeadMs"/> or more and the microphone delivered nothing at all.</summary>
    NoAudio,
    /// <summary>Audio arrived but every sample was exactly zero for a long stretch: muted, or blocked by Windows.</summary>
    Muted,
    /// <summary>Audio arrived and none of it was loud enough to be speech.</summary>
    NoSpeech,
    /// <summary>There is speech: send it to the engine.</summary>
    Speech,
}

/// <summary>
/// The words and the decision for a hold that ended without a transcript, kept
/// apart from the recorder and the UI so each case is tested. The old check
/// sent every non-zero clip to whisper and blamed Sound settings whenever
/// nothing arrived, even for a hold that ended while the microphone was still
/// opening.
/// </summary>
public static class HoldCheck
{
    /// <summary>A shorter hold is an accidental tap.</summary>
    public const double MinHoldSeconds = 0.3;
    /// <summary>A microphone open (or opening) this long without a single buffer is given up on.</summary>
    public const int DeadMs = 1500;
    /// <summary>All-zero audio is called "muted" only past this length: a cold microphone can start with a short run of exact zeros.</summary>
    public const double MutedSeconds = 2.0;

    /// <param name="HoldSeconds">From the press to the release.</param>
    /// <param name="Buffers">How many buffers the microphone delivered during the hold and its tail.</param>
    /// <param name="AudioSeconds">How much audio they add up to.</param>
    /// <param name="Sound">What the samples hold (see <see cref="SpeechGate"/>).</param>
    public readonly record struct Facts(double HoldSeconds, int Buffers, double AudioSeconds, SpeechGate.Analysis Sound);

    public static HoldOutcome Classify(Facts hold)
    {
        if (hold.HoldSeconds < MinHoldSeconds) return HoldOutcome.TooShort;
        if (hold.Buffers == 0)
            return hold.HoldSeconds * 1000 >= DeadMs ? HoldOutcome.NoAudio : HoldOutcome.StillStarting;
        if (hold.Sound.AllZero && hold.AudioSeconds >= MutedSeconds) return HoldOutcome.Muted;
        return hold.Sound.HasSpeech ? HoldOutcome.Speech : HoldOutcome.NoSpeech;
    }

    /// <summary>
    /// The pill's words for an outcome that ends the hold, or null when there
    /// is nothing to say (a tap) or the audio goes on to the engine.
    /// <paramref name="device"/> is the microphone's name, null while it was never opened.
    /// </summary>
    public static string? Message(HoldOutcome outcome, string? device)
    {
        string microphone = device ?? "the microphone";
        return outcome switch
        {
            HoldOutcome.StillStarting => "Hold the shortcut a moment longer, the microphone was still starting.",
            HoldOutcome.NoAudio => $"No sound came from {microphone}. Check Settings > System > Sound > Input.",
            HoldOutcome.Muted => $"{microphone} sent only silence. It may be muted, or blocked in Privacy & security > Microphone.",
            HoldOutcome.NoSpeech => "Didn't catch that",
            _ => null,
        };
    }

    /// <summary>Whether the pill shows the message as an error (red) or as a plain notice: only a microphone that is broken or blocked is an error.</summary>
    public static bool IsError(HoldOutcome outcome) => outcome is HoldOutcome.NoAudio or HoldOutcome.Muted;
}
