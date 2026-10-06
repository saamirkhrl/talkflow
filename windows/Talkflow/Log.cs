using System;
using System.IO;

namespace Talkflow;

/// <summary>
/// %LOCALAPPDATA%\talkflow\logs\talkflow.log. Sizes and timings only, never
/// what was dictated (set TALKFLOW_LOG_TRANSCRIPTS=1 to include it while
/// chasing a bug). Rolled over at 2 MB.
/// </summary>
static class Log
{
    static readonly object Gate = new();
    public static readonly bool Transcripts = Environment.GetEnvironmentVariable("TALKFLOW_LOG_TRANSCRIPTS") == "1";

    public static string FilePath => Path.Combine(Paths.LogsDir, "talkflow.log");

    public static void Write(string line)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.LogsDir);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 2_000_000) File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
            catch (Exception)
            {
                // Logging must never take the app down.
            }
        }
    }
}
