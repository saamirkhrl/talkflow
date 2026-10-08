using System.Net;
using System.Reflection;
using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>The install counter (docs/telemetry.md), against a fake network: nothing is sent.</summary>
public class InstallCounterTests
{
    static readonly Uri Url = new("https://counter.invalid/api/install");

    sealed class Flag : IInstallFlag
    {
        public bool InstallCounted { get; set; }
    }

    /// <summary>Records every request and answers with a status, an exception, or never (until cancelled).</summary>
    sealed class FakeNetwork : HttpMessageHandler
    {
        public readonly List<HttpRequestMessage> Requests = new();
        public HttpStatusCode? Status = HttpStatusCode.NoContent;
        public bool Hang;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Requests.Add(request);
            if (Hang) await Task.Delay(Timeout.Infinite, token);
            if (Status is not { } status) throw new HttpRequestException("no connection");
            return new HttpResponseMessage(status);
        }
    }

    static Task<bool> Run(FakeNetwork network, Flag flag, Uri? url = null, bool testHooks = false, string? ci = null) =>
        InstallCounter.CountOnce(url ?? Url, flag, testHooks, ci, new HttpMessageInvoker(network), TimeSpan.FromMilliseconds(200));

    [Fact]
    public void OnlyACompleteHttpsUrlIsUsed()
    {
        Assert.Null(InstallCounter.ParseUrl(null));
        Assert.Null(InstallCounter.ParseUrl(""));
        Assert.Null(InstallCounter.ParseUrl("   "));
        Assert.Null(InstallCounter.ParseUrl("http://counter.invalid/api/install"));
        Assert.Null(InstallCounter.ParseUrl("/api/install"));
        Assert.Equal(Url, InstallCounter.ParseUrl("https://counter.invalid/api/install"));
    }

    [Fact]
    public void ABuildWithoutTheUrlHasNone()
    {
        // The tests and every local build are compiled without -p:TalkflowTelemetryUrl.
        Assert.Null(InstallCounter.ConfiguredUrl(typeof(InstallCounter).Assembly));
        Assert.Null(InstallCounter.ConfiguredUrl(Assembly.GetExecutingAssembly()));
    }

    [Fact]
    public void TheRequestIsAnEmptyPost()
    {
        using var request = InstallCounter.Request(Url);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(Url, request.RequestUri);
        Assert.Null(request.Content);
        Assert.Empty(request.Headers);
    }

    [Fact]
    public async Task SendsExactlyOnceAndOnlyCountsA2xx()
    {
        var network = new FakeNetwork();
        var flag = new Flag();
        Assert.True(await Run(network, flag));
        Assert.True(flag.InstallCounted);
        var sent = Assert.Single(network.Requests);
        Assert.Equal(HttpMethod.Post, sent.Method);
        Assert.Null(sent.Content);
        Assert.Empty(sent.Headers);

        // Later launches send nothing.
        Assert.True(await Run(network, flag));
        Assert.Single(network.Requests);
    }

    [Theory]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.MovedPermanently)]
    [InlineData(HttpStatusCode.MethodNotAllowed)]
    public async Task AFailedAnswerIsRetriedNextLaunch(HttpStatusCode status)
    {
        var network = new FakeNetwork { Status = status };
        var flag = new Flag();
        Assert.False(await Run(network, flag));
        Assert.False(flag.InstallCounted);

        network.Status = HttpStatusCode.OK;
        Assert.True(await Run(network, flag));
        Assert.True(flag.InstallCounted);
        Assert.Equal(2, network.Requests.Count);
    }

    [Fact]
    public async Task NoConnectionOrATimeoutLeavesItUncounted()
    {
        var flag = new Flag();
        Assert.False(await Run(new FakeNetwork { Status = null }, flag));
        Assert.False(flag.InstallCounted);
        Assert.False(await Run(new FakeNetwork { Hang = true }, flag));
        Assert.False(flag.InstallCounted);
    }

    [Fact]
    public async Task NeverSendsWithoutAUrlInTestsOrOnCI()
    {
        var network = new FakeNetwork();
        var flag = new Flag();
        Assert.False(await InstallCounter.CountOnce(null, flag, false, null, new HttpMessageInvoker(network)));
        Assert.False(await Run(network, flag, testHooks: true));
        Assert.False(await Run(network, flag, ci: "true"));
        Assert.Empty(network.Requests);
        Assert.False(flag.InstallCounted);
        // An empty CI variable is not CI.
        Assert.True(await Run(network, flag, ci: ""));
    }

    [Fact]
    public void TheAppHandlerKeepsNoCookiesAndFollowsNoRedirects()
    {
        using var handler = Assert.IsType<SocketsHttpHandler>(InstallCounter.Handler());
        Assert.False(handler.UseCookies);
        Assert.False(handler.AllowAutoRedirect);
    }
}
