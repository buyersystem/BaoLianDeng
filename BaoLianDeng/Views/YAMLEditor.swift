// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import UIKit

// MARK: - YAML Syntax Highlighted Text Editor

struct YAMLEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var validationErrors: [YAMLError]
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .systemBackground
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.alwaysBounceVertical = true
        // Enable horizontal scrolling for long lines
        textView.isScrollEnabled = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.isEditable = isEditable
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.isEditable = isEditable
        // Avoid re-applying if the user is actively editing
        if textView.text != text {
            let selectedRange = textView.selectedRange
            context.coordinator.isUpdating = true
            textView.attributedText = YAMLHighlighter.highlight(text)
            textView.selectedRange = selectedRange
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: YAMLEditor
        var isUpdating = false
        private var debounceTimer: Timer?

        init(_ parent: YAMLEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }

            // Update the binding
            parent.text = textView.text

            // Re-highlight with debounce to avoid lag during fast typing
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.isUpdating = true
                let selectedRange = textView.selectedRange
                textView.attributedText = YAMLHighlighter.highlight(textView.text)
                // Restore cursor position safely
                if selectedRange.location <= textView.textStorage.length {
                    textView.selectedRange = selectedRange
                }
                self.isUpdating = false

                // Validate
                self.parent.validationErrors = YAMLValidator.validate(textView.text)
            }
        }
    }
}

// MARK: - YAML Syntax Highlighter

enum YAMLHighlighter {
    // Color palette
    private static let keyColor = UIColor.systemBlue
    private static let stringColor = UIColor.systemGreen
    private static let numberColor = UIColor.systemOrange
    private static let boolColor = UIColor.systemPurple
    private static let commentColor = UIColor.systemGray
    private static let anchorColor = UIColor.systemTeal
    private static let listDashColor = UIColor.systemRed
    private static let defaultColor = UIColor.label

    static func highlight(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: defaultColor,
            ]
        )

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Process line by line for context-aware highlighting
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let nsRange = NSRange(lineRange, in: text)
            let line = nsText.substring(with: nsRange)
            Self.highlightLine(line, at: nsRange.location, in: attributed)
        }

        // Multiline strings with | or > are handled at line level

        // Anchors & aliases: &name and *name
        Self.applyRegex("(?<=\\s)[&*][a-zA-Z_][a-zA-Z0-9_]*", color: anchorColor, in: attributed, range: fullRange, text: nsText)

        return attributed
    }

    private static func highlightLine(_ line: String, at offset: Int, in attributed: NSMutableAttributedString) {
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)

        // Full-line comment
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let commentRange = NSRange(location: offset, length: nsLine.length)
            attributed.addAttribute(.foregroundColor, value: commentColor, range: commentRange)
            return
        }

        // Inline comment: find # not inside quotes
        if let commentStart = findInlineCommentStart(in: line) {
            let commentNSRange = NSRange(location: offset + commentStart, length: nsLine.length - commentStart)
            attributed.addAttribute(.foregroundColor, value: commentColor, range: commentNSRange)
        }

        // List dash at line start: "  - "
        if let dashMatch = try? NSRegularExpression(pattern: "^(\\s*)(-\\s)", options: [])
            .firstMatch(in: line, range: lineRange) {
            let dashRange = dashMatch.range(at: 2)
            let adjustedRange = NSRange(location: offset + dashRange.location, length: dashRange.length)
            attributed.addAttribute(.foregroundColor, value: listDashColor, range: adjustedRange)
        }

        // Key-value pair: "key:" at line start (with optional leading spaces/dash)
        if let kvMatch = try? NSRegularExpression(pattern: "^(\\s*(?:-\\s+)?)([a-zA-Z0-9_][a-zA-Z0-9_.\\-]*)\\s*(:)", options: [])
            .firstMatch(in: line, range: lineRange) {
            // Highlight key name
            let keyRange = kvMatch.range(at: 2)
            let adjustedKeyRange = NSRange(location: offset + keyRange.location, length: keyRange.length)
            attributed.addAttribute(.foregroundColor, value: keyColor, range: adjustedKeyRange)

            // Highlight the colon
            let colonRange = kvMatch.range(at: 3)
            let adjustedColonRange = NSRange(location: offset + colonRange.location, length: colonRange.length)
            attributed.addAttribute(.foregroundColor, value: keyColor, range: adjustedColonRange)

            // Highlight value after colon
            let valueStart = kvMatch.range.location + kvMatch.range.length
            if valueStart < nsLine.length {
                let valueStr = nsLine.substring(from: valueStart).trimmingCharacters(in: .whitespaces)
                let valueTrimmedStart = (line as NSString).range(of: valueStr, options: [], range: NSRange(location: valueStart, length: nsLine.length - valueStart))
                if valueTrimmedStart.location != NSNotFound {
                    let adjustedValueRange = NSRange(location: offset + valueTrimmedStart.location, length: valueTrimmedStart.length)
                    highlightValue(valueStr, range: adjustedValueRange, in: attributed)
                }
            }
        }

        // Quoted strings anywhere in the line
        applyRegex("\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", color: stringColor, in: attributed,
                    range: NSRange(location: offset, length: nsLine.length), text: attributed.string as NSString)
        applyRegex("'[^']*'", color: stringColor, in: attributed,
                    range: NSRange(location: offset, length: nsLine.length), text: attributed.string as NSString)
    }

    private static func highlightValue(_ value: String, range: NSRange, in attributed: NSMutableAttributedString) {
        let stripped = value.trimmingCharacters(in: .whitespaces)
        // Remove inline comment portion
        let effectiveValue: String
        if let hashIdx = findInlineCommentStart(in: stripped) {
            effectiveValue = String(stripped.prefix(hashIdx)).trimmingCharacters(in: .whitespaces)
        } else {
            effectiveValue = stripped
        }

        // Boolean
        if ["true", "false", "yes", "no", "on", "off", "True", "False", "Yes", "No", "On", "Off", "TRUE", "FALSE", "YES", "NO", "ON", "OFF"]
            .contains(effectiveValue) {
            attributed.addAttribute(.foregroundColor, value: boolColor, range: range)
            return
        }

        // Null
        if ["null", "Null", "NULL", "~"].contains(effectiveValue) {
            attributed.addAttribute(.foregroundColor, value: boolColor, range: range)
            return
        }

        // Number (integer or float)
        if effectiveValue.range(of: "^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil {
            attributed.addAttribute(.foregroundColor, value: numberColor, range: range)
            return
        }

        // Quoted strings are handled separately
        if (effectiveValue.hasPrefix("\"") && effectiveValue.hasSuffix("\"")) ||
           (effectiveValue.hasPrefix("'") && effectiveValue.hasSuffix("'")) {
            attributed.addAttribute(.foregroundColor, value: stringColor, range: range)
            return
        }

        // Block scalar indicators
        if effectiveValue == "|" || effectiveValue == ">" || effectiveValue == "|-" || effectiveValue == ">-" {
            attributed.addAttribute(.foregroundColor, value: stringColor, range: range)
            return
        }
    }

    /// Find the start index of an inline comment (# not inside quotes)
    private static func findInlineCommentStart(in line: String) -> Int? {
        var inDouble = false
        var inSingle = false
        var prev: Character = "\0"

        for (i, ch) in line.enumerated() {
            if ch == "\"" && !inSingle && prev != "\\" { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#" && !inDouble && !inSingle && (i == 0 || line[line.index(line.startIndex, offsetBy: i - 1)] == " ") {
                return i
            }
            prev = ch
        }
        return nil
    }

    private static func applyRegex(_ pattern: String, color: UIColor, in attributed: NSMutableAttributedString, range: NSRange, text: NSString) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        // Clamp range to text length
        let safeRange = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        regex.enumerateMatches(in: text as String, range: safeRange) { match, _, _ in
            guard let matchRange = match?.range else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: matchRange)
        }
    }
}

