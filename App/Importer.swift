import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Markdown → text formatat

enum MarkdownImport {
    private enum Inline { case image, code, bold, strike, link, italic }

    private static let rules: [(NSRegularExpression, Inline)] = {
        let list: [(String, Inline)] = [
            (#"!\[([^\]]*)\]\(([^)]*)\)"#, .image),
            (#"`([^`]+)`"#, .code),
            (#"\*\*(.+?)\*\*"#, .bold),
            (#"__(.+?)__"#, .bold),
            (#"~~(.+?)~~"#, .strike),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, .link),
            (#"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#, .italic),
            (#"(?<![_\w])_(?!\s)(.+?)(?<!\s)_(?![_\w])"#, .italic)
        ]
        return list.compactMap { pattern, kind in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, kind) }
        }
    }()

    static func attributed(_ markdown: String, fallbackTitle: String?) -> NSAttributedString {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Antet YAML (--- ... ---) la începutul fișierului
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }

        var paragraphs: [NSAttributedString] = []
        var firstIsHeading = false
        var inCode = false

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode {
                paragraphs.append(NSAttributedString(string: raw.isEmpty ? " " : raw, attributes: RT.attributes(.mono)))
                continue
            }
            if trimmed.isEmpty { continue }

            let leading = raw.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let level = CGFloat(min(leading / 2, 6))

            if let m = match(#"^(#{1,6})\s+(.*)$"#, trimmed) {
                let hashes = m[1].count
                let style: ParaStyle
                if hashes == 1 {
                    style = paragraphs.isEmpty ? .title : .h1
                } else {
                    style = hashes == 2 ? .h2 : .h3
                }
                if paragraphs.isEmpty { firstIsHeading = true }
                paragraphs.append(inline(m[2], RT.attributes(style)))
            } else if match(#"^(-{3,}|\*{3,}|_{3,})$"#, trimmed) != nil {
                paragraphs.append(separator())
            } else if let m = match(#"^[-*+]\s+\[( |x|X)\]\s*(.*)$"#, trimmed) {
                let attrs = listAttributes(level)
                let p = NSMutableAttributedString(attributedString: RT.checkbox(m[1] != " ", base: attrs))
                p.append(NSAttributedString(string: " ", attributes: attrs))
                var textAttrs = attrs
                if m[1] != " " {
                    textAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    textAttrs[.foregroundColor] = RT.mutedText
                }
                p.append(inline(m[2], textAttrs))
                paragraphs.append(p)
            } else if let m = match(#"^[-*+•]\s+(.*)$"#, trimmed) {
                let attrs = listAttributes(level)
                let p = NSMutableAttributedString(string: "• ", attributes: attrs)
                p.append(inline(m[1], attrs))
                paragraphs.append(p)
            } else if let m = match(#"^(\d{1,3})[.)]\s+(.*)$"#, trimmed) {
                let attrs = listAttributes(level)
                let p = NSMutableAttributedString(string: "\(m[1]). ", attributes: attrs)
                p.append(inline(m[2], attrs))
                paragraphs.append(p)
            } else if let m = match(#"^>\s?(.*)$"#, trimmed) {
                var attrs = RT.attributes(.body)
                attrs[.font] = RT.font(style: .body, design: .standard, bold: false, italic: true)
                attrs[.foregroundColor] = RT.mutedText
                attrs[.guwColor] = "7F98A3"
                let ps = NSMutableParagraphStyle()
                ps.firstLineHeadIndent = 16
                ps.headIndent = 16
                ps.paragraphSpacing = 4
                attrs[.paragraphStyle] = ps
                paragraphs.append(inline(m[1], attrs))
            } else if trimmed.hasPrefix("|") {
                // Tabel: rândurile rămân ca text monospace; linia de separare se omite
                if match(#"^\|?[\s:\-|]+\|?$"#, trimmed) != nil { continue }
                paragraphs.append(NSAttributedString(string: trimmed, attributes: RT.attributes(.mono)))
            } else {
                var attrs = RT.attributes(.body)
                if level > 0 {
                    let ps = NSMutableParagraphStyle()
                    ps.firstLineHeadIndent = level * 12
                    ps.headIndent = level * 12
                    ps.paragraphSpacing = 4
                    attrs[.paragraphStyle] = ps
                }
                paragraphs.append(inline(trimmed, attrs))
            }
        }

        if !firstIsHeading, let title = fallbackTitle, !title.isEmpty {
            paragraphs.insert(NSAttributedString(string: title, attributes: RT.attributes(.title)), at: 0)
        }

        let out = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: RT.attributes(.body))) }
            out.append(p)
        }
        return out
    }

