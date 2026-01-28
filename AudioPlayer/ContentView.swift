import SwiftUI

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()

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
                }
                .buttonStyle(.plain)

                Button(action: audioPlayer.togglePlayPause) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                }
                .buttonStyle(.plain)

                Button(action: audioPlayer.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
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
                    Text("Playlist")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(audioPlayer.playlist.enumerated()), id: \.offset) { index, url in
                                Button(action: {
                                    audioPlayer.selectTrack(at: index)
                                }) {
                                    HStack {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .foregroundColor(index == audioPlayer.currentTrackIndex ? .accentColor : .primary)

                                        Spacer()

                                        Text(timeString(from: audioPlayer.getTrackDuration(for: url)))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(index == audioPlayer.currentTrackIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
            }
        }
        .padding(30)
        .frame(width: 400)
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
