import AVFoundation
import Foundation
import Testing

@testable import amanu

struct FishAudioEngineTests {
    @Test("Mono turns retain interruptions, punctuation and clipped source times")
    func monoTurnsAndBounds() async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url)
            let stub = StubHTTP { _, _ in .json(200, """
                {"text":"[speaker:0] First. [speaker:1] Yes! Again.","duration":1.1,"speaker_turns":[
                  {"speaker":"speaker:0","text":"  First.  ","start":-0.2,"end":0.4},
                  {"speaker":"speaker:1","text":"Yes!","start":0.2,"end":0.3},
                  {"speaker":"speaker:0","text":"Again.","start":0.35,"end":1.5},
                  {"speaker":"speaker:1","text":"after the source","start":2,"end":3},
                  {"speaker":"speaker:1","text":"before the source","start":-2,"end":-1},
                  {"speaker":"speaker:1","text":"  ","start":0.5,"end":0.6},
                  {"speaker":"speaker:1","text":"backwards","start":0.7,"end":0.6},
                  {"speaker":"speaker:1","text":"zero length","start":0.8,"end":0.8}
                ]}
                """) }
            let segments = try await fixture.engine(stub).transcribe(fixture.audio)

            #expect(segments.map(\.speaker) == ["A", "B", "A"])
            #expect(segments.map(\.text) == ["First.", "Yes!", "Again."])
            #expect(segments.map(\.start) == [0, 0.2, 0.35])
            #expect(segments.map(\.end) == [0.4, 0.3, 1])
            #expect(stub.requests.count == 1)
            #expect(!fixture.hasScratch)
        }
    }

    @Test("Only finite, possible turns survive before offsets are applied")
    func invalidTurnsAreOmitted() throws {
        let response = FishAudioEngine.Response(
            text: "A valid turn.", duration: 2,
            speaker_turns: [
                .init(speaker: "speaker:0", text: "nan start", start: .nan, end: 0.5),
                .init(speaker: "speaker:0", text: "infinite end", start: 0.1, end: .infinity),
                .init(speaker: "speaker:0", text: "negative infinity", start: -.infinity, end: 0.4),
                .init(speaker: "speaker:0", text: " A valid turn. ", start: -0.2, end: 2),
            ])

        let segments = try FishAudioEngine.segments(
            from: response, duration: 1, offset: 4, channel: 1, piece: 2)

        #expect(segments.map(\.text) == ["A valid turn."])
        #expect(segments.map(\.start) == [4])
        #expect(segments.map(\.end) == [5])
        #expect(segments.map(\.speaker) == ["2P3A"])
    }

    @Test("Fish's supported speaker range is fixed and unknown ids are retained")
    func speakerRangeBoundaries() throws {
        let speakers = [
            "speaker:0", "speaker:25", "speaker:26", "speaker:51", "speaker:52",
            "speaker:-1", "speaker:x", "guest", "speaker_0",
        ]
        let response = FishAudioEngine.Response(
            text: "Speech.", duration: 1,
            speaker_turns: speakers.map {
                .init(speaker: $0, text: "Speech.", start: 0.1, end: 0.5)
            })

        let segments = try FishAudioEngine.segments(
            from: response, duration: 1, offset: 0, channel: nil, piece: nil)

        #expect(segments.map(\.speaker) == [
            "A", "Z", "AA", "AZ", "speaker:52", "speaker:-1", "speaker:x", "guest", "speaker_0",
        ])
    }

    @Test("Five seconds uses actual 0/2/4 offsets and request-scoped voice identities",
          arguments: [1, 2])
    func piecesKeepOffsetsAndIdentity(channels: Int) async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url, seconds: 5, channels: channels)
            let stub = StubHTTP { _, _ in .json(200, Self.speech(duration: 2.1)) }
            let first = try await fixture.engine(stub, maxPieceDuration: 2).transcribe(fixture.audio)
            // A new engine must find the same original-source caches despite
            // having new UUID-named extraction and slicing directories.
            let second = try await fixture.engine(stub, maxPieceDuration: 2).transcribe(fixture.audio)

            let expected: [String: Double] = channels == 1
                ? ["P1A": 0.1, "P2A": 2.1, "P3A": 4.1]
                : ["1P1A": 0.1, "1P2A": 2.1, "1P3A": 4.1,
                   "2P1A": 0.1, "2P2A": 2.1, "2P3A": 4.1]
            for segments in [first, second] {
                #expect(segments.count == expected.count)
                for segment in segments {
                    let speaker = try #require(segment.speaker)
                    let start = try #require(expected[speaker])
                    #expect(abs(segment.start - start) < 0.000_001)
                    #expect(abs(segment.end - (start + 0.4)) < 0.000_001)
                    #expect(segment.text == "Speech.")
                }
                #expect(segments.map(\.start) == segments.map(\.start).sorted())
            }
            if channels == 2 {
                #expect(Set(MultichannelSpeakerLabels.map(first).map(\.speaker)) == [
                    "me P1A", "me P2A", "me P3A", "them P1A", "them P2A", "them P3A",
                ])
            }
            #expect(stub.requests.count == channels * 3)
            #expect(fixture.caches.count == channels * 3)
            #expect(!fixture.hasScratch)
        }
    }

    @Test("The last piece is clipped to the logical source rather than AAC padding")
    func lastPieceEndsAtSourceBoundary() async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url, seconds: 5)
            let stub = StubHTTP { _, _ in .json(200, """
                {"text":"Speech.","duration":2.1,"speaker_turns":[
                  {"speaker":"speaker:0","text":"Speech.","start":0.1,"end":2.1}]}
                """) }

            let segments = try await fixture.engine(stub, maxPieceDuration: 2).transcribe(fixture.audio)

            #expect(segments.map(\.start) == [0.1, 2.1, 4.1])
            #expect(segments.map(\.end) == [2, 4, 5])
            #expect(stub.requests.count == 3)
        }
    }

    @Test("A silent channel or middle piece does not discard speech or lose its valid cache",
          arguments: ["channel", "piece"])
    func partialSilenceIsCached(boundary: String) async throws {
        try await withFreshHome { home in
            let pieces = boundary == "piece"
            let fixture = try Fixture(in: home.url, seconds: pieces ? 5 : 1, channels: pieces ? 1 : 2)
            let stub = StubHTTP { _, count in
                let silent = pieces ? count == 2 : count == 1
                return .json(200, silent ? Self.silence : Self.speech())
            }
            let engine = try fixture.engine(stub, maxPieceDuration: 2)

            let first = try await engine.transcribe(fixture.audio)
            let second = try await engine.transcribe(fixture.audio)

            let labels = pieces ? ["P1A", "P3A"] : ["2A"]
            let starts = pieces ? [0.1, 4.1] : [0.1]
            #expect(first.map(\.speaker) == labels)
            #expect(second.map(\.speaker) == labels)
            #expect(first.map(\.start) == starts)
            #expect(second.map(\.start) == starts)
            #expect(stub.requests.count == (pieces ? 3 : 2))
            #expect(fixture.caches.count == (pieces ? 3 : 2))
            #expect(!fixture.hasScratch)
        }
    }

    @Test("Only completed all-silent input is permanent, and its silent pieces are reused",
          arguments: [1, 2])
    func allSilenceIsPermanentAndCached(channels: Int) async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url, seconds: 5, channels: channels)
            let stub = StubHTTP { _, _ in .json(200, Self.silence) }
            let engine = try fixture.engine(stub, maxPieceDuration: 2)

            for _ in 0..<2 {
                let error = await #expect(throws: FishAudioEngine.EngineError.self) {
                    try await engine.transcribe(fixture.audio)
                }
                guard case .empty = error else {
                    Issue.record("expected completed silent input, got \(String(describing: error))")
                    return
                }
                #expect(error?.isPermanent == true)
                #expect(error?.isEnvironmental == false)
                #expect(!fixture.hasScratch)
            }
            #expect(stub.requests.count == channels * 3)
            #expect(fixture.caches.count == channels * 3)
        }
    }

    @Test("An unfinished all-silent prefix still reports the later request failure")
    func silentPrefixDoesNotMaskFailure() async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url, seconds: 5)
            let stub = StubHTTP { _, count in
                count == 1 ? .json(200, Self.silence) : .json(402, "no credit")
            }
            let engine = try fixture.engine(stub, maxPieceDuration: 2)

            let error = await #expect(throws: CloudHTTP.Failure.self) {
                try await engine.transcribe(fixture.audio)
            }

            #expect(error?.status == 402)
            #expect(error?.isEnvironmental == true)
            #expect(fixture.caches.count == 1)
            #expect(stub.requests.count == 2)
            #expect(!fixture.hasScratch)
        }
    }

    @Test("Malformed Pro answers do not downgrade to full text or enter the cache", arguments: [
        #"{"text":"[speaker:0] Speech.","duration":1}"#,
        #"{"text":"Speech.","duration":0,"speaker_turns":[]}"#,
        #"{"text":"Speech.","duration":-1,"speaker_turns":[]}"#,
        #"{"text":"[speaker:0] Speech.","duration":1,"speaker_turns":[]}"#,
        #"{"text":"Speech.","duration":1,"speaker_turns":[{"speaker":"speaker:0","text":" ","start":0.1,"end":0.5}]}"#,
        #"{"text":"Speech.","duration":1,"speaker_turns":[{"speaker":"speaker:0","text":"Speech.","start":2,"end":3}]}"#,
        #"{"text":"Speech.","duration":1,"speaker_turns":[{"speaker":"speaker:0","text":"Speech.","start":0.5,"end":0.1}]}"#,
    ])
    func malformedResponsesAreNotCached(body: String) async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url)
            let stub = StubHTTP { _, _ in .json(200, body) }

            let error = await #expect(throws: CloudHTTP.Failure.self) {
                try await fixture.engine(stub).transcribe(fixture.audio)
            }

            guard case .malformed(service: "fishaudio", what: "transcription", body: _) = error else {
                Issue.record("expected malformed Fish transcription, got \(String(describing: error))")
                return
            }
            #expect(error?.isPermanent == false)
            #expect(error?.isEnvironmental == false)
            #expect(fixture.caches.isEmpty)
            #expect(stub.requests.count == 1)
            #expect(!fixture.hasScratch)
        }
    }

    @Test("Nonfinite response durations are malformed even when a turn looks usable",
          arguments: [Double.nan, Double.infinity, -Double.infinity])
    func nonfiniteDurationIsMalformed(duration: Double) {
        let response = FishAudioEngine.Response(
            text: "Speech.", duration: duration,
            speaker_turns: [.init(speaker: "speaker:0", text: "Speech.", start: 0.1, end: 0.5)])

        let error = #expect(throws: CloudHTTP.Failure.self) {
            try FishAudioEngine.segments(from: response, duration: 1, offset: 0, channel: nil, piece: nil)
        }

        #expect(error == .malformed(
            service: "fishaudio", what: "transcription", body: "invalid transcription duration"))
    }

    @Test("Decodable but semantically invalid cached responses are refreshed", arguments: [
        #"{"text":"Speech.","duration":0,"speaker_turns":[]}"#,
        #"{"text":"Speech.","duration":1,"speaker_turns":[]}"#,
        #"{"text":"Speech.","duration":1,"speaker_turns":[{"speaker":"speaker:0","text":"Speech.","start":2,"end":3}]}"#,
        #"{"text":"Speech.","duration":1}"#,
        "not JSON",
    ])
    func invalidCachesAreRefreshed(body: String) async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url)
            let stub = StubHTTP { _, _ in .json(200, Self.speech(text: "Refreshed.")) }
            let engine = try fixture.engine(stub)
            let cache = await engine.cacheURL(for: fixture.audio, channel: nil, piece: 0, of: 1)
            try Data(body.utf8).write(to: cache)

            let first = try await engine.transcribe(fixture.audio)
            let second = try await engine.transcribe(fixture.audio)

            #expect(first.map(\.text) == ["Refreshed."])
            #expect(second.map(\.text) == ["Refreshed."])
            #expect(stub.requests.count == 1)
            #expect(!fixture.hasScratch)
        }
    }

    @Test("Changing language or piece limits cannot reuse a response for another request")
    func cacheSeparatesRequestSemantics() async throws {
        try await withFreshHome(config: ["transcription": ["language": "en"]]) { home in
            let fixture = try Fixture(in: home.url)
            let stub = StubHTTP { _, count in .json(200, Self.speech(text: "Answer \(count).")) }
            let english = try fixture.engine(stub)
            let first = try await english.transcribe(fixture.audio)

            try home.writeConfig(["transcription": ["language": "ru"]])
            let detected = try fixture.engine(stub)
            let second = try await detected.transcribe(fixture.audio)
            let shorter = try fixture.engine(stub, maxPieceDuration: 2)
            let third = try await shorter.transcribe(fixture.audio)
            let englishAgain = try await english.transcribe(fixture.audio)
            let detectedAgain = try await fixture.engine(stub).transcribe(fixture.audio)

            #expect(first.map(\.text) == ["Answer 1."])
            #expect(second.map(\.text) == ["Answer 2."])
            #expect(third.map(\.text) == ["Answer 3."])
            #expect(englishAgain.map(\.text) == ["Answer 1."])
            #expect(detectedAgain.map(\.text) == ["Answer 2."])
            #expect(stub.requests.count == 3)
        }
    }

    @Test("Missing, unreadable and corrupt sources fail before HTTP, even with a cached answer",
          arguments: ["missing", "unreadable", "corrupt"])
    func invalidSourcesAreNotUploaded(kind: String) async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url)
            let stub = StubHTTP { _, _ in .json(200, Self.speech()) }
            let engine = try fixture.engine(stub)
            let cache = await engine.cacheURL(for: fixture.audio, channel: nil, piece: 0, of: 1)
            try Data(Self.speech().utf8).write(to: cache)
            switch kind {
            case "missing": try FileManager.default.removeItem(at: fixture.audio)
            case "unreadable":
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.audio.path)
            default: try Data("not a WAV recording".utf8).write(to: fixture.audio)
            }
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.audio.path)
            }

            await #expect(throws: (any Error).self) { try await engine.transcribe(fixture.audio) }

            #expect(stub.requests.isEmpty)
            #expect(!fixture.hasScratch)
        }
    }

    @Test("Cancellation of a later upload removes only scratch and retains completed responses")
    func cancellationKeepsCacheAndCleansScratch() async throws {
        try await withFreshHome { home in
            let fixture = try Fixture(in: home.url, seconds: 5, channels: 2)
            let stub = StubHTTP { _, count in count == 1 ? .json(200, Self.speech()) : .hang }
            let engine = try fixture.engine(stub, maxPieceDuration: 2)
            let task = Task { try await engine.transcribe(fixture.audio) }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(10)
            while stub.requests.count < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(stub.requests.count == 2)
            task.cancel()

            await #expect(throws: CancellationError.self) { try await task.value }

            #expect(fixture.caches.count == 1)
            #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
            #expect(!fixture.hasScratch)
        }
    }

    private static let silence = #"{"text":"  ","duration":2.1,"speaker_turns":[]}"#

    private static func speech(text: String = "Speech.", duration: Double = 1) -> String {
        """
        {"text":"\(text)","duration":\(duration),"speaker_turns":[
          {"speaker":"speaker:0","text":"\(text)","start":0.1,"end":0.5}]}
        """
    }

    private struct Fixture {
        let audio: URL

        init(in directory: URL, seconds: Double = 1, channels: Int = 1) throws {
            audio = directory.appendingPathComponent("recording.wav")
            try TestAudio.write(to: audio, seconds: seconds, sampleRate: 48_000,
                                channels: AVAudioChannelCount(channels)) { channel, frame in
                0.2 * Float(sin(Double(frame) * (channel == 0 ? 0.05 : 0.11)))
            }
        }

        var directory: URL { audio.deletingLastPathComponent() }
        var caches: [URL] { ProviderCache.files(in: directory) }
        var hasScratch: Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(
                TranscriptionScratch.fishAudioSliceFolder, isDirectory: true).path)
        }

        func engine(_ stub: StubHTTP,
                    maxPieceDuration: TimeInterval = FishAudioEngine.defaultMaxPieceDuration) throws -> FishAudioEngine {
            try FishAudioEngine(apiKey: "fish-test", session: stub.session,
                                maxPieceDuration: maxPieceDuration, retry: .once)
        }
    }
}
