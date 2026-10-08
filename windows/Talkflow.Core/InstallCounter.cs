using System.Reflection;

namespace Talkflow.Core;

/// <summary>Where the app keeps whether this install has been counted (windows.json, never settings.json).</summary>
public interface IInstallFlag
{
    bool InstallCounted { get; set; }
}

/// <summary>
/// The one thing talkflow reports about itself (InstallCounter.swift,
/// docs/telemetry.md): the first time a fresh install runs, one POST with no
/// body and no headers of its own, so the site can add 1 to a single install
/// count. No ID, no version, no device or usage data.
///
/// The URL exists only in release builds: the release workflow passes
/// -p:TalkflowTelemetryUrl=..., which becomes assembly metadata. Local and pull
/// request builds have none and never make the request.
/// </summary>
public static class InstallCounter
{
    public const string MetadataKey = "TalkflowTelemetryUrl";
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(10);

    /// <summary>The URL baked into an assembly, or null (every non-release build).</summary>
    public static Uri? ConfiguredUrl(Assembly assembly) =>
        ParseUrl(assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == MetadataKey)?.Value);

    /// <summary>Only a complete https URL counts; anything else means "don't send".</summary>
    public static Uri? ParseUrl(string? raw) =>
        Uri.TryCreate(raw?.Trim(), UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps && url.Host.Length > 0 ? url : null;

    /// <summary>
    /// Whether to send now: a URL, not counted yet, and a real launch, not the
    /// end-to-end test (any TALKFLOW_TEST_* hook) or a CI machine.
    /// </summary>
    public static bool ShouldSend(Uri? url, bool counted, bool testHooks, string? ciVariable) =>
        url is not null && !counted && !testHooks && string.IsNullOrEmpty(ciVariable);

    /// <summary>An empty POST: no body, no headers of its own.</summary>
    public static HttpRequestMessage Request(Uri url) => new(HttpMethod.Post, url);

    /// <summary>
    /// Sends once when <see cref="ShouldSend"/> allows it, and marks the install
    /// counted only on a 2xx answer, so a failure or timeout is retried on the
    /// next launch. Never throws. Returns whether the install now counts as counted.
    /// </summary>
    public static async Task<bool> CountOnce(Uri? url, IInstallFlag flag, bool testHooks, string? ciVariable,
        HttpMessageInvoker http, TimeSpan? timeout = null)
    {
        if (!ShouldSend(url, flag.InstallCounted, testHooks, ciVariable)) return flag.InstallCounted;
        try
        {
            using var deadline = new CancellationTokenSource(timeout ?? DefaultTimeout);
            using var request = Request(url!);
            using var response = await http.SendAsync(request, deadline.Token);
            if (!response.IsSuccessStatusCode) return false;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException)
        {
            return false;
        }
        flag.InstallCounted = true;
        return true;
    }

    /// <summary>The handler the app sends with: no cookies, no redirects followed.</summary>
    public static HttpMessageHandler Handler() => new SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = false };
}
