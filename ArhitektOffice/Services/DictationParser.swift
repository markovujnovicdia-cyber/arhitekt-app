import Foundation

enum DictationCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case note = "Bilješka"
    case task = "Zadatak"
    case issue = "Problem"
    var id: String { rawValue }
}

struct DictationItem: Identifiable, Equatable {
    var id = UUID()
    var category: DictationCategory
    var text: String
}

struct DictationDraft {
    var originalText: String
    var projectID: UUID?
    var projectIsConfident: Bool
    var items: [DictationItem]
}

/// A local, deterministic first pass. Every suggestion remains editable and must
/// be confirmed by the user. Dates and priorities are never guessed silently.
enum DictationParser {
    static func parse(_ text: String, projects: [Project]) -> DictationDraft {
        let normalized = normalize(text)
        let candidates = projects.filter { !$0.isArchived }.filter { project in
            let name = normalize(project.name)
            let number = normalize(project.number)
            return (name.count >= 3 && containsPhrase(name, in: normalized)) ||
                (!number.isEmpty && containsPhrase(number, in: normalized))
        }
        // Multiple exact names/numbers are ambiguous, including nested names.
        let projectID = candidates.count == 1 ? candidates.first?.id : nil
        let pieces = splitSentences(text)
        return DictationDraft(
            originalText: text,
            projectID: projectID,
            projectIsConfident: projectID != nil,
            items: pieces.map { DictationItem(category: classify($0), text: $0) }
        )
    }

    static func classify(_ text: String) -> DictationCategory {
        let normalized = normalize(text)
        let taskPhrases = ["trebam", "treba nazvati", "treba poslati", "treba provjeriti",
                           "moram", "potrebno je", "zadatak", "nazovi", "posalji", "provjeri",
                           "pripremi", "dogovori", "podsjeti"]
        let issuePhrases = ["problem", "nedostaje", "nemamo", "kasni", "zapelo", "prepreka",
                            "nije rijeseno", "nije dostavljeno", "nije stiglo", "ne mozemo"]
        if issuePhrases.contains(where: { containsPhrase($0, in: normalized) }) { return .issue }
        if taskPhrases.contains(where: { containsPhrase($0, in: normalized) }) { return .task }
        return .note
    }

    private static func splitSentences(_ text: String) -> [String] {
        // Keep sentence punctuation and preserve the complete unmodified source
        // separately. Newlines also support manual transcripts without punctuation.
        let pattern = #"[^.!?\n]+(?:[.!?]+|(?=\n|$))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "hr_HR"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }
}
