-- ============================================================================
-- ALGEBRA ASSISTANT ("mini-AI") for TI-NSPIRE CX II CAS
-- A tool-driven helper for College Algebra and the SAT Math section: equation
-- solving, a guided quadratic breakdown, a 2-equation system solver,
-- simplify/factor/expand, a function evaluator, percent & rate-distance-time
-- word-problem calculators, and a full formula reference sheet.
--
-- The Solve / Simplify / System / Evaluate tools call the calculator's own
-- CAS through math.eval(), so they need a CAS-enabled handheld (TI-Nspire
-- CX II CAS). The Quadratic Helper, Percent Toolkit, Rate/Distance/Time
-- solver, and Formula Sheet are plain arithmetic and work on any Nspire.
--
-- 100% keyboard driven, same control philosophy as the Casino app in this
-- repo. See README.md for install instructions and full key reference.
-- ============================================================================

platform.apilevel = '2.5'

-- ----------------------------------------------------------------------------
-- Global state
-- ----------------------------------------------------------------------------

local W, H = 318, 212
local screen = "lobby"
local screens = {} -- filled in below

-- ----------------------------------------------------------------------------
-- Palette + small drawing helpers
-- ----------------------------------------------------------------------------

local COLOR = {
  bg      = { 14, 18, 28 },
  bgPanel = { 22, 28, 42 },
  bar     = { 10, 13, 20 },
  accent  = { 70, 200, 235 },
  accent2 = { 140, 110, 230 },
  white   = { 235, 240, 245 },
  dim     = { 150, 160, 175 },
  gray    = { 90, 100, 115 },
  fieldBg = { 30, 38, 55 },
  ok      = { 100, 220, 140 },
  warn    = { 230, 120, 90 },
  gold    = { 235, 195, 90 },
}

