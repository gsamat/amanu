using Amanu.Core.Configuration;

namespace Amanu.Core.Tests;

public sealed class SetupChoiceTests
{
    [Theory]
    [InlineData(false, false, false, "auto")]
    [InlineData(true, false, true, "cloud")]
    [InlineData(false, true, true, "local")]
    [InlineData(true, true, true, "auto")]
    public void Switches_preserve_the_available_transcription_modes(
        bool cloud, bool local, bool enabled, string engine)
    {
        var choice = SetupChoice.FromSwitches(cloud, local);
        Assert.Equal(enabled, choice.Enabled);
        Assert.Equal(engine, choice.Engine);
    }

    [Theory]
    [InlineData(true, "cloud", true, false)]
    [InlineData(true, "local", false, true)]
    [InlineData(true, "auto", true, true)]
    [InlineData(false, "auto", false, false)]
    public void Stored_mode_restores_the_same_switches(
        bool enabled, string engine, bool cloud, bool local)
    {
        var choice = SetupChoice.FromSettings(enabled, engine);
        Assert.Equal(cloud, choice.Cloud);
        Assert.Equal(local, choice.Local);
    }
}
