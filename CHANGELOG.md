# Changelog

## [2.0.0] - 2026-09-14

### Security
- Authentication cookies are sent only to HTTPS Substack hosts and are removed on cross-origin redirects.
- Article images are downloaded anonymously, with private-network URLs, insecure redirects, header injection, and oversized responses blocked.
- The session cookie is no longer copied into `substack_settings.json`.

### Added
- Reading progress and a Continue Reading section.
- Search across downloaded posts.
- Richer Latest, Saved, and Publications views with compact/comfortable feed density,
  publication/date context, and author bylines.
- Hold actions for read/unread state, refresh, and offline-copy removal.
- Grouped account, reading, sync, and storage settings.
- Cache statistics, atomic JSON writes, API pagination guards, per-post image limits,
  and automated regression tests.

### Changed
- Post rendering and offline sync now share one sanitization, image, and cache pipeline.
- SQLite writes are transactional and schema-versioned; image lookups are indexed.
- Online list failures automatically fall back to downloaded data.
- Sync yields between posts and reports progress instead of blocking for the entire batch.
- Dates, metadata, and plugin descriptions are translatable; UTF-8 titles are truncated safely.

### Fixed
- Correct next/previous position when opening any post in a list.
- Posts are marked read only after the viewer opens successfully.
- Image-incomplete cached posts are refreshed when images are later enabled.
- Custom input, malformed dates, corrupted settings, and partial API responses are handled defensively.

## [1.1.0] - 2026-08-17

### Added
- **Offline Batch Sync**: New "Sync for Offline" menu option batch-downloads recent posts (full content + images) to local SQLite cache for offline reading. Shows progress summary on completion.
- **Read/Unread Tracking**: Posts are automatically marked as read when opened. Unread posts are indicated with a bullet (•) prefix in post lists. Read status persists across sessions via SQLite.
- **Next/Previous Post Navigation**: New `< Prev` and `Next >` buttons in the viewer toolbar enable sequential browsing through post lists without returning to the menu. Title bar shows position (e.g. "2/10").
- **Font Family Selection**: New `Font: Sans/Serif/Mono` cycling button in the viewer. Selection persists across sessions.
- **Smart Image Download Bypass**: When images are toggled off (`Img: Off`), HTTP image downloads are skipped entirely during post fetching, significantly improving load speed on slow connections.

### Changed
- **Viewer Toolbar**: Reorganized into 2-row layout — Row 1: navigation + font family; Row 2: size, images, spacing.
- **HTML Sanitization**: All fetched post HTML is now cleaned via `SubstackUtils.clean_html()` before rendering.

## [1.0.4] - 2026-08-17

### Fixed
- **Subscriptions Crash**: Fixed a crash when opening "Subscriptions" caused by attempting to load non-existent module `ffi/unistd` during retry backoff, and resolved unsafe table traversal / sorting edge cases on subscription response data. Added fallback to reader inbox publications.
- **Max Post Limit > 20 Support**: Implemented automatic multi-page chunked fetching via pagination offsets (`limit=20`, `offset=...`) across inbox, saved, and publication post feeds, preventing HTTP 400 Bad Request errors when setting post limits above 20 (e.g. 40, 60, 100).
- **Network Retry Stability**: Replaced missing `ffi/unistd` with standard `socket.sleep` and restricted exponential backoff retries to genuine transient errors (HTTP 429 and 5xx) rather than 4xx client errors.
- **Type-Safe Post Sorting**: Fixed post list sorting comparator to prevent Lua type comparison runtime errors between timestamps and ISO strings.

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
