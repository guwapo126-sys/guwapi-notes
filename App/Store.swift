import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

enum SortMode: String, CaseIterable, Identifiable {
    case manual, updated, title, status
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: return "Ordinea mea"
        case .updated: return "Ultima modificare"
        case .title: return "Titlu"
        case .status: return "Grupat pe status"
        }
    }
    var icon: String {
        switch self {
        case .manual: return "hand.draw"
        case .updated: return "clock"
        case .title: return "textformat.abc"
        case .status: return "square.stack.3d.up"
        }
    }
}

struct CustomTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// Sursa unică de adevăr pentru foldere, note și șabloane.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var notes: [NoteMeta] = []
    @Published private(set) var customTemplates: [CustomTemplate] = []
    @Published private(set) var tagDefs: [TagDef] = []
    /// Propunerile lui Claude care așteaptă „Acceptă / Respinge”.
    @Published private(set) var proposals: [Proposal] = []
    private var resolvedProposals: [String] = []
    private var codeCounters: [String: Int] = [:]

    /// Apelat după fiecare schimbare locală salvată (sincronizarea se programează de aici).
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    init() {
        let lib = LibraryFile.load()
        folders = lib.folders
        notes = lib.notes
        codeCounters = lib.codeCounters ?? [:]
        let proposalFile = ProposalFile.load()
        proposals = proposalFile.pending
        resolvedProposals = proposalFile.resolved
        var needsSave = false
        if let tags = lib.tags {
            tagDefs = tags
        } else {
            // Prima pornire cu etichete separate: etichetele implicite + curățarea celor vechi din #text
            tagDefs = TagDef.defaults
            for i in notes.indices where !notes[i].tags.isEmpty { notes[i].tags = [] }
            needsSave = true
        }
        // Etichete implicite adăugate ulterior (o singură dată, dacă lipsesc)
        let addedKey = "tags.added.decizieClient"
        if !UserDefaults.standard.bool(forKey: addedKey) {
            UserDefaults.standard.set(true, forKey: addedKey)
            if !tagDefs.contains(where: { $0.name == "Decizie client" }) {
                tagDefs.append(TagDef(name: "Decizie client", emoji: "🚨", colorHex: "FF5A5F"))
                needsSave = true
            }
        }
        if migrateTagsV07() { needsSave = true }
        loadTemplates()
        migrateLegacyIfNeeded()
        if needsSave { persist() }
    }

    /// 0.7: eticheta „În lucru” devine status; apar etichetele Bug și Securitate.
    private func migrateTagsV07() -> Bool {
        let key = "tags.migrated.v07"
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(true, forKey: key)
        var changed = false

        if let working = tagDefs.first(where: { $0.name == "În lucru" }) {
            for i in notes.indices where notes[i].tagIDs.contains(working.id) {
                notes[i].tagIDs.removeAll { $0 == working.id }
                if notes[i].status == nil { notes[i].status = .progress }
            }
            tagDefs.removeAll { $0.id == working.id }
            changed = true
        }
        let additions = [TagDef(name: "Bug", emoji: "🐛", colorHex: "A3E635"),
                         TagDef(name: "Securitate", emoji: "🔒", colorHex: "59E0EF")]
        for tag in additions where !tagDefs.contains(where: { $0.name == tag.name }) {
            // Înaintea lui „Jale”, dacă există, ca lista să rămână ordonată
            if let jale = tagDefs.firstIndex(where: { $0.name == "Jale" }) {
                tagDefs.insert(tag, at: jale)
            } else {
                tagDefs.append(tag)
            }
            changed = true
        }
        return changed
    }

    // MARK: Interogări

    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func note(_ id: UUID) -> NoteMeta? { notes.first { $0.id == id } }

    func subfolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func notes(in folderID: UUID?) -> [NoteMeta] {
        Self.sorted(notes.filter { $0.folderID == folderID }, mode: sortMode(for: folderID))
    }

    func sortMode(for folderID: UUID?) -> SortMode {
        let raw = folderID == nil
            ? UserDefaults.standard.string(forKey: "rootSortMode")
            : folder(folderID)?.sortMode
        // Implicit: grupat pe status — intri în proiect și vezi imediat ce a rămas
        return SortMode(rawValue: raw ?? "") ?? .status
    }

    func setSortMode(_ mode: SortMode, for folderID: UUID?) {
        if let folderID, var f = folder(folderID) {
            f.sortMode = mode.rawValue
            updateFolder(f)
        } else {
            UserDefaults.standard.set(mode.rawValue, forKey: "rootSortMode")
            objectWillChange.send()
        }
    }

    /// Salvează ordinea aleasă de utilizator. Folderul trece pe „Ordinea mea”,
    /// cu excepția modului grupat pe status, unde ordinea se aplică în interiorul fiecărui grup.
    func setManualOrder(_ ids: [UUID], for folderID: UUID?) {
        for (i, id) in ids.enumerated() {
            if let idx = notes.firstIndex(where: { $0.id == id }) { notes[idx].sortIndex = Double(i) }
        }
        if sortMode(for: folderID) == .status {
            persist()
            return
        }
        if let folderID, var f = folder(folderID) {
            f.sortMode = SortMode.manual.rawValue
            if let i = folders.firstIndex(where: { $0.id == folderID }) { folders[i] = f }
        } else {
            UserDefaults.standard.set(SortMode.manual.rawValue, forKey: "rootSortMode")
        }
        persist()
    }

    /// Mută o notă cu o poziție mai sus / mai jos în folderul ei (trece folderul pe „Ordinea mea”).
    func moveNote(_ id: UUID, up: Bool) {
        guard let n = note(id) else { return }
        var order = notes(in: n.folderID).filter { $0.pinned == n.pinned }.map(\.id)
        guard let i = order.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
        let others = notes(in: n.folderID).filter { $0.pinned != n.pinned }.map(\.id)
        setManualOrder(n.pinned ? order + others : others + order, for: n.folderID)
    }

    /// Drag & drop: pune nota trasă lângă nota țintă (după ea dacă vine de sus, înainte dacă vine de jos).
    func moveNote(_ id: UUID, onto target: UUID) {
        guard id != target, let dragged = note(id), let goal = note(target),
              dragged.folderID == goal.folderID else { return }
        var order = notes(in: dragged.folderID).map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        let targetIndex = order.firstIndex(of: target) ?? to
        order.insert(id, at: from < to ? targetIndex + 1 : targetIndex)
        // Nota preia starea de „fixată” a zonei în care a fost lăsată
        if dragged.pinned != goal.pinned, let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].pinned = goal.pinned
        }
        // În modul grupat pe status, lăsată în alt grup, nota preia statusul grupului
        if sortMode(for: dragged.folderID) == .status, dragged.status != goal.status,
           let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].status = goal.status
            if goal.status == .done {
                var n = notes[i]
                handleDone(&n)
                notes[i] = n
            }
        }
        setManualOrder(order, for: dragged.folderID)
    }

    func setStatus(_ id: UUID, _ status: NoteStatus?) {
        guard var n = note(id) else { return }
        let wasDone = n.status == .done
        n.status = status
        if status == .done && !wasDone { handleDone(&n) }
        update(n)
    }

    // MARK: „Gata” și etichetele

    /// Bara de jos după ce o notă trece pe Gata: oferă ștergerea etichetelor sau anularea ei.
    struct DoneNotice: Identifiable, Equatable {
        enum Kind { case offerClear, cleared }
        let id = UUID()
        let noteID: UUID
        let tagIDs: [UUID]
        let kind: Kind
    }

    @Published var doneNotice: DoneNotice?

    /// Ce face aplicația cu etichetele când o notă devine Gata (setat din Setări).
    enum DoneTagMode: String, CaseIterable, Identifiable {
        case ask, clear, keep
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: return "Întreabă"
            case .clear: return "Șterge automat"
            case .keep: return "Păstrează"
            }
        }
    }

    static let doneTagModeKey = "done.tagMode"

    static var doneTagMode: DoneTagMode {
        DoneTagMode(rawValue: UserDefaults.standard.string(forKey: doneTagModeKey) ?? "") ?? .ask
    }

    private func handleDone(_ n: inout NoteMeta) {
        guard !n.tagIDs.isEmpty else { return }
        switch Self.doneTagMode {
        case .keep:
            return
        case .ask:
            doneNotice = DoneNotice(noteID: n.id, tagIDs: n.tagIDs, kind: .offerClear)
        case .clear:
            doneNotice = DoneNotice(noteID: n.id, tagIDs: n.tagIDs, kind: .cleared)
            n.tagIDs = []
        }
    }

    func clearTags(_ id: UUID) {
        guard var n = note(id) else { return }
        n.tagIDs = []
        update(n)
    }

    func restoreTags(_ id: UUID, _ tagIDs: [UUID]) {
        guard var n = note(id) else { return }
        n.tagIDs = tagIDs
        update(n)
    }

    var allNotes: [NoteMeta] { Self.sorted(notes) }

    func noteCount(in folderID: UUID?, recursive: Bool = true) -> Int {
        var count = notes.filter { $0.folderID == folderID }.count
        if recursive, let folderID {
            for sub in subfolders(of: folderID) { count += noteCount(in: sub.id) }
        }
        return count
    }

    /// „Client / Aplicație” — drumul complet al unui folder.
    func path(of folderID: UUID?) -> String {
        var parts: [String] = []
        var current = folder(folderID)
        var guardCount = 0
        while let f = current, guardCount < 20 {
            parts.insert(f.name, at: 0)
            current = folder(f.parentID)
            guardCount += 1
        }
        return parts.isEmpty ? "Note rapide" : parts.joined(separator: " / ")
    }

    // MARK: Etichete

    func tag(_ id: UUID) -> TagDef? { tagDefs.first { $0.id == id } }

    /// Etichetele unei note, în ordinea din listă.
    func tags(of note: NoteMeta) -> [TagDef] { tagDefs.filter { note.tagIDs.contains($0.id) } }

    func tagCount(_ id: UUID) -> Int { notes.filter { $0.tagIDs.contains(id) }.count }

    func notes(tagID: UUID) -> [NoteMeta] { Self.sorted(notes.filter { $0.tagIDs.contains(tagID) }) }

    func toggleTag(_ tagID: UUID, on noteID: UUID) {
        guard var n = note(noteID) else { return }
        if let i = n.tagIDs.firstIndex(of: tagID) { n.tagIDs.remove(at: i) } else { n.tagIDs.append(tagID) }
        update(n)
    }

    func saveTag(_ tag: TagDef) {
        if let i = tagDefs.firstIndex(where: { $0.id == tag.id }) { tagDefs[i] = tag } else { tagDefs.append(tag) }
        persist()
    }

    func deleteTag(_ id: UUID) {
        tagDefs.removeAll { $0.id == id }
        for i in notes.indices { notes[i].tagIDs.removeAll { $0 == id } }
        persist()
    }

    func moveTags(from: IndexSet, to: Int) {
        tagDefs.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func search(_ query: String) -> [NoteMeta] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Self.sorted(notes.filter { n in matches(n, q) })
    }

    private func matches(_ n: NoteMeta, _ q: String) -> Bool {
        if n.title.localizedCaseInsensitiveContains(q) || n.plain.localizedCaseInsensitiveContains(q) { return true }
        if tags(of: n).contains(where: { $0.name.localizedCaseInsensitiveContains(q) }) { return true }
        return path(of: n.folderID).localizedCaseInsensitiveContains(q)
    }

    /// Lista plată a folderelor, cu nivel de indentare, pentru selectoare.
    func flattenedFolders() -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for f in subfolders(of: parent) {
                out.append((f, depth))
                if depth < 10 { walk(f.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return out.map { (folder: $0.0, depth: $0.1) }
    }

    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        for sub in subfolders(of: id) {
            result.insert(sub.id)
            result.formUnion(descendants(of: sub.id))
        }
        return result
    }

    private static func sorted(_ list: [NoteMeta], mode: SortMode = .updated) -> [NoteMeta] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            switch mode {
            case .updated:
                return a.updated > b.updated
            case .title:
                return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            case .status:
                let ra = a.status?.rank ?? NoteStatus.unsetRank, rb = b.status?.rank ?? NoteStatus.unsetRank
                if ra != rb { return ra < rb }
                return manualOrder(a, b)
            case .manual:
                return manualOrder(a, b)
            }
        }
    }

    /// Ordinea manuală (sortIndex); notele fără poziție vin după, în ordinea creării.
    private static func manualOrder(_ a: NoteMeta, _ b: NoteMeta) -> Bool {
        switch (a.sortIndex, b.sortIndex) {
        case let (x?, y?): return x == y ? a.created < b.created : x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.created < b.created
        }
    }

    // MARK: Note

    @discardableResult
    func createNote(in folderID: UUID?, body: NSAttributedString? = nil, colorHex: String? = nil) -> UUID {
        var meta = NoteMeta(folderID: folderID)
        meta.colorHex = colorHex
        if sortMode(for: folderID) == .manual {
            let last = notes.filter { $0.folderID == folderID }.compactMap(\.sortIndex).max() ?? -1
            meta.sortIndex = last + 1
        }
        notes.insert(meta, at: 0)
        if let body {
            saveBody(meta.id, body)
        } else {
            persist()
        }
        meta = notes.first { $0.id == meta.id } ?? meta
        return meta.id
    }

    func loadBody(_ id: UUID) -> NSMutableAttributedString {
        guard let data = try? Data(contentsOf: LibraryFile.bodyURL(id)),
              let text = RT.decode(data) else {
            return NSMutableAttributedString(string: "", attributes: RT.attributes(.title))
        }
        return text
    }

    func saveBody(_ id: UUID, _ text: NSAttributedString) {
        if let data = RT.encode(text) {
            try? data.write(to: LibraryFile.bodyURL(id), options: .atomic)
        }
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let info = RT.summary(of: text)
        notes[i].title = info.title
        notes[i].preview = info.preview
        notes[i].plain = info.plain
        notes[i].updated = Date()
        persist()
    }

    func isEmptyBody(_ text: NSAttributedString) -> Bool {
        RT.summary(of: text).plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !RT.containsImages(text)
    }

    func update(_ meta: NoteMeta) {
        guard let i = notes.firstIndex(where: { $0.id == meta.id }) else { return }
        notes[i] = meta
        Reminders.schedule(meta)
        persist()
    }

    func togglePin(_ id: UUID) {
        guard var n = note(id) else { return }
        n.pinned.toggle()
        update(n)
    }

    func setColor(_ id: UUID, _ hex: String?) {
        guard var n = note(id) else { return }
        n.colorHex = hex
        update(n)
    }

    func move(_ id: UUID, to folderID: UUID?) {
        guard var n = note(id) else { return }
        n.folderID = folderID
        update(n)
    }

    func duplicate(_ id: UUID) {
        guard let original = note(id) else { return }
        let body = loadBody(id)
        let newID = createNote(in: original.folderID, body: body, colorHex: original.colorHex)
        if var copy = note(newID) {
            copy.title = original.title + " (copie)"
            update(copy)
        }
    }

    func deleteNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: LibraryFile.bodyURL(id))
        Reminders.cancel(id)
        persist()
    }

    // MARK: Foldere

    @discardableResult
    func createFolder(name: String, parent: UUID?, colorHex: String, icon: String,
                      access: ClaudeAccess? = nil, hideTitles: Bool? = nil, projectRepo: String? = nil) -> UUID {
        var f = Folder(name: name.isEmpty ? "Folder nou" : name, parentID: parent, colorHex: colorHex, icon: icon)
        // Folderele de pe primul nivel primesc nivelul implicit din Setări; subfolderele moștenesc
        f.access = access ?? (parent == nil ? Self.defaultAccess : nil)
        f.hideTitles = hideTitles
        f.projectRepo = projectRepo
        folders.append(f)
        persist()
        return f.id
    }

    // MARK: Acces Claude

    static let defaultAccessKey = "claude.defaultAccess"

    /// Nivelul pentru folderele noi de pe primul nivel (implicit: Privat).
    static var defaultAccess: ClaudeAccess {
        ClaudeAccess(rawValue: UserDefaults.standard.string(forKey: defaultAccessKey) ?? "") ?? .privat
    }

    /// Nivelul efectiv: setarea folderului sau, dacă lipsește, a celui mai apropiat părinte.
    /// „Note rapide” (fără folder) rămân mereu private.
    func effectiveAccess(_ folderID: UUID?) -> ClaudeAccess {
        var current = folder(folderID)
        var depth = 0
        while let f = current, depth < 20 {
            if let a = f.access { return a }
            current = folder(f.parentID)
            depth += 1
        }
        return .privat
    }

    func effectiveHideTitles(_ folderID: UUID?) -> Bool {
        var current = folder(folderID)
        var depth = 0
        while let f = current, depth < 20 {
            if let h = f.hideTitles { return h }
            current = folder(f.parentID)
            depth += 1
        }
        return false
    }

    /// Folderul are setarea lui proprie (nu o moștenește).
    func hasOwnAccess(_ folderID: UUID) -> Bool { folder(folderID)?.access != nil }

    func setAccess(_ access: ClaudeAccess?, for folderID: UUID) {
        guard var f = folder(folderID) else { return }
        f.access = access
        updateFolder(f)
    }

    // MARK: Coduri scurte (GIC-12)

    /// Prefixul codului: inițialele folderului („Dezvoltare Website Ventures” → DWV) sau primele litere („GIC”).
    private func codePrefix(for folderID: UUID?) -> String {
        guard let name = folder(folderID)?.name else { return "N" }
        let words = name.folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let raw: String
        if words.count >= 2 {
            raw = words.prefix(4).compactMap(\.first).map(String.init).joined()
        } else {
            raw = String((words.first ?? "N").prefix(4))
        }
        let prefix = raw.uppercased()
        return prefix.isEmpty ? "N" : prefix
    }

    /// Codul notei; se atribuie o singură dată și nu se mai schimbă.
    @discardableResult
    func ensureCode(_ id: UUID) -> String {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return "N-0" }
        if let code = notes[i].code { return code }
        let prefix = codePrefix(for: notes[i].folderID)
        let next = (codeCounters[prefix] ?? 0) + 1
        codeCounters[prefix] = next
        let code = "\(prefix)-\(next)"
        notes[i].code = code
        return code
    }

    // MARK: Schimbări venite din sincronizare

    /// Aplică statusul / etichetele venite din repo, fără să declanșeze o nouă sincronizare.
    func applyRemote(_ id: UUID, status: NoteStatus?, tagIDs: [UUID], summary: String, by author: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].status = status
        notes[i].tagIDs = tagIDs
        notes[i].externalChange = summary
        notes[i].externalChangeAt = Date()
        notes[i].externalChangeBy = author
        applyingRemote = true
        persist()
        applyingRemote = false
    }

    // MARK: Propunerile lui Claude

    func proposals(for noteID: UUID) -> [Proposal] { proposals.filter { $0.noteID == noteID } }

    /// Adaugă propuneri noi (fără dubluri și fără cele deja rezolvate). Întoarce câte s-au adăugat.
    @discardableResult
    func addProposals(_ incoming: [Proposal]) -> Int {
        var known = Set(proposals.map(\.fingerprint)).union(resolvedProposals)
        var added = 0
        for p in incoming where !known.contains(p.fingerprint) {
            proposals.append(p)
            known.insert(p.fingerprint)
            added += 1
        }
        if added > 0 { saveProposals() }
        return added
    }

    func rejectProposal(_ id: UUID) {
        guard let p = proposals.first(where: { $0.id == id }) else { return }
        resolve(p)
    }

    /// Aplică propunerea în notă. Întoarce un mesaj dacă n-a reușit (propunerea rămâne, marcată).
    @discardableResult
    func acceptProposal(_ id: UUID) -> String? {
        guard let p = proposals.first(where: { $0.id == id }) else { return nil }
        switch p.kind {
        case .update, .check, .newStep:
            guard let noteID = p.noteID, note(noteID) != nil else {
                return markFailed(p, "Nota nu mai există.")
            }
            let body = loadBody(noteID)
            switch p.kind {
            case .update:
                RT.appendUpdate(to: body, text: p.text, evidence: p.evidence, author: p.author, date: p.createdAt)
            case .newStep:
                RT.appendStep(to: body, text: p.text)
            default:
                guard RT.checkStep(in: body, matching: p.text) else {
                    return markFailed(p, "Nu am găsit pasul „\(p.text)” nebifat în notă. Respinge-l sau bifează-l manual.")
                }
            }
            saveBody(noteID, body)
        case .newNote:
            let folderID = p.folderID ?? p.noteID.flatMap { note($0)?.folderID }
            let body = NSMutableAttributedString(string: p.text, attributes: RT.attributes(.title))
            if p.reason != nil || p.evidence != nil {
                var muted = RT.attributes(.body)
                muted[.foregroundColor] = RT.mutedText
                muted[.guwColor] = "7F98A3"
                let reasonLine: String? = p.reason.map { (r: String) -> String in "Motiv: \(r)" }
                let evidenceLine: String? = p.evidence.map { (e: String) -> String in "Dovadă: \(e)" }
                let lines: [String] = [reasonLine, evidenceLine].compactMap { $0 }
                body.append(NSAttributedString(string: "\nPropusă de \(p.author). " + lines.joined(separator: " · "), attributes: muted))
            }
            let newID = createNote(in: folderID, body: body)
            if var created = note(newID) {
                created.status = .todo
                update(created)
            }
        }
        resolve(p)
        return nil
    }

    private func markFailed(_ p: Proposal, _ message: String) -> String {
        if let i = proposals.firstIndex(where: { $0.id == p.id }) {
            proposals[i].failure = message
            saveProposals()
        }
        return message
    }

    private func resolve(_ p: Proposal) {
        proposals.removeAll { $0.id == p.id }
        resolvedProposals.append(p.fingerprint)
        if resolvedProposals.count > 400 { resolvedProposals.removeFirst(resolvedProposals.count - 400) }
        saveProposals()
    }

    private func saveProposals() {
        ProposalFile(pending: proposals, resolved: resolvedProposals).save()
    }

    /// Salvează fără să programeze sincronizarea (ex. coduri atribuite în timpul sincronizării).
    func persistQuietly() {
        applyingRemote = true
        persist()
        applyingRemote = false
    }

    /// Găsește o etichetă după nume, ignorând majuscule, diacritice și emoji.
    func tagID(named raw: String) -> UUID? {
        let key = Self.normalize(raw)
        return tagDefs.first { Self.normalize($0.name) == key }?.id
    }

    /// `nonisolated`: folosit și din BoardFormat (în afara MainActor).
    nonisolated static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    func updateFolder(_ folder: Folder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i] = folder
        persist()
    }

    /// Șterge folderul și subfolderele; notele lor se mută în folderul părinte.
    func deleteFolder(_ id: UUID) {
        guard let f = folder(id) else { return }
        let removed = descendants(of: id).union([id])
        for i in notes.indices where notes[i].folderID.map({ removed.contains($0) }) == true {
            notes[i].folderID = f.parentID
        }
        folders.removeAll { removed.contains($0.id) }
        persist()
    }

    // MARK: Șabloane personale

    func saveTemplate(name: String, body: NSAttributedString) {
        let t = CustomTemplate(name: name.isEmpty ? "Șablon" : name)
        if let data = RT.encode(body) {
            try? data.write(to: LibraryFile.templatesDirectory.appendingPathComponent("\(t.id.uuidString).note"))
        }
        customTemplates.append(t)
        saveTemplateIndex()
    }

    func templateBody(_ t: CustomTemplate) -> NSAttributedString {
        let url = LibraryFile.templatesDirectory.appendingPathComponent("\(t.id.uuidString).note")
        guard let data = try? Data(contentsOf: url), let s = RT.decode(data) else { return NSAttributedString() }
        return s
    }

    func deleteTemplate(_ t: CustomTemplate) {
        customTemplates.removeAll { $0.id == t.id }
        try? FileManager.default.removeItem(at: LibraryFile.templatesDirectory.appendingPathComponent("\(t.id.uuidString).note"))
        saveTemplateIndex()
    }

    private var templateIndexURL: URL { LibraryFile.templatesDirectory.appendingPathComponent("index.json") }

    private func loadTemplates() {
        guard let data = try? Data(contentsOf: templateIndexURL),
              let list = try? JSONDecoder().decode([CustomTemplate].self, from: data) else { return }
        customTemplates = list
    }

    private func saveTemplateIndex() {
        if let data = try? JSONEncoder().encode(customTemplates) {
            try? data.write(to: templateIndexURL, options: .atomic)
        }
    }

    // MARK: Persistență

    private func persist() {
        LibraryFile.save(Library(folders: folders, notes: notes, tags: tagDefs, codeCounters: codeCounters))
        if !applyingRemote { onLocalChange?() }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Mută notele din build-ul de test (notes.json) în noul format.
    private func migrateLegacyIfNeeded() {
        struct LegacyNote: Codable {
            var id: UUID
            var title: String
            var body: String
            var client: String
            var pinned: Bool
            var reminder: Date?
            var updated: Date
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: LibraryFile.url.path),
              let data = try? Data(contentsOf: LibraryFile.legacyURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let legacy = try? dec.decode([LegacyNote].self, from: data), !legacy.isEmpty else { return }

        var folderByClient: [String: UUID] = [:]
        for old in legacy {
            var folderID: UUID? = nil
            let client = old.client.trimmingCharacters(in: .whitespaces)
            if !client.isEmpty {
                if let existing = folderByClient[client] {
                    folderID = existing
                } else {
                    let f = Folder(name: client, parentID: nil, colorHex: "59E0EF", icon: "briefcase.fill")
                    folders.append(f)
                    folderByClient[client] = f.id
                    folderID = f.id
                }
            }
            var meta = NoteMeta(folderID: folderID)
            meta.id = old.id
            meta.pinned = old.pinned
            meta.reminder = old.reminder
            notes.append(meta)
            let body = NSMutableAttributedString(string: old.title.isEmpty ? "Notă" : old.title,
                                                 attributes: RT.attributes(.title))
            if !old.body.isEmpty {
                body.append(NSAttributedString(string: "\n" + old.body, attributes: RT.attributes(.body)))
            }
            saveBody(meta.id, body)
            if let i = notes.firstIndex(where: { $0.id == meta.id }) { notes[i].updated = old.updated }
        }
        persist()
        try? fm.removeItem(at: LibraryFile.legacyURL)
    }
}

// MARK: - Remindere (notificări locale)

enum Reminders {
    static func requestAuth() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func schedule(_ note: NoteMeta) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [note.id.uuidString])
        guard let date = note.reminder, date > Date() else { return }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: note.id.uuidString,
                                         content: content(title: note.displayTitle, body: note.preview, id: note.id),
                                         trigger: trigger))
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    /// Notificări înainte să expire instalarea: cu o zi și cu 3 ore înainte. Se reprogramează la fiecare pornire.
    static func scheduleExpiryWarnings() {
        let center = UNUserNotificationCenter.current()
        let ids = ["guwapi.expiry.24h", "guwapi.expiry.3h"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard let expiry = InstallExpiry.date else { return }
        let plan: [(String, TimeInterval, String)] = [
            (ids[0], 24 * 3600, "Aplicația expiră mâine"),
            (ids[1], 3 * 3600, "Aplicația expiră în 3 ore")
        ]
        for (id, before, title) in plan {
            let fire = expiry.addingTimeInterval(-before)
            guard fire > Date() else { continue }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = "Deschide SideStore → My Apps → Refresh All. Notițele rămân neschimbate."
            c.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
        }
    }

    static func test() {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "guwapi.test",
                                  content: content(title: "Test guwapi", body: "Notificările funcționează.", id: nil),
                                  trigger: trigger))
    }

    private static func content(title: String, body: String, id: UUID?) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = String(body.prefix(160))
        c.sound = .default
        if let id { c.userInfo = ["noteID": id.uuidString] }
        return c
    }
}
