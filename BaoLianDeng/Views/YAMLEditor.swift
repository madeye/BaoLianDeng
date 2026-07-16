// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI
import AppKit

// MARK: - YAML Error (shared)

struct YAMLError: Identifiable {
    let id = UUID()
    let line: Int
    let message: String
}

// MARK: - YAML Validator (shared)

enum YAMLValidator {
    static func validate(_ text: String) -> [YAMLError] {
        var errors: [YAMLError] = []
        let lines = text.components(separatedBy: "\n")
        var indentStack: [Int] = [0]

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            validateTabs(line, lineNum: lineNum, errors: &errors)

            let indent = line.prefix(while: { $0 == " " }).count
            validateColon(trimmed, lineNum: lineNum, errors: &errors)
            validateIndent(
                indent, stack: &indentStack,
                lineNum: lineNum, errors: &errors
            )
            validateQuotes(trimmed, lineNum: lineNum, errors: &errors)
        }

        return errors
    }

    private static func validateTabs(
        _ line: String, lineNum: Int, errors: inout [YAMLError]
    ) {
        if line.contains("\t") {
            errors.append(YAMLError(
                line: lineNum,
                message: "Tabs are not allowed in YAML, use spaces"
            ))
        }
    }

    private static func validateColon(
        _ trimmed: String, lineNum: Int, errors: inout [YAMLError]
    ) {
        guard let colonIdx = trimmed.firstIndex(of: ":"),
              !trimmed.hasPrefix("-") else { return }
        let afterColon = trimmed[trimmed.index(after: colonIdx)...]
        guard let first = afterColon.first,
              first != " ", first != "\n",
              !trimmed.hasPrefix("http"),
              !trimmed.hasPrefix("https"),
              !trimmed.hasPrefix("\""),
              !trimmed.hasPrefix("'"),
              !trimmed.contains("://") else { return }
        errors.append(YAMLError(
            line: lineNum, message: "Missing space after colon"
        ))
    }

    private static func validateIndent(
        _ indent: Int,
        stack: inout [Int],
        lineNum: Int,
        errors: inout [YAMLError]
    ) {
        if indent > (stack.last ?? 0) + 8 {
            errors.append(YAMLError(
                line: lineNum,
                message: "Unexpected indentation increase"
            ))
        }
        if indent > (stack.last ?? 0) {
            stack.append(indent)
        } else {
            while let last = stack.last, last > indent {
                stack.removeLast()
            }
        }
    }

    private static func validateQuotes(
        _ trimmed: String, lineNum: Int, errors: inout [YAMLError]
    ) {
        let doubleQuotes = trimmed.filter { $0 == "\"" }.count
        let singleQuotes = trimmed.filter { $0 == "'" }.count
        if doubleQuotes % 2 != 0 && !trimmed.contains("\\\"") {
            errors.append(YAMLError(
                line: lineNum, message: "Unclosed double quote"
            ))
        }
        if singleQuotes % 2 != 0 {
            errors.append(YAMLError(
                line: lineNum, message: "Unclosed single quote"
            ))
        }
    }
}

// MARK: - YAML Syntax Highlighted Text Editor (macOS)

struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var validationErrors: [YAMLError]
    var isEditable: Bool = true
    var onFocusLost: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = isEditable

        scrollView.documentView = textView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView
        else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            context.coordinator.isUpdating = true
            let highlighted = YAMLHighlighter.highlight(text)
            textView.textStorage?.setAttributedString(highlighted)
            textView.selectedRanges = selectedRanges
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: YAMLEditor
        var isUpdating = false
        weak var textView: NSTextView?
        private var debounceTimer: Timer?

        init(_ parent: YAMLEditor) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func windowDidResignKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  let textView = textView,
                  textView.window == window else { return }
            parent.onFocusLost?()
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? NSTextView
            else { return }

            parent.text = textView.string

            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(
                withTimeInterval: 0.3, repeats: false
            ) { [weak self] _ in
                self?.applyHighlighting(to: textView)
            }
        }

        private func applyHighlighting(to textView: NSTextView) {
            isUpdating = true
            let selectedRanges = textView.selectedRanges
            let highlighted = YAMLHighlighter.highlight(textView.string)
            textView.textStorage?.setAttributedString(highlighted)
            let maxLen = textView.textStorage?.length ?? 0
            let safeRanges = selectedRanges.filter {
                let range = $0.rangeValue
                return range.location + range.length <= maxLen
            }
            textView.selectedRanges = safeRanges.isEmpty
                ? selectedRanges : safeRanges
            isUpdating = false

            parent.validationErrors = YAMLValidator.validate(
                textView.string
            )
        }
    }
}
