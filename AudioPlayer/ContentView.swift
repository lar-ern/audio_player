import SwiftUI

// ContentView is intentionally a zero-logic shell. Its body calls no SwiftUI API —
// just a plain struct init — so SwiftUI+19950082 (_assertionFailure in SwiftUI 4.6.3
// on macOS 13.7) cannot be triggered here. All layout logic lives in RootLayoutView.
struct ContentView: View {
    var body: some View {
        RootLayoutView()
    }
}

// RootLayoutView owns the wide/tall switch and theming. It is a non-root child view,
// which avoids the specific code path in SwiftUI 4.6.3 that fires the assertion when
// the root Window content view body calls AnyView.init or _ConditionalContent.
struct RootLayoutView: View {
    @EnvironmentObject var playlistStore: PlaylistStore

    var body: some View {
        (playlistStore.isWideLayout ? AnyView(WideLayoutView()) : AnyView(TallLayoutView()))
            .background(Color(white: 0.10))
            .foregroundColor(Color(white: 0.85))
            .tint(Color(white: 0.50))
    }
}

// MARK: - Tall layout
//
// Extracted from ContentView to avoid the SwiftUI 4.6.3 assertion
// (_assertionFailure at SwiftUI+19950082) that fires from any large
// @ViewBuilder closure evaluated in ContentView's type context on macOS 13.7.

struct TallLayoutView: View {
    var body: some View {
        VStack(spacing: 20) {
            PlayerControlsView()
            PlaylistView(sidePanel: false)
        }
        .padding(30)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Wide layout

struct WideLayoutView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 20) {
                PlayerControlsView()
            }
            .padding(30)
            .frame(width: 380)

            Rectangle()
                .fill(Color(white: 0.20))
                .frame(width: 1)

