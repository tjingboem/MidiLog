# MidiLog — manual

MidiLog is a JSFX MIDI-monitoring effect (`MidiLog.jsfx`, originally
DarkStar 2018 + casrya 2025/2026, extended further 6–7 Aug 2026). It
logs every MIDI message passing through an FX chain — Note On/Off, CC,
Pitch Wheel, Channel Pressure, SysEx — with sample-accurate timing,
scrollable history, and filter switches for Notes and MPE expression
data. General-purpose: not tied to any one project, usable on any FX
chain you want visibility into.

This doc exists because MidiLog isn't just one file. It's a small
two-part system, and the reason it has to be two parts (not one) is a
hard constraint of the JSFX sandbox, not a design preference — worth
writing down before that reasoning gets lost.

## The two parts, and why there are two

1. **`MidiLog.jsfx`** — the effect itself. Captures MIDI in `@block`,
   draws the scrollable log in `@gfx`, holds the "Export" button.
2. **`Log_Export.lua`** — a companion ReaScript. Its only job is
   turning a click of "Export" into an actual `.txt` file on disk.

They're two files instead of one because **JSFX cannot do either of
the things Export needs**:

- **JSFX cannot write an arbitrary file to disk.** `file_open()` is
  read-only. The only write-capable functions — `file_var`,
  `file_mem`, `file_string` — only work inside the `@serialize`
  section, writing into the plugin's own project-state blob, not a
  chosen path. There's no save-file dialog either. Confirmed against
  REAPER's own JSFX File I/O reference, not assumed.
- **JSFX cannot call REAPER's API directly**, e.g. `SetExtState()`.
  This looks like it should work (ReaScript can call it fine, and nothing
  in the JSFX docs rules it out explicitly) but it doesn't — confirmed
  the hard way, by an actual compile error (`'SetExtState' undefined`)
  when it was tried here. JSFX's callable surface is its own EEL2
  function set, not the general REAPER API.
- **JSFX cannot invoke a ReaScript action either** — so it can't even
  ask a script to run on its behalf at the moment Export is clicked.

So a second file, running in ReaScript's environment (which *can* do
all three of the above), is the only way out. `MidiLog.jsfx` prepares
the data and hands it off; `Log_Export.lua` receives the hand-off and
does the actual file write.

## The hand-off: `gmem[]`

The bridge between the two is JSFX's `gmem[]` — a plain numeric shared
memory array, readable and writable from *both* JSFX and ReaScript
(`reaper.gmem_attach()` / `gmem_read()` / `gmem_write()` on the Lua
side). It's the one channel that's actually documented to cross that
boundary.

`MidiLog.jsfx` declares a **named** segment —
`options:gmem=MidiLogExport` at the top of the file — rather than using
the default anonymous gmem space, so it doesn't collide with any other
plugin's use of gmem. `Log_Export.lua` attaches to that exact same
name.

gmem only holds numbers, not strings, so the export text is written out
byte-by-byte in `export_log()` (`MidiLog.jsfx`):

- `gmem[0]` — a **generation counter**, incremented on every Export
  click. This is what lets the Lua side tell "a fresh export just
  happened" apart from "nothing's changed since I last checked" — see
  below.
- `gmem[1]` — the text length, in characters.
- `gmem[2 .. length+1]` — the text itself, one character's byte value
  per slot (`str_getchar()` on the way out, `string.char()` on the way
  back in).

Export always dumps the **entire** captured history, ignoring the
Note/MPE filter switches — those are a viewing convenience for the
on-screen log, not a limit on what counts as "the record." If you've
filtered notes out of view and click Export, you still get everything
that was ever captured.

## Why a background watcher, not a one-shot script

The obvious design would be: click Export, run `Log_Export.lua` once,
done. But JSFX can't trigger a script run — there's no call from
`MidiLog.jsfx` back into `Log_Export.lua` at the moment you click
Export. The only thing JSFX *can* do is sit there having written into
`gmem[]`, with no way to announce it.

So the shape flips: `Log_Export.lua` runs continuously instead,
via `reaper.defer()`, polling `gmem[0]` (the generation counter) once
per REAPER cycle. The instant it sees that counter change, it reads the
length and text out of `gmem[1..]`, writes a new timestamped file, and
reschedules itself. Practically this means: **launch the script once,
leave it running, and every future Export click is picked up
automatically** — no need to re-run anything per export. The polling
cost is negligible (one integer read per cycle when idle).

It stays running until you stop it from the Actions list, or close
the REAPER session.

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

The watcher makes no noise on startup (no console message, no
message box) — it was originally set up to print a "watcher running"
line, but that forced REAPER's console window open on every single
launch for no real benefit, so it was removed. It stays silent until
an export actually happens.

## What happens when you click Export

1. `export_log()` walks `MidiLog.jsfx`'s entire `hist[]` buffer,
   building one tab-separated line per entry (Seq, TimePos, Bus, Chan,
   Type, Ident, Value — the same fields shown on screen, same note-name
   and CC-name decoding, just written to a string instead of drawn to
   the screen).
2. That text is written into `gmem[]` as described above, and the
   generation counter is bumped.
3. `Log_Export.lua`'s background loop notices the counter change on its
   next cycle, reads the text back out, and writes it to
   `<REAPER resource path>/MidiLogExports/midilog_<timestamp>.txt`.
4. A message box pops up with the exact path (clickable OK, not just a
   console line — deliberately chosen over the quieter console message
   used for the startup notice, since this one is the actual
   confirmation that something happened).

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
  Added the Export feature and everything described above.
