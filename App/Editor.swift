import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

// MARK: - Controller: toate comenzile de formatare

@MainActor
final class EditorController: ObservableObject {
    weak var textView: UITextView?

    @Published var style: ParaStyle = .body
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderline = false
    @Published var isStrike = false
    @Published var showPhotoPicker = false
    @Published var showScanner = false

    /// Salvarea notei; apelată cu întârziere după fiecare modificare.
    var save: ((NSAttributedString) -> Void)?
    private var pendingSave: DispatchWorkItem?

    private var storage: NSTextStorage? { textView?.textStorage }

    // MARK: Stare

    func refreshState() {
        guard let tv = textView else { return }
        let r = tv.selectedRange
        let attrs: [NSAttributedString.Key: Any]
        if r.length > 0, r.location < tv.textStorage.length {
            attrs = tv.textStorage.attributes(at: r.location, effectiveRange: nil)
        } else {
            attrs = tv.typingAttributes
        }
        let t = RT.traits(of: attrs)
        style = RT.style(of: attrs)
        isBold = t.bold
        isItalic = t.italic
        isUnderline = attrs[.underlineStyle] != nil
        isStrike = attrs[.strikethroughStyle] != nil
    }

    func changed() {
        refreshState()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Salvează imediat (la ieșirea din notă).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let tv = textView else { return }
        save?(NSAttributedString(attributedString: tv.attributedText))
    }

    var currentText: NSAttributedString {
        NSAttributedString(attributedString: textView?.attributedText ?? NSAttributedString())
    }

    private func paragraphRange() -> NSRange? {
        guard let tv = textView else { return nil }
        return (tv.textStorage.string as NSString).paragraphRange(for: tv.selectedRange)
    }

