import AppKit
import Foundation
import Testing
import os

@testable import amanu

@Suite(.serialized, .freshHome)
@MainActor
struct CompatibleTranscriptionSettingsTests {
    private func field<T: NSView>(_ id: String, in form: SetupForm, as: T.Type = T.self) throws -> T {
        try #require(form.view.allDescendants.first { $0.identifier?.rawValue == id } as? T)
    }

    @Test("Compatible server settings round-trip without becoming auto or borrowing credentials")
    func configurationAndTokenIsolation() throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "compatible": [
            "base_url": "https://speech.example/v1", "model": "private-speech", "protocol": "mlx-audio",
        ]]])
        try Credentials.writeSecret("openai-secret", to: Config.openAIKeyPath)
        try Credentials.writeSecret("summary-secret", to: Credentials.openAICompatibleKeyPath)
        #expect(Config.compatibleTranscriptionKey() == nil)
        let form = SetupForm()
        let toggle: NSSwitch = try field("transcription.compatible", in: form)
        #expect(toggle.state == .on)
        #expect(Config.compatibleTranscriptionBaseURL() == "https://speech.example/v1")
        #expect(Config.compatibleTranscriptionModel() == "private-speech")
        #expect(Config.compatibleTranscriptionProtocol() == "mlx-audio")
        let token: NSSecureTextField = try field("transcription.compatible.token", in: form)
        token.stringValue = "speech-secret"
        form.saveCompatibleToken()
        #expect(Config.compatibleTranscriptionKey() == "speech-secret")
        #expect(Config.openAIKey() == "openai-secret")
        #expect(Config.secret(at: Credentials.openAICompatibleKeyPath) == "summary-secret")
        #expect(!(Home.current.configText ?? "").contains("speech-secret"))
        form.reload()
        #expect(Config.transcriptionEngine() == "compatible")
        #expect(toggle.state == .on)
        form.stop()
    }

    @Test("A compatible token path outside Amanu is read but never overwritten by Setup")
    func namedTokenPathIsReadOnly() throws {
        let other = Home.current.url.appendingPathComponent("shared-secret")
        try Credentials.writeSecret("original", to: other)
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "compatible": [
            "api_key_path": other.path,
        ]]])
        let form = SetupForm()
        let token: NSSecureTextField = try field("transcription.compatible.token", in: form)
        token.stringValue = "replacement"
        form.saveCompatibleToken()
        #expect(Config.compatibleTranscriptionKey() == "original")
        #expect(Config.secret(at: other) == "original")
        form.stop()
    }

    @Test("Connection and recognition checks are independent and expose their real result")
    func separateChecks() async throws {
        let form = SetupForm()
        var connection = 0
        var recognition = 0
        form.checkCompatibleConnection = { connection += 1; return "server answered" }
        form.checkCompatibleRecognition = { recognition += 1; return "public phrase recognized" }
        form.checkCompatibleServer(recognition: false)
        await form.waitForCompatibleCheck()
        #expect(connection == 1 && recognition == 0)
        let status: NSTextField = try field("transcription.compatible.status", in: form)
        #expect(status.stringValue == "server answered")
        form.checkCompatibleServer(recognition: true)
        await form.waitForCompatibleCheck()
        #expect(connection == 1 && recognition == 1)
        #expect(status.stringValue == "public phrase recognized")
        form.stop()
    }

    @Test("Connection probing sends no audio and distinguishes HTTP response from authentication")
    func connectionProbeHasNoMeetingPayload() async throws {
        let methods = OSAllocatedUnfairLock(initialState: [String]())
        let session = StubbedService.session { request in
            #expect(request.httpBody == nil && request.httpBodyStream == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer speech-token")
            methods.withLock { $0.append(request.httpMethod ?? "") }
            return .success(request.httpMethod == "HEAD" ? 405 : 404)
        }
        let result = try await CompatibleTranscriptionProbe.connection(
            baseURL: "http://127.0.0.1:8000/v1", token: "speech-token", session: session)
        #expect(result.contains("404"))
        #expect(methods.withLock { $0 } == ["HEAD", "GET"])
        let refused = StubbedService.session { _ in .success(401) }
        await #expect(throws: CompatibleTranscriptionProbe.Failure.self) {
            _ = try await CompatibleTranscriptionProbe.connection(
                baseURL: "https://speech.example/v1", token: "wrong", session: refused)
        }
    }

    @Test("Failure to synthesize public speech sends nothing and removes its temporary directory")
    func failedSynthesisNeverUsesMeetingAudio() async {
        let generated = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let sent = OSAllocatedUnfairLock(initialState: false)
        let session = StubbedService.session { _ in sent.withLock { $0 = true }; return .success(200) }
        do {
            _ = try await CompatibleTranscriptionProbe.recognition(
                baseURL: "http://localhost:8000/v1", model: "test", token: nil,
                apiProtocol: "mlx-audio", session: session,
                synthesize: { url in
                    generated.withLock { $0 = url }
                    throw CompatibleTranscriptionProbe.Failure.speechFailed
                })
            Issue.record("Synthesis should have failed")
        } catch { }
        #expect(!sent.withLock { $0 })
        if let url = generated.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        } else { Issue.record("The public fixture path was not requested") }
    }
}
