import Foundation
import Testing

@testable import amanu

/// `amanu doctor`'s summary line: the chain the config actually names, walked
/// against what this machine has — not whether some key or CLI exists
/// somewhere, which is what it used to ask whatever the summary was set to.
struct DoctorSummaryTests {
    private static let pulled = OllamaClient.Model(
        name: "qwen3:8b", bytes: 5_000_000_000, remoteModel: nil, remoteHost: nil)

    private static func check(
        summary: [String: Any], facts: DoctorReport.ModelFacts
    ) -> Check {
        let settings = Config.summary(in: ["summary": summary])
        let route = MeetingEgress.route(
            for: .summary, summary: settings, names: Config.SpeakerNamesSettings())
        return DoctorReport.evaluate("summary", route: route, facts: facts, settings: settings)
    }

    private static func warning(_ check: Check) -> String? {
        if case .warn(let message) = check.status { return message }
        return nil
    }

    private static var everythingButOllama: DoctorReport.ModelFacts {
        var facts = DoctorReport.ModelFacts()
        facts.claudeRuns = true
        facts.codexRuns = true
        facts.anthropicKey = true
        facts.openAIKey = true
        facts.ollama = .unreachable
        return facts
    }

    @Test("Doctor names the selected speaker model and its pinned terms",
          .freshHome(config: #"{"transcription":{"local_diarization":true,"diarization_model":"ls-eend-ami"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func selectedSpeakerModel() throws {
        let check = DoctorReport.checkDiarization()
        let message = try #require(Self.warning(check))
        #expect(message.contains("LS-EEND AMI"))
        #expect(message.contains("MIT"))
        #expect(message.contains("28ce1b1f8ef1"))
        #expect(check.remediation?.contains("LS-EEND AMI") == true)
        #expect(!message.contains("Community-1"))
    }

    @Test("Doctor defaults new speaker choice to Nemotron with its terms",
          .freshHome(config: #"{"transcription":{"local_diarization":true}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func defaultSpeakerModel() throws {
        let check = DoctorReport.checkDiarization()
        let message = try #require(Self.warning(check))
        #expect(message.contains("Nemotron 3"))
        #expect(message.contains("OpenMDW 1.1"))
        #expect(message.contains("f667ed73aee5"))
    }

    /// The case the old check got wrong: Ollama chosen, Ollama not running,
    /// and a claude CLI elsewhere on the machine making the line read "ok".
    @Test("Ollama chosen and not running is a warning, whatever else is installed")
    func explicitOllamaNotRunning() throws {
        let check = Self.check(summary: ["backend": "ollama"], facts: Self.everythingButOllama)
        let message = try #require(Self.warning(check))
        #expect(message.contains("nothing answers at http://127.0.0.1:11434"))
        #expect(check.remediation?.contains("start Ollama") == true)
    }

    @Test("Ollama running without the chosen model says which model to pull")
    func explicitOllamaWithoutTheModel() throws {
        var facts = DoctorReport.ModelFacts()
        facts.ollama = .running([OllamaClient.Model(
            name: "llama3:8b", bytes: 1, remoteModel: nil, remoteHost: nil)])
        let check = Self.check(summary: ["backend": "ollama"], facts: facts)
        #expect(Self.warning(check)?.contains("qwen3:8b is not pulled") == true)
        #expect(check.remediation == "ollama pull qwen3:8b")
    }

    @Test("Ollama running with the model, on this Mac, is simply fine")
    func explicitOllamaReady() {
        var facts = DoctorReport.ModelFacts()
        facts.ollama = .running([Self.pulled])
        guard case .ok = Self.check(summary: ["backend": "ollama"], facts: facts).status else {
            Issue.record("A local Ollama with its model is ready.")
            return
        }
    }

    @Test("An Ollama cloud model is ready but said to leave the machine")
    func ollamaCloudModel() {
        var facts = DoctorReport.ModelFacts()
        facts.ollama = .running([OllamaClient.Model(
            name: "qwen3:8b", bytes: 0, remoteModel: "qwen3", remoteHost: "https://ollama.com")])
        #expect(Self.warning(Self.check(summary: ["backend": "ollama"], facts: facts))?
            .contains("leaves this machine") == true)
    }

    @Test("A plain-http Ollama on another machine is refused, and the line says why")
    func lanOllamaOverHTTP() throws {
        let status = DoctorReport.ollamaStatus(baseURL: "http://studio.local:11434")
        guard case .refused(let why) = status else {
            Issue.record("Expected the Base URL to be refused, got \(status)")
            return
        }
        #expect(why.contains("https"))

        var facts = DoctorReport.ModelFacts()
        facts.ollama = status
        let check = Self.check(
            summary: ["backend": "ollama", "ollama_base_url": "http://studio.local:11434"],
            facts: facts)
        #expect(Self.warning(check)?.contains("Base URL is refused") == true)
    }

    @Test("Codex chosen and missing is a warning even with claude installed")
    func explicitCodexMissing() {
        var facts = Self.everythingButOllama
        facts.codexRuns = false
        let check = Self.check(summary: ["backend": "codex-cli"], facts: facts)
        #expect(Self.warning(check)?.contains("codex CLI") == true)
    }

    @Test("auto names the backend that will answer and what follows it")
    func autoNamesTheChain() {
        var facts = DoctorReport.ModelFacts()
        facts.codexRuns = true
        facts.ollama = .running([Self.pulled])
        let message = Self.warning(Self.check(summary: [:], facts: facts))
        #expect(message == "via codex-cli (then ollama) · the transcript leaves this machine")
    }

    @Test("auto with nothing but a local Ollama is fine")
    func autoFallsToLocalOllama() {
        var facts = DoctorReport.ModelFacts()
        facts.ollama = .running([Self.pulled])
        guard case .ok = Self.check(summary: [:], facts: facts).status else {
            Issue.record("Ollama alone on this Mac is a working chain.")
            return
        }
    }

    @Test("auto with nothing ready lists why each backend is not")
    func autoWithNothingReady() throws {
        let message = try #require(Self.warning(
            Self.check(summary: [:], facts: DoctorReport.ModelFacts())))
        #expect(message.hasPrefix("no backend is ready"))
        #expect(message.contains("claude CLI"))
        #expect(message.contains("nothing answers at"))
    }

    @Test("Summaries off, or a backend amanu does not know, are said as such")
    func offAndUnknown() {
        guard case .ok = Self.check(summary: ["enabled": false], facts: .init()).status else {
            Issue.record("Summaries off is not a problem.")
            return
        }
        #expect(Self.warning(Self.check(summary: ["backend": "olama"], facts: .init()))?
            .contains("not one amanu knows") == true)
    }

    @Test("Naming gets a line of its own only when it has a backend of its own",
          .freshHome(config: #"{"summary": {"backend": "none"}}"#))
    func speakerNamesLine() throws {
        #expect(DoctorReport.checkSpeakerNames() == nil)
        try Home.current.writeConfig([
            "summary": ["backend": "none"], "speaker_names": ["backend": "anthropic-api"],
        ])
        let check = try #require(DoctorReport.checkSpeakerNames())
        #expect(check.name == "speaker names")
        #expect(Self.warning(check)?.contains("no Anthropic key") == true)
    }
}