    /// Aplică o transformare pe selecție sau, fără selecție, pe atributele de scriere.
    private func modifySelection(_ transform: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let tv = textView, let storage else { return }
        let r = tv.selectedRange
        if r.length == 0 {
            var typing = tv.typingAttributes
            transform(&typing)
            tv.typingAttributes = typing
            refreshState()
            return
        }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: r) { attrs, range, _ in runs.append((range, attrs)) }
        storage.beginEditing()
        for (range, attrs) in runs {
            var a = attrs
            transform(&a)
            storage.setAttributes(a, range: range)
        }
        storage.endEditing()
        tv.selectedRange = r
        changed()
    }

    // MARK: Stil paragraf

    func apply(_ newStyle: ParaStyle) {
        guard let tv = textView, let storage, let pr = paragraphRange() else { return }
        let content = contentRange(pr)
        if content.length > 0 {
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: content) { attrs, range, _ in runs.append((range, attrs)) }
            storage.beginEditing()
            for (range, attrs) in runs where attrs[.attachment] == nil || attrs[.guwCheckbox] != nil {
                var a = attrs
                let isList = RT.listPrefix(in: storage, paragraphStart: pr.location) != nil
                a[.font] = RT.font(style: newStyle, design: RT.design(of: attrs),
                                   bold: newStyle.defaultBold, italic: RT.traits(of: attrs).italic)
                a[.guwStyle] = newStyle.rawValue
                a[.paragraphStyle] = RT.paragraphStyle(newStyle, list: isList)
                storage.setAttributes(a, range: range)
            }
            storage.endEditing()
        }
        var typing = tv.typingAttributes
        typing[.font] = RT.font(style: newStyle, design: RT.design(of: typing), bold: newStyle.defaultBold, italic: false)
        typing[.guwStyle] = newStyle.rawValue
        typing[.paragraphStyle] = RT.paragraphStyle(newStyle, list: false)
        tv.typingAttributes = typing
        changed()
    }

    /// Paragraful fără caracterul de linie nouă de la final.
    private func contentRange(_ pr: NSRange) -> NSRange {
        guard let storage else { return pr }
        var length = pr.length
        let ns = storage.string as NSString
        while length > 0 {
            let c = ns.character(at: pr.location + length - 1)
            if c == 10 || c == 13 || c == 0x2029 { length -= 1 } else { break }
        }
        return NSRange(location: pr.location, length: length)
    }

    // MARK: Caractere

    func toggleBold() {
        let target = !isBold
        modifySelection { a in
            let t = RT.traits(of: a)
            a[.font] = RT.font(style: RT.style(of: a), design: RT.design(of: a), bold: target, italic: t.italic, size: t.size)
        }
    }

    func toggleItalic() {
        let target = !isItalic
        modifySelection { a in
            let t = RT.traits(of: a)
            a[.font] = RT.font(style: RT.style(of: a), design: RT.design(of: a), bold: t.bold, italic: target, size: t.size)
        }
    }

    func toggleUnderline() {
        let target = !isUnderline
        modifySelection { a in
            if target { a[.underlineStyle] = NSUnderlineStyle.single.rawValue } else { a.removeValue(forKey: .underlineStyle) }
        }
    }

    func toggleStrike() {
        let target = !isStrike
        modifySelection { a in
            if target { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue } else { a.removeValue(forKey: .strikethroughStyle) }
        }
    }

    func setColor(_ hex: String?) {
        modifySelection { a in
            if let hex {
                a[.foregroundColor] = UIColor(hexString: hex)
                a[.guwColor] = hex
            } else {
                a[.foregroundColor] = RT.defaultText
                a.removeValue(forKey: .guwColor)
            }
        }
    }

    func setHighlight(_ hex: String?) {
        modifySelection { a in
            if let hex {
                a[.backgroundColor] = UIColor(hexString: hex).withAlphaComponent(0.35)
            } else {
                a.removeValue(forKey: .backgroundColor)
            }
        }
    }

    func setDesign(_ design: FontDesign) {
        modifySelection { a in
            let t = RT.traits(of: a)
            a[.guwDesign] = design.rawValue
            a[.font] = RT.font(style: RT.style(of: a), design: design, bold: t.bold, italic: t.italic, size: t.size)
        }
    }

    func changeSize(by delta: CGFloat) {
        modifySelection { a in
            let t = RT.traits(of: a)
            let size = min(60, max(10, t.size + delta))
            a[.font] = RT.font(style: RT.style(of: a), design: RT.design(of: a), bold: t.bold, italic: t.italic, size: size)
        }
    }

    // MARK: Liste

    func toggleList(_ kind: ListKind) {
        guard let tv = textView, let storage else { return }
        let ns = storage.string as NSString
        let selection = tv.selectedRange
        let whole = ns.paragraphRange(for: selection)

        var starts: [Int] = []
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.location)
        }
        if starts.isEmpty { starts = [whole.location] }

        let allSame = starts.allSatisfy { RT.listPrefix(in: storage, paragraphStart: $0)?.kind == kind }
        var delta = 0

        storage.beginEditing()
        for (index, start) in starts.enumerated().reversed() {
            let existing = RT.listPrefix(in: storage, paragraphStart: start)
            var base: [NSAttributedString.Key: Any] = start < storage.length
                ? storage.attributes(at: start, effectiveRange: nil)
                : tv.typingAttributes
            base.removeValue(forKey: .attachment)
            base.removeValue(forKey: .guwCheckbox)
            let paraStyle = RT.style(of: base)
            base[.paragraphStyle] = RT.paragraphStyle(paraStyle, list: !allSame)

            let replacement: NSAttributedString
            if allSame {
                replacement = NSAttributedString(string: "")
            } else {
                replacement = prefix(kind, number: index + 1, base: base)
            }
            let oldRange = NSRange(location: start, length: existing?.length ?? 0)
            storage.replaceCharacters(in: oldRange, with: replacement)
            if index == 0 { delta = replacement.length - oldRange.length }

            // Indentare pentru tot paragraful
            let para = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
            if para.length > 0 {
                storage.addAttribute(.paragraphStyle, value: RT.paragraphStyle(paraStyle, list: !allSame), range: para)
            }
        }
        storage.endEditing()

        if starts.count == 1 {
            let minimum = starts[0] + (allSame ? 0 : prefixLength(kind, number: 1))
            tv.selectedRange = NSRange(location: max(minimum, selection.location + delta), length: 0)
        }
        var typing = tv.typingAttributes
        typing.removeValue(forKey: .attachment)
        typing.removeValue(forKey: .guwCheckbox)
        tv.typingAttributes = typing
        changed()
    }

    private func prefix(_ kind: ListKind, number: Int, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch kind {
        case .bullet:
            return NSAttributedString(string: "• ", attributes: base)
        case .number:
            return NSAttributedString(string: "\(number). ", attributes: base)
        case .check:
            let s = NSMutableAttributedString(attributedString: RT.checkbox(false, base: base))
            s.append(NSAttributedString(string: " ", attributes: base))
            return s
        }
    }

    private func prefixLength(_ kind: ListKind, number: Int) -> Int {
        switch kind {
        case .bullet: return 2
        case .number: return "\(number). ".count
        case .check: return 2
        }
    }

    /// Enter: continuă lista sau o închide pe un rând gol; după titlu revine la text normal.
    func handleReturn(in range: NSRange) -> Bool {
        guard let tv = textView, let storage else { return true }
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let content = contentRange(para)
        var typing = tv.typingAttributes
        typing.removeValue(forKey: .attachment)
        typing.removeValue(forKey: .guwCheckbox)

        if let lp = RT.listPrefix(in: storage, paragraphStart: para.location) {
            let afterPrefix = content.length - lp.length
            if afterPrefix <= 0 {
                // Rând gol de listă: închide lista
                storage.replaceCharacters(in: NSRange(location: para.location, length: lp.length), with: "")
                storage.addAttribute(.paragraphStyle, value: RT.paragraphStyle(RT.style(of: typing), list: false),
                                     range: (storage.string as NSString).paragraphRange(for: NSRange(location: para.location, length: 0)))
                tv.selectedRange = NSRange(location: para.location, length: 0)
                typing[.paragraphStyle] = RT.paragraphStyle(RT.style(of: typing), list: false)
                tv.typingAttributes = typing
                changed()
                return false
            }
            var base = typing
            base[.paragraphStyle] = RT.paragraphStyle(RT.style(of: typing), list: true)
            // Textul nou nu moștenește tăierea/estomparea unui element bifat
            base.removeValue(forKey: .strikethroughStyle)
            if base[.guwColor] == nil { base[.foregroundColor] = RT.defaultText }
            let next = (lp.kind == .number ? (RT.numberValue(in: storage, paragraphStart: para.location) ?? 0) : 0) + 1
            let insert = NSMutableAttributedString(string: "\n", attributes: base)
            insert.append(prefix(lp.kind, number: next, base: base))
            storage.replaceCharacters(in: range, with: insert)
            tv.selectedRange = NSRange(location: range.location + insert.length, length: 0)
            tv.typingAttributes = base
            changed()
            return false
        }

        if RT.style(of: typing) != .body && RT.style(of: typing) != .mono {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: typing))
            tv.selectedRange = NSRange(location: range.location + 1, length: 0)
            var body = RT.attributes(.body, design: RT.design(of: typing))
            if let color = typing[.guwColor] as? String {
                body[.guwColor] = color
                body[.foregroundColor] = UIColor(hexString: color)
            }
            tv.typingAttributes = body
            changed()
            return false
        }
        return true
    }

    // MARK: Checkbox

    func toggleCheckbox(at index: Int) {
        guard let tv = textView, let storage, let checked = RT.isCheckbox(storage, at: index) else { return }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        let selection = tv.selectedRange
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: index, length: 1), with: RT.checkbox(!checked, base: attrs))
        let para = contentRange((storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0)))
        let textStart = index + 1
        let textRange = NSRange(location: textStart, length: max(0, para.location + para.length - textStart))
        if textRange.length > 0 {
            if !checked {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                storage.addAttribute(.foregroundColor, value: RT.mutedText, range: textRange)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: textRange)
                var restores: [(NSRange, UIColor)] = []
                storage.enumerateAttribute(.guwColor, in: textRange) { value, r, _ in
                    restores.append((r, (value as? String).map { UIColor(hexString: $0) } ?? RT.defaultText))
                }
                for (r, c) in restores { storage.addAttribute(.foregroundColor, value: c, range: r) }
            }
        }
        storage.endEditing()
        tv.selectedRange = selection
        changed()
    }

    // MARK: Inserare

    func insertImage(_ image: UIImage) {
        guard let tv = textView, let storage else { return }
        let width = tv.bounds.width - tv.textContainerInset.left - tv.textContainerInset.right
            - tv.textContainer.lineFragmentPadding * 2 - 4
        let attachment = RT.imageAttachment(image, maxWidth: max(120, width))
        var base = RT.attributes(.body)
        if let ps = tv.typingAttributes[.guwDesign] { base[.guwDesign] = ps }
        let insert = NSMutableAttributedString(string: "\n", attributes: base)
        let img = NSMutableAttributedString(attachment: attachment)
        img.addAttributes(base, range: NSRange(location: 0, length: img.length))
        insert.append(img)
        insert.append(NSAttributedString(string: "\n", attributes: base))
        let r = tv.selectedRange
        storage.replaceCharacters(in: r, with: insert)
        tv.selectedRange = NSRange(location: r.location + insert.length, length: 0)
        tv.typingAttributes = base
        changed()
    }

    func insertText(_ text: String) {
        guard let tv = textView, let storage, !text.isEmpty else { return }
        var base = tv.typingAttributes
        base.removeValue(forKey: .attachment)
        base.removeValue(forKey: .guwCheckbox)
        let r = tv.selectedRange
        let s = NSAttributedString(string: text, attributes: base)
        storage.replaceCharacters(in: r, with: s)
        tv.selectedRange = NSRange(location: r.location + s.length, length: 0)
        changed()
    }

    /// Live Text: textul din cameră se scrie direct la cursor.
    var canCaptureText: Bool {
        guard let tv = textView else { return false }
        return tv.canPerformAction(#selector(UIResponder.captureTextFromCamera(_:)), withSender: nil)
    }

    func captureTextFromCamera() {
        guard let tv = textView else { return }
        if !tv.isFirstResponder { tv.becomeFirstResponder() }
        tv.captureTextFromCamera(nil)
    }

    /// Inserează textul scanat, cu titluri și liste.
    func insertBlocks(_ all: [OCRBlock], unclear mode: UnclearMode = .image) {
        let blocks = mode == .skip ? all.filter { $0.kind != .unclear } : all
        guard let tv = textView, let storage, !blocks.isEmpty else { return }
        let design = RT.design(of: tv.typingAttributes)
        let warn = UIColor(hexString: "FF9F43")
        let out = NSMutableAttributedString()
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: RT.attributes(.body, design: design))) }
            switch b.kind {
            case .unclear:
                var a = RT.attributes(.body, design: design)
                a[.foregroundColor] = warn
                a[.guwColor] = "FF9F43"
                if mode == .image, let img = b.image {
                    let width = tv.bounds.width - tv.textContainerInset.left - tv.textContainerInset.right
                        - tv.textContainer.lineFragmentPadding * 2 - 4
                    let maxW = min(max(120, width), img.size.width * 70 / max(img.size.height, 1))
                    let attachment = RT.imageAttachment(img, maxWidth: maxW)
                    out.append(NSAttributedString(string: "⚠ ", attributes: a))
                    let pic = NSMutableAttributedString(attachment: attachment)
                    pic.addAttributes(RT.attributes(.body, design: design), range: NSRange(location: 0, length: pic.length))
                    out.append(pic)
                } else {
                    a[.backgroundColor] = warn.withAlphaComponent(0.25)
                    out.append(NSAttributedString(string: "⚠ " + (b.text.isEmpty ? "necitit" : b.text), attributes: a))
                }
            case .heading:
                out.append(NSAttributedString(string: b.text, attributes: RT.attributes(.h2, design: design)))
            case .bullet:
                var a = RT.attributes(.body, design: design)
                a[.paragraphStyle] = RT.paragraphStyle(.body, list: true)
                out.append(NSAttributedString(string: "• " + b.text, attributes: a))
            case .paragraph, .line:
                out.append(NSAttributedString(string: b.text, attributes: RT.attributes(.body, design: design)))
            }
        }
        let r = tv.selectedRange
        let ns = storage.string as NSString
        let atLineStart = r.location == 0 || ns.character(at: r.location - 1) == 10
        if !atLineStart {
            out.insert(NSAttributedString(string: "\n", attributes: RT.attributes(.body, design: design)), at: 0)
        }
        out.append(NSAttributedString(string: "\n", attributes: RT.attributes(.body, design: design)))
        storage.replaceCharacters(in: r, with: out)
        tv.selectedRange = NSRange(location: r.location + out.length, length: 0)
        tv.typingAttributes = RT.attributes(.body, design: design)
        changed()
    }

    // MARK: Layout

    /// Paragrafele atinse de selecție (sau paragraful curent).
    private func selectedParagraphs() -> NSRange? {
        guard let tv = textView, let storage else { return nil }
        return (storage.string as NSString).paragraphRange(for: tv.selectedRange)
    }

    private func updateParagraphStyles(_ transform: (NSMutableParagraphStyle) -> Void) {
        guard let tv = textView, let storage, let range = selectedParagraphs() else { return }
        let selection = tv.selectedRange
        if range.length == 0 {
            let current = (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? NSParagraphStyle.default
            let p = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            transform(p)
            tv.typingAttributes[.paragraphStyle] = p
            return
        }
        var runs: [(NSRange, NSParagraphStyle?)] = []
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, r, _ in
            runs.append((r, value as? NSParagraphStyle))
        }
        storage.beginEditing()
        for (r, style) in runs {
            let p = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            transform(p)
            storage.addAttribute(.paragraphStyle, value: p, range: r)
        }
        storage.endEditing()
        tv.selectedRange = selection
        if let current = tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
           let p = current.mutableCopy() as? NSMutableParagraphStyle {
            transform(p)
            tv.typingAttributes[.paragraphStyle] = p
        }
        changed()
    }

    func align(_ alignment: NSTextAlignment) {
        updateParagraphStyles { $0.alignment = alignment }
    }

    func indent(_ delta: CGFloat) {
        updateParagraphStyles { p in
            p.firstLineHeadIndent = max(0, p.firstLineHeadIndent + delta)
            p.headIndent = max(0, p.headIndent + delta)
        }
    }

    /// Unește rândurile selectate într-un singur paragraf (sau paragraful curent cu următorul).
    func joinLines() {
        guard let tv = textView, let storage else { return }
        let ns = storage.string as NSString
        var range = tv.selectedRange
        if range.length == 0 {
            let current = ns.paragraphRange(for: range)
            let end = current.location + current.length
            guard end < ns.length else { return }
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            range = NSRange(location: current.location, length: current.length + next.length)
        }
        // Nu atingem linia nouă de la finalul intervalului
        var last = range.location + range.length
        while last > range.location, ns.character(at: last - 1) == 10 { last -= 1 }
        var newlines: [Int] = []
        for i in range.location..<last where ns.character(at: i) == 10 { newlines.append(i) }
        guard !newlines.isEmpty else { return }

        storage.beginEditing()
        for i in newlines.reversed() {
            let current = storage.string as NSString
            let prevIsHyphen = i > 0 && current.character(at: i - 1) == 45
            let nextIsLower: Bool = {
                guard i + 1 < current.length else { return false }
                let c = current.substring(with: NSRange(location: i + 1, length: 1))
                return c.lowercased() == c && c.uppercased() != c
            }()
            if prevIsHyphen && nextIsLower {
                storage.replaceCharacters(in: NSRange(location: i - 1, length: 2), with: "")
            } else {
                // elimină spațiile din jurul rândului nou, lasă unul singur
                var start = i
                var end = i + 1
                while start > 0, current.character(at: start - 1) == 32 { start -= 1 }
                while end < current.length, current.character(at: end) == 32 { end += 1 }
                storage.replaceCharacters(in: NSRange(location: start, length: end - start), with: " ")
            }
        }
        storage.endEditing()
        tv.selectedRange = NSRange(location: range.location, length: 0)
        changed()
    }

    /// Curăță textul: rânduri goale multiple, spații duble, spații la final de rând.
    func cleanUp() {
        guard let tv = textView, let storage else { return }
        let selection = tv.selectedRange
        let target = selection.length > 0 ? selection : NSRange(location: 0, length: storage.length)
        let rules: [(String, String)] = [
            (#"[ \t]+\n"#, "\n"),        // spații la final de rând
            (#"\n{3,}"#, "\n\n"),         // cel mult un rând gol
            (#"(?<=\S) {2,}"#, " ")       // spații duble în text
        ]
        storage.beginEditing()
        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let currentLength = target.location + target.length <= storage.length
                ? target.length : max(0, storage.length - target.location)
            let scope = NSRange(location: target.location, length: currentLength)
            for m in regex.matches(in: storage.string, range: scope).reversed() {
                storage.replaceCharacters(in: m.range, with: replacement)
            }
        }
        storage.endEditing()
        tv.selectedRange = NSRange(location: min(selection.location, storage.length), length: 0)
        changed()
    }

    /// Schimbă locul a două paragrafe vecine; întoarce lungimea primei bucăți rezultate.
    @discardableResult
    private func swapParagraphs(_ first: NSRange, _ second: NSRange) -> Int {
        guard let storage else { return 0 }
        let a = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: first))
        let b = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: second))
        if !b.string.hasSuffix("\n"), a.string.hasSuffix("\n") {
            let nl = a.attributedSubstring(from: NSRange(location: a.length - 1, length: 1))
            a.deleteCharacters(in: NSRange(location: a.length - 1, length: 1))
            b.append(nl)
        }
        let combined = NSMutableAttributedString(attributedString: b)
        combined.append(a)
        storage.replaceCharacters(in: NSRange(location: first.location, length: first.length + second.length), with: combined)
        return b.length
    }

    func moveParagraph(up: Bool) {
        guard let tv = textView, let storage else { return }
        let ns = storage.string as NSString
        let selection = tv.selectedRange
        let current = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let offset = selection.location - current.location
        storage.beginEditing()
        if up {
            guard current.location > 0 else { storage.endEditing(); return }
            let previous = ns.paragraphRange(for: NSRange(location: current.location - 1, length: 0))
            swapParagraphs(previous, current)
            storage.endEditing()
            tv.selectedRange = NSRange(location: previous.location + offset, length: 0)
        } else {
            let end = current.location + current.length
            guard end < ns.length, ns.substring(with: current).hasSuffix("\n") else { storage.endEditing(); return }
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            let movedLength = swapParagraphs(current, next)
            storage.endEditing()
            tv.selectedRange = NSRange(location: min(storage.length, current.location + movedLength + offset), length: 0)
        }
        changed()
    }

    func insertSeparator() {
        guard let tv = textView, let storage else { return }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacing = 6
        p.paragraphSpacingBefore = 6
        var line = RT.attributes(.body)
        line[.foregroundColor] = RT.mutedText
        line[.paragraphStyle] = p
        let body = RT.attributes(.body, design: RT.design(of: tv.typingAttributes))
        let r = tv.selectedRange
        let ns = storage.string as NSString
        let out = NSMutableAttributedString()
        if r.location > 0 && ns.character(at: r.location - 1) != 10 {
            out.append(NSAttributedString(string: "\n", attributes: body))
        }
        out.append(NSAttributedString(string: String(repeating: "─", count: 18), attributes: line))
        out.append(NSAttributedString(string: "\n", attributes: body))
        storage.replaceCharacters(in: r, with: out)
        tv.selectedRange = NSRange(location: r.location + out.length, length: 0)
        tv.typingAttributes = body
        changed()
    }

    func dismissKeyboard() { textView?.resignFirstResponder() }
}

