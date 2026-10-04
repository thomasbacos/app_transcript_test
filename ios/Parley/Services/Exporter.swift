import UIKit

/// Shareable files: a clean PDF (summary, actions, transcript), plain text, Markdown, subtitles.
@MainActor
enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case pdf, text, markdown, srt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pdf: return tr("PDF document")
            case .text: return tr("Text")
            case .markdown: return tr("Markdown (Notion, Obsidian…)")
            case .srt: return tr("Subtitles (SRT)")
            }
        }
        var icon: String {
            switch self {
            case .pdf: return "doc.richtext"
            case .text: return "doc.plaintext"
            case .markdown: return "number"
            case .srt: return "captions.bubble"
            }
        }
    }

    static func file(_ format: Format, recording r: Recording, result: TranscriptResult) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = safeName(r.title)
        switch format {
        case .pdf:
            let url = dir.appendingPathComponent(base + ".pdf")
            try pdf(html(r, result)).write(to: url, options: .atomic)
            return url
        case .text:
            let url = dir.appendingPathComponent(base + ".txt")
            try text(r, result).write(to: url, atomically: true, encoding: .utf8)
            return url
        case .markdown:
            let url = dir.appendingPathComponent(base + ".md")
            try markdown(r, result).write(to: url, atomically: true, encoding: .utf8)
            return url
        case .srt:
            let url = dir.appendingPathComponent(base + ".srt")
            try srt(r, result).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Parley" : cleaned).prefix(80))
    }

    private static func name(_ spk: String, _ r: Recording, _ res: TranscriptResult) -> String {
        res.displayName(spk, overrides: r.speakerNames)
    }

    // MARK: text formats

    static func summaryText(_ r: Recording, _ res: TranscriptResult) -> String {
        var out = [r.title]
        if let s = res.summary {
            if !s.subtitle.isEmpty { out.append(s.subtitle) }
            for sec in s.sections {
                out.append("")
                out.append(sec.head.uppercased())
                out.append(contentsOf: sec.bullets.map { "• " + $0 })
            }
            if let actions = s.actions, !actions.isEmpty {
                out.append("")
                out.append(tr("Action items").uppercased())
                out.append(contentsOf: actions.map { a in
                    "☐ " + a.task + [a.owner, a.due].filter { !$0.isEmpty }.map { " — " + $0 }.joined()
                })
            }
        }
        return out.joined(separator: "\n")
    }

    static func transcriptText(_ r: Recording, _ res: TranscriptResult) -> String {
        if res.turns.isEmpty { return res.text }
        return res.turns.map { t in
            "[\(Fmt.clock(t.start))] \(name(t.spk, r, res))\n\(t.text)"
        }.joined(separator: "\n\n")
    }

    static func text(_ r: Recording, _ res: TranscriptResult) -> String {
        var parts = [summaryText(r, res)]
        parts.append("\n" + String(repeating: "=", count: 40) + "\n" + tr("Transcript").uppercased() + "\n")
        parts.append(transcriptText(r, res))
        return parts.joined(separator: "\n")
    }

    static func markdown(_ r: Recording, _ res: TranscriptResult) -> String {
        var out = ["# \(r.title)", "", "*\(Fmt.date(r.createdAt)) · \(Fmt.duration(r.duration))*", ""]
        if let s = res.summary {
            if !s.subtitle.isEmpty { out += ["> \(s.subtitle)", ""] }
            if let actions = s.actions, !actions.isEmpty {
                out.append("## \(tr("Action items"))")
                for (i, a) in actions.enumerated() {
                    let done = r.doneActions.contains(i) ? "x" : " "
                    let meta = [a.owner, a.due].filter { !$0.isEmpty }.joined(separator: " · ")
                    out.append("- [\(done)] \(a.task)" + (meta.isEmpty ? "" : " — *\(meta)*"))
                }
                out.append("")
            }
            for sec in s.sections {
                out.append("## \(sec.head)")
                out += sec.bullets.map { "- \($0)" }
                out.append("")
            }
        }
        out.append("## \(tr("Transcript"))")
        if res.turns.isEmpty {
            out.append(res.text)
        } else {
            for t in res.turns {
                out.append("**\(name(t.spk, r, res))** `\(Fmt.clock(t.start))`  ")
                out.append(t.text)
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    static func srt(_ r: Recording, _ res: TranscriptResult) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return res.turns.enumerated().map { i, t in
            "\(i + 1)\n\(stamp(t.start)) --> \(stamp(max(t.end, t.start + 1)))\n\(name(t.spk, r, res)): \(t.text)\n"
        }.joined(separator: "\n")
    }

    // MARK: PDF

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(_ r: Recording, _ res: TranscriptResult) -> String {
        let palette = ["#5B4BDB", "#E0567A", "#1FA67A", "#F29D38", "#2E8BE6", "#9B59D0", "#00A3A3", "#D35400"]
        var body = """
        <div class="brand">PARLEY</div>
        <h1>\(esc(r.title))</h1>
        <div class="meta">\(esc(Fmt.date(r.createdAt))) · \(esc(Fmt.duration(r.duration)))\
        \(res.speakers.isEmpty ? "" : " · " + esc(res.speakers.map { name($0, r, res) }.joined(separator: ", ")))</div>
        """
        if let s = res.summary {
            if !s.subtitle.isEmpty { body += "<p class=\"sub\">\(esc(s.subtitle))</p>" }
            if let actions = s.actions, !actions.isEmpty {
                body += "<div class=\"card\"><h2>\(esc(tr("Action items")))</h2><ul class=\"actions\">"
                for (i, a) in actions.enumerated() {
                    let meta = [a.owner, a.due].filter { !$0.isEmpty }.joined(separator: " · ")
                    body += "<li><span class=\"box\">\(r.doneActions.contains(i) ? "✓" : "")</span>\(esc(a.task))"
                    if !meta.isEmpty { body += " <span class=\"muted\">— \(esc(meta))</span>" }
                    body += "</li>"
                }
                body += "</ul></div>"
            }
            for sec in s.sections {
                body += "<h2>\(esc(sec.head))</h2><ul>"
                body += sec.bullets.map { "<li>\(esc($0))</li>" }.joined()
                body += "</ul>"
            }
        }
        body += "<h2 class=\"break\">\(esc(tr("Transcript")))</h2>"
        if res.turns.isEmpty {
            body += res.text.components(separatedBy: "\n\n").map { "<p>\(esc($0))</p>" }.joined()
        } else {
            for t in res.turns {
                let color = palette[res.speakerIndex(t.spk) % palette.count]
                body += "<div class=\"turn\"><div class=\"who\" style=\"color:\(color)\">\(esc(name(t.spk, r, res)))"
                body += " <span class=\"ts\">\(Fmt.clock(t.start))</span></div><div>\(esc(t.text))</div></div>"
            }
        }
        body += "<p class=\"foot\">\(esc(tr("Generated by Parley from an automatic transcript. Check names, figures and quotes before sharing.")))</p>"
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 10.5pt; color: #1d1b2e; line-height: 1.45; }
        .brand { font-size: 8pt; letter-spacing: 3px; color: #5B4BDB; font-weight: 700; }
        h1 { font-size: 20pt; margin: 4px 0 2px 0; }
        h2 { font-size: 12.5pt; color: #5B4BDB; margin: 16px 0 4px 0; }
        .meta, .muted, .ts { color: #6b6880; font-size: 9pt; }
        .sub { font-style: italic; color: #4a475e; }
        ul { margin: 0; padding-left: 16px; } li { margin: 2px 0; }
        .card { background: #f4f2ff; border-radius: 8px; padding: 2px 12px 8px 12px; margin-top: 10px; }
        .actions { list-style: none; padding-left: 0; }
        .box { display: inline-block; width: 11px; height: 11px; border: 1px solid #5B4BDB; border-radius: 3px;
               margin-right: 7px; font-size: 8pt; line-height: 11px; text-align: center; color: #5B4BDB; }
        .turn { margin: 0 0 8px 0; page-break-inside: avoid; }
        .who { font-weight: 700; font-size: 9.5pt; }
        .break { page-break-before: always; }
        .foot { margin-top: 24px; color: #8a879c; font-size: 8pt; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func pdf(_ html: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)          // A4
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.insetBy(dx: 42, dy: 46)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}
