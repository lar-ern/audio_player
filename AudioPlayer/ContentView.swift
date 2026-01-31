import SwiftUI

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @State private var isPlaylistExpanded = true

    var body: some View {
        VStack(spacing: 20) {
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
                            gradient: Gradient(colors: [.purple, .blue]),
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

            // Track Info
            VStack(spacing: 5) {
                Text(audioPlayer.currentTrackName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(audioPlayer.currentArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(audioPlayer.currentAlbum)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Button(action: audioPlayer.togglePlayPause) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Button(action: audioPlayer.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
            }

            // Volume Control
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)

                Slider(value: $audioPlayer.volume, in: 0...1)
                    .frame(width: 150)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
            }

            // Clear and Load Buttons
            HStack(spacing: 10) {
                Button("Clear List") {
                    audioPlayer.clearPlaylist()
                }
                .buttonStyle(.bordered)
                .disabled(audioPlayer.playlist.isEmpty)

                Button("Load Audio File") {
                    audioPlayer.selectAudioFile()
                }
                .buttonStyle(.borderedProminent)
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
                            withAnimation {
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

                    if isPlaylistExpanded {
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
                        .frame(maxHeight: 200)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }
            }
        }
        .padding(30)
        .frame(width: 500)
    }

    private func timeString(from seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
                            .foregroundColor(isCurrentTrack ? .accentColor : .primary)
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
                    .fill(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
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
}