    private static func listAttributes(_ level: CGFloat) -> [NSAttributedString.Key: Any] {
        var attrs = RT.attributes(.body)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 3
        ps.paragraphSpacing = 4
        ps.firstLineHeadIndent = level * 18
        ps.headIndent = 26 + level * 18
        attrs[.paragraphStyle] = ps
        return attrs
    }

    private static func separator() -> NSAttributedString {
        var attrs = RT.attributes(.body)
        attrs[.foregroundColor] = RT.mutedText
        attrs[.guwColor] = "7F98A3"
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.paragraphSpacing = 6
        ps.paragraphSpacingBefore = 6
        attrs[.paragraphStyle] = ps
        return NSAttributedString(string: String(repeating: "─", count: 18), attributes: attrs)
    }

    /// Grupurile unei potriviri (indexul 0 = tot textul).
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        let ns = text as NSString
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// Formatarea din interiorul unui rând: bold, italic, tăiat, cod, linkuri.
    static func inline(_ text: String, _ base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = text as NSString
        var pos = 0
        while pos < ns.length {
            var best: (NSTextCheckingResult, Inline)?
            for (re, kind) in rules {
                guard let m = re.firstMatch(in: text, range: NSRange(location: pos, length: ns.length - pos)) else { continue }
                if best == nil || m.range.location < best!.0.range.location { best = (m, kind) }
            }
            guard let found = best else {
                out.append(NSAttributedString(string: ns.substring(from: pos), attributes: base))
                break
            }
            let (m, kind) = found
            if m.range.location > pos {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)),
                                              attributes: base))
            }
            let inner = ns.substring(with: m.range(at: 1))
            let t = RT.traits(of: base)
            switch kind {
            case .code:
                var a = base
                a[.font] = RT.font(style: .mono, design: .mono, bold: false, italic: false, size: max(13, t.size - 2))
                a[.backgroundColor] = RT.codeBackground
                out.append(NSAttributedString(string: inner, attributes: a))
            case .bold:
                var a = base
                a[.font] = RT.font(style: RT.style(of: base), design: RT.design(of: base), bold: true, italic: t.italic, size: t.size)
                out.append(inline(inner, a))
            case .italic:
                var a = base
                a[.font] = RT.font(style: RT.style(of: base), design: RT.design(of: base), bold: t.bold, italic: true, size: t.size)
                out.append(inline(inner, a))
            case .strike:
                var a = base
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                out.append(inline(inner, a))
            case .link:
                var a = base
                let target = ns.substring(with: m.range(at: 2))
                if let url = URL(string: target) { a[.link] = url }
                a[.foregroundColor] = RT.accent
                a[.guwColor] = "59E0EF"
                out.append(NSAttributedString(string: inner, attributes: a))
            case .image:
                var a = base
                a[.foregroundColor] = RT.mutedText
                a[.guwColor] = "7F98A3"
                out.append(NSAttributedString(string: "[imagine\(inner.isEmpty ? "" : ": " + inner)]", attributes: a))
            }
            pos = m.range.location + max(m.range.length, 1)
        }
        return out
    }
}

// MARK: - Import fișiere și foldere

enum Importer {
    struct Summary {
        var notes: [UUID] = []
        var folders = 0
        var skipped: [String] = []
    }

