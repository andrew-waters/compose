import ComposeModel
import Foundation

/// Variable substitution over scalar values, matching compose's shell-like forms.
///
/// Substitution happens per value rather than over the raw text, so a `$` inside a quoted
/// YAML string is still a `$` to YAML first and to this second, and every expansion keeps the
/// mark of the node it came from.
struct Interpolator {
    /// The lookup, already merged: shell environment over `.env` file.
    let variables: [String: String]

    func expand(
        _ text: String,
        path: String,
        mark: SourceMark?,
        warnings: inout [InterpolationWarning]
    ) throws -> String {
        guard text.contains("$") else { return text }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "$" else {
                output.append(character)
                index += 1
                continue
            }
            guard index + 1 < characters.count else {
                output.append("$")
                index += 1
                continue
            }
            let next = characters[index + 1]
            if next == "$" {
                // `$$` is how compose writes a literal dollar.
                output.append("$")
                index += 2
            } else if next == "{" {
                guard let close = Self.matchingBrace(characters, openBraceAt: index + 1) else {
                    throw ParseError(
                        reason: .invalidValue,
                        problem: "unterminated `${` in `\(text)`",
                        mark: mark,
                        path: path
                    )
                }
                let expression = String(characters[(index + 2)..<close])
                output += try evaluate(expression, path: path, mark: mark, warnings: &warnings)
                index = close + 1
            } else if Self.isNameStart(next) {
                var end = index + 1
                while end < characters.count, Self.isNameCharacter(characters[end]) { end += 1 }
                let name = String(characters[(index + 1)..<end])
                output += lookup(name, path: path, mark: mark, warnings: &warnings) ?? ""
                index = end
            } else {
                output.append("$")
                index += 1
            }
        }
        return output
    }

    /// One `${...}` body, which is a name and optionally an operator and a word. The word is
    /// expanded in turn, so `${TAG:-${DEFAULT_TAG}}` works.
    private func evaluate(
        _ expression: String,
        path: String,
        mark: SourceMark?,
        warnings: inout [InterpolationWarning]
    ) throws -> String {
        let characters = Array(expression)
        var end = 0
        while end < characters.count, Self.isNameCharacter(characters[end]) { end += 1 }
        let name = String(characters[0..<end])
        guard !name.isEmpty, Self.isNameStart(characters.first ?? " ") else {
            throw ParseError(
                reason: .invalidValue,
                problem: "`${\(expression)}` does not name a variable",
                mark: mark,
                path: path
            )
        }
        let remainder = String(characters[end...])
        let raw = variables[name]

        if remainder.isEmpty {
            return lookup(name, path: path, mark: mark, warnings: &warnings) ?? ""
        }

        let (op, word) = Self.split(remainder)
        guard let op else {
            throw ParseError(
                reason: .invalidValue,
                problem: "`${\(expression)}` is not a substitution this understands",
                mark: mark,
                path: path
            )
        }
        let expandedWord = try expand(word, path: path, mark: mark, warnings: &warnings)
        let isSet = raw != nil
        let isEmpty = (raw ?? "").isEmpty

        switch op {
        case .defaultIfUnsetOrEmpty:
            return isSet && !isEmpty ? (raw ?? "") : expandedWord
        case .defaultIfUnset:
            return isSet ? (raw ?? "") : expandedWord
        case .alternativeIfSetAndNotEmpty:
            return isSet && !isEmpty ? expandedWord : ""
        case .alternativeIfSet:
            return isSet ? expandedWord : ""
        case .requiredNotEmpty where !isSet || isEmpty,
             .required where !isSet:
            let detail = expandedWord.isEmpty ? "" : ": \(expandedWord)"
            throw ParseError(
                reason: .requiredVariableUnset,
                problem: "`\(name)` is required and is not set\(detail)",
                mark: mark,
                path: path
            )
        case .requiredNotEmpty, .required:
            return raw ?? ""
        }
    }

    private func lookup(
        _ name: String,
        path: String,
        mark: SourceMark?,
        warnings: inout [InterpolationWarning]
    ) -> String? {
        if let value = variables[name] { return value }
        warnings.append(InterpolationWarning(variable: name, path: path, mark: mark))
        return nil
    }

    private enum Operator {
        case defaultIfUnsetOrEmpty      // ${VAR:-word}
        case defaultIfUnset             // ${VAR-word}
        case alternativeIfSetAndNotEmpty // ${VAR:+word}
        case alternativeIfSet           // ${VAR+word}
        case requiredNotEmpty           // ${VAR:?message}
        case required                   // ${VAR?message}
    }

    private static func split(_ remainder: String) -> (Operator?, String) {
        let pairs: [(String, Operator)] = [
            (":-", .defaultIfUnsetOrEmpty),
            (":+", .alternativeIfSetAndNotEmpty),
            (":?", .requiredNotEmpty),
            ("-", .defaultIfUnset),
            ("+", .alternativeIfSet),
            ("?", .required),
        ]
        for (token, op) in pairs where remainder.hasPrefix(token) {
            return (op, String(remainder.dropFirst(token.count)))
        }
        return (nil, remainder)
    }

    /// Index of the `}` closing the `{` at `openBraceAt`, counting nested `${`.
    private static func matchingBrace(_ characters: [Character], openBraceAt start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == "{" {
                depth += 1
            } else if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func isNameStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}

/// The `.env` and `env_file` format, which is not YAML and not a shell script, however much it
/// looks like one.
enum DotEnv {
    /// Parse in file order, so a key written twice takes its last value, as every other
    /// implementation of this format does.
    static func parse(_ text: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            pairs.append((key, unquote(rawValue)))
        }
        return pairs
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        // An unquoted value ends at a comment, but only one introduced by whitespace: a `#`
        // in the middle of a password is part of the password.
        if let hash = value.range(of: " #") {
            return String(value[value.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
