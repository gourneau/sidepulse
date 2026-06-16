import SwiftUI

/// A lightweight, scrollable viewer for the LEDS.TXT DSL reference. Renders
/// headings, prose (with inline markdown), and fenced code blocks.
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
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .h1(let text):
            Text(text).font(.title.bold()).padding(.top, 4)
        case .h2(let text):
            Text(text).font(.title3.bold()).padding(.top, 6)
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
        case h1(String), h2(String), paragraph(String), code(String)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeBuffer: [String] = []
        var paraBuffer: [String] = []

        func flushParagraph() {
            if !paraBuffer.isEmpty {
                blocks.append(.paragraph(paraBuffer.joined(separator: " ")))
                paraBuffer = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode { codeBuffer.append(line); continue }
            if line.hasPrefix("## ") { flushParagraph(); blocks.append(.h2(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { flushParagraph(); blocks.append(.h1(String(line.dropFirst(2)))); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph(); continue }
            paraBuffer.append(line)
        }
        flushParagraph()
        if inCode, !codeBuffer.isEmpty { blocks.append(.code(codeBuffer.joined(separator: "\n"))) }
        return blocks
    }
}
