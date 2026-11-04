import SwiftUI
import WidgetKit
import UserNotifications

// MARK: - Ecranul principal

struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var router: Router
    @State var search = ""
    @State var folderDraft: FolderDraft?
    @State var showTemplates = false
    @State var showDiagnostics = false
    @State var showImport = false
    @State var showTagManager = false
    @State var showSettings = false
    @State var deleting: Folder?

    var body: some View {
        NavigationStack(path: $router.path) {
            List {
                if search.isEmpty { libraryContent } else { searchResults }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .refreshable { await SyncEngine.shared.syncNow() }
            .navigationTitle("guwapi notes")
            .searchable(text: $search, prompt: "Caută în toate notele")
            .toolbar { toolbarContent }
            .navigationDestination(for: Route.self) { destination($0) }
            .modifier(rootSheets)
            .task { _ = await Reminders.requestAuth() }
        }
    }

    private var rootSheets: RootSheets {
        RootSheets(folderDraft: $folderDraft, showTemplates: $showTemplates, showDiagnostics: $showDiagnostics,
                   showImport: $showImport, showTagManager: $showTagManager, showSettings: $showSettings,
                   deleting: $deleting)
    }

    @ViewBuilder private var libraryContent: some View {
        if !store.proposals.isEmpty {
            Section {
                NavigationLink(value: Route.proposals) { ProposalsEntryRow(count: store.proposals.count) }
            }
            .listRowBackground(Brand.surface)
        }
        Section {
            NavigationLink(value: Route.all) {
                shortcutRow("Toate notele", icon: "tray.full.fill", count: store.notes.count)
            }
            NavigationLink(value: Route.folder(nil)) {
                shortcutRow("Note rapide", icon: "bolt.fill", count: store.notes(in: nil).count)
            }
        }
        .listRowBackground(Brand.surface)

        Section {
            ForEach(store.subfolders(of: nil)) { folder in
                NavigationLink(value: Route.folder(folder.id)) { FolderRow(folder: folder) }
                    .contextMenu { folderMenu(folder) }
            }
            Button { newFolder() } label: {
                Label("Folder nou", systemImage: "folder.badge.plus").foregroundStyle(Brand.accent)
            }
        } header: { sectionHeader("Clienți și foldere") }
        .listRowBackground(Brand.surface)

        Section {
            ForEach(store.tagDefs) { tag in
                NavigationLink(value: Route.tag(tag.id)) { tagRow(tag) }
            }
            Button { showTagManager = true } label: {
                Label("Gestionează etichetele", systemImage: "tag").foregroundStyle(Brand.accent)
            }
        } header: { sectionHeader("Etichete") }
        .listRowBackground(Brand.surface)
    }

    @ViewBuilder private var searchResults: some View {
        let results = store.search(search)
        Section {
            if results.isEmpty {
                Text("Niciun rezultat").foregroundStyle(Brand.muted)
            }
            ForEach(results) { note in
                NavigationLink(value: Route.note(note.id)) { NoteListRow(note: note, showPath: true) }
            }
        } header: { sectionHeader("Rezultate") }
        .listRowBackground(Brand.surface)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button { showDiagnostics = true } label: {
                Image(systemName: "stethoscope").foregroundStyle(WidgetLink.current.color)
            }
        }
        ToolbarItem(placement: .topBarTrailing) { addMenu }
    }

    private var addMenu: some View {
        Menu {
            Button { router.open(store.createNote(in: nil)) } label: {
                Label("Notă nouă", systemImage: "square.and.pencil")
            }
            Button { showTemplates = true } label: { Label("Din șablon…", systemImage: "doc.on.doc") }
            Button { newFolder() } label: { Label("Folder nou", systemImage: "folder.badge.plus") }
            Button { showImport = true } label: {
                Label("Importă fișiere sau folder…", systemImage: "square.and.arrow.down")
            }
        } label: { Image(systemName: "plus.circle.fill").font(.title3) }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .folder(let id):
            FolderScreen(folderID: id)
        case .all:
            NotesScreen(title: "Toate notele", source: .all)
        case .tag(let id):
            NotesScreen(title: tagTitle(id), source: .tag(id))
        case .note(let id):
            NoteEditorScreen(noteID: id)
        case .proposals:
            ProposalsScreen(noteID: nil)
        }
    }

    private func tagTitle(_ id: UUID) -> String {
        guard let t = store.tag(id) else { return "Etichetă" }
        return "\(t.emoji) \(t.name)"
    }

    private func newFolder() {
        folderDraft = FolderDraft(folder: Folder(name: "", parentID: nil), isNew: true)
    }

    private func tagRow(_ tag: TagDef) -> some View {
        HStack(spacing: 12) {
            Text(tag.emoji).frame(width: 26)
            Text(tag.name).foregroundStyle(Brand.text)
            Spacer()
            Text("\(store.tagCount(tag.id))").font(.caption).foregroundStyle(Brand.muted)
        }
    }

    @ViewBuilder private func folderMenu(_ folder: Folder) -> some View {
        Button { folderDraft = FolderDraft(folder: folder, isNew: false) } label: { Label("Editează", systemImage: "pencil") }
        Button {
            folderDraft = FolderDraft(folder: Folder(name: "", parentID: folder.id, colorHex: folder.colorHex), isNew: true)
        } label: { Label("Subfolder nou", systemImage: "folder.badge.plus") }
        AccessMenu(folder: folder)
        Button(role: .destructive) { deleting = folder } label: { Label("Șterge", systemImage: "trash") }
    }

    private func shortcutRow(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Brand.accent).frame(width: 26)
            Text(title).foregroundStyle(Brand.text)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(Brand.muted)
        }
    }
}

@MainActor
func sectionHeader(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.caption.weight(.semibold))
        .tracking(1.1)
        .foregroundStyle(Brand.muted)
}

struct FolderRow: View {
    @EnvironmentObject var store: LibraryStore
    let folder: Folder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.icon)
                .foregroundStyle(Color(hexString: folder.colorHex))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).foregroundStyle(Brand.text)
                let subs = store.subfolders(of: folder.id).count
                if subs > 0 {
                    Text(subs == 1 ? "1 subfolder" : "\(subs) subfoldere")
                        .font(.caption2).foregroundStyle(Brand.muted)
                }
            }
            Spacer()
            AccessBadge(folderID: folder.id)
            Text("\(store.noteCount(in: folder.id))").font(.caption).foregroundStyle(Brand.muted)
        }
    }
}

