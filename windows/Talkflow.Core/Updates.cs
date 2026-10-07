using System.Text.Json;

namespace Talkflow.Core;

/// <summary>
/// Finds the newest talkflow for this PC (Updater.swift's parse and isNewer).
///
/// Every release carries talkflow-release.json, one manifest for all
/// platforms (docs/releases.md): the Windows app reads its own entry,
/// platforms.windows.&lt;arch&gt;, and verifies the installer's SHA-256 before
/// running it. A release without a manifest (older ones) falls back to GitHub's
/// release API and the installer asset by name, with no checksum.
/// </summary>
public static class Updates
{
    public const string Repository = "saamirkhrl/talkflow";
    public const string ManifestUrl = $"https://github.com/{Repository}/releases/latest/download/talkflow-release.json";
    public const string LatestReleaseApi = $"https://api.github.com/repos/{Repository}/releases/latest";

    public sealed record Release(string Version, string InstallerUrl, string InstallerName, string? Sha256, long? Size, string? PageUrl);

    /// <summary>The installer asset name for an architecture: "x64" or "arm64".</summary>
    public static string InstallerName(string architecture) => $"talkflow-windows-{architecture}-setup.exe";

    /// <summary>This PC's own architecture first, then x64, which Windows on Arm runs through emulation.</summary>
    static IEnumerable<string> Architectures(string architecture) =>
        architecture == "x64" ? new[] { "x64" } : new[] { architecture, "x64" };

    /// <summary>
    /// The Windows entry of a release manifest. Null when the manifest is
    /// unreadable, of a newer schema, or has no build this PC can run (a
    /// release whose Windows installers are not attached yet).
    /// </summary>
    public static Release? ParseManifest(string json, string architecture)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("schema", out var schema) || !schema.TryGetInt32(out var s) || s != 1) return null;
            if (Str(root, "version") is not { Length: > 0 } version) return null;
            if (!root.TryGetProperty("platforms", out var platforms) || platforms.ValueKind != JsonValueKind.Object) return null;
            if (!platforms.TryGetProperty("windows", out var windows) || windows.ValueKind != JsonValueKind.Object) return null;
            foreach (var arch in Architectures(architecture))
            {
                if (!windows.TryGetProperty(arch, out var build) || build.ValueKind != JsonValueKind.Object) continue;
                if (!build.TryGetProperty("update", out var update) || update.ValueKind != JsonValueKind.Object) continue;
                if (Str(update, "url") is not { Length: > 0 } url || Str(update, "sha256") is not { Length: 64 } sha) continue;
                long? size = update.TryGetProperty("size", out var sz) && sz.TryGetInt64(out var n) ? n : null;
                return new Release(version, url, Str(update, "name") ?? InstallerName(arch), sha.ToLowerInvariant(), size, Str(root, "notesUrl"));
            }
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>GitHub's "latest release" API answer, for releases that predate the manifest.</summary>
    public static Release? Parse(string json, string architecture)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (Str(root, "tag_name") is not { Length: > 0 } tag) return null;
            if (IsTrue(root, "draft") || IsTrue(root, "prerelease")) return null;
            if (!root.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;

            foreach (var arch in Architectures(architecture))
            {
                var name = InstallerName(arch);
                foreach (var asset in assets.EnumerateArray())
                {
                    if (Str(asset, "name") == name && Str(asset, "browser_download_url") is { Length: > 0 } link)
                    {
                        var version = tag.StartsWith('v') ? tag[1..] : tag;
                        return new Release(version, link, name, null, null, Str(root, "html_url"));
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

    /// <summary>
    /// The newest version a manifest or a GitHub "latest release" answer
    /// names, whether or not it has a Windows build, so the app can say
    /// "0.1.3 has no Windows installer" instead of "up to date". Null when
    /// unreadable.
    /// </summary>
    public static string? LatestVersion(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            // A manifest of another schema counts as missing (docs/releases.md).
            if (root.TryGetProperty("schema", out var schema) && (!schema.TryGetInt32(out var n) || n != 1)) return null;
            if (Str(root, "version") is { Length: > 0 } version) return version;
            if (Str(root, "tag_name") is { Length: > 0 } tag) return tag.StartsWith('v') ? tag[1..] : tag;
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    static string? Str(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

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

    /// <summary>Lowercase hex SHA-256 of a file.</summary>
    public static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)).ToLowerInvariant();
    }
}
