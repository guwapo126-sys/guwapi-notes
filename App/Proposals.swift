import SwiftUI
import UIKit

// MARK: - Model

/// Ce propune Claude. Actualizările și notele noi cer nivelul „Status + jurnal”;
/// bifele și pașii noi cer „Complet” (Claude trebuie să vadă checklistul).
enum ProposalKind: String, Codable, CaseIterable, Identifiable {
    case update, check, newStep, newNote
    var id: String { rawValue }

    var label: String {
        switch self {
        case .update: return "Actualizare"
        case .check: return "Bifă"
        case .newStep: return "Pas nou"
        case .newNote: return "Notă nouă"
        }
    }

    var icon: String {
        switch self {
        case .update: return "text.badge.checkmark"
        case .check: return "checkmark.circle.fill"
        case .newStep: return "plus.circle"
        case .newNote: return "doc.badge.plus"
        }
    }

    var hex: String {
        switch self {
        case .update: return "59E0EF"
        case .check: return "3DDC97"
        case .newStep, .newNote: return "8B7CFF"
        }
    }

    var color: Color { Color(hexString: hex) }

    /// Follow-up = sugestie de muncă rămasă, nu ceva deja făcut.
    var isFollowUp: Bool { self == .newStep || self == .newNote }

    /// Nivelul minim de acces la care propunerea e permisă.
    func allowed(at access: ClaudeAccess) -> Bool {
        switch self {
        case .update, .newNote: return access.allowsUpdates
        case .check, .newStep: return access.syncsContent
        }
    }

    /// Din textul scris de Claude: „actualizare”, „bifa”, „pas-nou”, „nota-noua”…
    static func from(_ raw: String) -> ProposalKind? {
        switch LibraryStore.normalize(raw) {
        case "actualizare", "update", "jurnal", "facut": return .update
        case "bifa", "check", "bifeaza": return .check
        case "pasnou", "newstep", "pas", "followup": return .newStep
        case "notanoua", "newnote", "nota": return .newNote
        default: return nil
        }
    }
}

struct Proposal: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ProposalKind
    /// Nota la care se referă (nil = propunere la nivel de proiect, ex. notă nouă).
    var noteID: UUID?
    var folderID: UUID?
    /// Textul actualizării / pasul / titlul notei noi.
    var text: String
    var evidence: String?
    var reason: String?
    var author: String
    var createdAt = Date()
    /// Dacă acceptarea n-a reușit (ex. pasul nu există în notă).
    var failure: String?

    var fingerprint: String {
        let target = noteID?.uuidString ?? folderID?.uuidString ?? "-"
        return [target, kind.rawValue, LibraryStore.normalize(text), evidence ?? ""].joined(separator: "|")
    }

    /// Primul link din dovadă, ca să fie apăsabil.
    var evidenceURL: URL? {
        guard let evidence,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: evidence, range: NSRange(location: 0, length: (evidence as NSString).length))
        else { return nil }
        return match.url
    }
}

// MARK: - Citirea propunerilor din fișierele din repo

/// Propunere brută, așa cum a scris-o Claude în secțiunea „## Propuneri”.
struct RawProposal {
    var kind: ProposalKind
    var text: String
    var evidence: String?
    var reason: String?
}

enum ProposalParser {
    /// Formatul (în orice fișier de notă sau `_proiect.md`):
    ///
    ///     ## Propuneri
    ///     - tip: actualizare
    ///       text: Migrarea la schema nouă e gata.
    ///       dovada: commit 8f92b80
    static func parse(_ document: String) -> [RawProposal] {
        let lines = document.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { isProposalHeading($0) }) else { return [] }

        var items: [[String: String]] = []
        var current: [String: String]?
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") { break }
            if trimmed.isEmpty || trimmed.hasPrefix("<!--") || trimmed.hasPrefix(">") { continue }
            var body = trimmed
            if body.hasPrefix("- ") || body.hasPrefix("* ") {
                if let item = current { items.append(item) }
                current = [:]
                body = String(body.dropFirst(2))
            }
            guard current != nil, let colon = body.firstIndex(of: ":") else { continue }
            let key = LibraryStore.normalize(String(body[..<colon]))
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            current?[key] = value
        }
        if let item = current { items.append(item) }

        return items.compactMap { fields in
            guard let kind = fields["tip"].flatMap(ProposalKind.from) ?? fields["type"].flatMap(ProposalKind.from) else { return nil }
            let text: String?
            switch kind {
            case .update: text = fields["text"] ?? fields["facut"] ?? fields["ce"]
            case .check, .newStep: text = fields["pas"] ?? fields["step"] ?? fields["text"]
            case .newNote: text = fields["titlu"] ?? fields["title"] ?? fields["text"]
            }
            guard let text, !text.isEmpty else { return nil }
            let evidence = fields["dovada"] ?? fields["evidence"] ?? fields["sursa"]
            let reason = fields["motiv"] ?? fields["reason"] ?? fields["dece"]
            return RawProposal(kind: kind, text: text, evidence: evidence, reason: reason)
        }
    }

    private static func isProposalHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("## ") else { return false }
        return LibraryStore.normalize(String(t.dropFirst(3))) == "propuneri"
    }
}

