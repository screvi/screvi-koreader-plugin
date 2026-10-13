# Screvi for KOReader

Sync your [KOReader](https://koreader.rocks) highlights and notes to [Screvi](https://screvi.com), on Kindle, Kobo, PocketBook, Android or desktop.

- Connect with a short code. No typing an API key on an e-ink keyboard.
- Sends each highlight's text, note, page, chapter and date, with the book's title, authors and ISBN.
- Only sends what's new. Screvi also skips highlights it already has, so re-sending is always safe.
- Optional auto-sync when you close a book (only if Wi-Fi is already on).

## Install

1. Download `screvi-koreader.zip` from the [latest release](https://github.com/pedroaraujo74/screvi-koreader-plugin/releases/latest) and unzip it. You get a folder called `screvi.koplugin`.
2. Connect your e-reader by USB and copy that folder into KOReader's `plugins` folder:

   | Device | Folder |
   |---|---|
   | Kindle | `koreader/plugins/` |
   | Kobo | `.adds/koreader/plugins/` |
   | PocketBook | `applications/koreader/plugins/` |
   | Android | `koreader/plugins/` |
   | Linux (AppImage) | `~/.config/koreader/plugins/` |
   | macOS | `~/Library/Application Support/koreader/plugins/` |

3. Restart KOReader.

## Connect

1. In KOReader, open the top menu → **Tools** → **Screvi** → **Connect to Screvi**.
2. KOReader shows a code like `K7F2-9QXD` and a QR code. Scan it with your phone, or open [app.screvi.com/pair](https://app.screvi.com/pair) and type the code.
3. Approve it on Screvi. KOReader picks up its key within a few seconds.

Each device gets its own key, listed in Screvi under **Settings → API**. Revoke it there to disconnect that device. You can also paste a key by hand under **Screvi → API key**.

## Sync

- **Sync current book** sends new highlights from the open book.
- **Sync all books** sends new highlights from every book in your reading history.
- **Auto-sync when closing a book** sends new highlights when you close a book, if Wi-Fi is already on. It never turns Wi-Fi on; anything it skips goes out with the next sync.
- **Re-send all highlights** forgets what was sent. Screvi skips what it already has, so this only fills gaps.

Both sync actions are also in KOReader's gesture and shortcut manager, under "Screvi".

## How it works

- Reads highlights from KOReader's annotations (2024.05 and later) and from the older `highlight`/`bookmarks` sidecar format. Page bookmarks are not highlights and are left out.
- Sends them to Screvi's import API in batches of up to 500.
- Remembers what it has sent in `screvi_settings.lua` in KOReader's settings folder. A highlight counts as sent only after Screvi accepts it.
- Editing the note on a highlight that was already sent re-sends it, but Screvi keeps the first version: it matches highlights by book and text.

## Development

The tests run the real `main.lua` against stubbed KOReader modules:

```sh
brew install luajit   # or your package manager
luajit spec/run.lua
```

`./build-zip.sh` runs the tests and writes `dist/screvi-koreader.zip`, the asset attached to each release.

```
screvi.koplugin/
├── _meta.lua   # Plugin metadata
└── main.lua    # Plugin logic
spec/
└── run.lua     # Test harness
```

## License

[AGPL-3.0](LICENSE), the same license as KOReader.
