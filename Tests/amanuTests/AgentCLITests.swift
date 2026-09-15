import Foundation
import Testing

@testable import amanu

@Suite("Command-line link installation")
struct AgentCLITests {
    @Test("A Homebrew-managed command prevents a duplicate private link")
    func homebrewLinkWins() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let executable = root.appendingPathComponent("Applications/Amanu.app/Contents/MacOS/Amanu")
        let homebrewCLI = root.appendingPathComponent("homebrew/bin/amanu")
        let privateCLI = root.appendingPathComponent("home/.local/bin/amanu")
        try fm.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: homebrewCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("amanu".utf8).write(to: executable)
        try fm.createSymbolicLink(at: homebrewCLI, withDestinationURL: executable)
        defer { try? fm.removeItem(at: root) }

        let changed = try AgentCLI.install(
            at: privateCLI,
            to: executable,
            managedCLIs: [homebrewCLI],
            persistent: true
        ).get()

        #expect(!changed)
        #expect(!fm.fileExists(atPath: privateCLI.path))
    }
}
