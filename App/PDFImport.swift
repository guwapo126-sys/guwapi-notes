import PDFKit
import UIKit

/// Citește un PDF digital păstrând structura: titluri (după mărimea fontului), paragrafe,
/// liste, tabele cu două coloane, imagini la locul lor; elimină antetul și subsolul repetate.
enum PDFStructureImport {

    // MARK: Model intern

    struct Fragment {
        var text: String
        var rect: CGRect          // spațiul paginii (origine jos-stânga)
        var size: CGFloat
        var bold: Bool
        var page: Int
    }

    struct Picture {
        var image: UIImage
        var rect: CGRect
        var page: Int
    }

    enum Block {
        case heading(ParaStyle, String)
        case paragraph(String)
        case bullet(String)
        case row(String, String)
        case tableHeader([String])
        case image(UIImage, CGFloat)
    }

    private enum Item {
        case text(Fragment)
        case picture(Picture)

        var page: Int {
            switch self {
            case .text(let f): return f.page
            case .picture(let p): return p.page
            }
        }
        var top: CGFloat {
            switch self {
            case .text(let f): return f.rect.midY
            case .picture(let p): return p.rect.maxY
            }
        }
        var left: CGFloat {
            switch self {
            case .text(let f): return f.rect.minX
            case .picture(let p): return p.rect.minX
            }
        }
    }

    // MARK: Intrare