local function setColor(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

local function centerText(gc, text, cx, y)
  local w = gc:getStringWidth(text)
  gc:drawString(text, cx - w / 2, y, "top")
end

local function fitTail(gc, text, maxW)
  if gc:getStringWidth(text) <= maxW then return text end
  local i = 1
  while i < #text and gc:getStringWidth(text:sub(i)) > maxW do
    i = i + 1
  end
  return text:sub(i)
end

-- Shared chrome: dark panel background + title bar + footer legend.
-- Returns the y-coordinate where screen-specific content should start.
local function drawChrome(gc, title, footer)
  setColor(gc, COLOR.bg)
  gc:fillRect(0, 0, W, H)

  setColor(gc, COLOR.bar)
  gc:fillRect(0, 0, W, 20)
  setColor(gc, COLOR.accent)
  gc:setFont("sansserif", "b", 10)
  gc:drawString(title, 4, 4, "top")

  if footer then
    setColor(gc, COLOR.bar)
    gc:fillRect(0, H - 14, W, 14)
    setColor(gc, COLOR.dim)
    gc:setFont("sansserif", "r", 7)
    gc:drawString(footer, 3, H - 12, "top")
  end

  return 24
end

local function switchScreen(name)
  screen = name
  if screens[name].enter then screens[name].enter() end
  platform.window:invalidate()
end

-- ----------------------------------------------------------------------------
-- CAS bridge
-- ----------------------------------------------------------------------------

-- Calls the calculator's CAS. Returns (resultString, nil) on success or
-- (nil, errorMessage) on failure -- CAS errors and math.eval being
-- unavailable (non-CAS handheld) are both caught here so no tool ever hard
-- crashes on bad input.
local function casEval(expr)
  if not math.eval then
    return nil, "CAS not available on this handheld."
  end
  local ok, result = pcall(math.eval, expr)
  if ok and result ~= nil then
    return tostring(result), nil
  end
  return nil, "Couldn't evaluate -- check the syntax."
end

local FUNC_WORDS = { "sqrt", "asin", "acos", "atan", "sin", "cos", "tan",
                      "log", "ln", "abs", "exp", "min", "max" }

local function guessVariables(s, maxN)
  local stripped = s:lower()
  for _, w in ipairs(FUNC_WORDS) do
    stripped = stripped:gsub(w, "")
  end
  local seen, order = {}, {}
  for ch in stripped:gmatch("%a") do
    if not seen[ch] then
      seen[ch] = true
      order[#order + 1] = ch
    end
  end
  if #order == 0 then return { "x" } end
  if maxN and #order > maxN then
    local trimmed = {}
    for i = 1, maxN do trimmed[i] = order[i] end
    return trimmed
  end
  return order
end

-- ----------------------------------------------------------------------------
-- Text field widget (single line, used by every tool screen)
-- ----------------------------------------------------------------------------

local EXPR_CLASS = "[%w%.,%(%)%^%+%-%*/=%s<>|]"
local NUM_CLASS = "[%d%.%-]"

local function newField(maxLen, numeric)
  return { text = "", maxLen = maxLen or 44, numeric = numeric }
end

local function fieldChar(f, ch)
  local class = f.numeric and NUM_CLASS or EXPR_CLASS
  if #f.text < f.maxLen and ch:match(class) then
    f.text = f.text .. ch
  end
end

local function fieldBackspace(f)
  f.text = f.text:sub(1, -2)
end

local function drawField(gc, f, x, y, w, active, label)
  if label then
    setColor(gc, COLOR.dim)
    gc:setFont("sansserif", "r", 7)
    gc:drawString(label, x, y - 9, "top")
  end
  setColor(gc, COLOR.fieldBg)
  gc:fillRect(x, y, w, 16)
  setColor(gc, active and COLOR.accent or COLOR.gray)
  gc:drawRect(x, y, w, 16)
  setColor(gc, COLOR.white)
  gc:setFont("sansserif", "r", 9)
  local disp = f.text .. (active and "_" or "")
  disp = fitTail(gc, disp, w - 6)
  gc:drawString(disp, x + 3, y + 3, "top")
end

local function drawResultBox(gc, x, y, w, h, lines)
  setColor(gc, COLOR.bgPanel)
  gc:fillRect(x, y, w, h)
  setColor(gc, COLOR.accent2)
  gc:drawRect(x, y, w, h)
  gc:setFont("sansserif", "r", 8)
  local ly = y + 4
  for _, line in ipairs(lines) do
    setColor(gc, line.color or COLOR.white)
    gc:drawString(fitTail(gc, line.text, w - 8), x + 4, ly, "top")
    ly = ly + 12
  end
end

-- ============================================================================
-- LOBBY
-- ============================================================================

local lobby = { sel = 1 }
local lobbyItems = {
  { name = "Equation Solver",       screen = "solve" },
  { name = "Quadratic Helper",      screen = "quad" },
  { name = "System of 2 Equations", screen = "system" },
  { name = "Simplify/Factor/Expand",screen = "simplify" },
  { name = "Evaluate f(x)",         screen = "evaluate" },
  { name = "Percent Toolkit",       screen = "percent" },
  { name = "Rate * Distance * Time",screen = "rdt" },
  { name = "SAT Formula Sheet",     screen = "formulas" },
  { name = "How To Use",            screen = "help" },
}

function lobby.enter()
  lobby.sel = 1
end

function lobby.arrowKey(key)
  if key == "up" then
    lobby.sel = lobby.sel - 1
    if lobby.sel < 1 then lobby.sel = #lobbyItems end
  elseif key == "down" then
    lobby.sel = lobby.sel + 1
    if lobby.sel > #lobbyItems then lobby.sel = 1 end
  end
end

function lobby.enterKey()
  switchScreen(lobbyItems[lobby.sel].screen)
end

function lobby.charIn(ch)
  local idx = tonumber(ch)
  if idx and idx >= 1 and idx <= #lobbyItems then
    lobby.sel = idx
    switchScreen(lobbyItems[idx].screen)
  end
end

function lobby.paint(gc)
  local y = drawChrome(gc, "Algebra Assistant", "Up/Down move  1-9 jump  Enter open")
  setColor(gc, COLOR.dim)
  gc:setFont("sansserif", "r", 8)
  gc:drawString("College Algebra + SAT Math helper", 6, y, "top")
  y = y + 16
  gc:setFont("sansserif", "r", 10)
  for i, item in ipairs(lobbyItems) do
    local rowY = y + (i - 1) * 16
    if i == lobby.sel then
      setColor(gc, COLOR.accent)
      gc:fillRect(4, rowY - 1, W - 8, 15)
      setColor(gc, COLOR.bg)
    else
      setColor(gc, COLOR.white)
    end
    gc:drawString(i .. ". " .. item.name, 8, rowY, "top")
  end
end

screens.lobby = lobby

-- ============================================================================
-- EQUATION SOLVER
-- ============================================================================

local solve = { field = newField(44), result = nil, err = nil }

function solve.enter()
  solve.field = newField(44)
  solve.result = nil
  solve.err = nil
end

function solve.charIn(ch)
  fieldChar(solve.field, ch)
end

function solve.backspaceKey()
  fieldBackspace(solve.field)
end

function solve.enterKey()
  local expr = solve.field.text
  if expr == "" then return end
  if not expr:find("=") then expr = expr .. "=0" end
  local vars = guessVariables(expr, 1)
  local var = vars[1] or "x"
  local result, err = casEval("solve(" .. expr .. "," .. var .. ")")
  solve.result, solve.err = result, err
  if result then solve.lastVar = var end
end

function solve.escapeKey()
  if solve.field.text ~= "" or solve.result then
    solve.field = newField(44)
    solve.result, solve.err = nil, nil
  else
    switchScreen("lobby")
  end
end

function solve.paint(gc)
  local y = drawChrome(gc, "Equation Solver", "type eqn (=0 optional)  Enter=solve  Esc=clear/back")
  drawField(gc, solve.field, 6, y + 6, W - 12, true, "Equation (e.g. x^2-5x+6=0, or 2x+3=11)")
  local by = y + 34
  if solve.result then
    drawResultBox(gc, 6, by, W - 12, 40, {
      { text = "Solving for " .. (solve.lastVar or "x") .. ":", color = COLOR.dim },
      { text = solve.result, color = COLOR.ok },
    })
  elseif solve.err then
    drawResultBox(gc, 6, by, W - 12, 28, { { text = solve.err, color = COLOR.warn } })
  end
end

screens.solve = solve

-- ============================================================================
-- QUADRATIC HELPER
-- ============================================================================

local quad = { fields = {}, active = 1, lines = nil }

function quad.enter()
  quad.fields = { newField(10, true), newField(10, true), newField(10, true) }
  quad.active = 1
  quad.lines = nil
end

function quad.charIn(ch)
  fieldChar(quad.fields[quad.active], ch)
  quad.lines = nil
end

function quad.backspaceKey()
  fieldBackspace(quad.fields[quad.active])
  quad.lines = nil
end

function quad.arrowKey(key)
  if key == "left" then
    quad.active = quad.active - 1
    if quad.active < 1 then quad.active = 3 end
  elseif key == "right" then
    quad.active = quad.active + 1
    if quad.active > 3 then quad.active = 1 end
  end
end

function quad.enterKey()
  local a = tonumber(quad.fields[1].text)
  local b = tonumber(quad.fields[2].text) or 0
  local c = tonumber(quad.fields[3].text) or 0
  if not a or a == 0 then
    quad.lines = { { text = "Enter a nonzero 'a' coefficient.", color = COLOR.warn } }
    return
  end
  local D = b * b - 4 * a * c
  local lines = {}
  lines[#lines + 1] = { text = string.format("Discriminant D = b^2-4ac = %.4g", D), color = COLOR.dim }
  if D > 0 then
    local r1 = (-b + math.sqrt(D)) / (2 * a)
    local r2 = (-b - math.sqrt(D)) / (2 * a)
    lines[#lines + 1] = { text = "D>0: two real roots", color = COLOR.ok }
    lines[#lines + 1] = { text = string.format("x = %.5g  or  x = %.5g", r1, r2), color = COLOR.ok }
  elseif D == 0 then
    local r = -b / (2 * a)
    lines[#lines + 1] = { text = "D=0: one repeated root", color = COLOR.ok }
    lines[#lines + 1] = { text = string.format("x = %.5g", r), color = COLOR.ok }
  else
    lines[#lines + 1] = { text = "D<0: no real roots (complex pair)", color = COLOR.warn }
  end
  local h = -b / (2 * a)
  local k = a * h * h + b * h + c
  lines[#lines + 1] = { text = string.format("Vertex: (%.4g, %.4g)   Axis: x=%.4g", h, k, h), color = COLOR.dim }

  local exact = casEval("solve(" .. a .. "x^2+" .. b .. "x+" .. c .. "=0,x)")
  if exact then
    lines[#lines + 1] = { text = "CAS exact: " .. exact, color = COLOR.accent }
  end
  quad.lines = lines
end

function quad.escapeKey()
  if quad.lines then
    quad.enter()
  else
    switchScreen("lobby")
  end
end

function quad.paint(gc)
  local y = drawChrome(gc, "Quadratic Helper", "Left/Right field  type a,b,c  Enter=solve  Esc=clear/back")
  setColor(gc, COLOR.dim)
  gc:setFont("sansserif", "r", 8)
  gc:drawString("ax^2 + bx + c = 0", 6, y, "top")
  y = y + 14
  local labels = { "a", "b", "c" }
  local fw = 90
  for i = 1, 3 do
    drawField(gc, quad.fields[i], 6 + (i - 1) * (fw + 8), y + 10, fw, quad.active == i, labels[i])
  end
  y = y + 34
  if quad.lines then
    drawResultBox(gc, 6, y, W - 12, H - y - 18, quad.lines)
  end
end

screens.quad = quad

-- ============================================================================
-- SYSTEM OF 2 EQUATIONS
-- ============================================================================

local system = { fields = {}, active = 1, result = nil, err = nil }

function system.enter()
  system.fields = { newField(30), newField(30) }
  system.active = 1
  system.result, system.err = nil, nil
end

function system.charIn(ch)
  fieldChar(system.fields[system.active], ch)
end

function system.backspaceKey()
  fieldBackspace(system.fields[system.active])
end

function system.arrowKey(key)
  if key == "up" or key == "down" then
    system.active = system.active == 1 and 2 or 1
  end
end

function system.enterKey()
  local e1, e2 = system.fields[1].text, system.fields[2].text
  if e1 == "" or e2 == "" then return end
  local vars = guessVariables(e1 .. " " .. e2, 2)
  if #vars < 2 then vars[2] = (vars[1] == "x") and "y" or "x" end
  local result, err = casEval("solve({" .. e1 .. "," .. e2 .. "},{" .. vars[1] .. "," .. vars[2] .. "})")
  system.result, system.err = result, err
end

function system.escapeKey()
  if system.result or system.err then
    system.enter()
  else
    switchScreen("lobby")
  end
end

function system.paint(gc)
  local y = drawChrome(gc, "System of 2 Equations", "Up/Down field  type eqns  Enter=solve  Esc=clear/back")
  drawField(gc, system.fields[1], 6, y + 10, W - 12, system.active == 1, "Equation 1 (e.g. y=2x+3)")
  drawField(gc, system.fields[2], 6, y + 44, W - 12, system.active == 2, "Equation 2 (e.g. y=-x+1)")
  local by = y + 68
  if system.result then
    drawResultBox(gc, 6, by, W - 12, H - by - 18, { { text = system.result, color = COLOR.ok } })
  elseif system.err then
    drawResultBox(gc, 6, by, W - 12, 24, { { text = system.err, color = COLOR.warn } })
  end
end

screens.system = system

-- ============================================================================
-- SIMPLIFY / FACTOR / EXPAND
-- ============================================================================

local simplify = { field = newField(44), modeIdx = 1, result = nil, err = nil }
local SIMPLIFY_MODES = { "simplify", "factor", "expand" }

function simplify.enter()
  simplify.field = newField(44)
  simplify.modeIdx = 1
  simplify.result, simplify.err = nil, nil
end

function simplify.charIn(ch)
  fieldChar(simplify.field, ch)
end

function simplify.backspaceKey()
  fieldBackspace(simplify.field)
end

function simplify.arrowKey(key)
  if key == "up" then
    simplify.modeIdx = simplify.modeIdx - 1
    if simplify.modeIdx < 1 then simplify.modeIdx = #SIMPLIFY_MODES end
  elseif key == "down" then
    simplify.modeIdx = simplify.modeIdx + 1
    if simplify.modeIdx > #SIMPLIFY_MODES then simplify.modeIdx = 1 end
  end
end

function simplify.enterKey()
  local expr = simplify.field.text
  if expr == "" then return end
  local mode = SIMPLIFY_MODES[simplify.modeIdx]
  local result, err = casEval(mode .. "(" .. expr .. ")")
  simplify.result, simplify.err = result, err
end

function simplify.escapeKey()
  if simplify.result or simplify.err then
    simplify.result, simplify.err = nil, nil
  else
    switchScreen("lobby")
  end
end

function simplify.paint(gc)
  local y = drawChrome(gc, "Simplify / Factor / Expand", "Up/Down mode  type expr  Enter=go  Esc=clear/back")
  setColor(gc, COLOR.gold)
  gc:setFont("sansserif", "b", 9)
  gc:drawString("Mode: " .. SIMPLIFY_MODES[simplify.modeIdx], 6, y, "top")
  y = y + 14
  drawField(gc, simplify.field, 6, y, W - 12, true, "Expression (e.g. x^2-9, or 2(x+3)-x)")
  local by = y + 28
  if simplify.result then
    drawResultBox(gc, 6, by, W - 12, 28, { { text = simplify.result, color = COLOR.ok } })
  elseif simplify.err then
    drawResultBox(gc, 6, by, W - 12, 24, { { text = simplify.err, color = COLOR.warn } })
  end
end

screens.simplify = simplify

-- ============================================================================
-- EVALUATE f(x)
-- ============================================================================

local evaluate = { fields = {}, active = 1, result = nil, err = nil }

function evaluate.enter()
  evaluate.fields = { newField(40), newField(12, true) }
  evaluate.active = 1
  evaluate.result, evaluate.err = nil, nil
end

function evaluate.charIn(ch)
  fieldChar(evaluate.fields[evaluate.active], ch)
end

function evaluate.backspaceKey()
  fieldBackspace(evaluate.fields[evaluate.active])
end

function evaluate.arrowKey(key)
  if key == "up" or key == "down" then
    evaluate.active = evaluate.active == 1 and 2 or 1
  end
end

function evaluate.enterKey()
  local expr = evaluate.fields[1].text
  local val = evaluate.fields[2].text
  if expr == "" or val == "" then return end
  local var = guessVariables(expr, 1)[1] or "x"
  local result, err = casEval("(" .. expr .. ")|" .. var .. "=" .. val)
  evaluate.result, evaluate.err = result, err
  if result then evaluate.lastVar = var end
end

function evaluate.escapeKey()
  if evaluate.result or evaluate.err then
    evaluate.result, evaluate.err = nil, nil
  else
    switchScreen("lobby")
  end
end

function evaluate.paint(gc)
  local y = drawChrome(gc, "Evaluate f(x)", "Up/Down field  type expr+value  Enter=go  Esc=clear/back")
  drawField(gc, evaluate.fields[1], 6, y + 10, W - 12, evaluate.active == 1, "f(x) = ... (e.g. 2x^2-3x+1)")
  drawField(gc, evaluate.fields[2], 6, y + 44, 90, evaluate.active == 2, "value")
  local by = y + 68
  if evaluate.result then
    drawResultBox(gc, 6, by, W - 12, 24, {
      { text = (evaluate.lastVar or "x") .. "=" .. evaluate.fields[2].text .. "  ->  " .. evaluate.result, color = COLOR.ok },
    })
  elseif evaluate.err then
    drawResultBox(gc, 6, by, W - 12, 24, { { text = evaluate.err, color = COLOR.warn } })
  end
end

screens.evaluate = evaluate

-- ============================================================================
-- PERCENT TOOLKIT
-- ============================================================================

local percent = { fields = {}, active = 1, modeIdx = 1 }
local PERCENT_MODES = { "A% of B", "%% change A to B", "A is what %% of B" }

function percent.enter()
  percent.fields = { newField(12, true), newField(12, true) }
  percent.active = 1
  percent.modeIdx = 1
end

function percent.charIn(ch)
  fieldChar(percent.fields[percent.active], ch)
end

function percent.backspaceKey()
  fieldBackspace(percent.fields[percent.active])
end

function percent.arrowKey(key)
  if key == "left" or key == "right" then
    percent.active = percent.active == 1 and 2 or 1
  elseif key == "up" then
    percent.modeIdx = percent.modeIdx - 1
    if percent.modeIdx < 1 then percent.modeIdx = #PERCENT_MODES end
  elseif key == "down" then
    percent.modeIdx = percent.modeIdx + 1
    if percent.modeIdx > #PERCENT_MODES then percent.modeIdx = 1 end
  end
end

function percent.compute()
  local a = tonumber(percent.fields[1].text)
  local b = tonumber(percent.fields[2].text)
  if not a or not b then return nil end
  if percent.modeIdx == 1 then
    return string.format("%g%% of %g = %.4g", a, b, a / 100 * b)
  elseif percent.modeIdx == 2 then
    if a == 0 then return "A can't be 0 for %% change." end
    local pct = (b - a) / a * 100
    local dir = pct >= 0 and "increase" or "decrease"
    return string.format("%.4g -> %.4g is a %.4g%% %s", a, b, math.abs(pct), dir)
  else
    if b == 0 then return "B can't be 0." end
    return string.format("%g is %.4g%% of %g", a, a / b * 100, b)
  end
end

function percent.paint(gc)
  local y = drawChrome(gc, "Percent Toolkit", "Left/Right field  Up/Down mode  Esc=back")
  setColor(gc, COLOR.gold)
  gc:setFont("sansserif", "b", 9)
  gc:drawString("Mode: " .. PERCENT_MODES[percent.modeIdx]:gsub("%%%%", "%%"), 6, y, "top")
  y = y + 14
  drawField(gc, percent.fields[1], 6, y + 10, 90, percent.active == 1, "A")
  drawField(gc, percent.fields[2], 104, y + 10, 90, percent.active == 2, "B")
  local out = percent.compute()
  if out then
    drawResultBox(gc, 6, y + 40, W - 12, 26, { { text = out, color = COLOR.ok } })
  end
end

function percent.escapeKey()
  switchScreen("lobby")
end

screens.percent = percent

-- ============================================================================
-- RATE * DISTANCE * TIME
-- ============================================================================

local rdt = { fields = {}, active = 1 }

function rdt.enter()
  rdt.fields = { newField(12, true), newField(12, true), newField(12, true) }
  rdt.active = 1
end

function rdt.charIn(ch)
  fieldChar(rdt.fields[rdt.active], ch)
end

function rdt.backspaceKey()
  fieldBackspace(rdt.fields[rdt.active])
end

function rdt.arrowKey(key)
  if key == "left" then
    rdt.active = rdt.active - 1
    if rdt.active < 1 then rdt.active = 3 end
  elseif key == "right" then
    rdt.active = rdt.active + 1
    if rdt.active > 3 then rdt.active = 1 end
  end
end

-- Leave exactly one of Distance/Rate/Time blank; the other two solve for it.
function rdt.compute()
  local raw = { rdt.fields[1].text, rdt.fields[2].text, rdt.fields[3].text }
  local blanks = {}
  for i, t in ipairs(raw) do if t == "" then blanks[#blanks + 1] = i end end
  if #blanks == 0 then
    local d, r, t = tonumber(raw[1]), tonumber(raw[2]), tonumber(raw[3])
    if d and r and t then
      local ok = math.abs(d - r * t) < 1e-6
      return string.format("Check: d=r*t -> %.4g %s %.4g*%.4g=%.4g", d, ok and "=" or "!=", r, t, r * t)
    end
    return nil
  end
  if #blanks > 1 then
    return "Leave exactly one field blank (the unknown)."
  end
  local d, r, t = tonumber(raw[1]), tonumber(raw[2]), tonumber(raw[3])
  local missing = blanks[1]
  if missing == 1 then
    if not (r and t) then return nil end
    return string.format("Distance = r*t = %.4g * %.4g = %.4g", r, t, r * t)
  elseif missing == 2 then
    if not (d and t) then return nil end
    if t == 0 then return "Time can't be 0." end
    return string.format("Rate = d/t = %.4g / %.4g = %.4g", d, t, d / t)
  else
    if not (d and r) then return nil end
    if r == 0 then return "Rate can't be 0." end
    return string.format("Time = d/r = %.4g / %.4g = %.4g", d, r, d / r)
  end
end

function rdt.paint(gc)
  local y = drawChrome(gc, "Rate * Distance * Time", "Left/Right field  leave 1 blank  Esc=back")
  setColor(gc, COLOR.dim)
  gc:setFont("sansserif", "r", 8)
  gc:drawString("d = r * t  --  leave the unknown blank", 6, y, "top")
  y = y + 14
  local labels = { "Distance", "Rate", "Time" }
  local fw = 90
  for i = 1, 3 do
    drawField(gc, rdt.fields[i], 6 + (i - 1) * (fw + 8), y + 10, fw, rdt.active == i, labels[i])
  end
  local out = rdt.compute()
  if out then
    drawResultBox(gc, 6, y + 40, W - 12, 26, { { text = out, color = COLOR.ok } })
  end
end

function rdt.escapeKey()
  switchScreen("lobby")
end

screens.rdt = rdt

-- ============================================================================
-- SAT / COLLEGE ALGEBRA FORMULA SHEET
-- ============================================================================

local formulas = { idx = 1 }
local FORMULA_PAGES = {
  { title = "Linear Equations", lines = {
    "y = mx + b  (slope-intercept)",
    "m = (y2-y1) / (x2-x1)",
    "Point-slope: y - y1 = m(x - x1)",
    "Parallel lines: equal slopes",
    "Perpendicular: slopes are negative",
    "  reciprocals of each other",
  } },
  { title = "Quadratics", lines = {
    "Standard form: ax^2 + bx + c = 0",
    "Quadratic formula:",
    "x = (-b +/- sqrt(b^2-4ac)) / (2a)",
    "Discriminant D = b^2 - 4ac",
    "D>0: two real roots",
    "D=0: one repeated root",
    "D<0: two complex roots",
    "Vertex form: y=a(x-h)^2+k, vertex(h,k)",
    "Axis of symmetry: x = -b/(2a)",
  } },
  { title = "Exponent & Radical Rules", lines = {
    "x^a * x^b = x^(a+b)",
    "x^a / x^b = x^(a-b)",
    "(x^a)^b = x^(a*b)",
    "x^0 = 1  (x != 0)",
    "x^(-a) = 1 / x^a",
    "x^(1/n) = n-th root of x",
    "sqrt(a) * sqrt(b) = sqrt(a*b)",
  } },
  { title = "Factoring Patterns", lines = {
    "Diff. of squares: a^2-b^2=(a-b)(a+b)",
    "Perfect square:",
    "  a^2+2ab+b^2 = (a+b)^2",
    "  a^2-2ab+b^2 = (a-b)^2",
    "Sum of cubes:",
    "  a^3+b^3=(a+b)(a^2-ab+b^2)",
    "Diff. of cubes:",
    "  a^3-b^3=(a-b)(a^2+ab+b^2)",
  } },
  { title = "Systems of Equations", lines = {
    "Substitution: solve one eqn for a",
    "  variable, plug into the other",
    "Elimination: add/subtract eqns to",
    "  cancel a variable",
    "1 solution: lines cross",
    "0 solutions: parallel lines",
    "Infinite solutions: same line",
  } },
  { title = "Geometry: Area & Perimeter", lines = {
    "Rectangle: A=lw   P=2(l+w)",
    "Triangle: A = 1/2 * b * h",
    "Circle: A = pi*r^2   C = 2*pi*r",
    "Trapezoid: A = 1/2 (b1+b2) h",
    "Parallelogram: A = b * h",
  } },
  { title = "Geometry: 3D & Triangles", lines = {
    "Rect. prism: V = l*w*h",
    "Cylinder: V = pi*r^2*h",
    "Sphere: V = 4/3 * pi * r^3",
    "Cone: V = 1/3 * pi * r^2 * h",
    "Pythagorean: a^2 + b^2 = c^2",
    "45-45-90: legs x, hyp x*sqrt(2)",
    "30-60-90: sides x, x*sqrt(3), 2x",
  } },
  { title = "Coordinate Geometry", lines = {
    "Distance:",
    "  d = sqrt((x2-x1)^2 + (y2-y1)^2)",
    "Midpoint: ((x1+x2)/2, (y1+y2)/2)",
    "Circle: (x-h)^2 + (y-k)^2 = r^2",
  } },
  { title = "Statistics & Probability", lines = {
    "Mean = sum of values / count",
    "Median = middle value (sorted)",
    "Range = max - min",
    "P(event) = favorable / total outcomes",
    "P(A and B) = P(A)*P(B) if independent",
  } },
  { title = "Function Notation & SAT Tips", lines = {
    "f(x) = output for input x",
    "f(a)=b  means point (a,b) is on graph",
    "|x|=a  ->  x=a or x=-a",
    "Always check answers by substituting",
    "  back into the original equation",
    "Watch for extraneous roots (radical",
    "  and rational equations)",
  } },
}

function formulas.enter()
  formulas.idx = 1
end

function formulas.arrowKey(key)
  if key == "up" then
    formulas.idx = formulas.idx - 1
    if formulas.idx < 1 then formulas.idx = #FORMULA_PAGES end
  elseif key == "down" then
    formulas.idx = formulas.idx + 1
    if formulas.idx > #FORMULA_PAGES then formulas.idx = 1 end
  end
end

function formulas.escapeKey()
  switchScreen("lobby")
end

function formulas.paint(gc)
  local page = FORMULA_PAGES[formulas.idx]
  local y = drawChrome(gc, "SAT Formula Sheet", "Up/Down = next/prev topic   Esc=back")
  setColor(gc, COLOR.gold)
  gc:setFont("sansserif", "b", 10)
  gc:drawString(page.title .. "  (" .. formulas.idx .. "/" .. #FORMULA_PAGES .. ")", 6, y, "top")
  y = y + 16
  setColor(gc, COLOR.white)
  gc:setFont("sansserif", "r", 8)
  for _, line in ipairs(page.lines) do
    gc:drawString(line, 8, y, "top")
    y = y + 12
  end
end

screens.formulas = formulas

-- ============================================================================
-- HOW TO USE
-- ============================================================================

local help = {}
local HELP_LINES = {
  "Every tool is keyboard only:",
  "type expressions/numbers, Enter runs",
  "the tool, Esc clears a result or",
  "returns to the menu.",
  "",
  "Solve / Simplify / System / Evaluate",
  "call the calculator's CAS, so they",
  "need a CAS-enabled handheld (CX II",
  "CAS). Quadratic Helper, Percent",
  "Toolkit, Rate*Distance*Time and the",
  "Formula Sheet are plain arithmetic",
  "and work on any Nspire.",
  "",
  "Equation Solver: type an equation",
  "(x^2-5x+6=0). '=0' is added if you",
  "omit it. The variable is guessed",
  "from your input.",
  "",
  "Tip: for the SAT, use the Formula",
  "Sheet as a quick review, and the",
  "solvers to check your work.",
}

function help.paint(gc)
  local y = drawChrome(gc, "How To Use", "Esc=back")
  setColor(gc, COLOR.white)
  gc:setFont("sansserif", "r", 8)
  for _, line in ipairs(HELP_LINES) do
    gc:drawString(line, 6, y, "top")
    y = y + 11
  end
end

function help.escapeKey()
  switchScreen("lobby")
end

screens.help = help

-- ============================================================================
-- Top-level event dispatch
-- ============================================================================

function on.resize(w, h)
  W, H = w, h
  platform.window:invalidate()
end

function on.paint(gc)
  screens[screen].paint(gc)
end

function on.charIn(ch)
  if screens[screen].charIn then screens[screen].charIn(ch) end
  platform.window:invalidate()
end

function on.enterKey()
  if screens[screen].enterKey then screens[screen].enterKey() end
  platform.window:invalidate()
end

function on.escapeKey()
  if screens[screen].escapeKey then screens[screen].escapeKey() end
  platform.window:invalidate()
end

function on.backspaceKey()
  if screens[screen].backspaceKey then screens[screen].backspaceKey() end
  platform.window:invalidate()
end

function on.arrowKey(key)
  if screens[screen].arrowKey then screens[screen].arrowKey(key) end
  platform.window:invalidate()
end
