-- Dumps each screen's drawing calls as JSON so tests/render_shot.py can turn
-- them into a PNG preview at the real handheld geometry.
local mock = require("mock_nspire")
local function esc(s)
  return (s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end))
end
local function dump(name, setup, w, h)
  app.screen, app.text, app.caret = "input", "", 0
  app.result, app.error, app.lines, app.layoutW, app.scroll = nil, nil, nil, -1, 0
  app.mode, app.eventCount, app.lastEvent = 1, 0, "none yet"
  setup()
  on.resize(w, h)
  local gc = mock.newGC(true)
  on.paint(gc)
  local out = { '{"name":"' .. name .. '","w":' .. w .. ',"h":' .. h .. ',"ops":[' }
  for i, o in ipairs(gc.ops) do
    local kind = o[1]
    local parts = string.format('{"k":"%s","a":%d,"b":%d,"c":%d,"d":%d,"col":[%d,%d,%d],"fs":%d,"fb":"%s"',
      kind, o[2] or 0, o[3] or 0, o[4] or 0,
      (kind == "str") and 0 or (o[5] or 0),
      o.col[1], o.col[2], o.col[3], o.fnt[3], o.fnt[2])
    if kind == "str" then parts = parts .. ',"t":"' .. esc(tostring(o[5])) .. '"' end
    out[#out + 1] = parts .. "}" .. (i < #gc.ops and "," or "")
  end
  out[#out + 1] = "]}"
  local f = io.open("/tmp/claude-0/-home-user-TI-Nspire-CX-II-Casino/60701558-354b-5432-aad2-03d3880ac64e/scratchpad/shot_" .. name .. ".json", "w")
  f:write(table.concat(out)); f:close()
end

dump("input", function() end, 325, 217)
dump("keypad", function() app.screen = "keys"; app.kpRow, app.kpCol = 2, 4
                          app.text = "2x+3=11"; app.caret = 7 end, 325, 217)
dump("result", function()
  app.text = "2x+3=11"; app.caret = 7
  on.enterKey()
end, 325, 217)
print("dumped")
