import WidgetKit
import SwiftUI
struct MusicWatchEntry: TimelineEntry { var date: Date; var snapshot: WatchWidgetSnapshot }
struct MusicWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> MusicWatchEntry { .init(date: Date(), snapshot: .init(title: "Nova Music", artist: "Your music, on your wrist", playing: false, updated: Date())) }
    func getSnapshot(in context: Context, completion: @escaping (MusicWatchEntry) -> Void) { completion(.init(date: Date(), snapshot: .read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MusicWatchEntry>) -> Void) { completion(Timeline(entries: [.init(date: Date(), snapshot: .read())], policy: .after(Date().addingTimeInterval(900)))) }
}
struct MusicWatchWidgetView: View {
    var entry: MusicWatchEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular { Image(systemName: entry.snapshot.playing ? "waveform" : "music.note").font(.title2).widgetAccentable() }
            else { VStack(alignment: .leading) { Label("Nova Music", systemImage: entry.snapshot.playing ? "waveform" : "music.note").font(.caption).widgetAccentable(); Text(entry.snapshot.title).font(.headline).lineLimit(1); if family == .accessoryRectangular { Text(entry.snapshot.artist).font(.caption).lineLimit(1) } } }
        }.containerBackground(.black.gradient, for: .widget).widgetURL(URL(string: "novamusic-watch://player"))
    }
}
@main
struct NovaMusicWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NovaMusicWatch", provider: MusicWatchProvider()) { MusicWatchWidgetView(entry: $0) }
            .configurationDisplayName("Nova Music").description("Return to your music.").supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