            PlaylistView(sidePanel: true)
                .padding(16)
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .frame(minHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Playlist view

struct PlaylistView: View {
    let sidePanel: Bool
    // Observes only PlaylistStore — re-renders on tracks/index/search/layout
    // changes, NOT on isPlaying, artworkImages, duration, or timer ticks.
    @EnvironmentObject var playlistStore: PlaylistStore
    @State private var isPlaylistExpanded = true

    private var filteredPlaylist: [(index: Int, track: PlaylistTrack)] {
        if playlistStore.searchText.isEmpty {
            return playlistStore.tracks.enumerated().map { (index: $0.offset, track: $0.element) }
        }
        let query = playlistStore.searchText.lowercased()
        let mgr = playlistStore.manager
        return playlistStore.tracks.enumerated().compactMap { offset, track in
            let meta = mgr.getTrackMetadata(for: track)
            if meta.title.lowercased().contains(query) ||
               meta.artist.lowercased().contains(query) ||
               meta.album.lowercased().contains(query) {
                return (index: offset, track: track)
            }
            return nil
        }
    }

    var body: some View {
        // Empty state: sidePanel shows placeholder; tall layout shows nothing.
        // Handled here so TallLayoutView/WideLayoutView need no conditionals over
        // PlaylistView — _ConditionalContent<PlaylistView, EmptyView> in a parent
        // body with @Binding properties triggers the SwiftUI 4.6.3 assertion on
        // macOS 13.7 / Intel Mac (_assertionFailure at SwiftUI+19950082).
        if playlistStore.tracks.isEmpty {
            if sidePanel {
                VStack {
                    Spacer()
                    Text("No tracks loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            // Non-sidePanel + empty: fall through to EmptyView (no tracks = no list)
        } else {
            playlistContent
        }
    }

    @ViewBuilder private var playlistContent: some View {
        let items = filteredPlaylist   // compute once per render
        let mgr = playlistStore.manager
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Playlist")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("Search", text: $playlistStore.searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !playlistStore.searchText.isEmpty {
                        Button(action: { playlistStore.searchText = "" }) {
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

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        playlistStore.isWideLayout.toggle()
                    }
                }) {
                    Image(systemName: playlistStore.isWideLayout ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(playlistStore.isWideLayout ? "Switch to tall layout" : "Switch to wide layout")

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

            let showList = sidePanel || isPlaylistExpanded
            ScrollView {
                LazyVStack(spacing: 2) {
                    if items.isEmpty {
                        Text("No results for \"\(playlistStore.searchText)\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.index) { arrayIdx, item in
                            let prevMeta = arrayIdx > 0
                                ? mgr.getTrackMetadata(for: items[arrayIdx - 1].track)
                                : nil
                            PlaylistItemView(
                                track: item.track,
                                index: item.index,
                                isCurrentTrack: item.index == playlistStore.currentIndex,
                                previousMetadata: prevMeta,
                                onSelect: { mgr.selectTrack(at: item.index) },
                                onDoubleClick: { mgr.startTrack(at: item.index) },
                                audioPlayer: mgr
                            )
                        }
                    }
                }  // LazyVStack
            }
            .frame(maxHeight: showList ? 500 : 0)
            .opacity(showList ? 1 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

// MARK: - Player controls
//
// Extracted into its own struct so SwiftUI sees an independent view node rather
// than a monolithic inlined @ViewBuilder closure inside ContentView. A large
// inlined computed-property body triggers a SwiftUI 4.6.3 internal assertion
// (_assertionFailure at SwiftUI+19950082) on macOS 13.7 / Intel Mac.

struct PlayerControlsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @EnvironmentObject var clock: PlaybackClock
    @EnvironmentObject var playlistStore: PlaylistStore
    @State private var showVolumePopup    = false
    @State private var showEQPopup        = false
    @State private var showSettingsPopup  = false
    @State private var showLargeArtwork   = false

    var body: some View {
        VStack(spacing: 20) {
            artworkBaseView
            .shadow(radius: 10)
            .onTapGesture { audioPlayer.cycleArtwork() }
            .overlay(alignment: .bottom) {
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
                if !audioPlayer.artworkImages.isEmpty {
                    Button(action: { showLargeArtwork = true }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .sheet(isPresented: $showLargeArtwork) {
                        LargeArtworkSheet()
                            .environmentObject(audioPlayer)
                    }
                }
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
                        if audioPlayer.upnpManager.isActive,
                           let device = audioPlayer.upnpManager.selectedDevice {
                            HStack(spacing: 3) {
                                Image(systemName: "hifispeaker.2.fill")
                                    .font(.caption2)
                                Text(device.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundColor(.blue)
                        } else if !audioPlayer.outputSampleRate.isEmpty {
                            Text(audioPlayer.outputSampleRate)
                                .font(.caption2)
                                .foregroundColor(audioPlayer.isRateConverting ? .orange : .secondary)
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
                Slider(value: $clock.currentTime, in: 0...max(audioPlayer.duration, 1.0)) { editing in
                    if !editing { audioPlayer.seek(to: clock.currentTime) }
                }
                .tint(Color(white: 0.50))
                .disabled(!audioPlayer.isTrackLoaded)

                HStack {
                    Text(timeString(from: clock.currentTime))
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
                .disabled(!audioPlayer.isTrackLoaded)

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
                .disabled(playlistStore.tracks.isEmpty)
                .opacity(playlistStore.tracks.isEmpty ? 0.4 : 1.0)

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

    // MARK: - Artwork view
    //
    // NSViewRepresentable makes SwiftUI treat the artwork as an opaque AppKit view,
    // bypassing SwiftUI 4.6.3's type-graph machinery that triggers the internal
    // assertion (_assertionFailure at SwiftUI+19950082) on macOS 13.7 / Intel Mac.
    private var artworkBaseView: some View {
        ArtworkDisplayView(
            artworkImages: audioPlayer.artworkImages,
            currentIndex: audioPlayer.currentArtworkIndex
        )
        .frame(width: 250, height: 250)
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

/// Full-size artwork viewer — opens in a sheet at 800 px wide.
struct LargeArtworkSheet: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if audioPlayer.artworkImages.count > 1 {
                    Button(action: { index = max(index - 1, 0) }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)

                    Text("\(index + 1) / \(audioPlayer.artworkImages.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { index = min(index + 1, audioPlayer.artworkImages.count - 1) }) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == audioPlayer.artworkImages.count - 1)

                    Spacer()
                } else {
                    Spacer()
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Artwork
            if index < audioPlayer.artworkImages.count {
                let img = audioPlayer.artworkImages[index]
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 800)
            }
        }
        .frame(width: 800)
        .onAppear { index = audioPlayer.currentArtworkIndex }
    }
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
    @EnvironmentObject var audioPlayer: AudioPlayerManager

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

            Divider()

            UPnPOutputPickerView()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Cover Art")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button(action: { audioPlayer.downloadCoverArt() }) {
                    HStack(spacing: 6) {
                        if audioPlayer.isDownloadingCoverArt {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption)
                        }
                        Text(audioPlayer.isDownloadingCoverArt ? "Searching…" : "Download from MusicBrainz")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(!audioPlayer.isTrackLoaded || audioPlayer.isDownloadingCoverArt)

                if !audioPlayer.coverArtMessage.isEmpty {
                    Text(audioPlayer.coverArtMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    private func gapLabel(_ gap: Double) -> String {
        if gap == 0 { return "0s" }
        return gap == gap.rounded() ? "\(Int(gap))s" : String(format: "%.1fs", gap)
    }
}

// MARK: - UPnP Output Picker

struct UPnPOutputPickerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager

    var body: some View {
        let upnp = audioPlayer.upnpManager
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { upnp.discover() }) {
                    HStack(spacing: 3) {
                        if upnp.isDiscovering {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        Text("Scan")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(upnp.isDiscovering)
            }

            // Mac (local) option
            Button(action: { upnp.selectDevice(nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: upnp.selectedDevice == nil ? "checkmark" : "")
                        .font(.caption2)
                        .frame(width: 12)
                        .foregroundColor(upnp.selectedDevice == nil ? .primary : .clear)
                    Image(systemName: "hifispeaker.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("This Mac")
                        .font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(upnp.selectedDevice == nil
                          ? Color(white: 0.35).opacity(0.5)
                          : Color.clear))
            }
            .buttonStyle(.plain)

            // Discovered UPnP renderers
            ForEach(upnp.discoveredDevices) { device in
                Button(action: { upnp.selectDevice(device) }) {
                    HStack(spacing: 6) {
                        Image(systemName: upnp.selectedDevice == device ? "checkmark" : "")
                            .font(.caption2)
                            .frame(width: 12)
                            .foregroundColor(upnp.selectedDevice == device ? .primary : .clear)
                        Image(systemName: "hifispeaker.2.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .font(.caption2)
                                .lineLimit(1)
                            if !device.modelName.isEmpty {
                                Text(device.modelName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(upnp.selectedDevice == device
                              ? Color(white: 0.35).opacity(0.5)
                              : Color.clear))
                }
                .buttonStyle(.plain)
            }

            if upnp.discoveredDevices.isEmpty && !upnp.isDiscovering {
                Text("No UPnP renderers found — tap Scan")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}

struct PlaylistItemView: View {
    let track: PlaylistTrack
    let index: Int
    let isCurrentTrack: Bool
    let previousMetadata: TrackMetadata?
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let audioPlayer: AudioPlayerManager

    var body: some View {
        let metadata = audioPlayer.getTrackMetadata(for: track)
        let duration = audioPlayer.getTrackDuration(at: index)
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
        // Double-click starts playback; single click selects immediately (no delay).
        // Two separate modifiers: the double-tap fires on the second tap instantly;
        // the single-tap fires on first tap without waiting for a possible second tap.
        .onTapGesture(count: 2) { onDoubleClick() }
        .onTapGesture(count: 1) { onSelect() }
    }

    private func timeString(from seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - Artwork display (AppKit-backed)
//
// NSViewRepresentable wrapper so SwiftUI treats the artwork area as an opaque
// AppKit view. All rendering (gradient, image, music-note icon) is done in
// Core Animation / AppKit, completely outside SwiftUI's type-graph machinery.

struct ArtworkDisplayView: NSViewRepresentable {
    let artworkImages: [NSImage]
    let currentIndex: Int

    func makeNSView(context: Context) -> ArtworkAppKitView {
        ArtworkAppKitView()
    }

    func updateNSView(_ nsView: ArtworkAppKitView, context: Context) {
        nsView.update(images: artworkImages, index: currentIndex)
    }
}

final class ArtworkAppKitView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let imageLayer    = CALayer()
    private let symbolView    = NSImageView()
    private var displayedImage: NSImage?   // identity guard — avoids redundant CA uploads

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius  = 12
        layer?.masksToBounds = true

        // Gradient placeholder background (top-leading → bottom-trailing).
        // CAGradientLayer uses unit coords with y=0 at bottom, y=1 at top.
        gradientLayer.colors = [
            NSColor(white: 0.45, alpha: 1).cgColor,
            NSColor(white: 0.30, alpha: 1).cgColor,
            NSColor(white: 0.20, alpha: 1).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 1) // top-left
        gradientLayer.endPoint   = CGPoint(x: 1, y: 0) // bottom-right
        layer?.addSublayer(gradientLayer)

        // Artwork image layer (hidden until artwork is available).
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds   = true
        imageLayer.isHidden        = true
        layer?.addSublayer(imageLayer)

        // Music-note icon (SF Symbol, macOS 11+).
        if let sym = NSImage(systemSymbolName: "music.note",
                             accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 80, weight: .regular)
            symbolView.image = sym.withSymbolConfiguration(cfg)
        }
        symbolView.contentTintColor = NSColor(white: 1.0, alpha: 0.8)
        symbolView.imageScaling     = .scaleNone
        symbolView.imageAlignment   = .alignCenter
        addSubview(symbolView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        imageLayer.frame    = bounds
        CATransaction.commit()
        symbolView.frame = bounds
    }

    func update(images: [NSImage], index: Int) {
        if images.isEmpty {
            guard displayedImage != nil else { return }  // already showing placeholder
            displayedImage = nil
            imageLayer.contents = nil
            imageLayer.isHidden = true
            gradientLayer.isHidden = false
            symbolView.isHidden    = false
        } else {
            let i = min(index, images.count - 1)
            let newImage = images[i]
            guard newImage !== displayedImage else { return }  // same object — skip GPU upload
            displayedImage = newImage
            // cgImage() decompresses JPEG/PNG on first call — can take 100–500 ms for
            // large album art on Intel Mac. Offload to background; identity-check on
            // return so a quickly-changing track doesn't show stale artwork.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let cgImage = newImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, newImage === self.displayedImage else { return }
                    self.imageLayer.contents    = cgImage ?? newImage
                    self.imageLayer.isHidden    = false
                    self.gradientLayer.isHidden = true
                    self.symbolView.isHidden    = true
                }
            }
        }
    }
}
