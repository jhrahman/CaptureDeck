# CaptureDeck brand assets

| Folder | What it holds |
| --- | --- |
| `AppIcon.iconset` | App icon at every macOS size. Sizes under 64 px leave out the viewfinder corners. |
| `menubar` | Menu bar icons, 18 x 18 pt at 1x and 2x. |
| `svg` | Vector sources. |

Menu bar icons:

- `MenuBarIdle` and `MenuBarPaused` are template images; macOS tints them.
- `MenuBarRecordingLight` (black, for a light menu bar) and `MenuBarRecordingDark` (white, for a dark one) keep the red dot, so the app picks one by the menu bar's appearance.

Colors: navy `#14213D`, white `#FFFFFF`, record red `#FF4D4F`.

`scripts/build-app.sh` builds `AppIcon.icns` from the iconset and copies the menu bar images into the app.
