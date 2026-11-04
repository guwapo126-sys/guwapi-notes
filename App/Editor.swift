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

enum OCR {
    /// Recunoaște textul de pe pagini; rulează în afara firului principal.
    static func recognize(_ images: [UIImage]) async -> String {
        await Task.detached(priority: .userInitiated) {
            var pages: [String] = []
            for image in images {
                guard let cg = image.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                pages.append(lines.joined(separator: "\n"))
            }
            return pages.joined(separator: "\n\n")
        }.value
    }
}
