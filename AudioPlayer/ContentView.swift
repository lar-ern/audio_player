import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @State private var isPlaylistExpanded = true
    @State private var showVolumePopup = false
    @State private var showEQPopup = false
    @State private var showSettingsPopup = false
    @State private var searchText = ""
    @State private var isWideLayout = false

    // Filtered playlist as (originalIndex, url) pairs so tapping a search
    // result still plays the correct track in the full playlist.
    private var filteredPlaylist: [(index: Int, url: URL)] {
        if searchText.isEmpty {
            return audioPlayer.playlist.enumerated().map { (index: $0.offset, url: $0.element) }
        }
        let query = searchText.lowercased()
        return audioPlayer.playlist.enumerated().compactMap { offset, url in
            let meta = audioPlayer.getTrackMetadata(for: url)
            if meta.title.lowercased().contains(query) ||
               meta.artist.lowercased().contains(query) ||
               meta.album.lowercased().contains(query) {
                return (index: offset, url: url)
            }
            return nil
        }
    }

    var body: some View {
        Group {
            if isWideLayout {
                wideLayout
            } else {
                tallLayout
            }
        }
        .background(Color(white: 0.10))
        .foregroundColor(Color(white: 0.85))
        .tint(Color(white: 0.50))
    }

    // MARK: - Tall layout (default)

    private var tallLayout: some View {
        VStack(spacing: 20) {
            playerControlsView

            if !audioPlayer.playlist.isEmpty {
                playlistView(sidePanel: false)
            }
        }
        .padding(30)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Wide layout

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: player controls
            VStack(spacing: 20) {
                playerControlsView
            }
            .padding(30)
            .frame(width: 380)

            Rectangle()
                .fill(Color(white: 0.20))
                .frame(width: 1)

            // Right: search + track list
            Group {
                if audioPlayer.playlist.isEmpty {
                    VStack {
                        Spacer()
                        Text("No tracks loaded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    playlistView(sidePanel: true)
                        .padding(16)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Player controls (shared)

    private var playerControlsView: some View {
        VStack(spacing: 20) {
            // Album art with overlay icons
            ZStack {
                ZStack {
                    if !audioPlayer.artworkImages.isEmpty {
                        Image(nsImage: audioPlayer.artworkImages[audioPlayer.currentArtworkIndex])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 250, height: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(white: 0.45),
                                    Color(white: 0.30),
                                    Color(white: 0.20)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 250, height: 250)

                        Image(systemName: "music.note")
                            .font(.system(size: 80))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .shadow(radius: 10)
                // Clicking cycles through available artwork images.
                .onTapGesture { audioPlayer.cycleArtwork() }
                .overlay(alignment: .bottom) {
                    // Show counter when there is more than one image.
                    if audioPlayer.artworkImages.count > 1 {
                        Text("\(audioPlayer.currentArtworkIndex + 1) / \(audioPlayer.artworkImages.count)")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { showSettingsPopup.toggle() }
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .popover(isPresented: $showSettingsPopup, arrowEdge: .leading) {
                        SettingsPopoverView(gapDuration: $audioPlayer.gapDuration)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    AirPlayPickerView()
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { showEQPopup.toggle() }
                    }) {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 14))
                            .foregroundColor(audioPlayer.eqEnabled ? Color(white: 0.75) : .white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .popover(isPresented: $showEQPopup, arrowEdge: .leading) {
                        EQPopoverView(
                            eqEnabled: $audioPlayer.eqEnabled,
                            bassGain: $audioPlayer.bassGain,
                            trebleGain: $audioPlayer.trebleGain
                        )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { showVolumePopup.toggle() }
                    }) {
                        Image(systemName: volumeIcon)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .popover(isPresented: $showVolumePopup, arrowEdge: .trailing) {
                        VolumePopoverView(volume: $audioPlayer.volume)
                    }
                }
            }

            // Track info
            VStack(spacing: 5) {
                Text(audioPlayer.currentTrackName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(audioPlayer.currentArtist)
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.55))
                    .lineLimit(1)

                Text(audioPlayer.currentAlbum)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.50))
                    .lineLimit(1)

                if !audioPlayer.sampleRate.isEmpty || !audioPlayer.bitDepth.isEmpty {
                    HStack(spacing: 8) {
                        if !audioPlayer.sampleRate.isEmpty {
                            Text(audioPlayer.sampleRate)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if !audioPlayer.bitDepth.isEmpty {
                            Text(audioPlayer.bitDepth)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if !audioPlayer.copyright.isEmpty {
                    Text(audioPlayer.copyright)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            // Progress bar
            VStack(spacing: 8) {
                Slider(value: $audioPlayer.currentTime, in: 0...audioPlayer.duration) { editing in
                    if !editing { audioPlayer.seek(to: audioPlayer.currentTime) }
                }
                .tint(Color(white: 0.50))
                .disabled(!audioPlayer.isTrackLoaded)

                HStack {
                    Text(timeString(from: audioPlayer.currentTime))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(timeString(from: audioPlayer.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            // Playback controls
            HStack(spacing: 40) {
                Button(action: audioPlayer.previousTrack) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .foregroundColor(Color(white: 0.60))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Button(action: audioPlayer.togglePlayPause) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(Color(white: 0.70))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Button(action: audioPlayer.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .foregroundColor(Color(white: 0.60))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
            }

            // Clear and Load buttons
            HStack(spacing: 10) {
                Button("Clear List") {
                    audioPlayer.clearPlaylist()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.25))
                .foregroundColor(Color(white: 0.70))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(audioPlayer.playlist.isEmpty)
                .opacity(audioPlayer.playlist.isEmpty ? 0.4 : 1.0)

                Button("Load Audio File") {
                    audioPlayer.selectAudioFile()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.40))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Playlist view (shared)

    private func playlistView(sidePanel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack(spacing: 6) {
                Text("Playlist")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Search field — fills the space between label and toggle button
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(white: 0.18))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .frame(maxWidth: .infinity)

                // Layout toggle
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isWideLayout.toggle()
                    }
                }) {
                    Image(systemName: isWideLayout ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(isWideLayout ? "Switch to tall layout" : "Switch to wide layout")

                // Expand/collapse (tall layout only)
                if !sidePanel {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPlaylistExpanded.toggle()
                        }
                    }) {
                        Image(systemName: isPlaylistExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 5)

            // Track list
            let showList = sidePanel || isPlaylistExpanded
            ScrollView {
                VStack(spacing: 2) {
                    if filteredPlaylist.isEmpty {
                        Text("No results for \"\(searchText)\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filteredPlaylist, id: \.index) { item in
                            let prevIndex = filteredPlaylist.first(where: { $0.index == item.index - 1 })?.index
                            let prevMeta = prevIndex.map { audioPlayer.getTrackMetadata(for: audioPlayer.playlist[$0]) }
                            PlaylistItemView(
                                url: item.url,
                                index: item.index,
                                isCurrentTrack: item.index == audioPlayer.currentTrackIndex,
                                previousMetadata: prevMeta,
                                onSelect: { audioPlayer.selectTrack(at: item.index) },
                                onDoubleClick: { audioPlayer.startTrack(at: item.index) },
                                audioPlayer: audioPlayer
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: showList ? (sidePanel ? .infinity : 320) : 0)
            .opacity(showList ? 1 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var volumeIcon: String {
        if audioPlayer.volume == 0 { return "speaker.slash.fill" }
        if audioPlayer.volume < 0.33 { return "speaker.wave.1.fill" }
        if audioPlayer.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func timeString(from seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct VolumePopoverView: View {
    @Binding var volume: Double

    var body: some View {
        VStack(spacing: 8) {
            Button(action: { volume = 1.0 }) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.55))
            }
            .buttonStyle(.plain)

            Slider(value: $volume, in: 0...1)
                .tint(Color(white: 0.50))
                .rotationEffect(.degrees(-90))
                .frame(width: 120, height: 20)
                .frame(width: 20, height: 120)

            Button(action: { volume = 0.0 }) {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }
}

struct AirPlayPickerView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        if let button = picker.subviews.first(where: { $0 is NSButton }) as? NSButton {
            button.contentTintColor = NSColor(white: 0.85, alpha: 1.0)
        }
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct EQPopoverView: View {
    @Binding var eqEnabled: Bool
    @Binding var bassGain: Double
    @Binding var trebleGain: Double

    private let gainSteps: [Double] = [-6, -3, 0, 3, 6]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Tone Control", isOn: $eqEnabled)
                .font(.caption)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bass (100 Hz)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(gainSteps, id: \.self) { gain in
                        Button(action: { bassGain = gain }) {
                            Text(gainLabel(gain))
                                .font(.caption2)
                                .fontWeight(bassGain == gain ? .bold : .regular)
                                .frame(width: 36, height: 24)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(bassGain == gain ? Color(white: 0.40) : Color.primary.opacity(0.1)))
                                .foregroundColor(bassGain == gain ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!eqEnabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Treble (10 kHz)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(gainSteps, id: \.self) { gain in
                        Button(action: { trebleGain = gain }) {
                            Text(gainLabel(gain))
                                .font(.caption2)
                                .fontWeight(trebleGain == gain ? .bold : .regular)
                                .frame(width: 36, height: 24)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(trebleGain == gain ? Color(white: 0.40) : Color.primary.opacity(0.1)))
                                .foregroundColor(trebleGain == gain ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!eqEnabled)
                    }
                }
            }
        }
        .padding(12)
    }

    private func gainLabel(_ gain: Double) -> String {
        gain > 0 ? "+\(Int(gain))" : "\(Int(gain))"
    }
}

struct SettingsPopoverView: View {
    @Binding var gapDuration: Double

    private let gapSteps: [Double] = [0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.caption)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Gap Between Tracks")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(gapSteps, id: \.self) { gap in
                        Button(action: { gapDuration = gap }) {
                            Text(gapLabel(gap))
                                .font(.caption2)
                                .fontWeight(gapDuration == gap ? .bold : .regular)
                                .frame(width: 32, height: 24)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(gapDuration == gap ? Color(white: 0.40) : Color.primary.opacity(0.1)))
                                .foregroundColor(gapDuration == gap ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
    }

    private func gapLabel(_ gap: Double) -> String {
        if gap == 0 { return "0s" }
        return gap == gap.rounded() ? "\(Int(gap))s" : String(format: "%.1fs", gap)
    }
}

struct PlaylistItemView: View {
    let url: URL
    let index: Int
    let isCurrentTrack: Bool
    let previousMetadata: TrackMetadata?
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let audioPlayer: AudioPlayerManager

    var body: some View {
        let metadata = audioPlayer.getTrackMetadata(for: url)
        let duration = audioPlayer.getTrackDuration(for: url)
        let showFullInfo = previousMetadata == nil ||
                           previousMetadata?.artist != metadata.artist ||
                           previousMetadata?.album != metadata.album

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if showFullInfo {
                    HStack(spacing: 0) {
                        Text(metadata.artist)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(" • ")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(metadata.album)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                    .lineLimit(1)
                }
                HStack(spacing: 0) {
                    Text("  ")
                        .font(.caption)
                    Text(metadata.title)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundColor(isCurrentTrack ? Color(white: 0.45) : .primary)
                }
            }
            Spacer()
            Text(timeString(from: duration))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrentTrack ? Color(white: 0.45).opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        // Double-click starts playback; single click selects (respects play state).
        .gesture(
            TapGesture(count: 2).onEnded { onDoubleClick() }
                .exclusively(before: TapGesture(count: 1).onEnded { onSelect() })
        )
    }

    private func timeString(from seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

#if DEBUG && canImport(DeveloperToolsSupport)
#Preview {
    ContentView()
        .environmentObject(AudioPlayerManager())
}
#endif
