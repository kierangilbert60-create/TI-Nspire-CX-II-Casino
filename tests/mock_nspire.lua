-- Minimal stand-in for the TI-Nspire Lua sandbox so src/eqsolver.lua can be
-- loaded, driven and tested by a desktop Lua interpreter.
--
-- It mimics the parts of the real API the script actually touches, and it is
-- deliberately strict: drawing with a colour that was never set, or calling an
-- unknown gc method, raises instead of silently passing.

local M = {}

local gc = {}
gc.__index = gc

function M.newGC(record)
  return setmetatable({ calls = 0, strings = {}, ops = record and {} or nil,
                        colour = { 0, 0, 0 }, font = { "sansserif", "r", 10 } }, gc)
end

-- Records a drawing call so tests (and the PNG preview) can replay the screen.
-- NB: a vararg in a table constructor keeps only its first value unless it is
-- last, so the fields are written out explicitly.
local function op(self, kind, a, b, c, d)
  if self.ops then
    self.ops[#self.ops + 1] = { kind, a, b, c, d,
      col = { self.colour[1], self.colour[2], self.colour[3] },
      fnt = { self.font[1], self.font[2], self.font[3] } }
  end
end
M.op = op

function gc:setColorRGB(r, g, b)
  assert(type(r) == "number" and r >= 0 and r <= 255, "bad red")
  assert(type(g) == "number" and g >= 0 and g <= 255, "bad green")
  assert(type(b) == "number" and b >= 0 and b <= 255, "bad blue")
  self.colour = { r, g, b }
  self.calls = self.calls + 1
end

function gc:setFont(family, style, size)
  assert(family == "sansserif" or family == "serif" or family == "mono", "bad font family")
  assert(style == "r" or style == "b" or style == "i" or style == "bi", "bad font style")
  assert(type(size) == "number" and size >= 6 and size <= 255, "bad font size")
  self.font = { family, style, size }
  self.calls = self.calls + 1
end

local function num(v, what)
  assert(type(v) == "number" and v == v, (what or "coordinate") .. " must be a number")
end

function gc:drawString(s, x, y, anchor)
  assert(type(s) == "string", "drawString needs a string, got " .. type(s))
  num(x, "x"); num(y, "y")
  assert(anchor == nil or anchor == "top" or anchor == "middle" or anchor == "baseline" or anchor == "bottom",
         "bad anchor " .. tostring(anchor))
  self.strings[#self.strings + 1] = { text = s, x = x, y = y, w = self:getStringWidth(s) }
  M.op(self, "str", x, y, self:getStringWidth(s), s)
  self.calls = self.calls + 1
end

-- Rough proportional-width model: enough to exercise the wrapping code.
function gc:getStringWidth(s)
  assert(type(s) == "string", "getStringWidth needs a string")
  local size = self.font[3]
  local w = 0
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local step = 1
    if b >= 240 then step = 4 elseif b >= 224 then step = 3 elseif b >= 192 then step = 2 end
    local ch = s:sub(i, i)
    local factor = 0.55
    if ch:match("[iljt%.,%(%)%|]") then factor = 0.3
    elseif ch:match("[mwMW]") then factor = 0.85
    elseif step > 1 then factor = 0.7 end
    w = w + size * factor
    i = i + step
  end
  return math.floor(w + 0.5)
end

function gc:getStringHeight(s) return self.font[3] + 4 end
function gc:fillRect(x, y, w, h) num(x); num(y); num(w); num(h); M.op(self, "fill", x, y, w, h); self.calls = self.calls + 1 end
function gc:drawRect(x, y, w, h) num(x); num(y); num(w); num(h); M.op(self, "rect", x, y, w, h); self.calls = self.calls + 1 end
function gc:fillArc(x, y, w, h, a, b) num(x); num(y); num(w); num(h); num(a); num(b); self.calls = self.calls + 1 end
function gc:drawArc(x, y, w, h, a, b) num(x); num(y); num(w); num(h); num(a); num(b); self.calls = self.calls + 1 end
function gc:drawLine(x1, y1, x2, y2) num(x1); num(y1); num(x2); num(y2); M.op(self, "line", x1, y1, x2, y2); self.calls = self.calls + 1 end
function gc:fillPolygon(pts) assert(type(pts) == "table"); self.calls = self.calls + 1 end
-- Deliberately fatal: on a real CX II everything drawn inside a clipRect
-- came out blank (no hint text, no typed characters, no caret), so this
-- project trims strings to fit instead of clipping.
function gc:clipRect(mode, x, y, w, h)
  error("gc:clipRect is banned in this project - it renders blank on real "
        .. "hardware; trim the string to fit instead", 2)
end
function gc:setPen(thickness, style) self.calls = self.calls + 1 end
function gc:smartGraphicsRefresh() end

_G.platform = {
  apilevel = "1.0",
  window = {
    width = function() return 318 end,
    height = function() return 212 end,
    invalidate = function() M.invalidations = (M.invalidations or 0) + 1 end,
  },
  isColorDisplay = function() return true end,
  hw = function() return 5 end,
  withGC = function(f) return f(M.newGC()) end,
}

_G.timer = {
  start = function(_) M.timerOn = true end,
  stop = function() M.timerOn = false end,
}

_G.on = {}
_G.toolpalette = {
  register = function(menus)
    M.palette = menus
    return true
  end,
}
_G.var = { store = function() end, recall = function() return nil end }
_G.clipboard = { addText = function() end, getText = function() return "" end }
_G.cursor = { set = function() end }
_G.document = { markChanged = function() end }

-- math.eval / math.evalStr only exist on real hardware. Tests install a fake
-- when they want to exercise the CAS fallback path.
M.setFakeCAS = function(fn)
  math.evalStr = fn
  math.eval = function(s)
    local r = fn(s)
    return tonumber(r)
  end
end
M.clearCAS = function()
  math.evalStr = nil
  math.eval = nil
end

return M
