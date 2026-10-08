using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// Captures the default microphone into memory as 16 kHz mono 16-bit PCM and
/// hands back a complete WAV on demand (Recorder.swift). Audio never touches
/// the disk. Windows' audio engine converts to 16 kHz for us.
///
/// The device is the default input in Settings > Sound, opened with WASAPI,
/// which names it and fails out loud. The older waveIn API is the fallback
/// only: on one PC its default mapper opened a USB microphone and then never
/// returned a single buffer, with no error.
///
/// Opening and closing the device happen on a thread of their own (Device),
/// never on the UI thread: drivers can block in them for seconds, and one USB
/// microphone blocked in Dispose for 17 minutes. So a device thread that is
/// still busy when the next hold starts is left behind, and the hold opens
/// the microphone on a new thread. Start and Stop return at once (Stop after
/// a short tail); a hold's audio is whatever arrived between them.
///
/// A device that delivered audio stays open after a hold, so the next hold
/// does not lose the start of its words to the device opening again: for a few
/// seconds when it opens fast or very slowly, for two minutes when it opens in
/// a quarter to a full second (an Intel Smart Sound array takes 300 to 700 ms,
/// and its first buffers are near-silent). A Bluetooth headset, about a second
/// to switch to its microphone, keeps the short window: open, it would stay in
/// hands-free mode. See DevicePolicy.KeepOpenMs for the privacy cost: Windows
/// shows the microphone as in use for as long as it is open.
/// </summary>
sealed class Recorder
{
    public const int SampleRate = 16000;
    /// <summary>A device call still running this long when a hold starts is taken as stuck.</summary>
    const int StuckMs = 1000;

    readonly object _gate = new();
    readonly List<short> _samples = new();
    /// <summary>Which hold the audio belongs to.</summary>
    int _generation;
    bool _capturing;
    long _startedTicks;
    double _firstAudioMs = -1;
    int _buffers;
    float _peak;
    string? _deviceName;
    Device _device;
    Timer? _closeTimer;
    Timer? _openWatch;
    static bool s_hangingUsed;

    /// <summary>
    /// What one hold captured. Buffers is 0 when the device sent nothing at
    /// all. Wav has the near-silence of a cold start cut from its front;
    /// Seconds is the audio before that cut, and Sound describes it.
    /// </summary>
    public sealed record Capture(byte[] Wav, int Buffers, float Peak, string? Device, double Seconds, SpeechGate.Analysis Sound, double FirstAudioMs);

    /// <summary>Each buffer's level, roughly 0..1, on a background thread.</summary>
    public event Action<float>? Level;

    /// <summary>The first buffer of a hold has arrived (the microphone is delivering), with the hold's number from <see cref="Start"/>; on a background thread.</summary>
    public event Action<int>? FirstAudio;

    /// <summary>The device could not be opened; on a background thread, with a message for the pill.</summary>
    public event Action<string>? Failed;

    public Recorder()
    {
        _device = new Device(this);
    }

    /// <summary>Begins a hold and returns its number.</summary>
    public int Start()
    {
        lock (_gate)
        {
            _samples.Clear();
            int generation = ++_generation;
            _capturing = true;
            _startedTicks = Stopwatch.GetTimestamp();
            _firstAudioMs = -1;
            _buffers = 0;
            _peak = 0;
            _deviceName = null;
            _closeTimer?.Dispose();
            _closeTimer = null;
            if (_device.BusyMs > StuckMs) Replace();
            var device = _device;
            device.Post("open", () => device.Open(generation));
            // The device thread can also get stuck after this check, in a
            // close queued just before this open.
            _openWatch?.Dispose();
            _openWatch = new Timer(_ => Rescue(device, generation), null, StuckMs, Timeout.Infinite);
            return generation;
        }
    }

    /// <summary>The open has not begun after StuckMs: the device thread is stuck, so move to a new one.</summary>
    void Rescue(Device device, int generation)
    {
        lock (_gate)
        {
            if (!_capturing || generation != _generation || device != _device || device.OpenedGeneration >= generation) return;
            Replace();
            var fresh = _device;
            fresh.Post("open", () => fresh.Open(generation));
        }
    }

