namespace Amanu.Core.Configuration;

/// <summary>The two setup switches expressed in the processing engine's stored mode.</summary>
public readonly record struct SetupChoice(bool Cloud, bool Local, bool Enabled, string Engine)
{
    public static SetupChoice FromSwitches(bool cloud, bool local) =>
        new(cloud, local, cloud || local,
            cloud && local ? "auto" : cloud ? "cloud" : local ? "local" : "auto");

    public static SetupChoice FromSettings(bool enabled, string engine) =>
        !enabled ? FromSwitches(false, false) : engine.ToLowerInvariant() switch
        {
            "cloud" => FromSwitches(true, false),
            "local" => FromSwitches(false, true),
            _ => FromSwitches(true, true),
        };
}
