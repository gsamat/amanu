import Darwin
import Foundation
import Testing

@testable import amanu

/// The suite used to read the developer's own `~/.config/amanu/config.json`,
/// their key files, and — through `LLMBackend.available` — their `claude`
/// CLI, Anthropic key and Ollama. Nothing did anything harmful with them only
/// because the fixtures happened to say "already summarized". `Home` is what
/// makes it structural, and like the banner test in `NativeAppTests`, this is
/// the pin: the property being relied on is of the test binary, so it is
/// asked out loud rather than assumed.
@Suite("A test cannot reach the person's home")
struct SandboxTests {
    /// Where the real home is, asked of the account rather than of anything
    /// `Home` controls.
    private static let realHome: String = {
        guard let record = getpwuid(getuid()), let dir = record.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return String(cString: dir)
    }()

    /// Every place amanu keeps something for the person, as the code sees it
    /// right now.
    private static func personalPaths() -> [String: URL] {
        var paths: [String: URL] = [
            "config": Config.path,
            "setup state": SetupState.path,
            "analytics identity": AnalyticsIdentity.path,
            "analytics queue": AnalyticsSink.defaultStore,
            "key drawer": Config.keysDir,
            "anthropic key": Config.anthropicKeyPath,
            "fish audio key": Config.fishAudioKeyPath,
            "default recordings": Config.defaultRoot,
            "recordings from ~": Home.current.expanding("~/Recordings"),
        ]
        let shared = Config.assemblyAISharedKeyPaths + Config.openAISharedKeyPaths
            + Config.elevenLabsSharedKeyPaths + Config.fishAudioSharedKeyPaths
            + Config.anthropicSharedKeyPaths
        for (index, url) in shared.enumerated() { paths["shared key \(index)"] = url }
        return paths
    }

    private static func expectNothingPersonal(_ context: String) {
        for (name, url) in personalPaths() {
            #expect(
                !url.path.hasPrefix(realHome + "/"),
                "\(name) resolves into the real home \(context): \(url.path)")
        }
        #expect(Home.current.variable("ANTHROPIC_API_KEY") == nil)
        #expect(Home.current.variable("OPENAI_API_KEY") == nil)
        #expect(Home.current.variable("ASSEMBLYAI_API_KEY") == nil)
        #expect(Home.current.variable("ELEVENLABS_API_KEY") == nil)
        #expect(Home.current.variable("FISH_API_KEY") == nil)
    }

    @Test("The code under test knows it is under test")
    func theBinaryIsATestBundle() {
        #expect(Home.runsInsideTests)
        #expect(!Home.process.discoversTools)
        #expect(Home.process.environment == [:])
    }

    @Test("Every personal path is inside a sandbox, whichever thread asks")
    func pathsAreSandboxed() async {
        Self.expectNothingPersonal("on the test's own task")
        // The two ways work leaves a task-local scope behind. Both land on
        // the process home, and in a test process that is a sandbox too.
        await Task.detached { Self.expectNothingPersonal("from a detached task") }.value
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                Self.expectNothingPersonal("from a dispatch queue")
                done.resume()
            }
        }
    }

    /// The first half of what could otherwise go out: a model. Every
    /// preference `LLMBackend` understands, including `ollama`, which the
    /// `auto` chain appends unconditionally and which needs no key at all.
    @Test("No language model is available to a test that did not bring one")
    func noLanguageModel() async {
        let preferences = ["auto", "claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama"]
        for preference in preferences {
            #expect(LLMBackend.available(preference: preference).isEmpty, "\(preference)")
        }
        await Task.detached {
            #expect(LLMBackend.available().isEmpty, "from a detached task")
        }.value
    }

    /// The second half: the machine's own tools. `zsh` is on every Mac and a
    /// login shell would find it at once, so a nil here is the gate and not
    /// the tool being missing.
    @Test("Nothing goes looking for the machine's tools")
    func noToolDiscovery() async {
        #expect(Tooling.path(for: "zsh") == nil)
        #expect(Tooling.probe("claude") == nil)
        #expect(await Tooling.ollamaModels() == nil)
        await Task.detached { #expect(Tooling.path(for: "zsh") == nil) }.value
    }

    /// And a test that wants a particular config gets its own, without the
    /// test beside it seeing it.
    @Test("A scoped home is the one config reads, and only inside its scope")
    func scopedHomes() throws {
        let outside = Config.path
        try withFreshHome(config: ["keep_audio": true]) { home in
            #expect(Config.path == home.configFile)
            #expect(Config.keepAudio())
        }
        #expect(Config.path == outside)
        #expect(!Config.keepAudio())
    }

    @Test("A test can hand the code a model of its own")
    func suppliedModels() {
        let fake = LLMBackend(name: "fake", model: nil) { _, _ in "answer" }
        let home = Home.sandbox(languageModels: { _ in [fake] })
        defer { try? FileManager.default.removeItem(at: home.url) }
        Home.$scoped.withValue(home) {
            #expect(LLMBackend.available().map(\.name) == ["fake"])
        }
    }
}