    /// <summary>Leaves the current device thread to finish (or not) on its own. Under _gate.</summary>
    void Replace()
    {
        var old = _device;
        Log.Write($"microphone thread stuck for {old.BusyMs} ms in {old.BusyWith}; opening the microphone on a new one");
        old.Retire();
        _device = new Device(this);
    }

    bool IsCurrent(int generation, Device device)
    {
        lock (_gate) return _capturing && generation == _generation && device == _device;
    }

    void Opened(int generation, string? name)
    {
        lock (_gate) if (generation == _generation) _deviceName = name;
    }

    void OnSamples(Device device, short[] chunk)
    {
        if (chunk.Length == 0) return;
        device.Heard = true;
        double sum = 0;
        foreach (short s in chunk)
        {
            double f = s / 32768.0;
            sum += f * f;
        }
        // Speech RMS is quiet; scaled for a visible range, as on the Mac.
        float level = (float)Math.Min(1, Math.Sqrt(sum / chunk.Length) * 8);
        bool first;
        int hold;
        lock (_gate)
        {
            if (!_capturing || device != _device) return; // kept open between holds, or left behind
            _samples.AddRange(chunk);
            if (_firstAudioMs < 0) _firstAudioMs = Stopwatch.GetElapsedTime(_startedTicks).TotalMilliseconds;
            first = _buffers++ == 0;
            hold = _generation;
            _peak = Math.Max(_peak, level);
        }
        if (first) FirstAudio?.Invoke(hold);
        Level?.Invoke(level);
    }

    public double DurationSeconds
    {
        get { lock (_gate) return (double)_samples.Count / SampleRate; }
    }

    /// <summary>
    /// Everything captured so far, as a WAV, for a live preview. Always the
    /// whole buffer (see StreamCommit), with a cold start's lead-in cut as in
    /// the final one. Null while nothing in it is loud enough to be speech yet:
    /// a preview of silence would only queue ahead of the real ones.
    /// </summary>
    public byte[]? SnapshotForPreview()
    {
        short[] copy;
        lock (_gate) copy = _samples.ToArray();
        var sound = SpeechGate.Analyze(copy);
        return sound.HasSpeech ? Wav.FromSamples(SpeechGate.TrimLeading(copy, sound), SampleRate) : null;
    }

    Capture MakeCapture(short[] samples, int buffers, float peak, string? device, double firstAudioMs)
    {
        var sound = SpeechGate.Analyze(samples);
        return new Capture(Wav.FromSamples(SpeechGate.TrimLeading(samples, sound), SampleRate), buffers, peak, device,
            (double)samples.Length / SampleRate, sound, firstAudioMs);
    }

