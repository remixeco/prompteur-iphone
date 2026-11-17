import Foundation

struct ScriptFollower {
    struct Line: Identifiable {
        let id: Int
        let text: String
        let startWord: Int
        fileprivate let wordStarts: [String.Index]

        var endWord: Int { startWord + wordStarts.count }

        func split(at position: Int) -> (read: String, unread: String) {
            if position <= startWord { return ("", text) }
            if position >= endWord { return (text, "") }
            let index = wordStarts[position - startWord]
            return (String(text[..<index]), String(text[index...]))
        }
    }

    let lines: [Line]
    private let words: [String]
    private(set) var position = 0

    private var committedPosition = 0
    private var heardCount = 0
    private var ignoredCount = 0
    private var trailingWords: [String] = []

    var wordCount: Int { words.count }
    var isFinished: Bool { wordCount > 0 && position == wordCount }
    var activeLine: Int {
        lines.firstIndex { position < $0.endWord } ?? max(0, lines.count - 1)
    }

    init(_ script: String) {
        var lines: [Line] = []
        var words: [String] = []
        for paragraph in script.split(whereSeparator: \.isNewline) {
            let groups = paragraph.split(whereSeparator: \.isWhitespace)
            for start in stride(from: 0, to: groups.count, by: 7) {
                let end = min(start + 6, groups.count - 1)
                let text = String(paragraph[groups[start].startIndex..<groups[end].endIndex])
                let ranges = Self.tokenRanges(in: text)
                guard !ranges.isEmpty else { continue }
                lines.append(Line(
                    id: lines.count, text: text, startWord: words.count,
                    wordStarts: ranges.map(\.lowerBound)
                ))
                words += ranges.map { Self.normalize(String(text[$0])) }
            }
        }
        self.lines = lines
        self.words = words
    }

    mutating func seek(toLine index: Int) {
        let line = max(0, min(index, lines.count))
        position = line == lines.count ? wordCount : lines[line].startWord
        committedPosition = position
        ignoredCount = max(ignoredCount, heardCount)
        trailingWords = []
    }

    mutating func reset() { seek(toLine: 0) }

    mutating func beginListening() {
        committedPosition = position
        heardCount = 0
        ignoredCount = 0
        trailingWords = []
    }

    mutating func update(_ text: String, isFinal: Bool) {
        let heard = Self.tokenRanges(in: text).map { Self.normalize(String(text[$0])) }
        heardCount = heard.count
        let utterance = trailingWords + heard.dropFirst(ignoredCount)
        let match = matchProgress(in: utterance)
        position = max(position, match.position)

        if isFinal {
            // Keep a short unmatched tail so a correction can span two recognition chunks.
            trailingWords = match.position == position
                ? Array(utterance.dropFirst(match.consumed).suffix(2))
                : []
            committedPosition = position
            ignoredCount = 0
            heardCount = 0
        }
    }

    private func matchProgress(in heard: [String]) -> (position: Int, consumed: Int) {
        var cursor = committedPosition
        var consumed = 0
        for index in heard.indices {
            guard cursor < words.count else { break }
            let word = heard[index]
            if word == words[cursor] {
                cursor += 1
                consumed = index + 1
                continue
            }

            // shortcut: skip only nearby words with a two-word anchor, use manual seek for larger jumps
            let limit = min(cursor + 7, words.count - 1)
            let nextHeard = heard.dropFirst(index + 1).prefix(2)
            guard cursor + 1 < limit, !nextHeard.isEmpty else { continue }
            if let anchor = ((cursor + 1)..<limit).first(where: { candidate in
                let nextWord = words[candidate + 1]
                return words[candidate] == word && word != nextWord
                    && (word.count > 3 || nextWord.count > 3)
                    && nextHeard.contains(nextWord)
            }) {
                cursor = anchor + 1
                consumed = index + 1
            }
        }
        return (cursor, consumed)
    }

    private static func tokenRanges(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /[\p{L}\p{M}\p{N}]+/)
    }

    private static func normalize(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
    }
}
