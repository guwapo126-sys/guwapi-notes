import UIKit
import UniformTypeIdentifiers

// MARK: - Atribute proprii (salvate în fiecare notă)

extension NSAttributedString.Key {
    /// Stilul paragrafului: title, h1, h2, h3, body, mono.
    static let guwStyle = NSAttributedString.Key("guw.style")
    /// Familia de font: standard, rounded, serif, mono.
    static let guwDesign = NSAttributedString.Key("guw.design")
    /// Culoare de text aleasă de utilizator (hex). Lipsă = culoarea implicită.
    static let guwColor = NSAttributedString.Key("guw.color")
    /// Marchează caracterul de checkbox; valoare NSNumber(bool) = bifat.
    static let guwCheckbox = NSAttributedString.Key("guw.checkbox")
}

enum ParaStyle: String, CaseIterable, Identifiable {
    case title, h1, h2, h3, body, mono
    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Titlu"
        case .h1: return "Titlu 1 (H1)"
        case .h2: return "Titlu 2 (H2)"
        case .h3: return "Titlu 3 (H3)"
        case .body: return "Text"
        case .mono: return "Cod"
        }
    }

    var short: String {
        switch self {
        case .title: return "T"
        case .h1: return "H1"
        case .h2: return "H2"
        case .h3: return "H3"
        case .body: return "Aa"
        case .mono: return "</>"
        }
    }

    var size: CGFloat {
        switch self {
        case .title: return 30
        case .h1: return 25
        case .h2: return 21
        case .h3: return 18
        case .body: return 17
        case .mono: return 15
        }
    }

    var defaultBold: Bool { self == .title || self == .h1 || self == .h2 || self == .h3 }
    var isHeading: Bool { defaultBold }
}

