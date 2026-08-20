# LilTerminal

A macOS terminal built around vertical tabs, tab groups, and live per-tab
resource metering — for running many long-lived sessions at once without the
tab list turning into noise.

## Building and installing

```sh
./make.sh              # debug build   -> build/LilTerminal.app
./make.sh --release    # optimized build
./make.sh --install    # release build, installed to /Applications, relaunched
./make.sh --dmg        # release build -> dist/LilTerminal-<version>.dmg
```

Requires macOS 14+ and a Swift 6 toolchain.

`--install` is the normal way to ship yourself a new version: it quits the
running copy first (replacing a bundle underneath a live process leaves it
running stale code), replaces `/Applications/LilTerminal.app`, re-registers with
Launch Services so the icon and version refresh, and relaunches.

The icon is generated from `Tools/makeicon.swift` rather than checked in as a
binary — `make.sh` regenerates the `.icns` whenever that source is newer, so the
icon is editable code like everything else.

## Local AI (opt-in, off by default)

Four features, each separately switchable, all running on this Mac. Settings → AI.

- **Tab activity** — labels each tab *needs you* / *working* / *done* / *failed*.
  This is the one that earns its place: no process-tree heuristic can tell a
  build that is running from an agent sitting at a prompt waiting for you.
- **Auto-naming** — turns a tab called `~` into `refactor auth`.
- **Error triage** — one line explaining a failed command, shown in History.
- **Search history by description** — when substring search finds little.

**Backends.** `Apple on-device` (macOS 26, nothing to install, memory belongs to
the system) or `Ollama` (install separately, choose your own model).

The Ollama pane starts the server if it is installed but not running, lists what
is already pulled, and offers a short catalog to download in place with live
progress. Every entry is costed against *this* Mac — size, share of physical
memory, and a warning when a model would force swapping. The catalog is
deliberately small models: everything here is labelling, and a 1-3B model does
that as well as a 7B while costing a third of the memory.

### Not making pointless calls

The scheduler exists to refuse work. Every request clears four gates: the
feature is on, the input hash actually changed since the last answer, the
per-key cooldown has elapsed, and nothing identical is already running.
Concurrency is capped at one. On top of that:

- The focused tab is skipped — you can already see what it is doing.
- Tabs can be excluded individually from the sidebar's context menu.
- Auto-naming never runs for a tab with no commands, or one you have renamed.
- Error triage is pre-filtered by a plain substring check; output with no sign
  of failure never reaches a model.
- Semantic search is debounced and only fires when literal search came up short.
- A failed call still records its input hash, so a broken backend is not retried
  on unchanged input every cooldown.

### Working directory

The sidebar's branch and path come from reading the shell's cwd directly with
`proc_pidinfo(PROC_PIDVNODEPATHINFO)`, not from OSC 7. macOS only wires up OSC 7
when `TERM_PROGRAM` is `Apple_Terminal`, so any other terminal never hears about
a `cd` at all — waiting for the shell to report it means never knowing where it is.

### Not leaking

- `AICoordinator` holds `Workspace` weakly; tabs and sessions are looked up by
  id at use time, so an in-flight request cannot keep a closed tab alive.
- A fresh `LanguageModelSession` per request. Reusing one accumulates a
  transcript, which for thousands of small classifications is a leak in
  everything but name.
- Scheduler bookkeeping is pruned past 200 keys; history is capped at 500
  entries; closing a tab drops its keys and cancels its in-flight work.
- Ollama is asked to unload after two minutes idle, so an idle terminal is not
  holding gigabytes.

## Pinning and locking

- **Pin** (`⌘⇧P`) sorts a tab to the top of the sidebar and holds it there.
- **Lock** (`⌘⇧L`) makes a tab refuse to close without confirmation. Groups can
  be locked too, which covers every tab inside them.
- **Lock App** (File menu) makes quitting ask first.

Locks are enforced in `Workspace.requestClose` and in
`applicationShouldTerminate` rather than at each call site, so a stray `⌘W` or
`⌘Q` cannot take out a long-running job by accident. Pin and lock state persists
with the session layout.

## Engine

The terminal engine is **Ghostty** (`libghostty-vt`), and the rendering is this
app's own. SwiftTerm has been removed entirely.

