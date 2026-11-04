import AppIntents

/// Deschide aplicația — folosit de butonul guwapi de pe ecranul de blocare și din Centrul de control.
struct OpenGuwapiIntent: AppIntent {
    static var title: LocalizedStringResource { "Deschide guwapi notes" }
    static var description: IntentDescription { IntentDescription("Deschide aplicația guwapi notes.") }
    static var openAppWhenRun: Bool { true }

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}
