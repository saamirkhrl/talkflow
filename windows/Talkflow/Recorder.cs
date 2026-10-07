using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using NAudio.Wave;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// Captures the default microphone into memory as 16 kHz mono 16-bit PCM and
/// hands back a complete WAV on demand (Recorder.swift). Audio never touches
/// the disk. Windows' audio engine converts to 16 kHz for us.
/// </summary>
sealed class Recorder
{
    public const int SampleRate = 16000;

    readonly object _gate = new();
    readonly List<short> _samples = new();
    WaveInEvent? _wave;
    TestAudio? _test;

    /// <summary>Each buffer's level, roughly 0..1, on a background thread.</summary>
    public event Action<float>? Level;

    public void Start()
    {
        lock (_gate) _samples.Clear();
        if (TestHooks.AudioFile is { } file)
        {
            _test = new TestAudio(file, OnSamples);
            _test.Start();
            return;
        }
        if (WaveInEvent.DeviceCount == 0) throw new InvalidOperationException("No microphone was found.");
        var wave = new WaveInEvent
        {
            DeviceNumber = -1, // WAVE_MAPPER: the Windows default input device
            WaveFormat = new WaveFormat(SampleRate, 16, 1),
            BufferMilliseconds = 50,
            NumberOfBuffers = 4,
        };
        wave.DataAvailable += OnData;
        try
        {
            wave.StartRecording();
        }
        catch
        {
            wave.Dispose();
            throw;
        }
        _wave = wave;
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        int count = e.BytesRecorded / 2;
        if (count == 0) return;
        var chunk = new short[count];
        Buffer.BlockCopy(e.Buffer, 0, chunk, 0, count * 2);
        OnSamples(chunk);
    }

    void OnSamples(short[] chunk)
    {
        int count = chunk.Length;
        if (count == 0) return;
        double sum = 0;
        foreach (short s in chunk)
        {
            double f = s / 32768.0;
            sum += f * f;
        }
        lock (_gate) _samples.AddRange(chunk);
        // Speech RMS is quiet; scaled for a visible range, as on the Mac.
        Level?.Invoke((float)Math.Min(1, Math.Sqrt(sum / count) * 8));
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

    /// <summary>Stops capture and returns the whole recording.</summary>
    public byte[] Stop()
    {
        _test?.Stop();
        _test = null;
        var wave = _wave;
        _wave = null;
        if (wave is not null)
        {
            try { wave.StopRecording(); } catch (Exception e) { Log.Write($"stopping the microphone: {e.Message}"); }
            wave.DataAvailable -= OnData;
            wave.Dispose();
        }
        return SnapshotWav();
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