    static let textExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]
    static let otherExtensions: Set<String> = ["rtf", "html", "htm", "pdf"]

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.folder, .plainText, .text, .rtf, .html, .pdf]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        return types
    }

    @MainActor
    static func run(_ urls: [URL], into folderID: UUID?, store: LibraryStore) -> Summary {
        var summary = Summary()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if isDirectory(url) {
                importDirectory(url, parent: folderID, store: store, depth: 0, summary: &summary)
            } else {
                importFile(url, folderID: folderID, store: store, summary: &summary)
            }
        }
        return summary
    }

    @MainActor
    private static func importDirectory(_ url: URL, parent: UUID?, store: LibraryStore, depth: Int, summary: inout Summary) {
        guard depth < 8 else { return }
        let folderID = store.createFolder(name: url.lastPathComponent, parent: parent,
                                          colorHex: store.folder(parent)?.colorHex ?? "59E0EF", icon: "folder.fill")
        summary.folders += 1
        let before = summary.notes.count
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if isDirectory(item) {
                importDirectory(item, parent: folderID, store: store, depth: depth + 1, summary: &summary)
            } else {
                importFile(item, folderID: folderID, store: store, summary: &summary)
            }
        }
        // Notele importate direct în folder păstrează ordinea fișierelor
        let direct = summary.notes[before...].filter { store.note($0)?.folderID == folderID }
        store.setManualOrder(Array(direct), for: folderID)
    }

    @MainActor
    private static func importFile(_ url: URL, folderID: UUID?, store: LibraryStore, summary: inout Summary) {
        guard let body = attributed(for: url) else {
            summary.skipped.append(url.lastPathComponent)
            return
        }
        summary.notes.append(store.createNote(in: folderID, body: body))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Conținutul unui fișier, transformat în text formatat.
    static func attributed(for url: URL) -> NSAttributedString? {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        if textExtensions.contains(ext) || ext.isEmpty {
            guard let text = readText(url) else { return nil }
            return MarkdownImport.attributed(text, fallbackTitle: title)
        }
        switch ext {
        case "rtf", "html", "htm":
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .html
            guard let data = try? Data(contentsOf: url),
                  let doc = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
            else { return nil }
            return MarkdownImport.attributed(doc.string, fallbackTitle: title)
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { return nil }
            return PDFStructureImport.attributed(pdf, fallbackTitle: title)
        default:
            return nil
        }
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1250)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Textul din PDF vine rând cu rând; îl reunim în paragrafe (rândul gol = paragraf nou).
    static func reflow(_ text: String) -> String {
        let blocks = text.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n\n")
        return blocks.map { block -> String in
            var out = ""
            for line in block.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                let startsItem = t.first.map { "•-*–".contains($0) } == true
                    || t.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) != nil
                if out.isEmpty {
                    out = t
                } else if startsItem {
                    out += "\n" + t
                } else {
                    out = OCR.join(out, t)
                }
            }
            return out
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}

// MARK: - Butonul de import (selector de fișiere + rezultat)

struct ImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    let folderID: UUID?
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var router: Router
    @State var message: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: Importer.allowedTypes,
                          allowsMultipleSelection: true) { result in handle(result) }
            .alert("Import", isPresented: messageBinding) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }

    private func handle(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let summary = Importer.run(urls, into: folderID, store: store)
        if summary.notes.count == 1 && summary.folders == 0 && summary.skipped.isEmpty {
            router.open(summary.notes[0])
            return
        }
        let noteWord = summary.notes.count == 1 ? "notă" : "note"
        var text = "Am importat \(summary.notes.count) " + noteWord
        if summary.folders > 0 {
            let folderWord = summary.folders == 1 ? "folder" : "foldere"
            text += " în \(summary.folders) " + folderWord
        }
        text += "."
        if !summary.skipped.isEmpty {
            text += "\n\nNu am putut citi: " + summary.skipped.prefix(5).joined(separator: ", ")
            if summary.skipped.count > 5 { text += " și încă \(summary.skipped.count - 5)" }
            text += ".\nFișierele Word (.docx) le poți exporta ca PDF sau TXT și le imporți apoi."
        }
        message = text
    }
}

extension View {
    func importer(isPresented: Binding<Bool>, into folderID: UUID?) -> some View {
        modifier(ImportModifier(isPresented: isPresented, folderID: folderID))
    }
}
