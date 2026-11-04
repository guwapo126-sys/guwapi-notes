import PhotosUI
import SwiftUI

struct NoteEditorScreen: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let noteID: UUID

    @StateObject var controller = EditorController()
    @State var initial: NSAttributedString?
    @State var focusOnOpen = false
    @State var photoItem: PhotosPickerItem?
    @State var scannedPages: [UIImage] = []
    @State var showScanReview = false
    @State var showReminder = false
    @State var showMove = false
    @State var showTemplateName = false
    @State var templateName = ""
    @State var confirmDelete = false
    @State var shareItem: ShareItem?
    @State var isOCRRunning = false
    @State var deleted = false

    private var meta: NoteMeta? { store.note(noteID) }
    private var tint: Color { meta?.colorHex.map { Color(hexString: $0) } ?? Brand.accent }
    private var gradientColors: [Color] {
        let strength: Double = meta?.colorHex == nil ? 0 : 0.16
        return [tint.opacity(strength), Color.clear]
    }

    var body: some View {
        withMedia
            .sheet(isPresented: $showReminder) {
                if let meta { ReminderSheet(meta: meta) }
            }
            .sheet(isPresented: $showMove) {
                FolderPickerSheet(title: "Mută nota", current: meta?.folderID) { store.move(noteID, to: $0) }
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
            .alert("Salvează ca șablon", isPresented: $showTemplateName) {
                TextField("Nume șablon", text: $templateName)
                Button("Salvează") { saveTemplate() }
                Button("Anulează", role: .cancel) { templateName = "" }
            }
            .confirmationDialog("Ștergi nota?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Șterge", role: .destructive) { deleteNote() }
            }
    }

    /// Ecranul de bază + galerie, scaner și previzualizarea scanării.
    private var withMedia: some View {
        mainContent
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear { load() }
            .onDisappear { close() }
            .photosPicker(isPresented: $controller.showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in handlePhoto(item) }
            .fullScreenCover(isPresented: $controller.showScanner) { scannerCover }
            .sheet(isPresented: $showScanReview, onDismiss: { scannedPages = [] }) { scanReview }
    }

    @ViewBuilder private var scannerCover: some View {
        if DocumentScanner.isAvailable {
            DocumentScanner { pages in handleScan(pages) }
                .ignoresSafeArea()
        } else {
            VStack(spacing: 16) {
                Text("Scanarea nu e disponibilă pe acest dispozitiv.")
                Button("Închide") { controller.showScanner = false }
            }
        }
    }

    private var scanReview: some View {
        ScanReviewSheet(pages: scannedPages) { blocks, includeImages, mode in
            insertScan(blocks, includeImages: includeImages, mode: mode)
        }
    }

    @ViewBuilder private var mainContent: some View {
        if meta == nil && !deleted && initial == nil {
            EmptyState(text: "Nota nu mai există.")
        } else {
            ZStack(alignment: .top) {
                Brand.background.ignoresSafeArea()
                LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if let initial { editorStack(initial) }
                if isOCRRunning { ocrProgress }
            }
        }
    }

    private func editorStack(_ text: NSAttributedString) -> some View {
        VStack(spacing: 0) {
            if let meta, !meta.tagIDs.isEmpty {
                TagChips(note: meta)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            RichTextView(initial: text, controller: controller, focusOnAppear: focusOnOpen)
        }
    }

    private var ocrProgress: some View {
        ProgressView("Extrag textul…")
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.surfaceHi))
            .padding(.top, 40)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) { folderButton }
        ToolbarItemGroup(placement: .topBarTrailing) {
            statusMenu
            Button { showReminder = true } label: {
                Image(systemName: hasReminder ? "bell.badge.fill" : "bell")
            }
            Menu { noteMenu } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private var hasReminder: Bool { (meta?.reminder ?? .distantPast) > Date() }

    private var folderButton: some View {
        Button { showMove = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.caption)
                Text(store.path(of: meta?.folderID)).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(Brand.muted)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(NoteStatus.allCases) { s in
                Button { store.setStatus(noteID, s) } label: {
                    Label { Text(s.label) } icon: { Image(uiImage: StatusMenu.icon(s)) }
                }
            }
            Button { store.setStatus(noteID, nil) } label: { Label("Fără status", systemImage: "circle.slash") }
        } label: {
            Image(systemName: meta?.status?.icon ?? "flag")
                .foregroundStyle(meta?.status?.color ?? Brand.text)
        }
    }

    @ViewBuilder private var noteMenu: some View {
        Button { store.togglePin(noteID) } label: {
            Label(meta?.pinned == true ? "Anulează fixarea" : "Fixează sus (și pe widget)",
                  systemImage: meta?.pinned == true ? "pin.slash" : "pin")
        }
        TagsMenu(noteID: noteID)
        ColorMenu(selected: meta?.colorHex) { store.setColor(noteID, $0) }
        Button { showMove = true } label: { Label("Mută în folder…", systemImage: "folder") }
        Button { showReminder = true } label: { Label("Reminder…", systemImage: "bell") }
        Divider()
        Button { export(markdown: true) } label: { Label("Exportă Markdown", systemImage: "doc.plaintext") }
        Button { export(markdown: false) } label: { Label("Exportă PDF", systemImage: "doc.richtext") }
        Button {
            templateName = meta?.title ?? ""
            showTemplateName = true
        } label: { Label("Salvează ca șablon", systemImage: "doc.badge.plus") }
        Divider()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Șterge nota", systemImage: "trash") }
    }

    // MARK: Acțiuni

    private func handlePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                controller.insertImage(image)
            }
            photoItem = nil
        }
    }

    private func handleScan(_ pages: [UIImage]) {
        controller.showScanner = false
        if !pages.isEmpty {
            scannedPages = pages
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showScanReview = true }
        }
    }

    private func insertScan(_ blocks: [OCRBlock], includeImages: Bool, mode: UnclearMode) {
        if includeImages { for p in scannedPages { controller.insertImage(p) } }
        controller.insertBlocks(blocks, unclear: mode)
    }

    private func saveTemplate() {
        store.saveTemplate(name: templateName, body: controller.currentText)
        templateName = ""
    }

    private func deleteNote() {
        deleted = true
        store.deleteNote(noteID)
        dismiss()
    }

    private func load() {
        guard initial == nil, meta != nil else { return }
        let body = store.loadBody(noteID)
        focusOnOpen = body.length == 0
        controller.save = { text in
            guard !deleted else { return }
            store.saveBody(noteID, text)
        }
        initial = body
    }

    private func close() {
        guard !deleted, initial != nil else { return }
        // Scanerul / galeria pot ascunde ecranul temporar: nu închidem nota atunci.
        if controller.showScanner || controller.showPhotoPicker { return }
        let text = controller.currentText
        if store.isEmptyBody(text) {
            deleted = true
            store.deleteNote(noteID)
        } else {
            controller.flush()
        }
    }

    private func export(markdown: Bool) {
        controller.flush()
        let text = controller.currentText
        let base = (meta?.title.isEmpty == false ? meta!.title : "nota")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(base + (markdown ? ".md" : ".pdf"))
        let data = markdown ? Data(RT.markdown(text).utf8) : RT.pdf(text)
        do {
            try data.write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {}
    }
}

// MARK: - Reminder

struct ReminderSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let meta: NoteMeta
    @State var date = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Când", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                }
                .listRowBackground(Brand.surface)
                Section {
                    HStack {
                        quick("Peste 1 oră", Date().addingTimeInterval(3600))
                        quick("Diseară 20:00", Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()))
                        quick("Mâine 9:00", Calendar.current.date(byAdding: .day, value: 1,
                              to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()))
                    }
                }
                .listRowBackground(Brand.surface)
                if meta.reminder != nil {
                    Section {
                        Button("Șterge reminderul", role: .destructive) {
                            var m = meta
                            m.reminder = nil
                            store.update(m)
                            dismiss()
                        }
                    }
                    .listRowBackground(Brand.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Setează") {
                        var m = meta
                        m.reminder = date
                        store.update(m)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                if let r = meta.reminder, r > Date() { date = r }
            }
        }
    }

    private func quick(_ title: String, _ value: Date?) -> some View {
        Button(title) { if let value, value > Date() { date = value } }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled((value ?? .distantPast) <= Date())
    }
}

// MARK: - Partajare

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
