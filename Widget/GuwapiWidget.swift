import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Date pentru widgeturi

struct NoteEntry: TimelineEntry {
    let date: Date
    let pinned: [NoteMeta]
    let next: NoteMeta?
    let groupOK: Bool
    let tags: [UUID: TagDef]
    let tagOrder: [UUID]
    let folders: [UUID: String]
    let counts: [NoteStatus: Int]
    let urgent: Int

    var focus: NoteMeta? { next ?? pinned.first }

    func emojis(_ note: NoteMeta, limit: Int = 3) -> String {
        tagOrder.filter { note.tagIDs.contains($0) }.prefix(limit).compactMap { tags[$0]?.emoji }.joined()
    }

    func folderName(_ note: NoteMeta) -> String {
        note.folderID.flatMap { folders[$0] } ?? "Note rapide"
    }

    func accent(_ note: NoteMeta) -> Color {
        if let status = note.status { return status.color }
        if let hex = note.colorHex { return Color(hexString: hex) }
        return Brand.accent
    }

    static func load(at date: Date) -> NoteEntry {
        let lib = LibraryFile.load()
        let notes = lib.notes
        let pinned = notes.filter(\.pinned).sorted { $0.updated > $1.updated }
        let next = notes
            .filter { ($0.reminder ?? .distantPast) > date }
            .min { ($0.reminder ?? .distantFuture) < ($1.reminder ?? .distantFuture) }
        let tagList = lib.tags ?? TagDef.defaults
        var counts: [NoteStatus: Int] = [:]
        for n in notes { if let s = n.status { counts[s, default: 0] += 1 } }
        let urgentID: UUID? = tagList.first(where: { $0.name == "Urgent" })?.id
        var urgent = 0
        if let id = urgentID {
            for n in notes where n.tagIDs.contains(id) && n.status != NoteStatus.done { urgent += 1 }
        }
        // Un id duplicat în fișier nu trebuie să oprească widgetul (uniqueKeysWithValues ar opri procesul).
        var tags: [UUID: TagDef] = [:]
        for t in tagList where tags[t.id] == nil { tags[t.id] = t }
        var folders: [UUID: String] = [:]
        for f in lib.folders where folders[f.id] == nil { folders[f.id] = f.name }
        let pinnedTop: [NoteMeta] = Array(pinned.prefix(4))
        let tagOrder: [UUID] = tagList.map(\.id)
        let groupOK: Bool = AppGroup.resolvedID != nil
        return NoteEntry(
            date: date,
            pinned: pinnedTop,
            next: next,
            groupOK: groupOK,
            tags: tags,
            tagOrder: tagOrder,
            folders: folders,
            counts: counts,
            urgent: urgent
        )
    }

    static var sample: NoteEntry {
        var note = NoteMeta()
        note.title = "Brief Ventures-n-Law"
        note.preview = "Structura CMS, roluri, SEO tehnic"
        note.status = .progress
        note.pinned = true
        return NoteEntry(date: Date(), pinned: [note], next: nil, groupOK: true,
                         tags: [:], tagOrder: [], folders: [:],
                         counts: [.problem: 1, .progress: 3, .done: 7], urgent: 1)
    }
}

struct Provider: TimelineProvider {
    let kind: String

    func placeholder(in context: Context) -> NoteEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
        completion(context.isPreview ? .sample : .load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
        WidgetHeartbeat.record(kind)
        let now = Date()
        var entries = [NoteEntry.load(at: now)]
        // O intrare imediat după fiecare reminder, ca widgetul să treacă singur la următorul.
        let upcoming = LibraryFile.load().notes.compactMap(\.reminder).filter { $0 > now }.sorted().prefix(5)
        for d in upcoming { entries.append(.load(at: d.addingTimeInterval(1))) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Elemente comune

/// Semnătura guwapi: scutul nostru + numele.
struct BrandMark: View {
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Image("guwapi.shield")
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
            if !compact {
                Text("guwapi")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.4)
            }
        }
        .foregroundStyle(Brand.accent)
    }
}

