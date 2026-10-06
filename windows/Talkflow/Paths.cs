using System;
using System.IO;

namespace Talkflow;

/// <summary>
/// Where everything lives. Two folders, on purpose:
///
///  - <see cref="DataDir"/>, %APPDATA%\talkflow: the user's own data (stats.json,
///    settings.json, windows.json). Uninstalling keeps it, so a reinstall picks
///    up where the user left off. Same files and format as the Mac's
///    ~/Library/Application Support/talkflow.
///  - <see cref="LocalDir"/>, %LOCALAPPDATA%\talkflow: what the app can fetch or
///    rebuild (speech models, logs, the update download). Uninstalling removes it.
///
/// The program itself is installed to %LOCALAPPDATA%\Programs\talkflow.
/// </summary>
static class Paths
{
    /// <summary>TALKFLOW_DATA_DIR is for tests only, so they never touch the real folder.</summary>
    public static string DataDir { get; } = Environment.GetEnvironmentVariable("TALKFLOW_DATA_DIR") is { Length: > 0 } dir
        ? dir
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "talkflow");

    public static string LocalDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "talkflow");

    public static string StatsFile => Path.Combine(DataDir, "stats.json");
    public static string SettingsFile => Path.Combine(DataDir, "settings.json");
    public static string WindowsPrefsFile => Path.Combine(DataDir, "windows.json");

    public static string ModelsDir => Path.Combine(LocalDir, "models");
    public static string LogsDir => Path.Combine(LocalDir, "logs");
    public static string UpdatesDir => Path.Combine(LocalDir, "updates");

    /// <summary>The folder talkflow.exe runs from.</summary>
    public static string InstallDir => AppContext.BaseDirectory;

    /// <summary>whisper-server.exe and its DLLs, shipped in the installer.</summary>
    public static string EngineDir => Path.Combine(InstallDir, "engine");
    public static string ServerExe => Path.Combine(EngineDir, "whisper-server.exe");

    public static void EnsureCreated()
    {
        Directory.CreateDirectory(DataDir);
        Directory.CreateDirectory(LocalDir);
        Directory.CreateDirectory(LogsDir);
    }
}
