import FluidAudio
import Foundation
import Testing

@testable import amanu

/// The setting stopped meaning "transcribe in this language" and started
/// meaning "expect these languages". These are the rules that turn one into
/// the other, and the one that keeps a Russian menu entry from quietly
/// becoming a Cyrillic filter over an English meeting.
struct MeetingLanguagesTests {
    @Test("The five spoken languages come first, in the order they are listed")
    func pinnedComeFirst() {
        let head = MeetingLanguages.menu.prefix(MeetingLanguages.pinned.count).map(\.code)
        #expect(head == MeetingLanguages.pinned)
    }

    @Test("The rest follow by name, each language offered once")
    func restIsAlphabeticalAndUnique() {
        let codes = MeetingLanguages.menu.map(\.code)
        #expect(Set(codes).count == codes.count)

        let tail = MeetingLanguages.menu.dropFirst(MeetingLanguages.pinned.count).map(\.name)
        #expect(tail == tail.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(tail.first == "Bosanski")
    }

    /// The menu is built from FluidAudio's own list, so a language it learns
    /// arrives here without a name and is silently dropped. That is the right
    /// failure — better an absent entry than one that means nothing — but it
    /// should be noticed, and this is where.
    @Test("Every language the engine knows is offered under a name")
    func everyEngineLanguageHasAName() {
        let offered = Set(MeetingLanguages.menu.map(\.code))
        let known = Set(Language.allCases.map(\.rawValue))
        #expect(offered == known)
    }

    @Test("Naming a language expects English alongside it")
    func expectedAddsEnglish() {
        #expect(MeetingLanguages.expected(primary: "ru") == ["ru", "en"])
        #expect(MeetingLanguages.expected(primary: " RU ") == ["ru", "en"])
        #expect(MeetingLanguages.expected(primary: "de") == ["de", "en"])
    }

    @Test("English on its own expects nothing else")
    func englishStandsAlone() {
        #expect(MeetingLanguages.expected(primary: "en") == ["en"])
    }

    /// A code nobody can transcribe is the same as no code: an expectation
    /// that can't be met is worse than none, because it would be passed on to
    /// the engines as if it could.
    @Test("An unset or unknown language expects nothing")
    func unknownExpectsNothing() {
        #expect(MeetingLanguages.expected(primary: nil).isEmpty)
        #expect(MeetingLanguages.expected(primary: "").isEmpty)
        #expect(MeetingLanguages.expected(primary: "  ").isEmpty)
        #expect(MeetingLanguages.expected(primary: "klingon").isEmpty)
        #expect(MeetingLanguages.expected(primary: "ru-RU").isEmpty)
    }

    @Test("The expected set reads as a sentence for the places that report it")
    func describesItself() {
        #expect(MeetingLanguages.describe(["ru", "en"]) == "Русский and English")
        #expect(MeetingLanguages.describe(["en"]) == "English")
        #expect(MeetingLanguages.describe([]) == "any language")
    }
}

/// parakeet's language flag is a script filter and nothing finer, so these are
/// about alphabets rather than languages: when one can be assumed, and how the
/// audio answers when it can't.
struct ParakeetScriptTests {
    @Test("An expected set in one alphabet settles the filter before transcribing")
    func oneAlphabetSettlesIt() {
        #expect(ParakeetEngine.sharedScript(of: [.english]) == .english)
        #expect(ParakeetEngine.sharedScript(of: [.russian, .ukrainian]) == .russian)
        #expect(ParakeetEngine.sharedScript(of: [.english, .polish]) == .english)
    }

    /// The ordinary case, and the reason any of this exists: Russian and
    /// English cannot share a filter, so nothing may be assumed from the
    /// setting alone.
    @Test("Two alphabets settle nothing")
    func twoAlphabetsSettleNothing() {
        #expect(ParakeetEngine.sharedScript(of: [.russian, .english]) == nil)
        #expect(ParakeetEngine.sharedScript(of: []) == nil)
    }

    @Test("The alphabet a transcript came back in is its majority of letters")
    func dominantScriptIsTheMajority() {
        #expect(ParakeetEngine.dominantScript(of: "Давайте начнём со сроков.") == .cyrillic)
        #expect(ParakeetEngine.dominantScript(of: "Let's start with the timeline.") == .latin)
        #expect(ParakeetEngine.dominantScript(of: "Ναι, συμφωνώ.") == .greek)
    }

    /// Meetings are not pure. A Russian one is full of English product names,
    /// and the filter has to follow the language being spoken rather than the
    /// last word borrowed into it.
    @Test("Borrowed words don't carry the vote")
    func borrowingsDoNotDecide() {
        let mixed = "Задеплоили новый билд, но staging всё ещё падает на CI."
        #expect(ParakeetEngine.dominantScript(of: mixed) == .cyrillic)
    }

    @Test("Text with no letters decides nothing")
    func nothingToConcludeFromSilence() {
        #expect(ParakeetEngine.dominantScript(of: "") == nil)
        #expect(ParakeetEngine.dominantScript(of: "… — 12:30 (!) ") == nil)
    }
}
