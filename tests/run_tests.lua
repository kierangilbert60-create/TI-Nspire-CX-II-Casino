-- ============================================================================
-- Test suite for src/eqsolver.lua
--
--   lua5.1 tests/run_tests.lua        (5.1 matches the handheld's interpreter)
--   lua5.3 tests/run_tests.lua        (catches version-specific slips)
--
-- Covers the parser, the exact algebra engine, every solver mode, the answer
-- checking, error handling, and the drawing code (painted through a mock of
-- the Nspire graphics API at several screen sizes).
-- ============================================================================

package.path = "./tests/?.lua;" .. package.path
local mock = require("mock_nspire")

_G.__eqsolver_test = {}
local src = assert(io.open("src/eqsolver.lua", "r"))
local code = src:read("*a")
src:close()
local chunk = assert(loadstring and loadstring(code, "@eqsolver") or load(code, "@eqsolver"))
chunk()

local T = _G.__eqsolver_test
local ENG, MODES, app = T.ENG, T.MODES, T.app

local pass, fail, failures = 0, 0, {}
local group = "?"

local function ok(cond, what)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = group .. ": " .. what
  end
  return cond
end

local function eq(got, want, what)
  return ok(got == want, what .. "  (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
end

-- ---------------------------------------------------------------------------
group = "parser"
-- ---------------------------------------------------------------------------

local function evalAt(text, env)
  local st = T.parseOne(text)
  return T.astNum(st.lhs, env)
end

local parseCases = {
  { "2x",            { x = 5 }, 10 },
  { "2 x",           { x = 5 }, 10 },
  { "2*x",           { x = 5 }, 10 },
  { "x y",           { x = 3, y = 4 }, 12 },
  { "xy",            { x = 3, y = 4 }, 12 },
  { "3(x+1)",        { x = 2 }, 9 },
  { "(x+1)(x-1)",    { x = 3 }, 8 },
  { "x^2",           { x = -3 }, 9 },
  { "-x^2",          { x = 3 }, -9 },
  { "(-x)^2",        { x = 3 }, 9 },
  { "2^-2",          {}, 0.25 },
  { "2^3^2",         {}, 512 },          -- right associative
  { "x^2y",          { x = 2, y = 5 }, 20 },
  { "1/2x",          { x = 4 }, 2 },     -- (1/2)*x, standard reading
  { "sqrt(9)",       {}, 3 },
  { "sqrt 9",        {}, 3 },
  { "abs(-4)",       {}, 4 },
  { "|3-7|",         {}, 4 },
  { "0.25",          {}, 0.25 },
  { ".5+.25",        {}, 0.75 },
  { "10-3-2",        {}, 5 },            -- left associative
  { "12/3/2",        {}, 2 },
  { "2+3*4",         {}, 14 },
  { "-3+5",          {}, 2 },
  { "X^2",           { x = 4 }, 16 },    -- case insensitive
  { "3\226\136\1461",{}, 2 },            -- unicode minus
  { "x\194\178",     { x = 5 }, 25 },    -- superscript two
  { "\226\136\154(16)", {}, 4 },         -- unicode radical
}
for _, c in ipairs(parseCases) do
  local got = evalAt(c[1], c[2])
  ok(got and math.abs(got - c[3]) < 1e-9,
     "parse " .. c[1] .. " = " .. tostring(got) .. " want " .. c[3])
end

local badInputs = { "2x+", "(x+1", "x+1)", "2**3", "x=1=2", "", "@#$", "3 4 +", "sqrt(", "|x" }
for _, s in ipairs(badInputs) do
  local good = pcall(T.parseOne, s)
  ok(not good, "rejects bad input: " .. (s == "" and "<empty>" or s))
end

-- ---------------------------------------------------------------------------
group = "factor"
-- ---------------------------------------------------------------------------

local function polyOf(s)
  local st = T.parseOne(s)
  local ctx = T.newCtx()
  local r = T.astToR(st.lhs, ctx)
  assert(T.pisconst(r.d), "not polynomial: " .. s)
  return T.pscale(r.n, T.ONE / T.pconstval(r.d))
end

local factorCases = {
  { "x^2-5x+6",      "(x - 2)(x - 3)" },
  { "x^2+5x+6",      "(x + 2)(x + 3)" },
  { "x^2-9",         "(x + 3)(x - 3)" },
  { "4x^2-9",        "(2x + 3)(2x - 3)" },
  { "6x^2+11x+3",    "(2x + 3)(3x + 1)" },
  { "x^2+6x+9",      "(x + 3)^2" },
  { "4x^2-12x+9",    "(2x - 3)^2" },
  { "x^3-8",         "(x - 2)(x^2 + 2x + 4)" },
  { "x^3+27",        "(x + 3)(x^2 - 3x + 9)" },
  { "2x^3-4x^2-6x",  "2x(x + 1)(x - 3)" },
  { "x^4-16",        "(x + 2)(x - 2)(x^2 + 4)" },
  { "x^4+5x^2+6",    "(x^2 + 2)(x^2 + 3)" },
  { "x^4+4",         "(x^2 + 2x + 2)(x^2 - 2x + 2)" },
  { "x^2+2xy+y^2",   "(x + y)^2" },
  { "x^2-y^2",       "(x + y)(x - y)" },
  { "6x^2+11xy+3y^2","(2x + 3y)(3x + y)" },
  { "xy+x+y+1",      "(x + 1)(y + 1)" },
  { "x^3-x",         "x(x + 1)(x - 1)" },
  { "x^2+1",         "x^2 + 1" },
  { "x^2+x+1",       "x^2 + x + 1" },
  { "12x^2y-27y^3",  "3y(2x + 3y)(2x - 3y)" },
  { "x^6-1",         "(x + 1)(x - 1)(x^2 + x + 1)(x^2 - x + 1)" },
  { "x^2/4-1",       "(1/4)(x + 2)(x - 2)" },
  { "0",             "0" },
  { "7",             "7" },
  { "x",             "x" },
}
for _, c in ipairs(factorCases) do
  local f = ENG.factorPoly(polyOf(c[1]))
  eq(ENG.factorStr(f, "x"), c[2], "factor " .. c[1])
end

-- randomised: build a product of known factors, expand it, factor it back and
-- require the SAME multiset of primitive factors (factorisation over Q is
-- unique), then require the product to re-expand to the original.
local function normalizedFactorList(poly)
  local f = ENG.factorPoly(poly)
  local names = {}
  for _, item in ipairs(f.factors) do
    for _ = 1, item.k do names[#names + 1] = T.pstr(item.p, "x") end
  end
  table.sort(names)
  return names, f
end

math.randomseed(20240917)
local pieces = {
  "(x - 1)", "(x + 1)", "(x - 2)", "(x + 3)", "(2x + 1)", "(3x - 2)",
  "(x + 5)", "(x - 4)", "(x^2 + 1)", "(x^2 + 2)", "(5x + 4)", "(x - 7)",
}
for trial = 1, 400 do
  local n = 2 + math.random(0, 2)
  local chosen = {}
  for i = 1, n do chosen[i] = pieces[math.random(#pieces)] end
  local expr = table.concat(chosen, "")
  local poly = polyOf(expr)
  local got = normalizedFactorList(poly)

  local want = {}
  for _, piece in ipairs(chosen) do
    local sub = normalizedFactorList(polyOf(piece))
    for _, nm in ipairs(sub) do want[#want + 1] = nm end
  end
  table.sort(want)
  local same = #got == #want
  if same then
    for i = 1, #got do
      if got[i] ~= want[i] then same = false; break end
    end
  end
  if not ok(same, "random factor #" .. trial .. " " .. expr ..
            " -> " .. table.concat(got, " ") .. " want " .. table.concat(want, " ")) then
    break
  end
end

-- ---------------------------------------------------------------------------
group = "solve"
-- ---------------------------------------------------------------------------

local function answersOf(fn, text)
  local good, res = pcall(fn, text)
  if not good then return nil, (type(res) == "table" and (res.msg or res.code) or tostring(res)) end
  if not res.ok then return nil, res.error end
  return res.answers, nil, res
end

local function joined(list) return table.concat(list or {}, " ; ") end

local solveCases = {
  { "3x+7=22",              "x = 5" },
  { "2(x+3)=5x-4",          "x = 10/3   \226\137\136 3.333333" },
  { "x/2 + 1/3 = 5/6",      "x = 1" },
  { "x^2-5x+6=0",           "x = 2 ; x = 3" },
  { "x^2=4",                "x = -2 ; x = 2" },
  { "x^2+4=0",              "x = -2i ; x = 2i" },
  { "x^3-6x^2+11x-6=0",     "x = 1 ; x = 2 ; x = 3" },
  { "x^4-5x^2+4=0",         "x = -2 ; x = -1 ; x = 1 ; x = 2" },
  { "(x-1)/(x-2)=3",        "x = 5/2   \226\137\136 2.5" },
  { "abs(2x-3)=7",          "x = -2 ; x = 5" },
  { "sqrt(x+4)=x-2",        "x = 5" },
  { "2x+1=2x+3",            "no solution" },
  { "2x+1=2x+1",            "every real number (identity)" },
  { "x^2/(x-1)=1/(x-1)",    "x = -1" },
  { "5=5",                  "true" },
  { "2pi*r=10",             "r = 5/pi" },
  { "x^2-2=0",              "x = -\226\136\1542   \226\137\136 -1.414214 ; x = \226\136\1542   \226\137\136 1.414214" },
}
for _, c in ipairs(solveCases) do
  local a, err = answersOf(ENG.solve, c[1])
  eq(joined(a) or ("ERROR " .. tostring(err)), c[2], "solve " .. c[1])
end

-- every solution must satisfy the ORIGINAL equation
local function satisfies(text, varName)
  local a, err, res = answersOf(ENG.solve, text)
  if not a then return false, err end
  if not res.roots then return true end
  local st = T.parseOne(text)
  local rhs = st.rhs or { k = "num", v = T.q(0) }
  for _, r in ipairs(res.roots) do
    if r.kind == "real" and r.num then
      local l = T.astNum(st.lhs, { [varName] = r.num })
      local rr = T.astNum(rhs, { [varName] = r.num })
      if l == nil or rr == nil then return false, "undefined at a root" end
      if math.abs(l - rr) > 1e-6 * (1 + math.abs(l) + math.abs(rr)) then
        return false, "root " .. r.exact .. " does not satisfy it"
      end
    end
  end
  return true
end

for _, text in ipairs({
  "x^2-5x+6=0", "3x+7=22", "x^2+x-1=0", "x^3-2x-5=0", "x^4-10x^2+9=0",
  "1/x + 1/(x+1) = 1/2", "sqrt(x+4)=x-2", "sqrt(2x+3)=x", "abs(2x-3)=7",
  "abs(x+1)=2x", "(x-1)/(x-2)=3", "x^5-x=0", "2x^3-3x^2-11x+6=0",
  "x^2-2=0", "6x^2+11x+3=0", "(x+1)^2=9", "x^3=27", "x^2/(x-1)=1/(x-1)",
}) do
  local good, why = satisfies(text, "x")
  ok(good, "roots satisfy " .. text .. (why and ("  -- " .. tostring(why)) or ""))
end

-- randomised: construct polynomials from known rational roots and require
-- exactly those roots back
local function qstrOf(n, d)
  local g = (function(a, b) a, b = math.abs(a), math.abs(b); while b > 0 do a, b = b, a % b end; return a end)(n, d)
  n, d = n / g, d / g
  if d < 0 then n, d = -n, -d end
  if d == 1 then return tostring(math.floor(n)) end
  return math.floor(n) .. "/" .. math.floor(d)
end

for trial = 1, 300 do
  local k = math.random(1, 3)
  local seen, roots, factors = {}, {}, {}
  for _ = 1, k do
    local den = ({ 1, 1, 1, 2, 3 })[math.random(5)]
    local num = math.random(-6, 6)
    local key = qstrOf(num, den)
    if not seen[key] then
      seen[key] = true
      roots[#roots + 1] = { n = num, d = den, key = key, val = num / den }
      factors[#factors + 1] = "(" .. den .. "x - " .. num .. ")"
    end
  end
  local expr = table.concat(factors, "") .. " = 0"
  table.sort(roots, function(a, b) return a.val < b.val end)
  local want = {}
  for i, r in ipairs(roots) do
    want[i] = "x = " .. r.key
    if r.key:find("/") then
      want[i] = want[i] .. "   \226\137\136 " ..
        (function(x)
           local s = string.format("%.6f", x):gsub("0+$", ""):gsub("%.$", "")
           return s
         end)(r.val)
    end
  end
  local a = answersOf(ENG.solve, expr)
  if not ok(joined(a) == table.concat(want, " ; "),
            "random solve #" .. trial .. " " .. expr .. " -> " .. joined(a) ..
            "  want " .. table.concat(want, " ; ")) then
    break
  end
end

-- ---------------------------------------------------------------------------
group = "modes"
-- ---------------------------------------------------------------------------

local modeCases = {
  { ENG.doFactor,   "x^2-5x+6",             "(x - 2)(x - 3)" },
  { ENG.doFactor,   "(x^2-1)/(x^2-2x+1)",   "(x + 1)/(x - 1)" },
  { ENG.doExpand,   "(x+3)(x-2)",           "x^2 + x - 6" },
  { ENG.doExpand,   "(2x-1)^3",             "8x^3 - 12x^2 + 6x - 1" },
  { ENG.doExpand,   "(x+y)^2",              "x^2 + 2x*y + y^2" },
  { ENG.doEvaluate, "x^2+3x-1, x=2",        "9" },
  { ENG.doEvaluate, "2x+y, x=1, y=3",       "5" },
  { ENG.doEvaluate, "x^2=4, x=-2",          "true" },
  { ENG.doSystem,   "2x+y=7, x-y=2",        "x = 3 ; y = 1" },
  { ENG.doSystem,   "3x+2y=16, 5x-y=9",     "x = 34/13 ; y = 53/13" },
  { ENG.doSystem,   "x+y=3, 2x+2y=6",       "infinitely many solutions (same line)" },
  { ENG.doSystem,   "x+y=3, 2x+2y=7",       "no solution (parallel lines)" },
  { ENG.doSystem,   "y=x^2, y=x+2",         "x = -1,  y = 1 ; x = 2,  y = 4" },
  { ENG.doSolveFor, "a=1/2*b*h for h",      "h = 2a/b" },
  { ENG.doSolveFor, "f=9/5*c+32 for c",     "c = (5f - 160)/9" },
  { ENG.doSolveFor, "2x+3y=12 for y",       "y = (-2x + 12)/3" },
  { ENG.doSolveFor, "v=pi*r^2*h for h",     "h = v/(pi*r^2)" },
}
for _, c in ipairs(modeCases) do
  local a, err = answersOf(c[1], c[2])
  eq(joined(a) or ("ERROR " .. tostring(err)), c[3], c[2])
end

-- the printed factorisation must parse back and expand to the original
for _, s in ipairs({ "x^2-5x+6", "6x^2+11x+3", "x^4-16", "2x^3-4x^2-6x",
                     "x^2+2xy+y^2", "x^3-8", "12x^2y-27y^3", "x^2/4-1" }) do
  local a = answersOf(ENG.doFactor, s)
  local good = false
  if a and a[1] then
    local parsed = pcall(function()
      local back = polyOf(a[1])
      good = (back == polyOf(s))
    end)
    if not parsed then good = false end
  end
  ok(good, "factored form of " .. s .. " re-expands to the original (" ..
     tostring(a and a[1]) .. ")")
end

-- and so must the expanded form
for _, s in ipairs({ "(x+3)(x-2)", "(2x-1)^3", "(x+y)^2", "3(x-1)+2(x+4)",
                     "(x+1)(x-1)(x+2)" }) do
  local a = answersOf(ENG.doExpand, s)
  local good = false
  pcall(function() good = (polyOf(a[1]) == polyOf(s)) end)
  ok(good, "expanded form of " .. s .. " matches the original")
end

-- ---------------------------------------------------------------------------
group = "steps"
-- ---------------------------------------------------------------------------

local stepProbes = {
  { ENG.solve,      "x^2-5x+6=0" },
  { ENG.solve,      "3x+7=22" },
  { ENG.solve,      "sqrt(x+4)=x-2" },
  { ENG.solve,      "1/x + 1/(x+1) = 1/2" },
  { ENG.solve,      "sin(x)=0.5" },
  { ENG.doFactor,   "x^4-16" },
  { ENG.doExpand,   "(x+3)(x-2)" },
  { ENG.doEvaluate, "x^2+3x-1, x=2" },
  { ENG.doSystem,   "2x+y=7, x-y=2" },
  { ENG.doAnalyze,  "x^2-4x+1" },
}
for _, probe in ipairs(stepProbes) do
  local _, err, res = answersOf(probe[1], probe[2])
  if ok(res ~= nil, "steps produced for " .. probe[2] .. " " .. tostring(err)) then
    ok(#res.steps >= 2, "at least two steps for " .. probe[2])
    local clean = true
    for _, st in ipairs(res.steps) do
      if type(st.title) ~= "string" or st.title == "" then clean = false end
      for _, field in ipairs({ st.title, st.body, st.note }) do
        if field ~= nil and (type(field) ~= "string" or field:find("nil") or field:find("table: ")) then
          clean = false
        end
      end
    end
    ok(clean, "every step of " .. probe[2] .. " has clean text")
  end
end

-- extraneous solutions must be dropped, not reported
local a = answersOf(ENG.solve, "sqrt(x+4)=x-2")
ok(joined(a) == "x = 5", "x=0 is rejected as extraneous in sqrt(x+4)=x-2")
a = answersOf(ENG.solve, "x/(x-3) = 3/(x-3)")
ok(joined(a) == "no solution", "x=3 is rejected: it zeroes the denominator")

-- ---------------------------------------------------------------------------
group = "errors"
-- ---------------------------------------------------------------------------

for _, bad in ipairs({ "2x+", "((x+1)", "x@y", "= 5", "x^^2", "1/0",
                       "x=1, y=2, z=3", "for h", ",,,", "sqrt()" }) do
  local crashed = false
  local caught = false
  local good, res = pcall(ENG.solve, bad)
  if not good then
    caught = (type(res) == "table" and res.eqsolver == true)
    crashed = not caught
  elseif res and res.ok == false then
    caught = true
  end
  ok(not crashed, "no raw crash on " .. bad .. (crashed and ("  (" .. tostring(res) .. ")") or ""))
end

-- huge inputs must fail cleanly rather than hang or produce nonsense
for _, big in ipairs({ "(x+1)^45", "x^999=1", "(x+1)^20 = 0" }) do
  local good, res = pcall(ENG.solve, big)
  local clean = good or (type(res) == "table" and res.eqsolver == true)
  ok(clean, "clean handling of " .. big)
end

-- ---------------------------------------------------------------------------
group = "wrapping"
-- ---------------------------------------------------------------------------

local gcProbe = mock.newGC()
gcProbe:setFont("sansserif", "r", 9)
for _, sample in ipairs({
  "short",
  "a much longer line of explanatory text that definitely has to be wrapped over several lines",
  "supercalifragilisticexpialidociousandthensomemoretomakeitreallylong",
  "x = (-1 - \226\136\1545)/2   \226\137\136 -1.618034",
  "",
}) do
  local lines = T.wrapText(gcProbe, sample, 120)
  local widest = 0
  for _, l in ipairs(lines) do
    local w = gcProbe:getStringWidth(l)
    if w > widest then widest = w end
  end
  ok(widest <= 120, "wrapped within 120px (widest " .. widest .. ") for: " .. sample:sub(1, 24))
  local rejoined = table.concat(lines, ""):gsub("%s", "")
  ok(rejoined == sample:gsub("%s", ""), "no characters lost wrapping: " .. sample:sub(1, 24))
end

-- ---------------------------------------------------------------------------
group = "ui"
-- ---------------------------------------------------------------------------

local function resetApp()
  app.screen, app.text, app.caret = "input", "", 0
  app.result, app.error, app.lines = nil, nil, nil
  app.layoutW, app.scroll, app.inScroll = -1, 0, 0
  app.mode, app.menuSel, app.exSel = 1, 1, 1
  app.history, app.histPos = {}, 1
end

local function typeIn(text)
  for i = 1, #text do on.charIn(text:sub(i, i)) end
end

local function paintNow(w, h)
  on.resize(w, h)
  local gc = mock.newGC()
  local good, err = pcall(on.paint, gc)
  return good, err, gc
end

local function noOverflow(gc, w, label)
  local worst, worstText = 0, ""
  for _, rec in ipairs(gc.strings) do
    if rec.x >= 0 then
      local right = rec.x + rec.w
      if right > worst then worst, worstText = right, rec.text end
    end
  end
  ok(worst <= w + 3, label .. ": widest line ends at " .. worst .. " (screen " .. w ..
     ")  text=" .. worstText:sub(1, 40))
end

for _, size in ipairs({ { 318, 212 }, { 400, 300 }, { 640, 480 } }) do
  local w, h = size[1], size[2]
  for modeIdx, m in ipairs(MODES) do
    resetApp()
    app.mode = modeIdx
    typeIn(m.hint:gsub("\226\136\154", "sqrt"))
    local good, err, gc = paintNow(w, h)
    ok(good, "paint input screen " .. m.id .. " @" .. w .. " " .. tostring(err))
    noOverflow(gc, w, "input " .. m.id .. " @" .. w)

    on.enterKey()
    ok(app.screen == "result", "mode " .. m.id .. " produced a result from its own example" ..
       (app.error and ("  err=" .. app.error) or ""))

    good, err, gc = paintNow(w, h)
    ok(good, "paint result " .. m.id .. " @" .. w .. " " .. tostring(err))
    noOverflow(gc, w, "result " .. m.id .. " @" .. w)

    -- scroll all the way through; every line must draw
    local guard = 0
    while guard < 200 do
      guard = guard + 1
      local before = app.scroll
      on.arrowKey("down")
      local g2, e2, gc2 = paintNow(w, h)
      if not ok(g2, "paint while scrolling " .. m.id .. " " .. tostring(e2)) then break end
      noOverflow(gc2, w, "scrolled " .. m.id .. " @" .. w)
      if app.scroll == before then break end
    end
    ok(guard < 200, "scrolling terminates for " .. m.id)

    -- the drop-down, the example list and help all have to paint too
    on.tabKey()
    good, err, gc = paintNow(w, h)
    ok(good and app.screen == "menu", "paint drop-down @" .. w .. " " .. tostring(err))
    noOverflow(gc, w, "menu @" .. w)

    app.menuSel = #MODES + 1
    on.enterKey()
    good, err, gc = paintNow(w, h)
    ok(good and app.screen == "examples", "paint examples @" .. w .. " " .. tostring(err))
    noOverflow(gc, w, "examples @" .. w)

    on.enterKey()
    ok(app.screen == "input" and app.text ~= "", "picking an example fills the entry line")

    on.tabKey()
    app.menuSel = #MODES + 2
    on.enterKey()
    good, err, gc = paintNow(w, h)
    ok(good and app.screen == "help", "paint help @" .. w .. " " .. tostring(err))
    noOverflow(gc, w, "help @" .. w)
  end
end

-- every worked example in every mode must actually solve
for _, m in ipairs(MODES) do
  for _, ex in ipairs(m.examples) do
    resetApp()
    app.mode = 1
    for i, mm in ipairs(MODES) do if mm.id == m.id then app.mode = i end end
    app.text = ex
    app.caret = #ex
    local good, err = pcall(on.enterKey)
    ok(good and app.screen == "result",
       "example works: [" .. m.id .. "] " .. ex ..
       (app.error and ("  -> " .. app.error) or "") .. (good and "" or ("  !! " .. tostring(err))))
  end
end

-- editing keys
resetApp()
typeIn("x^2+1")
on.arrowKey("left"); on.arrowKey("left")
on.backspaceKey()
eq(app.text, "x^+1", "backspace deletes the character before the caret")
on.charIn("0")
eq(app.text, "x^0+1", "typing inserts at the caret")
on.clearKey()
eq(app.text, "", "clear empties the entry line")
on.backspaceKey()
eq(app.text, "", "backspace on an empty line is harmless")
on.arrowKey("left"); on.arrowKey("right")
eq(app.caret, 0, "caret stays inside the text")

-- history
resetApp()
typeIn("3x+7=22"); on.enterKey(); on.escapeKey(); on.escapeKey()
app.screen = "input"; app.text = ""; app.caret = 0
on.arrowKey("up")
eq(app.text, "3x+7=22", "up-arrow recalls the last entry")

-- bad input reaches the user as a message, never as a crash
resetApp()
typeIn("2x+")
local goodRun = pcall(on.enterKey)
ok(goodRun and app.screen == "input" and app.error ~= nil,
   "a syntax error keeps you on the entry line with a message")
local goodPaint = paintNow(318, 212)
ok(goodPaint, "the error message paints")

-- save / restore round trip
resetApp()
app.mode = 3; app.text = "(x+1)^2"
local saved = on.save()
resetApp()
on.restore(saved)
ok(app.mode == 3 and app.text == "(x+1)^2", "state survives save/restore")
ok(pcall(on.restore, nil) and pcall(on.restore, "junk") and pcall(on.restore, {}),
   "restore survives junk state")

-- ---------------------------------------------------------------------------
group = "controls"
-- ---------------------------------------------------------------------------

-- The native Nspire menu is the control path that cannot be swallowed by the
-- host software, so it has to carry every mode plus the core actions.
ok(type(mock.palette) == "table", "a toolpalette menu was registered")
if type(mock.palette) == "table" then
  local modeMenu, actionMenu = mock.palette[1], mock.palette[2]
  eq(modeMenu and modeMenu[1], "Mode", "first menu is Mode")
  eq(#modeMenu - 1, #MODES, "every mode has a menu entry")
  for i, m in ipairs(MODES) do
    eq(modeMenu[i + 1][1], m.name, "menu entry " .. i .. " names its mode")
  end
  -- picking a mode from the menu must actually switch mode
  resetApp()
  app.screen = "result"
  modeMenu[4][2]()
  ok(app.mode == 3 and app.screen == "input", "the menu switches mode and returns to the entry line")
  -- the action menu's entries must all run without error
  eq(actionMenu[1], "Solver", "second menu is Solver")
  resetApp(); app.text = "x^2-4=0"; app.caret = #app.text
  ok(pcall(actionMenu[2][2]) and app.screen == "result", "menu: Solve it now")
  resetApp()
  ok(pcall(actionMenu[3][2]) and app.screen == "examples", "menu: Examples")
  resetApp(); app.text = "junk"
  ok(pcall(actionMenu[4][2]) and app.text == "", "menu: Clear the entry line")
  resetApp()
  ok(pcall(actionMenu[5][2]) and app.screen == "help", "menu: Help")
end

-- Arrows change mode when the entry line is empty, and move the caret when it
-- is not. This is the fallback for a host that eats TAB and ESC.
resetApp()
local startMode = app.mode
on.arrowKey("right")
eq(app.mode, startMode % #MODES + 1, "right arrow on an empty line advances the mode")
on.arrowKey("left")
eq(app.mode, startMode, "left arrow on an empty line goes back")
on.arrowKey("left")
eq(app.mode, (startMode - 2) % #MODES + 1, "mode wraps around")

resetApp()
typeIn("abc")
local modeBefore = app.mode
on.arrowKey("left")
ok(app.mode == modeBefore and app.caret == 2, "with text present the arrows move the caret instead")

-- Every event must bump the counter shown in the footer, so a silent handheld
-- can be told apart from a mishandled key.
resetApp()
local before = app.eventCount
on.charIn("x"); on.arrowKey("up"); on.enterKey(); on.escapeKey(); on.tabKey()
on.backspaceKey(); on.clearKey(); on.mouseDown(10, 10)
ok(app.eventCount == before + 8, "all eight event kinds are counted (got " ..
   (app.eventCount - before) .. ")")
ok(app.lastEvent == "click", "the last event is recorded by name")

-- ---------------------------------------------------------------------------
group = "cas fallback"
-- ---------------------------------------------------------------------------

mock.clearCAS()
local ansNoCas = answersOf(ENG.solve, "sin(x)=0.5")
ok(ansNoCas and #ansNoCas > 0, "trig still answered numerically without a CAS")

mock.setFakeCAS(function(expr)
  if expr:find("^solve") then return "x=0.5235987755983 or x=2.6179938779915" end
  return "1"
end)
local ansCas = answersOf(ENG.solve, "sin(x)=0.5")
ok(ansCas and joined(ansCas):find("0.5235"), "the CAS answer is used when available")
mock.clearCAS()

-- ---------------------------------------------------------------------------
group = "fuzz"
-- ---------------------------------------------------------------------------

-- Regression: pi parses to a zero-argument node, which used to be indexed blindly.
for _, s in ipairs({ "pi", "2pi", "1/2pi", "x*pi=1", "pi=pi", "xpi0-x", "pi+sqrt(x)=0" }) do
  local good, res = pcall(ENG.solve, s)
  ok(good or (type(res) == "table" and res.eqsolver == true), "pi input handled: " .. s)
end

-- Random garbage must always come back as a clean refusal, never a Lua error.
math.randomseed(4242)
local atoms = { "x", "y", "2", "3", "0", "1/2", "0.5", "pi", "sqrt(x)", "abs(x)",
                "(x+1)", "x^2", "-x", "7" }
local ops = { "+", "-", "*", "/", "^", "", ")", "(", " ", "=", ",", "|" }
local fns = { ENG.solve, ENG.doFactor, ENG.doExpand, ENG.doEvaluate,
              ENG.doSystem, ENG.doAnalyze, ENG.doSolveFor }
local rawCrashes, firstCrash = 0, nil
for _ = 1, 3000 do
  local parts = {}
  for j = 1, math.random(1, 9) do
    parts[j] = (math.random() < 0.72) and atoms[math.random(#atoms)] or ops[math.random(#ops)]
  end
  local s = table.concat(parts)
  local good, res = pcall(fns[math.random(#fns)], s)
  if not good and not (type(res) == "table" and res.eqsolver == true) then
    rawCrashes = rawCrashes + 1
    firstCrash = firstCrash or (s .. " -> " .. tostring(res))
  end
end
ok(rawCrashes == 0, "3000 fuzzed inputs, no raw crash (" .. tostring(firstCrash) .. ")")

-- Random key mashing must never break the UI either.
math.randomseed(99)
local keys = { "char", "enter", "esc", "tab", "back", "del", "clear",
               "up", "down", "left", "right", "mouse" }
local letters = "xy0123456789+-*/^()=., "
resetApp()
local uiCrashes, firstUi = 0, nil
for _ = 1, 4000 do
  local k = keys[math.random(#keys)]
  local good, err
  if k == "char" then
    local i = math.random(#letters)
    good, err = pcall(on.charIn, letters:sub(i, i))
  elseif k == "enter" then good, err = pcall(on.enterKey)
  elseif k == "esc" then good, err = pcall(on.escapeKey)
  elseif k == "tab" then good, err = pcall(on.tabKey)
  elseif k == "back" then good, err = pcall(on.backspaceKey)
  elseif k == "del" then good, err = pcall(on.deleteKey)
  elseif k == "clear" then good, err = pcall(on.clearKey)
  elseif k == "mouse" then good, err = pcall(on.mouseDown, math.random(0, 318), math.random(0, 212))
  else good, err = pcall(on.arrowKey, k) end
  if not good then
    uiCrashes = uiCrashes + 1
    firstUi = firstUi or (k .. " -> " .. tostring(err))
  end
  if math.random() < 0.08 then
    local g2, e2 = pcall(on.paint, mock.newGC())
    if not g2 then
      uiCrashes = uiCrashes + 1
      firstUi = firstUi or ("paint -> " .. tostring(e2))
    end
  end
end
ok(uiCrashes == 0, "4000 random key/mouse events, no crash (" .. tostring(firstUi) .. ")")

-- ---------------------------------------------------------------------------
print(string.rep("=", 62))
print(string.format("%d passed, %d failed  (Lua %s)", pass, fail, _VERSION))
if fail > 0 then
  print(string.rep("-", 62))
  for i, f in ipairs(failures) do
    if i <= 40 then print("FAIL  " .. f) end
  end
  if #failures > 40 then print("... and " .. (#failures - 40) .. " more") end
  os.exit(1)
end
print("ALL GREEN")
