using System.Text.Json;
using System.Text.Json.Nodes;
using Talkflow.Core.Text;

namespace Talkflow.Core;

/// <summary>
/// The user's choices, in settings.json (UserData.swift). Same keys, types and
/// defaults as the Mac app, so the file moves between platforms unchanged.
/// Keys this platform does not use (aiPolish needs Apple's on-device model)
/// are kept as they are, never dropped. API keys are never stored here.
/// </summary>
public sealed class SettingsStore
{
    /// <summary>
    /// Every shared key the Mac app writes. Windows-only choices live in windows.json instead; the Mac's
    /// own shortcut ("macHotkey", Mac keycodes) is kept in the file as it is, like any key Windows does not use.
    /// </summary>
    public static readonly string[] SettingKeys =
    {
        "typeWhileSpeaking", "accurateFinalPass", "aiPolish", "learnedWords", "writingStyle",
        "useOpenAITranscription", "useClaudePunctuation", "claudeModel", "dashboardChart",
    };

    public static readonly (string Id, string Title)[] ClaudeModels =
    {
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-4-5", "Claude Haiku 4.5 (fastest)"),
    };

    readonly string _path;
    readonly object _lock = new();
    JsonObject _values = new();

    public event Action? Changed;

    public SettingsStore(string path)
    {
        _path = path;
        Load();
    }

    public string FilePath => _path;

    void Load()
    {
        try
        {
            if (File.Exists(_path) && JsonNode.Parse(File.ReadAllText(_path)) is JsonObject obj) _values = obj;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            _values = new JsonObject();
        }
    }

    void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        // Sorted keys, two-space indent: the shape the Mac writes.
        var sorted = new JsonObject();
        foreach (var key in _values.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal))
            sorted[key] = _values[key]?.DeepClone();
        var json = sorted.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        var temp = _path + ".tmp";
        File.WriteAllText(temp, json);
        File.Move(temp, _path, overwrite: true);
    }

    /// <summary>Writes every shared key at its current value, so the file is complete.</summary>
    public void BackUp()
    {
        lock (_lock)
        {
            SetDefault("typeWhileSpeaking", false);
            SetDefault("accurateFinalPass", true);
            SetDefault("aiPolish", false);
            if (_values["learnedWords"] is not JsonArray) _values["learnedWords"] = new JsonArray();
            SetDefault("writingStyle", "formal");
            SetDefault("useOpenAITranscription", false);
            SetDefault("useClaudePunctuation", false);
            SetDefault("claudeModel", "claude-opus-5-5");
            SetDefault("dashboardChart", "Grid");
            TrySave();
        }
    }

    void SetDefault(string key, JsonNode value)
    {
        if (!_values.ContainsKey(key) || _values[key] is null) _values[key] = value;
    }

    void TrySave()
    {
        try { Save(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    bool GetBool(string key, bool fallback)
    {
        lock (_lock)
        {
            var node = _values[key];
            if (node is JsonValue v)
            {
                if (v.TryGetValue(out bool b)) return b;
                if (v.TryGetValue(out int i)) return i != 0; // NSNumber bools can come back as 0/1
            }
            return fallback;
        }
    }

    string? GetString(string key)
    {
        lock (_lock) return _values[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;
    }

    void Set(string key, JsonNode? value)
    {
        lock (_lock)
        {
            _values[key] = value;
            TrySave();
        }
        Changed?.Invoke();
    }

    /// <summary>Type into the field while the key is held. Off by default.</summary>
    public bool TypeWhileSpeaking { get => GetBool("typeWhileSpeaking", false); set => Set("typeWhileSpeaking", value); }

    /// <summary>Transcribe the final pass with large-v3-turbo when it is installed. On by default.</summary>
    public bool AccurateFinalPass { get => GetBool("accurateFinalPass", true); set => Set("accurateFinalPass", value); }

    public WritingStyle WritingStyle
    {
        get => WritingStyles.Parse(GetString("writingStyle"));
        set => Set("writingStyle", value.RawValue());
    }

    public bool UseOpenAITranscription { get => GetBool("useOpenAITranscription", false); set => Set("useOpenAITranscription", value); }

    public bool UseClaudePunctuation { get => GetBool("useClaudePunctuation", false); set => Set("useClaudePunctuation", value); }

    public string ClaudeModel
    {
        get
        {
            var raw = GetString("claudeModel");
            return ClaudeModels.Any(m => m.Id == raw) ? raw! : ClaudeModels[0].Id;
        }
        set => Set("claudeModel", value);
    }

    /// <summary>"Grid" or "Weekly bars", the dashboard chart.</summary>
    public string DashboardChart
    {
        get => GetString("dashboardChart") == "Weekly bars" ? "Weekly bars" : "Grid";
        set => Set("dashboardChart", value);
    }

    /// <summary>Newest first.</summary>
    public List<string> LearnedWords
    {
        get
        {
            lock (_lock)
            {
                if (_values["learnedWords"] is not JsonArray array) return new List<string>();
                return array.Select(n => n is JsonValue v && v.TryGetValue(out string? s) ? s : null)
                    .Where(s => s is not null).Select(s => s!).ToList();
            }
        }
        set => Set("learnedWords", new JsonArray(value.Select(w => (JsonNode?)JsonValue.Create(w)).ToArray()));
    }
}