struct StatusBadge: View {
    let status: NoteStatus
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon).font(.system(size: 9, weight: .bold))
            Text(status.label).font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(status.color.opacity(0.18)))
    }
}

/// Fundal discret: lumina brandului din colț.
struct WidgetGlow: View {
    var tint: Color = Brand.accent
    var body: some View {
        ZStack {
            Brand.background
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 170)
        }
    }
}

// MARK: - Widget „Note”: notele fixate și următorul reminder

struct NotesWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NoteEntry

    var body: some View {
        content
            .widgetURL(entry.focus.flatMap { URL(string: "guwapinotes://note/\($0.id.uuidString)") })
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    @ViewBuilder private var background: some View {
        switch family {
        case .accessoryInline, .accessoryCircular, .accessoryRectangular: Color.clear
        default: WidgetGlow(tint: entry.focus.map(entry.accent) ?? Brand.accent)
        }
    }

    // Ecran de blocare — rândul de deasupra ceasului
    @ViewBuilder private var inline: some View {
        if let n = entry.next, let r = n.reminder {
            Label("\(r.formatted(date: .omitted, time: .shortened)) · \(n.displayTitle)", systemImage: "bell.fill")
        } else if let p = entry.pinned.first {
            Label("\(entry.emojis(p, limit: 1)) \(p.displayTitle)", image: "guwapi.shield")
        } else {
            Label("guwapi notes", image: "guwapi.shield")
        }
    }

    // Ecran de blocare — rotund
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                if let r = entry.next?.reminder {
                    Image(systemName: "bell.fill").font(.system(size: 12, weight: .semibold))
                    Text(r.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                } else {
                    Image("guwapi.shield").font(.system(size: 18, weight: .semibold))
                    Text("\(entry.pinned.count)").font(.system(size: 10, weight: .bold, design: .rounded))
                }
            }
        }
        .widgetAccentable()
    }

    // Ecran de blocare — dreptunghi
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !entry.groupOK {
                Label("guwapi · setup", image: "guwapi.shield").font(.headline)
                Text("Deschide Diagnostic în aplicație").font(.caption)
            } else if let n = entry.focus {
                HStack(spacing: 4) {
                    if let r = n.reminder, entry.next?.id == n.id {
                        Image(systemName: "bell.fill")
                        Text(r.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Image(systemName: n.status?.icon ?? "pin.fill")
                        Text(n.status?.label ?? "Fixată")
                    }
                    Spacer(minLength: 2)
                    Text(entry.emojis(n))
                }
                .font(.caption2.weight(.semibold))
                Text(n.displayTitle).font(.headline).lineLimit(1)
                Text(entry.folderName(n)).font(.caption).lineLimit(1).opacity(0.8)
            } else {
                Label("guwapi notes", image: "guwapi.shield").font(.headline)
                Text("Fixează o notă ca s-o vezi aici").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Ecran principal — mic
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                BrandMark()
                Spacer()
                if let n = entry.focus { Text(entry.emojis(n)).font(.caption) }
            }
            if let n = entry.focus {
                Spacer(minLength: 0)
                Text(n.displayTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.text)
                    .lineLimit(3)
                Text(entry.folderName(n).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
                HStack {
                    if let r = n.reminder, entry.next?.id == n.id {
                        Label(r.formatted(date: .omitted, time: .shortened), systemImage: "bell.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(entry.accent(n))
                    } else if let s = n.status {
                        StatusBadge(status: s)
                    }
                }
            } else {
                Spacer()
                Text(entry.groupOK ? "Fixează o notă ca s-o vezi aici." : "Legătura cu aplicația lipsește.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
    }

    // Ecran principal — mediu
    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                BrandMark()
                Spacer()
                StatusCounts(counts: entry.counts)
            }
            let rows = mediumRows
            if rows.isEmpty {
                Spacer()
                Text("Fixează note din aplicație ca să apară aici.").font(.caption).foregroundStyle(Brand.muted)
            }
            ForEach(rows, id: \.id) { n in
                Link(destination: URL(string: "guwapinotes://note/\(n.id.uuidString)")!) { row(n) }
            }
            Spacer(minLength: 0)
        }
    }

    private var mediumRows: [NoteMeta] {
        var list: [NoteMeta] = []
        if let n = entry.next { list.append(n) }
        list += entry.pinned.filter { $0.id != entry.next?.id }
        return Array(list.prefix(3))
    }

    private func row(_ n: NoteMeta) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(entry.accent(n)).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(n.displayTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                    Text(entry.emojis(n)).font(.caption2)
                }
                HStack(spacing: 4) {
                    if let r = n.reminder, entry.next?.id == n.id {
                        Image(systemName: "bell.fill")
                        Text(r.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text(entry.folderName(n))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Brand.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let s = n.status {
                Image(systemName: s.icon).font(.caption).foregroundStyle(s.color)
            }
        }
    }
}

struct StatusCounts: View {
    let counts: [NoteStatus: Int]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(NoteStatus.allCases) { s in
                HStack(spacing: 3) {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                    Text("\(counts[s] ?? 0)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.text)
                }
            }
        }
    }
}

