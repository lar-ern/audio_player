# AudioPlayer - macOS Audio Player

A modern macOS audio player built with Swift and SwiftUI.

## Features

- Play audio files (MP3, WAV, AIFF, M4A, AAC, MP4, FLAC)
- FLAC (Free Lossless Audio Codec) support with native decoding
- Multiple file playlist support
- Play/Pause controls
- Previous/Next track navigation
- Seek functionality with progress bar
- Volume control
- Real-time playback progress
- Clean, modern UI
- Automatic format detection

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later

## How to Build and Run

### Option 1: Using Xcode GUI

1. Open Xcode
2. Select "Create a new Xcode project"
3. Choose "macOS" > "App"
4. Set the following:
   - Product Name: AudioPlayer
   - Interface: SwiftUI
   - Language: Swift
5. Click "Next" and choose a location
6. Replace the contents of the created files with the files from this project:
   - Replace `AudioPlayerApp.swift` with the one in this project
   - Replace `ContentView.swift` with the one in this project
   - Add `AudioPlayerManager.swift` to the project
   - Add `FLACDecoder.swift` to the project
7. Build and run (Cmd+R)

### Option 2: Using Command Line

```bash
# Navigate to the project directory
cd ~/claude_projects/audio_player

# Create an Xcode project using SwiftPM
swift package init --type executable --name AudioPlayer

# Or manually create an Xcode project file and add the Swift files
```

## Usage

1. Launch the application
2. Click "Load Audio File" button
3. Select one or more audio files from your computer
4. Use the playback controls:
   - Play/Pause button (center)
   - Previous track (left arrow)
   - Next track (right arrow)
   - Progress bar (seek to any position)
   - Volume slider

## Project Structure

```
AudioPlayer/
├── AudioPlayerApp.swift      # Main app entry point
├── ContentView.swift          # UI layout and controls
├── AudioPlayerManager.swift   # Audio playback logic and format handling
└── FLACDecoder.swift          # FLAC file decoder using AVAudioEngine
```

## Architecture

- **AudioPlayerApp**: The main app entry point using SwiftUI's @main
- **ContentView**: SwiftUI view containing the player interface
- **AudioPlayerManager**: ObservableObject managing audio playback, automatically selecting the appropriate decoder based on file format
- **FLACDecoder**: Dedicated FLAC file decoder using AVAudioEngine and AVAudioFile for lossless audio playback

## FLAC Support

The app includes native FLAC support for macOS 10.13 and later:
- FLAC files are automatically detected by file extension
- Uses AVAudioEngine with AVAudioFile for hardware-accelerated decoding
- Supports all standard FLAC features including seeking and real-time progress
- No external dependencies required - uses native macOS Core Audio framework

## License

MIT
