import Foundation
import Testing

@testable import amanu

struct AuditCaptureSafetyTests {
    @Test("Denied microphone reopens setup even when it was completed previously",
          arguments: [true, false])
    func permissionRepair(setupPending: Bool) {
        let microphone = Check(name: "microphone", status: .fail("denied"), remediation: nil)
        #expect(DoctorReport.startupAction(checks: [microphone], setupPending: setupPending) == .setup)
        let folder = Check(name: "recordings", status: .fail("not writable"), remediation: nil)
        #expect(DoctorReport.startupAction(checks: [folder], setupPending: setupPending) == .refuse)
        #expect(DoctorReport.startupAction(checks: [], setupPending: setupPending)
                == (setupPending ? .setup : .proceed))
    }
    @Test("Short agreements cannot turn a local speaker's substantive answers into echo")
    func agreementsDoNotCondemnTheSpeaker() {
        var segments: [Transcript.Segment] = []
        for index in 0..<25 {
            let start = index * 2000
            segments.append(.init(speaker: "them A", start_ms: start, end_ms: start + 1200,
                                  text: "да сейчас рассказываю следующую часть доклада"))
            segments.append(.init(speaker: "me A", start_ms: start + 200, end_ms: start + 1000,
                                  text: index < 21 ? "да" : "предлагаю отменить решение и проверить бюджет"))
        }

        let kept = EchoFilter.dropEchoes(segments)
        #expect(kept.filter { $0.speaker == "me A" && $0.text.hasPrefix("предлагаю") }.count == 4)
    }

    @Test("An echo-dominated label does not justify deleting unrelated substantive speech")
    func substantialSpeechSurvivesAnEchoLabel() {
        var segments: [Transcript.Segment] = []
        for index in 0..<20 {
            let start = index * 2000
            for speaker in ["them A", "me A"] {
                segments.append(.init(speaker: speaker, start_ms: start, end_ms: start + 1000,
                                      text: "the quarterly report will be ready tomorrow"))
            }
        }
        segments.append(.init(speaker: "them A", start_ms: 41_000, end_ms: 42_000,
                              text: "and then we move to the next topic"))
        let reply = "Please stop because the budget has not been approved"
        segments.append(.init(speaker: "me A", start_ms: 41_100, end_ms: 42_100, text: reply))

        #expect(EchoFilter.dropEchoes(segments).contains { $0.text == reply })
    }

    @Test("Hearing the test tone does not complete an unfinished setup")
    func testToneDoesNotCompleteSetup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("setup.json")
        let heard = Date(timeIntervalSince1970: 1_800_000_000)

        SetupState.rememberSystemAudioHeard(now: heard, at: state)

        #expect(SetupState.systemAudioHeardAt(at: state) == heard)
        #expect(SetupState.isPending(at: state))
    }
}
