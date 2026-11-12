import SwiftUI
import BlinkCore

@main
struct BlinkApp: App {
    @StateObject private var graph = Graph()

    init() {
        // Обложки и ответы сервера кладутся в общий кэш: побольше памяти и диска, чем по умолчанию,
        // чтобы список с картинками листался без повторных загрузок.
        URLCache.shared = URLCache(memoryCapacity: 48 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, directory: nil)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(graph)
                .environmentObject(graph.navStore)
                .environmentObject(graph.playerStore)
                .environmentObject(graph.offlineStore)
                .environmentObject(graph.searchStore)
                .environmentObject(graph.authStore)
                .environmentObject(graph.plusStore)
                .environmentObject(graph.onlineStore)
                .environmentObject(graph.currentIdStore)
                .environmentObject(graph.hasTrackStore)
                .environmentObject(graph.downloadingStore)
                .environmentObject(graph.toastCenter)
                .environmentObject(graph.flash)
                .environmentObject(graph.roomStore)
                .environmentObject(graph.friendsStore)
                .environmentObject(graph.libraryVersion)
                .environmentObject(graph.pick)
                .environmentObject(graph.info)
                .onOpenURL { graph.handleLink($0.absoluteString) }
                .preferredColorScheme(.dark)
                .tint(Ink.accent)
                .task { graph.start() }
        }
    }
}
