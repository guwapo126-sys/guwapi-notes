import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

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

    init() {
        let lib = LibraryFile.load()
        folders = lib.folders
        notes = lib.notes
        loadTemplates()
        migrateLegacyIfNeeded()
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
        Self.sorted(notes.filter { $0.folderID == folderID })
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

    var allTags: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in notes { for t in n.tags { counts[t, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { $0.tag < $1.tag }
    }

    func notes(tag: String) -> [NoteMeta] { Self.sorted(notes.filter { $0.tags.contains(tag) }) }

    func search(_ query: String) -> [NoteMeta] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Self.sorted(notes.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.plain.localizedCaseInsensitiveContains(q)
                || path(of: $0.folderID).localizedCaseInsensitiveContains(q)
        })
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

    private static func sorted(_ list: [NoteMeta]) -> [NoteMeta] {
        list.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updated > $1.updated
        }
    }

    // MARK: Note

    @discardableResult
    func createNote(in folderID: UUID?, body: NSAttributedString? = nil, colorHex: String? = nil) -> UUID {
        var meta = NoteMeta(folderID: folderID)
        meta.colorHex = colorHex
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
        notes[i].tags = info.tags
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
    func createFolder(name: String, parent: UUID?, colorHex: String, icon: String) -> UUID {
        let f = Folder(name: name.isEmpty ? "Folder nou" : name, parentID: parent, colorHex: colorHex, icon: icon)
        folders.append(f)
        persist()
        return f.id
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
        LibraryFile.save(Library(folders: folders, notes: notes))
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