// MARK: - Folder (client / aplicație)

struct FolderScreen: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    @AppStorage("notesGridMode") var grid = true
    let folderID: UUID?

    @State var folderDraft: FolderDraft?
    @State var showTemplates = false
    @State var confirmDelete = false
    @State var showImport = false
    @State var showReorder = false
    @State var statusFilter: NoteStatus?
    @State var tagFilter: UUID?
    @State var showDone = false

    private var folder: Folder? { store.folder(folderID) }

    private var filtersActive: Bool { statusFilter != nil || tagFilter != nil }

    private func filtered(_ list: [NoteMeta]) -> [NoteMeta] {
        list.filter { n in
            let statusOK = statusFilter == nil || n.status == statusFilter
            let tagOK = tagFilter.map { n.tagIDs.contains($0) } ?? true
            return statusOK && tagOK
        }
    }

    private var sortBinding: Binding<SortMode> {
        Binding(get: { store.sortMode(for: folderID) },
                set: { store.setSortMode($0, for: folderID) })
    }

    private var screenTitle: String { folder?.name ?? "Note rapide" }

    var body: some View {
        screen
            .sheet(item: $folderDraft) { FolderEditorSheet(draft: $0) }
            .sheet(isPresented: $showTemplates) { TemplatePickerSheet(folderID: folderID) }
            .importer(isPresented: $showImport, into: folderID)
            .sheet(isPresented: $showReorder) { ReorderSheet(folderID: folderID) }
            .confirmationDialog("Ștergi folderul?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Șterge folderul", role: .destructive) { deleteThisFolder() }
            } message: { Text("Notele și subfolderele lui se mută în folderul părinte.") }
    }

    private var screen: some View {
        ScrollView { content.padding(16) }
            .refreshable { await SyncEngine.shared.syncNow() }
            .background(Brand.background)
            .navigationTitle(screenTitle)
            .toolbar { toolbarContent }
    }

    private func deleteThisFolder() {
        if let id = folderID { store.deleteFolder(id) }
        dismiss()
    }

    @ViewBuilder private var content: some View {
        let subs = store.subfolders(of: folderID)
        let allNotes = store.notes(in: folderID)
        let notes = filtered(allNotes)
        VStack(alignment: .leading, spacing: 18) {
            if let folder, folder.parentID != nil {
                Text(store.path(of: folder.parentID))
                    .font(.caption).foregroundStyle(Brand.muted)
            }
            if !subs.isEmpty {
                SubfolderList(folders: subs) { folderDraft = FolderDraft(folder: $0, isNew: false) }
            }
            if !allNotes.isEmpty {
                ProjectSummary(notes: allNotes, selection: $statusFilter)
            }
            if allNotes.contains(where: { !$0.tagIDs.isEmpty }) {
                StatusFilterBar(notes: allNotes, selection: $statusFilter, tagSelection: $tagFilter, showStatuses: false)
            }
            notesArea(notes, folderEmpty: allNotes.isEmpty && subs.isEmpty)
        }
    }

    @ViewBuilder private func notesArea(_ notes: [NoteMeta], folderEmpty: Bool) -> some View {
        if folderEmpty {
            EmptyState(text: "Folder gol. Adaugă o notă sau un subfolder din butonul +.")
        } else if notes.isEmpty && filtersActive {
            EmptyState(text: "Nicio notă cu acest filtru.")
        } else if store.sortMode(for: folderID) == .status && statusFilter == nil {
            StatusGroupedNotes(notes: notes, grid: grid, showDone: $showDone)
        } else {
            NotesCollection(notes: notes, grid: grid, showPath: false)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            sortMenu
            Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
            addMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortare", selection: sortBinding) {
                ForEach(SortMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            Divider()
            Button { showReorder = true } label: { Label("Aranjează ordinea…", systemImage: "line.3.horizontal") }
        } label: { Image(systemName: "arrow.up.arrow.down") }
    }

    private var addMenu: some View {
        Menu {
            Button { router.open(store.createNote(in: folderID, colorHex: nil)) } label: {
                Label("Notă nouă", systemImage: "square.and.pencil")
            }
            Button { showTemplates = true } label: { Label("Din șablon…", systemImage: "doc.on.doc") }
            Button { showImport = true } label: {
                Label("Importă fișiere sau folder…", systemImage: "square.and.arrow.down")
            }
            if let folder { folderActions(folder) }
        } label: { Image(systemName: "plus.circle.fill").font(.title3) }
    }

    @ViewBuilder private func folderActions(_ folder: Folder) -> some View {
        Button {
            folderDraft = FolderDraft(folder: Folder(name: "", parentID: folder.id, colorHex: folder.colorHex), isNew: true)
        } label: { Label("Subfolder nou", systemImage: "folder.badge.plus") }
        Divider()
        Button { folderDraft = FolderDraft(folder: folder, isNew: false) } label: {
            Label("Editează folderul", systemImage: "pencil")
        }
        Button(role: .destructive) { confirmDelete = true } label: {
            Label("Șterge folderul", systemImage: "trash")
        }
    }
}

/// Subfolderele unui folder; acceptă note trase peste ele.
struct SubfolderList: View {
    @EnvironmentObject var store: LibraryStore
    let folders: [Folder]
    let onEdit: (Folder) -> Void
    @State var dropTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(folders) { sub in
                row(sub)
                if sub.id != folders.last?.id {
                    Divider().overlay(Brand.line).padding(.leading, 52)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
    }

    private func row(_ sub: Folder) -> some View {
        let highlighted = dropTarget == sub.id
        return NavigationLink(value: Route.folder(sub.id)) {
            FolderRow(folder: sub)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onEdit(sub) } label: { Label("Editează", systemImage: "pencil") }
            AccessMenu(folder: sub)
        }
        .dropDestination(for: String.self) { items, _ in
            dropNote(items, into: sub.id)
        } isTargeted: { hovering in
            if hovering { dropTarget = sub.id } else if dropTarget == sub.id { dropTarget = nil }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(highlighted ? Brand.accent.opacity(0.18) : Color.clear))
    }

