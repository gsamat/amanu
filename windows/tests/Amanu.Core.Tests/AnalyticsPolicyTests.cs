using Amanu.Core.Analytics;

namespace Amanu.Core.Tests;

public sealed class AnalyticsPolicyTests
{
    [Theory]
    [InlineData(60, "under_5m")]
    [InlineData(600, "5_15m")]
    [InlineData(4_000, "1_2h")]
    [InlineData(8_000, "over_2h")]
    public void Duration_is_coarsened_before_it_can_leave_the_machine(int seconds, string expected) =>
        Assert.Equal(expected, AnalyticsPolicy.DurationBucket(seconds));

    [Fact]
    public void Sanitizer_drops_content_and_replaces_unknown_choices()
    {
        var result = AnalyticsPolicy.Sanitize(new Dictionary<string, object?>
        {
            ["engine"] = "private/model-name",
            ["trigger"] = "manual",
            ["reason"] = "no_network",
            ["path"] = "C:\\Secret\\meeting.wav",
            ["api_key"] = "secret",
        });

        Assert.Equal("custom", result["engine"]);
        Assert.Equal("manual", result["trigger"]);
        Assert.Equal("no_network", result["reason"]);
        Assert.DoesNotContain("path", result.Keys);
        Assert.DoesNotContain("api_key", result.Keys);
    }
}
