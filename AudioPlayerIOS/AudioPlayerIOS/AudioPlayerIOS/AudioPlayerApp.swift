import SwiftUI

@main
struct AudioPlayerIOSApp: App {
    @StateObject private var audioPlayer = AudioPlayerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
        }
    }
}
