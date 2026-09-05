// transcribePerTrack copied verbatim from HEAD except private visibility. Surrounding types are synthetic stubs.
import Foundation
struct Transcript { struct Segment { let speaker: String; let start_ms: Int; let end_ms: Int; let text: String } }
struct SessionMeta { struct Track { let file: String; let channel: Int?; let speaker: String; let offsetMs: Int }; let tracks: [Track] }
enum AudioChannelExtractor { static func extract(channel: Int, from: URL, to: URL) throws { fatalError("not used") } }
struct BrokenAtTranscribe: TranscriptionEngine {
    struct DecoderFailure: Error {}
    let name = "fake-local"; let model = "audit"; let input = TranscriptionInput.perTrack
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] { throw DecoderFailure() }
}
actor Harness {
    func log(_ dir: URL, _ message: String) { print(message) }
    func transcribePerTrack(
        _ dir: URL,
        meta: SessionMeta,
        engine: TranscriptionEngine
    ) async throws -> [Transcript.Segment] {
        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let storedAudio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: storedAudio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }

            var audio = storedAudio
            var temporary: URL?
            if let channel = track.channel {
                let extracted = FileManager.default.temporaryDirectory
                    .appendingPathComponent("amanu-\(UUID().uuidString)-channel-\(channel).m4a")
                do {
                    try await Task.detached(priority: .utility) {
                        try AudioChannelExtractor.extract(
                            channel: channel, from: storedAudio, to: extracted)
                    }.value
                    audio = extracted
                    temporary = extracted
                } catch {
                    try? FileManager.default.removeItem(at: extracted)
                    log(dir, "skipping \(track.speaker) channel in \(track.file): \(error)")
                    continue
                }
            }

            log(dir, "transcribing \(track.file)\(track.channel.map { " channel \($0)" } ?? "") "
                + "(\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        return merged
    }

}
@main struct Repro {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("synthetic-failed-tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["mic.caf", "system.caf"] { try Data("synthetic fixture; no real audio".utf8).write(to: root.appendingPathComponent(name)) }
        let meta = SessionMeta(tracks: [.init(file: "mic.caf", channel: nil, speaker: "me", offsetMs: 0), .init(file: "system.caf", channel: nil, speaker: "them", offsetMs: 0)])
        do {
            let segments = try await Harness().transcribePerTrack(root, meta: meta, engine: BrokenAtTranscribe())
            print("BUG: both decoders threw, but transcribePerTrack succeeded with \(segments.count) segments")
        } catch { print("Expected safe behavior: throw \(error)") }
    }
}
