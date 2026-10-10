# AutoWords

**A word-count-aware auto page turner for [KOReader](https://koreader.rocks/).**

AutoWords decides when to turn the page from *how much text is on screen right now*,
instead of waiting a fixed number of seconds. A dense page gets more time; a page holding
three lines gets less. The reading speed can be calibrated on the very page you are
looking at.

*Read this in [简体中文](README_zh-CN.md).*

---

## Why another auto-turner?

KOReader ships **AutoTurn**, which waits a fixed interval before every page turn. A fixed
interval always forces a compromise: tune it for dense pages and sparse pages feel
sluggish, tune it for sparse pages and dense ones turn before you finish them.

AutoWords measures the visible text and computes a delay per page:

```
delay = (units of text on screen) / (reading speed) * 60 seconds
```

## Features

| | |
| --- | --- |
| 📖 **Paced by text** | Every page turn is timed from the amount of text actually visible |
| 🎯 **Calibrated in place** | The dialog always shows this page's count and the resulting delay; *Calibrate on this page* derives your speed from a single number you type |
| 🔤 **Two counting modes** | *Characters* (every non-space UTF-8 code point, CJK-friendly) or *Words* (CJK per character, latin per word) |
| ⏱️ **Floor and ceiling** | Never turn faster than N seconds, never wait longer than M |
| 👆 **Restart on touch** | Touching the screen restarts the countdown for the current page |
| 📐 **Page distance** | How far the view moves per turn (fractional values work in scroll mode) |
| 📖 **Sentence guide** | ⚠ experimental, see below — walks the text sentence by sentence, underlining the sentence being read (never saved as an annotation) |
| 🅰️ **Status-bar icon** | A small selectable badge in the top (*Alt status bar*) and/or the bottom status bar, visible only while AutoWords runs |
| 🎛️ **Gestures / shortcuts** | Registered as dispatcher actions: `AutoWords: start/stop`, `AutoWords: settings` |
| 🩺 **Diagnostics** | One dialog listing every piece of state that matters when the icon does not show up |
| 🌐 **Localized UI** | Follows KOReader's language; English and Simplified Chinese ship in-tree |

## Requirements

- **KOReader** — developed and verified against current `master` sources.
- **Reflowable documents only**: EPUB, FB2, TXT, HTML … (anything rendered by crengine).
  PDF and DJVU are detected and refused on purpose — their text cannot be measured cheaply,
  and the plugin says so instead of silently misbehaving.
- The *top* status bar is optional and needs KOReader's **Alt status bar** to be enabled.

## Installation

The repository root **is** the plugin directory, so installing is just cloning it into
KOReader's `plugins` directory — you should end up with `plugins/autowords.koplugin/`:

```sh
cd <KOReader install dir>/plugins
git clone https://github.com/khhf/autowords.koplugin.git
```

Or download the ZIP from the [releases page](https://github.com/khhf/autowords.koplugin/releases)
and unpack it so that the plugin files sit in `plugins/autowords.koplugin/`.

Then restart KOReader **completely** — returning to the file browser is not enough.

| Platform | `plugins` directory |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `.kobo/koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| Linux / macOS | `<KOReader install dir>/plugins/` |

Pure Lua, nothing to compile. If no menu entry shows up afterwards, check
*Plugin management* in KOReader's menu.

## Usage

1. Open a book, then **top menu → Navigation → AutoWords**.
2. The dialog shows what AutoWords measured:

   ```
   This page: 486 characters
   Reading speed: 300 characters/min
   → AutoWords waits 97.2 s on this page
   ```

3. Press **Calibrate on this page** and type how many seconds this page takes you — say 80.
   The speed is derived and saved (486 ÷ 80 × 60 ≈ 365 characters/min).
4. Press **Start**. From then on every page is measured and timed individually, and a
   small icon appears in your status bar. Press **Stop** to end it — the icon disappears
   immediately.

### Status-bar icon

By default the badge lives in the **top status bar** (KOReader's *Alt status bar*), where
crengine draws it at the left end of the right-hand block, just before the page number:

```
┌──────────────────────────────────────────────┐
│ Book title · chapter               Ⓐ 12/240  5.0% │
├──────────────────────────────────────────────┤
│                                              │
│                   text …                     │
│                                              │
└──────────────────────────────────────────────┘
```

*More settings → Icon position* switches between **Top / Bottom / Both / Hidden**. The
bottom bar is only touched when you explicitly ask for it (see the note in *How it works*).

- The **top** bar needs KOReader's Alt status bar to be enabled (reader menu → Alt status
  bar); without it that bar does not exist and no icon can be shown.
- In the **bottom** bar the icon is the *External content* item of KOReader's status bar
  settings — the official hook third-party plugins are given, the same one the stock SSH
  and ReadTimer plugins use.
- The icon is **not clickable**: KOReader gives its own status-bar taps higher priority
  (top = open menu, bottom = cycle the status-bar mode), so a plugin cannot win that
  fight. Open the settings from the menu, or bind `AutoWords: settings` to a gesture.
- If the character renders as an empty box, your font lacks that glyph — pick another one
  under *More settings → Icon character*; `(A)`, `[A]` and `A` are plain ASCII and always work.

## Settings

| Menu item | Description | Default |
| --- | --- | --- |
| Reading speed | Units per minute, 10–3000 | 300 |
| Reading mode | **Whole page** (stable) / **Sentence guide** (⚠ experimental, mutually exclusive) | Whole page |
| Calibrate on this page | Derives the speed from this page plus a duration you type | — |
| Counting mode | **Characters** (every non-space UTF-8 code point) / **Words** (CJK per character, latin per word) | Characters |
| Minimum delay | Never turn faster than this — handy for image-only pages | 2 s |
| Maximum delay | Upper bound, 0 = no limit | none |
| Restart after touch | Touching the screen restarts the countdown for the current page | on |
| Page distance | How far the view moves per turn, 1 = one screen | 1 |
| Min. sentence time | A sentence stays on screen at least this long (sentence guide) | 0.8 s |
| Punctuation pause | Scales every punctuation pause at once | 1.0x |
| Paragraph pause | Extra time when a sentence ends a paragraph | 0.6 s |
| Icon position | Top / Bottom / Both / Hidden | Top |
| Icon character | `Ⓐ ⓐ (A) [A] A ●` | Ⓐ |
| Diagnostics | Dumps plugin and status-bar state | — |

## How it works

### Measuring the text

AutoWords counts the text of the **currently visible area**
(`document:getTextFromPositions({x=0,y=0}, {x=screen_w, y=screen_h}, true)`) — the same
call KOReader's own status bar uses for its line/word counter. In scroll mode this is the
only meaningful definition anyway, and it means the count follows your font size, margins
and layout changes for free.

> `document:getPageText()` looks like the obvious API but is a trap: the base
> implementation calls `self._document:openPage()`, which **crengine documents do not
> have** — on an EPUB it raises *"attempt to call a nil value (method 'openPage')"*. It
> exists for the MuPDF backend, where it returns structured data rather than a string.

Counting itself is a single linear scan of the returned string (`autowords_count.lua`,
no intermediate tables), with the two modes described above.

### Timing

`count / speed * 60` seconds, clamped to the minimum and maximum delay. The result is
handed to `UIManager:scheduleIn()`, the same timer API the stock AutoTurn plugin uses.

There is **no polling**: the plugin computes a delay once per page, schedules one
callback, turns the page when it fires and then measures the new page. Idle cost is zero.
`PluginShare.pause_auto_suspend` is set while running so the device does not auto-suspend
mid-read.

Page changes (manual ones included) arrive as `PageUpdate` / `PosUpdate` events and
restart the countdown, so turning a page by hand never leaves you waiting for the old
page's timer. At the end of the document (a forward move that changes nothing, or
crengine's `EndOfBook` event) AutoWords stops itself instead of spinning.

### The status-bar icon

Neither status bar can host a plugin widget — both are text:

- The bottom bar is a single `TextWidget` filled by `ReaderFooter:genFooterText()`;
  plugins contribute through `ReaderFooter:addAdditionalFooterContent(func)` (this is what
  the stock SSH and ReadTimer plugins use, and why the entry is called *External content*).
- The top *Alt status bar* is painted by **crengine itself**: KOReader hands it a string
  through `ReaderCoptListener:updatePageInfoOverride()`, and plugins prepend to it via
  `crelistener:addAdditionalHeaderContent(func)`. Because crengine draws that whole string
  **right-aligned**, a prepended icon ends up at the left end of the right-hand block.

`ReaderFooter:addAdditionalFooterContent()` has a side effect worth knowing about: the
first call rebuilds the mode index and runs `updateFooterTextGenerator()`, which rewrites
`footer.mode` to the first enabled item. AutoWords therefore (1) only registers with the
bottom bar when you ask for it, (2) does so after the document is ready rather than during
plugin `init()`, and (3) saves and restores `footer.mode` around the call.

### Cost

One crengine text extraction plus one linear scan per page turn, nothing else — no timer
faster than the page turn itself, no per-frame work. The icon is text, so drawing it costs
KOReader exactly nothing.

### The sentence guide — ⚠ experimental

> **This mode has not been verified on a real device yet.** Its logic is covered by the
> offline test suite, but no line has ever been seen on a screen. It may do nothing, or
> stop right after starting. The default mode is *Whole page*, which is unaffected.
> If you try it and nothing happens, *More settings → Diagnostics* shows where it stopped.

*Sentence guide* is the second reading mode (the two modes are mutually exclusive):
instead of timing whole pages, it walks the text one sentence at a time and keeps a single
underline under the sentence being read.

- **Sentences are found by scanning the visible text**: the guide starts at the
  first character on screen (`document:getTextFromPositions()`, the call KOReader's own
  status-bar word counter uses) and walks forward with `getNextVisibleChar()` until a
  sentence-ending punctuation mark, so the next sentence starts exactly where the
  previous one ended. (It deliberately avoids
  `document:extendXPointersToSentenceSegment()`: that only works when the position sits
  right after punctuation and returns nothing otherwise, which made the guide give up on
  real books.)
- **The underline is not an annotation.** It is drawn through KOReader's
  *temporary* highlight (`view.highlight.temp` with
  `view.highlight.temp_drawer = "underscore"`), the same mechanism dictionary
  lookups use. Temporary highlights are painted on screen and never written to
  the document settings, so **nothing this plugin draws can show up in the
  bookmark/annotation list**, and nothing is added to your highlights when you
  export them later.
- **Pacing** is the reading time of the sentence plus the pauses a reader
  naturally takes:

  ```
  delay = characters / speed * 60
        + commas × 0.15 s + semicolons × 0.25 s + dashes × 0.15 s
        + (sentence ends ? 0.4 s)
        + (paragraph ends ? 0.6 s)
  ```

  with a floor of *Min. sentence time* (0.8 s by default) — without it a page of
  short dialogue lines would race past. *Punctuation pause* scales all the
  punctuation terms at once (0 disables them, 2 doubles them).
- **Scrolling**: when the current sentence would drop below about 2/3 of the
  usable height (or has gone off the top), the view scrolls so that the sentence
  sits about 1/3 from the top, always leaving text visible underneath it.
- **Manual control**: bind *AutoWords: next sentence*, *AutoWords: previous
  sentence* and *AutoWords: pause/resume* to gestures to drive the guide by hand.
  Touching the screen restarts the countdown for the current sentence, and pausing
  keeps the underline where it is, so you can look away without losing your place.

## Known limitations

1. **No PDF / DJVU / image documents.** The text cannot be measured there; the plugin
   detects it and refuses to start rather than guessing.
2. **Top status bar only exists in paged mode** and only when KOReader's *Alt status bar*
   is enabled; crengine does not draw it in scroll mode.
3. The count is the **visible area**: in two-column mode that is both columns, and a
   running header or page number inside the text flow is counted too.
4. If the text extraction returns nothing (image-only page, document still laying out),
   the count is 0 and the *minimum delay* applies — the plugin never stalls.
5. **Menus and dialogs pause the turning**: while another window is on top, AutoWords
   retries every 2 s instead of turning pages behind your menu.
6. The reading speed is a single number — calibrate it once with *Calibrate on this page*
   and it will fit your language and typography; the default 300 units/min is a guess.
7. Localization of the readings themselves (KOReader needs `.po` catalogues, which a
   user-side plugin cannot install) is done with a small in-tree table for Simplified
   Chinese, falling back to KOReader's own translations everywhere else.

8. **The sentence guide needs a reflowable document** (it relies on crengine sentence
   xpointers); PDF and DJVU are refused in that mode.
9. The underline moves every few seconds and is repainted partially; on e-ink, ghosting can
   show up — raising *Min. sentence time* helps a lot.
10. Dictionary lookups and text selection use the same temporary highlight and briefly cover
    the underline; it comes back afterwards.

## Troubleshooting

**The icon does not show up.** Open *More settings → Diagnostics*. It lists, among others:

- `Plugin loaded`, `Running` — has the plugin been started at all?
- `Icon position` — is it set to *Top* while the Alt status bar is off?
- `Status bar found` / `Status bar visible` — is the bottom bar there and shown?
- `Alt status bar (top)` — is KOReader's Alt status bar enabled for this document?
- `Status bar content registered` / `Alt status bar content registered` — did the
  registration succeed?
- `Text on this page` — did the text measurement return anything?

**The bottom status bar changed or looks wrong.** KOReader's `addAdditionalFooterContent()`
recomputes the bar's mode the first time it is used (see *How it works*). Keep *Icon
position* on **Top**, or uncheck *External content* in KOReader's status-bar settings.

**Pages turn too early / too late.** Use *Calibrate on this page* on a typical page, and
check *Counting mode*: a page of English prose counted in *characters* gives roughly five
times the number of *words*.

## Development

The plugin is plain Lua, and the test suite runs offline — no device, no KOReader
required. It loads the real `main.lua`, `autowords_count.lua` and `autowords_guide.lua`
with stubbed KOReader modules and checks counting, delay math, the scheduling state
machine, the lifecycle hooks, every dialog, the status-bar registration, and the sentence
guide (punctuation classification, sentence boundaries, pacing, underline and scrolling).

```
python -m pip install lupa      # test runner only; the plugin itself has no dependencies
python tests/run_tests.py
```

Current status: **258 checks, 0 failures**.

```
.                            # the repository root is the plugin directory
├── _meta.lua                # plugin metadata
├── main.lua                 # timing, page turning, menu, dialogs, status-bar wiring
├── autowords_count.lua      # dependency-free UTF-8 counting
├── autowords_guide.lua      # sentence guide: stepping, underline, pacing, scrolling
├── autowords_i18n.lua       # UI strings (Chinese table + KOReader gettext)
└── tests/                   # not installed, development only
    ├── run_tests.py         # runner (lupa)
    └── test_autowords.lua   # the tests themselves
```

### Verification status

Everything was derived from the KOReader `master` sources (file and line references are in
the code comments) and is covered by the offline test suite.

- **Whole page mode and the status-bar icon have been used on a real device.**
- **The sentence guide has not.** It ships as an experiment: the logic is tested, the
  drawing is not. Diagnostics output and logs are very welcome.

## Contributing

Issues and pull requests are welcome. Please run the test suite before submitting a
change; if you touch the counting or the timing, add a case for it.

## Acknowledgements

- [KOReader](https://github.com/koreader/koreader) — the reader this plugs into, and the
  source of every API used here.
- The stock **AutoTurn** plugin, which this one is deliberately modelled after (same timer
  API, same suspend handling), and **SSH** / **ReadTimer**, whose use of
  `addAdditionalFooterContent()` showed the way.

## License

[MIT](LICENSE) © 2026 khhf
