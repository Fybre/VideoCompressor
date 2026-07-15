# Video Compressor

A simple, native iOS app for compressing videos on-device — no uploads, no accounts, no tracking.

Pick a video from your photo library, choose a compression level (or a quick preset), optionally tweak resolution/codec/frame rate, and export a smaller file you can preview, save back to Photos, or share.

## Features

- **Real bitrate control** — compression level actually drives the encoder's target bitrate via a custom `AVAssetReader`/`AVAssetWriter` pipeline, not just a fixed quality preset
- **Quick presets** — Balanced, Social Media, Archive, High Quality, Original
- **Advanced options** — resolution, codec (H.264/HEVC), and frame rate, with sensible guardrails so a setting can never produce a file *larger* than the source
- **Cancel anytime** — mid-compression cancellation with immediate UI feedback
- **Switch videos freely** — change your selection before compressing, or jump back to the home screen at any point (when not actively compressing)
- **Preview, save, and share** — review the compressed result, save it to Photos, or share it directly
- **Settings persist** — your last-used compression settings are remembered between videos and app launches
- **Keeps working in the background** — compression continues briefly if you switch apps mid-run, rather than being killed immediately
- **Accessible** — VoiceOver labels throughout, including live compression progress and selection state
- **All local** — video processing happens entirely on-device

## Requirements

- Xcode 16+
- iOS 26+
- Swift 5

## Building

Open `VideoCompressor.xcodeproj` in Xcode, select a run destination, and build (⌘B) / run (⌘R).

## Privacy

Video Compressor collects no data and makes no network requests — see the [Privacy Policy](PRIVACY.md).

## License

Released under the [MIT License](LICENSE). Attribution isn't required, but a link back is appreciated.

## Links

- [fybre.me](https://fybre.me)
