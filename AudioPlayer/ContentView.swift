import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @State private var isPlaylistExpanded = true
    @State private var showVolumePopup = false
    @State private var showEQPopup = false
    @State private var showSettingsPopup = false

    var body: some View {
        VStack(spacing: 20) {
            // Album Art with overlay icons
            ZStack {
                // Album Art
                ZStack {
                    if let artwork = audioPlayer.albumArtwork {
                        Image(nsImage: artwork)
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
                .overlay(alignment: .topLeading) {
                    // Settings icon
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSettingsPopup.toggle()
                        }
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
                    // AirPlay picker
                    AirPlayPickerView()
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    // EQ icon
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEQPopup.toggle()
                        }
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
                    // Volume speaker icon
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showVolumePopup.toggle()
                        }
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

            // Track Info
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

                // Technical info
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

                // Copyright info
                if !audioPlayer.copyright.isEmpty {
                    Text(audioPlayer.copyright)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            // Progress Bar
            VStack(spacing: 8) {
                Slider(value: $audioPlayer.currentTime, in: 0...audioPlayer.duration) { editing in
                    if !editing {
                        audioPlayer.seek(to: audioPlayer.currentTime)
                    }
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

            // Controls
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

            // Clear and Load Buttons
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

            // Playlist
            if !audioPlayer.playlist.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Playlist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)

                        Spacer()

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
                        .padding(.trailing, 5)
                    }

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(audioPlayer.playlist.enumerated()), id: \.offset) { index, url in
                                PlaylistItemView(
                                    url: url,
                                    index: index,
                                    isCurrentTrack: index == audioPlayer.currentTrackIndex,
                                    previousMetadata: index > 0 ? audioPlayer.getTrackMetadata(for: audioPlayer.playlist[index - 1]) : nil,
                                    onSelect: {
                                        audioPlayer.selectTrack(at: index)
                                    },
                                    audioPlayer: audioPlayer
                                )
                            }
                        }
                    }
                    .frame(maxHeight: isPlaylistExpanded ? 200 : 0)
                    .opacity(isPlaylistExpanded ? 1 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
            }
        }
        .padding(30)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.10))
        .foregroundColor(Color(white: 0.85))
        .tint(Color(white: 0.50))
    }

    private var volumeIcon: String {
        if audioPlayer.volume == 0 {
            return "speaker.slash.fill"
        } else if audioPlayer.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if audioPlayer.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func timeString(from seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct VolumePopoverView: View {
    @Binding var volume: Double

    var body: some View {
        VStack(spacing: 8) {
            // Max volume button
            Button(action: { volume = 1.0 }) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.55))
            }
            .buttonStyle(.plain)

            // Vertical slider
            Slider(value: $volume, in: 0...1)
                .tint(Color(white: 0.50))
                .rotationEffect(.degrees(-90))
                .frame(width: 120, height: 20)
                .frame(width: 20, height: 120)

            // Mute button
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

        // Style the button to match our steel theme
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
            // On/Off toggle
            Toggle("Tone Control", isOn: $eqEnabled)
                .font(.caption)
                .fontWeight(.semibold)

            // Bass control
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
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(bassGain == gain ? Color(white: 0.40) : Color.primary.opacity(0.1))
                                )
                                .foregroundColor(bassGain == gain ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!eqEnabled)
                    }
                }
            }

            // Treble control
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
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(trebleGain == gain ? Color(white: 0.40) : Color.primary.opacity(0.1))
                                )
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
        if gain > 0 {
            return "+\(Int(gain))"
        } else {
            return "\(Int(gain))"
        }
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
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(gapDuration == gap ? Color(white: 0.40) : Color.primary.opacity(0.1))
                                )
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
        if gap == 0 {
            return "0s"
        } else if gap == gap.rounded() {
            return "\(Int(gap))s"
        } else {
            return String(format: "%.1fs", gap)
        }
    }
}

struct PlaylistItemView: View {
    let url: URL
    let index: Int
    let isCurrentTrack: Bool
    let previousMetadata: TrackMetadata?
    let onSelect: () -> Void
    let audioPlayer: AudioPlayerManager

    var body: some View {
        let metadata = audioPlayer.getTrackMetadata(for: url)
        let duration = audioPlayer.getTrackDuration(for: url)
        let showFullInfo = index == 0 ||
                          previousMetadata?.artist != metadata.artist ||
                          previousMetadata?.album != metadata.album

        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if showFullInfo {
                        // Show artist and album on first line
                        Text("\(metadata.artist) • \(metadata.album)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Show title with 2-character indent
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
        }
        .buttonStyle(.plain)
    }

    private func timeString(from seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    ContentView()
        .environmentObject(AudioPlayerManager())
}