    private func dropNote(_ items: [String], into folderID: UUID) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
        store.move(id, to: folderID)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return true
    }
}

/// Toate notele sau o etichetă.
struct NotesScreen: View {
    enum Source { case all, tag(UUID) }

    @EnvironmentObject var store: LibraryStore
    @AppStorage("notesGridMode") var grid = true
    let title: String
    let source: Source

    var body: some View {
        let notes: [NoteMeta] = {
            switch source {
            case .all: return store.allNotes
            case .tag(let t): return store.notes(tagID: t)
            }
        }()
        ScrollView {
            if notes.isEmpty {
                EmptyState(text: "Nicio notă aici încă.").padding(16)
            } else {
                NotesCollection(notes: notes, grid: grid, showPath: true).padding(16)
            }
        }
        .background(Brand.background)
        .navigationTitle(title)
        .toolbar {
            Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
        }
    }
}

struct EmptyState: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image("LaunchLogo").resizable().scaledToFit().frame(width: 64, height: 64).opacity(0.6)
            Text(text).font(.subheadline).foregroundStyle(Brand.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Carduri și listă compactă

struct NotesCollection: View {
    @EnvironmentObject var store: LibraryStore
    let notes: [NoteMeta]
    let grid: Bool
    let showPath: Bool
    @State var moving: NoteMeta?
    @State var deleting: NoteMeta?
    @State var dropTarget: UUID?

    var body: some View {
        collection
            .sheet(item: $moving) { note in
                FolderPickerSheet(title: "Mută nota", current: note.folderID) { store.move(note.id, to: $0) }
            }
            .confirmationDialog(deleteTitle, isPresented: deletingBinding, titleVisibility: .visible) {
                Button("Șterge", role: .destructive) { confirmDelete() }
            }
    }

    @ViewBuilder private var collection: some View {
        if grid { gridView } else { listView }
    }

    private var gridView: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
            ForEach(notes) { note in gridCell(note) }
        }
    }

    private var listView: some View {
        LazyVStack(spacing: 0) {
            ForEach(notes) { note in
                listCell(note)
                if note.id != notes.last?.id { Divider().overlay(Brand.line).padding(.leading, 36) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
    }

    private func gridCell(_ note: NoteMeta) -> some View {
        NavigationLink(value: Route.note(note.id)) { NoteCard(note: note, showPath: showPath) }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) { quickStatus(note).frame(width: 104, height: 30).padding(6) }
            .contextMenu { menu(note) }
            .modifier(drag(note, cornerRadius: 16))
    }

    private func listCell(_ note: NoteMeta) -> some View {
        NavigationLink(value: Route.note(note.id)) {
            NoteListRow(note: note, showPath: showPath)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) { quickStatus(note).frame(width: 40).frame(maxHeight: .infinity) }
        .contextMenu { menu(note) }
        .modifier(drag(note, cornerRadius: 10))
    }

    /// Atingi statusul (bulina sau eticheta de status) și îl schimbi direct, fără să deschizi nota.
    private func quickStatus(_ note: NoteMeta) -> QuickStatusMenu {
        let id = note.id
        return QuickStatusMenu(current: note.status) { store.setStatus(id, $0) }
    }

    private func drag(_ note: NoteMeta, cornerRadius: CGFloat) -> NoteDrag {
        let targetID = note.id
        return NoteDrag(note: note, enabled: !showPath, cornerRadius: cornerRadius, target: $dropTarget) { dragged in
            store.moveNote(dragged, onto: targetID)
        }
    }

    private var deleteTitle: String { "Ștergi nota „\(deleting?.displayTitle ?? "")”?" }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func confirmDelete() {
        if let n = deleting { store.deleteNote(n.id) }
        deleting = nil
    }

    @ViewBuilder private func menu(_ note: NoteMeta) -> some View {
        Button { store.togglePin(note.id) } label: {
            Label(note.pinned ? "Anulează fixarea" : "Fixează sus", systemImage: note.pinned ? "pin.slash" : "pin")
        }
        StatusMenu(selected: note.status) { store.setStatus(note.id, $0) }
        TagsMenu(noteID: note.id)
        ColorMenu(selected: note.colorHex) { store.setColor(note.id, $0) }
        Button { moving = note } label: { Label("Mută…", systemImage: "folder") }
        Button { store.duplicate(note.id) } label: { Label("Duplică", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { deleting = note } label: { Label("Șterge", systemImage: "trash") }
    }
}

struct ColorMenu: View {
    let selected: String?
    let onPick: (String?) -> Void

    var body: some View {
        Menu {
            Button { onPick(nil) } label: { Label("Fără culoare", systemImage: selected == nil ? "checkmark" : "circle.slash") }
            ForEach(Brand.palette, id: \.hex) { item in
                Button { onPick(item.hex) } label: {
                    Label { Text(selected == item.hex ? "\(item.name) ✓" : item.name) } icon: { Image(uiImage: Swatch.image(item.hex)) }
                }
            }
        } label: { Label("Culoare", systemImage: "paintpalette") }
    }
}

struct NoteCard: View {
    @EnvironmentObject var store: LibraryStore
    let note: NoteMeta
    var showPath = false

    private var color: Color { note.colorHex.map { Color(hexString: $0) } ?? Brand.muted }

    var body: some View {
        cardContent
            .accessibilityElement(children: .combine)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            .background(cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1))
    }

    private var fillColor: Color { note.colorHex == nil ? Color.clear : color.opacity(0.13) }
    private var borderColor: Color { note.colorHex == nil ? Brand.line : color.opacity(0.55) }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Brand.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).fill(fillColor))
    }

    private var topRow: some View {
        HStack(spacing: 5) {
            if let status = note.status {
                StatusPill(status: status)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.accent) }
            Spacer()
            if let r = note.reminder, r > Date() {
                Image(systemName: "bell.fill").font(.caption2).foregroundStyle(Brand.accent)
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if note.recentExternalChange {
                Image(systemName: "sparkles").foregroundStyle(Brand.accent)
            }
            Text(note.updated, format: .relative(presentation: .named))
            Spacer(minLength: 0)
            TagEmojis(note: note, limit: 3)
        }
        .font(.caption2)
        .foregroundStyle(Brand.muted)
        .lineLimit(1)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            Text(note.displayTitle)
                .font(.headline)
                .foregroundStyle(Brand.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(Brand.text.opacity(0.7))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if showPath {
                Text(store.path(of: note.folderID)).font(.caption2).foregroundStyle(Brand.muted).lineLimit(1)
            }
            bottomRow
        }
    }
}

