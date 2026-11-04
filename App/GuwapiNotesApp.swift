import SwiftUI
import UserNotifications

@main
struct GuwapiNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var store = LibraryStore()
    @StateObject var router = Router.shared
    @State var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if showSplash {
                    SplashView().transition(.opacity).zIndex(1)
                }
            }
            .environmentObject(store)
            .environmentObject(router)
            .preferredColorScheme(.dark)
            .tint(Brand.accent)
            .onOpenURL { router.handle($0) }
            .task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
            }
        }
    }
}

/// Continuarea ecranului de lansare iOS: scutul guwapi se micșorează și dispare.
struct SplashView: View {
    @State var settle = false

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .scaleEffect(settle ? 0.92 : 1)
                .shadow(color: Brand.accent.opacity(settle ? 0.45 : 0.15), radius: settle ? 24 : 8)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.5)) { settle = true } }
    }
}

// MARK: - Navigare (widget, notificări, linkuri)

enum Route: Hashable {
    case folder(UUID?)
    case all
    case tag(UUID)
    case note(UUID)
}

@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var path: [Route] = []

    func open(_ id: UUID) {
        if case .note(let current)? = path.last, current == id { return }
        path.append(.note(id))
    }

    /// guwapinotes://note/<uuid>
    func handle(_ url: URL) {
        guard url.scheme == "guwapinotes", url.host == "note",
              let id = UUID(uuidString: url.lastPathComponent) else { return }
        path = [.note(id)]
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
        await MainActor.run { Router.shared.path = [.note(id)] }
    }
}
