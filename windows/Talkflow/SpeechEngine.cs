using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
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

    /// <summary>Why the last start failed, in words for the pill and setup; null when it is running.</summary>
    public string? LastError { get; private set; }

    Process? _process;
    readonly object _gate = new();
    /// <summary>The first lines the server printed, kept for the log when it fails to start.</summary>
    readonly StringBuilder _startOutput = new();

    public WhisperServer(string name, int port, string modelFile, string url, long minimumBytes, string? modelOverride = null)
    {
        Name = name;
        Port = port;
        ModelPath = modelOverride ?? Path.Combine(Paths.ModelsDir, modelFile);
        DownloadUrl = new Uri(url);
        MinimumBytes = modelOverride is null ? minimumBytes : 1;
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
        if (SpeechEngine.IsResponding(Port))
        {
            LastError = null;
            return true;
        }
        if (!File.Exists(Paths.ServerExe)) return Failed($"{Paths.ServerExe} is missing. Reinstall talkflow.");
        if (!ModelIsComplete) return Failed("The speech model is not downloaded yet.");
        Process process;
        lock (_gate)
        {
            if (_process is { HasExited: false } running)
            {
                process = running;
            }
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
                if (_cpuOnly) info.ArgumentList.Add("-ng");
                lock (_startOutput) _startOutput.Clear();
                try
                {
                    Directory.CreateDirectory(Paths.LogsDir);
                    var writer = new StreamWriter(log, append: false) { AutoFlush = true };
                    process = new Process { StartInfo = info, EnableRaisingEvents = true };
                    DataReceivedEventHandler keep = (_, e) =>
                    {
                        if (e.Data is null) return;
                        lock (writer) writer.WriteLine(e.Data);
                        lock (_startOutput) if (_startOutput.Length < 4000) _startOutput.AppendLine(e.Data);
                    };
                    process.OutputDataReceived += keep;
                    process.ErrorDataReceived += keep;
                    process.Exited += (_, _) => { lock (writer) writer.Dispose(); };
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    SpeechEngine.AdoptChild(process);
                    _process = process;
                    Log.Write($"started {Name} server on :{Port} (pid {process.Id}, model {Path.GetFileName(ModelPath)}, {SpeechEngine.Threads} threads{(_cpuOnly ? ", CPU only" : "")})");
                }
                catch (Exception e)
                {
                    // Win32Exception 225: Windows Security blocked the file; 5: access denied.
                    var code = e is System.ComponentModel.Win32Exception w ? $" (error {w.NativeErrorCode})" : "";
                    Log.Write($"could not start the {Name} server{code}: {e.Message}");
                    return Failed($"Windows would not start the speech engine{code}: {e.Message}");
                }
            }
        }

        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < timeout)
        {
            if (SpeechEngine.IsResponding(Port))
            {
                Log.Write($"{Name} server answered after {watch.Elapsed.TotalSeconds:F1}s on {Device()}");
                LastError = null;
                return true;
            }
            if (process.HasExited)
            {
                process.WaitForExit(); // flushes the output handlers
                int code = process.ExitCode;
                Log.Write($"{Name} server exited during startup with code {code} (0x{code:X8}) after {watch.Elapsed.TotalSeconds:F1}s; its output began:\n{OutputHead()}");
                if (RetryOnCpu()) return Start(TimeSpan.FromSeconds(Math.Max(15, (timeout - watch.Elapsed).TotalSeconds)));
                return Failed($"The speech engine stopped while starting ({SpeechEngine.DescribeExit(code)}).");
            }
            Thread.Sleep(250);
        }
        Log.Write($"{Name} server did not answer within {timeout.TotalSeconds:F0}s; its output began:\n{OutputHead()}");
        if (RetryOnCpu())
        {
            Stop();
            return Start(timeout);
        }
        return Failed($"The speech engine did not answer within {timeout.TotalSeconds:F0} seconds.");
    }

    /// <summary>Set once a start with the GPU backend failed; the server then runs with -ng.</summary>
    volatile bool _cpuOnly;

    /// <summary>
    /// A GPU driver that crashes or hangs whisper at startup must not cost the
    /// user dictation: once, the server is started again on the CPU only.
    /// </summary>
    bool RetryOnCpu()
    {
        if (_cpuOnly || !SpeechEngine.HasGpuBackend) return false;
        _cpuOnly = true;
        Log.Write($"{Name} server: starting again on the CPU only (-ng)");
        return true;
    }

    /// <summary>What whisper said it runs on, from its startup output: the GPU's name, or the CPU.</summary>
    string Device()
    {
        string output;
        lock (_startOutput) output = _startOutput.ToString();
        foreach (var line in output.Split('\n'))
        {
            // "whisper_backend_init_gpu: device 0: Vulkan0 (NVIDIA GeForce RTX 4070) (type: 1)" or "...: CPU (type: 0)"
            int at = line.IndexOf("whisper_backend_init_gpu: device", StringComparison.Ordinal);
            if (at >= 0) return line[(line.IndexOf(':', at + 25) + 1)..].Trim();
        }
        return _cpuOnly ? "the CPU (-ng)" : "an unreported device";
    }

    string OutputHead()
    {
        lock (_startOutput) return _startOutput.Length == 0 ? "    (nothing)" : "    " + _startOutput.ToString().TrimEnd().Replace("\n", "\n    ");
    }

    bool Failed(string message)
    {
        LastError = message;
        return false;
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
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin", 480_000_000, TestHooks.Model);

    /// <summary>The final-pass model; optional, the dictation falls back to small.en.</summary>
    public static readonly WhisperServer Large = new("large-v3-turbo", 8179, "ggml-large-v3-turbo-q5_0.bin",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin", 570_000_000);

    /// <summary>Leaves cores for the app the user is typing into.</summary>
    public static int Threads => Math.Clamp(Environment.ProcessorCount - 1, 1, 8);

    public static bool EngineInstalled => File.Exists(Paths.ServerExe);

    /// <summary>The engine was built with whisper's Vulkan backend (x64); whisper uses it when a Vulkan driver is present.</summary>
    public static bool HasGpuBackend => File.Exists(Path.Combine(Paths.EngineDir, "ggml-vulkan.dll"));

    static readonly HttpClient Probe = new(new SocketsHttpHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(1.5) };

    /// <summary>
    /// Any HTTP answer at all means the server is up. Truly synchronous
    /// (HttpClient.Send), so a probe never ties up a second thread pool
    /// thread the way blocking on an async call does.
    /// </summary>
    public static bool IsResponding(int port)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{port}/");
            using var response = Probe.Send(request, HttpCompletionOption.ResponseHeadersRead);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>A process exit code in words; the NTSTATUS crashes a missing DLL or an unsupported CPU cause.</summary>
    public static string DescribeExit(int code) => unchecked((uint)code) switch
    {
        0xC0000135 => "a file it needs is missing, exit code 0xC0000135",
        0xC000007B => "a file it needs is for another kind of PC, exit code 0xC000007B",
        0xC000001D => "this processor lacks an instruction it uses, exit code 0xC000001D",
        0xC0000005 => "it crashed, exit code 0xC0000005",
        _ => $"exit code {code}",
    };

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
    /// something that looks like a finished model. Progress is bytes written
    /// and the total when the server says it (reported about 5 times a second).
    /// </summary>
    public static async Task Download(WhisperServer server, IProgress<(long Written, long? Total)>? progress, CancellationToken cancel)
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
                if (DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(200))
                {
                    lastReport = DateTime.UtcNow;
                    progress?.Report((written, total));
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
        progress?.Report((size, size));
    }
}