// MARK: - Aplicarea în textul notei

extension RT {
    /// „4 nov 2026 · Claude — text”, cu dovada dedesubt.
    static func appendUpdate(to body: NSMutableAttributedString, text: String, evidence: String?, author: String, date: Date) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ro_RO")
        f.dateFormat = "d MMM yyyy"
        newline(body)
        body.append(NSAttributedString(string: "Actualizare · \(f.string(from: date)) · \(author)", attributes: attributes(.h3)))
        body.append(NSAttributedString(string: "\n" + text, attributes: attributes(.body)))
        if let evidence, !evidence.isEmpty {
            var muted = attributes(.body)
            muted[.font] = font(style: .body, design: .standard, bold: false, italic: false, size: 14)
            muted[.foregroundColor] = mutedText
            muted[.guwColor] = "7F98A3"
            let line = NSMutableAttributedString(string: "\nDovadă: \(evidence)", attributes: muted)
            if let url = Proposal(kind: .update, text: "", evidence: evidence, author: "").evidenceURL {
                let range = (line.string as NSString).range(of: url.absoluteString)
                if range.location != NSNotFound { line.addAttribute(.link, value: url, range: range) }
            }
            body.append(line)
        }
    }

    /// Adaugă un pas nebifat la finalul notei.
    static func appendStep(to body: NSMutableAttributedString, text: String) {
        var attrs = attributes(.body)
        attrs[.paragraphStyle] = paragraphStyle(.body, list: true)
        newline(body)
        body.append(checkbox(false, base: attrs))
        body.append(NSAttributedString(string: " " + text, attributes: attrs))
    }

    /// Bifează pasul care se potrivește cu textul (întâi potrivire exactă, apoi parțială).
    @discardableResult
    static func checkStep(in body: NSMutableAttributedString, matching text: String) -> Bool {
        let wanted = LibraryStore.normalize(text)
        guard !wanted.isEmpty else { return false }
        let ns = body.string as NSString
        var exact: NSRange?
        var partial: NSRange?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, stop in
            guard range.length > 1, isCheckbox(body, at: range.location) == false else { return }
            let rest = ns.substring(with: NSRange(location: range.location + 1, length: range.length - 1))
            let key = LibraryStore.normalize(rest)
            if key == wanted { exact = range; stop.pointee = true }
            else if partial == nil, key.count > 3, key.contains(wanted) || wanted.contains(key) { partial = range }
        }
        guard let range = exact ?? partial else { return false }
        let attrs = body.attributes(at: range.location, effectiveRange: nil)
        body.replaceCharacters(in: NSRange(location: range.location, length: 1), with: checkbox(true, base: attrs))
        let textRange = NSRange(location: range.location + 1, length: range.length - 1)
        body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
        body.addAttribute(.foregroundColor, value: mutedText, range: textRange)
        return true
    }

    private static func newline(_ body: NSMutableAttributedString) {
        if body.length > 0 && !body.string.hasSuffix("\n") {
            body.append(NSAttributedString(string: "\n", attributes: attributes(.body)))
        }
    }
}

// MARK: - Fișierul cu propuneri (local)

struct ProposalFile: Codable {
    var pending: [Proposal] = []
    /// Amprentele propunerilor deja acceptate / respinse, ca să nu reapară.
    var resolved: [String] = []

    private static var url: URL { LibraryFile.directory.appendingPathComponent("proposals.json") }