enum FontDesign: String, CaseIterable, Identifiable {
    case standard, rounded, serif, mono
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .rounded: return "Rotunjit"
        case .serif: return "Serif"
        case .mono: return "Monospace"
        }
    }

    var system: UIFontDescriptor.SystemDesign {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

enum ListKind { case bullet, number, check }

extension UIColor {
    convenience init(hexString: String) {
        let v = UInt32(hexString.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xE6F4F7
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Text bogat: fonturi, stiluri, codare, export

enum RT {
    static let defaultText = UIColor(hexString: "E6F4F7")
    static let mutedText = UIColor(hexString: "7F98A3")
    static let accent = UIColor(hexString: "59E0EF")

    static func font(style: ParaStyle, design: FontDesign, bold: Bool, italic: Bool, size: CGFloat? = nil) -> UIFont {
        let pointSize = size ?? style.size
        let weight: UIFont.Weight = bold ? .bold : .regular
        var descriptor = UIFont.systemFont(ofSize: pointSize, weight: weight).fontDescriptor
        let chosen: FontDesign = style == .mono ? .mono : design
        if let d = descriptor.withDesign(chosen.system) { descriptor = d }
        if italic, let d = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = d
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    static func paragraphStyle(_ style: ParaStyle, list: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = style.isHeading ? 6 : 4
        p.paragraphSpacingBefore = style.isHeading ? 10 : 0
        if list { p.headIndent = 26 }
        return p
    }

    static func attributes(_ style: ParaStyle, design: FontDesign = .standard) -> [NSAttributedString.Key: Any] {
        [
            .font: font(style: style, design: design, bold: style.defaultBold, italic: false),
            .foregroundColor: defaultText,
            .paragraphStyle: paragraphStyle(style, list: false),
            .guwStyle: style.rawValue,
            .guwDesign: design.rawValue
        ]
    }

    static func style(of attrs: [NSAttributedString.Key: Any]) -> ParaStyle {
        ParaStyle(rawValue: attrs[.guwStyle] as? String ?? "") ?? .body
    }

    static func design(of attrs: [NSAttributedString.Key: Any]) -> FontDesign {
        FontDesign(rawValue: attrs[.guwDesign] as? String ?? "") ?? .standard
    }

    static func traits(of attrs: [NSAttributedString.Key: Any]) -> (bold: Bool, italic: Bool, size: CGFloat) {
        guard let f = attrs[.font] as? UIFont else { return (false, false, 17) }
        let t = f.fontDescriptor.symbolicTraits
        return (t.contains(.traitBold), t.contains(.traitItalic), f.pointSize)
    }

    // MARK: Checkbox

    static func checkbox(_ checked: Bool, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let size = max(15, (base[.font] as? UIFont)?.pointSize ?? 17)
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle", withConfiguration: config)?
            .withTintColor(checked ? accent : mutedText, renderingMode: .alwaysOriginal)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -4, width: size + 3, height: size + 3)
        let s = NSMutableAttributedString(attachment: attachment)
        var attrs = base
        attrs.removeValue(forKey: .attachment)
        attrs[.guwCheckbox] = NSNumber(value: checked)
        s.addAttributes(attrs, range: NSRange(location: 0, length: s.length))
        return s
    }

    static func isCheckbox(_ s: NSAttributedString, at index: Int) -> Bool? {
        guard index >= 0, index < s.length else { return nil }
        return (s.attribute(.guwCheckbox, at: index, effectiveRange: nil) as? NSNumber)?.boolValue
    }

    /// Prefixul de listă de la începutul unui paragraf.
    static func listPrefix(in s: NSAttributedString, paragraphStart p: Int) -> (kind: ListKind, length: Int)? {
        let ns = s.string as NSString
        guard p < ns.length else { return nil }
        if isCheckbox(s, at: p) != nil {
            let hasSpace = p + 1 < ns.length && ns.character(at: p + 1) == 32
            return (.check, hasSpace ? 2 : 1)
        }
        let rest = ns.substring(from: p)
        if rest.hasPrefix("• ") { return (.bullet, 2) }
        if let r = rest.range(of: #"^\d{1,3}\. "#, options: .regularExpression) {
            return (.number, rest.distance(from: r.lowerBound, to: r.upperBound))
        }
        return nil
    }

    static func numberValue(in s: NSAttributedString, paragraphStart p: Int) -> Int? {
        let rest = (s.string as NSString).substring(from: p)
        guard let r = rest.range(of: #"^\d{1,3}"#, options: .regularExpression) else { return nil }
        return Int(rest[r])
    }

    // MARK: Imagini

    static func imageAttachment(_ image: UIImage, maxWidth: CGFloat) -> NSTextAttachment {
        let scaled = downscale(image, maxPixel: 1600)
        let data = scaled.jpegData(compressionQuality: 0.8) ?? Data()
        let attachment = NSTextAttachment(data: data, ofType: UTType.jpeg.identifier)
        attachment.image = scaled
        let width = min(maxWidth, scaled.size.width)
        let ratio = scaled.size.width > 0 ? scaled.size.height / scaled.size.width : 1
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * ratio)
        return attachment
    }

    static func downscale(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixel else { return image }
        let factor = maxPixel / longest
        let target = CGSize(width: image.size.width * image.scale * factor,
                            height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func containsImages(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, stop in
            if value != nil, isCheckbox(s, at: range.location) == nil { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: Codare (fișier .note)

    static func encode(_ s: NSAttributedString) -> Data? {
        let copy = NSMutableAttributedString(attributedString: s)
        var replacements: [(NSRange, NSTextAttachment)] = []
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let a = value as? NSTextAttachment else { return }
            if isCheckbox(copy, at: range.location) != nil {
                replacements.append((range, NSTextAttachment()))   // se regenerează la deschidere
            } else {
                let data = a.contents ?? a.image?.jpegData(compressionQuality: 0.8) ?? Data()
                let clean = NSTextAttachment(data: data, ofType: a.fileType ?? UTType.jpeg.identifier)
                clean.bounds = a.bounds
                replacements.append((range, clean))
            }
        }
        for (range, a) in replacements { copy.addAttribute(.attachment, value: a, range: range) }
        return try? NSKeyedArchiver.archivedData(withRootObject: copy, requiringSecureCoding: false)
    }

    static func decode(_ data: Data) -> NSMutableAttributedString? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString
        unarchiver.finishDecoding()
        guard let object else { return nil }
        return normalize(NSMutableAttributedString(attributedString: object))
    }

    /// Reface checkbox-urile și imaginile după încărcare.
    static func normalize(_ s: NSMutableAttributedString) -> NSMutableAttributedString {
        var boxes: [(NSRange, Bool, [NSAttributedString.Key: Any])] = []
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard let a = value as? NSTextAttachment else { return }
            if let checked = isCheckbox(s, at: range.location) {
                boxes.append((range, checked, s.attributes(at: range.location, effectiveRange: nil)))
            } else if a.image == nil, let data = a.contents, let img = UIImage(data: data) {
                a.image = img
            }
        }
        for (range, checked, attrs) in boxes.reversed() {
            s.replaceCharacters(in: range, with: checkbox(checked, base: attrs))
        }
        return s
    }

    // MARK: Rezumat pentru listă, căutare, widget

    static func summary(of s: NSAttributedString) -> (title: String, preview: String, plain: String, tags: [String]) {
        let plain = s.string
            .replacingOccurrences(of: "\u{FFFC} ", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
        let lines = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let title = String((lines.first ?? "").prefix(80))
        let preview = String(lines.dropFirst().joined(separator: " · ").prefix(240))
        return (title, preview, plain, tags(in: plain))
    }

    static func tags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\p{N}_\-]{2,40})"#) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            if seen.insert(tag).inserted { out.append(tag) }
        }
        return out
    }

    // MARK: Export Markdown

    static func markdown(_ s: NSAttributedString) -> String {
        let ns = s.string as NSString
        var lines: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { lines.append(""); return }
            let style = RT.style(of: s.attributes(at: range.location, effectiveRange: nil))
            var start = range.location
            var prefix = ""
            if let lp = listPrefix(in: s, paragraphStart: range.location) {
                switch lp.kind {
                case .check: prefix = (isCheckbox(s, at: range.location) == true) ? "- [x] " : "- [ ] "
                case .bullet: prefix = "- "
                case .number: prefix = ns.substring(with: NSRange(location: range.location, length: lp.length))
                }
                start += lp.length
            }
            let body = inlineMarkdown(s, NSRange(location: start, length: range.location + range.length - start),
                                      plain: style == .mono)
            switch style {
            case .title, .h1: lines.append("# " + body)
            case .h2: lines.append("## " + body)
            case .h3: lines.append("### " + body)
            case .mono: lines.append("`" + body + "`")
            case .body: lines.append(prefix + body)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func inlineMarkdown(_ s: NSAttributedString, _ range: NSRange, plain: Bool) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        s.enumerateAttributes(in: range) { attrs, r, _ in
            if attrs[.attachment] != nil {
                if attrs[.guwCheckbox] == nil { out += "![imagine]" }
                return
            }
            let text = (s.string as NSString).substring(with: r)
            if plain || text.trimmingCharacters(in: .whitespaces).isEmpty { out += text; return }
            let t = traits(of: attrs)
            let headingBold = style(of: attrs).defaultBold
            var piece = text
            if t.italic { piece = "_\(piece)_" }
            if t.bold && !headingBold { piece = "**\(piece)**" }
            if attrs[.strikethroughStyle] != nil { piece = "~~\(piece)~~" }
            out += piece
        }
        return out
    }

    // MARK: Export PDF (text închis pe fundal alb)

    static func pdf(_ s: NSAttributedString) -> Data {
        let printable = NSMutableAttributedString(attributedString: s)
        let full = NSRange(location: 0, length: printable.length)
        var defaults: [NSRange] = []
        printable.enumerateAttribute(.guwColor, in: full) { value, range, _ in
            if value == nil { defaults.append(range) }
        }
        for r in defaults { printable.addAttribute(.foregroundColor, value: UIColor.black, range: r) }

        let formatter = UISimpleTextPrintFormatter(attributedText: printable)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)   // A4
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.insetBy(dx: 48, dy: 56)), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        let pages = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}

// MARK: - Șabloane predefinite

struct BuiltInTemplate: Identifiable {
    enum Line {
        case p(ParaStyle, String)
        case bullet(String)
        case check(String)
    }

    let id: String
    let name: String
    let icon: String
    let colorHex: String?
    let lines: () -> [Line]

    func build() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, line) in lines().enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: RT.attributes(.body))) }
            switch line {
            case let .p(style, text):
                out.append(NSAttributedString(string: text, attributes: RT.attributes(style)))
            case let .bullet(text):
                var a = RT.attributes(.body)
                a[.paragraphStyle] = RT.paragraphStyle(.body, list: true)
                out.append(NSAttributedString(string: "• " + text, attributes: a))
            case let .check(text):
                var a = RT.attributes(.body)
                a[.paragraphStyle] = RT.paragraphStyle(.body, list: true)
                out.append(RT.checkbox(false, base: a))
                out.append(NSAttributedString(string: " " + text, attributes: a))
            }
        }
        return out
    }

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ro_RO")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: Date())
    }

    static let all: [BuiltInTemplate] = [
        BuiltInTemplate(id: "meeting", name: "Meeting", icon: "person.2.fill", colorHex: "4C8DFF") {
            [.p(.title, "Meeting — \(today)"),
             .p(.h2, "Participanți"), .bullet(""),
             .p(.h2, "Agendă"), .bullet(""),
             .p(.h2, "Decizii"), .bullet(""),
             .p(.h2, "Acțiuni"), .check(""),
             .p(.body, "#meeting")]
        },
        BuiltInTemplate(id: "brief", name: "Brief client", icon: "briefcase.fill", colorHex: "59E0EF") {
            [.p(.title, "Brief — "),
             .p(.h2, "Context"), .p(.body, ""),
             .p(.h2, "Obiective"), .bullet(""),
             .p(.h2, "Livrabile"), .check(""),
             .p(.h2, "Termene"), .bullet(""),
             .p(.h2, "Contacte"), .bullet(""),
             .p(.body, "#brief")]
        },
        BuiltInTemplate(id: "deploy", name: "Checklist deploy", icon: "shippingbox.fill", colorHex: "3DDC97") {
            [.p(.title, "Deploy — \(today)"),
             .p(.h3, "Înainte"),
             .check("Backup bază de date"), .check("Variabile de mediu verificate"), .check("Build și teste OK"),
             .p(.h3, "Lansare"),
             .check("Migrări rulate"), .check("Smoke test în producție"),
             .p(.h3, "După"),
             .check("Loguri și monitorizare verificate"), .check("Client anunțat"),
             .p(.body, "#deploy")]
        },
        BuiltInTemplate(id: "bug", name: "Bug / incident", icon: "ladybug.fill", colorHex: "FF5A5F") {
            [.p(.title, "Bug — "),
             .p(.h2, "Simptom"), .p(.body, ""),
             .p(.h2, "Pași de reproducere"), .bullet(""),
             .p(.h2, "Cauză"), .p(.body, ""),
             .p(.h2, "Rezolvare"), .check("Fix implementat"), .check("Testat"), .check("Livrat"),
             .p(.body, "#bug")]
        },
        BuiltInTemplate(id: "idea", name: "Idee rapidă", icon: "lightbulb.fill", colorHex: "FFD166") {
            [.p(.title, "Idee"), .p(.body, ""), .p(.body, "#idee")]
        }
    ]
}
