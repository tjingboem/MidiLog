# Reading a MidiLog export — symbol reference

Every symbol that can appear in an exported `.txt`, and what it means.
This is the lookup table; `CLAUDE.md` in the repo root explains *why*
each one is the way it is.

An export has two parts: the raw log (a tab-separated table) and, three
blank lines below a `--- Diagrams ---` header, the ASCII diagrams.

The export carries its own short legend directly under that header,
covering the glyphs that actually appear in *that* file — so for most
reading you never need this page. What follows is the complete set,
including the cases a given export happens not to contain.

## The raw log

One line per MIDI message, tab-separated, under a `Duration:` line
giving the length of the capture in seconds.

| Column | Meaning |
|-----------|--------------------------------------------------------|
| `Seq` | Message number, from 0, in arrival order |
| `TimePos` | Project time in seconds |
| `Elapsed` | Seconds since the **first message after Clear** — the same clock every diagram is drawn against |
| `Bus` | MIDI bus |
| `Chan` | MIDI channel, 1–16 |
| `Type` | `Note On`, `Note Off`, `CC`, `Pitch Wheel`, `Chan Press`, `Poly AT`, `Program`, `SysEx` |
| `Ident` | What the message is about: a note name (`A#1`), or a CC number and name (`74 Sound Brightness`). Blank for messages that have no identity of their own, such as Pitch Wheel and Channel Pressure |
| `Value` | Velocity, CC value, pressure, or bend |

A `Note Off` is logged as such, but note that many controllers send
note-off as `Note On` with `Value 0`; both appear, and the diagrams
treat them identically.

## Keyboard diagram (notes)

One row per semitone, highest pitch at the top, including semitones
that were never played — a real keyboard has no gaps, so the chromatic
spacing stays true and a wrong note is visible by position alone. All
channels share one diagram rather than getting one each.

| Symbol | Meaning |
|--------|-----------------------------------------------------------|
| `[` | A note's **onset** |
| `]` | A note's **release** |
| `1`–`9` | Bar fill for channels 1–9; the digit *is* the channel |
| `/N` | Bar fill for channels 10–16, as a two-character unit: `/0` = channel 10, `/3` = channel 13, `/6` = channel 16 |
| `-` | Background of a **black-key** row (C#, D#, F#, G#, A#) |
| (space)| Background of a white-key row |

So `[888]` is one note on channel 8, and `[8][8]` is two separate notes
back to back — the brackets are what tell those apart. `[/3/3]` is one
note on channel 13.

Channels 10–16 use `/N` rather than two digits so that a repeated
single digit can never be misread: `88` is unambiguously two columns of
channel 8, never channel 88.

### Narrow bars

Brackets are reserved out of the bar's own width, so a short note has
to give something up:

| Bar width | Renders as | Kept |
|-----------|------------|-------------------------------|
| 1 column | `8` | Channel only, no brackets |
| 2 columns | `[8` | Onset bracket; release dropped |
| 3+ columns| `[8]`, `[88]`, … | Both brackets, channel fill between |

For a channel 10–16 bar whose inner space is too narrow for one
complete `/N` unit, that space is left as background rather than
showing half a symbol.

A note still sounding when Export was pressed has no release, and its
bar runs to the right edge with no `]`.

## Value diagrams (CC, Pitch Wheel, Channel Pressure, Poly Aftertouch)

One diagram per **(type, identity, channel)** — CC74 on channel 2 and
CC74 on channel 3 are two separate diagrams, never merged, because MPE
spreads one gesture across many channels and merging would hide which
channel actually moved. Eight rows tall, drawn as an area chart
(everything below the current value is filled).

| Symbol | Meaning |
|---------|-----------------------------------------------------------|
| `:` | Row fully reached by the value |
| `.` | Row half reached — doubles the vertical resolution from 8 steps to 16 |
| (space) | Above the current value |
| `--123` | At the **top** row: the highest value in this diagram |
| `--123` | At the **bottom** row: the lowest value |
| label | Under the diagram, e.g. `CC 74 (Ch 2)` |

The vertical scale auto-fits each diagram's own range rather than
spanning a fixed 0–127, so a small movement is still visible as a
shape. That is why the hi/lo numbers are printed: without them there is
no way to know what the top and bottom of a given chart mean. A flat
line with the same number top and bottom is a value that never changed.

Values are sample-and-hold: the line holds its last value until the
next message, which is how MIDI actually behaves.

## The time ruler

The row of numbers under each diagram, marking seconds since the first
message, labelled every 10 columns and followed by the word `seconds`.

Every diagram in one export shares the same width and the same left
margin, so a column is the same instant in every diagram — you can read
straight down from a note in the keyboard diagram into the CC diagrams
below and see what the expression was doing at that moment.

## Panels

The grid width is chosen per export, targeting about 25 ms per column
and clamped to between 100 and 400 columns, so a short capture is drawn
finely and a long one coarsely.

A wide grid would produce lines too long for an editor window, and every
pitch row is the same length — so they would all wrap at the same point
and interleave, destroying the vertical alignment the diagram exists
for. Instead the timeline is cut into **panels** of at most 200 columns,
stacked down the page like systems on a musical score:

```
     -- 0.0 - 2.3 s   (panel 1 of 3) --
```

Each panel is a complete keyboard followed by the value lanes for that
same span of time, and the series continues from where the previous
panel stopped. Times on the ruler are absolute, so panel 2 picks up
reading where panel 1 left off rather than restarting at zero.

Two rules govern what appears:

- **Every pitch row is drawn in every panel**, including pitches silent
  in that slice, so the keyboard keeps its shape and panels can be
  compared by eye.
- **A value lane appears only in panels where that stream moved.** A
  channel doing nothing in panel 2 contributes no lane there.

Value lanes are scaled to the stream's range across the *whole* capture,
not per panel, so a given height means the same thing in every panel.
The cost is that a gesture which is small relative to the whole take
looks flat in its own panel.

## The HTML page

Every export also writes a `.html` file beside the `.txt`, holding the
same information as a drawing. Open it in a browser.

It exists because every legibility compromise above — bracket widths,
`/N` units, panels, collisions — comes from the fixed grid of a text
file. A drawing has none of those limits, so notes are rectangles at
their true start and end, and the timeline is one continuous scroll.

| Element | Meaning |
|-----------------|-------------------------------------------------|
| Bar colour | The note's channel — one of 16 |
| Dark left tick | The note's onset, the equivalent of `[` |
| Gap between bars| A note boundary, not necessarily a rest |
| Shaded rows | Black keys, as in the ASCII diagram |
| Line under roll | A value stream, sharing the same time axis |
| Footer | Streams that never moved, and their value |

The onset tick and the gap both exist for the same reason the brackets
do: consecutive notes on one pitch and channel are the same colour, and
without them five notes in a row read as one long note. The gap alone
would be ambiguous with a real rest; the tick states that a note begins
there, and it stays visible for a retrigger that overlaps its own
predecessor, where there is no gap to see.

**Hover any note** for its pitch, channel, velocity and duration in
milliseconds — velocity appears nowhere in the ASCII diagrams, which
have no room for it.

**The channel checkboxes** in the header hide or isolate channels, which
is the fastest way to check what one part of a multitimbral fold
actually received.

The page is written in addition to the text, never instead of it: the
`.txt` stays greppable, diffable and pasteable, which the page is not.
If building the page fails, the text export is unaffected and the
confirmation dialog simply won't mention it.
