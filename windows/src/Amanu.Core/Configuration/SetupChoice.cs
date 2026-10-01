namespace Amanu.Core.Configuration;

/// <summary>
/// The setup form's two transcription switches, in the vocabulary of
/// <c>transcription.engine</c>. Both on is <c>auto</c> — the cloud when it
/// answers, this computer when it doesn't — which is what having both on means,
/// not a third option to pick. One on names that engine, so nothing else is ever
/// tried; both off turns transcription off.
/// </summary>
public readonly record struct SetupChoice(bool Cloud, bool Local, string Provider, string LocalEngine)
{
    public bool Enabled => Cloud || Local;

    public string Engine => Cloud && Local ? "auto" : Cloud ? Provider : Local ? LocalEngine : "auto";

    public static SetupChoice Read(bool enabled, string engine, string cloudProvider, string localEngine)
    {
        var namedCloud = TranscriptionSettings.CloudEngines.Contains(engine);
        var namedLocal = TranscriptionSettings.LocalEngines.Contains(engine);
        var provider = namedCloud ? engine
            : TranscriptionSettings.CloudEngines.Contains(cloudProvider) ? cloudProvider : "assemblyai";
        var local = namedLocal ? engine
            : TranscriptionSettings.LocalEngines.Contains(localEngine) ? localEngine : "parakeet";
        if (!enabled) return new(false, false, provider, local);
        // Anything that isn't an engine's name is auto — the default, and what an
        // unreadable value falls back to elsewhere too.
        var auto = !namedCloud && !namedLocal;
        return new(namedCloud || auto, namedLocal || auto, provider, local);
    }

    public void ApplyTo(TranscriptionSettings settings)
    {
        settings.Enabled = Enabled;
        settings.Engine = Engine;
        settings.Cloud = Provider;
        settings.LocalEngine = LocalEngine;
    }
}
