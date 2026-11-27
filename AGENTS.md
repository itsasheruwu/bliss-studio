# Bliss Studio

- Use **Bliss Studio** for the app name. Use “Music Scene” only when explaining the move from Graft.
- Keep player windows, playback integration, lyrics, and the effects editor in `Sources/BlissStudio`. Audio metering and beat detection live in `Sources/BlissAudio`.
- Save and export lyric effects as `.bliss`. Accept legacy `.graft` imports. Migration must preserve the original Graft files and any newer Bliss Studio edits.
- Use native macOS controls and the system accent for primary actions. Keep macOS 15 support when adding newer SwiftUI APIs.
- Run `./script/build_and_run.sh build` to package `dist/Bliss Studio.app`, or omit `build` to launch it. Use **Window → Preview** to check the player and lyric visuals without a connected music app.
