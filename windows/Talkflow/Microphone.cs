using System;
using Microsoft.Win32;
using NAudio.Wave;

namespace Talkflow;

/// <summary>
/// Whether Windows lets talkflow use the microphone. Windows has no prompt for
/// desktop apps: Settings > Privacy & security > Microphone either allows them
/// or silently hands them silence. Those switches live in the registry, so they
/// are read directly and the user is sent to the right page when one is off.
/// </summary>
static class Microphone
{
    public enum State { Allowed, BlockedForUser, BlockedForDesktopApps, BlockedForDevice, NoDevice }

    const string Consent = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public static State Check()
    {
        if (TestHooks.AudioFile is not null || TestHooks.SilentMicrophone) return State.Allowed; // the test stands in for the device
        if (Read(Registry.LocalMachine, Consent) == "Deny") return State.BlockedForDevice;
        if (Read(Registry.CurrentUser, Consent) == "Deny") return State.BlockedForUser;
        if (Read(Registry.CurrentUser, Consent + @"\NonPackaged") == "Deny") return State.BlockedForDesktopApps;
        try
        {
            if (WaveInEvent.DeviceCount == 0) return State.NoDevice;
        }
        catch (Exception)
        {
            return State.NoDevice;
        }
        return State.Allowed;
    }

    public static string Describe(State state) => state switch
    {
        State.Allowed => "Microphone access is on.",
        State.BlockedForDevice => "Microphone access is off for this device. Turn on \"Microphone access\" in Privacy & security > Microphone.",
        State.BlockedForUser => "Microphone access is off. Turn on \"Microphone access\" in Privacy & security > Microphone.",
        State.BlockedForDesktopApps => "Desktop apps can't use the microphone. Turn on \"Let desktop apps access your microphone\" in Privacy & security > Microphone.",
        _ => "No microphone found. Plug one in, or pick one in Settings > System > Sound > Input.",
    };

    public static void OpenSettings()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
        }
        catch (Exception e)
        {
            Log.Write($"could not open microphone settings: {e.Message}");
        }
    }

    static string? Read(RegistryKey hive, string path)
    {
        try
        {
            using var key = hive.OpenSubKey(path);
            return key?.GetValue("Value") as string;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
