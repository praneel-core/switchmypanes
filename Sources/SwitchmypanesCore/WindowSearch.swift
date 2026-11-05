import Foundation

/// Type-to-search in the window switcher: which windows match what you typed.
public enum WindowSearch {
    /// Lower-case, accent-insensitive form used for comparing ("Café" matches "cafe").
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Every space-separated word of the query must appear somewhere in the window's text (app name, title, tag...).
    /// An empty query matches everything.
    public static func matches(query: String, in texts: [String]) -> Bool {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = fold(texts.joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Keeps the original (most-recently-used) order.
    public static func filter<T>(_ items: [T], query: String, texts: (T) -> [String]) -> [T] {
        items.filter { matches(query: query, in: texts($0)) }
    }
}
