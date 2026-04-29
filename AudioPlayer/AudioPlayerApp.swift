import SwiftUI

@main
struct AudioPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("AudioPlayer", id: "main") {
            ContentView()
                .environmentObject(appDelegate.audioPlayer)
                .environmentObject(appDelegate.audioPlayer.clock)
                .environmentObject(appDelegate.audioPlayer.playlistStore)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // Remove the "New Window" menu item so users can't create extra windows
            CommandGroup(replacing: .newItem) { }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let audioPlayer = AudioPlayerManager()

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf", "ogg", "wma"
    ]

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenFiles(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any extra windows that SwiftUI may have created
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.closeExtraWindows()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return false
    }

    /// Keep only the first visible window, close any extras
    private func closeExtraWindows() {
        let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
        if visibleWindows.count > 1 {
            for window in visibleWindows.dropFirst() {
                window.close()
            }
        }
    }

    private func handleOpenFiles(_ urls: [URL]) {
        // Run directory scanning on a background queue — recursive enumeration
        // of a large music library can take seconds on spinning HDDs.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var audioURLs: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    audioURLs.append(contentsOf: self.audioFilesInDirectory(url))
                } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                    audioURLs.append(url)
                }
            }

            audioURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            guard !audioURLs.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let wasEmpty = self.audioPlayer.playlist.isEmpty
                self.audioPlayer.playlist.append(contentsOf: audioURLs.map { PlaylistTrack(url: $0) })
                if wasEmpty { self.audioPlayer.selectTrack(at: 0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.closeExtraWindows()
                }
            }
        }
    }

    /// Recursively find all audio files in a directory, sorted by path
    private func audioFilesInDirectory(_ directory: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            if Self.audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                results.append(fileURL)
            }
        }

        return results
    }
}