struct NoteListRow: View {
    @EnvironmentObject var store: LibraryStore
    let note: NoteMeta
    var showPath = false

    var body: some View {
        rowContent
            .accessibilityElement(children: .combine)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(note: note).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.accent) }
                    Text(note.displayTitle).font(.headline).foregroundStyle(Brand.text).lineLimit(1)
                }
                if !note.preview.isEmpty {
                    Text(note.preview).font(.subheadline).foregroundStyle(Brand.muted).lineLimit(1)
                }
                ExternalChangeLine(note: note)
                if showPath {
                    Text(store.path(of: note.folderID)).font(.caption2).foregroundStyle(Brand.muted.opacity(0.8))
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    TagEmojis(note: note, limit: 3)
                    Text(note.updated, format: .dateTime.day().month(.abbreviated))
                }
                    .font(.caption2).foregroundStyle(Brand.muted)
                if let r = note.reminder, r > Date() {
                    Image(systemName: "bell.fill").font(.caption2).foregroundStyle(Brand.accent)
                }
                if let s = note.status {
                    Text(s.label).font(.caption2.weight(.semibold)).foregroundStyle(s.color)
                }
            }
        }
    }
}

// MARK: - Editare folder

struct FolderDraft: Identifiable {
    let id = UUID()
    var folder: Folder
    var isNew: Bool
}

struct FolderEditorSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State var folder: Folder
    @State var accessChoice: AccessChoice
    private let isNew: Bool

    static let icons = [
        "folder.fill", "briefcase.fill", "person.fill", "person.2.fill", "building.2.fill", "app.fill",
        "iphone", "globe", "server.rack", "cart.fill", "shield.fill", "lock.fill",
        "star.fill", "bolt.fill", "hammer.fill", "doc.text.fill", "chart.bar.fill", "lightbulb.fill"
    ]

    init(draft: FolderDraft) {
        _folder = State(initialValue: draft.folder)
        isNew = draft.isNew
        // Folder nou pe primul nivel: pornește de la nivelul implicit din Setări
        let initial: ClaudeAccess? = draft.isNew && draft.folder.parentID == nil
            ? LibraryStore.defaultAccess
            : draft.folder.access
        // Folder vechi de pe primul nivel (fără setare): „Moștenește” nu e o opțiune acolo → Privat
        let shown: ClaudeAccess? = initial ?? (draft.folder.parentID == nil ? .privat : nil)
        _accessChoice = State(initialValue: AccessChoice(shown))
    }

    private static let columns = Array(repeating: GridItem(.flexible()), count: 6)

    private var folderColor: Color { Color(hexString: folder.colorHex) }
    private var screenTitle: String { isNew ? "Folder nou" : "Editează folderul" }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                AccessSection(folder: $folder, choice: $accessChoice)
                colorSection
                iconSection
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .presentationDetents([.large])
    }

    private var nameSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: folder.icon)
                    .font(.title2)
                    .foregroundStyle(folderColor)
                    .frame(width: 36)
                TextField("Nume (ex: client, aplicație)", text: $folder.name)
                    .font(.title3.weight(.semibold))
            }
            if let parent = folder.parentID {
                Text("În: \(store.path(of: parent))").font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .listRowBackground(Brand.surface)
    }

    private var colorSection: some View {
        Section("Culoare") {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(Brand.palette, id: \.hex) { item in colorCell(item.hex) }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Brand.surface)
    }

    private func colorCell(_ hex: String) -> some View {
        let ring: CGFloat = folder.colorHex == hex ? 3 : 0
        return Circle()
            .fill(Color(hexString: hex))
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(Brand.text, lineWidth: ring).padding(-4))
            .onTapGesture { folder.colorHex = hex }
    }

    private var iconSection: some View {
        Section("Iconiță") {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(Self.icons, id: \.self) { icon in iconCell(icon) }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Brand.surface)
    }

    private func iconCell(_ icon: String) -> some View {
        let selected = folder.icon == icon
        let foreground: Color = selected ? Brand.background : folderColor
        let fill: Color = selected ? folderColor : Brand.surfaceHi
        return Image(systemName: icon)
            .font(.title3)
            .frame(width: 40, height: 40)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .onTapGesture { folder.icon = icon }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button("Salvează") { save() }.bold()
        }
    }

    private func save() {
        let name = folder.name.trimmingCharacters(in: .whitespaces)
        if isNew {
            store.createFolder(name: name, parent: folder.parentID, colorHex: folder.colorHex, icon: folder.icon,
                               access: accessChoice.access ?? (folder.parentID == nil ? .privat : nil),
                               hideTitles: folder.hideTitles, projectRepo: folder.projectRepo)
        } else {
            var f = folder
            f.name = name.isEmpty ? "Folder" : name
            f.access = accessChoice.access
            store.updateFolder(f)
        }
        dismiss()
    }
}