    /// <summary>
    /// Stops capture and returns the whole recording. With a tail, keeps
    /// listening that long first: the last word is still on its way from the
    /// device when the keys come up (most of all over Bluetooth). Completes at
    /// once without one. The device is closed, or kept open, in the background.
    /// </summary>
    public async Task<Capture> Stop(int tailMs = 0)
    {
        int generation, released;
        Capture? atRelease = null;
        lock (_gate)
        {
            generation = _generation;
            released = _samples.Count;
            if (_buffers == 0) tailMs = 0; // nothing is coming
            if (tailMs > 0) atRelease = MakeCapture(_samples.ToArray(), _buffers, _peak, _deviceName, _firstAudioMs);
        }
        if (tailMs > 0) await Task.Delay(tailMs);

        short[] samples;
        int buffers;
        float peak;
        string? device;
        double firstAudioMs;
        string summary;
        lock (_gate)
        {
            if (generation != _generation && atRelease is not null)
            {
                // A new hold started during the tail and owns the buffer and the device now.
                Log.Write($"recording: {atRelease.Buffers} buffers; a new hold started during the tail, so it ends at the release");
                return atRelease;
            }
            _capturing = false;
            _openWatch?.Dispose();
            _openWatch = null;
            samples = _samples.ToArray();
            buffers = _buffers;
            peak = _peak;
            device = _deviceName;
            firstAudioMs = _firstAudioMs;
            var sound = SpeechGate.Analyze(samples);
            summary = _buffers == 0
                ? "no audio arrived from the microphone"
                : $"{_buffers} buffers, first after {_firstAudioMs:F0} ms, peak level {_peak:F2}, {sound.VoicedMs} ms of sound, {sound.LeadSilenceMs} ms of silence first"
                  + (tailMs > 0 ? $", {(samples.Length - released) * 1000 / SampleRate} ms in the {tailMs} ms after release" : "");
            var current = _device;
            if (current.WorthKeeping)
            {
                int keepMs = DevicePolicy.KeepOpenMs(current.OpenTookMs);
                summary += $"; the microphone opened in {current.OpenTookMs} ms, so it stays open for {keepMs / 1000} s";
                _closeTimer = new Timer(_ =>
                {
                    lock (_gate)
                    {
                        if (_capturing || current != _device) return;
                        current.Post("close", current.Close);
                    }
                }, null, keepMs, Timeout.Infinite);
            }
            else
            {
                current.Post("close", current.Close);
            }
        }
        Log.Write($"recording: {summary}");
        return MakeCapture(samples, buffers, peak, device, firstAudioMs);
    }

    /// <summary>The microphone and the thread that opens and closes it.</summary>
    sealed class Device
    {
        readonly Recorder _recorder;
        readonly BlockingCollection<(string What, Action Work)> _work = new();
        long _busySince;
        volatile string _busyWith = "";
        IWaveIn? _wave;
        MMDevice? _endpoint;
        TestAudio? _test;
        bool _hanging;
        volatile bool _failed;
        long _openedTicks;
        string? _name;

        /// <summary>The newest hold whose open this thread has begun.</summary>
        public volatile int OpenedGeneration;
        /// <summary>A buffer has arrived since the device opened.</summary>
        public volatile bool Heard;
        /// <summary>How long the last successful open took.</summary>
        public long OpenTookMs;

        public Device(Recorder recorder)
        {
            _recorder = recorder;
            var thread = new Thread(() =>
            {
                foreach (var (what, work) in _work.GetConsumingEnumerable())
                {
                    _busyWith = what;
                    Volatile.Write(ref _busySince, Stopwatch.GetTimestamp());
                    try { work(); }
                    catch (Exception e) { Log.Write($"microphone thread: {e.Message}"); }
                    Volatile.Write(ref _busySince, 0);
                }
            }) { IsBackground = true, Name = "talkflow microphone" };
            // WASAPI's objects are used from this thread and NAudio's capture thread.
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
        }

        public long BusyMs
        {
            get
            {
                long since = Volatile.Read(ref _busySince);
                return since == 0 ? 0 : (long)Stopwatch.GetElapsedTime(since).TotalMilliseconds;
            }
        }

        public string BusyWith => _busyWith;

        public void Post(string what, Action work)
        {
            if (!_work.IsAddingCompleted) _work.Add((what, work));
        }

        /// <summary>Closes the device whenever the stuck call returns, then ends the thread.</summary>
        public void Retire()
        {
            Post("close", Close);
            _work.CompleteAdding();
        }

        bool IsOpen => _wave is not null || _test is not null || _hanging;

        long OpenMs => Volatile.Read(ref _openedTicks) is var t and not 0 ? (long)Stopwatch.GetElapsedTime(t).TotalMilliseconds : 0;

        /// <summary>A real microphone that works, or has only just opened: kept open between holds.</summary>
        public bool WorthKeeping => _wave is not null && !_failed && (Heard || OpenMs < HoldCheck.DeadMs);

