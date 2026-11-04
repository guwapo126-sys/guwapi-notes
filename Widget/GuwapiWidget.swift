import SwiftUI
import WidgetKit

struct NoteEntry: TimelineEntry {
    let date: Date
    let pinned: Note?
    let next: Note?
    let groupOK: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NoteEntry {
        NoteEntry(date: Date(),
                  pinned: Note(title: "Notă fixată", body: "Conținutul notei apare aici.", client: "Client"),
                  next: nil, groupOK: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
        let now = Date()
        var entries = [entry(at: now)]
        // Câte o intrare imediat după fiecare reminder, ca widgetul să treacă singur la următorul.
        let upcoming = NoteFile.load().compactMap(\.reminder).filter { $0 > now }.sorted().prefix(5)
        for d in upcoming { entries.append(entry(at: d.addingTimeInterval(1))) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    private func entry(at date: Date) -> NoteEntry {
        let notes = NoteFile.load()
        let next = notes
            .filter { ($0.reminder ?? .distantPast) > date }
            .min { ($0.reminder ?? .distantFuture) < ($1.reminder ?? .distantFuture) }
        return NoteEntry(date: date,
                         pinned: notes.first(where: { $0.pinned }),
                         next: next,
                         groupOK: AppGroup.resolvedID != nil)
    }
}

struct GuwapiWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NoteEntry

    private var focus: Note? { entry.next ?? entry.pinned }
    private var isAccessory: Bool {
        family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: home
            }
        }
        .widgetURL(focus.flatMap { URL(string: "guwapinotes://note/\($0.id.uuidString)") })
        .containerBackground(for: .widget) {
            if isAccessory { Color.clear } else { Brand.background }
        }
    }

    // Ecran de blocare — sub ceas
    @ViewBuilder private var inline: some View {
        if let n = entry.next, let r = n.reminder {
            Label {
                Text("\(r.formatted(date: .omitted, time: .shortened)) \(n.title)")
            } icon: { Image(systemName: "bell.fill") }
        } else if let p = entry.pinned {
            Label(p.title, systemImage: "pin.fill")
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
                Text(n.title).font(.headline).lineLimit(1)
                if !n.client.isEmpty { Text(n.client).font(.caption).lineLimit(1) }
            } else if let p = entry.pinned {
                Label("Fixată", systemImage: "pin.fill").font(.caption2.weight(.semibold))
                Text(p.title).font(.headline).lineLimit(1)
                Text(p.body).font(.caption).lineLimit(2)
            } else {
                Text("guwapi notes").font(.headline)
                Text("Nicio notă fixată").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Ecran principal
    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("guwapi").font(.caption.weight(.bold)).foregroundStyle(Brand.accent)
                Spacer()
                Image(systemName: entry.next != nil ? "bell.fill" : "pin.fill")
                    .font(.caption).foregroundStyle(Brand.accent)
            }
            if let n = focus {
                Text(n.title.isEmpty ? "Fără titlu" : n.title)
                    .font(.headline).foregroundStyle(Brand.text).lineLimit(2)
                if !n.client.isEmpty {
                    Text(n.client.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Brand.muted)
                }
                if let r = n.reminder, entry.next?.id == n.id {
                    Text(r.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Brand.accent)
                } else {
                    Text(n.body).font(.caption).foregroundStyle(Brand.text.opacity(0.8)).lineLimit(4)
                }
            } else {
                Text(entry.groupOK ? "Nicio notă fixată" : "Legătura app-widget lipsește")
                    .font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

struct GuwapiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GuwapiWidget", provider: Provider()) { entry in
            GuwapiWidgetView(entry: entry)
        }
        .configurationDisplayName("guwapi notes")
        .description("Nota fixată și următorul reminder.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .systemSmall, .systemMedium])
    }
}

@main
struct GuwapiWidgetBundle: WidgetBundle {
    var body: some Widget { GuwapiWidget() }
}
