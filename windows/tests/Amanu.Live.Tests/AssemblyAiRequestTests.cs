using System.Text.Json;
using System.IO;
using System.Net;
using System.Net.Http;
using Amanu.App;
using Amanu.Core.Processing;
using NAudio.Wave;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class AssemblyAiRequestTests
{
    [Theory]
    [InlineData("speech")]
    [InlineData("silent")]
    [InlineData("failure")]
    public async Task Tracks_detect_independently_preserve_offsets_and_never_hide_a_failed_side(string outcome)
    {
        var folder = Path.Combine(Path.GetTempPath(), "amanu-bilingual-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var mic = Path.Combine(folder, "mic.wav");
            var system = Path.Combine(folder, "system.wav");
            foreach (var path in new[] { mic, system })
            {
                using var writer = new WaveFileWriter(path, new WaveFormat(16000, 16, 1));
                writer.Write(new byte[32000], 0, 32000);
            }
            var stereo = Path.Combine(folder, "stereo.wav");
            AudioPreprocessor.CreateAlignedStereo16k(mic, system, 4000, 7000, stereo);
            var legacy = ProviderCache.PathFor(folder, "assemblyai", "universal", "", "multichannel", "*", new FileInfo(stereo).Length.ToString())!;
            await File.WriteAllTextAsync(legacy, "{\"text\":\"old English-only answer\"}");
            File.Delete(stereo);
            using var handler = new ChannelHandler(outcome);
            using var http = new HttpClient(handler);
            var engine = new AssemblyAiTranscriptionEngine(http, "test-key", [], null);
            var audio = new SessionAudio(folder, "Mixed-language regression", mic, system, null, 4000, 7000);
            if (outcome == "failure")
            {
                await Assert.ThrowsAsync<ProcessingFailure>(() => engine.TranscribeAsync(audio, CancellationToken.None));
                var recovered = await engine.TranscribeAsync(audio, CancellationToken.None);
                Assert.Equal(new[] { "Привет, это русский текст", "Hello from the call" }, recovered.Segments.Select(x => x.Text));
            }
            else
            {
                var transcript = await engine.TranscribeAsync(audio, CancellationToken.None);
                Assert.Equal(outcome == "silent" ? new[] { "Hello from the call" } : new[] { "Привет, это русский текст", "Hello from the call" }, transcript.Segments.Select(x => x.Text));
                Assert.Equal(outcome == "silent" ? new[] { "them" } : new[] { "me", "them" }, transcript.Segments.Select(x => x.Speaker));
                Assert.Equal(outcome == "silent" ? new long[] { 7100 } : new long[] { 4100, 7100 }, transcript.Segments.Select(x => x.StartMs));
                var requests = handler.Requests;
                await engine.TranscribeAsync(audio, CancellationToken.None);
                Assert.Equal(requests, handler.Requests);
            }
            Assert.Equal(outcome == "failure" ? 3 : 2, handler.Uploads);
            Assert.Equal(outcome == "failure" ? 3 : 2, handler.Submissions);
            Assert.True(File.Exists(mic));
            Assert.True(File.Exists(system));
            Assert.True(File.Exists(legacy));
            Assert.False(File.Exists(Path.Combine(folder, ".assemblyai-input.wav")));
        }
        finally { Directory.Delete(folder, true); }
    }

    private sealed class ChannelHandler(string outcome) : HttpMessageHandler
    {
        public int Requests { get; private set; }
        public int Uploads { get; private set; }
        public int Submissions { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Requests++;
            string json;
            if (request.RequestUri!.AbsolutePath == "/v2/upload")
            {
                Uploads++;
                var wave = await request.Content!.ReadAsByteArrayAsync(token);
                Assert.Equal(1, BitConverter.ToInt16(wave, 22));
                json = "{\"upload_url\":\"https://example.test/audio\"}";
            }
            else if (request.Method == HttpMethod.Post)
            {
                Submissions++;
                using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));
                Assert.False(body.RootElement.TryGetProperty("multichannel", out _));
                Assert.True(body.RootElement.GetProperty("language_detection_options").GetProperty("code_switching").GetBoolean());
                json = $"{{\"id\":\"job-{Submissions}\"}}";
            }
            else if (request.RequestUri.AbsolutePath.EndsWith("job-1") && outcome == "silent")
                json = "{\"status\":\"error\",\"error\":\"language_detection cannot be performed on files with no spoken audio.\"}";
            else if (request.RequestUri.AbsolutePath.EndsWith("job-2") && outcome == "failure")
                json = "{\"status\":\"error\",\"error\":\"Transcoding failed\"}";
            else
            {
                var text = request.RequestUri.AbsolutePath.EndsWith("job-1") ? "Привет, это русский текст" : "Hello from the call";
                json = JsonSerializer.Serialize(new { status = "completed", utterances = new[] { new { speaker = "A", text, start = 100, end = 900 } } });
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) };
        }
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void Automatic_and_hinted_requests_keep_both_languages_on_mono_and_stereo(bool hinted, bool stereo)
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
        Assert.False(root.TryGetProperty("speech_model", out _));
        if (hinted)
        {
            Assert.Equal(expected, options.GetProperty("expected_languages").EnumerateArray().Select(x => x.GetString()));
            Assert.Equal("ru", options.GetProperty("fallback_language").GetString());
        }
        else Assert.False(options.TryGetProperty("expected_languages", out _));
    }
}
