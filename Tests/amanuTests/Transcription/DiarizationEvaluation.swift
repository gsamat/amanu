import Foundation

/// Private-corpus scoring support. This lives in the test target so no reporting
/// or annotation format becomes part of Amanu's transcript contract.
enum DiarizationEvaluation {
    struct Turn: Codable {
        let speaker: String?
        let start: Double
        let end: Double

        init(_ speaker: String?, _ start: Double, _ end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    struct Word: Codable {
        let text: String
        let start: Double
        let end: Double
        let speaker: String?

        init(_ text: String, _ start: Double, _ end: Double, _ speaker: String?) {
            self.text = text
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    struct DER {
        let reference: Double
        let missed: Double
        let falseAlarm: Double
        let confusion: Double
        var der: Double? {
            reference > 0 ? (missed + falseAlarm + confusion) / reference : nil
        }
    }

    struct Attribution {
        let reference: Int
        let hypothesis: Int
        let matched: Int
        let wrong: Int
        let unknown: Int
        let unknownHypothesis: Int
        var unmatched: Int { reference - matched }
    }

    /// Continuous-time DER. A fixed collar masks both sides of every reference
    /// turn boundary; the global one-to-one mapping maximizes coactive time.
    static func der(
        reference: [Turn],
        hypothesis: [Turn],
        collar: Double = 0.25,
        includeOverlap: Bool = true
    ) -> DER {
        let collars = reference.flatMap { [$0.start, $0.end] }
        let boundaries = Set((reference + hypothesis).flatMap { [$0.start, $0.end] }
            + collars.flatMap { [$0 - collar, $0 + collar] }).sorted()
        var slices: [(Set<String>, Set<String>, Double)] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let midpoint = (start + end) / 2
            if collars.contains(where: { abs(midpoint - $0) < collar }) { continue }
            let refs = Set(reference.filter { $0.start < midpoint && midpoint < $0.end }
                .compactMap(\.speaker))
            if !includeOverlap && refs.count > 1 { continue }
            let hyps = Set(hypothesis.filter { $0.start < midpoint && midpoint < $0.end }
                .compactMap(\.speaker).filter { !isUnknown($0) })
            slices.append((refs, hyps, end - start))
        }

        let refIDs = Set(slices.flatMap { $0.0 }).sorted()
        let hypIDs = Set(slices.flatMap { $0.1 }).sorted()
        var weights = Array(repeating: Array(repeating: 0.0, count: refIDs.count),
                            count: hypIDs.count)
        for (refs, hyps, seconds) in slices {
            for (h, hyp) in hypIDs.enumerated() where hyps.contains(hyp) {
                for (r, ref) in refIDs.enumerated() where refs.contains(ref) {
                    weights[h][r] += seconds
                }
            }
        }
        let assignment = optimalMapping(weights: weights)
        let mapped = Dictionary(uniqueKeysWithValues: assignment.compactMap { h, r in
            r < refIDs.count ? (hypIDs[h], refIDs[r]) : nil
        })

        var score = DER(reference: 0, missed: 0, falseAlarm: 0, confusion: 0)
        for (refs, hyps, seconds) in slices {
            let matched = hyps.reduce(0) { count, hyp in
                count + (mapped[hyp].map(refs.contains) == true ? 1 : 0)
            }
            score = DER(
                reference: score.reference + Double(refs.count) * seconds,
                missed: score.missed + Double(max(refs.count - hyps.count, 0)) * seconds,
                falseAlarm: score.falseAlarm + Double(max(hyps.count - refs.count, 0)) * seconds,
                confusion: score.confusion
                    + Double(min(refs.count, hyps.count) - matched) * seconds)
        }
        return score
    }

    static func wordAttribution(reference: [Word], hypothesis: [Word]) -> Attribution {
        var pairs: [(Word, Word, Double)] = []
        var unused = Set(hypothesis.indices)
        for ref in reference {
            var best: (Int, Double)?
            for index in unused {
                let seconds = max(0, min(ref.end, hypothesis[index].end)
                    - max(ref.start, hypothesis[index].start))
                if seconds > (best?.1 ?? 0)
                    || seconds == best?.1 && index < (best?.0 ?? Int.max) {
                    best = (index, seconds)
                }
            }
            guard let (index, seconds) = best else { continue }
            unused.remove(index)
            pairs.append((ref, hypothesis[index], seconds))
        }
        let refIDs = Set(pairs.compactMap { $0.0.speaker }).sorted()
        let hypIDs = Set(pairs.compactMap { $0.1.speaker }.filter { !isUnknown($0) }).sorted()
        var weights = Array(repeating: Array(repeating: 0.0, count: refIDs.count),
                            count: hypIDs.count)
        for (ref, hyp, seconds) in pairs {
            guard let r = ref.speaker.flatMap(refIDs.firstIndex),
                  let h = hyp.speaker.flatMap(hypIDs.firstIndex) else { continue }
            weights[h][r] += seconds
        }
        let assignment = optimalMapping(weights: weights)
        let mapped = Dictionary(uniqueKeysWithValues: assignment.compactMap { h, r in
            r < refIDs.count ? (hypIDs[h], refIDs[r]) : nil
        })
        let unknown = pairs.filter { isUnknown($0.1.speaker) }.count
        let wrong = pairs.filter { ref, hyp, _ in
            !isUnknown(hyp.speaker) && mapped[hyp.speaker!] != ref.speaker
        }.count
        return Attribution(
            reference: reference.count, hypothesis: hypothesis.count,
            matched: pairs.count, wrong: wrong, unknown: unknown,
            unknownHypothesis: hypothesis.filter { isUnknown($0.speaker) }.count)
    }

    static func wer(reference: [Word], hypothesis: [Word]) -> Double? {
        let expected = reference.flatMap { tokens($0.text) }
        let actual = hypothesis.flatMap { tokens($0.text) }
        guard !expected.isEmpty else { return nil }
        var previous = Array(0...actual.count)
        for (row, word) in expected.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: actual.count)
            for (column, candidate) in actual.enumerated() {
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (word == candidate ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func isUnknown(_ label: String?) -> Bool {
        guard let label else { return true }
        return label == "unknown" || label.hasSuffix(" ?")
    }

    /// Rectangular maximum-weight assignment, padded with dummy speakers.
    /// Hungarian O(n³) keeps evaluation valid beyond alphabetic label limits.
    private static func optimalMapping(weights: [[Double]]) -> [Int: Int] {
        let rows = weights.count
        let columns = weights.first?.count ?? 0
        guard rows > 0 else { return [:] }
        let size = max(rows, columns)
        let maximum = weights.flatMap { $0 }.max() ?? 0
        var u = Array(repeating: 0.0, count: size + 1)
        var v = Array(repeating: 0.0, count: size + 1)
        var p = Array(repeating: 0, count: size + 1)
        var way = Array(repeating: 0, count: size + 1)
        for row in 1...size {
            p[0] = row
            var column = 0
            var minValues = Array(repeating: Double.infinity, count: size + 1)
            var used = Array(repeating: false, count: size + 1)
            repeat {
                used[column] = true
                let currentRow = p[column]
                var delta = Double.infinity
                var next = 0
                for candidate in 1...size where !used[candidate] {
                    let weight = currentRow <= rows && candidate <= columns
                        ? weights[currentRow - 1][candidate - 1] : 0
                    let cost = maximum - weight - u[currentRow] - v[candidate]
                    if cost < minValues[candidate] {
                        minValues[candidate] = cost
                        way[candidate] = column
                    }
                    if minValues[candidate] < delta {
                        delta = minValues[candidate]
                        next = candidate
                    }
                }
                for candidate in 0...size {
                    if used[candidate] {
                        u[p[candidate]] += delta
                        v[candidate] -= delta
                    } else {
                        minValues[candidate] -= delta
                    }
                }
                column = next
            } while p[column] != 0
            repeat {
                let previous = way[column]
                p[column] = p[previous]
                column = previous
            } while column != 0
        }
        var mapping: [Int: Int] = [:]
        for column in 1...size where p[column] <= rows && p[column] > 0 {
            mapping[p[column] - 1] = column - 1
        }
        return mapping
    }
}