Ghostty parses the VT stream and owns terminal state; `Engine/` owns everything
else: `PTY.swift` spawns and talks to the shell, `GhosttyTerminalView.swift`
draws with CoreText, `KeyEncoder.swift` encodes keys through Ghostty's encoder
(so cursor-key application mode and the Kitty protocol are honoured rather than
guessed), and `GhosttyCore.swift` wraps the engine.

Owning the draw is the point: cells carrying no explicit background are simply
not painted, so **terminal transparency and blur work** — measured at
`(51,50,54)` where opaque would be `(18,18,23)`. SwiftTerm could not do this on
any path tried, including its documented `backgroundOpacity` and its Metal
renderer.

`Vendor/ghostty-vt` is committed so the app builds without a Zig toolchain;
`Tools/build-ghostty-vt.sh` regenerates it from the pinned revision. It links
dynamically on purpose: Zig bundles its own compiler-rt, whose
`___isPlatformVersionAtLeast` collides with Swift's runtime at static-link time.

### Find

`⌘F` opens an inline find bar seeded from the selection; `⌘G` / `⌘⇧G` step
through matches and `Esc` closes it. The menu commands only signal direction —
the bar owns the term — so there is one source of truth for what is being
searched.

### Mouse reporting

Clicks, drags, right-click and wheel are encoded through Ghostty's mouse
encoder, synced from the terminal so the program's chosen protocol (X10, normal,
button-event, any-event, SGR) is honoured rather than guessed. Motion tracking
areas are only installed while a program actually wants them.

**Holding Shift always reaches selection**, even while a program is tracking —
the long-standing convention for copying out of something like `vim`.

### Redraw

Frames are diffed row by row and only changed rows are invalidated. Measured
during incremental output: **~10-13% of rows redrawn per frame** instead of
100%, rising to ~39% during scroll bursts where most rows genuinely change.
Structural changes (a resize, a column count change) still fall back to a full
repaint, which is cheaper than reasoning about them row by row.

### Two bugs worth remembering

Both cost real time and neither was where it looked.

**Cells must be addressed by column.** The row-cells iterator does not
necessarily yield one entry per column, so a running counter drifts out of step
with the grid. Use `ghostty_render_state_row_cells_select(cells, column)`.

**`CTLineDraw` mutates the context's text matrix.** Setting
`context.textMatrix = .identity` once per frame is not enough: a single fallback
glyph — one emoji — permanently transforms everything drawn after it. The
symptom looked like rows landing at wrong positions, so the search went to row
indexing and threading; the cause was text drawing. Reset it per draw call.

## Architecture

| Area | Files |
|---|---|
| Terminal engine | `Engine/GhosttyCore.swift`, `Engine/PTY.swift`, `Engine/GhosttyTerminalView.swift`, `Engine/KeyEncoder.swift` |
| Shell discovery | `Model/ShellCatalog.swift` |
| Session / tab / pane model | `Model/TerminalSession.swift`, `Model/Tab.swift`, `Model/Pane.swift` |
| App state | `Model/Workspace.swift` |
| Themes | `Model/AppTheme.swift`, `UI/ThemeEditor.swift` |
| Preferences | `Model/Preferences.swift`, `UI/SettingsView.swift` |
| CPU / memory sampling | `Metrics/ProcessSampler.swift` |
| UI | `UI/SidebarView.swift`, `UI/PaneView.swift`, `UI/RootView.swift`, `UI/Chrome.swift` |

### A note on observation

Most bugs found while building this were the same SwiftUI trap: a view observing
`Workspace` never hears about state that lives on `Tab` or `ThemeStore`. If a
value renders stale — metrics stuck at zero, a split not appearing, chrome not
following a theme change — the fix is almost always to observe the object that
actually owns the value, not the one that holds a reference to it.

### Resource metering

`ProcessSampler` sweeps the whole process table once per second via `libproc`
(`proc_listallpids` + `PROC_PIDTASKALLINFO`), builds a parent→child index, and
walks each session's descendant tree. One sweep serves every tab, so cost is
O(total processes) rather than O(tabs × depth).

CPU is a rate, differentiated against the previous sample. Memory is summed
resident size across the shell and all its children — so a tab running a build
reports the build's memory, not the shell's.

**This is why the app is not sandboxed.** Reading other processes' resource
usage is impossible inside the App Sandbox, so distribution is direct-download
only, never Mac App Store.

### Background job auto-filing