// MARK: - UITextView în SwiftUI

struct RichTextView: UIViewRepresentable {
    let initial: NSAttributedString
    let controller: EditorController
    let focusOnAppear: Bool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.attributedText = initial
        tv.typingAttributes = initial.length > 0
            ? sanitized(initial.attributes(at: max(0, initial.length - 1), effectiveRange: nil))
            : RT.attributes(.title)
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 120, right: 14)
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.allowsEditingTextAttributes = true
        tv.tintColor = RT.accent
        tv.keyboardAppearance = .dark
        tv.autocorrectionType = .default
        tv.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)

        let host = UIHostingController(rootView: FormatBar(controller: controller))
        host.view.backgroundColor = UIColor(hexString: "0A1621")
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 52)
        host.view.autoresizingMask = [.flexibleWidth]
        context.coordinator.accessoryHost = host
        tv.inputAccessoryView = host.view

        controller.textView = tv
        controller.refreshState()
        if focusOnAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { tv.becomeFirstResponder() }
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    private func sanitized(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = attrs
        a.removeValue(forKey: .attachment)
        a.removeValue(forKey: .guwCheckbox)
        if a[.font] == nil { return RT.attributes(.body) }
        return a
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let controller: EditorController
        var accessoryHost: UIHostingController<FormatBar>?

        init(controller: EditorController) { self.controller = controller }

        func textViewDidChange(_ textView: UITextView) {
            MainActor.assumeIsolated { controller.changed() }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            var typing = textView.typingAttributes
            if typing[.attachment] != nil || typing[.guwCheckbox] != nil {
                typing.removeValue(forKey: .attachment)
                typing.removeValue(forKey: .guwCheckbox)
                textView.typingAttributes = typing
            }
            MainActor.assumeIsolated { controller.refreshState() }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            return MainActor.assumeIsolated { controller.handleReturn(in: range) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let point = g.location(in: tv)
            guard let position = tv.closestPosition(to: point) else { return }
            let offset = tv.offset(from: tv.beginningOfDocument, to: position)
            for index in [offset, offset - 1] {
                guard RT.isCheckbox(tv.textStorage, at: index) != nil,
                      let start = tv.position(from: tv.beginningOfDocument, offset: index),
                      let end = tv.position(from: start, offset: 1),
                      let range = tv.textRange(from: start, to: end) else { continue }
                let rect = tv.firstRect(for: range).insetBy(dx: -10, dy: -8)
                if rect.contains(point) {
                    MainActor.assumeIsolated { controller.toggleCheckbox(at: index) }
                    return
                }
            }
        }
    }
}

