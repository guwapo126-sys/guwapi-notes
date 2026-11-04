import Foundation
import Security
import SwiftUI

// MARK: - Brand (guwapi.com: fundal #07090B)

enum Brand {
    static let background = Color(hex: 0x07090B)
    static let surface    = Color(hex: 0x12161A)
    static let line       = Color(hex: 0x1F252B)
    static let text       = Color(hex: 0xE8ECEF)
    static let muted      = Color(hex: 0x8A949E)
    /// Culoare de accent — înlocuiește cu hex-ul exact din logo-ul guwapi.
    static let accent     = Color(hex: 0x4C8DFF)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Model

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = ""
    var body: String = ""
    var client: String = ""
    var pinned: Bool = false
    var reminder: Date? = nil
    var updated: Date = Date()
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

// MARK: - Stocare (JSON în containerul comun app + widget)

enum NoteFile {
    static var url: URL {
        let dir = AppGroup.containerURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("notes.json")
    }

    static func load() -> [Note] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Note].self, from: data)) ?? []
    }

    static func save(_ notes: [Note]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(notes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
