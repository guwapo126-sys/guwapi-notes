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

    var body: some View {
        Group {
            if meta == nil && !deleted && initial == nil {
                EmptyState(text: "Nota nu mai există.")
            } else {
                ZStack(alignment: .top) {
                    Brand.background.ignoresSafeArea()
                    LinearGradient(colors: [tint.opacity(meta?.colorHex == nil ? 0 : 0.16), .clear],
                                   startPoint: .top, endPoint: .center)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    if let initial {
                        RichTextView(initial: initial, controller: controller, focusOnAppear: focusOnOpen)
                    }
                    if isOCRRunning {
                        ProgressView("Extrag textul…")
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.surfaceHi))
                            .padding(.top, 40)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showMove = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.caption)
                        Text(store.path(of: meta?.folderID)).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(Brand.muted)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showReminder = true } label: {
                    Image(systemName: (meta?.reminder ?? .distantPast) > Date() ? "bell.badge.fill" : "bell")
                }
                Menu { noteMenu } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { load() }
        .onDisappear { close() }
        .photosPicker(isPresented: $controller.showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    controller.insertImage(image)
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $controller.showScanner) {
            if DocumentScanner.isAvailable {
                DocumentScanner { pages in
                    controller.showScanner = false
                    if !pages.isEmpty {
                        scannedPages = pages
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showScanReview = true }
                    }
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Text("Scanarea nu e disponibilă pe acest dispozitiv.")
                    Button("Închide") { controller.showScanner = false }
                }
            }
        }
        .sheet(isPresented: $showScanReview, onDismiss: { scannedPages = [] }) {
            ScanReviewSheet(pages: scannedPages) { blocks, includeImages, mode in
                if includeImages { for p in scannedPages { controller.insertImage(p) } }
                controller.insertBlocks(blocks, unclear: mode)
            }
        }
        .sheet(isPresented: $showReminder) {
            if let meta { ReminderSheet(meta: meta) }
        }
        .sheet(isPresented: $showMove) {
            FolderPickerSheet(title: "Mută nota", current: meta?.folderID) { store.move(noteID, to: $0) }
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .alert("Salvează ca șablon", isPresented: $showTemplateName) {
            TextField("Nume șablon", text: $templateName)
            Button("Salvează") {
                store.saveTemplate(name: templateName, body: controller.currentText)
                templateName = ""
            }
            Button("Anulează", role: .cancel) { templateName = "" }
        }
        .confirmationDialog("Ștergi nota?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Șterge", role: .destructive) {
                deleted = true
                store.deleteNote(noteID)
                dismiss()
            }
        }
    }

    @ViewBuilder private var noteMenu: some View {
        Button { store.togglePin(noteID) } label: {
            Label(meta?.pinned == true ? "Anulează fixarea" : "Fixează sus (și pe widget)",
                  systemImage: meta?.pinned == true ? "pin.slash" : "pin")
        }
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