    static func attributed(_ doc: PDFDocument, fallbackTitle: String) -> NSAttributedString? {
        var fragments: [Fragment] = []
        var pictures: [Picture] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            fragments += textFragments(page, index: i)
            pictures += images(page, index: i)
        }
        let textChars = fragments.reduce(0) { $0 + $1.text.count }
        if textChars < 20 {
            return scannedFallback(doc, title: fallbackTitle)
        }
        fragments = removeRunningHeaders(fragments, doc: doc)
        pictures = removeRepeatedPictures(pictures)
        let blocks = structure(fragments, pictures)
        return build(blocks, fallbackTitle: fallbackTitle)
    }

    // MARK: Text cu poziții și fonturi

    private static let bulletGlyphs: Set<Character> = ["•", "●", "▪", "■", "◦", "‣", "∙", "\u{F0B7}", "\u{F0A7}", "\u{F076}", "\u{F0D8}"]

    private static func textFragments(_ page: PDFPage, index: Int) -> [Fragment] {
        guard let raw = page.string, !raw.isEmpty else { return [] }
        let ns = raw as NSString
        let attr = page.attributedString
        let fontsAligned = attr?.length == ns.length

        var out: [Fragment] = []
        var pendingBullet: CGRect?
        var text = ""
        var rect = CGRect.null
        var lastRect = CGRect.null
        var sizeWeight: [CGFloat: Int] = [:]
        var boldChars = 0
        var chars = 0

        func flush() {
            var t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !rect.isNull {
                // O bulină singură (Word o pune separat de text) devine prefixul fragmentului următor
                if t.count == 1, let c = t.first, bulletGlyphs.contains(c) || c == "-" || c == "–" {
                    pendingBullet = rect
                } else {
                    var r = rect
                    if let b = pendingBullet, abs(b.midY - rect.midY) < max(b.height, rect.height) {
                        t = "• " + t
                        r = r.union(b)
                    }
                    pendingBullet = nil
                    let size = sizeWeight.max { $0.value < $1.value }?.key ?? rect.height
                    out.append(Fragment(text: t, rect: r, size: size, bold: chars > 0 && boldChars * 2 > chars, page: index))
                }
            }
            text = ""
            rect = .null
            lastRect = .null
            sizeWeight = [:]
            boldChars = 0
            chars = 0
        }

        var i = 0
        while i < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            i = range.location + range.length
            let piece = ns.substring(with: range)
            if piece == "\n" || piece == "\r" || piece == "\u{2028}" { flush(); continue }

            let bounds = page.characterBounds(at: range.location)
            let isSpace = piece.trimmingCharacters(in: .whitespaces).isEmpty
            if bounds.width <= 0 || bounds.height <= 0 || isSpace {
                if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
                continue
            }

            if !lastRect.isNull {
                let sameLine = abs(bounds.midY - lastRect.midY) < max(bounds.height, lastRect.height) * 0.55
                let gap = bounds.minX - lastRect.maxX
                let columnBreak = gap > max(10, lastRect.height * 1.1)
                let wentBack = gap < -lastRect.height * 2
                if !sameLine || columnBreak || wentBack { flush() }
            }

            let isNbsp = piece.unicodeScalars.contains(where: { $0.value == 0x00A0 })
            text += isNbsp ? " " : piece
            rect = rect.isNull ? bounds : rect.union(bounds)
            lastRect = bounds
            chars += 1

            if fontsAligned, let font = attr?.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
                let rounded = (font.pointSize * 2).rounded() / 2
                sizeWeight[rounded, default: 0] += 1
                if isBold(font) { boldChars += 1 }
            } else {
                let rounded = (bounds.height * 2).rounded() / 2
                sizeWeight[rounded, default: 0] += 1
            }
        }
        flush()
        return out.map { f in
            var f = f
            if let first = f.text.first, bulletGlyphs.contains(first) {
                f.text = "• " + String(f.text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return f
        }
    }

    private static func isBold(_ font: UIFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return true }
        let name = font.fontName.lowercased()
        return ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
    }

    // MARK: Imagini (poziția din conținutul paginii, decupate la randare)

    private final class ScanState {
        var ctm: [CGAffineTransform] = [.identity]
        var rects: [CGRect] = []
    }

    private static func images(_ page: PDFPage, index: Int) -> [Picture] {
        guard let cgPage = page.pageRef, let table = CGPDFOperatorTableCreate() else { return [] }
        let state = ScanState()

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            s.ctm.append(s.ctm.last ?? .identity)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            if s.ctm.count > 1 { s.ctm.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info else { return }
            let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            var v: [CGPDFReal] = Array(repeating: 0, count: 6)
            for k in (0..<6).reversed() {
                var n: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &n) else { return }
                v[k] = n
            }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            let current = s.ctm.last ?? .identity
            s.ctm[s.ctm.count - 1] = m.concatenating(current)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let stream = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
            var xStream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xStream), let xStream,
                  let dict = CGPDFStreamGetDictionary(xStream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image" else { return }
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm.last ?? .identity)
            s.rects.append(rect.standardized)
        }

        let content = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)

        let box = page.bounds(for: .mediaBox)
        return state.rects.compactMap { r in
            let rect = r.intersection(box)
            guard !rect.isNull, rect.width >= 36, rect.height >= 20,
                  rect.width * rect.height < box.width * box.height * 0.8 else { return nil }
            return Picture(image: render(page, rect: rect), rect: rect, page: index)
        }
    }

    /// Randează o zonă a paginii ca imagine (funcționează pentru orice format de imagine din PDF).
    static func render(_ page: PDFPage, rect: CGRect, scale: CGFloat = 2) -> UIImage {
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    // MARK: Curățenie

    /// Elimină rândurile din antet/subsol care se repetă pe mai multe pagini (și numerele de pagină).
    private static func removeRunningHeaders(_ fragments: [Fragment], doc: PDFDocument) -> [Fragment] {
        guard doc.pageCount > 1 else { return fragments }
        func inBand(_ f: Fragment) -> Bool {
            guard let page = doc.page(at: f.page) else { return false }
            let box = page.bounds(for: .mediaBox)
            return f.rect.minY > box.minY + box.height * 0.84 || f.rect.maxY < box.minY + box.height * 0.1
        }
        func key(_ f: Fragment) -> String {
            f.text.lowercased()
                .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        }
        var pagesPerKey: [String: Set<Int>] = [:]
        for f in fragments where inBand(f) { pagesPerKey[key(f), default: []].insert(f.page) }
        return fragments.filter { f in
            guard inBand(f) else { return true }
            if (pagesPerKey[key(f)]?.count ?? 0) >= 2 { return false }
            return f.text.range(of: #"^\d{1,4}$"#, options: .regularExpression) == nil
        }
    }

    private static func removeRepeatedPictures(_ pictures: [Picture]) -> [Picture] {
        func key(_ p: Picture) -> String {
            "\(Int(p.rect.minX / 4))-\(Int(p.rect.minY / 4))-\(Int(p.rect.width / 4))-\(Int(p.rect.height / 4))"
        }
        var pages: [String: Set<Int>] = [:]
        for p in pictures { pages[key(p), default: []].insert(p.page) }
        return pictures.filter { (pages[key($0)]?.count ?? 0) < 2 }
    }

    // MARK: Structură

    private static func structure(_ fragments: [Fragment], _ pictures: [Picture]) -> [Block] {
        // Mărimea textului normal = cea mai frecventă (ponderată cu numărul de caractere)
        var weights: [CGFloat: Int] = [:]
        for f in fragments { weights[f.size, default: 0] += f.text.count }
        let body = weights.max { $0.value < $1.value }?.key ?? 10
        let lineHeight = body * 1.3

        let lefts = fragments.map(\.rect.minX).sorted()
        let rights = fragments.map(\.rect.maxX).sorted()
        let leftMargin = lefts.isEmpty ? 0 : lefts[lefts.count / 10]
        let rightMargin = rights.isEmpty ? 500 : rights[rights.count * 95 / 100]
        let width = max(rightMargin - leftMargin, 100)
        let columnX = leftMargin + width * 0.3

        let textItems: [Item] = fragments.map { Item.text($0) }
        let pictureItems: [Item] = pictures.map { Item.picture($0) }
        var items: [Item] = textItems + pictureItems
        items.sort { a, b in
            if a.page != b.page { return a.page < b.page }
            let ya = (a.top / 3).rounded(), yb = (b.top / 3).rounded()
            if ya != yb { return ya > yb }
            return a.left < b.left
        }

        var blocks: [Block] = []
        var paragraph: ParaState?
        var bullet: BulletState?
        var table: TableState?
        var hasTitle = false
        var skipNext = false

        func flushParagraph() {
            if let p = paragraph {
                if let style = p.style { blocks.append(.heading(style, p.text)) } else { blocks.append(.paragraph(p.text)) }
            }
            paragraph = nil
        }
        func flushBullet() {
            if let b = bullet { blocks.append(.bullet(b.text)) }
            bullet = nil
        }
        func finishTable() {
            guard let t = table else { return }
            table = nil
            if let rows = t.rows(), !rows.isEmpty || t.header != nil {
                if let h = t.header { blocks.append(.tableHeader([h.0, h.1])) }
                for r in rows { blocks.append(.row(r.0, r.1)) }
            } else {
                // Nu era tabel (ex. un rând cu săgeți distanțate): îl tratăm ca paragraf
                let ordered = t.allFragments().sorted { a, b in
                    if a.page != b.page { return a.page < b.page }
                    let ya = (a.rect.midY / 3).rounded(), yb = (b.rect.midY / 3).rounded()
                    return ya != yb ? ya > yb : a.rect.minX < b.rect.minX
                }
                guard let last = ordered.last else { return }
                let text = ordered.map(\.text).reduce("") { join($0, $1) }
                paragraph = ParaState(text: text, style: nil, last: last)
            }
        }
        func flushAll() {
            finishTable()
            flushParagraph()
            flushBullet()
        }
        func gap(_ above: Fragment, _ below: Fragment) -> CGFloat {
            above.page == below.page ? above.rect.minY - below.rect.maxY : 0
        }
        func headingStyle(_ f: Fragment) -> ParaStyle? {
            if f.size >= body * 1.6 { return hasTitle ? .h1 : .title }
            if f.size >= body * 1.18 { return .h2 }
            if f.bold, f.text.count < 90, f.rect.minX < columnX, !f.text.hasPrefix("• ") { return .h3 }
            return nil
        }
        func rightPartner(of f: Fragment, at index: Int) -> Fragment? {
            guard index + 1 < items.count, case .text(let next) = items[index + 1] else { return nil }
            guard next.page == f.page, abs(next.rect.midY - f.rect.midY) < body * 0.6,
                  next.rect.minX >= columnX, next.rect.minX - f.rect.maxX > 12 else { return nil }
            return next
        }

        for (index, item) in items.enumerated() {
            switch item {
            case .picture(let p):
                flushAll()
                blocks.append(.image(p.image, min(340, max(120, p.rect.width))))

            case .text(let f):
                if skipNext { skipNext = false; continue }
                let isRight = f.rect.minX >= columnX
                let partner = isRight ? nil : rightPartner(of: f, at: index)
                let isHeaderRow = partner.map { f.bold && $0.bold } ?? false

                if var t = table {
                    if isRight {
                        t.rights.append(f)
                        table = t
                        continue
                    }
                    if !isHeaderRow, let last = t.labels.last?.last,
                       f.page == last.page, gap(last, f) < lineHeight * 0.45, !f.text.hasPrefix("• ") {
                        t.extendLabel(with: f)
                        table = t
                        continue
                    }
                    if !isHeaderRow && (partner != nil || f.rect.maxX < columnX + 4) {
                        t.addLabel(f)
                        table = t
                        continue
                    }
                    finishTable()
                }

                // Început de tabel: o etichetă în stânga cu text în coloana a doua pe același rând
                if let next = partner {
                    flushParagraph()
                    flushBullet()
                    var t = TableState()
                    t.lineGap = lineHeight * 0.45
                    if isHeaderRow {
                        t.header = (f.text, next.text)
                        skipNext = true
                    } else {
                        t.addLabel(f)
                    }
                    table = t
                    continue
                }

                // Titluri
                if let style = headingStyle(f) {
                    if let p = paragraph, p.style == style, gap(p.last, f) < lineHeight * 0.9 {
                        paragraph = ParaState(text: join(p.text, f.text), style: style, last: f)
                        continue
                    }
                    flushAll()
                    if style == .title { hasTitle = true }
                    paragraph = ParaState(text: f.text, style: style, last: f)
                    continue
                }

                // Liste
                if f.text.hasPrefix("• ") || f.text.range(of: #"^[-–]\s"#, options: .regularExpression) != nil {
                    flushParagraph()
                    flushBullet()
                    let text = f.text.replacingOccurrences(of: #"^(•|[-–])\s*"#, with: "", options: .regularExpression)
                    bullet = BulletState(text: text, last: f)
                    continue
                }
                if let b = bullet, f.rect.minX > leftMargin + 4, gap(b.last, f) < lineHeight * 0.8 {
                    bullet = BulletState(text: join(b.text, f.text), last: f)
                    continue
                }
                flushBullet()

                // Paragrafe
                if let p = paragraph, p.style == nil {
                    let g = gap(p.last, f)
                    let crossPage = p.last.page != f.page
                    let ended = p.text.hasSuffix(".") || p.text.hasSuffix(":")
                    let sameSize = abs(p.last.size - f.size) < 0.6
                    if sameSize && ((!crossPage && g < lineHeight * 0.8) || (crossPage && !ended)) {
                        paragraph = ParaState(text: join(p.text, f.text), style: nil, last: f)
                        continue
                    }
                }
                flushParagraph()
                paragraph = ParaState(text: f.text, style: nil, last: f)
            }
        }
        flushAll()
        return blocks
    }

    /// Tabel cu două coloane. Eticheta din stânga e adesea centrată vertical în celulă,
    /// așa că textul din dreapta se atribuie etichetei celei mai apropiate pe verticală.
    private struct TableState {
        struct Label {
            var text: String
            var first: Fragment
            var last: Fragment
            var mid: CGFloat { (first.rect.maxY + last.rect.minY) / 2 }
        }

        var header: (String, String)?
        var labels: [Label] = []
        var rights: [Fragment] = []
        var lineGap: CGFloat = 6

        mutating func addLabel(_ f: Fragment) {
            labels.append(Label(text: f.text, first: f, last: f))
        }

        mutating func extendLabel(with f: Fragment) {
            guard !labels.isEmpty else { return addLabel(f) }
            labels[labels.count - 1].text = PDFStructureImport.join(labels[labels.count - 1].text, f.text)
            labels[labels.count - 1].last = f
        }

        func allFragments() -> [Fragment] {
            var acc: [Fragment] = []
            for label in labels {
                for f in [label.first, label.last] where !acc.contains(where: { $0.rect == f.rect && $0.page == f.page }) {
                    acc.append(f)
                }
            }
            return acc + rights
        }

        /// nil = prea puține rânduri ca să fie tabel.
        func rows() -> [(String, String)]? {
            guard labels.count >= 2 || header != nil else { return nil }
            if labels.isEmpty {
                let text = rights.map(\.text).reduce("") { PDFStructureImport.join($0, $1) }
                return text.isEmpty ? [] : [("", text)]
            }
            // Grupăm textul din dreapta în celule: între celule spațiul e mai mare decât între rânduri
            let ordered = rights.sorted { a, b in
                a.page != b.page ? a.page < b.page : a.rect.midY > b.rect.midY
            }
            var cells: [[Fragment]] = []
            for r in ordered {
                if let last = cells.last?.last, last.page == r.page, last.rect.minY - r.rect.maxY < lineGap {
                    cells[cells.count - 1].append(r)
                } else {
                    cells.append([r])
                }
            }
            var buckets = Array(repeating: [Fragment](), count: labels.count)
            if cells.count == labels.count {
                for (i, cell) in cells.enumerated() { buckets[i] = cell }
            } else {
                for cell in cells {
                    guard let first = cell.first, let last = cell.last else { continue }
                    let mid = (first.rect.maxY + last.rect.minY) / 2
                    let samePage: [Int] = labels.indices.filter { labels[$0].first.page == first.page }
                    let nearest: Int? = samePage.min { (x: Int, y: Int) -> Bool in
                        let dx: CGFloat = abs(labels[x].mid - mid)
                        let dy: CGFloat = abs(labels[y].mid - mid)
                        return dx < dy
                    }
                    let lastPage: Int = labels.last?.first.page ?? 0
                    let fallback: Int = first.page > lastPage ? labels.count - 1 : 0
                    let index: Int = nearest ?? fallback
                    buckets[index] += cell
                }
            }
            return labels.indices.map { i in
                let ordered = buckets[i].sorted { a, b in
                    if a.page != b.page { return a.page < b.page }
                    return a.rect.midY > b.rect.midY
                }
                let text = ordered.map(\.text).reduce("") { PDFStructureImport.join($0, $1) }
                return (labels[i].text, text)
            }
        }
    }

    private struct ParaState {
        var text: String
        var style: ParaStyle?
        var last: Fragment
    }

    private struct BulletState {
        var text: String
        var last: Fragment
    }


    /// Unește rânduri: reface cuvintele despărțite, dar nu strică linkuri sau căi de fișiere.
    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let lastWord = a.split(separator: " ").last.map(String.init) ?? ""
        let looksLikePath = lastWord.contains("/") || lastWord.contains("://") || lastWord.contains("_")
        if a.hasSuffix("/") && looksLikePath { return a + b }
        if a.hasSuffix("-") {
            if looksLikePath { return a + b }
            if let first = b.first, first.isLowercase { return String(a.dropLast()) + b }
        }
        return a + " " + b
    }

    // MARK: Text formatat

    private static func build(_ blocks: [Block], fallbackTitle: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func newline() {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: RT.attributes(.body))) }
        }
        var listAttrs = RT.attributes(.body)
        listAttrs[.paragraphStyle] = RT.paragraphStyle(.body, list: true)
        var boldList = listAttrs
        boldList[.font] = RT.font(style: .body, design: .standard, bold: true, italic: false)
        var muted = RT.attributes(.body)
        muted[.font] = RT.font(style: .body, design: .standard, bold: true, italic: false, size: 13)
        muted[.foregroundColor] = RT.mutedText
        muted[.guwColor] = "7F98A3"

        let hasTitle = blocks.contains { (block: Block) -> Bool in
            guard case .heading(.title, _) = block else { return false }
            return true
        }
        if !hasTitle {
            out.append(NSAttributedString(string: fallbackTitle, attributes: RT.attributes(.title)))
        }

        for block in blocks {
            newline()
            switch block {
            case let .heading(style, text):
                out.append(NSAttributedString(string: text, attributes: RT.attributes(style)))
            case let .paragraph(text):
                out.append(NSAttributedString(string: text, attributes: RT.attributes(.body)))
            case let .bullet(text):
                out.append(NSAttributedString(string: "• " + text, attributes: listAttrs))
            case let .row(label, text):
                out.append(NSAttributedString(string: "• ", attributes: listAttrs))
                out.append(NSAttributedString(string: label, attributes: boldList))
                if !text.isEmpty {
                    out.append(NSAttributedString(string: (label.isEmpty ? "" : " — ") + text, attributes: listAttrs))
                }
            case let .tableHeader(columns):
                out.append(NSAttributedString(string: columns.joined(separator: "  ·  ").uppercased(), attributes: muted))
            case let .image(image, width):
                let attachment = RT.imageAttachment(image, maxWidth: width)
                let pic = NSMutableAttributedString(attachment: attachment)
                pic.addAttributes(RT.attributes(.body), range: NSRange(location: 0, length: pic.length))
                out.append(pic)
            }
        }
        return out
    }

    /// PDF scanat (fără text): paginile intră ca imagini; textul se poate extrage apoi cu scanarea.
    private static func scannedFallback(_ doc: PDFDocument, title: String) -> NSAttributedString? {
        guard doc.pageCount > 0 else { return nil }
        let out = NSMutableAttributedString(string: title, attributes: RT.attributes(.title))
        var note = RT.attributes(.body)
        note[.foregroundColor] = RT.mutedText
        note[.guwColor] = "7F98A3"
        out.append(NSAttributedString(string: "\nPDF scanat: paginile sunt imagini. Pentru text, folosește Scanează document din bara editorului.",
                                      attributes: note))
        for i in 0..<min(doc.pageCount, 30) {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let attachment = RT.imageAttachment(render(page, rect: box, scale: 1.5), maxWidth: 340)
            let pic = NSMutableAttributedString(string: "\n", attributes: RT.attributes(.body))
            pic.append(NSAttributedString(attachment: attachment))
            out.append(pic)
        }
        return out
    }
}
