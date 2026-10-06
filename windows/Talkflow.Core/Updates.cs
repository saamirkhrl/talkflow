using System.Text.Json;

namespace Talkflow.Core;

/// <summary>
/// Reads GitHub's "latest release" answer for the in-app updater
/// (Updater.swift's parse and isNewer). The Windows app installs the Inno
/// Setup installer for its own architecture; the Mac assets are ignored.
/// </summary>
public static class Updates
{
    public const string Repository = "saamirkhrl/talkflow";

    public sealed record Release(string Version, string InstallerUrl, string InstallerName, string? PageUrl);

    /// <summary>The installer asset name for an architecture: "x64" or "arm64".</summary>
    public static string InstallerName(string architecture) => $"talkflow-windows-{architecture}-setup.exe";

    /// <summary>
    /// The release, if it is published, not a prerelease, and carries an
    /// installer this PC can run: its own architecture first, then x64, which
    /// Windows on Arm runs through emulation.
    /// </summary>
    public static Release? Parse(string json, string architecture)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("tag_name", out var tagElement) || tagElement.ValueKind != JsonValueKind.String) return null;
            if (IsTrue(root, "draft") || IsTrue(root, "prerelease")) return null;
            if (!root.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;

            var wanted = new List<string> { InstallerName(architecture) };
            if (architecture != "x64") wanted.Add(InstallerName("x64"));
            foreach (var name in wanted)
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    if (asset.TryGetProperty("name", out var n) && n.GetString() == name
                        && asset.TryGetProperty("browser_download_url", out var url) && url.GetString() is { Length: > 0 } link)
                    {
                        var tag = tagElement.GetString()!;
                        var version = tag.StartsWith('v') ? tag[1..] : tag;
                        var page = root.TryGetProperty("html_url", out var html) ? html.GetString() : null;
                        return new Release(version, link, name, page);
                    }
                }
            }
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    static bool IsTrue(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    /// <summary>"0.10.0" is newer than "0.9.2"; missing parts count as zero.</summary>
    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string v) => v.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var a = Parts(candidate);
        var b = Parts(current);
        for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
