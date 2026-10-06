using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Shapes;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using static Amanu.Core.Localization.Localized;
using Button = System.Windows.Controls.Button;
using Orientation = System.Windows.Controls.Orientation;

namespace Amanu.App;

/// <summary>Device, then test and measured level. Uses existing recording packets while recording.</summary>
internal sealed class AudioDeviceControls : IAsyncDisposable
{
    private sealed class DeviceRow(bool microphone, IAudioEndpointFactory factory)
    {
        public bool Microphone { get; } = microphone;
        public ComboBox Devices { get; } = new() { DisplayMemberPath = nameof(AudioEndpointChoice.Name), MinWidth = 0, HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch };
        public AudioDevicePreview Preview { get; } = new(factory);
        public Button Test { get; set; } = null!;
        public TextBlock Message { get; } = Ui.Status();
        public Rectangle[] Bars { get; } = Enumerable.Range(0, 10).Select(_ => new Rectangle { Height = 9, RadiusX = 1, RadiusY = 1, Margin = new Thickness(1, 0, 1, 0) }).ToArray();
        public bool Testing;
        public bool Busy;
        public int Generation;
        public bool HadCaptureError;
    }
    private readonly AmanuRuntime runtime;
    private readonly DeviceRow mic, output;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(150) };
    private readonly SemaphoreSlim playbackGate = new(1, 1);
    private WasapiPlayer? player;
    private MMDevice? playbackDevice;
    private bool populating;
    private bool refreshing;
    private bool disposed;
    private int ticks;
    private int playbackGeneration;
    public StackPanel View { get; } = new() { Margin = new Thickness(0, 18, 0, 0) };

    public AudioDeviceControls(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        var factory = new WindowsAudioEndpointFactory();
        mic = new(true, factory); output = new(false, factory);
        View.Children.Add(CreateRow(mic, T("Microphone", "Микрофон")));
        View.Children.Add(CreateRow(output, T("Call audio", "Звук собеседника")));
        runtime.SettingsChanged += OnSettingsChanged;
        runtime.StateChanged += OnStateChanged;
        View.IsVisibleChanged += async (_, _) =>
        {
            if (disposed) return;
            if (View.IsVisible) { timer.Start(); await RefreshDevicesAsync(); }
            else { timer.Stop(); await StopPreviewsAsync(); }
        };
        timer.Tick += (_, _) =>
        {
            RefreshLevels();
            if (++ticks % 14 == 0) _ = RefreshDevicesAsync();
        };
        _ = View.Dispatcher.InvokeAsync(async () => await RefreshDevicesAsync());
    }

    private FrameworkElement CreateRow(DeviceRow row, string title)
    {
        var section = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
        section.Children.Add(Ui.Heading(title));
        var inside = new StackPanel { Margin = new Thickness(12) };
        System.Windows.Automation.AutomationProperties.SetName(row.Devices, title);
        inside.Children.Add(row.Devices);
        row.Test = Ui.Button(row.Microphone ? T("Test microphone", "Проверить микрофон") : T("Test sound", "Проверить звук"), () => _ = ToggleTestAsync(row));
        var tests = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        tests.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        tests.ColumnDefinitions.Add(new());
        tests.Children.Add(row.Test);
        var meter = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        meter.Children.Add(Ui.Detail(T("Sound level", "Уровень звука")));
        var bars = new UniformGrid { Columns = 10, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var bar in row.Bars) bars.Children.Add(bar);
        System.Windows.Automation.AutomationProperties.SetName(bars, T("Sound level", "Уровень звука"));
        meter.Children.Add(bars); Grid.SetColumn(meter, 1); tests.Children.Add(meter); inside.Children.Add(tests);
        row.Message.Margin = new Thickness(0, 8, 0, 0); inside.Children.Add(row.Message);
        section.Children.Add(Ui.Box(inside));
        row.Devices.SelectionChanged += (_, _) => SelectDevice(row);
        return section;
    }

    private void SelectDevice(DeviceRow row)
    {
        if (populating || row.Devices.SelectedItem is not AudioEndpointChoice choice) return;
        var settings = runtime.Settings;
        var old = row.Microphone ? settings.MicrophoneDevice : settings.OutputDevice;
        if (choice.Id == old) return;
        if (!row.Microphone && settings.SystemAudio == "app")
        {
            var accepted = System.Windows.MessageBox.Show(Ui.OwnerOf(View),
                T("Record sound from the selected device? This includes music and notifications on that device. The previous automatic mode recorded only the call app.",
                  "Записывать звук выбранного устройства? В запись также попадут музыка и уведомления на нём. Прежний автоматический режим записывал только приложение звонка."),
                T("Call audio device", "Устройство звука звонка"), MessageBoxButton.YesNo, MessageBoxImage.Information);
            if (accepted != MessageBoxResult.Yes) { _ = RefreshDevicesAsync(); return; }
        }
        if (!Ui.TryUpdate(Ui.OwnerOf(View), () => runtime.Update(next =>
        {
            if (row.Microphone) next.MicrophoneDevice = choice.Id;
            else { next.OutputDevice = choice.Id; next.SystemAudio = "all"; }
        }))) _ = RefreshDevicesAsync();
        _ = StopRowPreviewAsync(row);
    }

    private async Task RefreshDevicesAsync()
    {
        if (disposed || refreshing) return;
        refreshing = true;
        try
        {
            foreach (var row in new[] { mic, output })
            {
                var result = await Task.Run(() =>
                {
                    var choices = WindowsAudioEndpointFactory.List(row.Microphone).ToList();
                    string defaultName;
                    try { defaultName = WindowsAudioEndpointFactory.DefaultName(row.Microphone); }
                    catch (Exception) { defaultName = T("unavailable", "недоступно"); }
                    choices.Insert(0, new("", T($"Same as Windows ({defaultName})", $"Как в Windows ({defaultName})")));
                    return choices;
                });
                if (disposed) return;
                var selected = row.Microphone ? runtime.Settings.MicrophoneDevice : runtime.Settings.OutputDevice;
                if (!result.Any(item => item.Id == selected)) result.Add(new(selected, T("Selected device (disconnected)", "Выбранное устройство (отключено)")));
                if (row.Devices.ItemsSource is IEnumerable<AudioEndpointChoice> old && old.SequenceEqual(result) && (row.Devices.SelectedItem as AudioEndpointChoice)?.Id == selected) continue;
                populating = true;
                try { row.Devices.ItemsSource = result; row.Devices.SelectedItem = result.First(item => item.Id == selected); }
                finally { populating = false; }
            }
        }
        catch (Exception exception) { mic.Message.Text = T("Couldn't list audio devices: ", "Не удалось получить устройства звука: ") + exception.Message; }
        finally { refreshing = false; }
    }

    private async Task ToggleTestAsync(DeviceRow row)
    {
        if (disposed || row.Busy) return;
        row.Busy = true; row.Test.IsEnabled = false;
        try
        {
            if (row.Testing) { await StopRowPreviewAsync(row); return; }
            row.Testing = true;
            var rowGeneration = ++row.Generation;
            if (!runtime.State.IsRecording || !row.Microphone)
                await row.Preview.StartAsync(row.Microphone, row.Microphone ? runtime.Settings.MicrophoneDevice : runtime.Settings.OutputDevice);
            if (disposed || !View.IsVisible || rowGeneration != row.Generation) return;
            if (!row.Microphone)
            {
                var generation = ++playbackGeneration;
                await playbackGate.WaitAsync();
                try
                {
                    if (disposed || !View.IsVisible || rowGeneration != row.Generation) return;
                    await ReleasePlaybackAsync();
                    await Task.Run(() =>
                    {
                        using var enumerator = new MMDeviceEnumerator();
                        playbackDevice = enumerator.GetDevice(new WindowsAudioEndpointFactory().Resolve(false, runtime.Settings.OutputDevice));
                        player = new WasapiPlayerBuilder().WithDevice(playbackDevice).Build();
                        var tone = new SignalGenerator(48000, 2) { Gain = .12, Frequency = 660, Type = SignalGeneratorType.Sin }.Take(TimeSpan.FromSeconds(1.5));
                        player.Init(tone.ToWaveProvider()); player.Play();
                    });
                }
                finally { playbackGate.Release(); }
                _ = FinishOutputTestAsync(generation);
            }
            row.Message.Text = row.Microphone ? T("Say a few words and watch the level.", "Скажите пару слов и проверьте уровень.") : T("A test sound is playing through the selected device.", "Тестовый звук играет через выбранное устройство.");
        }
        catch (Exception exception)
        {
            await StopRowPreviewAsync(row);
            row.Message.Text = T("Couldn't check sound: ", "Не удалось проверить звук: ") + exception.Message;
        }
        finally { row.Busy = false; if (!disposed) row.Test.IsEnabled = true; RefreshLevels(); }
    }

    private async Task FinishOutputTestAsync(int generation)
    {
        await Task.Delay(1800);
        if (generation != playbackGeneration || disposed) return;
        await StopRowPreviewAsync(output); RefreshLevels();
    }
    private async Task ReleasePlaybackAsync()
    {
        var current = player; player = null;
        try { if (current is not null) { try { current.Stop(); } finally { await current.DisposeAsync(); } } }
        finally { playbackDevice?.Dispose(); playbackDevice = null; }
    }
    private async Task StopRowPreviewAsync(DeviceRow row)
    {
        ++row.Generation; row.Testing = false;
        try
        {
            try { await row.Preview.StopAsync(); }
            finally
            {
                if (!row.Microphone)
                {
                    ++playbackGeneration; await playbackGate.WaitAsync();
                    try { await ReleasePlaybackAsync(); } finally { playbackGate.Release(); }
                }
            }
            if (!disposed) row.Message.Text = "";
        }
        catch (Exception exception) { if (!disposed) row.Message.Text = T("Couldn't finish checking sound: ", "Не удалось завершить проверку звука: ") + exception.Message; }
    }
    public async Task StopPreviewsAsync()
    {
        await StopRowPreviewAsync(mic); await StopRowPreviewAsync(output); RefreshLevels();
    }
    private void RefreshLevels()
    {
        if (disposed) return;
        foreach (var row in new[] { mic, output })
        {
            var level = row.Testing && row.Preview.IsRunning ? row.Preview.Level : runtime.State.IsRecording ? row.Microphone ? runtime.AudioCapture.MicrophoneLevel : runtime.AudioCapture.SystemLevel : row.Preview.Level;
            var error = runtime.State.IsRecording ? row.Microphone ? runtime.AudioCapture.MicrophoneError : runtime.AudioCapture.SystemError : row.Preview.Error;
            for (var index = 0; index < row.Bars.Length; index++) row.Bars[index].SetResourceReference(Shape.FillProperty, index < Math.Ceiling(level * 10) ? Ui.Good : "ControlFillColorSecondaryBrush");
            row.Test.Content = row.Testing ? T("Finish checking", "Закончить проверку") : row.Microphone ? T("Test microphone", "Проверить микрофон") : T("Test sound", "Проверить звук");
            if (error is not null) { row.HadCaptureError = true; row.Message.Text = T("Sound is unavailable. Choose a device: ", "Звук недоступен. Выберите устройство: ") + error; }
            else if (row.HadCaptureError) { row.HadCaptureError = false; row.Message.Text = ""; }
            row.Message.Visibility = string.IsNullOrEmpty(row.Message.Text) ? Visibility.Collapsed : Visibility.Visible;
        }
    }
    private void OnSettingsChanged(object? sender, EventArgs args) => View.Dispatcher.InvokeAsync(async () => await RefreshDevicesAsync());
    private void OnStateChanged(object? sender, Core.Recording.RecordingState state) => View.Dispatcher.InvokeAsync(async () => { if (state.IsRecording) await StopPreviewsAsync(); RefreshLevels(); });
    public async ValueTask DisposeAsync()
    {
        if (disposed) return; disposed = true; timer.Stop();
        runtime.SettingsChanged -= OnSettingsChanged; runtime.StateChanged -= OnStateChanged;
        await StopPreviewsAsync();
    }
}
