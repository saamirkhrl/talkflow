namespace Talkflow.Core;

/// <summary>Where the app keeps whether <see cref="FinalPassDefault"/> has run (windows.json, never settings.json).</summary>
public interface IFinalPassDefaultFlag
{
    bool FinalPassOptInApplied { get; set; }
}

/// <summary>
/// 0.1.12 made the accurate final pass an opt-in on both apps (it keeps the ~800 MB large-v3-turbo model loaded).
/// On Windows the new default alone would reach only new installs: <see cref="SettingsStore.BackUp"/> writes every
/// shared key at its current value at each launch, so every install that ran an earlier version has
/// "accurateFinalPass": true in settings.json whether or not anyone chose it. So it is turned off once, on the first
/// launch of a version with this, and the flag keeps it from ever happening again: after that, turning it back on in
/// Settings sticks.
/// </summary>
public static class FinalPassDefault
{
    /// <summary>Runs once per install. Returns whether it turned the setting off.</summary>
    public static bool ApplyOnce(SettingsStore settings, IFinalPassDefaultFlag flag)
    {
        if (flag.FinalPassOptInApplied) return false;
        bool wasOn = settings.AccurateFinalPass;
        if (wasOn) settings.AccurateFinalPass = false;
        flag.FinalPassOptInApplied = true;
        return wasOn;
    }
}
