# MidiLog — working handover

MidiLog is a JSFX MIDI-monitoring and analysis effect (`MidiLog.jsfx`,
originally DarkStar 2018 + casrya 2025/2026, extended further 6–8 Aug
2026). It logs every MIDI message passing through an FX chain — Note
On/Off, CC, Pitch Wheel, Channel Pressure, Poly Aftertouch, SysEx —
with sample-accurate timing, scrollable history, filter switches for
Notes and MPE expression data, and an Export feature that writes the
full captured history to a text file as both a raw event log and a set
of ASCII diagrams ("an oscilloscope for MIDI data"). General-purpose:
not tied to any one project, usable on any FX chain you want visibility
into.

This doc exists because MidiLog isn't just one file, and because its
timing model and export format both carry non-obvious reasoning behind
them that's worth keeping written down.

**[screenshot placeholder — main window: header buttons, column
headers, a few logged rows, scrollbar]**

## The two parts, and why there are two

1. **`MidiLog.jsfx`** — the effect itself. Captures MIDI in `@block`,
   draws the scrollable log in `@gfx`, holds the header buttons
   including "Export".
2. **`Log_Export.lua`** — a companion ReaScript. Its job is turning a
   click of "Export" into an actual `.txt` file on disk, complete with
   the ASCII diagrams appended after the raw log.

They're two files instead of one because **JSFX cannot do any of the
things Export needs**:

- **JSFX cannot write an arbitrary file to disk.** `file_open()` is
  read-only. The only write-capable functions — `file_var`,
  `file_mem`, `file_string` — only work inside the `@serialize`
  section, writing into the plugin's own project-state blob, not a
  chosen path. There's no save-file dialog either. Confirmed against
  REAPER's own JSFX File I/O reference, not assumed.
- **JSFX cannot call REAPER's API directly**, e.g. `SetExtState()`.
  This looks like it should work (ReaScript can call it fine, and
  nothing in the JSFX docs rules it out explicitly) but it doesn't —
  confirmed the hard way, by an actual compile error
  (`'SetExtState' undefined`) when it was tried here. JSFX's callable
  surface is its own EEL2 function set, not the general REAPER API.
- **JSFX cannot invoke a ReaScript action either** — so it can't even
  ask a script to run on its behalf at the moment Export is clicked.
- **Scanning a variable-length buffer and building character-grid
  diagrams is also a poor fit for EEL2** compared to Lua's tables and
  string library, so the diagram logic lives entirely in
  `Log_Export.lua` too, not split back into the JSFX.

So a second file, running in ReaScript's environment (which *can* do
all of the above), is the only way out. `MidiLog.jsfx` prepares the
data and hands it off; `Log_Export.lua` receives the hand-off, does the
actual file write, and builds the diagrams.

## On-screen window

Header buttons, left to right:

- **Log / Log OFF** — toggles whether MIDI is captured (and passed
  through) at all. Brighter = active. The label itself switches text
  (not just color) so the state is readable at a glance. While off, no
  new rows are added to the history — existing rows stay visible and
  exportable.
- **Clear&Ready** — wipes the history and resets the elapsed-time
  origin (see Timing model below) in one click. Named to say what it
  actually does: not just "clear the screen," but "the measurement
  window is about to begin."
- **Note Filter** — hides Note On/Off rows from the on-screen view
  only. Export always ignores this and dumps everything captured — see
  Export below.
- **MPE Filter** — hides Pitch Wheel, Channel Pressure, and CC74 rows
  (the three MPE expression dimensions) from the on-screen view only,
  same exception for Export. Repeated MPE values that are exact
  duplicates of the previous value on their own channel are also
  hidden automatically whenever MPE data is visible at all — a
  receiver holding a value doesn't need announcing every block.
- **Export** — dumps the entire captured history (ignoring both
  filters above) to a `.txt` file. See "What happens when you click
  Export" below.

**[screenshot placeholder — close-up of the header button row, one
with Log OFF/filters engaged to show the brighter-means-active state]**

