import Foundation

enum QuestionDetector {
    /// Whether a finished piece of speech sounds like a question or request.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("?") { return true }  // the speech recognizer adds question marks
        let starters = ["what", "why", "how", "when", "where", "which", "who", "can you", "could you", "would you",
                        "do you", "did you", "have you", "are you", "is it", "is there", "tell me", "explain", "describe"]
        return t.split(separator: " ").count >= 4 && starters.contains { t.hasPrefix($0) }
    }

    /// Whether a finished piece of speech should be answered: a question, or a request such as
    /// "write me a logistic regression model from scratch".
    static func wantsAnswer(_ text: String) -> Bool {
        !isCallPhrase(withoutOpeners(text)) && (looksLikeQuestion(text) || looksLikeRequest(text))
    }

    /// Lowercased, without openers that don't change what's asked: "so", "okay", "um", "please", "I want you to"…
    static func withoutOpeners(_ text: String) -> String {
        var t = text.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let opener = #"^(?:(?:so|okay|ok|alright|all right|right|um+|uh+|uhm|erm|hmm+|now|and|also|then|next|well|yeah|yes|hey|please|just|kindly|basically|actually|quickly|can you|could you|would you|will you|i want you to|i need you to|i'd like you to|i would like you to)\b[\s,.!-]*)+"#
        if let r = t.range(of: opener, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    /// Everyday call phrases that start like a request but aren't asking for an answer ("give me a second").
    static func isCallPhrase(_ t: String) -> Bool {
        let chat = #"^(give me (a |one |just a )?(sec|second|seconds|minute|minutes|min|moment|bit)\b|make sure\b|(write|note|jot) (that|it|this) down\b|(show|share) (me )?(your|my) screen\b|tell me (when|if)\b|check (the|your|my) (chat|mic|microphone|audio|camera|email|inbox|messages)\b|find (a |some )?time\b|give me a (call|ring|shout)\b|count me in\b)"#
        return t.range(of: chat, options: .regularExpression) != nil
    }

    /// Whether spoken words ask for something without being phrased as a question:
    /// "write me a logistic regression model from scratch", "so, explain how DNS works".
    /// For speech only; on screen the same words are often buttons ("Create account").
    static func looksLikeRequest(_ text: String) -> Bool {
        let t = withoutOpeners(text)
        guard t.split(separator: " ").count >= 3 else { return false }

        let asks = #"^(write|code|implement|build|create|make|generate|design|develop|program|explain|describe|define|tell me|give me|show me|teach me|walk me through|talk me through|take me through|help me|list|name|summari[sz]e|solve|calculate|compute|work out|figure out|find|compare|translate|draft|debug|fix|optimi[sz]e|improve|convert|derive|prove|outline|suggest|recommend|plot|draw|rewrite|refactor|analy[sz]e|evaluate|simplify|sort|reverse|count|break down|go through|go over|answer)\b"#
        return t.range(of: asks, options: .regularExpression) != nil && !isCallPhrase(t)
    }

    /// Share of words two sentences have in common (0…1).
    static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<Substring> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }) }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count))
    }
}

/// Typed or spoken instructions about where to look, e.g. "read the left side of the screen".
enum ScreenCommand: Equatable {
    enum Side: String { case left, right, top, bottom }
    case watchSide(Side)
    case watchWholeScreen
    case stopWatching

    static func parse(_ text: String) -> ScreenCommand? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 160 else { return nil }  // commands are short; longer text is a real message
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

        if has(#"\bstop (watching|reading|looking|monitoring)\b"#) { return .stopWatching }
        guard has(#"\b(read|watch|look at|looking at|monitor|focus on|keep an eye on|follow|answer from|check)\b"#) else { return nil }

        // A side of the screen: "left side", "right half", "top part", "left of the screen", ...
        let sideWords = #"(-hand)?( side| half| part| area| corner| of (the|my) screen)"#
        if has(#"\bleft"# + sideWords) { return .watchSide(.left) }
        if has(#"\bright"# + sideWords) { return .watchSide(.right) }
        if has(#"\b(top|upper)"# + sideWords) { return .watchSide(.top) }
        if has(#"\b(bottom|lower)"# + sideWords) { return .watchSide(.bottom) }

        if has(#"\b(whole|entire|full) screen\b"#) || has(#"\b(read|watch|look at|monitor|follow) (my|the) screen\b"#) {
            return .watchWholeScreen
        }
        return nil
    }
}
