using System.Text.Json;
using Talkflow.Core.Text;
using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>
/// The Mac binary's own answers (windows/tools/make_golden.py), for every
/// transcript in tests/golden/corpus.json: every emoji name and alias, spoken
/// commands, lists, emails, corrections and casing.
/// </summary>
public class GoldenTests
{
    sealed record RenderCase(string input, string expected);
    sealed record SentenceCase(string input, string[] sentences);

    static T Load<T>(string name) =>
        JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "golden", name)))!;

    [Fact]
    public void RenderMatchesTheMacAppOnEveryCorpusInput()
    {
        var cases = Load<List<RenderCase>>("render.json");
        Assert.True(cases.Count > 800);
        var failures = cases
            .Select(c => (c.input, c.expected, got: Render.Text(c.input, "", structure: true)))
            .Where(c => c.got != c.expected)
            .Select(c => $"{JsonSerializer.Serialize(c.input)}\n  mac:     {JsonSerializer.Serialize(c.expected)}\n  windows: {JsonSerializer.Serialize(c.got)}")
            .ToList();
        Assert.True(failures.Count == 0, $"{failures.Count} of {cases.Count} differ:\n" + string.Join("\n", failures));
    }

    [Fact]
    public void SentenceSplitsMatchNLTokenizer()
    {
        var cases = Load<List<SentenceCase>>("sentences.json");
        var failures = cases
            .Select(c => (c.input, c.sentences, got: SentenceSplitter.Split(c.input).Select(Chars.Trim).Where(s => s.Length > 0).ToArray()))
            .Where(c => !c.got.SequenceEqual(c.sentences))
            .Select(c => $"{JsonSerializer.Serialize(c.input)}\n  mac:     {JsonSerializer.Serialize(c.sentences)}\n  windows: {JsonSerializer.Serialize(c.got)}")
            .ToList();
        Assert.True(failures.Count == 0, $"{failures.Count} of {cases.Count} differ:\n" + string.Join("\n", failures));
    }
}
