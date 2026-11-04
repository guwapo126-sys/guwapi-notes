import SwiftUI
import UserNotifications
import WidgetKit

// MARK: - Lista de note, grupate pe client

struct ContentView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var router: Router
    @State private var editing: Note?
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                if model.notes.isEmpty {
                    Text("Nicio notă încă. Apasă pe creion ca să adaugi una.")
                        .foregroundStyle(Brand.muted)
                        .listRowBackground(Brand.surface)
                }
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.notes) { note in
                            Button { editing = note } label: { NoteRow(note: note) }
                                .listRowBackground(Brand.surface)
                        }
                        .onDelete { offsets in
                            for i in offsets { model.delete(group.notes[i].id) }
                        }
                    } header: {
                        Text(group.id.uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(Brand.muted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle("guwapi notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Note() } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(item: $editing) { NoteEditorView(note: $0) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .onChange(of: router.openNoteID) { _, id in
                guard let id, let note = model.notes.first(where: { $0.id == id }) else { return }
                editing = note
                router.openNoteID = nil
            }
            .task { _ = await Reminders.requestAuth() }
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Brand.accent) }
                Text(note.title.isEmpty ? "Fără titlu" : note.title)
                    .font(.headline)
                    .foregroundStyle(Brand.text)
                    .lineLimit(1)
            }
            if !note.body.isEmpty {
                Text(note.body).font(.subheadline).foregroundStyle(Brand.muted).lineLimit(2)
            }
            if let r = note.reminder, r > Date() {
                Label(r.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.accent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor (versiunea de test: text simplu; editorul formatat vine în build-ul complet)

struct NoteEditorView: View {
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var note: Note
    @State private var hasReminder: Bool

    init(note: Note) {
        _note = State(initialValue: note)
        _hasReminder = State(initialValue: note.reminder != nil)
    }

    private var reminderBinding: Binding<Date> {
        Binding(get: { note.reminder ?? Date().addingTimeInterval(3600) },
                set: { note.reminder = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titlu", text: $note.title).font(.title3.bold())
                    TextField("Client / aplicație", text: $note.client)
                }
                .listRowBackground(Brand.surface)

                Section("Conținut") {
                    TextEditor(text: $note.body).frame(minHeight: 220)
                }
                .listRowBackground(Brand.surface)

                Section("Widget și reminder") {
                    Toggle("Fixează pe ecranul de blocare", isOn: $note.pinned)
                    Toggle("Reminder", isOn: $hasReminder.animation())
                    if hasReminder {
                        DatePicker("Când", selection: reminderBinding, in: Date()...)
                    }
                }
                .listRowBackground(Brand.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .navigationTitle(note.title.isEmpty ? "Notă nouă" : note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anulează") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvează") {
                        if !hasReminder { note.reminder = nil }
                        else if note.reminder == nil { note.reminder = Date().addingTimeInterval(3600) }
                        model.upsert(note)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

// MARK: - Diagnostic: confirmă dacă sideload-ul a păstrat App Group-ul și notificările

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notifStatus = "…"

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
                    ForEach(AppGroup.candidates(), id: \.self) {
                        Text($0).font(.caption.monospaced()).foregroundStyle(Brand.muted)
                    }
                }
                .listRowBackground(Brand.surface)

                Section("Notificări") {
                    Text("Permisiune: \(notifStatus)")
                    Button("Trimite notificare de test în 10 s") { Reminders.test() }
                }
                .listRowBackground(Brand.surface)

                Section("Widget") {
                    Button("Reîncarcă widgeturile") { WidgetCenter.shared.reloadAllTimelines() }
                    Text("Bundle: \(Bundle.main.bundleIdentifier ?? "-")")
                        .font(.caption.monospaced()).foregroundStyle(Brand.muted)
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
