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
    public event Action? Changed;

    readonly HttpClient _http;
    DateTime _lastCheck = DateTime.MinValue;

    public Updater()
    {
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"talkflow-windows/{CurrentVersion}");
    }

    public static string CurrentVersion
    {
        get
        {
            var info = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";
            int plus = info.IndexOf('+');
            return plus >= 0 ? info[..plus] : info;
        }
    }

    /// <summary>"x64" or "arm64": the build this process is. An x64 build on an Arm PC still asks for arm64 first.</summary>
    public static string Architecture =>
        RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";

    public Task CheckIfStale() =>
        DateTime.UtcNow - _lastCheck < TimeSpan.FromHours(6) || State is Phase.Checking ? Task.CompletedTask : Check();

    public async Task Check()
    {
        if (State is Phase.Checking or Phase.Downloading or Phase.Installing) return;
        Set(Phase.Checking);
        _lastCheck = DateTime.UtcNow;
        try
        {
            var release = await FromManifest() ?? await FromApi();
            if (release is not null && Updates.IsNewer(release.Version, CurrentVersion))
            {
                Available = release;
                Set(Phase.Available);
            }
            else
            {
                Available = null;
                Set(Phase.UpToDate);
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            // Offline is normal for a dictation app; say so only in the dashboard.
            Fail("Could not reach GitHub");
        }
    }

    async Task<Updates.Release?> FromManifest()
    {
        using var response = await _http.GetAsync(Updates.ManifestUrl);
        if (!response.IsSuccessStatusCode) return null;
        return Updates.ParseManifest(await response.Content.ReadAsStringAsync(), Architecture);
    }

    async Task<Updates.Release?> FromApi()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Updates.LatestReleaseApi);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await _http.SendAsync(request);
        if ((int)response.StatusCode == 404) return null;
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException((int)response.StatusCode == 403 ? "GitHub rate limit reached" : $"GitHub returned {(int)response.StatusCode}");
        return Updates.Parse(await response.Content.ReadAsStringAsync(), Architecture);
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
        catch (Exception e) when (e is HttpRequestException or IOException or TaskCanceledException or UnauthorizedAccessException)
        {
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
