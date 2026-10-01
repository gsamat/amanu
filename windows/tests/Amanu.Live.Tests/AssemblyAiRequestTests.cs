using System.Text.Json;
using Amanu.App;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class AssemblyAiRequestTests
{
    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void Requests_enable_code_switching_without_changing_channel_or_language_hints(bool hinted, bool stereo)
    {
        var expected = hinted ? new[] { "ru", "en" } : [];
        var body = AssemblyAiTranscriptionEngine.RequestBody("https://example.test/audio.wav", stereo, expected, null);
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(body));
        var root = document.RootElement;
        Assert.True(root.GetProperty("language_detection").GetBoolean());
        Assert.True(root.GetProperty("speaker_labels").GetBoolean());
        Assert.Equal(stereo, root.TryGetProperty("multichannel", out var multichannel) && multichannel.GetBoolean());
        var options = root.GetProperty("language_detection_options");
        Assert.True(options.GetProperty("code_switching").GetBoolean());
        Assert.False(root.TryGetProperty("language_code", out _));
        if (hinted)
        {
            Assert.Equal(expected, options.GetProperty("expected_languages").EnumerateArray().Select(x => x.GetString()));
            Assert.Equal("ru", options.GetProperty("fallback_language").GetString());
        }
        else Assert.False(options.TryGetProperty("expected_languages", out _));
    }
}
