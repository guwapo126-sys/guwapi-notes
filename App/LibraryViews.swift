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
    @State var deleting: Folder?

    var body: some View {
        NavigationStack(path: $router.path) {
            List {
                if search.isEmpty {
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
                        Button {
                            folderDraft = FolderDraft(folder: Folder(name: "", parentID: nil), isNew: true)
                        } label: {
                            Label("Folder nou", systemImage: "folder.badge.plus").foregroundStyle(Brand.accent)
                        }
                    } header: { sectionHeader("Clienți și foldere") }
                    .listRowBackground(Brand.surface)

                    Section {
                        ForEach(store.tagDefs) { tag in
                            NavigationLink(value: Route.tag(tag.id)) {
                                HStack(spacing: 12) {
                                    Text(tag.emoji).frame(width: 26)
                                    Text(tag.name).foregroundStyle(Brand.text)
                                    Spacer()
                                    Text("\(store.tagCount(tag.id))").font(.caption).foregroundStyle(Brand.muted)
                                }
                            }
                        }
                        Button { showTagManager = true } label: {
                            Label("Gestionează etichetele", systemImage: "tag").foregroundStyle(Brand.accent)
                        }
                    } header: { sectionHeader("Etichete") }
                    .listRowBackground(Brand.surface)
                } else {
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
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("guwapi notes")
            .searchable(text: $search, prompt: "Caută în toate notele")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { router.open(store.createNote(in: nil)) } label: {
                            Label("Notă nouă", systemImage: "square.and.pencil")
                        }
                        Button { showTemplates = true } label: {
                            Label("Din șablon…", systemImage: "doc.on.doc")
                        }
                        Button {
                            folderDraft = FolderDraft(folder: Folder(name: "", parentID: nil), isNew: true)
                        } label: { Label("Folder nou", systemImage: "folder.badge.plus") }
                        Button { showImport = true } label: {
                            Label("Importă fișiere sau folder…", systemImage: "square.and.arrow.down")
                        }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .folder(let id): FolderScreen(folderID: id)
                case .all: NotesScreen(title: "Toate notele", source: .all)
                case .tag(let id):
                    NotesScreen(title: store.tag(id).map { "\($0.emoji) \($0.name)" } ?? "Etichetă", source: .tag(id))
                case .note(let id): NoteEditorScreen(noteID: id)
                }
            }
            .sheet(item: $folderDraft) { FolderEditorSheet(draft: $0) }
            .sheet(isPresented: $showTemplates) { TemplatePickerSheet(folderID: nil) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .importer(isPresented: $showImport, into: nil)
            .sheet(isPresented: $showTagManager) { TagManagerSheet() }
            .confirmationDialog("Ștergi folderul „\(deleting?.name ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Șterge folderul", role: .destructive) {
                    if let f = deleting { store.deleteFolder(f.id) }
                    deleting = nil
                }
            } message: { Text("Notele lui se mută în folderul părinte; nu se pierde nimic.") }
            .task { _ = await Reminders.requestAuth() }
        }
    }

    @ViewBuilder private func folderMenu(_ folder: Folder) -> some View {
        Button { folderDraft = FolderDraft(folder: folder, isNew: false) } label: { Label("Editează", systemImage: "pencil") }
        Button {
            folderDraft = FolderDraft(folder: Folder(name: "", parentID: folder.id, colorHex: folder.colorHex), isNew: true)
        } label: { Label("Subfolder nou", systemImage: "folder.badge.plus") }
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
    @State var folderDropTarget: UUID?

    private var folder: Folder? { store.folder(folderID) }

    var body: some View {
        let subs = store.subfolders(of: folderID)
        let allNotes = store.notes(in: folderID)
        let notes = allNotes.filter { n in
            (statusFilter == nil || n.status == statusFilter) && (tagFilter.map { n.tagIDs.contains($0) } ?? true)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let folder, folder.parentID != nil {
                    Text(store.path(of: folder.parentID))
                        .font(.caption).foregroundStyle(Brand.muted)
                }
                if !subs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(subs) { sub in
                            NavigationLink(value: Route.folder(sub.id)) {
                                FolderRow(folder: sub)
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { folderDraft = FolderDraft(folder: sub, isNew: false) } label: {
                                    Label("Editează", systemImage: "pencil")
                                }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                                store.move(id, to: sub.id)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                return true
                            } isTargeted: { hovering in
                                folderDropTarget = hovering ? sub.id : (folderDropTarget == sub.id ? nil : folderDropTarget)
                            }
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(folderDropTarget == sub.id ? Brand.accent.opacity(0.18) : Color.clear))
                            if sub.id != subs.last?.id { Divider().overlay(Brand.line).padding(.leading, 52) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
                }
                if !allNotes.isEmpty {
                    StatusFilterBar(notes: allNotes, selection: $statusFilter, tagSelection: $tagFilter)
                }
                if allNotes.isEmpty && subs.isEmpty {
                    EmptyState(text: "Folder gol. Adaugă o notă sau un subfolder din butonul +.")
                } else if notes.isEmpty && (statusFilter != nil || tagFilter != nil) {
                    EmptyState(text: "Nicio notă cu acest filtru.")
                } else {
                    NotesCollection(notes: notes, grid: grid, showPath: false)
                }
            }
            .padding(16)
        }
        .background(Brand.background)
        .navigationTitle(folder?.name ?? "Note rapide")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sortare", selection: Binding(get: { store.sortMode(for: folderID) },
                                                         set: { store.setSortMode($0, for: folderID) })) {
                        ForEach(SortMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    Divider()
                    Button { showReorder = true } label: { Label("Aranjează ordinea…", systemImage: "line.3.horizontal") }
                    Divider()
                    Button { grid.toggle() } label: {
                        Label(grid ? "Vezi ca listă" : "Vezi ca grilă", systemImage: grid ? "list.bullet" : "square.grid.2x2")
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                Menu {
                    Button { router.open(store.createNote(in: folderID, colorHex: nil)) } label: {
                        Label("Notă nouă", systemImage: "square.and.pencil")
                    }
                    Button { showTemplates = true } label: { Label("Din șablon…", systemImage: "doc.on.doc") }
                    Button { showImport = true } label: {
                        Label("Importă fișiere sau folder…", systemImage: "square.and.arrow.down")
                    }
                    if let folder {
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
                } label: { Image(systemName: "plus.circle.fill").font(.title3) }
            }
        }
        .sheet(item: $folderDraft) { FolderEditorSheet(draft: $0) }
        .sheet(isPresented: $showTemplates) { TemplatePickerSheet(folderID: folderID) }
        .importer(isPresented: $showImport, into: folderID)
        .sheet(isPresented: $showReorder) { ReorderSheet(folderID: folderID) }
        .confirmationDialog("Ștergi folderul?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Șterge folderul", role: .destructive) {
                if let id = folderID { store.deleteFolder(id) }
                dismiss()
            }
        } message: { Text("Notele și subfolderele lui se mută în folderul părinte.") }
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
        Group {
            if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
                    ForEach(notes) { note in
                        NavigationLink(value: Route.note(note.id)) { NoteCard(note: note, showPath: showPath) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(note) }
                            .modifier(NoteDrag(note: note, enabled: !showPath, cornerRadius: 16, target: $dropTarget) {
                                store.moveNote($0, onto: note.id)
                            })
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(notes) { note in
                        NavigationLink(value: Route.note(note.id)) {
                            NoteListRow(note: note, showPath: showPath)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(note) }
                        .modifier(NoteDrag(note: note, enabled: !showPath, cornerRadius: 10, target: $dropTarget) {
                            store.moveNote($0, onto: note.id)
                        })
                        if note.id != notes.last?.id { Divider().overlay(Brand.line).padding(.leading, 36) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
            }
        }
        .sheet(item: $moving) { note in
            FolderPickerSheet(title: "Mută nota", current: note.folderID) { store.move(note.id, to: $0) }
        }
        .confirmationDialog("Ștergi nota „\(deleting?.displayTitle ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Șterge", role: .destructive) {
                if let n = deleting { store.deleteNote(n.id) }
                deleting = nil
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
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
            HStack(spacing: 6) {
                Text(note.updated, format: .relative(presentation: .named))
                Spacer(minLength: 0)
                TagEmojis(note: note, limit: 3)
            }
            .font(.caption2)
            .foregroundStyle(Brand.muted)
            .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Brand.surface)
                .overlay(RoundedRectangle(cornerRadius: 16).fill(note.colorHex == nil ? Color.clear : color.opacity(0.13)))
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(note.colorHex == nil ? Brand.line : color.opacity(0.55), lineWidth: 1))
    }
}

