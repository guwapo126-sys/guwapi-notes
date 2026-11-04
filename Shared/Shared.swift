import Foundation
import Security
import SwiftUI

// MARK: - Brand guwapi (paleta din iconița aplicației)

enum Brand {
    static let background = Color(hex: 0x020813)
    static let surface    = Color(hex: 0x0A1621)
    static let surfaceHi  = Color(hex: 0x10202D)
    static let line       = Color(hex: 0x173041)
    static let text       = Color(hex: 0xE6F4F7)
    static let muted      = Color(hex: 0x7F98A3)
    static let accent     = Color(hex: 0x59E0EF)
    static let teal       = Color(hex: 0x018190)

    /// Culori disponibile pentru note, foldere și text.
    static let palette: [(name: String, hex: String)] = [
        ("Cyan", "59E0EF"), ("Teal", "018190"), ("Albastru", "4C8DFF"), ("Violet", "8B7CFF"),
        ("Roz", "FF6FB5"), ("Roșu", "FF5A5F"), ("Portocaliu", "FF9F43"), ("Galben", "FFD166"),
        ("Verde", "3DDC97"), ("Lime", "A3E635"), ("Alb", "E6F4F7"), ("Gri", "7F98A3")
    ]
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    init(hexString: String?, fallback: UInt32 = 0x59E0EF) {
        let clean = (hexString ?? "").replacingOccurrences(of: "#", with: "")
        self.init(hex: UInt32(clean, radix: 16) ?? fallback)
    }
}

// MARK: - Model

/// Statusul unei note: unde se află în fluxul de lucru. O notă are cel mult unul.
enum NoteStatus: String, CaseIterable, Codable, Identifiable {
    // Ordinea de aici = ordinea din meniuri și filtre (fluxul de lucru)
    case todo, progress, review, problem, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return "De făcut"
        case .progress: return "În lucru"
        case .review: return "De verificat"
        case .problem: return "Problemă"
        case .done: return "Gata"
        }
    }

    var icon: String {
        switch self {
        case .todo: return "circle.dashed"
        case .progress: return "clock.fill"
        case .review: return "eye.circle.fill"
        case .problem: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    var hex: String {
        switch self {
        case .todo: return "9AA5B1"
        case .progress: return "FFD166"
        case .review: return "8B7CFF"
        case .problem: return "FF5A5F"
        case .done: return "3DDC97"
        }
    }

    var color: Color { Color(hexString: hex) }

    /// Ordinea pe ecranul de proiect: ce cere atenție vine primul, ce e gata la final.
    var rank: Int {
        switch self {
        case .problem: return 0
        case .progress: return 1
        case .review: return 2
        case .todo: return 3
        case .done: return 5
        }
    }

    /// Rangul unei note fără status (între „De făcut” și „Gata”).
    static let unsetRank = 4

    /// Statusurile care încă înseamnă muncă rămasă.
    var isOpen: Bool { self != .done }

    /// Pasul următor la glisare / atingere rapidă.
    var next: NoteStatus {
        switch self {
        case .todo: return .progress
        case .progress: return .review
        case .review: return .done
        case .problem: return .progress
        case .done: return .done
        }
    }
}

struct TagDef: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var colorHex: String

    init(name: String, emoji: String, colorHex: String) {
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Etichetă"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🏷️"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "59E0EF"
    }

    var color: Color { Color(hexString: colorHex) }

    static var defaults: [TagDef] {
        [TagDef(name: "Urgent", emoji: "🔥", colorHex: "FF6B3D"),
         TagDef(name: "Decizie client", emoji: "🚨", colorHex: "FF5A5F"),
         TagDef(name: "Idee", emoji: "💡", colorHex: "FFD166"),
         TagDef(name: "De discutat", emoji: "💬", colorHex: "4C8DFF"),
         TagDef(name: "Bug", emoji: "🐛", colorHex: "A3E635"),
         TagDef(name: "Securitate", emoji: "🔒", colorHex: "59E0EF"),
         TagDef(name: "Jale", emoji: "💀", colorHex: "9AA5B1")]
    }
}

struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "Folder nou"
    var parentID: UUID? = nil
    var colorHex: String = "59E0EF"
    var icon: String = "folder.fill"
    var created = Date()
    /// Modul de sortare al notelor din folder (vezi SortMode în aplicație).
    var sortMode: String? = nil

    init(name: String = "Folder nou", parentID: UUID? = nil, colorHex: String = "59E0EF", icon: String = "folder.fill") {
        self.name = name
        self.parentID = parentID
        self.colorHex = colorHex
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Folder"
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "59E0EF"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder.fill"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        sortMode = try c.decodeIfPresent(String.self, forKey: .sortMode)
    }
}

