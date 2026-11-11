using Amanu.App;
using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class ModelManagerTests
{
    [Fact]
    public async Task Missing_cli_reports_unavailable_runtime_without_downloading_native_library()
    {
        using var temp = new TemporaryDirectory();
        using var client = new HttpClient(new RejectDownloads());
        var manager = new ModelManager(temp.Path, client);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => manager.EnsureReadyAsync("parakeet"));

        Assert.Contains("runtime", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(manager.IsReady("parakeet"));
    }

    [Fact]
    public void Bundled_cli_and_existing_model_are_ready_without_legacy_runtime_cache()
    {
        using var temp = new TemporaryDirectory();
        using var client = new HttpClient(new RejectDownloads());
        var appDirectory = Path.Combine(temp.Path, "app");
        var cliDirectory = Path.Combine(appDirectory, "local-runtime");
        Directory.CreateDirectory(cliDirectory);
        File.WriteAllBytes(Path.Combine(cliDirectory, "transcribe-cli.exe"), [1]);
        var models = Path.Combine(temp.Path, "data", "models");
        Directory.CreateDirectory(models);
        File.WriteAllBytes(Path.Combine(models, ModelCatalog.Models["parakeet"].FileName), [1]);

        var manager = new ModelManager(Path.Combine(temp.Path, "data"), client, appDirectory);

        Assert.True(manager.IsReady("parakeet"));
        Assert.Equal(Path.Combine(cliDirectory, "transcribe-cli.exe"), manager.CliPath);
        Assert.Null(manager.GpuCliPath);
    }

    [Fact]
    public void The_gpu_cli_is_found_in_its_own_runtime_directory()
    {
        using var temp = new TemporaryDirectory();
        using var client = new HttpClient(new RejectDownloads());
        var appDirectory = Path.Combine(temp.Path, "app");
        var gpuDirectory = Path.Combine(appDirectory, "local-runtime-gpu");
        Directory.CreateDirectory(gpuDirectory);
        File.WriteAllBytes(Path.Combine(gpuDirectory, "transcribe-cli.exe"), [1]);

        var manager = new ModelManager(Path.Combine(temp.Path, "data"), client, appDirectory);

        Assert.Equal(Path.Combine(gpuDirectory, "transcribe-cli.exe"), manager.GpuCliPath);
        Assert.Null(manager.CliPath);
    }

    private sealed class RejectDownloads : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("Unexpected download: " + request.RequestUri);
    }
}