/// Alegere folder (mutare notă).
struct FolderPickerSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let title: String
    let current: UUID?
    let onPick: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                row(name: "Note rapide", icon: "bolt.fill", color: Brand.accent, depth: 0, id: nil)
                ForEach(store.flattenedFolders(), id: \.folder.id) { item in
                    row(name: item.folder.name, icon: item.folder.icon,
                        color: Color(hexString: item.folder.colorHex), depth: item.depth, id: item.folder.id)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(name: String, icon: String, color: Color, depth: Int, id: UUID?) -> some View {
        Button {
            onPick(id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 24)
                Text(name).foregroundStyle(Brand.text)
                Spacer()
                if current == id { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
        .listRowBackground(Brand.surface)
    }
}

// MARK: - Șabloane

struct TemplatePickerSheet: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) var dismiss
    let folderID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(BuiltInTemplate.all) { t in
                        Button { create(t.build(), color: t.colorHex) } label: {
                            Label {
                                Text(t.name).foregroundStyle(Brand.text)
                            } icon: {
                                Image(systemName: t.icon).foregroundStyle(Color(hexString: t.colorHex))
                            }
                        }
                    }
                } header: { sectionHeader("Predefinite") }
                .listRowBackground(Brand.surface)

                Section {
                    if store.customTemplates.isEmpty {
                        Text("Din orice notă: meniul ⋯ → Salvează ca șablon.")
                            .font(.footnote).foregroundStyle(Brand.muted)
                    }
                    ForEach(store.customTemplates) { t in
                        Button { create(store.templateBody(t), color: nil) } label: {
                            Label { Text(t.name).foregroundStyle(Brand.text) } icon: {
                                Image(systemName: "doc.badge.gearshape").foregroundStyle(Brand.accent)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { store.customTemplates[$0] }
                        for t in doomed { store.deleteTemplate(t) }
                    }
                } header: { sectionHeader("Ale tale") }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Notă din șablon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } } }
        }
    }

    private func create(_ body: NSAttributedString, color: String?) {
        let id = store.createNote(in: folderID, body: body, colorHex: color)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.open(id) }
    }
}

// MARK: - Diagnostic

struct DiagnosticsView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State var notifStatus = "…"
    @State var installed: [String] = []
    @State var link: WidgetLink = .current

    var body: some View {
        NavigationStack {
            List {
                Section { widgetCard } header: { sectionHeader("Widget") }
                    .listRowBackground(Brand.surface)
                Section { notificationsRows } header: { sectionHeader("Notificări") }
                    .listRowBackground(Brand.surface)
                Section { dataRows } header: { sectionHeader("Date") }
                    .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Diagnostic")
            .toolbar { Button("Gata") { dismiss() } }
            .task { await refresh() }
        }
    }

    private var widgetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(link.color.opacity(0.18)).frame(width: 44, height: 44)
                    Image(systemName: link.icon).font(.title3).foregroundStyle(link.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title).font(.headline).foregroundStyle(Brand.text)
                    Text(detail).font(.caption).foregroundStyle(Brand.muted)
                }
            }
            if !installed.isEmpty {
                Text("Pe ecran: " + installed.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Brand.text.opacity(0.8))
            }
            Button {
                WidgetCenter.shared.reloadAllTimelines()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await refresh()
                }
            } label: { Label("Reîncarcă widgeturile", systemImage: "arrow.clockwise") }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        switch link {
        case .healthy(let date):
            return "Ultima actualizare: " + date.formatted(.relative(presentation: .named))
        case .waiting:
            return installed.isEmpty
                ? "Adaugă widgetul guwapi pe ecranul de blocare sau pe ecranul principal."
                : "Widgetul e pus, dar nu s-a actualizat de curând. Apasă Reîncarcă."
        case .broken:
            return "Aplicația și widgetul nu au un spațiu comun de date. Reinstalează prin SideStore."
        }
    }

    @ViewBuilder private var notificationsRows: some View {
        Text("Permisiune: \(notifStatus)")
        Button("Trimite notificare de test în 10 s") { Reminders.test() }
    }

    @ViewBuilder private var dataRows: some View {
        Text("\(store.notes.count) note · \(store.folders.count) foldere · \(store.tagDefs.count) etichete")
        Text("Versiune \(appVersion)")
            .font(.caption).foregroundStyle(Brand.muted)
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
    }

    private func refresh() async {
        link = .current
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifStatus = "acordată"
        case .denied: notifStatus = "refuzată — activează din Setări"
        default: notifStatus = "necerută"
        }
        let configs = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        installed = configs.map { Self.describe($0.family) }
    }

    static func describe(_ family: WidgetFamily) -> String {
        switch family {
        case .accessoryRectangular: return "ecran blocare (dreptunghi)"
        case .accessoryCircular: return "ecran blocare (cerc)"
        case .accessoryInline: return "ecran blocare (sub ceas)"
        case .systemSmall: return "ecran principal (mic)"
        case .systemMedium: return "ecran principal (mediu)"
        case .systemLarge: return "ecran principal (mare)"
        default: return "alt format"
        }
    }
}


// MARK: - Status

/// Bulina din listă: culoarea statusului, altfel culoarea notei, altfel gri.
struct StatusDot: View {
    let note: NoteMeta
    var size: CGFloat = 12

    private var color: Color {
        if let status = note.status { return status.color }
        if let hex = note.colorHex { return Color(hexString: hex) }
        return Brand.muted
    }

    private var glow: Color { note.status == nil ? Color.clear : color.opacity(0.6) }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow, radius: 4)
    }
}

struct StatusPill: View {
    let status: NoteStatus

    var body: some View {
        Label(status.label, systemImage: status.icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(status.color.opacity(0.16)))
    }
}

struct StatusMenu: View {
    let selected: NoteStatus?
    let onPick: (NoteStatus?) -> Void

    var body: some View {
        Menu {
            ForEach(NoteStatus.allCases) { s in
                Button { onPick(s) } label: {
                    Label { Text(selected == s ? "\(s.label) ✓" : s.label) } icon: { Image(uiImage: StatusMenu.icon(s)) }
                }
            }
            Button { onPick(nil) } label: {
                Label("Fără status", systemImage: selected == nil ? "checkmark" : "circle.slash")
            }
        } label: { Label("Status", systemImage: "flag") }
    }

    static func icon(_ s: NoteStatus) -> UIImage {
        (UIImage(systemName: s.icon) ?? UIImage())
            .withTintColor(UIColor(hexString: s.hex), renderingMode: .alwaysOriginal)
    }
}

