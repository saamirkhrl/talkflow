using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// Keeps talkflow current (Updater.swift). Checks shortly after launch, every
/// six hours while running, and when the dashboard opens; when a newer version
/// has an installer for this PC, the tray menu offers it and Windows shows one
/// notification for that version. Nothing installs until the user clicks.
///
/// It reads talkflow-release.json (docs/releases.md), the manifest every
/// release carries, and verifies the installer's SHA-256 before running it.
/// Releases without a manifest fall back to GitHub's release API.
/// </summary>
sealed class Updater
{
    public enum Phase { Idle, Checking, UpToDate, Available, Downloading, Installing, Failed }

    public Phase State { get; private set; } = Phase.Idle;
    public Updates.Release? Available { get; private set; }
    public string? Error { get; private set; }
    /// <summary>The newest release GitHub named at the last check, with or without a build for this PC.</summary>
    public string? LatestVersion { get; private set; }
    public event Action? Changed;

    readonly HttpClient _http;
    DateTime _lastCheck = DateTime.MinValue;
    /// <summary>A whole check, manifest and API fallback together, gives up after this.</summary>
    static readonly TimeSpan CheckDeadline = TimeSpan.FromSeconds(40);

    public Updater()
    {
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"talkflow-windows/{CurrentVersion}");
    }

    static string InformationalVersion =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";

    public static string CurrentVersion
    {
        get
        {
            var info = InformationalVersion;
            int plus = info.IndexOf('+');
            return plus >= 0 ? info[..plus] : info;
        }
    }

    /// <summary>
    /// A build not made from a release tag: pull request and local builds are
    /// stamped 0.0.0 (windows.yml's version job). Any release counts as newer.
    /// </summary>
    public static bool IsDevelopmentBuild => CurrentVersion == "0.0.0";

    /// <summary>"v0.1.4", or "dev build 1a2b3c4" (the commit, when the build recorded it).</summary>
    public static string DisplayVersion
    {
        get
        {
            if (!IsDevelopmentBuild) return $"v{CurrentVersion}";
            var info = InformationalVersion;
            int plus = info.IndexOf('+');
            var commit = plus >= 0 ? info[(plus + 1)..] : "";
            return commit.Length >= 7 ? $"dev build {commit[..7]}" : "dev build";
        }
    }

    /// <summary>What the dashboard says next to the version after a check that found nothing to install.</summary>
    public string UpToDateText =>
        LatestVersion is { } latest && Updates.IsNewer(latest, CurrentVersion)
            ? $"{latest} has no Windows build yet"
            : "Up to date";

    /// <summary>"x64" or "arm64": the build this process is. An x64 build on an Arm PC still asks for arm64 first.</summary>
    public static string Architecture =>
        RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";

    public Task CheckIfStale() =>
        DateTime.UtcNow - _lastCheck < TimeSpan.FromHours(6) || State is Phase.Checking ? Task.CompletedTask : Check();

    /// <summary>
    /// Asks GitHub for the newest release. Always ends in UpToDate, Available
    /// or Failed, whatever goes wrong: an exception never leaves the state at
    /// Checking (which also blocks every later check).
    /// </summary>
    public async Task Check()
    {
        if (State is Phase.Checking or Phase.Downloading or Phase.Installing) return;
        Set(Phase.Checking);
        _lastCheck = DateTime.UtcNow;
        var watch = Stopwatch.StartNew();
        try
        {
            using var deadline = new CancellationTokenSource(CheckDeadline);
            var (latest, release) = await FromManifest(deadline.Token) ?? await FromApi(deadline.Token);
            LatestVersion = latest;
            if (release is not null && Updates.IsNewer(release.Version, CurrentVersion))
            {
                Available = release;
                Log.Write($"update check: {release.Version} is available ({watch.Elapsed.TotalSeconds:F1}s)");
                Set(Phase.Available);
            }
            else
            {
                Available = null;
                Log.Write($"update check: running {DisplayVersion}, newest release {latest ?? "none"}, " +
                          $"{(release is null ? $"no {Architecture} Windows build in it" : "nothing newer")} ({watch.Elapsed.TotalSeconds:F1}s)");
                Set(Phase.UpToDate);
            }
        }
        catch (Exception e)
        {
            Log.Write($"update check failed after {watch.Elapsed.TotalSeconds:F1}s: {e.GetType().Name}: {e.Message}");
            // Offline is normal for a dictation app; say so only in the dashboard.
            Fail(e is HttpRequestException or OperationCanceledException or IOException
                ? "Could not reach GitHub"
                : "Update check failed: " + e.Message);
        }
    }

    /// <summary>The manifest's newest version and this PC's build in it; null when the release has no manifest.</summary>
    async Task<(string? Latest, Updates.Release? Release)?> FromManifest(CancellationToken cancel)
    {
        using var response = await _http.GetAsync(Updates.ManifestUrl, cancel);
        if (!response.IsSuccessStatusCode) return null;
        var json = await response.Content.ReadAsStringAsync(cancel);
        if (Updates.LatestVersion(json) is not { } latest) return null;
        return (latest, Updates.ParseManifest(json, Architecture));
    }

    async Task<(string? Latest, Updates.Release? Release)> FromApi(CancellationToken cancel)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Updates.LatestReleaseApi);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await _http.SendAsync(request, cancel);
        if ((int)response.StatusCode == 404) return (null, null);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException((int)response.StatusCode == 403 ? "GitHub rate limit reached" : $"GitHub returned {(int)response.StatusCode}");
        var json = await response.Content.ReadAsStringAsync(cancel);
        return (Updates.LatestVersion(json), Updates.Parse(json, Architecture));
    }

    /// <summary>Downloads the installer, checks it, runs it silently and quits; the installer starts the new version.</summary>
    public async Task Install(Action quit)
    {
        if (Available is not { } release || State is Phase.Downloading or Phase.Installing) return;
        Set(Phase.Downloading);
        var path = Path.Combine(Paths.UpdatesDir, release.InstallerName);
        try
        {
            Directory.CreateDirectory(Paths.UpdatesDir);
            using (var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan })
            {
                client.DefaultRequestHeaders.UserAgent.ParseAdd($"talkflow-windows/{CurrentVersion}");
                using var response = await client.GetAsync(release.InstallerUrl, HttpCompletionOption.ResponseHeadersRead);
                response.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync();
                await using var target = File.Create(path);
                await source.CopyToAsync(target);
            }
            if (release.Size is { } size && new FileInfo(path).Length != size)
            {
                Fail("The download was incomplete");
                return;
            }
            if (release.Sha256 is { } expected && Updates.Sha256(path) != expected)
            {
                File.Delete(path);
                Fail("The download did not match the release checksum");
                return;
            }
        }
        catch (Exception e)
        {
            Log.Write($"update download failed: {e.GetType().Name}: {e.Message}");
            Fail("Download failed: " + e.Message);
            return;
        }

        Set(Phase.Installing);
        try
        {
            var info = new ProcessStartInfo(path) { UseShellExecute = true };
            foreach (var arg in new[] { "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS", "/LAUNCH=1" })
                info.ArgumentList.Add(arg);
            Process.Start(info);
            Log.Write($"installing update {release.Version}");
            quit();
        }
        catch (Exception e)
        {
            Log.Write($"could not start the update installer: {e.Message}");
            Fail("Could not start the installer: " + e.Message);
        }
    }

    void Fail(string message)
    {
        Error = message;
        Set(Phase.Failed);
    }

    void Set(Phase phase)
    {
        State = phase;
        Changed?.Invoke();
    }
}
