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
/// before a session is transcribed again.
enum TranscriptionScratch {
    static let echoFolderPrefix = ".transcription-aec-"
    static let sliceFolder = "openai-slices"
    static let fishAudioSliceFolder = "fishaudio-slices"
    static let derivedAudio = [
        TranscriptionInputs.mixedFile, "mixed.tmp.m4a",
        TranscriptionInputs.multichannelFile, TranscriptionInputs.multichannelTemporary,
    ]

    /// What `remove` would take from `dir`, by name.
    static func items(in dir: URL, includingDerivedAudio: Bool = false) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var found = ProviderCache.files(in: dir)
        found += names
            .filter {
                $0.hasPrefix(echoFolderPrefix) || $0 == sliceFolder || $0 == fishAudioSliceFolder
            }
            .map { dir.appendingPathComponent($0) }
        if includingDerivedAudio {
            found += names.filter(derivedAudio.contains).map { dir.appendingPathComponent($0) }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Remove it, and say in the session's log what went. `derivedAudio` is
    /// for a session about to be transcribed again, whose mixes may have been
    /// made from tracks as they were rather than as they are.
    @discardableResult
    static func remove(in dir: URL, includingDerivedAudio: Bool = false) -> [String] {
        var removed: [String] = []
        for url in items(in: dir, includingDerivedAudio: includingDerivedAudio) {
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
