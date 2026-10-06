using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Talkflow;

/// <summary>
/// The local speech engine: whisper-server.exe (built from whisper.cpp and
/// shipped in the installer) plus the model it loads. The Mac keeps the server
/// alive with a LaunchAgent; here talkflow runs it as a child process in a job
/// object, so it ends whenever talkflow does, however talkflow ends.
///
/// Two servers, as on the Mac: small.en on 127.0.0.1:8178 for the live
/// caption and the final text, and optionally large-v3-turbo on :8179 for a
/// more accurate final pass, downloaded in the background on first use.
/// </summary>
sealed class WhisperServer
{
    public string Name { get; }
    public int Port { get; }
    public string ModelPath { get; }
    public Uri DownloadUrl { get; }
    public long MinimumBytes { get; }

    Process? _process;
    readonly object _gate = new();

    public WhisperServer(string name, int port, string modelFile, string url, long minimumBytes)
    {
        Name = name;
        Port = port;
        ModelPath = Path.Combine(Paths.ModelsDir, modelFile);
        DownloadUrl = new Uri(url);
        MinimumBytes = minimumBytes;
    }

    public Uri InferenceUrl => new($"http://127.0.0.1:{Port}/inference");

    public bool ModelIsComplete
    {
        get
        {
            try { return new FileInfo(ModelPath).Length >= MinimumBytes; }
            catch (Exception) { return false; }
        }
    }

    public bool IsRunning
    {
        get { lock (_gate) return _process is { HasExited: false }; }
    }

    /// <summary>Starts the server if it is not answering already. Blocking; call off the UI thread.</summary>
    public bool Start(TimeSpan timeout)
    {
        if (SpeechEngine.IsResponding(Port)) return true;
        if (!File.Exists(Paths.ServerExe) || !ModelIsComplete) return false;
        lock (_gate)
        {
            if (_process is { HasExited: false }) { }
            else
            {
                var log = Path.Combine(Paths.LogsDir, $"whisper-server-{Port}.log");
                var info = new ProcessStartInfo(Paths.ServerExe)
                {
                    WorkingDirectory = Paths.EngineDir,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                foreach (var arg in new[] { "-m", ModelPath, "--host", "127.0.0.1", "--port", Port.ToString(), "-nt", "-t", SpeechEngine.Threads.ToString() })
                    info.ArgumentList.Add(arg);
                try
                {
                    Directory.CreateDirectory(Paths.LogsDir);
                    var writer = new StreamWriter(log, append: false) { AutoFlush = true };
                    var process = new Process { StartInfo = info, EnableRaisingEvents = true };
                    process.OutputDataReceived += (_, e) => { if (e.Data is not null) lock (writer) writer.WriteLine(e.Data); };
                    process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (writer) writer.WriteLine(e.Data); };
                    process.Exited += (_, _) => { lock (writer) writer.Dispose(); };
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    SpeechEngine.AdoptChild(process);
                    _process = process;
                    Log.Write($"started {Name} server on :{Port} (pid {process.Id})");
                }
                catch (Exception e)
                {
                    Log.Write($"could not start the {Name} server: {e.Message}");
                    return false;
                }
            }
        }
        return SpeechEngine.WaitUntilResponding(Port, timeout);
    }

    public void Stop()
    {
        lock (_gate)
        {
            try { if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true); }
            catch (Exception) { }
            _process = null;
        }
    }
}

static class SpeechEngine
{
    public static readonly WhisperServer Small = new("small.en", 8178, "ggml-small.en.bin",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin", 480_000_000);

    /// <summary>The final-pass model; optional, the dictation falls back to small.en.</summary>
    public static readonly WhisperServer Large = new("large-v3-turbo", 8179, "ggml-large-v3-turbo-q5_0.bin",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin", 570_000_000);

    /// <summary>Leaves cores for the app the user is typing into.</summary>
    public static int Threads => Math.Clamp(Environment.ProcessorCount - 1, 1, 8);

    public static bool EngineInstalled => File.Exists(Paths.ServerExe);

    static readonly HttpClient Probe = new(new SocketsHttpHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(1.5) };

    /// <summary>Any HTTP answer at all means the server is up.</summary>
    public static bool IsResponding(int port)
    {
        try
        {
            using var response = Probe.GetAsync($"http://127.0.0.1:{port}/").GetAwaiter().GetResult();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static bool WaitUntilResponding(int port, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (IsResponding(port)) return true;
            Thread.Sleep(500);
        }
        return false;
    }

    // MARK: - The job object

    static IntPtr _job;

    /// <summary>Puts a child in a kill-on-close job: when talkflow exits, crashes or is killed, the server goes too.</summary>
    public static void AdoptChild(Process process)
    {
        try
        {
            if (_job == IntPtr.Zero)
            {
                _job = Native.CreateJobObject(IntPtr.Zero, null);
                var info = new Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = Native.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                Native.SetInformationJobObject(_job, Native.JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(info));
            }
            Native.AssignProcessToJobObject(_job, process.Handle);
        }
        catch (Exception e)
        {
            Log.Write($"could not tie the speech engine to talkflow's lifetime: {e.Message}");
        }
    }

    /// <summary>Ends any whisper-server.exe running from this install (used by uninstall).</summary>
    public static void StopAll()
    {
        Small.Stop();
        Large.Stop();
        foreach (var process in Process.GetProcessesByName("whisper-server"))
        {
            try
            {
                var path = process.MainModule?.FileName;
                if (path is not null && path.StartsWith(Paths.EngineDir, StringComparison.OrdinalIgnoreCase)) process.Kill();
            }
            catch (Exception) { }
        }
    }

    // MARK: - Downloads

    /// <summary>
    /// Downloads a model to a temporary name and moves it into place only when
    /// it is complete and big enough, so a dropped connection never leaves
    /// something that looks like a finished model.
    /// </summary>
    public static async Task Download(WhisperServer server, IProgress<double>? progress, CancellationToken cancel)
    {
        Directory.CreateDirectory(Paths.ModelsDir);
        var partial = server.ModelPath + ".download";
        using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("talkflow-windows");
        using var response = await client.GetAsync(server.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancel);
        if (!response.IsSuccessStatusCode) throw new IOException($"The download server answered HTTP {(int)response.StatusCode}.");
        long? total = response.Content.Headers.ContentLength;
        await using (var source = await response.Content.ReadAsStreamAsync(cancel))
        await using (var target = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
        {
            var buffer = new byte[1 << 16];
            long written = 0;
            var lastReport = DateTime.MinValue;
            int read;
            using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            while (true)
            {
                stall.CancelAfter(TimeSpan.FromSeconds(60));
                read = await source.ReadAsync(buffer, stall.Token);
                if (read == 0) break;
                await target.WriteAsync(buffer.AsMemory(0, read), cancel);
                written += read;
                if (total > 0 && DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(200))
                {
                    lastReport = DateTime.UtcNow;
                    progress?.Report((double)written / total.Value);
                }
            }
        }
        var size = new FileInfo(partial).Length;
        if (size < server.MinimumBytes)
        {
            File.Delete(partial);
            throw new IOException($"The download ended early ({size:N0} bytes). Check your connection and try again.");
        }
        File.Move(partial, server.ModelPath, overwrite: true);
        progress?.Report(1);
    }
}