/// Filtre rapide în folder: Toate · Problemă · În lucru · Gata.
struct StatusFilterBar: View {
    @EnvironmentObject var store: LibraryStore
    let notes: [NoteMeta]
    @Binding var selection: NoteStatus?
    @Binding var tagSelection: UUID?
    var showStatuses = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Toate", count: notes.count, color: Brand.accent, active: selection == nil && tagSelection == nil) {
                    selection = nil
                    tagSelection = nil
                }
                if showStatuses {
                    ForEach(NoteStatus.allCases) { s in statusChip(s) }
                }
                ForEach(store.tagDefs) { t in tagChip(t) }
            }
        }
    }

    @ViewBuilder private func statusChip(_ s: NoteStatus) -> some View {
        let count = notes.filter { $0.status == s }.count
        if count > 0 || selection == s {
            chip(s.label, count: count, color: s.color, active: selection == s) {
                selection = (selection == s) ? nil : s
            }
        }
    }

    @ViewBuilder private func tagChip(_ t: TagDef) -> some View {
        let count = notes.filter { $0.tagIDs.contains(t.id) }.count
        let title = "\(t.emoji) \(t.name)"
        if count > 0 || tagSelection == t.id {
            chip(title, count: count, color: t.color, active: tagSelection == t.id) {
                tagSelection = (tagSelection == t.id) ? nil : t.id
            }
        }
    }

    private func chip(_ title: String, count: Int, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.caption).foregroundStyle(Brand.muted)
            }
            .foregroundStyle(Brand.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? color.opacity(0.22) : Brand.surface))
            .overlay(Capsule().stroke(active ? color.opacity(0.7) : Brand.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ordinea manuală

struct ReorderSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let folderID: UUID?
    @State var items: [NoteMeta] = []

    var body: some View {
        NavigationStack {
            list
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
                .background(Brand.background)
                .navigationTitle("Aranjează ordinea")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .onAppear { loadItems() }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(items) { note in row(note) }
                    .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            } footer: {
                Text("Trage de mânere ca să schimbi ordinea. Notele fixate rămân sus.")
                    .foregroundStyle(Brand.muted)
            }
        }
    }

    private func row(_ note: NoteMeta) -> some View {
        HStack(spacing: 12) {
            StatusDot(note: note, size: 10)
            Text(note.displayTitle).foregroundStyle(Brand.text).lineLimit(1)
            Spacer()
            if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.accent) }
        }
        .listRowBackground(Brand.surface)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button("Salvează") {
                store.setManualOrder(items.map(\.id), for: folderID)
                dismiss()
            }
            .bold()
        }
        ToolbarItem(placement: .bottomBar) { presetMenu }
    }

    private var presetMenu: some View {
        Menu {
            Button("După titlu (1, 2, 3…)") { items.sort(by: Self.byTitle) }
            Button("După data creării") { items.sort { $0.created < $1.created } }
            Button("După status") {
                items.sort { ($0.status?.rank ?? NoteStatus.unsetRank) < ($1.status?.rank ?? NoteStatus.unsetRank) }
            }
        } label: { Label("Pornește de la…", systemImage: "wand.and.stars") }
    }

    nonisolated private static func byTitle(_ a: NoteMeta, _ b: NoteMeta) -> Bool {
        a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
    }

    private func loadItems() {
        guard items.isEmpty else { return }
        let current = store.notes(in: folderID)
        if store.sortMode(for: folderID) == .manual {
            items = current
        } else {
            items = current.sorted(by: Self.byTitle)
        }
    }
}


// MARK: - Drag & drop între note

/// Ții apăsat pe o notă și o tragi peste alta ca să schimbi ordinea.
struct NoteDrag: ViewModifier {
    let note: NoteMeta
    let enabled: Bool
    let cornerRadius: CGFloat
    @Binding var target: UUID?
    let onDrop: (UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(note.id.uuidString) {
                    Label(note.displayTitle, systemImage: "line.3.horizontal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Brand.surfaceHi))
                }
                .dropDestination(for: String.self) { items, _ in
                    defer { target = nil }
                    guard let raw = items.first, let id = UUID(uuidString: raw), id != note.id else { return false }
                    onDrop(id)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    return true
                } isTargeted: { hovering in
                    if hovering { target = note.id } else if target == note.id { target = nil }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Brand.accent, lineWidth: target == note.id ? 2 : 0)
                        .allowsHitTesting(false)
                )
                .animation(.easeOut(duration: 0.15), value: target)
        } else {
            content
        }
    }
}


// MARK: - Etichete

/// Emoji-urile etichetelor unei note (pe card și în listă).
struct TagEmojis: View {
    @EnvironmentObject var store: LibraryStore
    let note: NoteMeta
    var limit = 3

    var body: some View {
        let tags = store.tags(of: note)
        if !tags.isEmpty {
            HStack(spacing: 2) {
                ForEach(tags.prefix(limit)) { Text($0.emoji).font(.caption2) }
                if tags.count > limit {
                    Text("+\(tags.count - limit)").font(.caption2).foregroundStyle(Brand.muted)
                }
            }
        }
    }
}

/// Etichetele ca pastile cu nume (în editor).
struct TagChips: View {
    @EnvironmentObject var store: LibraryStore
    let note: NoteMeta

    var body: some View {
        let tags = store.tags(of: note)
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags) { t in
                        Text("\(t.emoji) \(t.name)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(t.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(t.color.opacity(0.16)))
                    }
                }
            }
        }
    }
}

/// Meniu cu bife: adaugă sau scoate etichete de pe o notă.
struct TagsMenu: View {
    @EnvironmentObject var store: LibraryStore
    let noteID: UUID

    var body: some View {
        let current = store.note(noteID)?.tagIDs ?? []
        Menu {
            ForEach(store.tagDefs) { t in
                Button { store.toggleTag(t.id, on: noteID) } label: {
                    if current.contains(t.id) {
                        Label("\(t.emoji) \(t.name)", systemImage: "checkmark")
                    } else {
                        Text("\(t.emoji) \(t.name)")
                    }
                }
            }
        } label: { Label("Etichete", systemImage: "tag") }
    }
}

