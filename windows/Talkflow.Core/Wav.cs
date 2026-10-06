namespace Talkflow.Core;

/// <summary>A canonical 44-byte RIFF/WAVE header plus 16-bit mono samples, built in memory (Recorder.swift).</summary>
public static class Wav
{
    public static byte[] FromSamples(ReadOnlySpan<short> samples, int sampleRate)
    {
        const int bytesPerSample = 2;
        int dataBytes = samples.Length * bytesPerSample;
        var data = new byte[44 + dataBytes];
        using var stream = new MemoryStream(data);
        using var w = new BinaryWriter(stream);
        w.Write("RIFF"u8);
        w.Write(36 + dataBytes);
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16);                          // PCM header length
        w.Write((short)1);                    // format: PCM
        w.Write((short)1);                    // channels
        w.Write(sampleRate);
        w.Write(sampleRate * bytesPerSample); // byte rate
        w.Write((short)bytesPerSample);       // block align
        w.Write((short)16);                   // bits per sample
        w.Write("data"u8);
        w.Write(dataBytes);
        foreach (var s in samples) w.Write(s);
        return data;
    }
}
