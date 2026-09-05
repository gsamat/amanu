import Foundation
struct Transcript { struct Segment { let speaker: String; let start_ms: Int; let end_ms: Int; let text: String } }
@main struct Repro {
    static func main() {
        var segments: [Transcript.Segment] = []
        for i in 0..<25 {
            segments.append(.init(speaker: "them A", start_ms: i*2000, end_ms: i*2000+1200, text: "да сейчас рассказываю следующую часть доклада"))
            segments.append(.init(speaker: "me A", start_ms: i*2000+200, end_ms: i*2000+1000, text: i<21 ? "да" : "предлагаю отменить решение перенести встречу проверить бюджет"))
        }
        let filtered = EchoFilter.dropEchoes(segments)
        let important = filtered.filter { $0.speaker == "me A" && $0.text.hasPrefix("предлагаю") }
        print("Expected 4 substantive local statements retained; actual: \(important.count)")
        print("Local segments before: 25; after: \(filtered.filter { $0.speaker == "me A" }.count)")
    }
}
