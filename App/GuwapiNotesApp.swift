import SwiftUI
import UserNotifications
import WidgetKit

@main
struct GuwapiNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = NotesModel()
    @StateObject private var router = Router.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Brand.accent)
                .onOpenURL { router.handle($0) }
        }
    }
}

// MARK: - Navigare din widget / notificare

@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var openNoteID: UUID?

    /// guwapinotes://note/<uuid>
    func handle(_ url: URL) {
        guard url.scheme == "guwapinotes", url.host == "note" else { return }
        openNoteID = UUID(uuidString: url.lastPathComponent)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["noteID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { Router.shared.openNoteID = id }
    }
}

// MARK: - Model

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [Note] = NoteFile.load()

    struct ClientGroup: Identifiable {
        let id: String
        let notes: [Note]
    }

    var groups: [ClientGroup] {
        Dictionary(grouping: notes) { $0.client.trimmingCharacters(in: .whitespaces).isEmpty ? "Fără client" : $0.client }
            .map { ClientGroup(id: $0.key, notes: $0.value.sorted { $0.updated > $1.updated }) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    func upsert(_ input: Note) {
        var note = input
        note.updated = Date()
        if note.pinned {
            for i in notes.indices where notes[i].id != note.id { notes[i].pinned = false }
        }
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            notes.insert(note, at: 0)
        }
        Reminders.schedule(note)
        persist()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        Reminders.cancel(id)
        persist()
    }

    private func persist() {
        NoteFile.save(notes)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Remindere (notificări locale, fără cont plătit)

enum Reminders {
    static func requestAuth() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func schedule(_ note: Note) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [note.id.uuidString])
        guard let date = note.reminder, date > Date() else { return }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: note.id.uuidString, content: content(for: note), trigger: trigger))
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    static func test() {
        var note = Note(title: "Test guwapi", body: "Notificările funcționează.")
        note.client = "Diagnostic"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "guwapi.test", content: content(for: note), trigger: trigger))
    }

    private static func content(for note: Note) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = note.title.isEmpty ? "Notă" : note.title
        c.subtitle = note.client
        c.body = String(note.body.prefix(160))
        c.sound = .default
        c.userInfo = ["noteID": note.id.uuidString]
        return c
    }
}
