import Foundation

/// Language-agnostic text normalization and tokenization for the lexical tier.
enum TextNormalizer {
    /// Small multilingual stopword list (function words in English, Spanish,
    /// Catalan, French, German, Italian, Portuguese). Kept deliberately
    /// short: it only filters glue words from *queries*, never from the
    /// index, so an over-aggressive list cannot hide action terms.
    private static let stopwords: Set<String> = Set([
        // English
        "a", "an", "the", "to", "of", "in", "on", "for", "with", "and",
        "or", "is", "it", "my", "this", "that", "me", "at", "as", "into",
        // Spanish
        "de", "la", "el", "los", "las", "un", "una", "unos", "unas", "en",
        "y", "o", "del", "al", "por", "para", "con", "que", "es", "mi",
        "este", "esta", "lo",
        // Catalan
        "els", "les", "i", "amb", "per", "dels", "aquest", "aquesta", "em",
        // French
        "le", "du", "des", "et", "ou", "au", "aux", "pour", "dans", "ce",
        "cette", "je", "sur",
        // German
        "der", "die", "das", "den", "dem", "ein", "eine", "und", "oder",
        "zu", "mit", "fur", "im", "auf",
        // Italian
        "il", "gli", "di", "da", "nel", "nella", "e",
        // Portuguese
        "os", "as", "um", "uma", "do", "dos", "das", "no", "na", "em",
        "com", "ao",
    ])

    /// Lowercases and strips diacritics/width so that "Vídeo" == "video".
    static func normalize(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        .lowercased()
    }

    /// Splits normalized text on non-alphanumeric boundaries.
    static func tokenize(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Query tokens worth matching: stopwords and single characters are
    /// dropped, unless that would drop everything.
    static func contentTokens(_ tokens: [String]) -> [String] {
        let filtered = tokens.filter { $0.count >= 2 && !stopwords.contains($0) }
        return filtered.isEmpty ? tokens : filtered
    }
}
