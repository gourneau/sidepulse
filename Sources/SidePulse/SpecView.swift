import SwiftUI

/// A lightweight, scrollable viewer for the LEDS.LED DSL reference. Renders
/// headings, prose (with inline markdown), and code blocks — both fenced and
/// four-space indented (the spec's preamble uses the indented form for its shell
/// examples, which would otherwise be swallowed into the surrounding paragraph).
struct SpecView: View {
    private let blocks = SpecView.parse(SpecText.content)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(width: 660, height: 660)
        .onAppear {
            // An accessory (menu-bar) app opens windows behind the popover and
            // can't bring them front. Become a regular app while this window is
            // up so it comes forward; revert when it closes.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first { $0.title == SpecWindow.title }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            // Only drop back if the Activity window isn't still up.
            if !NSApp.windows.contains(where: { $0.title == ActivityWindow.title && $0.isVisible }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .h1(let text):
            Text(text).font(.title.bold()).padding(.top, 4)
        case .h2(let text):
            Text(text).font(.title3.bold()).padding(.top, 6)
        case .h3(let text):
            Text(text).font(.headline).padding(.top, 4)
        case .paragraph(let text):
            Text(markdown(text)).font(.body)
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
        }
    }

    private func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }

    // MARK: - Tiny markdown parser

    enum Block {
        case h1(String), h2(String), h3(String), paragraph(String), code(String)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeBuffer: [String] = []
        var indentBuffer: [String] = []
        var paraBuffer: [String] = []

        func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        func flushParagraph() {
            if !paraBuffer.isEmpty {
                blocks.append(.paragraph(paraBuffer.joined(separator: " ")))
                paraBuffer = []
            }
        }

        /// Emit a pending indented block, dedented by its own smallest indent (the
        /// spec mixes 4- and 5-space examples). Trailing blank lines belong to
        /// whatever follows, not to the code.
        func flushIndented() {
            while let last = indentBuffer.last, isBlank(last) { indentBuffer.removeLast() }
            guard !indentBuffer.isEmpty else { return }
            let minIndent = indentBuffer.filter { !isBlank($0) }.map(leadingSpaces).min() ?? 0
            let dedented = indentBuffer.map { String($0.dropFirst(min(minIndent, leadingSpaces($0)))) }
            blocks.append(.code(dedented.joined(separator: "\n")))
            indentBuffer = []
        }

        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer = []
                    inCode = false
                } else {
                    flushIndented()
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode { codeBuffer.append(line); continue }

            let indented = line.hasPrefix("    ") && !isBlank(line)
            if !indentBuffer.isEmpty {
                // Blank lines don't end an indented block; the next flush trims them.
                if indented || isBlank(line) { indentBuffer.append(line); continue }
                flushIndented()
            } else if indented, paraBuffer.isEmpty {
                // Only start one at the top level, never mid-paragraph — otherwise a
                // wrapped prose line that happens to be indented would become code.
                indentBuffer.append(line)
                continue
            }

            if line.hasPrefix("### ") { flushParagraph(); blocks.append(.h3(String(line.dropFirst(4)))); continue }
            if line.hasPrefix("## ") { flushParagraph(); blocks.append(.h2(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { flushParagraph(); blocks.append(.h1(String(line.dropFirst(2)))); continue }
            if isBlank(line) { flushParagraph(); continue }
            paraBuffer.append(line)
        }
        flushIndented()
        flushParagraph()
        if inCode, !codeBuffer.isEmpty { blocks.append(.code(codeBuffer.joined(separator: "\n"))) }
        return blocks
    }
}
