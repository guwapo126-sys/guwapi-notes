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

                    if !store.allTags.isEmpty {
                        Section {
                            ForEach(store.allTags, id: \.tag) { item in
                                NavigationLink(value: Route.tag(item.tag)) {
                                    HStack {
                                        Text("#\(item.tag)").foregroundStyle(Brand.text)
                                        Spacer()
                                        Text("\(item.count)").font(.caption).foregroundStyle(Brand.muted)
                                    }
                                }
                            }
                        } header: { sectionHeader("Etichete") }
                        .listRowBackground(Brand.surface)
                    }
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
                case .tag(let tag): NotesScreen(title: "#\(tag)", source: .tag(tag))
                case .note(let id): NoteEditorScreen(noteID: id)
                }
            }
            .sheet(item: $folderDraft) { FolderEditorSheet(draft: $0) }
            .sheet(isPresented: $showTemplates) { TemplatePickerSheet(folderID: nil) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .importer(isPresented: $showImport, into: nil)
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

    private var folder: Folder? { store.folder(folderID) }

    var body: some View {
        let subs = store.subfolders(of: folderID)
        let notes = store.notes(in: folderID)
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
                            if sub.id != subs.last?.id { Divider().overlay(Brand.line).padding(.leading, 52) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.surface))
                }
                if notes.isEmpty && subs.isEmpty {
                    EmptyState(text: "Folder gol. Adaugă o notă sau un subfolder din butonul +.")
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
    enum Source { case all, tag(String) }

    @EnvironmentObject var store: LibraryStore
    @AppStorage("notesGridMode") var grid = true
    let title: String
    let source: Source

    var body: some View {
        let notes: [NoteMeta] = {
            switch source {
            case .all: return store.allNotes
            case .tag(let t): return store.notes(tag: t)
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

    var body: some View {
        Group {
            if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
                    ForEach(notes) { note in
                        NavigationLink(value: Route.note(note.id)) { NoteCard(note: note, showPath: showPath) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(note) }
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
                Circle().fill(color).frame(width: 8, height: 8)
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
                ForEach(note.tags.prefix(2), id: \.self) { Text("#\($0)").foregroundStyle(color) }
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
            Circle()
                .fill(note.colorHex.map { Color(hexString: $0) } ?? Brand.muted)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
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
                Text(note.updated, format: .dateTime.day().month(.abbreviated))
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
