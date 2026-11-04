import SwiftUI
import WidgetKit

struct NoteEntry: TimelineEntry {
    let date: Date
    let pinned: [NoteMeta]
    let next: NoteMeta?
    let groupOK: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NoteEntry {
        var sample = NoteMeta()
        sample.title = "Notă fixată"
        sample.preview = "Conținutul notei apare aici."
        sample.colorHex = "59E0EF"
        sample.pinned = true
        return NoteEntry(date: Date(), pinned: [sample], next: nil, groupOK: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
        let now = Date()
        var entries = [entry(at: now)]
        // Câte o intrare imediat după fiecare reminder, ca widgetul să treacă singur la următorul.
        let upcoming = LibraryFile.load().notes.compactMap(\.reminder).filter { $0 > now }.sorted().prefix(5)
        for d in upcoming { entries.append(entry(at: d.addingTimeInterval(1))) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    private func entry(at date: Date) -> NoteEntry {
        let notes = LibraryFile.load().notes
        let pinned = notes.filter(\.pinned).sorted { $0.updated > $1.updated }
        let next = notes
            .filter { ($0.reminder ?? .distantPast) > date }
            .min { ($0.reminder ?? .distantFuture) < ($1.reminder ?? .distantFuture) }
        return NoteEntry(date: date, pinned: Array(pinned.prefix(4)), next: next, groupOK: AppGroup.resolvedID != nil)
    }
}

struct GuwapiWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NoteEntry

    private var focus: NoteMeta? { entry.next ?? entry.pinned.first }
    private var isAccessory: Bool {
        family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            default: small
            }
        }
        .widgetURL(focus.flatMap { URL(string: "guwapinotes://note/\($0.id.uuidString)") })
        .containerBackground(for: .widget) {
            if isAccessory { Color.clear } else { Brand.background }
        }
    }

    private func color(_ n: NoteMeta) -> Color { n.colorHex.map { Color(hexString: $0) } ?? Brand.accent }

    // Ecran de blocare — sub ceas
    @ViewBuilder private var inline: some View {
        if let n = entry.next, let r = n.reminder {
            Label {
                Text("\(r.formatted(date: .omitted, time: .shortened)) \(n.displayTitle)")
            } icon: { Image(systemName: "bell.fill") }
        } else if let p = entry.pinned.first {
            Label(p.displayTitle, systemImage: "pin.fill")
        } else {
            Text("guwapi notes")
        }
    }

    // Ecran de blocare — rotund
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: entry.next != nil ? "bell.fill" : "note.text")
                    .font(.system(size: 14, weight: .semibold))
                if let r = entry.next?.reminder {
                    Text(r.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .semibold))
                        .minimumScaleFactor(0.5)
                } else {
                    Text("\(entry.pinned.count)").font(.system(size: 11, weight: .bold))
                }
            }
        }
    }

    // Ecran de blocare — dreptunghiular
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !entry.groupOK {
                Text("guwapi · setup").font(.headline)
                Text("Legătura app-widget lipsește").font(.caption)
            } else if let n = entry.next, let r = n.reminder {
                Label(r.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill")
                    .font(.caption2.weight(.semibold))
                Text(n.displayTitle).font(.headline).lineLimit(1)
                if !n.preview.isEmpty { Text(n.preview).font(.caption).lineLimit(1) }
            } else if let p = entry.pinned.first {
                Label("Fixată", systemImage: "pin.fill").font(.caption2.weight(.semibold))
                Text(p.displayTitle).font(.headline).lineLimit(1)
                Text(p.preview).font(.caption).lineLimit(2)
            } else {
                Text("guwapi notes").font(.headline)
                Text("Nicio notă fixată").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Ecran principal — mic
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let n = focus {
                Text(n.displayTitle).font(.headline).foregroundStyle(Brand.text).lineLimit(2)
                if let r = n.reminder, entry.next?.id == n.id {
                    Text(r.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(color(n))
                } else {
                    Text(n.preview).font(.caption).foregroundStyle(Brand.text.opacity(0.75)).lineLimit(4)
                }
            } else {
                Text(entry.groupOK ? "Nicio notă fixată" : "Legătura app-widget lipsește")
                    .font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
        }
    }

    // Ecran principal — mediu: notele fixate
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let n = entry.next, let r = n.reminder {
                row(n, detail: r.formatted(date: .abbreviated, time: .shortened), icon: "bell.fill")
            }
            ForEach(entry.pinned.filter { $0.id != entry.next?.id }.prefix(entry.next == nil ? 3 : 2)) { n in
                Link(destination: URL(string: "guwapinotes://note/\(n.id.uuidString)")!) {
                    row(n, detail: n.preview, icon: nil)
                }
            }
            if entry.pinned.isEmpty && entry.next == nil {
                Text("Fixează note din aplicație ca să apară aici.").font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack {
            Text("guwapi").font(.caption.weight(.bold)).foregroundStyle(Brand.accent)
            Spacer()
            Image(systemName: entry.next != nil ? "bell.fill" : "pin.fill").font(.caption).foregroundStyle(Brand.accent)
        }
    }

    private func row(_ n: NoteMeta, detail: String, icon: String?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(n.status?.color ?? color(n)).frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(n.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.text).lineLimit(1)
                HStack(spacing: 4) {
                    if let icon { Image(systemName: icon).font(.caption2) }
                    Text(detail).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(Brand.muted)
            }
        }
    }
}

struct GuwapiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GuwapiWidget", provider: Provider()) { entry in
            GuwapiWidgetView(entry: entry)
        }
        .configurationDisplayName("guwapi notes")
        .description("Notele fixate și următorul reminder.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall, .systemMedium])
    }
}

@main
struct GuwapiWidgetBundle: WidgetBundle {
    var body: some Widget { GuwapiWidget() }
}
