# CaptureDeck

A lightweight, native macOS screen capture and editing utility. **Capture. Edit. Share.**

Status: early development (Phase 0 - app shell). See [Project Plan.md](Project%20Plan.md).

## Build and run

Requires macOS 13+ and Swift 6 (Xcode or Command Line Tools).

```sh
./scripts/setup-dev-signing.sh  # once: stable local signing so Screen Recording permission survives rebuilds
swift test                 # run unit tests
./scripts/build-app.sh     # builds build/CaptureDeck.app (universal arm64 + x86_64)
open build/CaptureDeck.app # look for the icon in the menu bar
```

## License

MIT