        public void Open(int generation)
        {
            OpenedGeneration = generation;
            if (!_recorder.IsCurrent(generation, this)) return; // let go before the device was reached
            if (IsOpen)
            {
                if (WorthKeeping)
                {
                    _recorder.Opened(generation, _name);
                    Log.Write($"microphone still open from the last hold: {_name}");
                    return;
                }
                if (_wave is not null) Log.Write($"closing {_name ?? "the microphone"}: {(_failed ? "it stopped with an error" : $"no audio in {OpenMs} ms")}");
                Close(); // never two devices at once
            }
            var watch = Stopwatch.StartNew();
            Heard = false;
            _failed = false;
            if (TestHooks.SilentMicrophone)
            {
                Log.Write("test: a microphone that opens but never sends audio");
                return;
            }
            if (TestHooks.HangingMicrophone && !s_hangingUsed)
            {
                s_hangingUsed = _hanging = true;
                Log.Write("test: a microphone that sends nothing and never finishes closing");
                return;
            }
            if (TestHooks.AudioFile is { } file)
            {
                // A slow test microphone takes its time to open, then sends a few
                // hundred milliseconds of near-silence before the recording.
                if (TestHooks.SlowMicrophoneMs > 0) Thread.Sleep(TestHooks.SlowMicrophoneMs);
                _test = new TestAudio(file, samples => _recorder.OnSamples(this, samples), TestHooks.SlowMicrophoneMs > 0 ? TestHooks.ColdSilenceMs : 0);
                _test.Start();
                OpenTookMs = watch.ElapsedMilliseconds;
                Log.Write($"test audio: playing {System.IO.Path.GetFileName(file)} instead of the microphone");
                if (TestHooks.SlowMicrophoneMs > 0) Log.Write($"microphone opened in {OpenTookMs} ms: test microphone, {TestHooks.ColdSilenceMs} ms of near-silence first");
                return;
            }
            string description;
            try
            {
                description = Start(OpenWasapi);
            }
            catch (Exception e)
            {
                Log.Write($"WASAPI could not use the default microphone after {watch.ElapsedMilliseconds} ms: {Describe(e)}; trying waveIn");
                try
                {
                    description = Start(OpenWaveIn);
                }
                catch (Exception fallback)
                {
                    Log.Write($"could not open the microphone after {watch.ElapsedMilliseconds} ms: {Describe(fallback)}");
                    if (_recorder.IsCurrent(generation, this)) _recorder.Failed?.Invoke(fallback.Message);
                    return;
                }
            }
            _name = _endpoint?.FriendlyName;
            OpenTookMs = watch.ElapsedMilliseconds;
            Volatile.Write(ref _openedTicks, Stopwatch.GetTimestamp());
            _recorder.Opened(generation, _name);
            Log.Write($"microphone opened in {watch.ElapsedMilliseconds} ms: {description}");
        }

        /// <summary>Opens and starts one kind of device; on failure releases it and throws.</summary>
        string Start(Func<(IWaveIn, string)> open)
        {
            var (wave, description) = open();
            wave.DataAvailable += (_, e) => OnData(e);
            wave.RecordingStopped += (_, e) =>
            {
                if (e.Exception is not { } x) return;
                _failed = true;
                Log.Write($"microphone stopped with an error: {Describe(x)}");
            };
            try
            {
                wave.StartRecording(); // WASAPI initializes the device here
            }
            catch
            {
                try { wave.Dispose(); } catch (Exception e) { Log.Write($"closing the microphone: {e.Message}"); }
                DisposeEndpoint();
                throw;
            }
            _wave = wave;
            return description;
        }

        /// <summary>The default capture device (Settings > Sound > Input), as 16 kHz mono 16-bit, converted by Windows.</summary>
        (IWaveIn, string) OpenWasapi()
        {
            using var devices = new MMDeviceEnumerator();
            var endpoint = devices.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            try
            {
                var capture = new WasapiCapture(endpoint, false, 100);
                var native = capture.WaveFormat; // the device's own format, before ours replaces it
                capture.WaveFormat = new WaveFormat(SampleRate, 16, 1);
                _endpoint = endpoint;
                return (capture, $"{endpoint.FriendlyName} (WASAPI, device format {native.SampleRate} Hz, {native.Channels} ch)");
            }
            catch
            {
                endpoint.Dispose();
                throw;
            }
        }