// MARK: - Bara de formatare de deasupra tastaturii

struct FormatBar: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(ParaStyle.allCases) { s in
                        Button { controller.apply(s) } label: {
                            if controller.style == s { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                } label: {
                    Text(controller.style.short)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(minWidth: 40, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.surfaceHi))
                }

                barButton("bold", on: controller.isBold) { controller.toggleBold() }
                barButton("italic", on: controller.isItalic) { controller.toggleItalic() }
                barButton("underline", on: controller.isUnderline) { controller.toggleUnderline() }
                barButton("strikethrough", on: controller.isStrike) { controller.toggleStrike() }

                divider

                barButton("checklist") { controller.toggleList(.check) }
                barButton("list.bullet") { controller.toggleList(.bullet) }
                barButton("list.number") { controller.toggleList(.number) }

                divider

                Menu {
                    Button { controller.setColor(nil) } label: { Label("Implicit", systemImage: "circle.slash") }
                    ForEach(Brand.palette, id: \.hex) { item in
                        Button { controller.setColor(item.hex) } label: {
                            Label { Text(item.name) } icon: { Image(uiImage: Swatch.image(item.hex)) }
                        }
                    }
                } label: { barIcon("paintpalette.fill", tint: Brand.accent) }

                Menu {
                    Button { controller.setHighlight(nil) } label: { Label("Fără evidențiere", systemImage: "circle.slash") }
                    ForEach(Brand.palette, id: \.hex) { item in
                        Button { controller.setHighlight(item.hex) } label: {
                            Label { Text(item.name) } icon: { Image(uiImage: Swatch.image(item.hex)) }
                        }
                    }
                } label: { barIcon("highlighter") }

