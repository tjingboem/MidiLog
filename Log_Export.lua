-- Log_Export.lua
-- Companion to MidiLog.jsfx's "Export" button. JSFX can't write an
-- arbitrary file to disk on its own (file_open() is read-only, and
-- file_var/file_mem/file_string only work inside @serialize against
-- the plugin's own state blob), and it has no way to invoke a
-- ReaScript action either -- there's no call from JSFX into REAPER's
-- own API at all. The actual bridge is gmem[]: MidiLog.jsfx declares
-- options:gmem=MidiLogExport and writes its exported text there
-- byte-by-byte (gmem[0] = generation counter, bumped on every export;
-- gmem[1] = length; gmem[2..length+1] = each character's byte value).
--
-- Since the JSFX side can't call back into this script either, this
-- runs as a background watcher instead of a one-shot: launch it once
-- (Actions list, or a toolbar button) and leave it running -- every
-- click of "Export" in the Log window is picked up automatically from
-- then on and written out as a new .txt file, no need to re-run this
-- script each time. It stays running until you stop it from the
-- Actions list (or close the REAPER project/session).

reaper.gmem_attach("MidiLogExport")

local last_gen = -1

local function read_export_text(len)
  local chars = {}
  for i = 1, len do
    chars[i] = string.char(math.floor(reaper.gmem_read(i + 1)) & 0xFF)
  end
  return table.concat(chars)
end

-- ======================================================================
-- ASCII diagrams, added 8 Aug 2026 ("an oscilloscope for MIDI data").
-- Everything below reads the plain tab-separated text MidiLog.jsfx
-- already writes (Seq/TimePos/Elapsed/Bus/Chan/Type/Ident/Value, plus a
-- "Duration: X.XXX seconds" line -- see MidiLog.jsfx's export_log()) and
-- appends character-grid plots to the same .txt file. Lives here, not in
-- the JSFX, because scanning a buffer for whatever data types happen to
-- be present and assembling variable-length strings is a poor fit for
-- EEL2 compared to Lua's tables and string library.
--
-- Grouping rule for CC/pitch-bend/pressure, agreed with tjingboem: split
-- by MIDI channel always, and by identity within a channel where one
-- exists (a CC number). This isn't just tidiness -- MPE deliberately
-- spreads one gesture across several channels at once (see MidiCloud's
-- own broadcast design), so merging channels together would smear
-- multiple independent streams into one misleading trace. Splitting
-- means more diagrams (tjingboem: "we may well end up with 20... but
-- this is an analyzing tool, so why not"), not fewer, wrong ones.
--
-- Notes are handled differently, revised 8 Aug 2026: all channels
-- *merged* into one keyboard/piano-roll diagram instead of one bar graph
-- per channel, specifically so the shape of what's actually in
-- MidiCloud's captured buffer is visible as one pattern, the way it
-- would look on a real keyboard -- fragmenting it into separate
-- per-channel diagrams was hiding exactly the cross-channel pattern
-- tjingboem needs to see to check whether notes are firing correctly.
-- Each channel still stays distinguishable within the merged view via a
-- digit fill character (see channel_digit_glyphs() below) instead of a
-- plain block, chosen over real ANSI color/bold specifically because
-- this file has to render correctly in any plain-text editor, on any
-- platform, with no escape-code dependency (see that function's own
-- comment for the three earlier attempts this replaced and why).
-- ======================================================================

local DIAGRAM_WIDTH = 100 -- columns; keeps a diagram readable regardless
                           -- of how long the actual recording was -- the
                           -- one thing tjingboem specifically asked to
                           -- keep bounded.

-- Every diagram's grid starts after this same left margin (matches the
-- keyboard diagram's own "%-4s " note-name label width), added 8 Aug
-- 2026 so every diagram's column 1 -- elapsed = 0.0 -- lines up
-- vertically across the whole file, letting every data stream's start
-- point be read at a glance instead of diagram by diagram.
local LABEL_MARGIN = string.rep(" ", 5)

-- Dropped to plain ASCII throughout, 8 Aug 2026 -- three rounds of
-- non-ASCII glyphs (circled digits, shape markers, then Mathematical
-- Bold digits, plus a UTF-8 BOM) all mojibake'd in whatever text editor
-- tjingboem actually opens these exports in ("ï»¿" for the BOM itself,
-- "Â·" for the middle dot, "ð" for the start of a bold-digit glyph --
-- all textbook "UTF-8 read as Latin-1" signatures). That editor doesn't
-- do encoding auto-detection at all, so no Unicode choice can be made
-- safe from here -- only bytes 0-127 are guaranteed to look the same
-- under every encoding there is. Channel identity in the keyboard
-- diagram is back to a plain digit (no more "bold").

-- Shades black-key rows in the keyboard diagram, the same way a real DAW
-- piano roll shades them, so the vertical axis reads like a keyboard at
-- a glance even before any notes are drawn on top of it.
local BLACK_KEY_BG = "."

-- Value diagrams became an 8-row area chart, 8 Aug 2026, replacing the
-- single-row density-coded sparkline above: normalizing against the
-- fixed theoretical MIDI range (0..127, or -8192..8191 for pitch bend)
-- made a real sweep -- checked against an actual capture that moved
-- between -81 and -194, real pitch-bend motion -- render completely flat,
-- since that's a tiny sliver of the full range. Auto-scaling each group
-- to its own actual min/max (see collect_value_groups below) instead
-- fixes that, matching how the keyboard diagram already scales itself to
-- the pitch range actually captured rather than the full 0-127 note
-- range. tjingboem's own framing: "the real numbers show the exact
-- numbers, the diagrams show evolution" -- so the auto-scaled range
-- itself still isn't shown in the label (see build_value_diagram), same
-- as before.
local AREA_ROWS = 8

-- Two-level fill, added 8 Aug 2026 (tjingboem's request): a plain
-- single-character fill only has AREA_ROWS (8) real steps of resolution,
-- so a fast, fine movement smaller than one row's worth of the
-- auto-scaled range rounds away to nothing -- invisible, same failure
-- mode a coarse quantizer always has. AREA_FILL_HALF marks a row that's
-- only half-reached (worth half of AREA_FILL_FULL), doubling the real
-- resolution to 16 steps without adding any more rows -- confirmed this
-- actually recovers a fine excursion that the single-level version
-- genuinely lost, via a prototype tjingboem reviewed before this was
-- built for real. tjingboem's own framing: "It is not intended for the
-- pleasure of the eye only" -- this is a real precision increase, not a
-- decoration.
local AREA_FILL_FULL = ":"
local AREA_FILL_HALF = "."

-- Plottable numeric-value message types. Note On/Off/On(Off) are handled
-- separately (bar graph, not a value trace); Prog Change and SysEx are
-- skipped -- neither is a plottable numeric stream over time. Used only
-- as a membership check now -- each group's own actual min/max (not a
-- fixed range) drives the area chart's vertical scale.
local VALUE_TYPES = {
  ["CC"] = true,
  ["Chan Press"] = true,
  ["Poly After"] = true,
  ["Pitch Wheel"] = true,
}

local NOTE_TYPES = {
  ["Note On"] = true,
  ["Note On (Off)"] = true, -- MidiLog.jsfx's own label for a Note On with velocity 0 (a de facto Note Off)
  ["Note Off"] = true,
}

-- Splits the exported text into rows and pulls out the Duration line.
-- Skips the column header and any SysEx row (different field layout --
-- a hex byte dump, not Seq/TimePos/.../Value -- so it naturally falls
-- short of the 8-field count checked below and gets dropped).
local function parse_export(text)
  local rows = {}
  local duration = nil
  for line in text:gmatch("[^\n]+") do
    local d = line:match("^Duration:%s*([%-%d%.]+)")
    if d then
      duration = tonumber(d)
    elseif line:sub(1, 4) ~= "Seq\t" then
      local fields = {}
      for f in (line .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = f
      end
      if #fields >= 8 then
        rows[#rows + 1] = {
          seq = tonumber(fields[1]),
          timepos = tonumber(fields[2]),
          elapsed = tonumber(fields[3]),
          bus = fields[4],
          chan = fields[5],
          mtype = fields[6],
          ident = fields[7],
          value = fields[8],
        }
      end
    end
  end
  return rows, duration
end

-- Value streams only now (notes are handled separately below) -- grouped
-- by type+identity+channel so e.g. CC74 on channel 9 and CC74 on channel
-- 10 never collapse into one misleading trace.
local function collect_value_groups(rows)
  local value_groups = {}
  local group_order = {}

  for _, r in ipairs(rows) do
    if not NOTE_TYPES[r.mtype] then
      if VALUE_TYPES[r.mtype] then
        local key = r.mtype .. "|" .. r.ident .. "|" .. r.chan
        if not value_groups[key] then
          -- Label trimmed 8 Aug 2026, tjingboem's request: CC's ident
          -- carries the CC name too ("74 Sound Brightness"), but only the
          -- number is needed to identify it -- the full name isn't
          -- dropped from the raw log rows above, just from this label.
          local label = r.mtype
          if r.mtype == "CC" then
            local cc_num = r.ident:match("^(%d+)")
            if cc_num then label = label .. " " .. cc_num end
          elseif r.ident ~= "" then
            label = label .. " " .. r.ident
          end
          label = label .. " (Ch " .. r.chan .. ")"
          -- lo/hi start at the extremes and narrow to this group's own
          -- actual min/max as points come in (see the auto-scaling note
          -- near AREA_ROWS above) -- not a fixed MIDI range.
          value_groups[key] = { label = label, lo = math.huge, hi = -math.huge, points = {} }
          group_order[#group_order + 1] = key
        end
        local v = tonumber(r.value)
        if v then
          local g = value_groups[key]
          table.insert(g.points, { elapsed = r.elapsed, value = v })
          if v < g.lo then g.lo = v end
          if v > g.hi then g.hi = v end
        end
      end
    end
  end

  return value_groups, group_order
end

-- Inverts MidiLog.jsfx's own note_name_text() convention exactly
-- (FIRST_C = -1, so MIDI note 0 = "C-1" -- confirmed by reading that
-- function directly, not assumed) back into a MIDI note number, so
-- rows can be laid out by real pitch instead of first-seen order.
local PITCH_CLASS = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

local function note_name_to_midi(name)
  local letter, sharp, octave_str = name:match("^([A-G])(#?)(%-?%d+)$")
  if not letter then return nil end
  local pc = PITCH_CLASS[letter]
  if sharp == "#" then pc = pc + 1 end
  return pc + (tonumber(octave_str) + 1) * 12
end

-- Forward direction of the same convention, for row labels.
local NOTE_LETTERS = {"C","C","D","D","E","F","F","G","G","A","A","B"}
local NOTE_SHARPS  = {false,true,false,true,false,false,true,false,true,false,true,false}

local function midi_to_note_name(midi)
  local pc = midi % 12
  local octave = math.floor(midi / 12) - 1
  local label = NOTE_LETTERS[pc + 1]
  if NOTE_SHARPS[pc + 1] then label = label .. "#" end
  return label .. octave
end

local function is_black_key(midi)
  return NOTE_SHARPS[(midi % 12) + 1]
end

-- Revised four times, 8 Aug 2026 -- see the ASCII-fallback note near
-- BLACK_KEY_BG above for why this ended up at plain digits: circled
-- digits (too small to read), shape markers (readable but needed a
-- legend), and Mathematical Bold digits (genuinely readable, but
-- mojibake'd in tjingboem's actual text editor) all didn't survive
-- contact with real use. The next version repeated a channel's raw
-- decimal digits across a bar (e.g. "1212..." for channel 12) -- but
-- tjingboem spotted a real ambiguity: two adjacent single-digit-channel
-- notes (channel 1 next to channel 3) render identically to one
-- two-digit-channel note (channel 13), no way to tell which from the
-- bar alone. Fixed with a reserved marker: channels 1-9 stay a plain
-- repeated digit; channels 10-16 repeat "/" + the ones digit (channel 13
-- -> "/3/3/3..."). "/" is never itself a valid channel digit, so it
-- can't collide with a same-digit single-channel neighbor -- and "."
-- was deliberately avoided for this marker (tjingboem's own catch)
-- since "." already means something else twice over in this same
-- diagram (BLACK_KEY_BG, and AREA_FILL_HALF in the value diagrams) --
-- a channel-13 note sitting on a black key would have its own marker
-- blend into the row's background. Known remaining edge case, accepted
-- as a tradeoff rather than solved: a very short bar for a 10-16
-- channel can still truncate down to just "/" or just the ones digit,
-- which does look like a single-channel note in that narrow case.
local function channel_digit_glyphs(chan_str)
  local n = tonumber(chan_str)
  if n and n >= 10 then
    return { "/", tostring(n - 10) }
  end
  return { chan_str }
end

-- Pairs every Note On in the whole export with the next Note Off/On(Off)
-- of the same pitch *on the same channel* -- a simple oldest-open-first
-- queue per (channel, pitch), adequate since real note pairing is
-- normally well-nested. A note still sounding at export time (no
-- matching off found) gets end_elapsed = nil, drawn out to the right
-- edge of the diagram by build_keyboard_diagram below. Notes whose name
-- doesn't parse (shouldn't happen given MidiLog.jsfx's own fixed naming,
-- but checked rather than assumed) are silently skipped.
local function pair_notes_all(rows)
  local open = {}
  local bars = {}
  for _, r in ipairs(rows) do
    if NOTE_TYPES[r.mtype] then
      local key = r.chan .. "|" .. r.ident
      if r.mtype == "Note On" then
        local midi = note_name_to_midi(r.ident)
        if midi then
          local bar = { chan = r.chan, midi = midi, start_elapsed = r.elapsed, end_elapsed = nil }
          bars[#bars + 1] = bar
          open[key] = open[key] or {}
          table.insert(open[key], bar)
        end
      else
        local stack = open[key]
        if stack and #stack > 0 then
          local bar = table.remove(stack, 1)
          bar.end_elapsed = r.elapsed
        end
      end
    end
  end
  return bars
end

local function elapsed_to_col(elapsed, duration)
  local c = math.floor((elapsed / duration) * (DIAGRAM_WIDTH - 1)) + 1
  if c < 1 then c = 1 elseif c > DIAGRAM_WIDTH then c = DIAGRAM_WIDTH end
  return c
end

-- A row of time labels (seconds since the first note, matching every
-- other number in this export) spaced every 10 columns, shared by every
-- diagram so they all read against the same ruler.
local function build_time_ruler(duration)
  local ruler = {}
  for c = 1, DIAGRAM_WIDTH do ruler[c] = " " end
  local c = 1
  while c <= DIAGRAM_WIDTH do
    local t = (c - 1) / (DIAGRAM_WIDTH - 1) * duration
    local label = string.format("%.1f", t)
    for i = 1, #label do
      if c + i - 1 <= DIAGRAM_WIDTH then
        ruler[c + i - 1] = label:sub(i, i)
      end
    end
    c = c + 10
  end
  return table.concat(ruler)
end

-- The keyboard/piano-roll diagram: one row per semitone from the highest
-- to the lowest pitch actually captured, *including* semitones with no
-- note at all -- a real keyboard has no gaps, and showing the true
-- chromatic spacing is what makes the buffer's actual pattern (or a
-- wrong note sitting where it shouldn't) visible at a glance, which was
-- the whole point of merging channels into one diagram instead of many.
-- Each note bar is filled with its own channel's bold digit(s), so
-- channel identity survives the merge without needing separate rows.
local function build_keyboard_diagram(bars, duration)
  if #bars == 0 then return nil end

  local min_midi, max_midi = math.huge, -math.huge
  for _, bar in ipairs(bars) do
    if bar.midi < min_midi then min_midi = bar.midi end
    if bar.midi > max_midi then max_midi = bar.midi end
  end
  if min_midi > max_midi then return nil end

  local row_cells = {}
  for midi = min_midi, max_midi do
    local bg = is_black_key(midi) and BLACK_KEY_BG or " "
    local cells = {}
    for c = 1, DIAGRAM_WIDTH do cells[c] = bg end
    row_cells[midi] = cells
  end

  for _, bar in ipairs(bars) do
    local start_c = elapsed_to_col(bar.start_elapsed, duration)
    local end_c = elapsed_to_col(bar.end_elapsed or duration, duration)
    if end_c < start_c then end_c = start_c end
    local glyphs = channel_digit_glyphs(bar.chan)
    local cells = row_cells[bar.midi]
    local width = end_c - start_c + 1

    if #glyphs == 1 then
      for c = start_c, end_c do cells[c] = glyphs[1] end
    elseif width < #glyphs then
      -- Too narrow to show even one complete "/N" unit -- show just the
      -- marker, honestly incomplete, rather than a bare digit that could
      -- be misread as a different, single-digit channel.
      cells[start_c] = glyphs[1]
    else
      -- Fill only complete "/N" units, left-aligned from the note's own
      -- onset -- never end a bar on a bare fragment of the pattern
      -- (tjingboem, after seeing it in real output: "truncated trailing
      -- / is weird"). Any leftover column at the tail stays background,
      -- a cleaner signal than a dangling half-symbol would be.
      local complete_units = math.floor(width / #glyphs)
      local gi = 0
      for i = 1, complete_units * #glyphs do
        gi = gi % #glyphs + 1
        cells[start_c + i - 1] = glyphs[gi]
      end
    end
  end

  -- No header line here (removed 8 Aug 2026, tjingboem's request) -- the
  -- first row starts immediately, so this diagram's own "0.0" ruler mark
  -- lands on the very first line after the "Diagrams" separator, which
  -- is also the shared left-margin every other diagram aligns against
  -- (see LABEL_MARGIN below).
  local lines = {}
  for midi = max_midi, min_midi, -1 do
    lines[#lines + 1] = string.format("%-4s ", midi_to_note_name(midi)) .. table.concat(row_cells[midi])
  end
  lines[#lines + 1] = LABEL_MARGIN .. build_time_ruler(duration)
  return table.concat(lines, "\n")
end

-- 8-row area chart, replacing the old single-row sparkline 8 Aug 2026
-- (see the note near AREA_ROWS above for why). Sample-and-hold: MIDI CC/
-- pitch-bend/pressure values are stateful (a receiver holds the last
-- value until a new one arrives), so each column's height reflects
-- whichever point was most recently in effect at that column's time, not
-- an interpolation between points. points[] is already time-ordered
-- (capture order), so a single forward-moving pointer does this in one
-- pass without rescanning per column. Filled from the bottom up to each
-- column's height, same shape convention as a typical area chart.
--
-- Resolution doubled to 16 real steps via AREA_FILL_HALF/FULL (see that
-- constant's own comment) -- heights[] is computed in half-row units
-- (0..AREA_ROWS*2) instead of whole rows, so a fine movement that would
-- round to the same whole row still shows up as a half-step.
local function build_value_diagram(group, duration)
  local pts = group.points
  if #pts == 0 then return nil end
  local range = group.hi - group.lo
  if range == 0 then range = 1 end

  local heights = {}
  local pi = 1
  local current = pts[1].value
  for c = 1, DIAGRAM_WIDTH do
    local t_c = (c - 1) / (DIAGRAM_WIDTH - 1) * duration
    while pts[pi] and pts[pi].elapsed <= t_c do
      current = pts[pi].value
      pi = pi + 1
    end
    local norm = (current - group.lo) / range
    if norm < 0 then norm = 0 elseif norm > 1 then norm = 1 end
    heights[c] = math.floor(norm * AREA_ROWS * 2 + 0.5)
  end

  -- Label moved below the diagram, 8 Aug 2026 (tjingboem's request) --
  -- was sitting above the chart, pushing its "0.0" ruler mark out of
  -- alignment with every other diagram's. LABEL_MARGIN keeps the actual
  -- data flush with the keyboard diagram's own left margin instead.
  -- Plain label, no "-- ... --" border or range suffix, 8 Aug 2026
  -- (tjingboem's request), and no auto-scaled range shown either, even
  -- though it's now real per-capture data rather than a fixed constant --
  -- tjingboem's own framing: "the real numbers show the exact numbers,
  -- the diagrams show evolution."
  local lines = {}
  for r = 1, AREA_ROWS do
    local row = {}
    local row_from_bottom = AREA_ROWS - r + 1
    local full_threshold = row_from_bottom * 2
    local half_threshold = full_threshold - 1
    for c = 1, DIAGRAM_WIDTH do
      row[c] = (heights[c] >= full_threshold) and AREA_FILL_FULL
        or (heights[c] >= half_threshold) and AREA_FILL_HALF
        or " "
    end
    lines[#lines + 1] = LABEL_MARGIN .. table.concat(row)
  end
  lines[#lines + 1] = LABEL_MARGIN .. build_time_ruler(duration)
  lines[#lines + 1] = group.label
  return table.concat(lines, "\n")
end

-- Top-level entry point: scans the export text tjingboem is about to get
-- written to disk anyway, and returns the diagram block to append after
-- it. Returns "" (nothing appended) if there's no Duration line (an
-- export from before this feature existed, or something malformed) or
-- no rows at all -- an empty capture has nothing to plot.
local function build_diagrams(text)
  local rows, duration = parse_export(text)
  if not duration or duration <= 0 or #rows == 0 then
    return ""
  end

  local value_groups, group_order = collect_value_groups(rows)
  local note_bars = pair_notes_all(rows)

  -- 3 blank lines of separation before the header, tjingboem's request --
  -- text (the raw log) already ends with its own trailing newline, so 3
  -- more newlines here is 3 full blank lines, not 4.
  local out = { string.rep("\n", 3) .. string.rep("=", 20) .. " Diagrams " .. string.rep("=", 20) }

  local keyboard_diagram = build_keyboard_diagram(note_bars, duration)
  if keyboard_diagram then out[#out + 1] = keyboard_diagram end

  for _, key in ipairs(group_order) do
    local diagram = build_value_diagram(value_groups[key], duration)
    if diagram then out[#out + 1] = diagram end
  end

  return table.concat(out, "\n\n") .. "\n"
end

local function watch()
  local gen = math.floor(reaper.gmem_read(0))
  if gen ~= last_gen then
    last_gen = gen
    local len = math.floor(reaper.gmem_read(1))
    if len > 0 then
      local text = read_export_text(len)
      text = text .. build_diagrams(text)

      local dir = reaper.GetResourcePath() .. "/MidiLogExports"
      reaper.RecursiveCreateDirectory(dir, 0)
      local fname = dir .. "/midilog_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"

      local f = io.open(fname, "w")
      if f then
        -- No UTF-8 BOM (tried, then dropped, 8 Aug 2026): tjingboem's
        -- text editor doesn't honor it either -- the BOM bytes themselves
        -- mojibake'd into "ï»¿" right at the top of a real export. Every
        -- diagram glyph is plain ASCII now (see the note near
        -- BLACK_KEY_BG above), so there's nothing left in this file that needs a
        -- BOM's help, and adding one back would just reintroduce visible
        -- garbage for no benefit.
        f:write(text)
        f:close()
        reaper.ShowMessageBox("Exported to:\n" .. fname, "MIDI Log Export", 0)
      else
        reaper.ShowMessageBox("Could not write file:\n" .. fname, "MIDI Log Export", 0)
      end
    end
  end
  reaper.defer(watch)
end

watch()