    static func load() -> ProposalFile {
        guard let data = try? Data(contentsOf: url) else { return ProposalFile() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(ProposalFile.self, from: data)) ?? ProposalFile()
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

// MARK: - Ecranul „Claude propune”

struct ProposalsScreen: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// nil = toate propunerile; altfel doar pentru o notă.
    let noteID: UUID?
    var showsDoneButton = false
    @State var confirmAll = false

    private var items: [Proposal] {
        store.proposals.filter { noteID == nil || $0.noteID == noteID }
    }

    private struct ProposalGroup: Identifiable {
        let id: String
        let title: String
        let items: [Proposal]
    }

    private var groups: [ProposalGroup] {
        var order: [String] = []
        var map: [String: [Proposal]] = [:]
        var titles: [String: String] = [:]
        for p in items {
            let folderKey: String = "folder-" + (p.folderID?.uuidString ?? "-")
            let key: String = p.noteID?.uuidString ?? folderKey
            if map[key] == nil {
                order.append(key)
                let noteTitle: String? = p.noteID.flatMap { store.note($0)?.displayTitle }
                let folderTitle: String = "Notă nouă · " + store.path(of: p.folderID)
                titles[key] = noteTitle ?? folderTitle
            }
            map[key, default: []].append(p)
        }
        return order.map { ProposalGroup(id: $0, title: titles[$0] ?? $0, items: map[$0] ?? []) }
    }

    var body: some View {
        List {
            if items.isEmpty {
                EmptyState(text: "Nicio propunere de la Claude. Când lucrezi cu el la un proiect, propunerile apar aici.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { p in row(p) }
                } header: {
                    sectionHeader(group.title)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.background)
        .navigationTitle("Claude propune")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("Accepți toate cele \(items.count) propuneri?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Acceptă tot") { acceptAll() }
        } message: {
            Text("Actualizările se adaugă la finalul notelor, bifele se aplică, follow-up-urile devin pași sau note noi.")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if showsDoneButton {
            ToolbarItem(placement: .cancellationAction) { Button("Gata") { dismiss() } }
        }
        ToolbarItem(placement: .confirmationAction) {
            if items.count > 1 {
                Button("Acceptă tot") { confirmAll = true }.bold()
            }
        }
    }

    private func row(_ p: Proposal) -> some View {
        ProposalCard(proposal: p,
                     onAccept: { accept(p) },
                     onReject: { reject(p) },
                     onOpen: openNote(p))
            .listRowBackground(Brand.surface)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { accept(p) } label: { Label("Acceptă", systemImage: "checkmark") }
                    .tint(NoteStatus.done.color)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { reject(p) } label: { Label("Respinge", systemImage: "xmark") }
            }
    }

    private func openNote(_ p: Proposal) -> (() -> Void)? {
        guard noteID == nil, let id = p.noteID, store.note(id) != nil else { return nil }
        return { router.open(id) }
    }

    private func animate(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.2)) { change() } }
    }

    private func accept(_ p: Proposal) {
        var failure: String?
        animate { failure = store.acceptProposal(p.id) }
        UINotificationFeedbackGenerator().notificationOccurred(failure == nil ? .success : .error)
    }

    private func reject(_ p: Proposal) {
        animate { store.rejectProposal(p.id) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func acceptAll() {
        let ids = items.map(\.id)
        animate { for id in ids { _ = store.acceptProposal(id) } }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct ProposalCard: View {
    let proposal: Proposal
    let onAccept: () -> Void
    let onReject: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(proposal.text)
                .font(.body)
                .foregroundStyle(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
            details
            if let failure = proposal.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(NoteStatus.problem.color)
            }
            buttons
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(proposal.kind.label, systemImage: proposal.kind.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(proposal.kind.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(proposal.kind.color.opacity(0.16)))
            if proposal.kind.isFollowUp {
                Text("SUGESTIE")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Text("\(proposal.author) · \(proposal.createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(Brand.muted)
        }
    }

    @ViewBuilder private var details: some View {
        if let evidence = proposal.evidence {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark.seal").foregroundStyle(Brand.accent)
                if let url = proposal.evidenceURL {
                    Link(evidence, destination: url).foregroundStyle(Brand.accent)
                } else {
                    Text(evidence).foregroundStyle(Brand.text.opacity(0.85))
                }
            }
            .font(.caption)
            .accessibilityLabel("Dovadă: \(evidence)")
        }
        if let reason = proposal.reason {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "lightbulb").foregroundStyle(Brand.muted)
                Text(reason).foregroundStyle(Brand.muted)
            }
            .font(.caption)
            .accessibilityLabel("Motiv: \(reason)")
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: onReject) {
                Label("Respinge", systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Brand.muted)
            Button(action: onAccept) {
                Label("Acceptă", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(NoteStatus.done.color)
            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right.square")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Deschide nota")
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

/// Cardul de pe ecranul principal: „✨ Claude propune · 5”.
struct ProposalsEntryRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.accent.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: "sparkles").foregroundStyle(Brand.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude propune").font(.headline).foregroundStyle(Brand.text)
                Text(count == 1 ? "1 propunere de verificat" : "\(count) propuneri de verificat")
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.background)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Brand.accent))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Banda din notă: „✨ Claude propune 2 schimbări”.
struct ProposalsBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text(count == 1 ? "Claude propune o schimbare" : "Claude propune \(count) schimbări")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Vezi").font(.subheadline.weight(.bold))
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
            }
            .foregroundStyle(Brand.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.accent.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}