/// Lista etichetelor: adaugă, redenumește, schimbă emoji/culoare, ordonează, șterge.
struct TagManagerSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State var editing: TagDef?
    @State var deleting: TagDef?

    var body: some View {
        NavigationStack {
            styledList
                .sheet(item: $editing) { TagEditorSheet(tag: $0) }
                .confirmationDialog(deleteTitle, isPresented: deletingBinding, titleVisibility: .visible) {
                    Button("Șterge eticheta", role: .destructive) { confirmDelete() }
                } message: { Text("Eticheta dispare de pe toate notele. Notele rămân.") }
        }
    }

    private var styledList: some View {
        list
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Etichete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.tagDefs) { t in row(t) }
                    .onMove { store.moveTags(from: $0, to: $1) }
            } footer: {
                Text("Atinge o etichetă ca s-o modifici. Glisează spre stânga ca s-o ștergi; notele nu se pierd.")
                    .foregroundStyle(Brand.muted)
            }
            .listRowBackground(Brand.surface)
        }
    }

    private func row(_ t: TagDef) -> some View {
        Button { editing = t } label: {
            HStack(spacing: 12) {
                Text(t.emoji).frame(width: 26)
                Text(t.name).foregroundStyle(Brand.text)
                Spacer()
                Circle().fill(t.color).frame(width: 12, height: 12)
                Text("\(store.tagCount(t.id))").font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .swipeActions {
            Button(role: .destructive) { deleting = t } label: { Label("Șterge", systemImage: "trash") }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { EditButton() }
        ToolbarItem(placement: .confirmationAction) { Button("Gata") { dismiss() }.bold() }
        ToolbarItem(placement: .bottomBar) {
            Button { editing = TagDef(name: "", emoji: "🏷️", colorHex: "59E0EF") } label: {
                Label("Etichetă nouă", systemImage: "plus.circle.fill")
            }
        }
    }

    private var deleteTitle: String { "Ștergi eticheta „\(deleting?.name ?? "")”?" }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func confirmDelete() {
        if let t = deleting { store.deleteTag(t.id) }
        deleting = nil
    }
}

struct TagEditorSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State var tag: TagDef

    static let emojis = ["🔥", "💡", "💬", "💪", "💀", "⏳", "🚀", "🐛", "💰", "📞", "📌", "⭐️",
                         "✅", "❗️", "🔒", "🎨", "🧪", "📦", "🧾", "👀", "🤝", "🏷️", "⚡️", "🧠"]

    private static let columns = Array(repeating: GridItem(.flexible()), count: 6)

    private var screenTitle: String { store.tag(tag.id) == nil ? "Etichetă nouă" : "Editează eticheta" }

    private var customEmoji: Binding<String> {
        Binding(get: { "" }, set: { if let c = $0.last { tag.emoji = String(c) } })
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                emojiSection
                colorSection
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
    }

    private var nameSection: some View {
        Section {
            HStack(spacing: 12) {
                Text(tag.emoji).font(.title)
                TextField("Nume etichetă", text: $tag.name).font(.title3.weight(.semibold))
            }
        }
        .listRowBackground(Brand.surface)
    }

    private var emojiSection: some View {
        Section("Emoji") {
            LazyVGrid(columns: Self.columns, spacing: 10) {
                ForEach(Self.emojis, id: \.self) { e in emojiCell(e) }
            }
            .padding(.vertical, 6)
            TextField("Sau scrie alt emoji", text: customEmoji)
        }
        .listRowBackground(Brand.surface)
    }

    private func emojiCell(_ e: String) -> some View {
        let fill: Color = tag.emoji == e ? tag.color.opacity(0.3) : Brand.surfaceHi
        return Text(e)
            .font(.title2)
            .frame(width: 42, height: 42)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .onTapGesture { tag.emoji = e }
    }

    private var colorSection: some View {
        Section("Culoare") {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(Brand.palette, id: \.hex) { item in colorCell(item.hex) }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Brand.surface)
    }

    private func colorCell(_ hex: String) -> some View {
        let ring: CGFloat = tag.colorHex == hex ? 3 : 0
        return Circle()
            .fill(Color(hexString: hex))
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(Brand.text, lineWidth: ring).padding(-4))
            .onTapGesture { tag.colorHex = hex }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button("Salvează") { save() }.bold()
        }
    }

    private func save() {
        var t = tag
        t.name = t.name.trimmingCharacters(in: .whitespaces)
        if t.name.isEmpty { t.name = "Etichetă" }
        store.saveTag(t)
        dismiss()
    }
}


/// Foile și dialogurile ecranului principal, separate ca să rămână ușor de compilat.
struct RootSheets: ViewModifier {
    @EnvironmentObject var store: LibraryStore
    @Binding var folderDraft: FolderDraft?
    @Binding var showTemplates: Bool
    @Binding var showDiagnostics: Bool
    @Binding var showImport: Bool
    @Binding var showTagManager: Bool
    @Binding var showSettings: Bool
    @Binding var deleting: Folder?

