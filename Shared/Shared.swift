import Foundation
import Security
import SwiftUI
import UIKit

// MARK: - Brand guwapi (paleta din iconița aplicației), adaptivă: luminos / întunecat

/// Construiește culori care se schimbă singure după modul iPhone-ului (sau alegerea din aplicație).
enum Adaptive {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static func pair(dark: UInt32, light: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }

    /// O culoare vie (galben, cyan, lime…) ușor de citit pe alb: o închidem până are contrast suficient.
    static func lightVariant(_ hex: UInt32) -> UInt32 {
        var r = CGFloat((hex >> 16) & 0xFF) / 255
        var g = CGFloat((hex >> 8) & 0xFF) / 255
        var b = CGFloat(hex & 0xFF) / 255
        func luminance() -> CGFloat {
            func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        // Contrast ~3:1 față de alb => luminanță ≤ 0.30
        var steps = 0
        while luminance() > 0.30 && steps < 20 {
            r *= 0.92; g *= 0.92; b *= 0.92
            steps += 1
        }
        return (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(b * 255)
    }

    /// Culoarea pentru un hex ales de utilizator (note, foldere, etichete, text colorat).
    static func ui(_ hex: UInt32) -> UIColor {
        if hex == 0xE6F4F7 { return Brand.textUI }     // „Alb” = culoarea textului: neagră pe fundal deschis
        return pair(dark: hex, light: lightVariant(hex))
    }

    static func parse(_ hexString: String?) -> UInt32? {
        UInt32((hexString ?? "").replacingOccurrences(of: "#", with: ""), radix: 16)
    }
}

enum Brand {
    static let backgroundUI = Adaptive.pair(dark: 0x020813, light: 0xF3F6F8)
    static let surfaceUI    = Adaptive.pair(dark: 0x0A1621, light: 0xFFFFFF)
    static let surfaceHiUI  = Adaptive.pair(dark: 0x10202D, light: 0xEAF0F3)
    static let lineUI       = Adaptive.pair(dark: 0x173041, light: 0xD7E1E6)
    static let textUI       = Adaptive.pair(dark: 0xE6F4F7, light: 0x0B1A24)
    static let mutedUI      = Adaptive.pair(dark: 0x7F98A3, light: 0x5B707C)
    static let accentUI     = Adaptive.pair(dark: 0x59E0EF, light: 0x0A8796)

    static let background = Color(uiColor: backgroundUI)
    static let surface    = Color(uiColor: surfaceUI)
    static let surfaceHi  = Color(uiColor: surfaceHiUI)
    static let line       = Color(uiColor: lineUI)
    static let text       = Color(uiColor: textUI)
    static let muted      = Color(uiColor: mutedUI)
    static let accent     = Color(uiColor: accentUI)
    static let teal       = Color(uiColor: Adaptive.pair(dark: 0x018190, light: 0x017A88))

    /// Culori disponibile pentru note, foldere și text.
    static let palette: [(name: String, hex: String)] = [
        ("Cyan", "59E0EF"), ("Teal", "018190"), ("Albastru", "4C8DFF"), ("Violet", "8B7CFF"),
        ("Roz", "FF6FB5"), ("Roșu", "FF5A5F"), ("Portocaliu", "FF9F43"), ("Galben", "FFD166"),
        ("Verde", "3DDC97"), ("Lime", "A3E635"), ("Text", "E6F4F7"), ("Gri", "7F98A3")
    ]
}

/// Aspectul aplicației: urmează iPhone-ul sau e fixat.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    static let storageKey = "appearance"

    var label: String {
        switch self {
        case .system: return "Sistem"
        case .light: return "Luminos"
        case .dark: return "Întunecat"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension Color {
    /// Culoare fixă (aceeași în ambele moduri).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Culoare aleasă de utilizator sau de status/etichetă: adaptivă, lizibilă pe ambele fundaluri.
    init(hexString: String?, fallback: UInt32 = 0x59E0EF) {
        self.init(uiColor: Adaptive.ui(Adaptive.parse(hexString) ?? fallback))
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
    /// Ce poate vedea Claude în acest folder. nil = moștenește de la folderul părinte.
    var access: ClaudeAccess? = nil
    /// La nivelul „Status”: Claude vede coduri (GIC-12) în loc de titluri. nil = moștenește.
    var hideTitles: Bool? = nil

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
        access = try? c.decodeIfPresent(ClaudeAccess.self, forKey: .access)
        hideTitles = try c.decodeIfPresent(Bool.self, forKey: .hideTitles)
    }
}

/// Nivelul de acces al lui Claude la un folder.
enum ClaudeAccess: String, Codable, CaseIterable, Identifiable {
    case privat = "private"
    case status
    var id: String { rawValue }

    var label: String {
        switch self {
        case .privat: return "Privat"
        case .status: return "Status"
        }
    }

    var icon: String {
        switch self {
        case .privat: return "lock.fill"
        case .status: return "tag.fill"
        }
    }

    var explanation: String {
        switch self {
        case .privat: return "Nimic nu pleacă de pe telefon."
        case .status: return "Claude vede titlul, statusul și etichetele. Conținutul rămâne pe telefon."
        }
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
    /// Cod scurt și stabil (ex. GIC-12), folosit în sincronizare.
    var code: String? = nil
    /// Ultima schimbare venită din afară (Claude / calculator), ex. „În lucru → De verificat”.
    var externalChange: String? = nil
    var externalChangeAt: Date? = nil
    var externalChangeBy: String? = nil

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
        code = try c.decodeIfPresent(String.self, forKey: .code)
        externalChange = try c.decodeIfPresent(String.self, forKey: .externalChange)
        externalChangeAt = try c.decodeIfPresent(Date.self, forKey: .externalChangeAt)
        externalChangeBy = try c.decodeIfPresent(String.self, forKey: .externalChangeBy)
    }

    /// Schimbare externă recentă (ultimele 3 zile), pentru insigna de pe rând / card.
    var recentExternalChange: Bool {
        guard let at = externalChangeAt else { return false }
        return Date().timeIntervalSince(at) < 3 * 24 * 3600
    }

    var displayTitle: String { title.isEmpty ? "Fără titlu" : title }
}

struct Library: Codable {
    var folders: [Folder] = []
    var notes: [NoteMeta] = []
    var tags: [TagDef]? = nil
    /// Ultimul număr folosit pentru fiecare prefix de cod (GIC → 34).
    var codeCounters: [String: Int]? = nil

    init(folders: [Folder] = [], notes: [NoteMeta] = [], tags: [TagDef]? = nil, codeCounters: [String: Int]? = nil) {
        self.folders = folders
        self.notes = notes
        self.tags = tags
        self.codeCounters = codeCounters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        notes = try c.decodeIfPresent([NoteMeta].self, forKey: .notes) ?? []
        tags = try c.decodeIfPresent([TagDef].self, forKey: .tags)
        codeCounters = try c.decodeIfPresent([String: Int].self, forKey: .codeCounters)
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
