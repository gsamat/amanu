using Amanu.Core.Configuration;

namespace Amanu.Core.Tests;

public sealed class SetupChoiceTests
{
    [Theory]
    [InlineData(false, false, false, "auto")]
    [InlineData(true, false, true, "openai")]
    [InlineData(false, true, true, "whisper")]
    [InlineData(true, true, true, "auto")]
    public void Switches_are_written_in_the_engine_vocabulary(bool cloud, bool local, bool enabled, string engine)
    {
        var choice = new SetupChoice(cloud, local, "openai", "whisper");
        Assert.Equal(enabled, choice.Enabled);
        Assert.Equal(engine, choice.Engine);
    }

    [Theory]
    [InlineData(true, "assemblyai", true, false)]
    [InlineData(true, "gigaam", false, true)]
    [InlineData(true, "auto", true, true)]
    [InlineData(true, "something-else", true, true)]
    [InlineData(false, "auto", false, false)]
    public void Stored_engine_restores_the_same_switches(bool enabled, string engine, bool cloud, bool local)
    {
        var choice = SetupChoice.Read(enabled, engine, "assemblyai", "parakeet");
        Assert.Equal(cloud, choice.Cloud);
        Assert.Equal(local, choice.Local);
    }

    [Fact]
    public void A_named_engine_is_also_the_card_that_is_selected()
    {
        var choice = SetupChoice.Read(true, "gigaam", "openai", "parakeet");
        Assert.Equal("gigaam", choice.LocalEngine);
        Assert.Equal("openai", choice.Provider);
    }
}
