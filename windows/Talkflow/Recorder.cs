using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
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
/// Opening and closing the device happen on a thread of their own, never on
/// the UI thread: waveInOpen, waveInReset and waveInClose can block for
/// seconds on some drivers (a Bluetooth headset switching to its microphone
/// profile, for one), which would freeze the pill and the tray. Start and
/// Stop return at once; a hold's audio is whatever arrived between them.
/// </summary>
sealed class Recorder
{
    public const int SampleRate = 16000;

    readonly object _gate = new();
    readonly List<short> _samples = new();
    readonly BlockingCollection<Action> _device = new();
    /// <summary>Which hold the audio belongs to; data from an older device is dropped.</summary>
    int _generation;
    bool _capturing;
    long _startedTicks;
    double _firstAudioMs = -1;
    int _buffers;
    float _peak;
    string? _deviceName;

    /// <summary>What one hold captured. Buffers is 0 when the device sent nothing at all.</summary>
    public sealed record Capture(byte[] Wav, int Buffers, float Peak, string? Device);

    /// <summary>Each buffer's level, roughly 0..1, on a background thread.</summary>
    public event Action<float>? Level;

    /// <summary>The device could not be opened; on a background thread, with a message for the pill.</summary>
    public event Action<string>? Failed;

    public Recorder()
    {
        var thread = new Thread(() =>
        {
            foreach (var work in _device.GetConsumingEnumerable())
            {
                try { work(); }
                catch (Exception e) { Log.Write($"microphone thread: {e.Message}"); }
            }
        }) { IsBackground = true, Name = "talkflow microphone" };
        // WASAPI's objects are used from this thread and NAudio's capture thread.
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    public void Start()
    {
        int generation;
        lock (_gate)
        {
            _samples.Clear();
            generation = ++_generation;
            _capturing = true;
            _startedTicks = Stopwatch.GetTimestamp();
            _firstAudioMs = -1;
            _buffers = 0;
            _peak = 0;
            _deviceName = null;
        }
        _device.Add(() => Open(generation));
    }

    IWaveIn? _wave;
    MMDevice? _endpoint;
    TestAudio? _test;

    void Open(int generation)
    {
        if (!IsCurrent(generation)) return; // let go before the device was reached
        Close(); // never two devices at once
        var watch = Stopwatch.StartNew();
        if (TestHooks.SilentMicrophone)
        {
            Log.Write("test: a microphone that opens but never sends audio");
            return;
        }
        if (TestHooks.AudioFile is { } file)
        {
            _test = new TestAudio(file, samples => OnSamples(generation, samples));
            _test.Start();
            Log.Write($"test audio: playing {System.IO.Path.GetFileName(file)} instead of the microphone");
            return;
        }
        string description;
        try
        {
            description = Start(generation, OpenWasapi);
        }
        catch (Exception e)
        {
            Log.Write($"WASAPI could not use the default microphone after {watch.ElapsedMilliseconds} ms: {Describe(e)}; trying waveIn");
            try
            {
                description = Start(generation, OpenWaveIn);
            }
            catch (Exception fallback)
            {
                Log.Write($"could not open the microphone after {watch.ElapsedMilliseconds} ms: {Describe(fallback)}");
                if (IsCurrent(generation)) Failed?.Invoke(fallback.Message);
                return;
            }
        }
        string? name = _endpoint?.FriendlyName;
        lock (_gate) if (generation == _generation) _deviceName = name;
        Log.Write($"microphone opened in {watch.ElapsedMilliseconds} ms: {description}");
    }

    /// <summary>Opens and starts one kind of device; on failure releases it and throws.</summary>
    string Start(int generation, Func<(IWaveIn, string)> open)
    {
        var (wave, description) = open();
        wave.DataAvailable += (_, e) => OnData(generation, e);
        wave.RecordingStopped += (_, e) => { if (e.Exception is { } x) Log.Write($"microphone stopped with an error: {Describe(x)}"); };
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

    /// <summary>The message, plus the HRESULT for COM errors, which is what tells WASAPI failures apart.</summary>
    static string Describe(Exception e) =>
        e is System.Runtime.InteropServices.COMException ? $"{e.Message} (0x{e.HResult:X8})" : e.Message;

    void DisposeEndpoint()
    {
        try { _endpoint?.Dispose(); } catch (Exception e) { Log.Write($"releasing the microphone: {e.Message}"); }
        _endpoint = null;
    }

    void Close()
    {
        var watch = Stopwatch.StartNew();
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

    bool IsCurrent(int generation)
    {
        lock (_gate) return _capturing && generation == _generation;
    }

    void OnData(int generation, WaveInEventArgs e)
    {
        int count = e.BytesRecorded / 2;
        if (count == 0) return;
        var chunk = new short[count];
        Buffer.BlockCopy(e.Buffer, 0, chunk, 0, count * 2);
        OnSamples(generation, chunk);
    }

    void OnSamples(int generation, short[] chunk)
    {
        if (chunk.Length == 0) return;
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
            if (!_capturing || generation != _generation) return;
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

    /// <summary>Stops capture and returns the whole recording. The device is closed in the background.</summary>
    public Capture Stop()
    {
        string summary;
        int buffers;
        float peak;
        string? device;
        lock (_gate)
        {
            _capturing = false;
            buffers = _buffers;
            peak = _peak;
            device = _deviceName;
            summary = _buffers == 0
                ? "no audio arrived from the microphone"
                : $"{_buffers} buffers, first after {_firstAudioMs:F0} ms, peak level {_peak:F2}";
        }
        Log.Write($"recording: {summary}");
        _device.Add(Close);
        return new Capture(SnapshotWav(), buffers, peak, device);
    }

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
