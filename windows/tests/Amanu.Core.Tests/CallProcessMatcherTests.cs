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
