import CryptoKit
import Foundation
import Security
import SwiftUI

// MARK: - Tokenul GitHub, criptat în Keychain

enum TokenStore {
    private static let service = "guwapi.github"
    private static let account = "board-token"

    @discardableResult
    static func save(_ token: String) -> Bool {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8)
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasToken: Bool { load() != nil }
}

// MARK: - Client GitHub (Git Data API)

struct GitHubError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? {
        switch status {
        case 401: return "Tokenul nu e valid sau a expirat."
        case 403: return "Tokenul nu are voie să scrie în repo (verifică permisiunea Contents: Read and write)."
        case 404: return "Repo-ul nu a fost găsit. Verifică numele (proprietar/repo) și că tokenul are acces la el."
        default: return "GitHub \(status): \(message)"
        }
    }
}

struct GitHubClient {
    let owner: String
    let repo: String
    let token: String

    struct Response {
        let status: Int
        let json: Any?
        var object: [String: Any] { json as? [String: Any] ?? [:] }
    }

    func send(_ method: String, _ path: String, body: Any? = nil, allow: Set<Int> = []) async throws -> Response {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)\(path)") else {
            throw GitHubError(status: 0, message: "adresă invalidă")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("guwapi-notes", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json: Any? = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data))
        if status >= 400 && !allow.contains(status) {
            let message = (json as? [String: Any])?["message"] as? String ?? "eroare"
            throw GitHubError(status: status, message: message)
        }
        return Response(status: status, json: json)
    }
}

// MARK: - Formatul fișierelor din repo

enum BoardFormat {
    static let notesDir = "proiecte"
    static let schemaPath = "_guwapi/schema.md"
    static let claudePath = "CLAUDE.md"

    static func slug(_ status: NoteStatus?) -> String {
        switch status {
        case .todo?: return "de-facut"
        case .progress?: return "in-lucru"
        case .review?: return "de-verificat"
        case .problem?: return "problema"
        case .done?: return "gata"
        case nil: return "fara-status"
        }
    }

    /// Statusul dintr-un text scris de om sau de Claude („In lucru”, „in-lucru”, „De verificat”…).
    /// `nil` = nu l-am recunoscut; `.some(nil)` = fără status.
    static func status(from raw: String) -> NoteStatus?? {
        let key = LibraryStore.normalize(raw)
        let table: [String: NoteStatus?] = [
            "defacut": .todo, "todo": .todo,
            "inlucru": .progress, "progress": .progress,
            "deverificat": .review, "review": .review, "verificat": .review,
            "problema": .problem, "problem": .problem,
            "gata": .done, "done": .done,
            "farastatus": nil, "nimic": nil, "none": nil
        ]
        guard let value = table[key] else { return nil }
        return .some(value)
    }

    struct Parsed {
        var id: UUID
        var statusRaw: String?
        var tags: [String]
    }

    static let projectFile = "_proiect.md"

    static let proposalsHint = "<!-- Claude: propunerile tale aici (format în CLAUDE.md). Aplicația le preia și golește secțiunea. -->"