                Menu {
                    Section("Font") {
                        ForEach(FontDesign.allCases) { d in
                            Button(d.label) { controller.setDesign(d) }
                        }
                    }
                    Section("Mărime") {
                        Button { controller.changeSize(by: 2) } label: { Label("Mărește", systemImage: "plus") }
                        Button { controller.changeSize(by: -2) } label: { Label("Micșorează", systemImage: "minus") }
                    }
                } label: { barIcon("textformat.size") }

                Menu {
                    Section("Paragraf") {
                        Button { controller.joinLines() } label: { Label("Unește rândurile", systemImage: "arrow.right.to.line") }
                        Button { controller.cleanUp() } label: { Label("Curăță textul", systemImage: "wand.and.stars") }
                        Button { controller.moveParagraph(up: true) } label: { Label("Mută paragraful sus", systemImage: "arrow.up") }
                        Button { controller.moveParagraph(up: false) } label: { Label("Mută paragraful jos", systemImage: "arrow.down") }
                    }
                    Section("Aliniere") {
                        Button { controller.align(.left) } label: { Label("Stânga", systemImage: "text.alignleft") }
                        Button { controller.align(.center) } label: { Label("Centru", systemImage: "text.aligncenter") }
                        Button { controller.align(.right) } label: { Label("Dreapta", systemImage: "text.alignright") }
                        Button { controller.align(.justified) } label: { Label("Justificat", systemImage: "text.justify") }
                    }
                    Section("Indentare") {
                        Button { controller.indent(24) } label: { Label("Mărește indentarea", systemImage: "increase.indent") }
                        Button { controller.indent(-24) } label: { Label("Micșorează indentarea", systemImage: "decrease.indent") }
                    }
                    Button { controller.insertSeparator() } label: { Label("Separator", systemImage: "minus") }
                } label: { barIcon("text.alignleft") }

