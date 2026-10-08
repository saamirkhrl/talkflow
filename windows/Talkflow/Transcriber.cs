using System;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Talkflow.Core.Text;

namespace Talkflow;

/// <summary>
/// Sends audio to the local whisper-server (Transcriber.swift). HttpClient
/// keeps no response cache, so neither the audio nor the transcript is ever
/// written to disk by the networking layer.
/// </summary>
static class Transcriber
{
    public sealed record Result(string Text, double Elapsed, int Segments = 1);

    static readonly HttpClient Local = new(new SocketsHttpHandler { UseProxy = false }) { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>"I'm Samir, and I use talkflow, a dictation app.", from the Windows account's name.</summary>
    public static readonly string VocabularyPrompt = Transcript.Prompt(FullUserName());

    static string FullUserName()
    {
        try
        {
            var buffer = new StringBuilder(256);
            uint size = (uint)buffer.Capacity;
            if (Native.GetUserNameEx(Native.NameDisplay, buffer, ref size) && buffer.Length > 0) return buffer.ToString();
        }
        catch (Exception) { }
        return Environment.UserName;
    }

    /// <summary>What went wrong with a request, in words for the pill. <see cref="EngineDown"/>: nothing was listening.</summary>
    public sealed record Failure(string Message, bool EngineDown);

    public static async Task<(Result? Result, Failure? Failure)> Transcribe(byte[] wav, Uri server, TimeSpan timeout, string prompt)
    {
        var boundary = "talkflow-" + Guid.NewGuid().ToString("N");
        using var content = new ByteArrayContent(Transcript.MultipartBody(wav, boundary, prompt));
        content.Headers.ContentType = MediaTypeHeaderValue.Parse($"multipart/form-data; boundary={boundary}");
        var watch = Stopwatch.StartNew();
        try
        {
            using var cancel = new CancellationTokenSource(timeout);
            if (TestHooks.SlowEngineMs > 0) await Task.Delay(TestHooks.SlowEngineMs, cancel.Token);
            using var response = await Local.PostAsync(server, content, cancel.Token);
            if (!response.IsSuccessStatusCode)
            {
                Log.Write($"transcription server returned HTTP {(int)response.StatusCode}");
                return (null, new Failure($"the speech engine answered HTTP {(int)response.StatusCode}", false));
            }
            var raw = await response.Content.ReadAsStringAsync(cancel.Token);
            var text = Transcript.JoinSegments(raw).Trim();
            int segments = raw.Replace("\r\n", "\n").Split('\n').Count(s => !Transcript.IsPlaceholder(s));
            return (new Result(text, watch.Elapsed.TotalSeconds, Math.Max(segments, 1)), null);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException or System.IO.IOException)
        {
            bool refused = e is HttpRequestException { InnerException: SocketException { SocketErrorCode: SocketError.ConnectionRefused } };
            Log.Write($"transcription request failed after {watch.Elapsed.TotalSeconds:F2}s: {e.GetType().Name}{(refused ? " (connection refused)" : "")}");
            return (null, refused
                ? new Failure("the speech engine is not running", true)
                : e is HttpRequestException
                    ? new Failure("the speech engine could not be reached", false)
                    : new Failure($"the speech engine took longer than {timeout.TotalSeconds:F0} s", false));
        }
    }
}

/// <summary>The final pass with the user's own OpenAI key (CloudTranscriber.swift).</summary>
static class CloudTranscriber
{
    public const string Model = "gpt-4o-transcribe";
    static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };

    public static async Task<(Transcriber.Result? Result, string? Error)> Transcribe(byte[] wav, string prompt)
    {
        if (ApiKeys.Get(ApiKeys.Provider.OpenAI) is not { } key) return (null, "OpenAI: no API key saved");
        using var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(wav);
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(file, "file", "audio.wav");
        form.Add(new StringContent(Model), "model");
        form.Add(new StringContent("text"), "response_format");
        if (prompt.Length > 0) form.Add(new StringContent(prompt), "prompt");
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions") { Content = form };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        var watch = Stopwatch.StartNew();
        try
        {
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            using var response = await Client.SendAsync(request, cancel.Token);
            var body = await response.Content.ReadAsStringAsync(cancel.Token);
            if (!response.IsSuccessStatusCode) return (null, Failure((int)response.StatusCode, body));
            return (new Transcriber.Result(Transcript.JoinSegments(body).Trim(), watch.Elapsed.TotalSeconds), null);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return (null, "OpenAI unreachable: " + (e is TaskCanceledException ? "timed out" : e.Message));
        }
    }

