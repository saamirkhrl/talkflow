using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Win32;

namespace Talkflow;

/// <summary>Start talkflow when you sign in: a per-user Run entry, no admin rights.</summary>
static class StartupEntry
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "talkflow";

    static string Command => $"\"{Environment.ProcessPath}\" --background";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    public static void Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled) key.SetValue(Name, Command);
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch (Exception e)
        {
            Log.Write($"could not change the startup entry: {e.Message}");
        }
    }

    /// <summary>A reinstall may move the program; keep an existing entry pointing at this copy.</summary>
    public static void Refresh()
    {
        if (IsEnabled) Set(true);
    }
}

/// <summary>
/// Removes talkflow from this PC (Uninstaller.swift): the program, the speech
/// engine, the speech models, logs and caches, the startup entry and saved API
/// keys. The data folder, %APPDATA%\talkflow (stats, settings, learned words),
/// is kept, so installing again picks up where the user left off.
///
/// Two ways in, one cleanup: Settings > Uninstall runs <see cref="Cleanup"/>
/// and then the Inno Setup uninstaller; Windows' "Apps > Uninstall" runs the
/// same uninstaller, which first calls `talkflow.exe --uninstall-cleanup`.
/// </summary>
static class Uninstaller
{
    public static IEnumerable<string> Plan()
    {
        yield return $"Save your settings to {Paths.SettingsFile}";
        yield return "Stop the speech engine";
        yield return $"Remove the speech models, logs and downloads ({Paths.LocalDir})";
        yield return "Remove saved API keys from Credential Manager";
        yield return "Remove the startup entry";
        yield return $"Remove the program and the speech engine ({Paths.InstallDir.TrimEnd('\\')})";
        yield return $"Keep your data: {Paths.DataDir}";
    }

    /// <summary>Everything except deleting the program files, which the uninstaller does.</summary>
    public static void Cleanup(App? app)
    {
        try { app?.Settings.BackUp(); } catch (Exception) { }
        Log.Write("uninstall: cleaning up");
        // Other copies of talkflow (the uninstaller may run while it is open).
        foreach (var process in Process.GetProcessesByName("talkflow").Where(p => p.Id != Environment.ProcessId))
        {
            try { process.Kill(); process.WaitForExit(3000); } catch (Exception) { }
        }
        SpeechEngine.StopAll();
        ApiKeys.Remove(ApiKeys.Provider.OpenAI);
        ApiKeys.Remove(ApiKeys.Provider.Anthropic);
        StartupEntry.Set(false);
        // Models, logs and downloads. The log file is open, so delete what can be deleted.
        try
        {
            if (Directory.Exists(Paths.LocalDir))
            {
                foreach (var file in Directory.EnumerateFiles(Paths.LocalDir, "*", SearchOption.AllDirectories))
                {
                    try { File.Delete(file); } catch (Exception) { }
                }
                try { Directory.Delete(Paths.LocalDir, recursive: true); } catch (Exception) { }
            }
        }
        catch (Exception) { }
    }

    /// <summary>The Inno Setup uninstaller next to talkflow.exe, when installed.</summary>
    public static string? UninstallerPath =>
        Directory.EnumerateFiles(Paths.InstallDir, "unins*.exe").OrderBy(p => p).FirstOrDefault();

    /// <summary>Settings > Uninstall: clean up, start the uninstaller, quit.</summary>
    public static bool Run(App app)
    {
        var uninstaller = UninstallerPath;
        Cleanup(app);
        if (uninstaller is null)
        {
            Log.Write("uninstall: no uninstaller found (not an installed copy); cleanup only");
            return false;
        }
        try
        {
            var info = new ProcessStartInfo(uninstaller) { UseShellExecute = true };
            info.ArgumentList.Add("/SILENT");
            info.ArgumentList.Add("/NORESTART");
            Process.Start(info);
            return true;
        }
        catch (Exception e)
        {
            Log.Write($"could not start the uninstaller: {e.Message}");
            return false;
        }
    }
}
