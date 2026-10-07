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

    /// <summary>
    /// The samples of a 16-bit mono PCM WAV (the test audio source plays one).
    /// Walks the RIFF chunks, so extra chunks such as LIST are fine; any other
    /// format is refused rather than played as noise.
    /// </summary>
    public static short[] ReadSamples(byte[] wav)
    {
        if (wav.Length < 12 || !wav.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !wav.AsSpan(8, 4).SequenceEqual("WAVE"u8))
            throw new InvalidDataException("not a RIFF/WAVE file");
        bool pcm16Mono = false;
        for (int at = 12; at + 8 <= wav.Length;)
        {
            var id = wav.AsSpan(at, 4);
            int size = BitConverter.ToInt32(wav, at + 4);
            int body = at + 8;
            if (size < 0 || body + size > wav.Length) size = wav.Length - body;
            if (id.SequenceEqual("fmt "u8) && size >= 16)
            {
                short format = BitConverter.ToInt16(wav, body), channels = BitConverter.ToInt16(wav, body + 2), bits = BitConverter.ToInt16(wav, body + 14);
                pcm16Mono = format == 1 && channels == 1 && bits == 16;
            }
            else if (id.SequenceEqual("data"u8))
            {
                if (!pcm16Mono) throw new InvalidDataException("only 16-bit mono PCM is supported");
                var samples = new short[size / 2];
                Buffer.BlockCopy(wav, body, samples, 0, samples.Length * 2);
                return samples;
            }
            at = body + size + (size & 1);
        }
        throw new InvalidDataException("no data chunk");
    }
}
