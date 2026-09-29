using static Amanu.Core.Localization.Localized;

namespace Amanu.Core.Processing;

/// <summary>What a failure says about the session, which decides what it costs.</summary>
public enum FailureKind
{
    /// <summary>
    /// Something about this computer rather than the recording: no key, a key the
    /// service refuses, no network, a model not downloaded. It waits for the
    /// computer to change and never uses up one of the session's attempts.
    /// </summary>
    Environmental,
    /// <summary>A service that is busy or down for now. Tried again later; no attempt spent either.</summary>
    Transient,
    /// <summary>Something about the recording itself. Three of these and the session is given up on.</summary>
    Recording,
}

public sealed class ProcessingFailure(FailureKind kind, string message, Exception? inner = null) : Exception(message, inner)
{
    public FailureKind Kind { get; } = kind;

    /// <summary>No answer at all: nothing listening at the address, or no network.</summary>
    public bool Unreachable { get; init; }

    /// <summary>
    /// How an HTTP answer from a paid service is read. No answer at all is the
    /// network; 401 and 403 are the key; 408, 429 and 5xx pass; anything else is
    /// the service refusing this particular audio.
    /// </summary>
    public static ProcessingFailure FromHttp(string service, int? status, string? detail)
    {
        var text = string.IsNullOrWhiteSpace(detail) ? "" : ": " + (detail.Length > 300 ? detail[..300] + "…" : detail);
        return status switch
        {
            null => new(FailureKind.Environmental, T($"{service} could not be reached{text}", $"{service} недоступен{text}")) { Unreachable = true },
            401 or 403 => new(FailureKind.Environmental, T($"{service} refused the key (HTTP {status}){text}", $"{service} не принял ключ (HTTP {status}){text}")),
            408 or 429 or >= 500 => new(FailureKind.Transient, T($"{service} is busy (HTTP {status}){text}", $"{service} занят (HTTP {status}){text}")),
            _ => new(FailureKind.Recording, $"{service} HTTP {status}{text}"),
        };
    }
}