struct GuwapiWidget: Widget {
    static let kind = "GuwapiWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider(kind: Self.kind)) { entry in
            NotesWidgetView(entry: entry)
        }
        .configurationDisplayName("guwapi · Note")
        .description("Notele fixate și următorul reminder, cu status și etichete.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall, .systemMedium])
    }
}

// MARK: - Widget „Status”: probleme, în lucru, gata

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NoteEntry

    private var problems: Int { entry.counts[.problem] ?? 0 }

    var body: some View {
        content
            .widgetURL(URL(string: "guwapinotes://home"))
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    @ViewBuilder private var background: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular: Color.clear
        default: WidgetGlow(tint: problems > 0 ? NoteStatus.problem.color : NoteStatus.done.color)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: problems > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(problems)").font(.system(size: 16, weight: .bold, design: .rounded))
            }
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("guwapi · status", image: "guwapi.shield").font(.caption.weight(.bold))
            HStack(spacing: 10) {
                ForEach(NoteStatus.allCases) { s in
                    HStack(spacing: 3) {
                        Image(systemName: s.icon)
                        Text("\(entry.counts[s] ?? 0)").fontWeight(.bold)
                    }
                }
            }
            .font(.system(size: 13, design: .rounded))
            if entry.urgent > 0 { Text("🔥 \(entry.urgent) urgente").font(.caption2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandMark()
            Spacer(minLength: 0)
            ForEach(NoteStatus.allCases) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.icon).foregroundStyle(s.color)
                    Text(s.label).foregroundStyle(Brand.text)
                    Spacer()
                    Text("\(entry.counts[s] ?? 0)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(s.color)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            if entry.urgent > 0 {
                Text("🔥 \(entry.urgent) urgente deschise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.text.opacity(0.85))
            }
        }
    }
}

struct GuwapiStatusWidget: Widget {
    static let kind = "GuwapiStatusWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider(kind: Self.kind)) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("guwapi · Status")
        .description("Câte probleme, câte în lucru și câte gata, dintr-o privire.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

// MARK: - Butonul de pe ecranul de blocare / Centrul de control

struct GuwapiOpenControl: ControlWidget {
    static let kind = "com.guwapi.notes.control.open"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenGuwapiIntent()) {
                Label("guwapi notes", image: "guwapi.shield")
            }
        }
        .displayName("guwapi notes")
        .description("Deschide aplicația direct de pe ecranul de blocare.")
    }
}

@main
struct GuwapiWidgetBundle: WidgetBundle {
    var body: some Widget {
        GuwapiWidget()
        GuwapiStatusWidget()
        GuwapiOpenControl()
    }
}
