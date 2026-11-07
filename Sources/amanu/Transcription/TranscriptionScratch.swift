import Foundation

/// Everything a transcription leaves in a session folder on its way to the
/// transcript: the services' own answers, a job id, the echo-cancelled copies
/// and their folder, the slices of an over-long mix, the mixes themselves.
///
/// All of it exists to make a retry cheaper, and none of it is worth keeping
/// once there is nothing left to retry. It is also the meeting, word for word
/// or sample for sample: a provider cache is the whole transcript under
/// another name, and the echo-cancellation folder held one for every cloud
/// run and was never deleted by anything — so deleting a transcript, or
/// keeping no audio, left the meeting sitting in a hidden folder beside it.
/// So it goes when the transcript is written, when a session is retired, and
/// before a session is transcribed again — apart from the completed pieces of
/// an unfinished compatible run and the mix they were cut from, which a
/// retirement and a retry keep so the retry pays only for what failed. Those
/// go with the next transcript that is published, or with the folder.
enum TranscriptionScratch {
    static let echoFolderPrefix = ".transcription-aec-"
    static let sliceFolder = "openai-slices"
    static let derivedAudio = [
        TranscriptionInputs.mixedFile, "mixed.tmp.m4a",
        TranscriptionInputs.multichannelFile, TranscriptionInputs.multichannelTemporary,
    ]

    /// Providers whose caches hold completed pieces of an unfinished
    /// transcription rather than one answer for the whole meeting. Each piece
    /// is keyed by the endpoint, profile, model, request fields, preparation
    /// and a digest of the exact audio it was cut from, so a piece made from
    /// anything else simply misses.
    static let resumableProviders = ["compatible"]

    static func resumableCaches(in dir: URL) -> [URL] {
        ProviderCache.files(in: dir).filter { url in
            resumableProviders.contains { url.lastPathComponent.hasPrefix("transcript.\($0).") }
        }
    }

    /// What `remove` would take from `dir`, by name.
    ///
    /// `keepingResumable` is for a retry or a retirement, which are the same
    /// transcription continued rather than a new one: the pieces already paid
    /// for stay, and so does the mix they were cut from — regenerating it
    /// re-encodes AAC, and a mix that is not byte for byte the same would miss
    /// every piece. A success still clears all of it.
    static func items(
        in dir: URL, includingDerivedAudio: Bool = false, keepingResumable: Bool = false
    ) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let kept: Set<String> = keepingResumable
            ? Set(resumableCaches(in: dir).map(\.lastPathComponent)) : []
        var found = ProviderCache.files(in: dir).filter { !kept.contains($0.lastPathComponent) }
        if kept.isEmpty, names.contains(TranscriptionInputs.mixedIdentityFile) {
            found.append(dir.appendingPathComponent(TranscriptionInputs.mixedIdentityFile))
        }
        found += names
            .filter { $0.hasPrefix(echoFolderPrefix) || $0 == sliceFolder }
            .map { dir.appendingPathComponent($0) }
        if includingDerivedAudio {
            found += names.filter(derivedAudio.contains)
                .filter { kept.isEmpty || $0 != TranscriptionInputs.mixedFile }
                .map { dir.appendingPathComponent($0) }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Remove it, and say in the session's log what went. `derivedAudio` is
    /// for a session about to be transcribed again, whose mixes may have been
    /// made from tracks as they were rather than as they are.
    @discardableResult
    static func remove(
        in dir: URL, includingDerivedAudio: Bool = false, keepingResumable: Bool = false
    ) -> [String] {
        var removed: [String] = []
        for url in items(in: dir, includingDerivedAudio: includingDerivedAudio,
                         keepingResumable: keepingResumable) {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url.lastPathComponent)
            }
        }
        if !removed.isEmpty {
            appendSessionLog(
                "removed what transcribing left behind: \(removed.joined(separator: ", "))",
                to: dir)
        }
        return removed
    }
}
