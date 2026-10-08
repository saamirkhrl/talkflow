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
/// A device that delivered audio stays open for a few seconds after a hold:
/// a Bluetooth headset takes about a second to switch to its microphone, and
/// a second hold right after the first should not lose that second again.
/// </summary>
sealed class Recorder
{
    public const int SampleRate = 16000;
    /// <summary>How long a device that worked stays open after a hold.</summary>
    const int KeepOpenMs = 4000;
    /// <summary>A device call still running this long when a hold starts is taken as stuck.</summary>
    const int StuckMs = 1000;
    /// <summary>A device open this long without a single buffer is given up on.</summary>
    const int DeadMs = 1500;

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

    /// <summary>What one hold captured. Buffers is 0 when the device sent nothing at all.</summary>
    public sealed record Capture(byte[] Wav, int Buffers, float Peak, string? Device);

    /// <summary>Each buffer's level, roughly 0..1, on a background thread.</summary>
    public event Action<float>? Level;

    /// <summary>The device could not be opened; on a background thread, with a message for the pill.</summary>
    public event Action<string>? Failed;

    public Recorder()
    {
        _device = new Device(this);
    }

    public void Start()
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
        lock (_gate)
        {
            if (!_capturing || device != _device) return; // kept open between holds, or left behind
            _samples.AddRange(chunk);
            if (_firstAudioMs < 0) _firstAudioMs = Stopwatch.GetElapsedTime(_startedTicks).TotalMilliseconds;
            _buffers++;
            _peak = Math.Max(_peak, level);
        }
        Level?.Invoke(level);
    }

    public double DurationSeconds
    {
        get { lock (_gate) return (double)_samples.Count / SampleRate; }
    }

    /// <summary>Everything captured so far, as a WAV. Always the whole buffer (see StreamCommit).</summary>
    public byte[] SnapshotWav()
    {
        short[] copy;
        lock (_gate) copy = _samples.ToArray();
        return Wav.FromSamples(copy, SampleRate);
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
            if (tailMs > 0) atRelease = new Capture(Wav.FromSamples(_samples.ToArray(), SampleRate), _buffers, _peak, _deviceName);
        }
        if (tailMs > 0) await Task.Delay(tailMs);

        short[] samples;
        int buffers;
        float peak;
        string? device;
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
            summary = _buffers == 0
                ? "no audio arrived from the microphone"
                : $"{_buffers} buffers, first after {_firstAudioMs:F0} ms, peak level {_peak:F2}"
                  + (tailMs > 0 ? $", {(samples.Length - released) * 1000 / SampleRate} ms in the {tailMs} ms after release" : "");
            var current = _device;
            if (current.WorthKeeping)
            {
                _closeTimer = new Timer(_ =>
                {
                    lock (_gate)
                    {
                        if (_capturing || current != _device) return;
                        current.Post("close", current.Close);
                    }
                }, null, KeepOpenMs, Timeout.Infinite);
            }
            else
            {
                current.Post("close", current.Close);
            }
        }
        Log.Write($"recording: {summary}");
        return new Capture(Wav.FromSamples(samples, SampleRate), buffers, peak, device);
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
        public bool WorthKeeping => _wave is not null && !_failed && (Heard || OpenMs < DeadMs);

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
                _test = new TestAudio(file, samples => _recorder.OnSamples(this, samples));
                _test.Start();
                Log.Write($"test audio: playing {System.IO.Path.GetFileName(file)} instead of the microphone");
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
    /// microphone would deliver it, then silence until the hold ends.
    /// </summary>
    sealed class TestAudio
    {
        readonly short[] _all;
        readonly Action<short[]> _deliver;
        volatile bool _stopped;

        public TestAudio(string path, Action<short[]> deliver)
        {
            _all = Wav.ReadSamples(System.IO.File.ReadAllBytes(path));
            _deliver = deliver;
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
                if (sent < _all.Length) Array.Copy(_all, sent, buffer, 0, Math.Min(chunk, _all.Length - sent));
                _deliver(buffer);
                int due = (sent + chunk) * 1000 / SampleRate;
                int wait = due - (int)clock.ElapsedMilliseconds;
                if (wait > 0) Thread.Sleep(wait);
            }
        }
    }
}
