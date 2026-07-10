/// Character-level similarity primitives used by the lexical tier.
enum StringMetrics {
    /// Bounded Damerau-Levenshtein (optimal string alignment) distance.
    /// Returns `nil` when the distance exceeds `limit`, allowing early exit.
    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty { return b.count <= limit ? b.count : nil }
        if b.isEmpty { return a.count <= limit ? a.count : nil }

        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = Swift.min(
                    previous[j] + 1,          // deletion
                    current[j - 1] + 1,       // insertion
                    previous[j - 1] + substitutionCost
                )
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = Swift.min(value, previousPrevious[j - 2] + 1) // transposition
                }
                current[j] = value
                rowMinimum = Swift.min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }

    /// Character trigram set with boundary padding.
    static func trigrams(of text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        let padded = Array("  " + text + " ")
        guard padded.count >= 3 else { return [] }
        var result = Set<String>()
        result.reserveCapacity(padded.count - 2)
        for i in 0...(padded.count - 3) {
            result.insert(String(padded[i...(i + 2)]))
        }
        return result
    }

    /// Sørensen–Dice coefficient over trigram sets, in [0, 1].
    static func diceSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        return 2.0 * Double(intersection) / Double(a.count + b.count)
    }
}
