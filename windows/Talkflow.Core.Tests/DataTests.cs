using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>The update check (runUpdaterCases) and the user-data files the Mac and Windows apps share.</summary>
public class DataTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "talkflow-tests-" + Guid.NewGuid().ToString("N"));

    public DataTests() => Directory.CreateDirectory(_dir);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void VersionOrder()
    {
        Assert.True(Updates.IsNewer("0.2.0", "0.1.0"));
        Assert.True(Updates.IsNewer("0.10.0", "0.9.2"));
        Assert.False(Updates.IsNewer("0.1", "0.1.0"));
        Assert.False(Updates.IsNewer("0.1.0", "0.2.0"));
    }

    const string Release = """
        {"tag_name":"v0.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/x/y/releases/v0.2.0","assets":[
          {"name":"talkflow-macos.zip","browser_download_url":"https://e/talkflow-macos.zip"},
          {"name":"talkflow-windows-x64-setup.exe","browser_download_url":"https://e/x64.exe"},
          {"name":"talkflow-windows-arm64-setup.exe","browser_download_url":"https://e/arm64.exe"}]}
        """;

    [Fact]
    public void PicksThisPlatformsInstaller()
    {
        var x64 = Updates.Parse(Release, "x64");
        Assert.Equal("0.2.0", x64?.Version);
        Assert.Equal("https://e/x64.exe", x64?.InstallerUrl);
        Assert.Equal("https://e/arm64.exe", Updates.Parse(Release, "arm64")?.InstallerUrl);
        // Arm falls back to the x64 installer, which Windows on Arm emulates.
        var onlyX64 = Release.Replace("""{"name":"talkflow-windows-arm64-setup.exe","browser_download_url":"https://e/arm64.exe"}""", """{"name":"notes.txt","browser_download_url":"https://e/n"}""");
        Assert.Equal("https://e/x64.exe", Updates.Parse(onlyX64, "arm64")?.InstallerUrl);
        Assert.Null(Updates.Parse("""{"tag_name":"v1.0.0","assets":[{"name":"talkflow-macos.zip","browser_download_url":"https://e/a.zip"}]}""", "x64"));
        Assert.Null(Updates.Parse("""{"tag_name":"v1.0.0","prerelease":true,"assets":[{"name":"talkflow-windows-x64-setup.exe","browser_download_url":"https://e/a.exe"}]}""", "x64"));
        Assert.Null(Updates.Parse("not json", "x64"));
    }

    [Fact]
    public void LatestVersionEvenWithoutAWindowsBuild()
    {
        // v0.1.3 shipped the Mac build only: no Windows update, but the app can name the version.
        const string macOnly = """{"tag_name":"v0.1.3","assets":[{"name":"talkflow-macos.zip","browser_download_url":"https://e/a.zip"}]}""";
        Assert.Null(Updates.Parse(macOnly, "x64"));
        Assert.Equal("0.1.3", Updates.LatestVersion(macOnly));
        Assert.Equal("0.1.4", Updates.LatestVersion("""{"schema":1,"version":"0.1.4","platforms":{"macos":{},"windows":{},"linux":{}}}"""));
        Assert.Null(Updates.LatestVersion("""{"schema":2,"version":"9.0.0"}"""));
        Assert.Null(Updates.LatestVersion("not json"));
        Assert.Null(Updates.LatestVersion("[]"));
    }

    static readonly string Sha = new('a', 64);

    static string Manifest(string windows) => """
        {"schema":1,"version":"0.3.0","tag":"v0.3.0","notesUrl":"https://e/notes","platforms":{
          "macos":{"universal":{"update":{"name":"talkflow-macos.zip","url":"https://e/m.zip","sha256":"SHA","size":1}}},
          "windows":WINDOWS,
          "linux":{},
          "plan9":{"x":{}}}}
        """.Replace("WINDOWS", windows).Replace("SHA", Sha);

    [Fact]
    public void ReadsTheWindowsEntryOfTheReleaseManifest()
    {
        var both = Manifest("""{"x64":{"update":{"name":"talkflow-windows-x64-setup.exe","url":"https://e/x64.exe","sha256":"SHA","size":42}},"arm64":{"update":{"name":"talkflow-windows-arm64-setup.exe","url":"https://e/arm64.exe","sha256":"SHA","size":43}}}""");
        var x64 = Updates.ParseManifest(both, "x64");
        Assert.Equal("0.3.0", x64?.Version);
        Assert.Equal("https://e/x64.exe", x64?.InstallerUrl);
        Assert.Equal(Sha, x64?.Sha256);
        Assert.Equal(42, x64?.Size);
        Assert.Equal("https://e/arm64.exe", Updates.ParseManifest(both, "arm64")?.InstallerUrl);

        var onlyX64 = Manifest("""{"x64":{"update":{"name":"talkflow-windows-x64-setup.exe","url":"https://e/x64.exe","sha256":"SHA","size":42}}}""");
        Assert.Equal("https://e/x64.exe", Updates.ParseManifest(onlyX64, "arm64")?.InstallerUrl);

        // The Mac release went out before the Windows installers were attached.
        Assert.Null(Updates.ParseManifest(Manifest("{}"), "x64"));
        // No checksum, no install.
        Assert.Null(Updates.ParseManifest(Manifest("""{"x64":{"update":{"url":"https://e/x64.exe"}}}"""), "x64"));
        Assert.Null(Updates.ParseManifest(Manifest("{}").Replace("\"schema\":1", "\"schema\":2"), "x64"));
        Assert.Null(Updates.ParseManifest("[]", "x64"));
        Assert.Null(Updates.ParseManifest("not json", "x64"));
    }

    [Fact]
    public void ReadsAStatsFileTheMacWrote()
    {
        var path = Path.Combine(_dir, "stats.json");
        File.WriteAllText(path, """{"totalWords":1200,"totalSessions":30,"totalSpeakingSeconds":600.5,"dailyWordCounts":{"2026-10-04":100,"2026-10-05":50}}""");
        var store = new StatsStore(path, () => new DateTime(2026, 10, 5, 12, 0, 0));
        var snapshot = store.Take();
        Assert.Equal(1200, snapshot.TotalWords);
        Assert.Equal(30, snapshot.TotalSessions);
        Assert.Equal(50, snapshot.TodayWords);
        Assert.Equal(2, snapshot.DayStreak);
        Assert.Equal(119, snapshot.AverageWpm);

        store.RecordSession("three more words", 2);
        var json = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Assert.Equal(new[] { "dailyWordCounts", "totalSessions", "totalSpeakingSeconds", "totalWords" }, json.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal(1203, (long)json["totalWords"]!);
        Assert.Equal(53, (long)json["dailyWordCounts"]!["2026-10-05"]!);
        Assert.Equal(602.5, (double)json["totalSpeakingSeconds"]!);
    }

    [Fact]
    public void WritesEveryStatsKeyEvenWhenNew()
    {
        var path = Path.Combine(_dir, "new", "stats.json");
        new StatsStore(path).RecordSession("hello there", 1.5);
        var json = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Assert.Equal(4, json.Count);
    }

    [Fact]
    public void SettingsKeepTheMacSchemaAndUnknownKeys()
    {
        var path = Path.Combine(_dir, "settings.json");
        File.WriteAllText(path, """
            {
              "aiPolish" : true,
              "learnedWords" : ["Siobhan", "Kubernetes"],
              "typeWhileSpeaking" : 1,
              "writingStyle" : "casual"
            }
            """);
        var settings = new SettingsStore(path);
        Assert.True(settings.TypeWhileSpeaking);
        Assert.True(settings.AccurateFinalPass); // default
        Assert.Equal(Text.WritingStyle.Casual, settings.WritingStyle);
        Assert.Equal(new[] { "Siobhan", "Kubernetes" }, settings.LearnedWords);

        settings.ClaudeModel = "claude-haiku-4-5";
        settings.BackUp();
        var json = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Assert.Equal(SettingsStore.SettingKeys.OrderBy(k => k, StringComparer.Ordinal), json.Select(p => p.Key));
        Assert.True((bool)json["aiPolish"]!); // a Mac-only setting survives untouched
        Assert.Equal("claude-haiku-4-5", (string)json["claudeModel"]!);
        Assert.Equal("Grid", (string)json["dashboardChart"]!);
    }

    [Fact]
    public void TimeSaved()
    {
        Assert.Equal(new[] { ("14", "h"), ("39", "min") }, StatsStore.TimeSavedParts(879));
        Assert.Equal(new[] { ("2", "d"), ("18", "h") }, StatsStore.TimeSavedParts(4000));
        Assert.Equal(new[] { ("0", "min") }, StatsStore.TimeSavedParts(0));
    }

    [Fact]
    public void WavHeader()
    {
        var wav = Wav.FromSamples(new short[] { 1, -1, 300 }, 16000);
        Assert.Equal(44 + 6, wav.Length);
        Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wav, 0, 4));
        Assert.Equal(36 + 6, BitConverter.ToInt32(wav, 4));
        Assert.Equal(16000, BitConverter.ToInt32(wav, 24));
        Assert.Equal(6, BitConverter.ToInt32(wav, 40));
    }

    [Fact]
    public void WavReadsBackWhatItWrote()
    {
        var samples = new short[] { 1, -1, 300, short.MinValue, short.MaxValue };
        Assert.Equal(samples, Wav.ReadSamples(Wav.FromSamples(samples, 16000)));
    }

    [Fact]
    public void WavSkipsOtherChunksAndRefusesOtherFormats()
    {
        var plain = Wav.FromSamples(new short[] { 7, 8 }, 16000);
        // A LIST chunk (odd size, padded) between fmt and data, as many tools write.
        var list = new byte[] { (byte)'L', (byte)'I', (byte)'S', (byte)'T', 3, 0, 0, 0, 1, 2, 3, 0 };
        var withList = plain[..36].Concat(list).Concat(plain[36..]).ToArray();
        Assert.Equal(new short[] { 7, 8 }, Wav.ReadSamples(withList));

        var stereo = (byte[])plain.Clone();
        stereo[22] = 2;
        Assert.Throws<InvalidDataException>(() => Wav.ReadSamples(stereo));
        Assert.Throws<InvalidDataException>(() => Wav.ReadSamples(new byte[] { 1, 2, 3 }));
    }
}
