import Foundation
import Testing

@testable import amanu

struct StartFailureBannerTests {
    @Test("The banner says the call is not being recorded, without the system's error text")
    func bannerNamesTheConsequence() {
        struct Reason: LocalizedError { var errorDescription: String? { "tap busy" } }
        for failure in [
            RecordingSession.StartFailure.microphone(Reason()),
            RecordingSession.StartFailure.systemAudio(Reason()),
        ] {
            let text = failure.bannerBody
            #expect(!text.contains("tap busy"), "the raw reason stays in the log")
            #expect(text.contains("not being recorded") || text.contains("не записывается"))
        }
    }
}