// MARK: - YAML Validator

struct YAMLError: Identifiable {
    let id = UUID()
    let line: Int
    let message: String
}

enum YAMLValidator {
    static func validate(_ text: String) -> [YAMLError] {
        var errors: [YAMLError] = []
        let lines = text.components(separatedBy: "\n")
        var indentStack: [Int] = [0]

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1

            // Skip empty lines and comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Check for tabs (YAML only allows spaces)
            if line.contains("\t") {
                errors.append(YAMLError(line: lineNum, message: "Tabs are not allowed in YAML, use spaces"))
            }

            // Calculate indentation
            let indent = line.prefix(while: { $0 == " " }).count

            // Check odd indentation (common error, though technically valid)
            // Skip this check as some configs use 2-space indent

            // Check for trailing whitespace on non-empty lines
            if line != trimmed && line.last == " " && !trimmed.isEmpty {
                // This is a soft warning, skip for now
            }

            // Check for duplicate colons in key (likely malformed)
            if let colonIdx = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("-") {
                let afterColon = trimmed[trimmed.index(after: colonIdx)...]
                if afterColon.first != nil && afterColon.first != " " && afterColon.first != "\n"
                    && !trimmed.hasPrefix("http") && !trimmed.hasPrefix("https")
                    && !trimmed.hasPrefix("\"") && !trimmed.hasPrefix("'")
                    && !trimmed.contains("://") {
                    errors.append(YAMLError(line: lineNum, message: "Missing space after colon"))
                }
            }

            // Check for invalid indent jump
            if indent > (indentStack.last ?? 0) + 8 {
                errors.append(YAMLError(line: lineNum, message: "Unexpected indentation increase"))
            }

            // Update indent stack
            if indent > (indentStack.last ?? 0) {
                indentStack.append(indent)
            } else {
                while let last = indentStack.last, last > indent {
                    indentStack.removeLast()
                }
            }

            // Check for unclosed quotes
            let doubleQuotes = trimmed.filter { $0 == "\"" }.count
            let singleQuotes = trimmed.filter { $0 == "'" }.count
            // Simple check: odd number of unescaped quotes
            if doubleQuotes % 2 != 0 && !trimmed.contains("\\\"") {
                errors.append(YAMLError(line: lineNum, message: "Unclosed double quote"))
            }
            if singleQuotes % 2 != 0 {
                errors.append(YAMLError(line: lineNum, message: "Unclosed single quote"))
            }

            // Check for mapping with missing value (key: followed by nothing, then another key at same level)
            // This is complex to detect reliably, skip for basic validator
        }

        return errors
    }
}
