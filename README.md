# Substack Reader for KOReader

An unofficial, reading-first Substack client for KOReader. Browse your latest and
saved posts, organize publications, search downloads, and read offline.

## Highlights

- Latest, Saved, Publications, Continue Reading, and downloaded-post search.
- Comfortable and compact feed layouts with publication/date context, unread state,
  and offline indicators.
- Per-post hold actions: mark read/unread, refresh, or remove the offline copy.
- Offline sync with optional images, progress reporting, and automatic cached fallback.
- Persistent reading position, typography controls, next/previous navigation, and favourites.
- Transactional SQLite cache with storage statistics and schema migration.

## Install

Copy the complete `substack.koplugin` directory into KOReader's `plugins` directory,
then restart KOReader. The resulting path must end in:

```text
koreader/plugins/substack.koplugin/main.lua
```

This release expects a current KOReader build with SQLite UPSERT support and the
standard `socketutil`, `ScrollHtmlWidget`, and `Menu` APIs.

## Sign in

This plugin uses the `substack.sid` session cookie from a signed-in browser.
Treat this value like a password: anyone who obtains it may be able to access your
Substack account.

1. Sign in at `https://substack.com` in a desktop browser.
2. Open the browser's developer tools and locate cookies for `substack.com`.
3. Copy only the value of `substack.sid`.
4. Put that value in `koreader/settings/substack_cookie.txt` on the device.
5. Open **Substack Reader → Settings → Account** to test it.

Removing the file and reopening Substack Reader removes the credential from the
active client. Changing regular plugin settings does not copy the cookie elsewhere.

## Privacy and network behavior

- The authentication cookie is attached only to HTTPS requests whose host is
  `substack.com` or a `*.substack.com` publication host.
- Cross-origin article images are downloaded without authentication.
- HTTP URLs, HTTPS-to-HTTP redirects, URL credentials, private-network image hosts,
  control characters in cookies, and excessive response sizes are blocked.
- Post content, metadata, images, read state, and reading progress are stored locally
  in KOReader's settings directory until offline storage is cleared.

## Interface

- **Continue reading** resumes partially read downloaded posts.
- **Latest** shows the reader inbox.
- **Saved** shows remotely saved posts.
- **Publications** lists followed publications; hold one to toggle its favourite state.
- **Search downloads** searches locally cached title, publication, and body content.
- **Sync for offline** downloads the configured number of recent posts.
- **Settings** controls account status, density, images, sync, post limit, offline mode,
  and storage.

In a post list, tap to read or hold for post actions. A downward arrow in the
publication label indicates that an offline copy exists.

## Limitations

Substack does not publish a stable reader API for this use case. Its private web
endpoints and response shapes may change without notice. The plugin intentionally
does not perform account-writing operations such as likes, comments, restacks,
subscriptions, or remote read/archive updates.

The HTML sanitizer is designed for KOReader's non-browser HTML widget; it is not a
general-purpose browser security sanitizer. Audio and video posts are not downloaded.

## Troubleshooting

- **Sign-in needed:** recreate `substack_cookie.txt` with a current `substack.sid` value.
- **Refresh failed; showing downloaded data:** the network or Substack endpoint failed,
  but the last local response is still usable.
- **Partial publications:** the dedicated subscription endpoints failed, so the plugin
  derived publications from recent inbox posts.
- **Images unavailable:** the asset was insecure, private, too large, unsupported, or
  failed to download.

## Tests

With Lua installed, run this from the directory containing the plugin:

```sh
lua substack.koplugin/tests/run.lua substack.koplugin
```

The test suite stubs KOReader services and exercises URL/authentication policy,
redirect credential stripping, pagination guards, UTF-8 handling, and HTML cleanup.

## Fork lineage

This project is a maintained fork of
[anserina/substack.koplugin](https://codeberg.org/anserina/substack.koplugin).
Version 2.0 adds the redesigned interface, offline library features, and security
hardening while retaining the original repository history and MIT license.

## License

MIT. See `LICENSE.txt`.