                divider

                Menu {
                    Button { controller.showPhotoPicker = true } label: { Label("Poză din galerie", systemImage: "photo") }
                    Button { controller.showScanner = true } label: { Label("Scanează document → text", systemImage: "doc.viewfinder") }
                    if controller.canCaptureText {
                        Button { controller.captureTextFromCamera() } label: { Label("Text din cameră (Live Text)", systemImage: "text.viewfinder") }
                    }
                } label: { barIcon("camera.fill") }

                barButton("keyboard.chevron.compact.down") { controller.dismissKeyboard() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .foregroundStyle(Brand.text)
        .background(Brand.surface)
    }

    private var divider: some View {
        Rectangle().fill(Brand.line).frame(width: 1, height: 24).padding(.horizontal, 3)
    }

    private func barIcon(_ name: String, tint: Color = Brand.text, on: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(on ? Brand.background : tint)
            .frame(width: 38, height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Brand.accent : Color.clear))
    }

    private func barButton(_ name: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(name, on: on) }.buttonStyle(.plain)
    }
}

enum Swatch {
    static func image(_ hex: String, size: CGFloat = 20) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            UIColor(hexString: hex).setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Scanare document + extragere text (Vision, local pe telefon)

struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            for i in 0..<scan.pageCount { pages.append(scan.imageOfPage(at: i)) }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}

