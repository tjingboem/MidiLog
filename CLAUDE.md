# MidiLog — manual

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

Every diagram is fixed at 100 columns wide regardless of how long the
actual capture was, and every diagram shares the same left margin, so
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
3. **`github.com/tjingboem/Reaper_Scripts` at `JSFX/MidiLog/`** — the
   public push target, pushed on request rather than automatically.
   Full detail on this repo relationship (why it's a separate clone,
   why `~/Downloads/MidiLog` stays the real working copy) is in
   Claude's own memory, not repeated here.

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