struct NoteMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var folderID: UUID? = nil
    var title: String = ""
    var preview: String = ""
    var plain: String = ""
    var colorHex: String? = nil
    var pinned: Bool = false
    var tags: [String] = []
    var reminder: Date? = nil
    var created = Date()
    var updated = Date()
    var status: NoteStatus? = nil
    /// Etichetele notei (id-uri din Library.tags).
    var tagIDs: [UUID] = []
    /// Poziția în ordinea manuală a folderului.
    var sortIndex: Double? = nil

    init(folderID: UUID? = nil) {
        self.folderID = folderID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        plain = try c.decodeIfPresent(String.self, forKey: .plain) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        reminder = try c.decodeIfPresent(Date.self, forKey: .reminder)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
        status = try? c.decodeIfPresent(NoteStatus.self, forKey: .status)
        tagIDs = try c.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        sortIndex = try c.decodeIfPresent(Double.self, forKey: .sortIndex)
    }

    var displayTitle: String { title.isEmpty ? "Fără titlu" : title }
}

struct Library: Codable {
    var folders: [Folder] = []
    var notes: [NoteMeta] = []
    var tags: [TagDef]? = nil

    init(folders: [Folder] = [], notes: [NoteMeta] = [], tags: [TagDef]? = nil) {
        self.folders = folders
        self.notes = notes
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        notes = try c.decodeIfPresent([NoteMeta].self, forKey: .notes) ?? []
        tags = try c.decodeIfPresent([TagDef].self, forKey: .tags)
    }
}

// MARK: - App Group
// Programele de sideload (SideStore/iloader) redenumesc App Group-ul cu sufixul echipei.
// De aceea îl citim din profilul de instalare, cu variante de rezervă.

enum AppGroup {
    static let baseID = "group.com.guwapi.notes"

    static let resolvedID: String? = {
        for id in candidates() where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil {
            return id
        }
        return nil
    }()

    static var containerURL: URL? {
        guard let id = resolvedID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static func candidates() -> [String] {
        var ids = profileGroups()
        ids.append(baseID)
        var bundle = Bundle.main.bundleIdentifier ?? ""
        if bundle.hasSuffix(".widget") { bundle.removeLast(".widget".count) }
        if let team = teamID() {
            ids.append("\(baseID).\(team)")
            ids.append("group.\(bundle).\(team)")
        }
        ids.append("group.\(bundle)")
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func profileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return [] }
        let xml = Data(data[start.lowerBound..<end.upperBound])
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    static func teamID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "guwapi.teamid",
            kSecAttrService as String: "guwapi",
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String
        else { return nil }
        return group.components(separatedBy: ".").first
    }
}

// MARK: - Fișiere (comune app + widget)

enum LibraryFile {
    static var directory: URL {
        AppGroup.containerURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var url: URL { directory.appendingPathComponent("library.json") }
    /// Fișierul din build-ul de test, folosit doar pentru migrare.
    static var legacyURL: URL { directory.appendingPathComponent("notes.json") }

    static var bodiesDirectory: URL { subdirectory("bodies") }
    static var templatesDirectory: URL { subdirectory("templates") }

    static func bodyURL(_ id: UUID) -> URL {
        bodiesDirectory.appendingPathComponent("\(id.uuidString).note")
    }

    static func load() -> Library {
        guard let data = try? Data(contentsOf: url) else { return Library() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Library.self, from: data)) ?? Library()
    }

    static func save(_ library: Library) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(library) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func subdirectory(_ name: String) -> URL {
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

// MARK: - Semnal de viață al widgetului (citit de Diagnostic)

enum WidgetHeartbeat {
    private static var url: URL { LibraryFile.directory.appendingPathComponent("widget-heartbeat.json") }

    /// Widgetul notează când și-a refăcut ultima dată conținutul.
    static func record(_ kind: String) {
        var beats = read()
        beats[kind] = Date()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(beats) { try? data.write(to: url, options: .atomic) }
    }

    static func read() -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: Date].self, from: data)) ?? [:]
    }

    static var latest: Date? { read().values.max() }
}

/// Starea legăturii app ↔ widget: verde / galben / roșu.
enum WidgetLink {
    case healthy(Date)
    case waiting
    case broken

    static var current: WidgetLink {
        guard AppGroup.resolvedID != nil else { return .broken }
        if let last = WidgetHeartbeat.latest, Date().timeIntervalSince(last) < 6 * 3600 { return .healthy(last) }
        return .waiting
    }

    var color: Color {
        switch self {
        case .healthy: return Color(hexString: "3DDC97")
        case .waiting: return Color(hexString: "FFD166")
        case .broken: return Color(hexString: "FF5A5F")
        }
    }

    var title: String {
        switch self {
        case .healthy: return "Widgetul e conectat"
        case .waiting: return "Conectat, dar widgetul nu a raportat încă"
        case .broken: return "Widgetul nu poate citi notele"
        }
    }

    var icon: String {
        switch self {
        case .healthy: return "checkmark.seal.fill"
        case .waiting: return "hourglass"
        case .broken: return "xmark.octagon.fill"
        }
    }
}