    static func render(id: UUID, code: String, title: String, status: NoteStatus?, tags: [String],
                       access: ClaudeAccess, content: String?) -> String {
        let cleanTitle = title.replacingOccurrences(of: "\n", with: " ")
        let tagList = tags.map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ", ")
        var out = """
        ---
        id: \(id.uuidString)
        cod: \(code)
        status: \(slug(status))
        etichete: [\(tagList)]
        nivel: \(access.slug)
        ---
        # \(cleanTitle)

        """
        switch access {
        case .full:
            out += "> Poți schimba `status` și `etichete`. Restul doar prin propuneri, aprobate pe telefon.\n\n"
        case .journal:
            out += "> Poți schimba `status` și `etichete` și poți adăuga propuneri. Conținutul notei rămâne pe telefon.\n\n"
        default:
            out += "> Se pot schimba doar `status` și `etichete`. Conținutul notei rămâne pe telefon.\n\n"
        }
        if access.syncsContent, let content, !content.isEmpty {
            out += "## Conținut\n\n\(content)\n\n"
        }
        if access.allowsUpdates {
            out += "## Propuneri\n\n\(proposalsHint)\n"
        }
        return out
    }

    /// `_proiect.md`: legătura folder ↔ repo de cod și locul pentru propuneri de note noi.
    static func renderProject(folderID: UUID, title: String, access: ClaudeAccess, repo: String?) -> String {
        let repoLine = repo.map { "https://github.com/\($0)" } ?? "-"
        var out = """
        ---
        folder: \(folderID.uuidString)
        nivel: \(access.slug)
        repo: \(repo ?? "-")
        ---
        # \(title)

        > Proiectul acestor note. Repo de cod: \(repoLine)

        """
        if access.allowsUpdates {
            out += "## Propuneri\n\n\(proposalsHint)\n"
        }
        return out
    }

    static func parseProjectFolder(_ text: String) -> UUID? {
        for line in text.components(separatedBy: .newlines).prefix(12) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("folder:") {
                return UUID(uuidString: t.dropFirst("folder:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Conținutul notei în Markdown, fără titlul de pe primul rând (e deja în antet).
    static func contentMarkdown(_ body: NSAttributedString, title: String) -> String {
        var lines = RT.markdown(body).components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# "),
           LibraryStore.normalize(String(first.dropFirst(2))) == LibraryStore.normalize(title) {
            lines.removeFirst()
        }
        // Un „## Propuneri” din notă ar încurca citirea propunerilor
        let cleaned = lines.map { $0.hasPrefix("## Propuneri") ? "### Propuneri (din notă)" : $0 }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ text: String) -> Parsed? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var id: UUID?
        var statusRaw: String?
        var tags: [String] = []
        var inTagList = false
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if inTagList, t.hasPrefix("- ") {
                tags.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            inTagList = false
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "id":
                id = UUID(uuidString: value)
            case "status":
                statusRaw = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            case "etichete", "tags":
                if value.isEmpty {
                    inTagList = true
                } else {
                    let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    tags = inner.split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
                        .filter { !$0.isEmpty }
                }
            default:
                break
            }
        }
        guard let id else { return nil }
        return Parsed(id: id, statusRaw: statusRaw, tags: tags)
    }

    static func schema(tags: [TagDef]) -> String {
        let statusLines = NoteStatus.allCases.map { "- `\(slug($0))` — \($0.label)" }.joined(separator: "\n")
        let tagLines = tags.map { "- \($0.emoji) `\($0.name)`" }.joined(separator: "\n")
        return """
        # guwapi notes — vocabular

        Fișier generat de aplicație. Nu îl edita: se rescrie la fiecare sincronizare.

        ## Statusuri (câmpul `status`, o singură valoare)
        \(statusLines)
        - `fara-status` — fără status

        ## Etichete (câmpul `etichete`, listă; doar numele de mai jos sunt recunoscute)
        \(tagLines)

        ## Niveluri (câmpul `nivel`, setat doar din aplicație)
        - `status` — schimbi status / etichete
        - `jurnal` — + propuneri `actualizare`, `nota-noua`
        - `complet` — + propuneri `bifa`, `pas-nou` (vezi `## Conținut`)

        ## Tipuri de propuneri (sub `## Propuneri`)
        - `actualizare` — `text`, `dovada`
        - `bifa` — `pas` (textul exact din conținut), `dovada`
        - `pas-nou` — `pas`, `motiv`
        - `nota-noua` — `titlu`, `motiv` (în nota de lângă sau în `_proiect.md`)

        """
    }

    static let claudeRulesV1 = """
    # guwapi-board — reguli pentru Claude

    Acest repo oglindește notițele din aplicația **guwapi notes** (iPhone).
    Conținutul notelor NU este aici, doar titlul, statusul și etichetele.

    ## Structură
    - `proiecte/<Client>/<Proiect>/<COD>.md` — o notă (ex. `proiecte/Centry/GIC/GIC-12.md`).
    - Antetul fiecărui fișier (între `---`) are: `id`, `cod`, `status`, `etichete`.
    - `_guwapi/schema.md` — statusurile și etichetele valide. Citește-l înainte de orice schimbare.

    ## Ce ai voie să faci
    - Să schimbi `status` și `etichete` în antet, folosind doar valorile din `_guwapi/schema.md`.
    - Când consideri o notă terminată, pune `de-verificat`, NU `gata`. Utilizatorul o închide.

    ## Ce NU ai voie
    - Să ștergi, să creezi sau să redenumești fișiere.
    - Să schimbi `id`, `cod` sau titlul (se rescriu din aplicație).
    - Să adaugi conținut în note.

    ## Cum lucrezi
    1. Arată-i utilizatorului lista de schimbări propuse (cod, titlu, de la → la, motiv).
    2. Aplică doar după confirmarea lui.
    3. Commit cu un mesaj clar, ex. `GIC-12: in-lucru → de-verificat (migrarea e gata)`.
    4. Aplicația de pe telefon preia schimbările la următoarea deschidere.

    """

    static let claudeRules = """
    # guwapi-board — reguli pentru Claude

    <!-- generat de guwapi notes · v2 -->

    Acest repo oglindește notițele din aplicația **guwapi notes** (iPhone).
    Fiecare folder are un nivel ales de utilizator (`nivel:` în antet și în `_proiect.md`):

    | nivel | ce e aici | ce poți face |
    |---|---|---|
    | `status` | titlu, status, etichete | schimbi `status` / `etichete` |
    | `jurnal` | la fel | + propui actualizări („ce s-a făcut”) și note noi |
    | `complet` | + `## Conținut` (textul și checklistul notei) | + propui bife și pași noi |

    ## Structură
    - `proiecte/<Client>/<Proiect>/<COD>.md` — o notă (ex. `proiecte/Centry/GIC/GIC-12.md`).
    - `proiecte/<Client>/<Proiect>/_proiect.md` — `repo:` = repo-ul de cod al proiectului.
    - `_guwapi/schema.md` — statusurile și etichetele valide. Citește-l înainte de orice schimbare.

    ## Regula de bază: fără dovadă, nu scrii
    Orice propunere are o **dovadă scurtă, ca utilizatorul să știe unde s-o găsească**:
    - `commit 8f92b80` (cu link `https://github.com/<repo>/commit/<sha>` când știi repo-ul)
    - `PR #19`, `src/db/migrate.ts`, `test: npm test OK`
    - `conversație <dată>: „<ce a spus utilizatorul>”`
    Dacă nu ai dovadă, NU propui: întrebi utilizatorul. Nu deduce, nu inventa.

    ## Schimbări directe (doar după „da” în conversație)
    - `status:` și `etichete:` din antet, cu valori din `_guwapi/schema.md`.
    - Ceva terminat → `de-verificat`, NU `gata`. Utilizatorul închide.

    ## Propuneri (aprobate pe telefon)
    Scrie-le sub `## Propuneri` în fișierul notei (sau în `_proiect.md` pentru note noi):

    ```
    ## Propuneri
    - tip: actualizare
      text: Migrarea la schema nouă e gata.
      dovada: commit 8f92b80 https://github.com/<repo>/commit/8f92b80
    - tip: bifa
      pas: Migrare bază de date
      dovada: commit 8f92b80
    - tip: pas-nou
      pas: Backup bază de date înainte de deploy
      motiv: nota cere backup, în cod nu există
    - tip: nota-noua
      titlu: Diacritice la import
      motiv: TODO în src/import.ts:42
    ```
    - `actualizare`, `nota-noua`: nivel `jurnal` sau `complet`.
    - `bifa`, `pas-nou`: doar nivel `complet`; `pas` = textul exact al pasului din `## Conținut`.
    - `pas-nou` / `nota-noua` sunt follow-up-uri: muncă rămasă pe care ai văzut-o (în notă, în cod, în conversație).

    ## Ce NU ai voie
    - Să editezi `## Conținut`, titlul, `id`, `cod`, `nivel`.
    - Să ștergi, să creezi sau să redenumești fișiere.

    ## Cum lucrezi
    1. Rezumat scurt al proiectului (rămase / pe status).
    2. Lista de schimbări și propuneri, fiecare cu dovadă.
    3. Aplici doar după confirmare, un commit clar, push.

    """

    /// SHA-ul pe care GitHub îl dă unui fișier cu acest conținut (blob git).
    static func blobSHA(_ text: String) -> String {
        let data = Data(text.utf8)
        var header = Data("blob \(data.count)".utf8)
        header.append(0)
        header.append(data)
        return Insecure.SHA1.hash(data: header).map { String(format: "%02x", $0) }.joined()
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "Folder" : trimmed
    }
}

// MARK: - Starea sincronizării (salvată local)

struct SyncState: Codable {
    struct Fields: Codable, Equatable {
        var status: String
        var tags: [String]
    }

    struct CachedFile: Codable {
        var sha: String
        var id: String
        var statusRaw: String?
        var tags: [String]
    }

    /// Ce aveau notele la ultima sincronizare reușită (baza pentru îmbinarea în 3 părți).
    var base: [String: Fields] = [:]
    /// Fișierele din repo deja citite, după SHA (ca să nu le descărcăm din nou).
    var files: [String: CachedFile] = [:]
    var lastSync: Date?

    private static var url: URL { LibraryFile.directory.appendingPathComponent("sync-state.json") }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(SyncState.self, from: data)) ?? SyncState()
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

// MARK: - Motorul de sincronizare

@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    enum Phase: Equatable {
        case off
        case idle
        case syncing
        case ok(Date)
        case failed(String)
    }

    static let enabledKey = "sync.enabled"
    static let repoKey = "sync.repo"

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastChanges: Int = 0
    @Published private(set) var lastProposals: Int = 0
    @Published private(set) var repoIsPublic = false

    private weak var store: LibraryStore?
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var rerun = false
    private var lastAttempt: Date?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// „proprietar/repo”, curățat de spații, „;”, ghilimele sau un link lipit întreg.
    var repoSlug: String {
        var raw = UserDefaults.standard.string(forKey: Self.repoKey) ?? ""
        if let range = raw.range(of: "github.com/") { raw = String(raw[range.upperBound...]) }
        if raw.hasSuffix(".git") { raw.removeLast(4) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.split(separator: "/").prefix(2).joined(separator: "/")
    }

    private struct SyncConflict: Error {}

    func attach(_ store: LibraryStore) {
        self.store = store
        store.onLocalChange = { [weak self] in self?.schedule() }
        let state = SyncState.load()
        if enabled { phase = state.lastSync.map { .ok($0) } ?? .idle }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        phase = on ? .idle : .off
        if on { Task { await syncNow() } }
    }

    func setRepo(_ slug: String) {
        UserDefaults.standard.set(slug.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.repoKey)
    }

    /// După o schimbare locală: sincronizează peste câteva secunde (schimbările apropiate se adună).
    func schedule(after seconds: Double = 6) {
        guard enabled else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// La deschiderea aplicației: sincronizează dacă n-a mai făcut-o în ultimul minut.
    func syncIfStale() {
        guard enabled else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < 60 { return }
        Task { await syncNow() }
    }

    private func client() -> GitHubClient? {
        let parts = repoSlug.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, let token = TokenStore.load() else { return nil }
        return GitHubClient(owner: parts[0], repo: parts[1], token: token)
    }

    func syncNow() async {
        guard enabled else { phase = .off; return }
        guard let store, let client = client() else {
            phase = .failed("Completează repo-ul (proprietar/repo) și tokenul în Setări.")
            return
        }
        if running { rerun = true; return }
        running = true
        lastAttempt = Date()
        phase = .syncing
        do {
            do {
                try await perform(client, store)
            } catch is SyncConflict {
                try await perform(client, store)
            }
        } catch is SyncConflict {
            phase = .failed("Repo-ul s-a schimbat în timpul sincronizării. Încearcă din nou.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
        running = false
        if rerun {
            rerun = false
            await syncNow()
        }
    }

    /// Verifică tokenul și repo-ul, fără să schimbe nimic.
    func testConnection() async -> String {
        guard let client = client() else { return "Completează repo-ul și tokenul." }
        do {
            let info = try await client.send("GET", "")
            let isPrivate = info.object["private"] as? Bool ?? false
            repoIsPublic = !isPrivate
            return isPrivate
                ? "Conexiune OK. Repo-ul e privat. ✅"
                : "Conexiune OK, dar repo-ul e PUBLIC. Fă-l privat înainte să activezi folderele. ⚠️"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: O trecere completă: citește repo-ul, îmbină, scrie

    private func perform(_ gh: GitHubClient, _ store: LibraryStore) async throws {
        var state = SyncState.load()

        // 1. Repo și ramura principală
        let info = try await gh.send("GET", "")
        repoIsPublic = !(info.object["private"] as? Bool ?? false)
        var branch = info.object["default_branch"] as? String ?? "main"

        // 2. Repo gol: primul fișier se creează prin Contents API (Git Data API nu merge pe repo gol)
        var ref = try await gh.send("GET", "/git/ref/heads/\(branch)", allow: [404, 409])
        if ref.status != 200 {
            let body: [String: Any] = [
                "message": "guwapi: inițializare",
                "content": Data(BoardFormat.claudeRules.utf8).base64EncodedString()
            ]
            _ = try await gh.send("PUT", "/contents/\(BoardFormat.claudePath)", body: body)
            let refreshed = try await gh.send("GET", "")
            branch = refreshed.object["default_branch"] as? String ?? branch
            ref = try await gh.send("GET", "/git/ref/heads/\(branch)")
        }
        guard let head = (ref.object["object"] as? [String: Any])?["sha"] as? String else {
            throw GitHubError(status: 0, message: "ramura nu are commit")
        }

        // 3. Commit-ul curent și lista de fișiere
        let commit = try await gh.send("GET", "/git/commits/\(head)")
        guard let treeSHA = (commit.object["tree"] as? [String: Any])?["sha"] as? String else {
            throw GitHubError(status: 0, message: "commit fără tree")
        }
        let headMessage = commit.object["message"] as? String ?? ""
        let headAuthor = (commit.object["author"] as? [String: Any])?["name"] as? String ?? "PC"
        let author = headMessage.localizedCaseInsensitiveContains("claude") ? "Claude" : headAuthor

        let tree = try await gh.send("GET", "/git/trees/\(treeSHA)?recursive=1")
        var remote: [String: String] = [:]   // path -> sha
        for entry in tree.object["tree"] as? [[String: Any]] ?? [] {
            if entry["type"] as? String == "blob", let path = entry["path"] as? String, let sha = entry["sha"] as? String {
                remote[path] = sha
            }
        }

        // 4. Citim notele din repo (doar fișierele noi sau schimbate)
        var remoteNotes: [UUID: BoardFormat.Parsed] = [:]
        var newCache: [String: SyncState.CachedFile] = [:]
        var noteProposals: [(UUID, RawProposal)] = []
        var folderProposals: [(UUID, RawProposal)] = []
        for (path, sha) in remote where path.hasPrefix(BoardFormat.notesDir + "/") && path.hasSuffix(".md") {
            let isProject = path.hasSuffix("/" + BoardFormat.projectFile)
            if let cached = state.files[path], cached.sha == sha, let id = UUID(uuidString: cached.id) {
                if !isProject {
                    remoteNotes[id] = BoardFormat.Parsed(id: id, statusRaw: cached.statusRaw, tags: cached.tags)
                }
                newCache[path] = cached
                continue
            }
            let blob = try await gh.send("GET", "/git/blobs/\(sha)")
            let encoded = (blob.object["content"] as? String ?? "").replacingOccurrences(of: "\n", with: "")
            guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) else { continue }
            // Fișierul s-a schimbat de la ultima citire: poate conține propuneri noi
            let proposals = ProposalParser.parse(text)
            if isProject {
                guard let folderID = BoardFormat.parseProjectFolder(text) else { continue }
                for raw in proposals { folderProposals.append((folderID, raw)) }
                newCache[path] = SyncState.CachedFile(sha: sha, id: folderID.uuidString, statusRaw: nil, tags: [])
            } else {
                guard let parsed = BoardFormat.parse(text) else { continue }
                remoteNotes[parsed.id] = parsed
                for raw in proposals { noteProposals.append((parsed.id, raw)) }
                newCache[path] = SyncState.CachedFile(sha: sha, id: parsed.id.uuidString, statusRaw: parsed.statusRaw, tags: parsed.tags)
            }
        }

        // 5. Îmbinare în 3 părți: aplicăm din repo doar ce s-a schimbat acolo și nu și pe telefon
        let visible = store.notes.filter { store.effectiveAccess($0.folderID).syncsStatus }
        var changesFromRemote = 0
        for note in visible {
            guard let parsed = remoteNotes[note.id], let base = state.base[note.id.uuidString] else { continue }
            let local = fields(of: note, store)

            var newStatus = note.status
            var statusText: String?
            if let raw = parsed.statusRaw, let resolved = BoardFormat.status(from: raw) {
                let remoteSlug = BoardFormat.slug(resolved)
                if remoteSlug != base.status && local.status == base.status && remoteSlug != local.status {
                    newStatus = resolved
                    statusText = "\(note.status?.label ?? "Fără status") → \(resolved?.label ?? "Fără status")"
                }
            }

            var newTags = note.tagIDs
            var tagText: String?
            var seenTags = Set<UUID>()
            let remoteIDs: [UUID] = parsed.tags.compactMap { store.tagID(named: $0) }.filter { seenTags.insert($0).inserted }
            let remoteKey = tagKey(remoteIDs, store)
            if remoteKey != base.tags && local.tags == base.tags && remoteKey != local.tags {
                let added: [TagDef] = remoteIDs.filter { !note.tagIDs.contains($0) }.compactMap { store.tag($0) }
                let removed: [TagDef] = note.tagIDs.filter { !remoteIDs.contains($0) }.compactMap { store.tag($0) }
                newTags = remoteIDs
                let addedText: [String] = added.map { (t: TagDef) -> String in "+\(t.emoji) \(t.name)" }
                let removedText: [String] = removed.map { (t: TagDef) -> String in "−\(t.emoji) \(t.name)" }
                let parts: [String] = addedText + removedText
                tagText = parts.joined(separator: " · ")
            }

            if statusText != nil || tagText != nil {
                let summary = [statusText, tagText].compactMap { $0 }.joined(separator: " · ")
                store.applyRemote(note.id, status: newStatus, tagIDs: newTags, summary: summary, by: author)
                changesFromRemote += 1
            }
        }

        // 5b. Propunerile: le păstrăm doar dacă nivelul folderului le permite
        var incoming: [Proposal] = []
        for (noteID, raw) in noteProposals {
            guard let note = store.note(noteID) else { continue }
            let access = store.effectiveAccess(note.folderID)
            guard raw.kind.allowed(at: access) else { continue }
            incoming.append(Proposal(kind: raw.kind, noteID: noteID, folderID: note.folderID, text: raw.text,
                                     evidence: raw.evidence, reason: raw.reason, author: author))
        }
        for (folderID, raw) in folderProposals where raw.kind == .newNote {
            guard store.folder(folderID) != nil, raw.kind.allowed(at: store.effectiveAccess(folderID)) else { continue }
            incoming.append(Proposal(kind: .newNote, noteID: nil, folderID: folderID, text: raw.text,
                                     evidence: raw.evidence, reason: raw.reason, author: author))
        }
        let proposalsAdded = store.addProposals(incoming)

        // 6. Ce trebuie să fie în repo acum
        let folderPaths = folderPathMap(store)
        var desired: [String: String] = [:]   // path -> conținut
        var newBase: [String: SyncState.Fields] = [:]
        var codesAssigned = false
        for note in store.notes where store.effectiveAccess(note.folderID).syncsStatus {
            let hadCode = note.code != nil
            let code = store.ensureCode(note.id)
            if !hadCode { codesAssigned = true }
            guard let current = store.note(note.id) else { continue }
            let dir = current.folderID.flatMap { folderPaths[$0] } ?? "Note rapide"
            let path = "\(BoardFormat.notesDir)/\(dir)/\(code).md"
            let title = store.effectiveHideTitles(current.folderID) ? code : current.displayTitle
            let tagNames = store.tags(of: current).map(\.name)
            let access = store.effectiveAccess(current.folderID)
            let content = access.syncsContent
                ? BoardFormat.contentMarkdown(store.loadBody(current.id), title: current.displayTitle)
                : nil
            desired[path] = BoardFormat.render(id: current.id, code: code, title: title, status: current.status,
                                               tags: tagNames, access: access, content: content)
            newBase[current.id.uuidString] = fields(of: current, store)
        }
        for folder in store.folders {
            let access = store.effectiveAccess(folder.id)
            guard access.syncsStatus, let dir = folderPaths[folder.id] else { continue }
            let title = store.effectiveHideTitles(folder.id) && !access.syncsContent ? dir : store.path(of: folder.id)
            let repo = projectRepo(for: folder.id, store)
            desired["\(BoardFormat.notesDir)/\(dir)/\(BoardFormat.projectFile)"] =
                BoardFormat.renderProject(folderID: folder.id, title: title, access: access, repo: repo)
        }
        if codesAssigned { store.persistQuietly() }
        desired[BoardFormat.schemaPath] = BoardFormat.schema(tags: store.tagDefs)
        // CLAUDE.md: îl scriem dacă lipsește sau dacă e versiunea veche generată de aplicație (nu una editată de tine)
        let claudeSHA = remote[BoardFormat.claudePath]
        if claudeSHA == nil || claudeSHA == BoardFormat.blobSHA(BoardFormat.claudeRulesV1) {
            desired[BoardFormat.claudePath] = BoardFormat.claudeRules
        }

        // 7. Diferențele față de repo
        var entries: [[String: Any]] = []
        for (path, content) in desired.sorted(by: { $0.key < $1.key }) {
            if remote[path] != BoardFormat.blobSHA(content) {
                entries.append(["path": path, "mode": "100644", "type": "blob", "content": content])
            }
        }
        for path in remote.keys.sorted() where path.hasPrefix(BoardFormat.notesDir + "/") && desired[path] == nil {
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
        }

        // 8. Un singur commit cu toate schimbările
        if !entries.isEmpty {
            let treeBody: [String: Any] = ["base_tree": treeSHA, "tree": entries]
            let newTree = try await gh.send("POST", "/git/trees", body: treeBody)
            guard let newTreeSHA = newTree.object["sha"] as? String else {
                throw GitHubError(status: 0, message: "tree nou invalid")
            }
            let message = "guwapi: sincronizare din aplicație (\(entries.count) fișiere)"
            let commitBody: [String: Any] = ["message": message, "tree": newTreeSHA, "parents": [head]]
            let newCommit = try await gh.send("POST", "/git/commits", body: commitBody)
            guard let newCommitSHA = newCommit.object["sha"] as? String else {
                throw GitHubError(status: 0, message: "commit nou invalid")
            }
            let refBody: [String: Any] = ["sha": newCommitSHA, "force": false]
            let update = try await gh.send("PATCH", "/git/refs/heads/\(branch)", body: refBody, allow: [409, 422])
            if update.status == 409 || update.status == 422 { throw SyncConflict() }
        }

        // 9. Salvăm baza pentru data viitoare
        for (path, content) in desired where path.hasPrefix(BoardFormat.notesDir + "/") {
            if path.hasSuffix("/" + BoardFormat.projectFile) {
                if let folderID = BoardFormat.parseProjectFolder(content) {
                    newCache[path] = SyncState.CachedFile(sha: BoardFormat.blobSHA(content), id: folderID.uuidString,
                                                          statusRaw: nil, tags: [])
                }
            } else if let parsed = BoardFormat.parse(content) {
                newCache[path] = SyncState.CachedFile(sha: BoardFormat.blobSHA(content), id: parsed.id.uuidString,
                                                      statusRaw: parsed.statusRaw, tags: parsed.tags)
            }
        }
        newCache = newCache.filter { desired[$0.key] != nil }
        state.base = newBase
        state.files = newCache
        state.lastSync = Date()
        state.save()
        lastChanges = changesFromRemote
        lastProposals = proposalsAdded
        phase = .ok(Date())
    }

    /// Repo-ul de cod: al folderului sau al celui mai apropiat părinte care îl are.
    private func projectRepo(for folderID: UUID, _ store: LibraryStore) -> String? {
        var current = store.folder(folderID)
        var depth = 0
        while let f = current, depth < 20 {
            if let repo = f.projectRepo?.trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty {
                return repo.replacingOccurrences(of: "https://github.com/", with: "")
            }
            current = store.folder(f.parentID)
            depth += 1
        }
        return nil
    }

    private func fields(of note: NoteMeta, _ store: LibraryStore) -> SyncState.Fields {
        SyncState.Fields(status: BoardFormat.slug(note.status), tags: tagKey(note.tagIDs, store))
    }

    private func tagKey(_ ids: [UUID], _ store: LibraryStore) -> [String] {
        ids.compactMap { store.tag($0) }.map { LibraryStore.normalize($0.name) }.sorted()
    }

    /// Drumul fiecărui folder în repo („Centry/GIC”); numele identice primesc un sufix.
    private func folderPathMap(_ store: LibraryStore) -> [UUID: String] {
        var result: [UUID: String] = [:]
        func walk(_ parent: UUID?, _ prefix: String, _ depth: Int) {
            guard depth < 12 else { return }
            var used: Set<String> = []
            for f in store.subfolders(of: parent) {
                // Cu „Ascunde titlurile”, nici numele folderului nu ajunge în repo
                var name = store.effectiveHideTitles(f.id)
                    ? "folder-\(f.id.uuidString.prefix(6).lowercased())"
                    : BoardFormat.sanitize(f.name)
                if used.contains(name.lowercased()) { name += " (\(f.id.uuidString.prefix(4)))" }
                used.insert(name.lowercased())
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                result[f.id] = path
                walk(f.id, path, depth + 1)
            }
        }
        walk(nil, "", 0)
        return result
    }
}
