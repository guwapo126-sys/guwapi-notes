import SwiftUI

// MARK: - Setări → Sincronizare cu Claude

struct SyncSettingsSection: View {
    @EnvironmentObject var sync: SyncEngine
    @AppStorage(SyncEngine.enabledKey) var enabled = false
    @AppStorage(SyncEngine.repoKey) var repo = ""
    @AppStorage(LibraryStore.defaultAccessKey) var defaultAccess = ClaudeAccess.privat.rawValue
    @State var tokenInput = ""
    @State var hasToken = TokenStore.hasToken
    @State var testResult: String?
    @State var testing = false

    var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                Label("Sincronizare cu Claude", systemImage: "arrow.triangle.2.circlepath")
            }
            if enabled { details }
        } header: {
            sectionHeader("Claude")
        } footer: {
            Text(footer).foregroundStyle(Brand.muted)
        }
        .listRowBackground(Brand.surface)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { sync.setEnabled($0) })
    }

    @ViewBuilder private var details: some View {
        statusRow
        TextField("proprietar/repo (ex. guwapo126-sys/guwapi-board)", text: $repo)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.callout.monospaced())
        tokenRow
        Picker("Folderele noi", selection: $defaultAccess) {
            ForEach(ClaudeAccess.allCases) { a in
                Label(a.label, systemImage: a.icon).tag(a.rawValue)
            }
        }
        actions
        if let testResult {
            Text(testResult).font(.caption).foregroundStyle(Brand.text)
        }
        if sync.repoIsPublic {
            Label("Repo-ul e public: oricine poate vedea titlurile. Fă-l privat pe GitHub.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(NoteStatus.problem.color)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            Text(statusText).font(.subheadline).foregroundStyle(Brand.text)
            Spacer()
            if sync.phase == .syncing { ProgressView() }
        }
    }

    private var statusColor: Color {
        switch sync.phase {
        case .ok: return NoteStatus.done.color
        case .failed: return NoteStatus.problem.color
        case .syncing, .idle: return NoteStatus.progress.color
        case .off: return Brand.muted
        }
    }

    private var statusText: String {
        switch sync.phase {
        case .off: return "Oprită"
        case .idle: return "Pregătită"
        case .syncing: return "Se sincronizează…"
        case .ok(let date):
            let when = date.formatted(.relative(presentation: .named))
            return sync.lastChanges > 0 ? "Sincronizat \(when) · \(sync.lastChanges) schimbări primite" : "Sincronizat \(when)"
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var tokenRow: some View {
        if hasToken {
            HStack {
                Label("Token salvat în Keychain", systemImage: "key.fill").foregroundStyle(Brand.text)
                Spacer()
                Button("Șterge", role: .destructive) {
                    TokenStore.delete()
                    hasToken = false
                }
                .font(.subheadline)
            }
        } else {
            HStack {
                SecureField("Token GitHub (github_pat_…)", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Salvează") {
                    let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    hasToken = TokenStore.save(token)
                    tokenInput = ""
                }
                .bold()
                .disabled(tokenInput.isEmpty)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                testing = true
                Task {
                    testResult = await sync.testConnection()
                    testing = false
                }
            } label: { Label(testing ? "Se verifică…" : "Testează", systemImage: "checkmark.shield") }
                .buttonStyle(.bordered)
                .disabled(testing)
            Spacer()
            Button {
                Task { await sync.syncNow() }
            } label: { Label("Sincronizează acum", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderedProminent)
                .disabled(sync.phase == .syncing)
        }
        .font(.subheadline)
    }

    private var footer: String {
        guard enabled else {
            return "Pornește ca să-i dai voie lui Claude să vadă și să schimbe statusul și etichetele notelor din folderele pe care le alegi tu."
        }
        return "Ajung în repo doar folderele setate pe „Status”: titlul, statusul și etichetele. Conținutul notelor nu pleacă de pe telefon. Atenție: git păstrează istoricul; ce a fost odată în repo rămâne în commit-urile vechi."
    }
}

// MARK: - Acces Claude pe folder

/// Valoarea aleasă în editor: moștenește (doar subfoldere) sau un nivel explicit.
enum AccessChoice: String, CaseIterable, Identifiable {
    case inherit, privat, status
    var id: String { rawValue }

    init(_ access: ClaudeAccess?) {
        switch access {
        case .privat?: self = .privat
        case .status?: self = .status
        case nil: self = .inherit
        }
    }

    var access: ClaudeAccess? {
        switch self {
        case .inherit: return nil
        case .privat: return .privat
        case .status: return .status
        }
    }
}

struct AccessSection: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var folder: Folder
    @Binding var choice: AccessChoice

    private var isTopLevel: Bool { folder.parentID == nil }
    private var inherited: ClaudeAccess { store.effectiveAccess(folder.parentID) }
    private var effective: ClaudeAccess { choice.access ?? inherited }

    private var options: [AccessChoice] { isTopLevel ? [.privat, .status] : AccessChoice.allCases }

    var body: some View {
        Section {
            Picker("Nivel", selection: $choice) {
                ForEach(options) { option in
                    Label(label(option), systemImage: icon(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if effective == .status {
                Toggle("Ascunde titlurile (doar coduri, ex. GIC-12)", isOn: hideBinding)
            }
        } header: {
            sectionHeader("Acces Claude")
        } footer: {
            Text(effective.explanation + (isTopLevel ? "" : " Subfolderele moștenesc setarea, dacă nu au una proprie."))
                .foregroundStyle(Brand.muted)
        }
        .listRowBackground(Brand.surface)
    }

    private func label(_ option: AccessChoice) -> String {
        switch option {
        case .inherit: return "Moștenește (\(inherited.label))"
        case .privat: return "🔒 Privat"
        case .status: return "🏷️ Status"
        }
    }

    private func icon(_ option: AccessChoice) -> String {
        switch option {
        case .inherit: return "arrow.turn.left.up"
        case .privat: return ClaudeAccess.privat.icon
        case .status: return ClaudeAccess.status.icon
        }
    }

    private var hideBinding: Binding<Bool> {
        Binding(get: { folder.hideTitles ?? store.effectiveHideTitles(folder.parentID) },
                set: { folder.hideTitles = $0 })
    }
}

/// Meniu rapid (apăsare lungă pe folder).
struct AccessMenu: View {
    @EnvironmentObject var store: LibraryStore
    let folder: Folder

    var body: some View {
        Menu {
            if folder.parentID != nil {
                Button { store.setAccess(nil, for: folder.id) } label: {
                    Label("Moștenește\(folder.access == nil ? " ✓" : "")", systemImage: "arrow.turn.left.up")
                }
            }
            ForEach(ClaudeAccess.allCases) { a in
                Button { store.setAccess(a, for: folder.id) } label: {
                    Label(a.label + (folder.access == a ? " ✓" : ""), systemImage: a.icon)
                }
            }
        } label: {
            Label("Acces Claude: \(store.effectiveAccess(folder.id).label)", systemImage: "sparkles")
        }
    }
}

/// Iconița mică de pe rândul folderului când Claude îl vede.
struct AccessBadge: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var sync: SyncEngine
    let folderID: UUID

    var body: some View {
        if sync.enabled && store.effectiveAccess(folderID) == .status {
            Image(systemName: store.effectiveHideTitles(folderID) ? "number" : "tag.fill")
                .font(.caption2)
                .foregroundStyle(Brand.accent)
                .accessibilityLabel("Claude vede statusul")
        }
    }
}

/// „Claude · În lucru → De verificat · acum 2h”
struct ExternalChangeLine: View {
    let note: NoteMeta

    var body: some View {
        if note.recentExternalChange, let summary = note.externalChange {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("\(note.externalChangeBy ?? "Claude") · \(summary)")
                if let at = note.externalChangeAt {
                    Text("· " + at.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Brand.accent)
            .lineLimit(1)
        }
    }
}

/// Bara discretă din notă: ce vede Claude.
struct ClaudeVisibilityBar: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var sync: SyncEngine
    let note: NoteMeta

    var body: some View {
        if sync.enabled && store.effectiveAccess(note.folderID) == .status {
            VStack(alignment: .leading, spacing: 2) {
                Label(store.effectiveHideTitles(note.folderID)
                      ? "Claude vede: codul \(note.code ?? "…"), statusul, etichetele"
                      : "Claude vede: titlul, statusul, etichetele",
                      systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
                ExternalChangeLine(note: note)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
