# Changelog

## [1.0.3] - 2026-01-06

### Added
- **Gesture Support**: You can now assign "Substack Reader" to gestures or the QuickMenu (via Dispatcher registration).

### Fixed
- **Image Toggle**: Fixed an issue where the "Img: Off" setting was ignored when first opening a post.
- **Network Robustness**: Added retry mechanism with exponential backoff (0.25s, 0.5s, 1.0s) for HTTP 400 and 5xx errors to handle flaky connections.
- **Cookie Handling**: Now strictly checks for cookie presence before making requests. `substack_cookie.txt` is now the authoritative source, and removing it will correctly invalidate the session immediately.

## [1.0.2] - 2026-01-05

### Added
- **Image Toggle**: Option to toggle images on/off in the viewer.

### Changed
- **Refactoring**: Major code cleanup and deduplication. Separated viewer and utility logic into dedicated modules (`substack_viewer.lua`, `substack_utils.lua`).

## [1.0.1]

### Changed
- **HTML Widget**: Implemented a simple HTML widget for better rendering stability.

## [1.0.0]

### Added
- **Favourites System**: You can now mark newsletters as favourites. Use "Manage Favourites" in the subscription list to toggle. Favourites appear at the top.
- **Configurable Post Limit**: You can now set the number of posts to fetch (1-100) via the menu.
- **Post Dates**: Publication date is now displayed in the post header.
- **Enlarged Image Viewer**: Clicking images now opens them in the native KOReader image viewer for better zooming/panning.
- **Simplified Cookie Setup**: Now uses `substack_cookie.txt` for simpler authentication setup.
