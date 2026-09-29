using Amanu.Core.Recording;

namespace Amanu.Core.Tests;

public sealed class CallProcessMatcherTests
{
    [Theory]
    [InlineData("Zoom", "Zoom.exe")]
    [InlineData("zoom.exe", "Zoom.exe")]
    [InlineData(@"C:\Program Files\Zoom\bin\Zoom.exe", "Zoom.exe")]
    public void MatchesConfiguredProcessWithoutCaseSensitivity(string observed, string expected)
    {
        var matcher = new CallProcessMatcher(["Zoom.exe", "ms-teams.exe"], []);

        Assert.Equal(expected, matcher.Match(observed));
    }

    [Fact]
    public void IgnoreListWinsOverCallList()
    {
        var matcher = new CallProcessMatcher(["chrome.exe"], ["Chrome"]);

        Assert.Null(matcher.Match(@"C:\Program Files\Google\Chrome\Application\chrome.exe"));
    }

    [Fact]
    public void ReturnsNullForUnconfiguredProcess()
    {
        var matcher = new CallProcessMatcher(["Zoom.exe"], []);

        Assert.Null(matcher.Match("notepad.exe"));
    }
}

public sealed class CallProcessMatcherEdgeTests
{
    [Fact]
    public void An_empty_list_means_any_app_but_never_amanu_itself()
    {
        var matcher = new CallProcessMatcher([], ["obs64.exe"]);

        Assert.Equal("anything.exe", matcher.Match("anything.exe"));
        Assert.Null(matcher.Match("Amanu.exe"));
        Assert.Null(matcher.Match("obs64"));
    }
}