Below the buttons: a scrollable, auto-following log (Seq, TimePos,
Bus, Chan, Type, Ident, Value columns), a right-hand scrollbar you can
drag, and click-to-jump on the scrollbar track. Auto-follow ("stick to
the latest entry") is filter-aware: it counts only currently-visible
rows when deciding what's in view, so filtering out a dominant message
type (e.g. hiding Notes while watching MPE data) doesn't leave the view
starved down to zero or one visible row.

## Timing model

Two independent time values are captured per event, both shown in the
export (TimePos and Elapsed columns):

- **TimePos** — REAPER's own `play_position`. Only moves while the
  transport is actually rolling. Useless as a time axis for
  live-input-only testing (holding keys, no Play pressed) — it just
  sits frozen.
- **Elapsed** — real wall-clock time (`time_precise()`), independent
  of transport state, measured from the last **Clear&Ready** click
  (`clear_time_origin`). This is the axis every diagram and the
  Duration line are built on, since it's always meaningful regardless
  of whether you were pressing Play.

In the exported text, Elapsed is further **zero-based to the first
captured event**: there's usually a gap of a second or more between
clicking Clear&Ready and the first actual note, and subtracting that
gap out means "0.000" in the file always means "the first note," not
"whenever you happened to click Clear&Ready."

**Duration**, the summary line at the top of every export, is the span
from the first captured event to the **last** captured event — i.e.
`hist[]`'s own last entry, not "whatever time it happens to be when you
click Export." This matters because capture is gated by the Log
button: nothing is appended to `hist[]` while Log is off, so the last
entry already *is* the correct stop point whether Log is still on, was
switched off mid-session, or Export was clicked long after you actually
stopped playing. (An earlier version measured to "now" whenever Log was
still on, which overcounted Duration by however long you sat idle
before clicking Export — fixed 8 Aug 2026.)

## What happens when you click Export

1. `export_log()` (`MidiLog.jsfx`) walks the entire `hist[]` buffer,
   building one tab-separated line per entry — Seq, TimePos, Elapsed,
   Bus, Chan, Type, Ident, Value, plus the Duration summary line at the
   top — the same fields and decoding shown on screen, just written to
   a string instead of drawn to the screen. This always dumps the
   **full** history, ignoring the Note/MPE filters — those are a
   viewing convenience for the on-screen log, not a limit on what
   counts as "the record."
2. That text is written into `gmem[]` (see below), and a generation
   counter is bumped.
3. `Log_Export.lua`'s background loop notices the counter change on
   its next cycle, reads the text back out, appends the ASCII diagrams
   (see below), and writes the combined result to
   `<REAPER resource path>/MidiLogExports/midilog_<timestamp>.txt`.
4. A message box pops up with the exact path (clickable OK, not just a
   console line — this is the actual confirmation that something
   happened).

## The hand-off: `gmem[]`

The bridge between the two files is JSFX's `gmem[]` — a plain numeric
shared memory array, readable and writable from *both* JSFX and
ReaScript (`reaper.gmem_attach()` / `gmem_read()` / `gmem_write()` on
the Lua side). It's the one channel that's actually documented to
cross that boundary.

`MidiLog.jsfx` declares a **named** segment —
`options:gmem=MidiLogExport` at the top of the file — rather than using
the default anonymous gmem space, so it doesn't collide with any other
plugin's use of gmem. `Log_Export.lua` attaches to that exact same
name.

gmem only holds numbers, not strings, so the export text is written out
byte-by-byte in `export_log()`:

- `gmem[0]` — a **generation counter**, incremented on every Export
  click. Lets the Lua side tell "a fresh export just happened" apart
  from "nothing's changed since I last checked."
- `gmem[1]` — the text length, in characters.
- `gmem[2 .. length+1]` — the text itself, one character's byte value
  per slot (`str_getchar()` on the way out, `string.char()` on the way
  back in).

## Why a background watcher, not a one-shot script

The obvious design would be: click Export, run `Log_Export.lua` once,
done. But JSFX can't trigger a script run — there's no call from
`MidiLog.jsfx` back into `Log_Export.lua` at the moment you click
Export. The only thing JSFX *can* do is sit there having written into
`gmem[]`, with no way to announce it.

So the shape flips: `Log_Export.lua` runs continuously instead, via
`reaper.defer()`, polling `gmem[0]` (the generation counter) once per
REAPER cycle. The instant it sees that counter change, it reads the
length and text out of `gmem[1..]`, builds the diagrams, writes a new
timestamped file, and reschedules itself. Practically this means:
**launch the script once, leave it running, and every future Export
click is picked up automatically** — no need to re-run anything per
export. The polling cost is negligible (one integer read per cycle
when idle).

It stays running until you stop it from the Actions list, or close the
REAPER session.

**Self-reload — built, then declined, 29 Aug 2026.** A version of
`watch()` was written that checked its own file for on-disk changes
roughly once a second, `dofile()`-ing itself on a change so the watcher
never needed a manual stop/restart after an edit. It worked (generation
counter to stop the old chain, `pcall`-guarded against a mid-write
reload), and was briefly deployed to the live `Effects/` copy. Declined
before being committed: it's a script polling forever in the
background purely to save one manual step, the same shape of thing as
the `Effects/`-symlink idea already turned down elsewhere in this
family — tjingboem prefers the copy/restart to stay an explicit,
occasional action rather than something running continuously. Don't
re-propose a self-watching reload for this or any sibling script;
stopping and restarting `Log_Export.lua` by hand after an edit is the
intended, kept behavior.

## Auto-starting the watcher

`~/.config/REAPER/Scripts/__startup.lua` launches `Log_Export.lua`
automatically every time REAPER opens, alongside tjingboem's other
background scripts there (Adaptive grid, Gridbox, FX Modulator,
ReaSnap). It's wired in slightly differently from those: the other
entries use a `_RS...` command ID obtained by manually loading the
script once via Actions → Load ReaScript. `Log_Export.lua`'s entry
instead calls `reaper.AddRemoveReaScript(true, 0, path, true)`, which
registers the script and returns a runnable command ID in one step —
no manual load required first, at the cost of looking a little
different from the established pattern.

The watcher makes no noise on startup (no console message, no message
box) — it was originally set up to print a "watcher running" line, but
that forced REAPER's console window open on every single launch for no
real benefit, so it was removed. It stays silent until an export
actually happens.

## The ASCII diagrams

Appended after the raw tab-separated log, three blank lines down and
under a `--- Diagrams ---` header. Everything below is built purely
by reading the plain text `MidiLog.jsfx` already wrote (the same
Seq/TimePos/Elapsed/Bus/Chan/Type/Ident/Value rows and Duration line
described above) — there's no separate data path for the diagrams.
An extra blank line follows the keyboard/piano-roll diagram
specifically, setting it apart from the value diagrams that come
after it — every other pair of diagrams gets the usual single blank
line between them.

A short legend sits directly under the `--- Diagrams ---` header,
naming the glyphs used below it (added 29 Aug 2026, tjingboem's
request) — the export gets read on its own, often nowhere near this
repo, so it should be self-explanatory. It is built per export and
lists only what that file actually contains: the `/N` line appears
only if some note used channel 10–16, the value-diagram symbols only
if there are value diagrams. Its last line gives the grid width and
ms-per-column, which is what tells a reader how much to trust a dense
row.

Diagram width is chosen per export from the capture's duration
(29 Aug 2026), targeting ~25 ms per column and clamped to 100–400
columns; it was a flat 100. Every diagram in one export shares that
width and the same left margin, so
column 1 (elapsed = 0.0, the first note) lines up vertically across
the *entire* file — you can read straight down through a keyboard
diagram into a CC diagram below it and see the same instant in time in
both.

**[screenshot placeholder — a real export's Diagrams section: keyboard
diagram followed by one or two value diagrams, in a plain text
editor]**

### Keyboard / piano-roll diagram (Notes)

One merged diagram for all channels together, not one per channel —
deliberately, so the buffer's actual cross-channel pattern is visible
as one shape, the way it would look on a real keyboard. Splitting it
by channel was hiding exactly the pattern this diagram exists to show.

- One row per semitone from the highest to the lowest pitch actually
  captured, **including** semitones with no note at all — a real
  keyboard has no gaps, and the true chromatic spacing is what makes a
  wrong note sitting where it shouldn't be visible at a glance.
- Black-key rows get a shaded background (`-`), the same way a DAW
  piano roll shades them, so the vertical axis reads like a keyboard
  even before any notes are drawn on top. A repeated `.` read as busy
  and a plain `_` sat too low (baseline) to read as calm — `-` gives
  a continuous line at roughly the row's middle instead.
- Each Note On is paired with the next Note Off (or Note On with
  velocity 0) of the same pitch **on the same channel**, and drawn as
  a horizontal bar spanning that note's actual duration. A note still
  sounding at export time (no matching off found) is drawn out to the
  right edge of the diagram.
- Each bar is bracketed, not just filled: `[` marks the note's own
  onset, `]` its own release, with the channel's identity glyph(s)
  filling whatever's left between — e.g. a 4-column note on channel 8
  is `[88]`. This is what makes it possible to tell "one long note"
  apart from "several short ones back to back": two adjacent short
  notes on the same pitch and channel read as `[8][8]`, each keeping
  its own bracket pair, rather than merging into an indistinguishable
  `8888` — which used to happen for genuinely legato (zero-gap)
  retriggers even before this scheme, since there was no rest for any
  background gap to render. Channels 10–16 use a two-character `/N`
  unit in place of a single digit (channel 13 → `/3/3...`) so a
  repeated single digit can never be confused with two adjacent
  single-digit-channel notes sitting next to each other.
  - A bar only 1 column wide has no room for any bracket at all — just
    the bare identity glyph (e.g. `8`).
  - A bar 2 columns wide keeps the opening bracket and drops the
    closing one (`[8`) — onset is judged more useful to preserve than
    release when there's only room for one.
  - A bar 3+ columns wide gets both brackets, with the identity
    glyph(s) filling the columns between them (`[8]`, `[88]`, `[888]`,
    …). For a 10–16 channel, if the space between the brackets is too
    narrow for even one complete `/N` unit, that inner space is left
    as background rather than showing a fragment.
- Plain ASCII digits were the fourth attempt, after circled digits (too
  small to read), shape markers (readable but needed a legend), and
  Mathematical Bold Unicode digits (readable, but rendered as mojibake
  in the text editor these exports actually get read in). See the
  comment above `channel_digit_glyphs()` in `Log_Export.lua` for the
  full history if this ever needs revisiting.

#### When the row fills up with `[`

This was the shape of a dense row before 29 Aug 2026:

```
A#1  [[[[4][[7[4[[[[[[[[[5[[[[[[[[[8[1]------------[5[33[[[[[1[3[
```

Not corruption, and not a fault in the bracket scheme — the diagram
running out of horizontal resolution. The mechanism is worth keeping
written down, because it can still happen at the widest grid.

Bars are drawn one after another in onset order, each writing straight
into the shared row, so a later bar overwrites whatever an earlier one
put there. `[` is written at the onset column **unconditionally**, so
when the next note on a pitch starts before the previous bar has
finished, its opening bracket lands on the earlier note's channel digit.
Brackets systematically win; digits survive only in the gaps.

Measured on the export that row came from, at the old fixed width of
100 columns (68.7 ms each): 52 notes on that one pitch, bars 3–4 columns
wide but starting 1–2 columns apart, **110 writes into already-drawn
cells**, leaving 45 `[` against 19 digits.

Two changes fixed it. The grid became **adaptive** — about 25 ms per
column instead of whatever 100 columns happened to give — and the result
is cut into **panels** so the extra width doesn't wrap. The same row at
270 columns keeps 123 digits instead of 19, and reads as
`[11[4[777[44444]` rather than a run of brackets.

It can still degrade, at `DIAGRAM_MAX_WIDTH` on a long capture, so the
reading rules stay worth knowing:

- **Onsets are still trustworthy.** Every `[` is a real note starting.
- **Channel identity is not.** Visible digits are the ones that escaped
  being overwritten — go to the tab-separated rows for the truth.
- **Durations are gone**, since `]` is overwritten as readily as
  anything else.

The fix is still to capture less: hit Clear immediately before the
passage you care about. The `Grid` line in the legend gives the
ms-per-column, which is what says whether a row can be trusted.

#### Panels

A wide grid produces lines too long for an editor window, and every
pitch row is the same length — so they all wrap at the same point and
interleave, row B1's tail printing between row A#1's head and tail. That
destroys the vertical alignment the diagram exists for, which is worse
than the collisions were.

So the timeline is cut into panels of at most `PANEL_WIDTH` (200)
columns, stacked down the page like systems on a musical score. Panels
are made **equal width** rather than "full ones then a short
remainder", so each covers the same span of time and they can be
compared by eye — a 270-column grid becomes two panels of 135, not one
of 200 plus a stub.

Each panel is a complete keyboard followed by the value lanes for that
same span, and the series continues from where the previous panel
stopped; ruler times are absolute, never restarting at zero. Two rules:

- **Every pitch row appears in every panel**, including pitches silent
  in that slice — the keyboard has to keep its shape or panels can't be
  compared.
- **A value lane appears only where that stream moved.** With a real
  MPE capture — bend, CC74 and pressure on every channel — drawing all
  of them in every panel would run to hundreds of lines of flat line.

Keeping the value lanes *inside* their panel rather than gathered at the
end is the point: a note and the expression that shaped it end up in the
same column of the same block.

#### Streams that never move

A value stream that is constant for the whole capture has nothing to
plot: eight blank rows and two identical hi/lo labels, once per channel.
One real capture produced 24 of them in a row, roughly 260 lines of
nothing. Those are now reported as a single line each, collapsed across
channels that share a value:

```
     Constant through this capture, so not plotted:
       Pitch Wheel (Ch 1-8) = 0
       CC 74 (Ch 1-8) = 64
       Chan Press (Ch 1-8) = 0
```

Summarised rather than dropped — that the stream was present, and what
it sat at, is real information. It is the *chart* that carries none.

### Value diagrams (CC, Pitch Wheel, Channel Pressure, Poly Aftertouch)

One diagram **per (message type, identity, channel)** combination —
e.g. CC74 on channel 9 and CC74 on channel 10 are two separate
diagrams, never merged. This is deliberate, not an oversight: MPE
spreads one gesture across several channels at once (see MidiCloud's
own broadcast design), so merging channels together would smear
multiple independent streams into one misleading trace. A capture with
a lot of MPE activity may produce a large number of these diagrams —
intentional, since this is an analysis tool.

- An 8-row area chart, sample-and-held (a MIDI value stays in effect
  until the next point replaces it, so each column reflects whichever
  value was most recently in effect at that instant — not an
  interpolation between points).
- **Auto-scaled** to each group's own actual min/max, not the fixed
  theoretical MIDI range (0–127, or -8192..8191 for pitch bend). A
  real pitch-bend sweep that only moved through a small slice of the
  full range was rendering completely flat under fixed scaling: with
  auto-scaling, that same data shows its actual shape. The scaled
  range is printed at the right edge of the chart, each preceded by
  `--` (a leader/tick mark into the number, not just a trailing
  space) — the top row's line ends `--<hi>`, the bottom row's
  `--<lo>` — since with the vertical scale auto-fit per group, there'd
  otherwise be no way to tell what the top and bottom of the chart
  actually correspond to just by looking at it (unlike the fixed
  0–127 range this replaced, where the extremes were always
  implicit).
- **Two-level resolution**: each row can be a full fill (`:`) or a half
  fill (`.`), doubling the real resolution to 16 steps without adding
  more rows. A plain single-level fill was losing fast, fine
  movements smaller than one row's worth of range — this recovers
  them without making the diagram taller.
- A time ruler (seconds since the first note, every 10 columns) sits
  under every diagram, shared with the keyboard diagram's own ruler so
  everything reads against one consistent axis. The word "seconds" is
  appended right after it, landing in the exact same column every
  hi/lo value label starts in (both are `LABEL_MARGIN + DIAGRAM_WIDTH`
  columns in), so the ruler's unit is unambiguous without needing a
  separate label line of its own.

### The HTML page

Every export also writes a `.html` file beside the `.txt`, holding the
same capture as a drawing. Added 29 Aug 2026.

It exists because every legibility compromise above — bracket widths,
`/N` units, panels, collisions — is imposed by the fixed grid of a text
file. A drawing has none of those limits: notes become rectangles at
their true start and end, and the timeline is one continuous scroll.

Written as **`.html` with the SVG inlined**, not a bare `.svg`, on
purpose. On a normal Linux desktop `image/svg+xml` is associated with an
image viewer rather than a browser — it would render, but a rasterising
viewer doesn't run SVG's interactive layer, so tooltips and channel
toggles would be dead. `text/html` always opens a browser, and the page
stays one self-contained file with no assets beside it.

- **Colour carries channel** — the job the digit and `/N` glyphs were
  straining to do in ASCII.
- **A dark tick down each note's left edge** marks its onset, the direct
  equivalent of `[`, and each bar gives back 1.5 px so neighbours
  separate. Both are needed: consecutive notes on one pitch and channel
  are the same colour, so without them five notes read as one long one.
  A gap alone would be ambiguous with a real rest, and vanishes entirely
  when a note retriggers over its own predecessor — the tick doesn't.
- **The roll and every value lane live in one `<svg>`**, stacked, inside
  one scroll container. They share an x axis structurally and scroll
  together with no synchronisation code.
- **Hover a note** for pitch, channel, velocity and duration in ms.
  Velocity appears nowhere in the ASCII diagrams, which have no room.
- **Channel checkboxes** hide or isolate channels.

The page is additive, never a replacement. In `watch()` the `.txt` is
written and closed *first*, then the page is attempted inside a
`pcall` — if it ever throws, the text export is untouched and the
dialog simply doesn't mention a page. The text stays greppable,
diffable and pasteable, and is still the better view for counting: five
`[3` glyphs are countable, five adjacent bars of one colour are not.

Auto-opening the page is behind `HTML_AUTO_OPEN`, off by default. It
uses SWS's `CF_ShellExecute` where present, guarded so a REAPER without
SWS still exports normally; plain `os.execute("xdg-open …")` would do
the same job with no extension at all.

### Why plain ASCII, no Unicode, no BOM

Three separate rounds of non-ASCII output (circled digits, shape
markers, Mathematical Bold digits, and a UTF-8 BOM) all mojibake'd in
the actual text editor these files get opened in — `ï»¿` for the BOM,
`Â·` for a middle dot, `ð` for the start of a bold-digit glyph, all
textbook "UTF-8 read as Latin-1" signatures. That editor doesn't do
encoding auto-detection, so no Unicode choice is safe from this code's
side — only bytes 0–127 are guaranteed to look the same under every
encoding there is. Every glyph used anywhere in the diagrams (channel
digits, black-key shading, area-chart fill) is plain ASCII as a result.

## Where the files live

Three locations, kept in sync manually — same shape as every other
JSFX tool in this setup, no build script:

1. **`~/Downloads/MidiLog/`** — the working repo, own git history. Edit
   here.
2. **`~/.config/REAPER/Effects/tjingboem/MidiLog/`** — the live copy
   REAPER actually loads `MidiLog.jsfx` from. Needs a `cp` after every
   edit, **and** REAPER doesn't hot-reload an externally-edited JSFX
   file into an already-open FX instance — remove and re-insert the FX
   (or reload all JSFX plugins) to see changes take effect. This is the
   gotcha that cost the most back-and-forth confirming: silence after
   an edit almost always means "not reloaded," not "the fix didn't
   work." `Log_Export.lua` doesn't have this problem — ReaScript
   re-reads the file from disk each time it's launched, no reload
   trick needed, but the *running* watcher instance still has the old
   code loaded in memory until it's stopped and restarted.
3. **`github.com/tjingboem/MidiLog`** — the push target, and the
   `origin` of the working repo above. MidiLog graduated out of
   `Reaper_Scripts` into its own repo on 7 Aug 2026; anything still
   describing `Reaper_Scripts/JSFX/MidiLog/` as the push target is
   out of date.

Note that the copy under `Effects/` is itself a **separate git clone**
with no remote, and has drifted — it sits several commits behind and
carries uncommitted state of its own. Treat it as an install target, not
a working copy; `~/Downloads/MidiLog` is the real one.

Copying by hand is a **deliberate choice, not an oversight** (tjingboem,
29 Aug 2026). A symlink from `Effects/` back to the repo would end the
drift and the `cp` with it, and was offered and declined — the manual
step stays for now, so that what REAPER loads only changes when it is
explicitly put there. Worth re-reading this before proposing the
symlink again.

### What an export writes

Each Export produces two files in `<REAPER resource path>/MidiLogExports/`:

- `midilog_YYYYMMDD_HHMMSS.txt` — the raw log plus the ASCII diagrams
- `midilog_YYYYMMDD_HHMMSS.html` — the same capture as a drawing

The confirmation dialog names both. See `doc/Reading the export.md` for
a symbol-by-symbol reference to what is in them — that file is the
lookup table, this one is the reasoning.

## History

- **6 Aug 2026** — polished from an unversioned single file into a
  maintained tool (as `Log.jsfx`): git repo initialized, visual
  cleanup, two real bugs fixed (Channel Pressure always showing Value
  0; System Common/Real-Time messages mis-parsed as generic rows, now
  skipped). Built out specifically to test MidiCloud's MPE fixes.
- **7 Aug 2026** — renamed `Log.jsfx` → `MidiLog.jsfx` and the repo
  folder to match, since none of this is actually MidiCloud-specific.
  Added the Export feature: `gmem[]` hand-off to a new companion
  `Log_Export.lua`, running as a background watcher; fixed the export
  text truncating at ~16KB (JSFX's per-string soft cap) by writing
  each row into `gmem[]` as it's built instead of accumulating one
  giant string first.
- **8 Aug 2026** — turned MidiLog into an analysis tool. Added the
  Elapsed timing axis (`time_precise()`-based, independent of
  transport state) alongside TimePos, zero-based export timing, and
  the Duration summary line. Added the full ASCII-diagrams feature:
  the merged keyboard/piano-roll diagram for Notes, and auto-scaled,
  two-level-resolution area charts for CC/Pitch Wheel/Channel
  Pressure/Poly Aftertouch, split by channel and identity. Later the
  same day, fixed Duration to measure to the last captured event
  instead of "now," after it was overcounting idle time between the
  last note played and the Export click being noticed in real use —
  also removed the now-unneeded separate Log-OFF timestamp
  bookkeeping this replaced. Also switched the keyboard diagram's note
  bars from a plain repeated digit to a bracketed `[88]` convention
  (tjingboem's design): `[` marks a note's own onset, `]` its release,
  so a run of back-to-back short notes on the same pitch and channel
  stays visually distinct from one long note -- the plain-digit
  version had no way to show that boundary at all for genuinely
  legato (zero-gap) retriggers.
- **29 Aug 2026** — a run of diagram work, each step caused by the
  previous one. A dense 232-note capture exposed that the fixed
  100-column grid was collapsing busy rows into a run of `[`: bars
  overwrite in onset order and `[` is written unconditionally, so each
  note's opening bracket landed on the previous note's channel digit
  (measured: 110 writes into already-drawn cells on one pitch row, 45
  brackets left against 19 digits). Made the grid **adaptive** — ~25
  ms/column, clamped 100–400 — which recovered the digits (19 → 123 on
  that row) and immediately created the opposite problem: a 275-character
  line wraps, and since every pitch row is the same length they all wrap
  at the same point and interleave, destroying the vertical alignment
  the diagram exists for. Fixed by cutting the timeline into **panels**
  of equal width, stacked like systems on a score, each a complete
  keyboard plus the value lanes for that same span. Separately: 24
  never-moving value streams were producing ~260 lines of blank chart,
  so **constant streams are now summarised in one line each**, collapsed
  across channels, and a lane is drawn in a panel **only where it
  moved**. Added a **legend** under the `--- Diagrams ---` header,
  built per export so it names only the glyphs that file actually
  contains — the export is read on its own, often nowhere near this
  repo. Ruler label spacing now scales with the grid (every 10 columns
  gave 27 labels once the width moved).

  Then the out-of-the-box one: every remaining compromise above is
  imposed by the fixed grid of a text file, so an export now also writes
  an **HTML page with inline SVG** beside the `.txt` — notes as
  rectangles at their true start and end, colour for channel, a dark
  onset tick plus a 1.5 px gap so consecutive same-channel notes don't
  merge into one bar, value lanes in the same `<svg>` sharing the x
  axis, hover tooltips carrying velocity, and channel toggles. `.html`
  rather than `.svg` because Linux associates SVG with an image viewer,
  which renders but runs none of the interactive layer. Additive only:
  the `.txt` is written and closed first and the page is built inside a
  `pcall`, and the text remains the better view for counting sequential
  notes on one channel — countable glyphs beat a continuous drawing when
  the question is "how many".

  Also added `doc/Reading the export.md`, a symbol-by-symbol reference
  for people reading an export, as distinct from this file's reasoning.

- **29 Aug 2026, considered and declined** — a vertical "tracker" view
  of the notes, time running down the page and pitch across, which
  would have made line width depend on pitch range rather than capture
  length and so never wrapped or needed panels. Prototyped as a layout
  (75 characters wide for a 17-semitone span, onsets as the channel
  number, sustains as `|`) and dropped before any Lua was written: it
  reads note timing and channel precisely but loses melodic shape,
  which the horizontal roll gives for free, and the HTML page had by
  then solved the width problem outright. No code for it exists.

## Real user manual written, 9 September 2026 -- `doc/MidiLog.odt`

MidiLog is going out as donationware ("useful for other users, that
perhaps want to make a donation or not" -- tjingboem), so it needed an
actual manual, not just this handover. tjingboem had already created
`doc/MidiLog.odt` and pasted `doc/Reading the export.md` into it as a
starting point (as raw, unstyled Markdown text -- literal `#`/`|`
characters, not real headings or tables).

Rebuilt as a full seven-chapter manual, following the same guided-path
structure ReaSnap's and ReaMaskM's manuals already use -- Overview
first, reference material last:

1. **Overview** -- what MidiLog is, and the two-file split (why it
   exists: JSFX cannot write files or call REAPER's API directly) up
   front, since that's the first thing that would otherwise confuse a
   new user.
2. **Getting Started** -- loading the JSFX effect, separately launching
   `Log_Export.lua` (and that it has to *stay* running), and a
   concrete way to confirm the two-part setup actually worked.
3. **The On-Screen Window** -- the five header buttons and the log
   table, adapted from this file's own "On-screen window" section
   above.
4. **Timing: TimePos vs. Elapsed** -- adapted from "Timing model"
   above, trimmed to what a user needs (not the internal variable
   names).
5. **Exporting** -- what actually happens on click, where the files
   land.
6. **Reading an Export** -- `doc/Reading the export.md`'s content in
   full, converted from Markdown into real ODF headings and tables
   (five tables: the raw log's columns, keyboard-diagram symbols,
   narrow-bar behavior, value-diagram symbols, HTML page elements).
7. **Support MidiLog** -- a short donationware line. No donation
   link/platform specified -- tjingboem hasn't given me one, and I'm
   not fabricating one; add it by hand when there's a real link to put
   there.

**Styling matches the family look** established for ReaMaskM's and
ReaSnap's own manuals: navy (`#1f3864`) bold headings with a blue
bottom-border banner for chapters, and the same navy-header/light-blue-
first-column/gray-border table treatment already used in ReaSnap.docx
and (originally) MidiCloud.odt -- built as new automatic styles inside
`content.xml` (`MLH1`/`MLH2`/`MLTbl2`/`MLTbl3`/etc.) rather than reusing
another file's styles.xml, since this file's own default LibreOffice
styles had nothing usable (checked directly -- no navy heading style,
no table style existed in it before this).

Built by replacing the entire body content in one pass (title page +
all seven chapters), validated via `ET.fromstring` *before* writing to
disk (not after) -- the discipline established in ReaSnap's own
CLAUDE.md after a real mid-session corruption there. Packaged with
`mimetype` stored first and uncompressed, per the standing ODF
requirement. Backup at `doc/MidiLog.odt.bak-2026-09-09-preFullManual`.
Not yet committed to git.

**Also fixed in passing:** this file's own title said "MidiLog --
manual," which was accurate before today but now collides with the
real manual's existence -- retitled to "MidiLog -- working handover,"
matching every sibling tool's own `CLAUDE.md` naming convention.

**Not done, deliberately left for tjingboem:** every `[screenshot
placeholder]` marker in this file is still just that -- no screenshots
exist yet for the real manual either. Same next step as every other
tool in this family: capture them once the manual's text is confirmed
to read correctly, then place them (this file's placeholders mark
roughly where they'd go).

## Icon designed and drawn into the JSFX itself, 9 September 2026

tjingboem wanted an icon so `Log_Export.lua` could get a toolbar
button, and separately wanted the same image drawn inside
`MidiLog.jsfx`'s own window so the two files visibly "belong to each
other" -- otherwise it's just two unrelated-looking things a new user
has to discover need to run together.

**Design process, several iterations, each corrected by tjingboem
looking at the actual pixels:** a log + musical note combo read as
mud at true 30x30 size ("hard to see it is a log"); a log-only
top-down tree-ring cross-section read as "just a circle" once the note
was dropped, since concentric rings don't survive shrinking as
distinctly as a whole recognizable shape does; the final version is
the log viewed from the side (a rounded bark-coloured cylinder with
one end shown face-on, rings and all) -- which tjingboem correctly
called out as "Picasso-like" (an impossible combined perspective, side
view of the body with a face-on view of the cut end at the same time)
and then accepted anyway, since the anatomically correct foreshortened
ellipse would read as a smudge rather than rings at this size. Built
with PIL, drawn large (300px) and downsampled with Lanczos filtering
for clean anti-aliased edges at the real 30x30 size, matching the
flat/simple/single-silhouette style already established by this
family's other tool icons (`~/Downloads/icons/Mask.png` etc.).

**Two separate files, not one, since they serve different purposes:**

- **`MidiLog.png`** (30x30, single frame) -- drawn inside
  `MidiLog.jsfx`'s own `@gfx` window.
- **`MidiLog_toolbar.png`** (90x30, three 30x30 frames side by side) --
  for assigning as `Log_Export.lua`'s REAPER toolbar button icon.
  tjingboem: "what is needed is 3 of these... side by side, so when you
  click it changes to the second, and right-click shows the third."
  Confirmed the *format* (REAPER's real multi-state toolbar icon
  convention -- one image, 3x as wide as tall) but flagged real
  uncertainty about the *exact* trigger for the third frame -- tjingboem
  has built these before and knows from experience; I don't, and
  didn't want to assert an unverified detail as fact. Built as three
  tone variants of the same log artwork (normal warm brown, brighter
  warm/lit, and a cool blue-grey) so any REAPER-triggered state is at
  least visually distinct -- needs live testing in REAPER to confirm
  which frame actually shows when.

**Drawing the icon into `MidiLog.jsfx` itself:**

- `@init` (right after `load_CC_names()`, the file's last real
  top-level init statement before `@block`): `gfx_loadimg(midilog_icon_h,
  "MidiLog.png")`, handle 100 (arbitrary, checked no collision with any
  other variable name in the file first). `midilog_icon_ok` is set from
  the load's own return value so the draw call can skip cleanly if the
  file isn't found, rather than blitting a broken image.
- `@gfx`, inside the header-row block, right after the button-row's
  green highlight strip is drawn and `gfx_a`/`gfx_y` are restored, before
  the column-header line ("   Seq  TimePos ...") is printed. Anchored to
  **live** `gfx_w` (`gfx_w - icon_size - 6`), not the `@gfx 400 800`
  declaration's initial width, since this window gets resized in real
  use and a fixed offset would drift off-screen or overlap the buttons
  depending on how wide the user's made it. Scaled by `gfx_ext_retina`,
  matching the same HiDPI convention the rest of the header already uses
  for its font size. Saves and restores `gfx_x`/`gfx_y`/`gfx_r`/`gfx_g`/
  `gfx_b`/`gfx_a` around the blit so it doesn't disturb the header row's
  own cursor bookkeeping, which continues immediately afterward.

**Confirmed working in REAPER, 9 September 2026 -- after a real bug,
not a path problem.** The icon came up blank the first time
(`gfx_loadimg` returned 0). Debugged with an isolated throwaway JSFX
(`IconTest.jsfx`, same method already established in this family --
see `ReaTjingboem/CLAUDE.md`, "How to settle a REAPER/JSFX behaviour
question"), not by guessing further:

- Fetched the real SDK docs (`reaper.fm/sdk/js/gfx.php`, tjingboem's
  own link): `gfx_loadimg(image, filename)` returns the image index
  (e.g. 100, the handle passed in) on success, **-1** on failure --
  not the packed-w*h-value convention this file originally assumed,
  and the valid slot range is **0-127**, not 0-1023 as first written.
- Absolute path, relative path, REAPER's own `Data/` folder, a
  trivial plain-RGB test image with no alpha channel -- all still
  returned exactly `0`. Confirmed via `%f` formatting and explicit
  `== -1`/`== 0` checks that this was a genuine `0.0`, not a `%d`
  display bug hiding a real `-1`.
- Confirmed `@init` itself was genuinely running (a `42` sentinel
  printed correctly), ruling out "the code never executes" as an
  explanation.
- **The actual cause: `gfx_loadimg` was being called from `@init`,
  before any graphics context exists yet.** Moving the identical call
  into `@gfx` (guarded to run once, on the first frame only) made it
  return `100` immediately and the test image blit correctly. **This
  isn't written down anywhere in the SDK docs** -- found by measuring,
  not by reading a reference.

Fixed in the real file the same way: `midilog_icon_h` and
`midilog_icon_attempted` are set up in `@init`, but the actual
`gfx_loadimg` call and the `midilog_icon_ok` check now happen inside
`@gfx`, gated on `midilog_icon_attempted == 0` so it only runs once.
Relative filename (`"MidiLog.png"`) works fine now that the timing is
right -- path resolution was never actually the problem, it was
masked by every attempt failing at the loading stage before path
resolution could even matter. **tjingboem confirmed the icon now
shows** in the real running plugin, top-right of the header row, next
to Export.

Deployed (plain `cp`, no build step) to
`~/.config/REAPER/Effects/tjingboem/MidiLog/`, diff-confirmed identical
for both `MidiLog.jsfx` and `MidiLog.png`. Per this file's own "Where
the files live" section above: REAPER does not hot-reload an
externally-edited JSFX into an already-open FX instance -- remove and
re-insert the effect (or reload all JSFX plugins) to actually see the
icon, the same gotcha that's cost back-and-forth before. Not yet
committed to git.

## Two possible new capabilities -- #2 fully designed but DEFERRED TO v2, 10 September 2026

**"Load Capture" (capability 2 below) is explicitly deferred to MidiLog
v2, tjingboem's own call, same day it was designed:** "lets not add
this idea of midi reconstruction to MidiLog right now. That is
something for version 2." Also recorded in `ReaTjingboem/CLAUDE.md`
(item 14) as the cross-repo pointer. Not a "pick this up next" item --
leave it here as a complete design for whenever v2 actually starts.

tjingboem's own final framing, closing out a design conversation that
started from "can MidiLog be a VST3 plugin" (see `ReaTjingboem/
CLAUDE.md` item 13 and this repo's own donation-gate note for that,
unrelated to what follows): MidiLog now has two distinct jobs, one
already done and one not yet built.

**1. Analyzing MIDI data via text and HTML -- already built, no change.**
Export's existing `.txt`/`.html` output is enough for offline analysis
on its own; tjingboem explicitly confirmed this after considering
reloading a capture back into MidiLog's own live view ("I now think
that text and the html is enough to go through the data offline").

**2. "Load Capture" -- getting a previous export's data back into
MidiLog's live view, AND reconstructing it as a real MIDI item.** Two
outcomes from one action, not two separate features each re-parsing
the file:

- **Redisplay**: read a previously-exported `.txt`, parse it, push the
  events through the existing `gmem[]` bridge (the same one `Log_
  Export.lua` already uses for Export, just reversed) into `MidiLog.
  jsfx`'s own display buffer -- repopulates the on-screen table and
  diagrams exactly as if captured live. No new architecture, same
  proven pipeline.
- **Reconstruction**: a pure Lua-side operation (no JSFX/`gmem`
  involvement needed here at all) -- read the `.txt`, and call the
  same `MIDI_InsertNote`/`MIDI_InsertCC` API every other tool in this
  family already uses, building a real, editable REAPER MIDI item from
  the captured data. This is the piece that actually matters most:
  it turns a captured performance into something every other tool in
  this family can work on afterward -- including ReaShapeM's own new
  Interval Scaling/Pitch Compression/Duration Scale/Velocity Scale
  passes (see `reashapem-envelope-ideas` in memory) -- not just
  something MidiLog itself can re-view.

**Two real design decisions already made, tjingboem's own calls:**
- **Placement uses Elapsed, not TimePos.** "We are talking about
  reconstructing data back to a Midi Item, because the user wants that
  structure back, not the place in the composition." TimePos ties the
  data to a specific project timeline that may no longer be relevant;
  Elapsed (re-based to start at 0, or wherever the item lands) lets the
  performance be reconstructed anywhere, in any project.
- **Bus DOES need a separate track per bus on reconstruction --
  corrected 10 Sept 2026, reversing the original call below.**
  Original reasoning ("bus stays informational, not split into
  separate takes -- MIDI channel already carries 'sent to different
  instruments' in practice") was wrong on a real point, caught by
  tjingboem asking directly whether REAPER's bus system requires a
  separate track per bus. Verified via REAPER's own JSFX MIDI
  reference (`reaper.fm/sdk/js/midi.php`) and a KVR Audio forum
  answer: an item's raw MIDI data CAN be tagged with different bus
  numbers (valid range 0-15) within one take, but "any FX in REAPER
  receives MIDI from all channels on a specific MIDI Bus... that is
  not possible without using multiple tracks" -- i.e. a track's FX
  chain only ever listens to one bus at a time, so different buses
  only actually reach different instruments if each bus has its own
  track. tjingboem's own capture data already shows Bus as a real,
  used column (not always 1), so reconstructing multi-bus captures
  onto a single take would silently discard the very thing that made
  the buses meaningful in the first place -- different instruments
  genuinely wouldn't receive their intended data. **Corrected design:
  reconstruction groups captured events by Bus, creating one new
  track + MIDI item per distinct bus value found in the capture**, MIDI
  channel (1-16) preserved within each of those per the original
  design. Single-bus captures (the common case, per the earlier
  observation that bus 1 is typical) still produce exactly one track,
  so this only adds complexity when the source data actually needs it.

Not started. Pick this up by reading `Log_Export.lua`'s existing write
path first (the exact `.txt` column format is already the de facto
spec for the reader), then decide where "Load Capture" lives -- most
likely a new Lua companion action alongside `Log_Export.lua`, matching
this repo's existing two-file split (JSFX can't do file I/O or call
`MIDI_InsertNote`, so the reconstruction half has to be Lua regardless
of where redisplay ends up).

## Second v2 item: log System Common/Realtime messages -- SysEx truncation is CLOSED, not a v2 candidate -- 10 September 2026

tjingboem, comparing MidiLog against MIDI-OX as a reference analytic
tool: "I do think... that Sysex partially and MIDI Time Code, Song
Position Pointer, or realtime transport messages (Clock/Start/Stop)
are not reported. Midiox does show these." Confirmed true by reading
the actual code, not assumed. **Follow-up the same day split this into
two different calls, not one combined item:**

**SysEx truncation: CLOSED, working as intended, not a gap.**
tjingboem's own reasoning, and it's a real scope decision, not a
missed edge case: "MidiLog should do one thing, and that is logging.
But i realize that it would take to far when a whole sysex message is
displayed... Sysex messages can be seen in Reaper itself." Full SysEx
inspection is REAPER's own job (its MIDI Event List already shows
complete SysEx content) -- MidiLog showing the first 8 bytes plus the
true total length is enough to confirm "something happened here,
here's roughly what," without turning this into a second SysEx
inspector. **Reverses the "bigger, structural change" framing below**
-- not because the fix got easier, but because it's no longer wanted
at all.

**System Common/Realtime: still the real v2 item, now with a clear
reason why, not just "MIDI-OX shows it."** tjingboem: "yes, that is
something that MidiLog should show, so the user can make decisions
based on this information." Confirmed these messages genuinely reach
this JSFX in real use, not just in theory, so this isn't
dead-code-avoidance territory either. Explicitly deferred to v2 by
tjingboem's own call, same "feels like a version 2 thing to me"
treatment as the Load Capture idea above -- not started.

**What's actually missing, verified against the code:**

- **System Common/Realtime (status bytes 0xF1-0xFF) are deliberately
  skipped**, not an oversight -- there's already a real comment
  explaining why (they share status nibble 0xF, so the existing
  channel-message parser's assumptions about byte counts don't apply),
  dated 6 Aug 2026, crediting "casrya." Still forwarded untouched via
  `midisend_buf`, just never written into the log. The comment's own
  wording ("not logged **for now**") already reads as deferred, not
  permanent.

**Confirmed these messages actually arrive in real use, via a real
forum account of a near-identical logger JSFX** (`forum.cockos.com/
archive/index.php/t-189126.html`, "MIDI Logger - pimped") -- a user
reported Active Sensing messages genuinely showing up from a real
Yamaha keyboard when a similar logger JSFX was used as a track insert
FX. tjingboem: "it may have been me that made that comment." Possibly
the same person, on the other side of this exact question years later.

**Real design split needed if this gets built, not a single change:**
Active Sensing (continuous keep-alive, ~300ms) and MIDI Clock (24
pulses per quarter note during playback -- far higher volume than
Active Sensing) would flood the log if logged per-event the normal
way -- there's no value to deduplicate against, it's the identical
message repeated constantly. tjingboem's own framing: "shouting all
the time 'I am here' is interesting for the DAW but clutters the
screen." These two need either exclusion or a collapsed presence
indicator ("Clock running" / "Active Sensing: yes"), not a row per
message. The rest of the currently-skipped set -- Start, Stop,
Continue, Song Position Pointer, Song Select, Tune Request, MTC
Quarter Frame -- are one-off/occasional events, not continuous
streams, and would log fine as normal individual rows like everything
else already does.

Not started. Pick this up by reading the existing `midi_buf[0] >=
$xF1` skip branch first (`MidiLog.jsfx`, in the main capture loop) --
that's exactly where the new per-status-byte handling would replace
the current no-op skip, split into "log as one row" (System Common)
vs. "collapse to a presence indicator, don't log per-event" (Active
Sensing, Clock). SysEx's own 8-byte cap is out of scope for this pass
entirely now -- see the CLOSED note above, don't touch it as part of
this work.

**Real testing-access constraint, same day tjingboem raised it:** "i
have no direct access to System Common/Realtime." Most of this set is
still testable without needing hardware, though, since REAPER can
generate it itself: MIDI Clock, Start/Stop/Continue, and Song Position
Pointer can all be sent by REAPER's own transport (Preferences > MIDI
Devices, the sync-output options), routed to a virtual/loopback MIDI
port and back into a track hosting MidiLog -- a genuine, self-contained
test signal, no external device required. MTC the same way. **Active
Sensing is the one real exception** -- it's a hardware keep-alive a
physical controller sends on its own initiative, not something
REAPER's transport generates, so it needs either a real device
confirmed to send it (a prior forum account, possibly tjingboem's own,
mentions a Yamaha keyboard doing this -- see above), or a synthetic
stand-in test. Whether any of tjingboem's own current gear sends
Active Sensing is unconfirmed as of this writing -- worth checking
before this feature is built, not discovering as a surprise blocker
during testing.