A tab that has been left alone for over two minutes while still running child
processes is moved into a collapsed "Background" group. The heuristic keys on
*human attention* (time since last keystroke), not process activity — the goal
is to file away what you are not watching. Toggle in Settings → Terminal.

## History, library and palette

The right inspector (`⌘⌥I`) has two panels:

- **History** — every command this tab ran, with duration, captured from the
  rendered prompt line at the moment Return is pressed. Reading the line the
  shell actually shows survives line editing, history recall and tab completion,
  which a buffer of keystrokes does not.
- **Library** — Snippets, grown into a prompt library with folders and search.
  Deliberately the same system rather than a second one: one editor, one store,
  one set of bindings.

`⌘K` opens a command palette over tabs, snippets, recent history, themes and
actions, ranked by a subsequence match that favours tighter, earlier hits.

Long commands announce themselves when they finish (default: over 20 seconds,
and only when you are not already watching that tab). A notification for every
`ls` would train you to ignore them.

Each tab shows its **git branch** with a dot when the worktree is dirty.

## Clickable output, prompt jumping, paste guard, tab filter

**Cmd-hover** underlines a URL or file path in the output; **Cmd-click** opens
it. `file.swift:42` opens at that line. Relative paths resolve against the
shell's real directory.

**⌘↑ / ⌘↓** jump between previous commands. Positions are recorded when Return
is pressed rather than found by scanning, because a prompt's appearance is not
something that can be parsed reliably.

**Paste guard** (Settings → Terminal) confirms a paste that spans multiple lines,
ends in a newline, or contains something destructive — and shows you the text
first. The case it exists for is copying from a web page: text ending in a
newline runs the moment it lands, before you have read it.

**⌥⌘F** filters the sidebar by name, branch, directory or activity; Return jumps
to the top match. It appears on its own once there are six or more tabs.

## Keyboard shortcuts