struct OCRBlock: Identifiable {
    enum Kind { case heading, paragraph, bullet, line, unclear }
    let id = UUID()
    let kind: Kind
    var text: String
    /// Pentru rândurile nesigure: decupajul din poza originală.
    var image: UIImage? = nil
}

/// Ce facem cu rândurile citite nesigur.
enum UnclearMode: String, CaseIterable, Identifiable {
    case image, marked, skip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: return "Imaginea rândului"
        case .marked: return "Text ghicit, marcat"
        case .skip: return "Omite"
        }
    }
}

enum OCR {
    struct Line {
        let text: String
        let box: CGRect   // coordonate normalizate Vision (origine jos-stânga)
        var confidence: Float = 1
        var crop: UIImage? = nil
        func isUnclear(_ threshold: Float) -> Bool { confidence < threshold }
    }

    /// Cât de strict marcăm rândurile citite nesigur.
    enum Sensitivity: String, CaseIterable, Identifiable {
        case strict, normal, relaxed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .strict: return "Strict"
            case .normal: return "Normal"
            case .relaxed: return "Relaxat"
            }
        }
        var threshold: Float {
            switch self {
            case .strict: return 0.99
            case .normal: return 0.75
            case .relaxed: return 0.4
            }
        }
    }

    /// Cuvinte tehnice care ajută corectura automată.
    static let vocabulary = [
        "commit", "commit-uri", "merge", "README", "README.md", "GitHub", "PR", "FAQ", "CLS", "header",
        "footer", "layout", "load", "deploy", "branch", "rebase", "push", "pull", "docs", "design",
        "foundation", "desktop", "touch", "rail", "sticky", "tile", "prod", "dev", "server", "API",
        "Supabase", "Next.js", "React", "Vercel", "endpoint", "bug", "fix", "release", "staging"
    ]

    /// Decupează rândul din pagină, cu puțină margine.
    static func crop(_ cg: CGImage, _ box: CGRect) -> UIImage? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        rect = rect.insetBy(dx: -rect.height * 0.25, dy: -rect.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width > 4, rect.height > 4, let piece = cg.cropping(to: rect.integral) else { return nil }
        return UIImage(cgImage: piece)
    }

    /// Recunoaște rândurile de pe fiecare pagină; rulează în afara firului principal.
    static func recognizeLines(_ images: [UIImage]) async -> [[Line]] {
        await Task.detached(priority: .userInitiated) {
            var pages: [[Line]] = []
            for image in images {
                guard let cg = image.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.customWords = OCR.vocabulary
                let supported = (try? request.supportedRecognitionLanguages()) ?? []
                let wanted = ["ro-RO", "en-US"].filter { supported.contains($0) }
                if wanted.isEmpty {
                    request.automaticallyDetectsLanguage = true
                } else {
                    request.recognitionLanguages = wanted
                }
                let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
                try? handler.perform([request])
                let lines: [Line] = (request.results ?? []).compactMap { obs in
                    guard let best = obs.topCandidates(1).first else { return nil }
                    var line = Line(text: best.string, box: obs.boundingBox)
                    line.confidence = best.confidence
                    if best.confidence < 1 { line.crop = OCR.crop(cg, obs.boundingBox) }
                    return line
                }
                pages.append(lines)
            }
            return pages
        }.value
    }

    /// Transformă rândurile în blocuri. `smart` recompune paragrafele; altfel păstrează rândurile.
    static func blocks(from pages: [[Line]], smart: Bool, threshold: Float = 0.75) -> [OCRBlock] {
        var out: [OCRBlock] = []
        for page in pages {
            let lines = page.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !smart {
                out += lines.map {
                    $0.isUnclear(threshold)
                        ? OCRBlock(kind: .unclear, text: $0.text, image: $0.crop)
                        : OCRBlock(kind: .line, text: $0.text.trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            let heights = lines.map { $0.box.height }.sorted()
            let median = heights.isEmpty ? 0.02 : heights[heights.count / 2]
            let maxWidth = lines.map { $0.box.width }.max() ?? 1

            var current = ""
            var previous: Line?
            var lastBulletX: CGFloat?

            func flush() {
                if !current.isEmpty { out.append(OCRBlock(kind: .paragraph, text: current)) }
                current = ""
            }

            for line in lines {
                let t = line.text.trimmingCharacters(in: .whitespaces)
                let gap = previous.map { $0.box.minY - line.box.maxY } ?? 0

                // Rând citit nesigur: separat, cu imaginea originală
                if line.isUnclear(threshold) {
                    flush()
                    out.append(OCRBlock(kind: .unclear, text: t, image: line.crop))
                    previous = line
                    lastBulletX = nil
                    continue
                }
                // Titlu: rând vizibil mai mare decât restul
                if line.box.height > median * 1.35 && t.count < 80 {
                    flush()
                    out.append(OCRBlock(kind: .heading, text: t))
                    previous = line
                    lastBulletX = nil
                    continue
                }
                // Element de listă
                if let item = bulletContent(t) {
                    flush()
                    out.append(OCRBlock(kind: .bullet, text: item))
                    previous = line
                    lastBulletX = line.box.minX
                    continue
                }
                // Continuarea unui element de listă (rând indentat, apropiat)
                if let bx = lastBulletX, current.isEmpty, gap < median * 0.9,
                   line.box.minX > bx + 0.01, let last = out.indices.last, out[last].kind == .bullet {
                    out[last].text = join(out[last].text, t)
                    previous = line
                    continue
                }
                lastBulletX = nil

                var newParagraph = current.isEmpty
                if let p = previous, !current.isEmpty {
                    if gap > median * 0.9 { newParagraph = true }
                    let ended = p.text.hasSuffix(".") || p.text.hasSuffix(":") || p.text.hasSuffix("!") || p.text.hasSuffix("?")
                    if ended && p.box.width < maxWidth * 0.7 { newParagraph = true }
                    if line.box.minX > p.box.minX + 0.05 { newParagraph = true }   // primul rând indentat
                }
                if numbered(t) { newParagraph = true }

                if newParagraph {
                    flush()
                    current = t
                } else {
                    current = join(current, t)
                }
                previous = line
            }
            flush()
        }
        return out
    }

    /// Lipește două bucăți de text, refăcând cuvintele despărțite cu cratimă.
    static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-"), let first = b.first, first.isLowercase {
            return String(a.dropLast()) + b
        }
        return a + " " + b
    }

    static func bulletContent(_ t: String) -> String? {
        // Puncte de listă: pot fi lipite de text („•Data”)
        if let first = t.first, "•·▪◦○□☐●".contains(first) {
            let rest = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        // Liniuțe / steluțe: doar urmate de spațiu, ca să nu prindem „-5” sau „*args”
        for marker in ["- ", "* ", "– ", "— "] where t.hasPrefix(marker) {
            return String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func numbered(_ t: String) -> Bool {
        t.range(of: #"^\d{1,2}[.)] "#, options: .regularExpression) != nil
    }
}

// MARK: - Previzualizare scanare

struct ScanReviewSheet: View {
    let pages: [UIImage]
    let onInsert: ([OCRBlock], Bool, UnclearMode) -> Void
    @Environment(\.dismiss) var dismiss
    @State var lines: [[OCR.Line]]? = nil
    @State var smart = true
    @State var includeImages = false
    @State var unclearMode: UnclearMode = .image
    @State var sensitivity: OCR.Sensitivity = .normal

    var blocks: [OCRBlock] { OCR.blocks(from: lines ?? [], smart: smart, threshold: sensitivity.threshold) }
    var unclearCount: Int { (lines ?? []).joined().filter { $0.isUnclear(sensitivity.threshold) }.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mod", selection: $smart) {
                    Text("Paragrafe").tag(true)
                    Text("Rânduri ca pe hârtie").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 16)

                HStack {
                    Text("Marchează rândurile nesigure:").font(.caption).foregroundStyle(Brand.muted)
                    Picker("Sensibilitate", selection: $sensitivity) {
                        ForEach(OCR.Sensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(16)

                if unclearCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(unclearCount == 1 ? "1 rând nu a putut fi citit sigur"
                                                : "\(unclearCount) rânduri nu au putut fi citite sigur",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(hex: 0xFF9F43))
                        Picker("Rânduri nesigure", selection: $unclearMode) {
                            ForEach(UnclearMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFF9F43, opacity: 0.12)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                if lines == nil {
                    Spacer()
                    ProgressView("Extrag textul…")
                    Spacer()
                } else if blocks.isEmpty {
                    Spacer()
                    Text("Nu am găsit text pe pagină.").foregroundStyle(Brand.muted)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: smart ? 10 : 2) {
                            ForEach(blocks) { b in
                                switch b.kind {
                                case .heading:
                                    Text(b.text).font(.title3.bold()).foregroundStyle(Brand.text)
                                case .bullet:
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(Brand.accent)
                                        Text(b.text).foregroundStyle(Brand.text)
                                    }
                                case .paragraph, .line:
                                    Text(b.text).foregroundStyle(Brand.text)
                                case .unclear:
                                    if unclearMode != .skip {
                                        VStack(alignment: .leading, spacing: 4) {
                                            if unclearMode == .image, let img = b.image {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(maxHeight: 60, alignment: .leading)
                                            }
                                            Label(b.text.isEmpty ? "necitit" : b.text,
                                                  systemImage: "exclamationmark.triangle.fill")
                                                .font(.caption)
                                                .foregroundStyle(Color(hex: 0xFF9F43))
                                        }
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(hex: 0xFF9F43, opacity: 0.7), lineWidth: 1))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
                        .padding(.horizontal, 16)
                    }
                }

                Toggle("Adaugă și pozele paginilor", isOn: $includeImages)
                    .padding(16)
            }
            .background(Brand.background)
            .navigationTitle("Text scanat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Inserează") {
                        onInsert(blocks, includeImages, unclearMode)
                        dismiss()
                    }
                    .bold()
                    .disabled(lines == nil)
                }
            }
            .task {
                if lines == nil { lines = await OCR.recognizeLines(pages) }
            }
        }
    }
}
