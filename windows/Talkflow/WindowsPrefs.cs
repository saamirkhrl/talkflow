using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// Choices that only exist on Windows, in windows.json next to settings.json:
/// the hold-to-dictate shortcut, which update was last announced, and whether this install has been counted
/// (InstallCounter). Kept out of settings.json so that file stays exactly the Mac's schema and never carries the
/// counted flag to another PC, and kept in the data folder so it survives a reinstall.
/// </summary>
sealed class WindowsPrefs : IInstallFlag
{
    sealed class Data
    {
        /// <summary>Key groups that must all be held; a group is satisfied by any of its virtual-key codes.</summary>
        [JsonPropertyName("hotkey")] public List<List<int>>? Hotkey { get; set; }
        /// <summary>The newest version the user has been told about, so each update is announced once.</summary>
        [JsonPropertyName("notifiedVersion")] public string? NotifiedVersion { get; set; }
        /// <summary>Set once the install counter got a 2xx answer (docs/telemetry.md).</summary>
        [JsonPropertyName("installCounted")] public bool InstallCounted { get; set; }
    }

    Data _data = new();

    public WindowsPrefs()
    {
        try
        {
            if (File.Exists(Paths.WindowsPrefsFile))
                _data = JsonSerializer.Deserialize<Data>(File.ReadAllText(Paths.WindowsPrefsFile)) ?? new Data();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            _data = new Data();
        }
    }

    public HotkeySpec Hotkey
    {
        get => _data.Hotkey is { Count: > 0 } groups && groups.All(g => g.Count > 0)
            ? new HotkeySpec(groups.Select(g => g.ToArray()).ToArray())
            : HotkeySpec.Default;
        set
        {
            _data.Hotkey = value.Groups.Select(g => g.ToList()).ToList();
            Save();
        }
    }

    public string? NotifiedVersion
    {
        get => _data.NotifiedVersion;
        set
        {
            _data.NotifiedVersion = value;
            Save();
        }
    }

    public bool InstallCounted
    {
        get => _data.InstallCounted;
        set
        {
            _data.InstallCounted = value;
            Save();
        }
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(Paths.DataDir);
            File.WriteAllText(Paths.WindowsPrefsFile, JsonSerializer.Serialize(_data, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"could not save windows.json: {e.Message}");
        }
    }
}