struct NoteListRow: View {
    @EnvironmentObject var store: LibraryStore
    let note: NoteMeta
    var showPath = false

    var body: some View {
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
    private let isNew: Bool

    static let icons = [
        "folder.fill", "briefcase.fill", "person.fill", "person.2.fill", "building.2.fill", "app.fill",
        "iphone", "globe", "server.rack", "cart.fill", "shield.fill", "lock.fill",
        "star.fill", "bolt.fill", "hammer.fill", "doc.text.fill", "chart.bar.fill", "lightbulb.fill"
    ]

    init(draft: FolderDraft) {
        _folder = State(initialValue: draft.folder)
        isNew = draft.isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: folder.icon)
                            .font(.title2)
                            .foregroundStyle(Color(hexString: folder.colorHex))
                            .frame(width: 36)
                        TextField("Nume (ex: client, aplicație)", text: $folder.name)
                            .font(.title3.weight(.semibold))
                    }
                    if let parent = folder.parentID {
                        Text("În: \(store.path(of: parent))").font(.caption).foregroundStyle(Brand.muted)
                    }
                }
                .listRowBackground(Brand.surface)

                Section("Culoare") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Brand.palette, id: \.hex) { item in
                            Circle()
                                .fill(Color(hexString: item.hex))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Brand.text, lineWidth: folder.colorHex == item.hex ? 3 : 0).padding(-4))
                                .onTapGesture { folder.colorHex = item.hex }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Brand.surface)

                Section("Iconiță") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .foregroundStyle(folder.icon == icon ? Brand.background : Color(hexString: folder.colorHex))
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(folder.icon == icon ? Color(hexString: folder.colorHex) : Brand.surfaceHi))
                                .onTapGesture { folder.icon = icon }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(isNew ? "Folder nou" : "Editează folderul")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvează") {
                        let name = folder.name.trimmingCharacters(in: .whitespaces)
                        if isNew {
                            store.createFolder(name: name, parent: folder.parentID, colorHex: folder.colorHex, icon: folder.icon)
                        } else {
                            var f = folder
                            f.name = name.isEmpty ? "Folder" : name
                            store.updateFolder(f)
                        }
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.large])
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

    var body: some View {
        NavigationStack {
            List {
                Section("Legătura app ↔ widget") {
                    if let id = AppGroup.resolvedID {
                        Label("OK — \(id)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("LIPSĂ — widgetul nu poate citi notele", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                .listRowBackground(Brand.surface)

                Section("Notificări") {
                    Text("Permisiune: \(notifStatus)")
                    Button("Trimite notificare de test în 10 s") { Reminders.test() }
                }
                .listRowBackground(Brand.surface)

                Section("Date") {
                    Text("\(store.notes.count) note · \(store.folders.count) foldere")
                    Button("Reîncarcă widgeturile") { WidgetCenter.shared.reloadAllTimelines() }
                    Text("Versiune \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Diagnostic")
            .toolbar { Button("Gata") { dismiss() } }
            .task {
                let s = await UNUserNotificationCenter.current().notificationSettings()
                switch s.authorizationStatus {
                case .authorized, .provisional, .ephemeral: notifStatus = "acordată"
                case .denied: notifStatus = "refuzată — activează din Setări"
                default: notifStatus = "necerută"
                }
            }
        }
    }
}


// MARK: - Status

/// Bulina din listă: culoarea statusului, altfel culoarea notei, altfel gri.
struct StatusDot: View {
    let note: NoteMeta
    var size: CGFloat = 12

    var body: some View {
        let color = note.status?.color ?? note.colorHex.map { Color(hexString: $0) } ?? Brand.muted
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: note.status == nil ? .clear : color.opacity(0.6), radius: 4)
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Toate", count: notes.count, color: Brand.accent, active: selection == nil && tagSelection == nil) {
                    selection = nil
                    tagSelection = nil
                }
                ForEach(NoteStatus.allCases) { s in
                    let count = notes.filter { $0.status == s }.count
                    if count > 0 || selection == s {
                        chip(s.label, count: count, color: s.color, active: selection == s) {
                            selection = selection == s ? nil : s
                        }
                    }
                }
                ForEach(store.tagDefs) { t in
                    let count = notes.filter { $0.tagIDs.contains(t.id) }.count
                    if count > 0 || tagSelection == t.id {
                        chip("\(t.emoji) \(t.name)", count: count, color: t.color, active: tagSelection == t.id) {
                            tagSelection = tagSelection == t.id ? nil : t.id
                        }
                    }
                }
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
            List {
                Section {
                    ForEach(items) { note in
                        HStack(spacing: 12) {
                            StatusDot(note: note, size: 10)
                            Text(note.displayTitle).foregroundStyle(Brand.text).lineLimit(1)
                            Spacer()
                            if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.accent) }
                        }
                        .listRowBackground(Brand.surface)
                    }
                    .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text("Trage de mânere ca să schimbi ordinea. Notele fixate rămân sus.")
                        .foregroundStyle(Brand.muted)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Aranjează ordinea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvează") {
                        store.setManualOrder(items.map(\.id), for: folderID)
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("După titlu (1, 2, 3…)") {
                            items.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
                        }
                        Button("După data creării") { items.sort { $0.created < $1.created } }
                        Button("După status") {
                            items.sort { ($0.status?.rank ?? 2) < ($1.status?.rank ?? 2) }
                        }
                    } label: { Label("Pornește de la…", systemImage: "wand.and.stars") }
                }
            }
            .onAppear {
                if items.isEmpty {
                    let current = store.notes(in: folderID)
                    items = store.sortMode(for: folderID) == .manual
                        ? current
                        : current.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
                }
            }
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
            List {
                Section {
                    ForEach(store.tagDefs) { t in
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
                    .onMove { store.moveTags(from: $0, to: $1) }
                } footer: {
                    Text("Atinge o etichetă ca s-o modifici. Glisează spre stânga ca s-o ștergi; notele nu se pierd.")
                        .foregroundStyle(Brand.muted)
                }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Etichete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Gata") { dismiss() }.bold() }
                ToolbarItem(placement: .bottomBar) {
                    Button { editing = TagDef(name: "", emoji: "🏷️", colorHex: "59E0EF") } label: {
                        Label("Etichetă nouă", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(item: $editing) { TagEditorSheet(tag: $0) }
            .confirmationDialog("Ștergi eticheta „\(deleting?.name ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Șterge eticheta", role: .destructive) {
                    if let t = deleting { store.deleteTag(t.id) }
                    deleting = nil
                }
            } message: { Text("Eticheta dispare de pe toate notele. Notele rămân.") }
        }
    }
}

struct TagEditorSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State var tag: TagDef

    static let emojis = ["🔥", "💡", "💬", "💪", "💀", "⏳", "🚀", "🐛", "💰", "📞", "📌", "⭐️",
                         "✅", "❗️", "🔒", "🎨", "🧪", "📦", "🧾", "👀", "🤝", "🏷️", "⚡️", "🧠"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Text(tag.emoji).font(.title)
                        TextField("Nume etichetă", text: $tag.name).font(.title3.weight(.semibold))
                    }
                }
                .listRowBackground(Brand.surface)

                Section("Emoji") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(Self.emojis, id: \.self) { e in
                            Text(e)
                                .font(.title2)
                                .frame(width: 42, height: 42)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(tag.emoji == e ? tag.color.opacity(0.3) : Brand.surfaceHi))
                                .onTapGesture { tag.emoji = e }
                        }
                    }
                    .padding(.vertical, 6)
                    TextField("Sau scrie alt emoji", text: Binding(
                        get: { "" },
                        set: { if let c = $0.last { tag.emoji = String(c) } }
                    ))
                }
                .listRowBackground(Brand.surface)

                Section("Culoare") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Brand.palette, id: \.hex) { item in
                            Circle()
                                .fill(Color(hexString: item.hex))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Brand.text, lineWidth: tag.colorHex == item.hex ? 3 : 0).padding(-4))
                                .onTapGesture { tag.colorHex = item.hex }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(store.tag(tag.id) == nil ? "Etichetă nouă" : "Editează eticheta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvează") {
                        var t = tag
                        t.name = t.name.trimmingCharacters(in: .whitespaces)
                        if t.name.isEmpty { t.name = "Etichetă" }
                        store.saveTag(t)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}
