using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Talkflow.Core;

/// <summary>
/// Local usage stats in stats.json (StatsStore.swift). The file format is the
/// Mac app's, key for key, so the same file works on either platform:
/// <c>{"totalWords":0,"totalSessions":0,"totalSpeakingSeconds":0,"dailyWordCounts":{"yyyy-MM-dd":0}}</c>.
/// Every key is always written: the Mac decoder needs all four.
/// </summary>
public sealed class StatsStore
{
    public sealed class Data
    {
        [JsonPropertyName("totalWords")] public long TotalWords { get; set; }
        [JsonPropertyName("totalSessions")] public long TotalSessions { get; set; }
        [JsonPropertyName("totalSpeakingSeconds")] public double TotalSpeakingSeconds { get; set; }
        /// <summary>"yyyy-MM-dd" (local time) to the words dictated that day.</summary>
        [JsonPropertyName("dailyWordCounts")] public Dictionary<string, long> DailyWordCounts { get; set; } = new();
    }

    public sealed record Snapshot(long TotalWords, long TotalSessions, int AverageWpm, long TodayWords, int DayStreak, long EstimatedMinutesSaved);

    readonly string _path;
    readonly object _lock = new();
    readonly Func<DateTime> _now;
    Data _data = new();

    public StatsStore(string path, Func<DateTime>? now = null)
    {
        _path = path;
        _now = now ?? (() => DateTime.Now);
        Load();
    }

    public string FilePath => _path;

    void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var decoded = JsonSerializer.Deserialize<Data>(File.ReadAllText(_path));
            if (decoded is not null)
            {
                decoded.DailyWordCounts ??= new Dictionary<string, long>();
                _data = decoded;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // A damaged file starts the counts over rather than stopping the app.
        }
    }

    /// <summary>Re-reads the file, for the dashboard (another copy of the app may have written it).</summary>
    public void Reload()
    {
        lock (_lock) Load();
    }

    void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var json = JsonSerializer.Serialize(_data);
        var temp = _path + ".tmp";
        File.WriteAllText(temp, json);
        File.Move(temp, _path, overwrite: true);
    }

    public static string DayKey(DateTime date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static int CountWords(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    public void RecordSession(string text, double durationSeconds)
    {
        int wordCount = CountWords(text);
        if (wordCount <= 0 || durationSeconds <= 0) return;
        lock (_lock)
        {
            _data.TotalWords += wordCount;
            _data.TotalSessions += 1;
            _data.TotalSpeakingSeconds += durationSeconds;
            var key = DayKey(_now());
            _data.DailyWordCounts[key] = _data.DailyWordCounts.GetValueOrDefault(key) + wordCount;
            try { Save(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>Words per day for the last <paramref name="count"/> days, oldest first, ending today.</summary>
    public List<(DateTime Date, long Words)> RecentDays(int count)
    {
        lock (_lock)
        {
            var today = _now().Date;
            var list = new List<(DateTime, long)>();
            for (int offset = count - 1; offset >= 0; offset--)
            {
                var day = today.AddDays(-offset);
                list.Add((day, _data.DailyWordCounts.GetValueOrDefault(DayKey(day))));
            }
            return list;
        }
    }

    public Snapshot Take()
    {
        lock (_lock)
        {
            double minutesSpeaking = _data.TotalSpeakingSeconds / 60;
            int averageWpm = minutesSpeaking > 0 ? (int)(_data.TotalWords / minutesSpeaking) : 0;
            var now = _now();
            long today = _data.DailyWordCounts.GetValueOrDefault(DayKey(now));

            int streak = 0;
            var cursor = now.Date;
            while (_data.DailyWordCounts.TryGetValue(DayKey(cursor), out var words) && words > 0)
            {
                streak++;
                cursor = cursor.AddDays(-1);
            }

            // Time saved vs. typing at ~40 wpm, minus the time spent talking.
            double typingMinutes = _data.TotalWords / 40.0;
            double saved = Math.Max(0, typingMinutes - minutesSpeaking);
            return new Snapshot(_data.TotalWords, _data.TotalSessions, averageWpm, today, streak, (long)saved);
        }
    }

    /// <summary>Splits minutes into the two largest whole units: 879 -> 14 h 39 min.</summary>
    public static List<(string Value, string Unit)> TimeSavedParts(long minutes)
    {
        (string Name, long Minutes)[] units =
        {
            ("yr", 365 * 24 * 60), ("mo", 30 * 24 * 60), ("wk", 7 * 24 * 60), ("d", 24 * 60), ("h", 60), ("min", 1),
        };
        long remaining = Math.Max(minutes, 0);
        var parts = new List<(string, string)>();
        foreach (var unit in units)
        {
            if (remaining < unit.Minutes) continue;
            parts.Add(((remaining / unit.Minutes).ToString(CultureInfo.InvariantCulture), unit.Name));
            remaining %= unit.Minutes;
            if (parts.Count == 2) break;
        }
        return parts.Count == 0 ? new List<(string, string)> { ("0", "min") } : parts;
    }
}
