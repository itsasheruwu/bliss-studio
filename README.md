# Bliss Studio

Bliss Studio follows Spotify or Apple Music on your Mac and puts the current sleeve, timed lyrics, and beat-reactive light in a dedicated player. Open a second artwork window for another display or send the edge light to your desktop. Choose **Window → Preview** for a silent demo.

## Download

[Download Bliss Studio for Apple silicon](https://github.com/itsasheruwu/bliss-studio/releases/latest/download/Bliss-Studio-macOS-arm64.zip). Requires macOS 15 or later. Unzip the archive and move **Bliss Studio.app** to Applications. The release is ad-hoc signed and has not been notarized by Apple.

## Playback and lyrics

Connect your music player when prompted for Automation access. The optional reactive light uses system audio recording. Click the sleeve or press **A** to expand the artwork and **Escape** to collapse it. Open lyrics to look up the track on LRCLIB, or use the player’s **More** menu to import timed LRC or plain text lyrics. Apple Music artwork lookup uses Apple’s catalog.

On first launch, Bliss Studio copies Graft’s player preferences, imported lyrics, and saved lyric effects into its own library. New effects files use the `.bliss` extension. To use a previously exported `.graft` file, import it in the lyric effects editor, then export it as `.bliss`.

## Lyric effects

In Bliss Studio, load the song’s lyrics and choose **More → Edit lyric effects**.
Select a lyric, then click an effect in the library or drag it onto the graph.
Each connected block starts with that lyric. Select a block to set a delay,
choose a color or emoji, or target a word. Use **Replay** to preview that lyric.
Turn off **Automatic effects** on a line to use only its custom blocks.

Edits save for that recording. **Export** creates a portable `.bliss` file.
Import it after loading the matching lyrics and timestamps on another Mac.
**Reset** restores the automatic effects for the song.

A lyric effects `.bliss` file is versioned JSON. Each cue identifies a lyric
by text and start time in milliseconds. Blocks declare an effect, delay in
seconds, and any applicable settings. Image stickers are embedded as small PNG
thumbnails, so they travel with the file.

## Build from source

With Xcode 26 or later and Swift 6.2 or later, run `./script/build_and_run.sh` to build and open the app, or `./script/build_and_run.sh build` to assemble `dist/Bliss Studio.app`.