    public static async Task<string?> Validate(string key)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.openai.com/v1/models");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        try
        {
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using var response = await Client.SendAsync(request, cancel.Token);
            return response.IsSuccessStatusCode ? null : Failure((int)response.StatusCode, await response.Content.ReadAsStringAsync());
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return "OpenAI unreachable: " + e.Message;
        }
    }

    static string Failure(int code, string body) => code switch
    {
        401 or 403 => "OpenAI rejected your API key",
        429 => "OpenAI: rate limit or out of credit",
        _ => $"OpenAI error {code}" + (ErrorDetail(body) is { Length: > 0 } d ? ": " + d : ""),
    };

    /// <summary>{"error": {"message": "..."}}, the shape OpenAI and Anthropic both use.</summary>
    public static string ErrorDetail(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message) && message.GetString() is { } m)
                return m.Length > 80 ? m[..80] : m;
        }
        catch (JsonException) { }
        return "";
    }
}

/// <summary>
/// The punctuation pass by Claude with the user's own key (ClaudePolish.swift).
/// The answer is never inserted as is: it goes through PolishMerge, which keeps
/// the original words, and must pass the deletion-only check.
/// </summary>
static class ClaudePolish
{
    static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };
    const int BudgetSeconds = 6;

    public static async Task<(string Text, string? Error)> Run(string text, string model, string[] names)
    {
        if (ApiKeys.Get(ApiKeys.Provider.Anthropic) is not { } key) return (text, "Claude: no API key saved");
        var body = new System.Collections.Generic.Dictionary<string, object>
        {
            ["model"] = model,
            ["max_tokens"] = 4096,
            ["system"] = PolishMerge.Instructions,
            ["messages"] = new[] { new { role = "user", content = text } },
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
        if (model != "claude-haiku-4-5")
        {
            body["output_config"] = new { effort = "low" };
            body["fallbacks"] = "default";
            request.Headers.Add("anthropic-beta", "server-side-fallback-2026-07-01");
        }
        request.Headers.Add("x-api-key", key);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        var watch = Stopwatch.StartNew();
        try
        {
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(BudgetSeconds));
            using var response = await Client.SendAsync(request, cancel.Token);
            var json = await response.Content.ReadAsStringAsync(cancel.Token);
            int code = (int)response.StatusCode;
            if (!response.IsSuccessStatusCode)
            {
                return (text, code switch
                {
                    401 or 403 => "Anthropic rejected your API key",
                    429 => "Claude: rate limit reached",
                    529 => "Claude is overloaded, inserted without it",
                    _ => $"Claude error {code}" + (CloudTranscriber.ErrorDetail(json) is { Length: > 0 } d ? ": " + d : ""),
                });
            }
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("stop_reason", out var stop) && stop.GetString() == "refusal")
                return (text, "Claude declined this text, inserted without it");
            var reply = new StringBuilder();
            if (root.TryGetProperty("content", out var blocks))
                foreach (var block in blocks.EnumerateArray())
                    if (block.TryGetProperty("type", out var type) && type.GetString() == "text" && block.TryGetProperty("text", out var t))
                        reply.Append(t.GetString());
            var merged = PolishMerge.Merge(text, reply.ToString(), names);
            var safe = SelfCorrection.IsDeletionOnly(text, merged) ? merged : text;
            Log.Write($"Claude punctuation ({model}) {(safe == text ? "changed nothing" : "applied")} in {watch.Elapsed.TotalSeconds:F2}s");
            return (safe, null);
        }
        catch (Exception e) when (e is TaskCanceledException)
        {
            return (text, $"Claude took longer than {BudgetSeconds}s, inserted without it");
        }
        catch (Exception e) when (e is HttpRequestException or JsonException)
        {
            return (text, "Claude unreachable: " + e.Message);
        }
    }

    public static async Task<string?> Validate(string key)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/v1/models");
        request.Headers.Add("x-api-key", key);
        request.Headers.Add("anthropic-version", "2023-06-01");
        try
        {
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using var response = await Client.SendAsync(request, cancel.Token);
            if (response.IsSuccessStatusCode) return null;
            return (int)response.StatusCode is 401 or 403 ? "Anthropic rejected your API key" : $"Claude error {(int)response.StatusCode}";
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return "Anthropic unreachable: " + e.Message;
        }
    }
}
