import Foundation
import Testing

@testable import amanu

/// Form-based cloud engines through `CloudHTTP`, against a stub of each service.
struct FormEngineHTTPTests {
    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-form-engines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("OpenAI is sent one form with the key as a bearer token, and its answer is cached")
    func openAIRoundTrip() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440, sampleRate: 16_000)
        let service = StubHTTP { _, _ in
            .json(200, #"{"text":"hi","duration":1,"segments":[{"start":0.1,"end":0.8,"text":"hi","speaker":"A"}]}"#)
        }
        let engine = try OpenAITranscriptionEngine(apiKey: "sk-test", session: service.session)

        let first = try await engine.transcribe(audio)
        let second = try await engine.transcribe(audio)

        #expect(first.map(\.speaker) == ["A"])
        #expect(second.map(\.text) == ["hi"])
        #expect(service.requests.count == 1)
        #expect(service.requests.first?.path == "/v1/audio/transcriptions")
        #expect(service.requests.first?.header("authorization") == "Bearer sk-test")
        #expect(service.requests.first?.header("content-type")?.hasPrefix("multipart/form-data") == true)
    }

    @Test("A key OpenAI refuses is the machine's problem, not the recording's")
    func openAIUnauthorized() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440, sampleRate: 16_000)
        let service = StubHTTP { _, _ in .json(401, #"{"error":{"message":"bad key"}}"#) }
        let engine = try OpenAITranscriptionEngine(apiKey: "sk-test", session: service.session)

        let error = await #expect(throws: CloudHTTP.Failure.self) { try await engine.transcribe(audio) }
        #expect(error?.isEnvironmental == true)
        #expect(ProviderCache.files(in: dir).isEmpty)
    }

    @Test("ElevenLabs gets one request per channel with its own key header")
    func elevenLabsPerChannel() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("multichannel.caf")
        try TestAudio.write(to: audio, seconds: 1, sampleRate: 48_000, channels: 2) { channel, frame in
            0.2 * Float(sin(Double(frame) * (channel == 0 ? 0.05 : 0.11)))
        }
        let service = StubHTTP { _, count in
            .json(200, """
            {"text":"x","words":[{"start":0.1,"end":0.5,"text":"word\(count)","type":"word","speaker_id":"speaker_0"}]}
            """)
        }
        let engine = try ElevenLabsEngine(apiKey: "xi-test", session: service.session)

        let segments = try await engine.transcribe(audio)

        #expect(service.requests.count == 2)
        #expect(service.requests.allSatisfy { $0.header("xi-api-key") == "xi-test" })
        #expect(Set(segments.compactMap(\.speaker)) == ["1A", "2A"])
        #expect(ProviderCache.files(in: dir).count == 2)
    }

    @Test("Fish keeps mic and far-end voices distinct and reuses their timed answers")
    func fishAudioPerChannelCache() async throws {
        try await withFreshHome { home in
            let audio = home.url.appendingPathComponent("multichannel.wav")
            try TestAudio.write(to: audio, seconds: 1, sampleRate: 48_000, channels: 2) { channel, frame in
                0.2 * Float(sin(Double(frame) * (channel == 0 ? 0.05 : 0.11)))
            }
            let service = StubHTTP { _, count in
                if count == 1 {
                    return .json(200, """
                    {"text":"Mic sentence.","duration":1,"speaker_turns":[
                      {"speaker":"speaker:0","text":"Mic sentence.","start":0.1,"end":0.5}]}
                    """)
                }
                return .json(200, """
                {"text":"First guest. Second guest.","duration":1,"speaker_turns":[
                  {"speaker":"speaker:0","text":"First guest.","start":0.2,"end":0.6},
                  {"speaker":"speaker:1","text":"Second guest.","start":0.7,"end":0.9}]}
                """)
            }

            let first = try await FishAudioEngine(apiKey: "fish-test", session: service.session).transcribe(audio)
            let second = try await FishAudioEngine(apiKey: "fish-test", session: service.session).transcribe(audio)

            for segments in [first, second] {
                #expect(segments.map(\.speaker) == ["1A", "2A", "2B"])
                #expect(segments.map(\.text) == ["Mic sentence.", "First guest.", "Second guest."])
                #expect(segments.map(\.start) == [0.1, 0.2, 0.7])
                #expect(segments.map(\.end) == [0.5, 0.6, 0.9])
                #expect(MultichannelSpeakerLabels.map(segments).map(\.speaker) == ["me A", "them A", "them B"])
            }
            #expect(service.requests.count == 2)
            #expect(ProviderCache.files(in: home.url).count == 2)
            #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent(
                TranscriptionScratch.fishAudioSliceFolder, isDirectory: true).path))
        }
    }
}