    func body(content: Content) -> some View {
        content
            .sheet(item: $folderDraft) { FolderEditorSheet(draft: $0) }
            .sheet(isPresented: $showTemplates) { TemplatePickerSheet(folderID: nil) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .importer(isPresented: $showImport, into: nil)
            .sheet(isPresented: $showTagManager) { TagManagerSheet() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog(deleteTitle, isPresented: deletingBinding, titleVisibility: .visible) {
                Button("Șterge folderul", role: .destructive) {
                    if let f = deleting { store.deleteFolder(f.id) }
                    deleting = nil
                }
            } message: { Text("Notele lui se mută în folderul părinte; nu se pierde nimic.") }
    }

    private var deleteTitle: String { "Ștergi folderul „\(deleting?.name ?? "")”?" }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}


// MARK: - Ecranul de proiect: rezumat, grupare pe status, schimbare rapidă

/// Meniu invizibil peste bulina / eticheta de status a unei note.
struct QuickStatusMenu: View {
    let current: NoteStatus?
    let onPick: (NoteStatus?) -> Void

    var body: some View {
        Menu {
            ForEach(NoteStatus.allCases) { s in
                Button { onPick(s) } label: { row(s) }
            }
            Divider()
            Button { onPick(nil) } label: { Label("Fără status", systemImage: "circle.slash") }
        } label: {
            Color.clear.contentShape(Rectangle())
        }
        .accessibilityLabel("Schimbă statusul")
    }

    private func row(_ s: NoteStatus) -> some View {
        Label {
            Text(current == s ? "\(s.label) ✓" : s.label)
        } icon: {
            Image(uiImage: StatusMenu.icon(s))
        }
    }
}

/// Rezumatul de sus al unui proiect: câte au rămas, bara de progres, filtre pe status.
struct ProjectSummary: View {
    let notes: [NoteMeta]
    @Binding var selection: NoteStatus?

    /// Bara se citește de la stânga la dreapta: ce e gata, apoi ce mai e de făcut.
    private static let barOrder: [NoteStatus] = [.done, .review, .progress, .problem, .todo]

    private func count(_ s: NoteStatus?) -> Int { notes.filter { $0.status == s }.count }
    private var remaining: Int { notes.count - count(.done) }
    private var donePercent: Int { notes.isEmpty ? 0 : Int((Double(count(.done)) / Double(notes.count) * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline.accessibilityElement(children: .combine)
            ProgressSegments(segments: segments, total: notes.count)
                .frame(height: 8)
                .accessibilityHidden(true)
            chips
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }

    private var segments: [ProgressSegments.Segment] {
        var list: [ProgressSegments.Segment] = []
        for s in Self.barOrder {
            let c = count(s)
            if c > 0 { list.append(.init(id: s.rawValue, color: s.color, count: c)) }
        }
        let unset = count(nil)
        if unset > 0 { list.append(.init(id: "none", color: Brand.line, count: unset)) }
        return list
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(remaining)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.text)
            Text(remaining == 1 ? "rămasă din \(notes.count)" : "rămase din \(notes.count)")
                .font(.subheadline)
                .foregroundStyle(Brand.muted)
            Spacer()
            Text("\(donePercent)% gata")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NoteStatus.done.color)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NoteStatus.allCases) { s in
                    let c = count(s)
                    if c > 0 || selection == s { chip(s, count: c) }
                }
            }
        }
    }

    private func chip(_ s: NoteStatus, count: Int) -> some View {
        let active = selection == s
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selection = active ? nil : s }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: s.icon).font(.caption).foregroundStyle(s.color)
                Text(s.label).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.text)
                Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(s.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(active ? s.color.opacity(0.22) : Brand.surfaceHi))
            .overlay(Capsule().stroke(active ? s.color.opacity(0.8) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Bară orizontală împărțită proporțional pe statusuri.
struct ProgressSegments: View {
    struct Segment: Identifiable {
        let id: String
        let color: Color
        let count: Int
    }

    let segments: [Segment]
    let total: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { seg in
                    Capsule().fill(seg.color).frame(width: width(seg, in: geo.size.width))
                }
            }
        }
        .clipShape(Capsule())
    }

    private func width(_ seg: Segment, in full: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let gaps = CGFloat(max(segments.count - 1, 0)) * 2
        let share = (full - gaps) * CGFloat(seg.count) / CGFloat(total)
        return max(3, share)
    }
}

/// Notele unui proiect grupate pe status, în ordinea în care cer atenție; „Gata” strânse la final.
struct StatusGroupedNotes: View {
    let notes: [NoteMeta]
    let grid: Bool
    @Binding var showDone: Bool

    private struct StatusGroup: Identifiable {
        let id: String
        let status: NoteStatus?
        let notes: [NoteMeta]
    }

    private var groups: [StatusGroup] {
        let order: [NoteStatus?] = [.problem, .progress, .review, .todo, nil, .done]
        var list: [StatusGroup] = []
        for s in order {
            let items = notes.filter { $0.status == s }
            if !items.isEmpty { list.append(StatusGroup(id: s?.rawValue ?? "none", status: s, notes: items)) }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { g in section(g) }
        }
    }

    @ViewBuilder private func section(_ g: StatusGroup) -> some View {
        let collapsible = g.status == .done
        VStack(alignment: .leading, spacing: 8) {
            header(g, collapsible: collapsible)
            if !collapsible || showDone {
                NotesCollection(notes: g.notes, grid: grid, showPath: false)
            }
        }
    }

    @ViewBuilder private func header(_ g: StatusGroup, collapsible: Bool) -> some View {
        if collapsible {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showDone.toggle() }
            } label: {
                headerLabel(g, toggleText: showDone ? "Ascunde" : "Arată")
            }
            .buttonStyle(.plain)
        } else {
            headerLabel(g, toggleText: nil)
        }
    }

    private func headerLabel(_ g: StatusGroup, toggleText: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: g.status?.icon ?? "circle")
                .foregroundStyle(g.status?.color ?? Brand.muted)
            Text((g.status?.label ?? "Fără status").uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(Brand.text)
            Text("\(g.notes.count)")
                .font(.caption)
                .foregroundStyle(Brand.muted)
            Spacer()
            if let toggleText {
                Text(toggleText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.accent)
            }
        }
        .contentShape(Rectangle())
    }
}


// MARK: - Setări

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage(AppearanceMode.storageKey) var appearance = AppearanceMode.system.rawValue

    private var mode: AppearanceMode { AppearanceMode(rawValue: appearance) ?? .system }

    var body: some View {
        NavigationStack {
            List {
                SyncSettingsSection()
                Section {
                    appearancePicker
                } header: {
                    sectionHeader("Aspect")
                } footer: {
                    Text(footer).foregroundStyle(Brand.muted)
                }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Setări")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Gata") { dismiss() }.bold() }
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: 10) {
            ForEach(AppearanceMode.allCases) { m in option(m) }
        }
        .padding(.vertical, 6)
    }

    private func option(_ m: AppearanceMode) -> some View {
        let active = m == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { appearance = m.rawValue }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: m.icon)
                    .font(.title2)
                    .foregroundStyle(active ? Brand.accent : Brand.muted)
                Text(m.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(active ? Brand.accent.opacity(0.15) : Brand.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Brand.accent : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var footer: String {
        switch mode {
        case .system: return "Urmează modul iPhone-ului: se schimbă singur când activezi modul întunecat sau la apus, dacă ai setat automat."
        case .light: return "Mereu luminos, indiferent de setarea iPhone-ului."
        case .dark: return "Mereu întunecat, indiferent de setarea iPhone-ului."
        }
    }
}
