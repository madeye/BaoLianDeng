// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import AppKit

// MARK: - YAML Syntax Highlighter (macOS)

enum YAMLHighlighter {
    private static let keyColor = NSColor.systemBlue
    private static let stringColor = NSColor.systemGreen
    private static let numberColor = NSColor.systemOrange
    private static let boolColor = NSColor.systemPurple
    private static let commentColor = NSColor.systemGray
    private static let anchorColor = NSColor.systemTeal
    private static let listDashColor = NSColor.systemRed
    private static let defaultColor = NSColor.labelColor

    static func highlight(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: 13, weight: .regular
                ),
                .foregroundColor: defaultColor
            ]
        )

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        text.enumerateSubstrings(
            in: text.startIndex...,
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let nsRange = NSRange(lineRange, in: text)
            let line = nsText.substring(with: nsRange)
            Self.highlightLine(line, at: nsRange.location, in: attributed)
        }

        Self.applyRegex(
            "(?<=\\s)[&*][a-zA-Z_][a-zA-Z0-9_]*",
            color: anchorColor, in: attributed,
            range: fullRange, text: nsText
        )

        return attributed
    }

    private static func highlightLine(
        _ line: String, at offset: Int,
        in attributed: NSMutableAttributedString
    ) {
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let commentRange = NSRange(
                location: offset, length: nsLine.length
            )
            attributed.addAttribute(
                .foregroundColor, value: commentColor, range: commentRange
            )
            return
        }

        if let commentStart = findInlineCommentStart(in: line) {
            let commentLen = nsLine.length - commentStart
            let commentNSRange = NSRange(
                location: offset + commentStart, length: commentLen
            )
            attributed.addAttribute(
                .foregroundColor, value: commentColor,
                range: commentNSRange
            )
        }

        highlightListDash(line, lineRange: lineRange,
                          offset: offset, in: attributed)
        highlightKeyValue(line, nsLine: nsLine, lineRange: lineRange,
                          offset: offset, in: attributed)
        highlightQuotedStrings(nsLine, offset: offset, in: attributed)
    }

    private static func highlightListDash(
        _ line: String, lineRange: NSRange,
        offset: Int, in attributed: NSMutableAttributedString
    ) {
        let pattern = "^(\\s*)(-\\s)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let dashMatch = regex.firstMatch(
                  in: line, range: lineRange
              )
        else { return }
        let dashRange = dashMatch.range(at: 2)
        let adjusted = NSRange(
            location: offset + dashRange.location,
            length: dashRange.length
        )
        attributed.addAttribute(
            .foregroundColor, value: listDashColor, range: adjusted
        )
    }

    private static func highlightKeyValue(
        _ line: String, nsLine: NSString, lineRange: NSRange,
        offset: Int, in attributed: NSMutableAttributedString
    ) {
        let kvPattern =
            "^(\\s*(?:-\\s+)?)" +
            "([a-zA-Z0-9_][a-zA-Z0-9_.\\-]*)\\s*(:)"
        guard let regex = try? NSRegularExpression(pattern: kvPattern),
              let kvMatch = regex.firstMatch(
                  in: line, range: lineRange
              )
        else { return }

        let keyRange = kvMatch.range(at: 2)
        attributed.addAttribute(
            .foregroundColor, value: keyColor,
            range: NSRange(
                location: offset + keyRange.location,
                length: keyRange.length
            )
        )

        let colonRange = kvMatch.range(at: 3)
        attributed.addAttribute(
            .foregroundColor, value: keyColor,
            range: NSRange(
                location: offset + colonRange.location,
                length: colonRange.length
            )
        )

        let valueStart = kvMatch.range.location + kvMatch.range.length
        guard valueStart < nsLine.length else { return }
        let valueStr = nsLine.substring(from: valueStart)
            .trimmingCharacters(in: .whitespaces)
        let searchRange = NSRange(
            location: valueStart,
            length: nsLine.length - valueStart
        )
        let valueLoc = (line as NSString).range(
            of: valueStr, options: [], range: searchRange
        )
        guard valueLoc.location != NSNotFound else { return }
        let adjustedValueRange = NSRange(
            location: offset + valueLoc.location,
            length: valueLoc.length
        )
        highlightValue(
            valueStr, range: adjustedValueRange, in: attributed
        )
    }

    private static func highlightQuotedStrings(
        _ nsLine: NSString, offset: Int,
        in attributed: NSMutableAttributedString
    ) {
        let lineRange = NSRange(location: offset, length: nsLine.length)
        let fullText = attributed.string as NSString
        applyRegex(
            "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"",
            color: stringColor, in: attributed,
            range: lineRange, text: fullText
        )
        applyRegex(
            "'[^']*'",
            color: stringColor, in: attributed,
            range: lineRange, text: fullText
        )
    }

    private static let boolValues: Set<String> = [
        "true", "false", "yes", "no", "on", "off",
        "True", "False", "Yes", "No", "On", "Off",
        "TRUE", "FALSE", "YES", "NO", "ON", "OFF"
    ]

    private static let nullValues: Set<String> = [
        "null", "Null", "NULL", "~"
    ]

    private static func highlightValue(
        _ value: String, range: NSRange,
        in attributed: NSMutableAttributedString
    ) {
        let stripped = value.trimmingCharacters(in: .whitespaces)
        let effectiveValue: String
        if let hashIdx = findInlineCommentStart(in: stripped) {
            effectiveValue = String(stripped.prefix(hashIdx))
                .trimmingCharacters(in: .whitespaces)
        } else {
            effectiveValue = stripped
        }

        if boolValues.contains(effectiveValue)
            || nullValues.contains(effectiveValue) {
            attributed.addAttribute(
                .foregroundColor, value: boolColor, range: range
            )
            return
        }

        let numberPattern =
            "^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"
        if effectiveValue.range(
            of: numberPattern, options: .regularExpression
        ) != nil {
            attributed.addAttribute(
                .foregroundColor, value: numberColor, range: range
            )
            return
        }

        let isDoubleQuoted = effectiveValue.hasPrefix("\"")
            && effectiveValue.hasSuffix("\"")
        let isSingleQuoted = effectiveValue.hasPrefix("'")
            && effectiveValue.hasSuffix("'")
        if isDoubleQuoted || isSingleQuoted {
            attributed.addAttribute(
                .foregroundColor, value: stringColor, range: range
            )
            return
        }

        let blockScalars: Set<String> = ["|", ">", "|-", ">-"]
        if blockScalars.contains(effectiveValue) {
            attributed.addAttribute(
                .foregroundColor, value: stringColor, range: range
            )
            return
        }
    }

    static func findInlineCommentStart(in line: String) -> Int? {
        var inDouble = false
        var inSingle = false
        var prev: Character = "\0"

        for (idx, char) in line.enumerated() {
            if char == "\"" && !inSingle && prev != "\\" {
                inDouble.toggle()
            } else if char == "'" && !inDouble {
                inSingle.toggle()
            } else if char == "#" && !inDouble && !inSingle {
                let prevIsSpace = idx == 0
                    || line[line.index(
                        line.startIndex, offsetBy: idx - 1
                    )] == " "
                if prevIsSpace { return idx }
            }
            prev = char
        }
        return nil
    }

    private static func applyRegex(
        _ pattern: String, color: NSColor,
        in attributed: NSMutableAttributedString,
        range: NSRange, text: NSString
    ) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return }
        let maxLen = text.length - range.location
        let safeRange = NSRange(
            location: range.location,
            length: min(range.length, maxLen)
        )
        regex.enumerateMatches(
            in: text as String, range: safeRange
        ) { match, _, _ in
            guard let matchRange = match?.range else { return }
            attributed.addAttribute(
                .foregroundColor, value: color, range: matchRange
            )
        }
    }
}
