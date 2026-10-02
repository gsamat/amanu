using System.Text.Json.Nodes;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class SummaryProviderTests
{
    [Fact]
    public void Provider_selection_survives_saving_while_the_custom_URL_is_retained()
    {
        var settings = AppSettings.CreateDefault("C:\\Docs");
        settings.Summary.OpenAiBaseUrl = "https://router.example/api/v1";
        settings = SettingsDocument.With(settings, "summary.openai_compatible", JsonValue.Create(false), "C:\\Docs");
        var saved = SettingsDocument.ToNode(settings);
        var selected = SettingsDocument.Get(saved, "summary.openai_compatible");
        Assert.NotNull(selected);
        Assert.False(selected.GetValue<bool>());
        Assert.Equal("https://router.example/api/v1", settings.Summary.OpenAiBaseUrl);
        Assert.Equal("https://api.openai.com/v1", settings.Summary.EffectiveOpenAiBaseUrl);
        Assert.Equal("openai-key", KeyRouting.SummaryOpenAiKey(settings.Summary.EffectiveOpenAiBaseUrl, "openai-key", "router-key"));
        settings = SettingsDocument.With(settings, "summary.openai_compatible", JsonValue.Create(true), "C:\\Docs");
        Assert.Equal("https://router.example/api/v1", settings.Summary.EffectiveOpenAiBaseUrl);
        Assert.Equal("router-key", KeyRouting.SummaryOpenAiKey(settings.Summary.EffectiveOpenAiBaseUrl, "openai-key", "router-key"));
    }
    [Fact]
    public void Legacy_custom_endpoints_select_compatible_without_changing_the_route()
    {
        var settings = new SummarySettings { OpenAiBaseUrl = "https://router.example/api/v1" };
        Assert.True(settings.UsesCompatibleOpenAi);
        Assert.Equal("https://router.example/api/v1", settings.EffectiveOpenAiBaseUrl);
    }

    [Fact]
    public void A_compatible_provider_without_its_own_URL_does_not_use_OpenAI()
    {
        var settings = new SummarySettings { OpenAiCompatible = true };
        Assert.Empty(settings.EffectiveOpenAiBaseUrl);
        Assert.False(KeyRouting.AcceptableServer(settings.EffectiveOpenAiBaseUrl));
    }
}