| | |
|---|---|
| `⌘T` | New tab |
| `⌘⌥1…9` | New tab with the *n*th discovered shell |
| `⌘W` / `⌘⇧W` | Close tab / close focused pane |
| `⌘D` / `⌘⇧D` | Split right / split down |
| `⌘⌥]` `⌘⌥[` | Next / previous pane |
| `⌘⇧]` `⌘⇧[` | Next / previous tab |
| `⌘1…9` | Jump to tab |
| `⌘⇧N` | New group |
| `⌘B` | Toggle sidebar |
| `⌘D` / `⌘⇧D` | Split right / down (also in the toolbar) |
| `⌘+` `⌘-` `⌘0` | Font size |
| `⌘,` | Settings |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘⇧↩` | Zoom focused pane |
| `⌃⌥` + key | Run a snippet |

## Tabs and panes

Tabs reorder by dragging, and drag between groups; an insertion line shows where
the tab will land. Double-click a tab to rename it (context menu → Reset Name
returns it to tracking the running command).

`⌘⇧↩` zooms the focused pane to fill the tab — useful when one pane of a busy
split needs the whole window. The layout is untouched and comes back on the next
press. Opening Find in a narrow pane zooms automatically, because SwiftTerm's
find bar has fixed-width controls that would otherwise be clipped off the edge.

## Where settings live

Everything you configure — preferences, themes, snippets, groups, the active
theme — is one JSON document:

```
~/Library/Application Support/LilTerminal/settings.json
```

**Not UserDefaults.** `~/Library/Preferences` is the first thing an uninstaller
clears and the last thing anyone thinks to back up. A plain file in Application
Support survives dragging the app to the Trash, can be copied to another Mac,
and is readable when something goes wrong.

**Keychain mirror.** A cleaner utility removes the support folder too, so the
document is also mirrored into a keychain item (`app.lilterminal.settings`).
On launch the order is: settings file, then keychain, then a migration from the
old UserDefaults layout, then defaults. Settings → Storage reports which one it
actually used, so the recovery is visible rather than assumed.

Verified by deleting the app, the support folder *and* the defaults plist, then
reinstalling: settings came back from the keychain and the pane read
"Loaded from: keychain backup".

Caveat worth knowing: this app is signed ad-hoc, so a rebuilt copy has a
different signature and macOS may ask permission the first time it reads the
keychain item. It did not prompt in testing, but a properly signed build would
make that guarantee rather than a hope.

Session layout (`layout.json`) is deliberately *not* mirrored. It is state, not
configuration — which tabs were open is not worth restoring onto a different
machine.

**Moving machines**: Settings → Storage → Export writes the whole document to a
file; Import reads it back.

## Persistent sessions

`Settings → Terminal → Keep shells running after quit`. Off by default: it
changes where your processes live.

With it on, shells are owned by `lilterm-sessiond`, a small helper that ships
inside the bundle and outlives the app. Quitting — or crashing — no longer kills
a long job, and relaunching reattaches to the same processes with their recent
output replayed. Verified by `kill -9` on the app: same shell pid before and
after, no second shell spawned.

The helper is deliberately minimal: one Unix socket, newline-delimited JSON, and
the shared pty code. It exits on its own once no sessions and no clients remain.
Output is base64 inside the JSON frames — less efficient than a binary channel,
but the whole protocol stays inspectable with `nc`, which matters for something
designed to outlive the app.

### Three bugs this shook out

**Liquid Glass does not clip what it is applied to.** `glassEffect(_:in:)`
draws the material in the shape you give it and nothing more — unlike the solid
and frosted branches, which follow it with `.clipShape`. The Liquid Glass branch
had no clip, so each bar's own inner fills (the sidebar's footer, the inspector's
header) ran square past the glass and every panel corner read as a hard-edged
slab. This is the one that actually produced the reported square corners; the
`NSViewRepresentable` issue below is real but was a second, separate instance of
the same class of bug.

**SwiftUI's `clipShape` does not clip an `NSViewRepresentable`.** The terminal
content area was wrapped in a rounded `clipShape` and looked correct in every
mock, but AppKit draws the hosted terminal view outside that mask, so the pane
kept hard 90° corners while the sidebar and inspector either side of it were
rounded — the terminal read as a square slab. The rounding has to be applied to
the hosting view's own layer (`cornerRadius` + `masksToBounds`), and
unconditionally: it was previously tied to the split focus ring, so an unsplit
window never got it at all. `NSVisualEffectView` needs the same treatment, via
`maskImage` rather than a layer radius — behind-window blending composites below
the layer tree, where layer masking is ignored.

This is also why the status bar is a sibling panel rather than an overlay on the
terminal card. Sitting inside it, the bar had to paint its own surface over a
background configured separately from it, so the two never matched — and the
pane's bottom corners became an interior boundary that could not be rounded
without carving a notch above the bar. Beside the terminal, both problems go
away and the two surfaces simply agree.

**Merging settings over defaults has to recurse.** A shallow merge fixes the
top level and quietly reintroduces the same bug one level down: adding a field
to a nested object — a bar's `shadow`, say — meant that object no longer decoded,
which failed the whole document and reset *everything* to defaults. It presented
as unrelated features breaking at random: a background image path silently
cleared, a theme reverting. `deepMerge` recurses into nested objects.

**The session list is not optional.** `hasSession` was consulted before the
daemon's inventory arrived, so it answered "no" for everything and the app
started a *second* shell beside the one it had just survived — while looking
like it had reattached. Connecting now waits (briefly, with a timeout) for that
first reply.

**Ring buffers must be trimmed at line boundaries.** Cutting the replay buffer
at an arbitrary byte can slice an escape sequence or a UTF-8 character in half,
and the replay then feeds a malformed stream into a fresh parser.

**Replayed history keeps its old wrapping.** Bytes written at 80 columns still
wrap at 80 when replayed into a 92-column terminal. After reattaching, the
session is sent `Ctrl-L` so the live prompt is redrawn at the current width.

## Session restore

Tabs, groups, splits, pane proportions, custom names, and working directories
are restored on launch. **Commands are never re-run** — restoring a shell's
history of side effects would be surprising and occasionally destructive. The
layout is written on every structural change and again on quit, so the saved
directories reflect wherever you had `cd`'d to. Disable in Settings → Terminal.

## Snippets

Text macros sent to the focused pane, bound to `⌃⌥`+key. Ships with a git set
(`⌃⌥A` stage all, `⌃⌥C` commit, `⌃⌥P` push, `⌃⌥G` add+commit+push).

`{}` in a snippet parks the cursor there: the text is typed but not executed, so
`git commit -m "{}"` leaves you inside the quotes ready to type a message.

## Appearance

The window is a set of floating panels — a top bar, a frosted sidebar, and a
status pill, all lifted off a deeper window base — rather than edge-to-edge
chrome.

> The top bar is **not** an `NSToolbar`. AppKit centres toolbar items inside the
> titlebar band, placing them at `titlebarHeight / 2`, while the gap a person
> actually perceives runs from the window edge down to the terminal card
> (`titlebarHeight + margin`). Those two centres can only coincide when the top
> margin is zero, so no amount of padding centres a system toolbar in a floating
> layout. The window uses `.hiddenTitleBar` and the app draws its own bar, which
> also means `isMovableByWindowBackground` is required to keep the window
> draggable.
>
> The traffic lights are repositioned to sit inside that bar — centred on it and
> inset from its leading edge by the same margin the trailing buttons use. They
> are reparented out of the titlebar view, which is only ~28pt tall and would
> clip a button centred on a 36pt bar. AppKit re-lays them out on resize and on
> full-screen transitions, so `WindowConfigurator` re-applies the placement from
> notification observers rather than setting it once. Both the SwiftUI layout and
> that AppKit code read the same constants from `Layout`; letting either keep its
> own copy is how the buttons drift out of the bar. Everything
below is adjustable in Settings (`⌘,`) → Feel and Background.

**Backgrounds** (Settings → Background, or View → Background):

- **Solid** — the theme's colour.
- **Blur** — the desktop blurred through the window, via `NSVisualEffectView`
  behind-window blending. macOS blur materials are fixed recipes with no radius
  knob, so the strength control picks a material rather than a radius; the label
  says so instead of pretending otherwise.
- **Image** — any picture, with real gaussian blur (0–40) and opacity.

A **tint** slider lays theme colour over a blur or image so text stays readable
over an arbitrary wallpaper.

> **Known limitation:** the *terminal text area itself* stays opaque. SwiftTerm
> exposes `backgroundOpacity`, but with its default CoreGraphics renderer the
> view still composites solid — clearing the view's layer `isOpaque`, using
> within- and behind-window effect views, and a non-opaque window were all tried
> without success. The window background modes above work; per-terminal
> transparency does not, so no setting is offered for it.

**Bars are painted independently.** Settings → Feel → Bars gives the top bar,
sidebar, inspector and status pill each their own style (Solid / Frosted /
Liquid Glass on macOS 26+), blur strength, tint, and two switches:

- **Blur the desktop, not the window.** A `.withinWindow` effect view cannot
  sample a `.behindWindow` one beneath it, so with a blurred *background* the
  bars come out flat and dark — the sidebar looks like a black slab. Blurring
  behind the window instead gives them real depth. Settings warns about exactly
  that combination.
- **Keep blur when unfocused.** AppKit dims effect views the moment the window
  loses focus, which reads as the app greying out while you glance elsewhere.
  On by default. Measured: sidebar stays `(59,57,59)` focused and unfocused with
  it on, versus dropping to `(48,43,47)` with it off.

- **Shadow**, 0 for none. A heavy drop shadow is invisible over a dark
  background and reads as a black bar over a light one, because it lands in the
  gap between the panel and the window edge where there is nothing to soften it.
  Default is now 0.16 at radius 8 (it was 0.34 at radius 12).

Corner radii for rows, panels, and the status pill are independently adjustable,
as are density and animation speed.

> **Terminal opacity is linear, and a dark theme at high opacity is just dark.**
> At 75% a near-black background reads as near-black — that is the setting
> working, not a bug. Around 35% is where a blurred desktop actually shows
> through.

> Image backgrounds must be constrained by a `GeometryReader`. A `resizable()`
> SwiftUI `Image` propagates its intrinsic size — often thousands of points —
> to the enclosing stack, which blows out the window layout and pushes the
> entire UI off screen.

## Themes

Five built-ins (Lil Dark, Tokyo Night, Nord, Solarized Dark, Paper). Built-ins
are read-only and fork on edit. Themes are plain JSON with hex colours — export
to a file, or copy to the clipboard and paste it to someone else.

### Contrast

UI text tiers are derived from each theme's own foreground rather than SwiftUI's
`.primary`/`.secondary`, which track the system appearance and can land at
unreadable contrast on a custom palette. All shipped themes clear 4.5:1 for
secondary text and 3:1 for tertiary.

Two known exceptions, both deliberate: **Solarized Dark** is low-contrast by
design (5.6:1 body text), and **Nord**'s red sits at 3.05:1 against its
background. Both are the authentic published palettes and are left unmodified.
