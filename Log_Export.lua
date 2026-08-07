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

local function watch()
  local gen = math.floor(reaper.gmem_read(0))
  if gen ~= last_gen then
    last_gen = gen
    local len = math.floor(reaper.gmem_read(1))
    if len > 0 then
      local text = read_export_text(len)

      local dir = reaper.GetResourcePath() .. "/MidiLogExports"
      reaper.RecursiveCreateDirectory(dir, 0)
      local fname = dir .. "/midilog_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"

      local f = io.open(fname, "w")
      if f then
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