        static (IWaveIn, string) OpenWaveIn()
        {
            if (WaveInEvent.DeviceCount == 0) throw new InvalidOperationException("No microphone was found.");
            var wave = new WaveInEvent
            {
                DeviceNumber = -1, // WAVE_MAPPER: the Windows default input device
                WaveFormat = new WaveFormat(SampleRate, 16, 1),
                BufferMilliseconds = 50,
                NumberOfBuffers = 4,
            };
            return (wave, "the default microphone (waveIn)");
        }

        void DisposeEndpoint()
        {
            try { _endpoint?.Dispose(); } catch (Exception e) { Log.Write($"releasing the microphone: {e.Message}"); }
            _endpoint = null;
        }

        public void Close()
        {
            var watch = Stopwatch.StartNew();
            Volatile.Write(ref _openedTicks, 0);
            if (_hanging)
            {
                Log.Write("test: closing the hanging microphone, which never returns");
                Thread.Sleep(Timeout.Infinite);
            }
            _test?.Stop();
            _test = null;
            if (_wave is { } wave)
            {
                _wave = null;
                try { wave.StopRecording(); } catch (Exception e) { Log.Write($"stopping the microphone: {e.Message}"); }
                try { wave.Dispose(); } catch (Exception e) { Log.Write($"closing the microphone: {e.Message}"); }
            }
            DisposeEndpoint();
            if (watch.ElapsedMilliseconds > 200) Log.Write($"microphone closed in {watch.ElapsedMilliseconds} ms");
        }

        void OnData(WaveInEventArgs e)
        {
            int count = e.BytesRecorded / 2;
            if (count == 0) return;
            var chunk = new short[count];
            Buffer.BlockCopy(e.Buffer, 0, chunk, 0, count * 2);
            _recorder.OnSamples(this, chunk);
        }
    }

    /// <summary>The message, plus the HRESULT for COM errors, which is what tells WASAPI failures apart.</summary>
    static string Describe(Exception e) =>
        e is System.Runtime.InteropServices.COMException ? $"{e.Message} (0x{e.HResult:X8})" : e.Message;

    /// <summary>
    /// TALKFLOW_TEST_AUDIO: a WAV played in real time in 50 ms buffers, as a
    /// microphone would deliver it, then silence until the hold ends. With a
    /// lead-in, that much near-silence (samples of -1, 0 or 1) comes first, as
    /// from a cold microphone array.
    /// </summary>
    sealed class TestAudio
    {
        readonly short[] _all;
        readonly Action<short[]> _deliver;
        readonly int _leadSamples;
        volatile bool _stopped;

        public TestAudio(string path, Action<short[]> deliver, int leadMs = 0)
        {
            _all = Wav.ReadSamples(System.IO.File.ReadAllBytes(path));
            _deliver = deliver;
            _leadSamples = leadMs * SampleRate / 1000;
        }

        public void Start() => new Thread(Run) { IsBackground = true, Name = "talkflow test audio" }.Start();

        public void Stop() => _stopped = true;

        void Run()
        {
            const int chunk = SampleRate / 20;
            var clock = Stopwatch.StartNew();
            for (int sent = 0; !_stopped; sent += chunk)
            {
                var buffer = new short[chunk];
                if (sent < _leadSamples)
                    for (int i = 0; i < chunk; i++) buffer[i] = (short)((i + sent) % 3 - 1);
                else if (sent - _leadSamples < _all.Length)
                    Array.Copy(_all, sent - _leadSamples, buffer, 0, Math.Min(chunk, _all.Length - (sent - _leadSamples)));
                _deliver(buffer);
                int due = (sent + chunk) * 1000 / SampleRate;
                int wait = due - (int)clock.ElapsedMilliseconds;
                if (wait > 0) Thread.Sleep(wait);
            }
        }
    }
}
