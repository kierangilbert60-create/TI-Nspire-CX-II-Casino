-- ============================================================================
-- STEP-BY-STEP EQUATION SOLVER  --  TI-Nspire CX / CX II (CAS or numeric)
--
-- A full algebra assistant that runs as a native Lua "Script Editor" page:
-- type an equation, pick a mode from the drop-down, and get the worked
-- solution -- every step, in order, with the reasoning -- plus the answer.
--
-- Modes: Solve, Factor, Expand, Solve for variable, Evaluate,
--        System 2x2, Analyze (roots / vertex / end behaviour).
--
-- The algebra is done by an exact rational-arithmetic engine built into this
-- file, so the steps are real work rather than a pretty-printed CAS answer.
-- Where the engine cannot go (trig / log / exp), it falls back to the
-- handheld's own CAS via math.evalStr plus a numeric root scan.
--
-- See EQUATION_SOLVER.md for install + full key reference.
-- ============================================================================

platform.apilevel = '2.5'

-- ----------------------------------------------------------------------------
-- 0. Small numeric utilities
-- ----------------------------------------------------------------------------

local floor, ceil, abs, sqrt = math.floor, math.ceil, math.abs, math.sqrt
local fmt = string.format

-- Doubles hold integers exactly up to 2^53. Everything in the exact engine
-- stays well under that; anything that would cross it raises a clean error
-- which the caller turns into "numbers got too big" instead of silent garbage.
local INT_LIMIT = 9007199254740992

local function fail(code, msg)
  error({ eqsolver = true, code = code, msg = msg }, 0)
end

local function checkInt(x, what)
  if x ~= x or x == math.huge or x == -math.huge or abs(x) >= INT_LIMIT then
    fail("overflow", (what or "A number") .. " grew too large for exact arithmetic.")
  end
  return x
end

local function igcd(a, b)
  a, b = abs(a), abs(b)
  while b > 0.5 do
    a, b = b, a % b
  end
  return a
end

local function ilcm(a, b)
  if a == 0 or b == 0 then return 0 end
  local g = igcd(a, b)
  return checkInt(abs(a) / g * abs(b), "A common denominator")
end

-- "%d" chokes on non-integral doubles in some Lua builds; "%.0f" never does.
local function intStr(n)
  if n == 0 then return "0" end
  local s = fmt("%.0f", n)
  if s == "-0" then s = "0" end
  return s
end

-- All positive divisors of n (n > 0), smallest first. Only used on the
-- constant/leading coefficients during rational-root search, and only when
-- they are small enough that trial division is instant.
local DIVISOR_LIMIT = 2000000

local function divisors(n)
  n = abs(n)
  if n == 0 or n > DIVISOR_LIMIT then return nil end
  local small, large = {}, {}
  local i = 1
  while i * i <= n do
    if n % i == 0 then
      small[#small + 1] = i
      if i ~= n / i then large[#large + 1] = n / i end
    end
    i = i + 1
  end
  for j = #large, 1, -1 do small[#small + 1] = large[j] end
  return small
end

-- sqrt(n) = k * sqrt(m) with m square-free. Returns k, m.
local function simplifySurd(n)
  if n < 0 then return 1, n end
  local k, m = 1, floor(n + 0.5)
  if m == 0 then return 0, 1 end
  local d = 2
  while d * d <= m do
    local dd = d * d
    while m % dd == 0 do
      m = m / dd
      k = k * d
    end
    d = d + 1
    if d > 100000 then break end -- give up on pathological inputs, stay exact
  end
  return k, m
end

-- ----------------------------------------------------------------------------
-- 1. Exact rational numbers
-- ----------------------------------------------------------------------------

local Q = {}
Q.__index = Q

local function q(n, d)
  d = d or 1
  if d == 0 then fail("divzero", "Division by zero.") end
  checkInt(n, "A numerator"); checkInt(d, "A denominator")
  if d < 0 then n, d = -n, -d end
  local g = igcd(n, d)
  if g > 1 then n, d = n / g, d / g end
  return setmetatable({ n = n, d = d }, Q)
end

local ZERO, ONE, MINUS_ONE, TWO = q(0), q(1), q(-1), q(2)

function Q.__add(a, b) return q(checkInt(a.n * b.d + b.n * a.d), checkInt(a.d * b.d)) end
function Q.__sub(a, b) return q(checkInt(a.n * b.d - b.n * a.d), checkInt(a.d * b.d)) end
function Q.__mul(a, b) return q(checkInt(a.n * b.n), checkInt(a.d * b.d)) end
function Q.__div(a, b)
  if b.n == 0 then fail("divzero", "Division by zero.") end
  return q(checkInt(a.n * b.d), checkInt(a.d * b.n))
end
function Q.__unm(a) return q(-a.n, a.d) end
function Q.__eq(a, b) return a.n == b.n and a.d == b.d end
function Q.__lt(a, b) return a.n * b.d < b.n * a.d end
function Q.__le(a, b) return a.n * b.d <= b.n * a.d end

local function qnum(a) return a.n / a.d end
local function qz(a) return a.n == 0 end
local function qisint(a) return a.d == 1 end
local function qabs(a) return a.n < 0 and -a or a end

local function qpow(a, k)
  if k < 0 then
    if qz(a) then fail("divzero", "Division by zero.") end
    a, k = q(a.d, a.n), -k
  end
  local r = ONE
  for _ = 1, k do r = r * a end
  return r
end

-- "3", "-7/4"
local function qstr(a)
  if a.d == 1 then return intStr(a.n) end
  return intStr(a.n) .. "/" .. intStr(a.d)
end

-- Same, but wrapped in parentheses when it is a fraction, so it can be glued
-- onto a variable without changing meaning: (3/4)x re-parses as 3/4 * x.
local function qstrCoef(a)
  if a.d == 1 then return intStr(a.n) end
  return "(" .. intStr(a.n) .. "/" .. intStr(a.d) .. ")"
end

Q.__tostring = qstr

-- Decimal rendering used for "approximately" lines. Trims trailing zeros and
-- never prints scientific notation for ordinary school-sized numbers.
local function decStr(x, digits)
  digits = digits or 6
  if x ~= x then return "undefined" end
  if x == math.huge then return "inf" end
  if x == -math.huge then return "-inf" end
  if abs(x) >= 1e12 or (x ~= 0 and abs(x) < 1e-9) then
    return (fmt("%.5g", x))
  end
  local s = fmt("%." .. digits .. "f", x)
  if s:find("%.") then
    s = s:gsub("0+$", "")
    s = s:gsub("%.$", "")
  end
  if s == "-0" then s = "0" end
  return s
end

-- ----------------------------------------------------------------------------
-- 2. Tokeniser + parser  ->  abstract syntax tree
--
-- AST nodes:
--   { k = "num", v = Q }            { k = "var", v = "x" }
--   { k = "add"/"sub"/"mul"/"div"/"pow", a = node, b = node }
--   { k = "neg", a = node }         { k = "fn",  name = "sqrt", args = { ... } }
-- ----------------------------------------------------------------------------

-- Longest first so "asin" wins over "a", and "sqrt" over "s".
local FUNC_NAMES = { "asin", "acos", "atan", "sqrt", "abs", "cos", "sin", "tan", "log", "exp", "ln", "pi" }

-- Characters the Nspire's own editor / catalogue can produce, mapped onto the
-- plain ASCII the parser understands.
local UNICODE_MAP = {
  ["\226\136\146"] = "-",      -- MINUS SIGN
  ["\226\128\147"] = "-",      -- EN DASH
  ["\226\128\148"] = "-",      -- EM DASH
  ["\195\151"]     = "*",      -- MULTIPLICATION SIGN
  ["\194\183"]     = "*",      -- MIDDLE DOT
  ["\226\139\133"] = "*",      -- DOT OPERATOR
  ["\195\183"]     = "/",      -- DIVISION SIGN
  ["\226\136\154"] = "sqrt",   -- SQUARE ROOT
  ["\207\128"]     = "pi",     -- GREEK SMALL PI
  ["\194\185"]     = "^1",
  ["\194\178"]     = "^2",
  ["\194\179"]     = "^3",
  ["\226\129\180"] = "^4",
  ["\226\129\181"] = "^5",
  ["\226\129\182"] = "^6",
  ["\226\128\162"] = "*",
}

local function normalizeInput(s)
  s = s or ""
  for from, to in pairs(UNICODE_MAP) do
    s = s:gsub(from, to)
  end
  return s:lower()
end

local function tokenize(src)
  local toks, i, n = {}, 1, #src
  local function push(t, v, at) toks[#toks + 1] = { t = t, v = v, at = at } end

  while i <= n do
    local c = src:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local s = i
      while i <= n and src:sub(i, i):match("%d") do i = i + 1 end
      if src:sub(i, i) == "." then
        i = i + 1
        while i <= n and src:sub(i, i):match("%d") do i = i + 1 end
      end
      local text = src:sub(s, i - 1)
      local dot = text:find("%.")
      local val
      if dot then
        local whole = text:sub(1, dot - 1)
        local frac = text:sub(dot + 1)
        local den = 10 ^ #frac
        val = q(tonumber(whole .. frac) or 0, den)
      else
        val = q(tonumber(text) or 0)
      end
      push("num", val, s)
    elseif c:match("%a") then
      local matched = false
      for _, name in ipairs(FUNC_NAMES) do
        if src:sub(i, i + #name - 1) == name then
          if name == "pi" then push("const", "pi", i) else push("fn", name, i) end
          i = i + #name
          matched = true
          break
        end
      end
      if not matched then
        push("var", c, i)
        i = i + 1
      end
    elseif c == "+" or c == "-" or c == "*" or c == "/" or c == "^" then
      push("op", c, i); i = i + 1
    elseif c == "(" or c == "[" or c == "{" then
      push("lp", "(", i); i = i + 1
    elseif c == ")" or c == "]" or c == "}" then
      push("rp", ")", i); i = i + 1
    elseif c == "=" then
      push("eq", "=", i); i = i + 1
    elseif c == "," or c == ";" then
      push("comma", c, i); i = i + 1
    elseif c == "|" then
      push("bar", "|", i); i = i + 1
    elseif c == "\n" then
      push("comma", ";", i); i = i + 1
    else
      fail("syntax", "I don't understand the character '" .. c .. "' (position " .. i .. ").")
    end
  end
  push("end", nil, n + 1)
  return toks
end

-- Recursive-descent parser. Handles implicit multiplication (2x, 3(x+1),
-- (x+1)(x-2), xy), right-associative ^, unary minus, |...| absolute value,
-- and function calls with or without parentheses (sqrt x == sqrt(x)).
local Parser = {}
Parser.__index = Parser

local function newParser(toks)
  return setmetatable({ toks = toks, pos = 1, barDepth = 0 }, Parser)
end

function Parser:peek(k) return self.toks[self.pos + (k or 0)] end
function Parser:next() local t = self.toks[self.pos]; self.pos = self.pos + 1; return t end
function Parser:at(t, v)
  local tok = self:peek()
  return tok.t == t and (v == nil or tok.v == v)
end
function Parser:expect(t, what)
  if not self:at(t) then
    local tok = self:peek()
    fail("syntax", "Expected " .. what .. " near position " .. tostring(tok.at) .. ".")
  end
  return self:next()
end

local function nAdd(a, b) return { k = "add", a = a, b = b } end
local function nSub(a, b) return { k = "sub", a = a, b = b } end
local function nMul(a, b) return { k = "mul", a = a, b = b } end
local function nDiv(a, b) return { k = "div", a = a, b = b } end
local function nPow(a, b) return { k = "pow", a = a, b = b } end
local function nNeg(a)    return { k = "neg", a = a } end
local function nNum(v)    return { k = "num", v = v } end
local function nVar(v)    return { k = "var", v = v } end
local function nFn(name, ...) return { k = "fn", name = name, args = { ... } } end

function Parser:parseExpr() return self:parseAddSub() end

function Parser:parseAddSub()
  local node = self:parseMulDiv()
  while self:at("op", "+") or self:at("op", "-") do
    local op = self:next().v
    local rhs = self:parseMulDiv()
    node = (op == "+") and nAdd(node, rhs) or nSub(node, rhs)
  end
  return node
end

-- True when the upcoming token can start an atom, i.e. juxtaposition here
-- means multiplication.
function Parser:startsAtom()
  local t = self:peek().t
  if t == "bar" then
    -- Inside |...| the next bar closes the group; it is not a new factor.
    return self.barDepth == 0
  end
  return t == "num" or t == "var" or t == "fn" or t == "const" or t == "lp"
end

function Parser:parseMulDiv()
  local node = self:parseUnary()
  while true do
    if self:at("op", "*") or self:at("op", "/") then
      local op = self:next().v
      local rhs = self:parseUnary()
      node = (op == "*") and nMul(node, rhs) or nDiv(node, rhs)
    elseif self:startsAtom() then
      -- implicit multiplication: 2x, 3(x+1), (x+1)(x-2), 2sqrt(3)
      node = nMul(node, self:parseUnary())
    else
      return node
    end
  end
end

function Parser:parseUnary()
  if self:at("op", "-") then self:next(); return nNeg(self:parseUnary()) end
  if self:at("op", "+") then self:next(); return self:parseUnary() end
  return self:parsePower()
end

function Parser:parsePower()
  local base = self:parseAtom()
  if self:at("op", "^") then
    self:next()
    return nPow(base, self:parseUnary())
  end
  return base
end

function Parser:parseAtom()
  local tok = self:peek()
  if tok.t == "num" then
    self:next(); return nNum(tok.v)
  elseif tok.t == "const" then
    self:next(); return nFn("pi")
  elseif tok.t == "var" then
    self:next(); return nVar(tok.v)
  elseif tok.t == "lp" then
    self:next()
    local e = self:parseExpr()
    self:expect("rp", "a closing ')'")
    return e
  elseif tok.t == "bar" then
    self:next()
    self.barDepth = self.barDepth + 1
    local e = self:parseExpr()
    self.barDepth = self.barDepth - 1
    if not self:at("bar") then fail("syntax", "Missing the closing '|' of an absolute value.") end
    self:next()
    return nFn("abs", e)
  elseif tok.t == "fn" then
    self:next()
    if self:at("lp") then
      self:next()
      local args = { self:parseExpr() }
      while self:at("comma") do self:next(); args[#args + 1] = self:parseExpr() end
      self:expect("rp", "a closing ')'")
      return { k = "fn", name = tok.v, args = args }
    end
    -- no parentheses: bind to the next atom/power, e.g. sqrt x, sqrt 2
    return { k = "fn", name = tok.v, args = { self:parsePower() } }
  elseif tok.t == "op" and tok.v == "-" then
    self:next(); return nNeg(self:parseUnary())
  end
  fail("syntax", "Unexpected end of expression near position " .. tostring(tok.at) .. ".")
end

-- Parses one "statement": either `lhs = rhs` or a bare expression.
local function parseOne(text)
  local toks = tokenize(normalizeInput(text))
  local p = newParser(toks)
  local lhs = p:parseExpr()
  local rhs = nil
  if p:at("eq") then
    p:next()
    rhs = p:parseExpr()
    if p:at("eq") then fail("syntax", "Only one '=' sign is allowed.") end
  end
  if not p:at("end") then
    local tok = p:peek()
    fail("syntax", "Unexpected '" .. tostring(tok.v or "?") .. "' at position " .. tostring(tok.at) .. ".")
  end
  if rhs then return { eq = true, lhs = lhs, rhs = rhs } end
  return { eq = false, lhs = lhs }
end

-- Splits on top-level commas / semicolons / newlines (used by System mode and
-- by Evaluate's "expr, x=2, y=3" form), then parses each piece.
local function splitStatements(text)
  local parts, depth, start = {}, 0, 1
  local s = normalizeInput(text)
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "(" or c == "[" or c == "{" then depth = depth + 1
    elseif c == ")" or c == "]" or c == "}" then depth = depth - 1
    elseif depth == 0 and (c == "," or c == ";" or c == "\n") then
      parts[#parts + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  parts[#parts + 1] = s:sub(start)
  local out = {}
  for _, piece in ipairs(parts) do
    if piece:match("%S") then out[#out + 1] = piece end
  end
  return out
end

-- ----------------------------------------------------------------------------
-- 3. Multivariate polynomials over Q  (sparse: monomial key -> term)
--
--   poly.t[key] = { c = Q coefficient, e = { x = 2, y = 1 } }
-- ----------------------------------------------------------------------------

local P = {}
P.__index = P

local function monKey(e)
  local names = {}
  for name, ex in pairs(e) do
    if ex ~= 0 then names[#names + 1] = name end
  end
  if #names == 0 then return "" end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = name .. "^" .. intStr(e[name]) end
  return table.concat(parts, "*")
end

local function monClean(e)
  local out = {}
  for name, ex in pairs(e) do
    if ex ~= 0 then out[name] = ex end
  end
  return out
end

local function pnew() return setmetatable({ t = {} }, P) end

local function paddTerm(p, c, e)
  if qz(c) then return p end
  e = monClean(e)
  local key = monKey(e)
  local cur = p.t[key]
  if cur then
    local nc = cur.c + c
    if qz(nc) then p.t[key] = nil else cur.c = nc end
  else
    p.t[key] = { c = c, e = e }
  end
  return p
end

local function pconst(qv)
  local p = pnew()
  return paddTerm(p, qv, {})
end

local function pvar(name)
  local p = pnew()
  return paddTerm(p, ONE, { [name] = 1 })
end

local PZERO = pconst(ZERO)
local PONE = pconst(ONE)

local function pcopy(a)
  local p = pnew()
  for key, term in pairs(a.t) do p.t[key] = { c = term.c, e = monClean(term.e) } end
  return p
end

local function piszero(a) return next(a.t) == nil end

function P.__add(a, b)
  local p = pcopy(a)
  for _, term in pairs(b.t) do paddTerm(p, term.c, term.e) end
  return p
end

function P.__unm(a)
  local p = pnew()
  for _, term in pairs(a.t) do paddTerm(p, -term.c, term.e) end
  return p
end

function P.__sub(a, b) return a + (-b) end

function P.__mul(a, b)
  local p = pnew()
  for _, ta in pairs(a.t) do
    for _, tb in pairs(b.t) do
      local e = {}
      for name, ex in pairs(ta.e) do e[name] = ex end
      for name, ex in pairs(tb.e) do e[name] = (e[name] or 0) + ex end
      paddTerm(p, ta.c * tb.c, e)
    end
  end
  return p
end

function P.__eq(a, b)
  for key, term in pairs(a.t) do
    local o = b.t[key]
    if not o or not (o.c == term.c) then return false end
  end
  for key in pairs(b.t) do
    if not a.t[key] then return false end
  end
  return true
end

local function ppow(a, k)
  if k < 0 then fail("internal", "Negative polynomial power.") end
  local r = PONE
  for _ = 1, k do
    r = r * a
    if r.t and next(r.t) then
      local count = 0
      for _ in pairs(r.t) do count = count + 1 end
      if count > 4000 then fail("overflow", "That expression expands to too many terms.") end
    end
  end
  return r
end

local function pvars(a)
  local seen, out = {}, {}
  for _, term in pairs(a.t) do
    for name in pairs(term.e) do
      if not seen[name] then seen[name] = true; out[#out + 1] = name end
    end
  end
  table.sort(out)
  return out
end

local function pisconst(a) return #pvars(a) == 0 end

local function pconstval(a)
  local term = a.t[""]
  return term and term.c or ZERO
end

local function ptotalDeg(e)
  local d = 0
  for _, ex in pairs(e) do d = d + ex end
  return d
end

local function pdegIn(a, v)
  local d = 0
  for _, term in pairs(a.t) do
    local ex = term.e[v] or 0
    if ex > d then d = ex end
  end
  return d
end

-- Ordered term list for display / leading-term selection.
-- Graded order: higher power of mainVar first, then higher total degree,
-- then alphabetically by key so the result is always deterministic.
local function psortedTerms(a, mainVar)
  local list = {}
  for key, term in pairs(a.t) do
    list[#list + 1] = { key = key, c = term.c, e = term.e,
                        mv = mainVar and (term.e[mainVar] or 0) or 0,
                        td = ptotalDeg(term.e) }
  end
  table.sort(list, function(x, y)
    if x.mv ~= y.mv then return x.mv > y.mv end
    if x.td ~= y.td then return x.td > y.td end
    return x.key < y.key
  end)
  return list
end

-- The rational content: gcd of numerators over lcm of denominators, carrying
-- the sign of the leading term so factoring out the content leaves a
-- polynomial with a positive leading coefficient.
local function pcontent(a)
  if piszero(a) then return ZERO end
  local gn, ld = 0, 1
  for _, term in pairs(a.t) do
    gn = igcd(gn, term.c.n)
    ld = ilcm(ld, term.c.d)
  end
  local c = q(gn, ld)
  local lead = psortedTerms(a)[1]
  if lead.c.n < 0 then c = -c end
  return c
end

-- Highest monomial dividing every term, e.g. 6x^3y + 9x^2 -> {x = 2}
local function pmonGCD(a)
  if piszero(a) then return {} end
  local g = nil
  for _, term in pairs(a.t) do
    if g == nil then
      g = {}
      for name, ex in pairs(term.e) do g[name] = ex end
    else
      for name, ex in pairs(g) do
        local other = term.e[name] or 0
        g[name] = (other < ex) and other or ex
      end
    end
    for name, ex in pairs(g) do if ex == 0 then g[name] = nil end end
  end
  return g or {}
end

local function pscale(a, c)
  local p = pnew()
  for _, term in pairs(a.t) do paddTerm(p, term.c * c, term.e) end
  return p
end

local function pmulMon(a, e, c)
  local p = pnew()
  for _, term in pairs(a.t) do
    local ne = {}
    for name, ex in pairs(term.e) do ne[name] = ex end
    for name, ex in pairs(e) do ne[name] = (ne[name] or 0) + ex end
    paddTerm(p, term.c * c, ne)
  end
  return p
end

-- Divide every term by the monomial e (caller must know it divides).
local function pdivMon(a, e)
  local p = pnew()
  for _, term in pairs(a.t) do
    local ne = {}
    for name, ex in pairs(term.e) do ne[name] = ex end
    for name, ex in pairs(e) do
      ne[name] = (ne[name] or 0) - ex
      if ne[name] < 0 then return nil end
    end
    paddTerm(p, term.c, ne)
  end
  return p
end

-- Exact multivariate division; returns nil when b does not divide a.
local function pdivExact(a, b)
  if piszero(b) then return nil end
  if piszero(a) then return PZERO end
  local bt = psortedTerms(b)[1]
  local rem = pcopy(a)
  local out = pnew()
  local guard = 0
  while not piszero(rem) do
    guard = guard + 1
    if guard > 3000 then return nil end
    local rt = psortedTerms(rem)[1]
    local e = {}
    for name, ex in pairs(rt.e) do e[name] = ex end
    for name, ex in pairs(bt.e) do
      e[name] = (e[name] or 0) - ex
      if e[name] < 0 then return nil end
    end
    local c = rt.c / bt.c
    paddTerm(out, c, e)
    rem = rem - pmulMon(b, e, c)
  end
  return out
end

-- ---- univariate helpers (coefficients as a 0-based Q array) ----------------

-- Returns { [0] = a0, [1] = a1, ... } or nil when other variables are present.
local function uniCoeffs(a, v)
  local vs = pvars(a)
  for _, name in ipairs(vs) do
    if name ~= v then return nil end
  end
  local deg = pdegIn(a, v)
  local c = {}
  for i = 0, deg do c[i] = ZERO end
  for _, term in pairs(a.t) do
    c[term.e[v] or 0] = term.c
  end
  c.deg = deg
  return c
end

local function uniPoly(v, c, deg)
  local p = pnew()
  for i = 0, deg do
    if c[i] and not qz(c[i]) then paddTerm(p, c[i], { [v] = i }) end
  end
  return p
end

local function uniTrim(c)
  local d = c.deg or 0
  while d > 0 and (c[d] == nil or qz(c[d])) do d = d - 1 end
  c.deg = d
  return c
end

local function uniCopy(c)
  local o = { deg = c.deg }
  for i = 0, c.deg do o[i] = c[i] end
  return o
end

-- Long division of univariate rational-coefficient polynomials.
local function uniDivMod(a, b)
  local rem = uniCopy(a)
  local dq = a.deg - b.deg
  local out = { deg = dq > 0 and dq or 0 }
  for i = 0, out.deg do out[i] = ZERO end
  if a.deg < b.deg then
    return { deg = 0, [0] = ZERO }, uniTrim(rem)
  end
  for i = a.deg - b.deg, 0, -1 do
    local coef = rem[i + b.deg] / b[b.deg]
    out[i] = coef
    if not qz(coef) then
      for j = 0, b.deg do
        rem[i + j] = rem[i + j] - coef * b[j]
      end
    end
  end
  rem.deg = b.deg > 0 and (b.deg - 1) or 0
  return uniTrim(out), uniTrim(rem)
end

local function uniIsZero(c) return c.deg == 0 and qz(c[0]) end

-- Monic gcd over Q (used to cancel rational functions).
local function uniGCD(a, b)
  local x, y = uniCopy(a), uniCopy(b)
  local guard = 0
  while not uniIsZero(y) do
    guard = guard + 1
    if guard > 200 then return nil end
    local _, r = uniDivMod(x, y)
    x, y = y, r
  end
  if uniIsZero(x) then return x end
  local lead = x[x.deg]
  for i = 0, x.deg do x[i] = x[i] / lead end
  return x
end

local function pevalQ(a, env)
  local total = ZERO
  for _, term in pairs(a.t) do
    local v = term.c
    for name, ex in pairs(term.e) do
      local val = env[name]
      if not val then return nil end
      v = v * qpow(val, ex)
    end
    total = total + v
  end
  return total
end

-- Coefficients of `a` viewed as a polynomial in v; entries are polynomials in
-- the remaining variables. Index 0 .. degree.
local function pcoeffsIn(a, v)
  local deg = pdegIn(a, v)
  local out = {}
  for i = 0, deg do out[i] = pnew() end
  for _, term in pairs(a.t) do
    local ex = term.e[v] or 0
    local e = {}
    for name, x in pairs(term.e) do
      if name ~= v then e[name] = x end
    end
    paddTerm(out[ex], term.c, e)
  end
  out.deg = deg
  return out
end

-- ----------------------------------------------------------------------------
-- 4. Rendering polynomials back to text
--
-- Everything printed here is round-trippable: feeding any printed line back
-- into the parser yields the same polynomial. (tests/run_tests.lua checks it.)
-- ----------------------------------------------------------------------------

local SQRT_CH = "\226\136\154"   -- U+221A
local APPROX  = "\226\137\136"   -- U+2248
local PLUSMIN = "\194\177"       -- U+00B1
local NEQ     = "\226\137\160"   -- U+2260
local ARROW   = "\226\134\146"   -- U+2192

local function varPower(name, ex, disp)
  local shown = (disp and disp[name]) or name
  if ex == 1 then return shown end
  return shown .. "^" .. intStr(ex)
end

local function monStr(e, mainVar, disp)
  local names = {}
  for name in pairs(e) do names[#names + 1] = name end
  table.sort(names, function(x, y)
    if mainVar then
      if x == mainVar and y ~= mainVar then return true end
      if y == mainVar and x ~= mainVar then return false end
    end
    return x < y
  end)
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = varPower(name, e[name], disp) end
  return table.concat(parts, "*")
end

-- Renders one term without its leading sign; returns text plus sign (-1/1).
local function termBody(c, e, mainVar, disp)
  local sign = (c.n < 0) and -1 or 1
  local mag = qabs(c)
  local vars = monStr(e, mainVar, disp)
  if vars == "" then return qstr(mag), sign end
  if mag == ONE then return vars, sign end
  return qstrCoef(mag) .. vars, sign
end

local function pstr(a, mainVar, disp)
  if piszero(a) then return "0" end
  local list = psortedTerms(a, mainVar)
  local out = {}
  for i, term in ipairs(list) do
    local body, sign = termBody(term.c, term.e, mainVar, disp)
    if i == 1 then
      out[#out + 1] = (sign < 0 and "-" or "") .. body
    else
      out[#out + 1] = (sign < 0 and " - " or " + ") .. body
    end
  end
  return table.concat(out)
end

-- Parenthesised when the polynomial is a sum or a bare negative, so it can be
-- glued into a product safely.
local function pstrP(a, mainVar, disp)
  local s = pstr(a, mainVar, disp)
  local single = true
  local count = 0
  for _ in pairs(a.t) do count = count + 1 end
  if count > 1 then single = false end
  if single and s:sub(1, 1) ~= "-" then return s end
  if single and count == 1 then return s end -- "-3x" is fine inside a product
  return "(" .. s .. ")"
end

-- ----------------------------------------------------------------------------
-- 5. Rational functions  num / den  (den never zero, kept in lowest terms)
-- ----------------------------------------------------------------------------

local R = {}
R.__index = R

local function rmake(num, den)
  if piszero(den) then fail("divzero", "This expression divides by zero.") end
  if piszero(num) then return setmetatable({ n = PZERO, d = PONE }, R) end

  -- cancel the numeric content and the common monomial
  local cn, cd = pcontent(num), pcontent(den)
  local scale = cn / cd
  local n2 = pscale(num, ONE / cn)
  local d2 = pscale(den, ONE / cd)
  local mg = {}
  local mn, md = pmonGCD(n2), pmonGCD(d2)
  for name, ex in pairs(mn) do
    local o = md[name] or 0
    if o > 0 then mg[name] = (o < ex) and o or ex end
  end
  if next(mg) then
    n2 = pdivMon(n2, mg) or n2
    d2 = pdivMon(d2, mg) or d2
  end

  -- cancel a common polynomial factor when both sides live in one variable
  local vn, vd = pvars(n2), pvars(d2)
  if #vn <= 1 and #vd <= 1 and (#vn == 0 or #vd == 0 or vn[1] == vd[1]) then
    local v = vn[1] or vd[1]
    if v then
      local cnum, cden = uniCoeffs(n2, v), uniCoeffs(d2, v)
      if cnum and cden and cden.deg > 0 then
        local g = uniGCD(cnum, cden)
        if g and g.deg > 0 then
          local qn = uniDivMod(cnum, g)
          local qd = uniDivMod(cden, g)
          n2 = uniPoly(v, qn, qn.deg)
          d2 = uniPoly(v, qd, qd.deg)
        end
      end
    end
  end

  -- keep the denominator's leading coefficient positive
  local dc = pcontent(d2)
  if dc.n < 0 then
    n2, d2 = -n2, -d2
    scale = -scale
  end
  n2 = pscale(n2, scale)
  return setmetatable({ n = n2, d = d2 }, R)
end

local function rconst(qv) return rmake(pconst(qv), PONE) end
local function rvar(name) return rmake(pvar(name), PONE) end

function R.__add(a, b) return rmake(a.n * b.d + b.n * a.d, a.d * b.d) end
function R.__sub(a, b) return rmake(a.n * b.d - b.n * a.d, a.d * b.d) end
function R.__mul(a, b) return rmake(a.n * b.n, a.d * b.d) end
function R.__div(a, b)
  if piszero(b.n) then fail("divzero", "This expression divides by zero.") end
  return rmake(a.n * b.d, a.d * b.n)
end
function R.__unm(a) return rmake(-a.n, a.d) end

local function rpow(a, k)
  if k >= 0 then return rmake(ppow(a.n, k), ppow(a.d, k)) end
  if piszero(a.n) then fail("divzero", "This expression divides by zero.") end
  return rmake(ppow(a.d, -k), ppow(a.n, -k))
end

-- A denominator needs brackets unless it is a single symbol or power:
-- v/(pi*r^2) must not print as v/pi*r^2.
local function denWrap(s)
  if s:find("[%*%+%-/ ]") then return "(" .. s .. ")" end
  return s
end

local function rstr(a, mainVar, disp)
  if pisconst(a.d) then
    local c = pconstval(a.d)
    local num = (c == ONE) and a.n or pscale(a.n, ONE / c)
    -- Prefer one fraction over fractional coefficients:
    -- (5f - 160)/9 reads better than (5/9)f - 160/9.
    local den = 1
    for _, term in pairs(num.t) do den = ilcm(den, term.c.d) end
    if den > 1 then
      return "(" .. pstr(pscale(num, q(den)), mainVar, disp) .. ")/" .. intStr(den)
    end
    return pstr(num, mainVar, disp)
  end
  return pstrP(a.n, mainVar, disp) .. "/" .. denWrap(pstr(a.d, mainVar, disp))
end

-- ----------------------------------------------------------------------------
-- 6. AST -> rational function
--
-- Anything that is not a rational function of the variables is abstracted into
-- an "atom": a private symbol (&1, &2, ...) that carries an algebraic rule.
--   sqrt(u)  ->  t   with   t^2 = u      (t >= 0)
--   abs(u)   ->  t   with   t^2 = u^2    (t >= 0)
--   pi       ->  a symbol with a known decimal value
-- Solving then eliminates the atoms by squaring, and every candidate answer is
-- checked numerically against the ORIGINAL input, which removes the extraneous
-- roots squaring can introduce.
-- ----------------------------------------------------------------------------

local function newCtx()
  return { atoms = {}, order = {}, byKey = {}, n = 0 }
end

local function addAtom(ctx, kind, key, disp, rule, numval)
  local existing = ctx.byKey[key]
  if existing then return existing end
  ctx.n = ctx.n + 1
  local name = "&" .. intStr(ctx.n)
  ctx.atoms[name] = { kind = kind, disp = disp, rule = rule, numval = numval, name = name }
  ctx.byKey[key] = name
  ctx.order[#ctx.order + 1] = name
  return name
end

local astToR

local function constOf(r)
  if pisconst(r.n) and pisconst(r.d) then
    return pconstval(r.n) / pconstval(r.d)
  end
  return nil
end

-- exact square root of a rational, or nil
local function qsqrt(x)
  if x.n < 0 then return nil end
  local rn, rd = sqrt(x.n), sqrt(x.d)
  local fn, fd = floor(rn + 0.5), floor(rd + 0.5)
  if fn * fn == x.n and fd * fd == x.d then return q(fn, fd) end
  return nil
end

function astToR(node, ctx)
  local k = node.k
  if k == "num" then return rconst(node.v) end
  if k == "var" then return rvar(node.v) end
  if k == "add" then return astToR(node.a, ctx) + astToR(node.b, ctx) end
  if k == "sub" then return astToR(node.a, ctx) - astToR(node.b, ctx) end
  if k == "mul" then return astToR(node.a, ctx) * astToR(node.b, ctx) end
  if k == "div" then return astToR(node.a, ctx) / astToR(node.b, ctx) end
  if k == "neg" then return -astToR(node.a, ctx) end
  if k == "pow" then
    local base = astToR(node.a, ctx)
    local ex = astToR(node.b, ctx)
    local c = constOf(ex)
    if not c then
      fail("unsupported", "A variable exponent needs the CAS, not the step engine.")
    end
    if qisint(c) then
      if abs(c.n) > 40 then fail("overflow", "Exponents above 40 are too big to expand.") end
      return rpow(base, c.n)
    end
    if c == q(1, 2) then
      return astToR({ k = "fn", name = "sqrt", args = { node.a } }, ctx)
    end
    fail("unsupported", "Fractional exponents other than 1/2 need the CAS.")
  end
  if k == "fn" then
    local name = node.name
    if name == "pi" then
      local an = addAtom(ctx, "pi", "pi", "pi", nil, math.pi)
      return rvar(an)
    end
    if not (node.args and node.args[1]) then
      fail("syntax", name .. "() needs something inside the brackets.")
    end
    local argR = astToR(node.args[1], ctx)
    if name == "sqrt" then
      local c = constOf(argR)
      if c then
        if c.n < 0 then fail("unsupported", "The square root of a negative number needs the CAS.") end
        local e = qsqrt(c)
        if e then return rconst(e) end
      end
      local key = "sqrt:" .. rstr(argR)
      local an = addAtom(ctx, "sqrt", key, SQRT_CH .. "(" .. rstr(argR) .. ")",
                         { type = "sq", value = argR })
      return rvar(an)
    elseif name == "abs" then
      local c = constOf(argR)
      if c then return rconst(qabs(c)) end
      local key = "abs:" .. rstr(argR)
      local an = addAtom(ctx, "abs", key, "|" .. rstr(argR) .. "|",
                         { type = "sq", value = argR * argR })
      return rvar(an)
    end
    fail("unsupported", name .. "() is outside the step-by-step engine.")
  end
  fail("internal", "Unknown expression node.")
end

local function atomDisp(ctx)
  local disp = {}
  for name, a in pairs(ctx.atoms) do disp[name] = a.disp end
  return disp
end

local function pevalNum(a, env)
  local total = 0
  for _, term in pairs(a.t) do
    local v = qnum(term.c)
    for name, ex in pairs(term.e) do
      local val = env[name]
      if val == nil then return nil end
      v = v * (val ^ ex)
    end
    total = total + v
  end
  return total
end

-- ----------------------------------------------------------------------------
-- 7. Numeric evaluation straight from the AST (used to verify every answer)
-- ----------------------------------------------------------------------------

local function astNum(node, env)
  local k = node.k
  if k == "num" then return qnum(node.v) end
  if k == "var" then
    local v = env[node.v]
    if v == nil then return nil end
    return v
  end
  if k == "neg" then
    local a = astNum(node.a, env); if a == nil then return nil end; return -a
  end
  if k == "add" or k == "sub" or k == "mul" or k == "div" or k == "pow" then
    local a = astNum(node.a, env); if a == nil then return nil end
    local b = astNum(node.b, env); if b == nil then return nil end
    if k == "add" then return a + b end
    if k == "sub" then return a - b end
    if k == "mul" then return a * b end
    if k == "div" then
      if b == 0 then return nil end
      return a / b
    end
    if a < 0 and b ~= floor(b) then return nil end
    if a == 0 and b < 0 then return nil end
    local ok, res = pcall(function() return a ^ b end)
    if not ok then return nil end
    return res
  end
  if k == "fn" then
    local name = node.name
    if name == "pi" then return math.pi end
    local arg = node.args and node.args[1]
    if arg == nil then return nil end
    local a = astNum(arg, env)
    if a == nil then return nil end
    if name == "sqrt" then
      if a < 0 then return nil end
      return sqrt(a)
    elseif name == "abs" then return abs(a)
    elseif name == "ln" then
      if a <= 0 then return nil end
      return math.log(a)
    elseif name == "log" then
      if a <= 0 then return nil end
      return math.log(a) / math.log(10)
    elseif name == "exp" then return math.exp(a)
    elseif name == "sin" then return math.sin(a)
    elseif name == "cos" then return math.cos(a)
    elseif name == "tan" then
      local c = math.cos(a)
      if abs(c) < 1e-13 then return nil end
      return math.sin(a) / c
    elseif name == "asin" then
      if a < -1 or a > 1 then return nil end
      return math.asin(a)
    elseif name == "acos" then
      if a < -1 or a > 1 then return nil end
      return math.acos(a)
    elseif name == "atan" then return math.atan(a)
    end
    return nil
  end
  return nil
end

local function astVars(node, out)
  out = out or {}
  if node.k == "var" then
    out[node.v] = true
  elseif node.k == "fn" then
    for _, a in ipairs(node.args) do astVars(a, out) end
  elseif node.a then
    astVars(node.a, out)
    if node.b then astVars(node.b, out) end
  end
  return out
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function astFuncs(node, out)
  out = out or {}
  if node.k == "fn" then
    out[node.name] = true
    for _, a in ipairs(node.args) do astFuncs(a, out) end
  elseif node.a then
    astFuncs(node.a, out)
    if node.b then astFuncs(node.b, out) end
  end
  return out
end

-- ----------------------------------------------------------------------------
-- 8. Factoring over the rationals
--
-- Result shape: { const = Q, factors = { { p = Poly, k = multiplicity }, ... } }
-- Every factorisation is re-expanded and compared with the input before it is
-- returned, so a wrong factorisation can never reach the screen.
-- ----------------------------------------------------------------------------

local ENG = {}

local function note(res, text)
  if res.notes then
    for _, t in ipairs(res.notes) do
      if t == text then return end
    end
    res.notes[#res.notes + 1] = text
  end
end

local function addFactor(res, p, k)
  if pisconst(p) then
    res.const = res.const * qpow(pconstval(p), k)
    return
  end
  for _, f in ipairs(res.factors) do
    if f.p == p then f.k = f.k + k; return end
  end
  res.factors[#res.factors + 1] = { p = p, k = k }
end

-- Horner evaluation of an integer/rational coefficient list at a rational.
local function uniEvalQ(c, x)
  local acc = ZERO
  for i = c.deg, 0, -1 do
    acc = acc * x + c[i]
  end
  return acc
end

-- Rational Root Theorem: every rational root n/d has n | a0 and d | an.
function ENG.rationalRoots(c)
  if c.deg < 1 then return {} end
  local a0, an = c[0], c[c.deg]
  if qz(a0) then return { ZERO } end
  local ps, qs = divisors(a0.n), divisors(an.n)
  if not ps or not qs then return {} end
  local seen, out = {}, {}
  for _, pp in ipairs(ps) do
    for _, qq in ipairs(qs) do
      for _, sgn in ipairs({ 1, -1 }) do
        local r = q(sgn * pp, qq)
        local key = qstr(r)
        if not seen[key] then
          seen[key] = true
          if qz(uniEvalQ(c, r)) then out[#out + 1] = r end
        end
      end
    end
  end
  table.sort(out, function(x, y) return x < y end)
  return out
end

-- Square root of a polynomial, or nil when it is not a perfect square.
function ENG.polySqrt(p)
  if piszero(p) then return PZERO end
  local lead = psortedTerms(p)[1]
  local rc = qsqrt(lead.c)
  if not rc then return nil end
  local he = {}
  for name, ex in pairs(lead.e) do
    if ex % 2 ~= 0 then return nil end
    he[name] = ex / 2
  end
  local s = paddTerm(pnew(), rc, he)
  local guard = 0
  while true do
    guard = guard + 1
    if guard > 60 then return nil end
    local r = p - s * s
    if piszero(r) then return s end
    local rt = psortedTerms(r)[1]
    local st = psortedTerms(s)[1]
    local e = {}
    for name, ex in pairs(rt.e) do e[name] = ex end
    for name, ex in pairs(st.e) do
      e[name] = (e[name] or 0) - ex
      if e[name] < 0 then return nil end
    end
    local coef = rt.c / (TWO * st.c)
    local add = paddTerm(pnew(), coef, e)
    local s2 = s + add
    if s2 == s then return nil end
    s = s2
  end
end

-- a^n +/- b^n patterns for a two-term polynomial (difference of squares,
-- sum/difference of cubes, and their nested forms).
function ENG.factorBinomial(p, res)
  local list = psortedTerms(p)
  if #list ~= 2 then return false end
  local t1, t2 = list[1], list[2]

  -- Difference of squares: A^2 - B^2 = (A - B)(A + B)
  local sq1 = ENG.polySqrt(paddTerm(pnew(), t1.c, t1.e))
  local sq2 = ENG.polySqrt(paddTerm(pnew(), -t2.c, t2.e))
  if sq1 and sq2 and t2.c.n < 0 then
    note(res, "Difference of squares:  a^2 - b^2 = (a - b)(a + b)")
    ENG.factorInto(sq1 - sq2, res)
    ENG.factorInto(sq1 + sq2, res)
    return true
  end

  -- Sum / difference of cubes
  local function cubeRoot(c, e)
    local rc
    local function icbrt(n)
      local s = n < 0 and -1 or 1
      local r = floor(abs(n) ^ (1 / 3) + 0.5)
      if r * r * r == abs(n) then return s * r end
      return nil
    end
    local rn, rd = icbrt(c.n), icbrt(c.d)
    if not rn or not rd then return nil end
    rc = q(rn, rd)
    local he = {}
    for name, ex in pairs(e) do
      if ex % 3 ~= 0 then return nil end
      he[name] = ex / 3
    end
    return paddTerm(pnew(), rc, he)
  end
  local c1 = cubeRoot(t1.c, t1.e)
  local c2 = cubeRoot(t2.c, t2.e)
  if c1 and c2 then
    -- a^3 + b^3 = (a + b)(a^2 - ab + b^2)   (b carries its own sign)
    note(res, "Sum/difference of cubes:  a^3 " .. PLUSMIN .. " b^3 = (a " .. PLUSMIN ..
              " b)(a^2 " .. "\226\136\147" .. " ab + b^2)")
    ENG.factorInto(c1 + c2, res)
    ENG.factorInto(c1 * c1 - c1 * c2 + c2 * c2, res)
    return true
  end
  return false
end

-- Four-term grouping: try each pairing, pull the GCF out of both halves and
-- look for a shared binomial.
function ENG.factorGrouping(p, res)
  local list = psortedTerms(p)
  if #list ~= 4 then return false end
  local pairings = { { 1, 2, 3, 4 }, { 1, 3, 2, 4 }, { 1, 4, 2, 3 } }
  for _, order in ipairs(pairings) do
    local function half(i, j)
      local h = pnew()
      paddTerm(h, list[i].c, list[i].e)
      paddTerm(h, list[j].c, list[j].e)
      local c = pcontent(h)
      local prim = pscale(h, ONE / c)
      local mg = pmonGCD(prim)
      local gp = paddTerm(pnew(), c, mg)
      if next(mg) then prim = pdivMon(prim, mg) end
      return gp, prim
    end
    local g1, r1 = half(order[1], order[2])
    local g2, r2 = half(order[3], order[4])
    if r1 == r2 then
      note(res, "Factor by grouping: pull the GCF out of each pair of terms")
      ENG.factorInto(r1, res); ENG.factorInto(g1 + g2, res); return true
    elseif r1 == -r2 then
      note(res, "Factor by grouping: pull the GCF out of each pair of terms")
      ENG.factorInto(r1, res); ENG.factorInto(g1 - g2, res); return true
    end
  end
  return false
end

-- A quartic with no rational root can still split into two quadratics over Z.
function ENG.factorQuartic(c, v, res)
  local A, B, C, D, E = c[4].n, c[3].n, c[2].n, c[1].n, c[0].n
  local da, de = divisors(A), divisors(E)
  if not da or not de then return false end
  local m = 0
  for _, x in ipairs({ A, B, C, D, E }) do if abs(x) > m then m = abs(x) end end
  local bound = m + 2
  if bound > 200 then bound = 200 end
  local budget = 400000
  for _, a in ipairs(da) do
    local d = A / a
    for _, cc0 in ipairs(de) do
      for _, sgn in ipairs({ 1, -1 }) do
        local cc = sgn * cc0
        local f = E / cc
        for b = -bound, bound do
          budget = budget - 1
          if budget <= 0 then return false end
          local en = B - b * d
          if en % a == 0 then
            local e = en / a
            if a * f + b * e + cc * d == C and b * f + cc * e == D then
              local f1 = uniPoly(v, { [0] = q(cc), [1] = q(b), [2] = q(a) }, 2)
              local f2 = uniPoly(v, { [0] = q(f), [1] = q(e), [2] = q(d) }, 2)
              if not (pdegIn(f1, v) < 1 or pdegIn(f2, v) < 1) then
                note(res, "No rational roots, but it splits into two quadratics over the integers")
                ENG.factorInto(f1, res); ENG.factorInto(f2, res); return true
              end
            end
          end
        end
      end
    end
  end
  return false
end

-- Homogeneous in exactly two variables: set the second to 1, factor the
-- resulting univariate polynomial, then put the powers back.
function ENG.factorHomogeneous(p, vars, res)
  if #vars ~= 2 then return false end
  local vx, vy = vars[1], vars[2]
  local deg = nil
  for _, term in pairs(p.t) do
    local d = ptotalDeg(term.e)
    if deg == nil then deg = d elseif deg ~= d then return false end
  end
  if not deg or deg < 2 then return false end
  local flat = pnew()
  for _, term in pairs(p.t) do
    paddTerm(flat, term.c, { [vx] = term.e[vx] or 0 })
  end
  local sub = ENG.factorPoly(flat)
  if #sub.factors == 0 then return false end
  note(res, "Every term has the same total degree, so set " .. vy ..
            " = 1, factor in " .. vx .. ", then restore the powers of " .. vy)
  local total = 0
  for _, f in ipairs(sub.factors) do total = total + pdegIn(f.p, vx) * f.k end
  if total ~= deg or (#sub.factors == 1 and sub.factors[1].k == 1) then return false end
  res.const = res.const * sub.const
  for _, f in ipairs(sub.factors) do
    local k = pdegIn(f.p, vx)
    local hom = pnew()
    for _, term in pairs(f.p.t) do
      local ex = term.e[vx] or 0
      paddTerm(hom, term.c, { [vx] = ex, [vy] = k - ex })
    end
    addFactor(res, hom, f.k)
  end
  return true
end

-- Quadratic in one variable whose other-variable coefficients make the
-- discriminant a perfect square: x^2 + (y+1)x + y  ->  (x + 1)(x + y)
function ENG.factorQuadInVar(p, vars, res)
  for _, v in ipairs(vars) do
    if pdegIn(p, v) == 2 then
      local co = pcoeffsIn(p, v)
      if pisconst(co[2]) then
        local A = pconstval(co[2])
        local B, C = co[1], co[0]
        local disc = B * B - pconst(q(4) * A) * C
        local S = ENG.polySqrt(disc)
        if S then
          local twoA = pconst(TWO * A)
          local f1 = twoA * pvar(v) + B - S
          local f2 = twoA * pvar(v) + B + S
          if not piszero(f1) and not piszero(f2) then
            local c1, c2 = pcontent(f1), pcontent(f2)
            local p1, p2 = pscale(f1, ONE / c1), pscale(f2, ONE / c2)
            local scale = c1 * c2 / (q(4) * A)
            if p1 * p2 * pconst(scale) == p and pdegIn(p1, v) >= 1 and pdegIn(p2, v) >= 1 then
              note(res, "Quadratic in " .. v .. " whose discriminant is a perfect square")
              res.const = res.const * scale
              ENG.factorInto(p1, res)
              ENG.factorInto(p2, res)
              return true
            end
          end
        end
      end
    end
  end
  return false
end

-- Core recursion: `p` is primitive (integer coefficients, gcd 1, positive
-- leading coefficient) with no monomial common factor.
function ENG.factorInto(p, res)
  if pisconst(p) then
    res.const = res.const * pconstval(p)
    return
  end
  local c = pcontent(p)
  if not (c == ONE) then
    res.const = res.const * c
    p = pscale(p, ONE / c)
  end
  local mg = pmonGCD(p)
  if next(mg) then
    p = pdivMon(p, mg)
    for name, ex in pairs(mg) do addFactor(res, pvar(name), ex) end
    if pisconst(p) then
      res.const = res.const * pconstval(p)
      return
    end
  end

  local vars = pvars(p)
  local totalDeg = 0
  for _, term in pairs(p.t) do
    local d = ptotalDeg(term.e)
    if d > totalDeg then totalDeg = d end
  end
  if totalDeg <= 1 then addFactor(res, p, 1); return end

  if #vars == 1 then
    local v = vars[1]
    local c0 = uniCoeffs(p, v)

    -- 1. peel off every rational root
    local roots = ENG.rationalRoots(c0)
    if #roots > 0 then
      local r = roots[1]
      local lin = uniPoly(v, { [0] = -q(r.n), [1] = q(r.d) }, 1)
      local qq = pdivExact(p, lin)
      if qq then
        note(res, "Factor Theorem: " .. v .. " = " .. qstr(r) .. " is a root, so " ..
                  pstr(lin, v) .. " is a factor (divide it out)")
        addFactor(res, lin, 1)
        ENG.factorInto(qq, res)
        return
      end
    end

    -- 2. polynomial in x^k  ->  factor in u, substitute back
    local g = 0
    for _, term in pairs(p.t) do g = igcd(g, term.e[v] or 0) end
    if g >= 2 then
      local flat = pnew()
      for _, term in pairs(p.t) do paddTerm(flat, term.c, { [v] = (term.e[v] or 0) / g }) end
      local sub = ENG.factorPoly(flat)
      local nontrivial = #sub.factors > 1 or (#sub.factors == 1 and sub.factors[1].k > 1)
      if nontrivial then
        note(res, "Only powers of " .. v .. "^" .. intStr(g) .. " appear, so substitute u = " ..
                  v .. "^" .. intStr(g) .. ", factor, then substitute back")
        res.const = res.const * sub.const
        for _, f in ipairs(sub.factors) do
          local back = pnew()
          for _, term in pairs(f.p.t) do paddTerm(back, term.c, { [v] = (term.e[v] or 0) * g }) end
          ENG.factorInto(back, res)
          for _ = 2, f.k do ENG.factorInto(back, res) end
        end
        return
      end
    end

    -- 3. two-term patterns, then the quartic split
    if ENG.factorBinomial(p, res) then return end
    if c0.deg == 4 and ENG.factorQuartic(c0, v, res) then return end
    addFactor(res, p, 1)
    return
  end

  if ENG.factorBinomial(p, res) then return end
  if ENG.factorHomogeneous(p, vars, res) then return end
  if ENG.factorGrouping(p, res) then return end
  if ENG.factorQuadInVar(p, vars, res) then return end
  addFactor(res, p, 1)
end

function ENG.factorPoly(p)
  local res = { const = ONE, factors = {}, notes = {} }
  if piszero(p) then
    res.const = ZERO
    return res
  end
  local ok, err = pcall(ENG.factorInto, p, res)
  if not ok then
    res = { const = ONE, factors = { { p = p, k = 1 } }, notes = {} }
    if type(err) ~= "table" then error(err, 0) end
  end

  -- self-check: multiply everything back out
  local prod = pconst(res.const)
  for _, f in ipairs(res.factors) do prod = prod * ppow(f.p, f.k) end
  if not (prod == p) then
    res = { const = ONE, factors = { { p = p, k = 1 } }, notes = {} }
  end

  table.sort(res.factors, function(a, b)
    local da, db = 0, 0
    for _, t in pairs(a.p.t) do local d = ptotalDeg(t.e); if d > da then da = d end end
    for _, t in pairs(b.p.t) do local d = ptotalDeg(t.e); if d > db then db = d end end
    local na, nb = 0, 0
    for _ in pairs(a.p.t) do na = na + 1 end
    for _ in pairs(b.p.t) do nb = nb + 1 end
    if na ~= nb then return na < nb end
    if da ~= db then return da < db end
    return pstr(a.p) < pstr(b.p)
  end)
  return res
end

function ENG.factorStr(res, mainVar, disp)
  if #res.factors == 0 then return qstr(res.const) end
  -- a single irreducible factor prints bare, without decorative parentheses
  if #res.factors == 1 and res.factors[1].k == 1 and res.const == ONE then
    return pstr(res.factors[1].p, mainVar, disp)
  end
  local out = {}
  if res.const == MINUS_ONE then
    out[#out + 1] = "-"
  elseif not (res.const == ONE) then
    out[#out + 1] = qstrCoef(res.const)
  end
  for _, f in ipairs(res.factors) do
    local body = pstrP(f.p, mainVar, disp)
    local count = 0
    for _ in pairs(f.p.t) do count = count + 1 end
    if f.k > 1 then
      if count > 1 or body:sub(1, 1) == "(" then
        if body:sub(1, 1) ~= "(" then body = "(" .. body .. ")" end
      else
        body = "(" .. body .. ")"
      end
      body = body .. "^" .. intStr(f.k)
    end
    out[#out + 1] = body
  end
  return table.concat(out)
end

function ENG.isFactored(res)
  if #res.factors > 1 then return true end
  if #res.factors == 1 and res.factors[1].k > 1 then return true end
  return false
end

-- ----------------------------------------------------------------------------
-- 9. Answers: exact surds, complex numbers, numeric roots
-- ----------------------------------------------------------------------------

-- Renders  a + b*sqrt(r)*suffix  over a common denominator, fully reduced.
function ENG.mixedStr(a, b, r, suffix)
  suffix = suffix or ""
  if qz(b) then return qstr(a) end
  local D = ilcm(a.d, b.d)
  local A = a.n * (D / a.d)
  local B = b.n * (D / b.d)
  local g = igcd(igcd(A, B), D)
  if g > 1 then A, B, D = A / g, B / g, D / g end

  local radical = (r == 1) and "" or (SQRT_CH .. intStr(r))
  local core = suffix .. radical
  local mag = abs(B)
  local term = ((mag == 1 and core ~= "") and "" or intStr(mag)) .. core
  local numer
  if A == 0 then
    numer = (B < 0 and "-" or "") .. term
  else
    numer = intStr(A) .. (B < 0 and " - " or " + ") .. term
  end
  if D == 1 then return numer end
  if A == 0 and B > 0 then return term .. "/" .. intStr(D) end
  return "(" .. numer .. ")/" .. intStr(D)
end

-- Root records carry both an exact rendering and a decimal, plus the numeric
-- value used for checking.
function ENG.rootRational(x, mult)
  return { kind = "real", exact = qstr(x), num = qnum(x), q = x, mult = mult or 1 }
end

function ENG.rootSurd(a, b, r, mult)
  local val = qnum(a) + qnum(b) * sqrt(r)
  return { kind = "real", exact = ENG.mixedStr(a, b, r), num = val, mult = mult or 1 }
end

function ENG.rootComplex(a, b, r, mult)
  return {
    kind = "complex",
    exact = ENG.mixedStr(a, b, r, "i"),
    re = qnum(a), im = qnum(b) * sqrt(r),
    mult = mult or 1,
  }
end

function ENG.rootNumeric(x, mult)
  return { kind = "real", exact = decStr(x, 8), num = x, approxOnly = true, mult = mult or 1 }
end

-- ---- complex arithmetic + Durand-Kerner, for polynomials with no exact form -

local CX = {}
local function cx(re, im) return { re = re, im = im or 0 } end
function CX.add(a, b) return cx(a.re + b.re, a.im + b.im) end
function CX.sub(a, b) return cx(a.re - b.re, a.im - b.im) end
function CX.mul(a, b) return cx(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) end
function CX.div(a, b)
  local d = b.re * b.re + b.im * b.im
  if d == 0 then return cx(0, 0) end
  return cx((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
end
function CX.abs(a) return sqrt(a.re * a.re + a.im * a.im) end

-- Evaluates a polynomial (0-based number array) at a complex point.
function CX.eval(c, deg, z)
  local acc = cx(0, 0)
  for i = deg, 0, -1 do
    acc = CX.add(CX.mul(acc, z), cx(c[i], 0))
  end
  return acc
end

-- All roots of a real-coefficient polynomial, to full double precision.
function ENG.numericRoots(qc)
  local deg = qc.deg
  if deg < 1 then return {} end
  local c = {}
  for i = 0, deg do c[i] = qnum(qc[i]) end
  local lead = c[deg]
  for i = 0, deg do c[i] = c[i] / lead end

  local roots = {}
  local seed = cx(0.4, 0.9)
  local cur = cx(1, 0)
  for i = 1, deg do
    roots[i] = cur
    cur = CX.mul(cur, seed)
  end
  for _ = 1, 500 do
    local moved = 0
    for i = 1, deg do
      local num = CX.eval(c, deg, roots[i])
      local den = cx(1, 0)
      for j = 1, deg do
        if j ~= i then den = CX.mul(den, CX.sub(roots[i], roots[j])) end
      end
      if CX.abs(den) < 1e-300 then den = cx(1e-300, 0) end
      local delta = CX.div(num, den)
      roots[i] = CX.sub(roots[i], delta)
      moved = moved + CX.abs(delta)
    end
    if moved < 1e-15 then break end
  end

  -- Newton polish, then snap near-real roots onto the real axis.
  local out = {}
  for i = 1, deg do
    local z = roots[i]
    for _ = 1, 40 do
      local f = CX.eval(c, deg, z)
      local d = cx(0, 0)
      for k = deg, 1, -1 do
        d = CX.add(CX.mul(d, z), cx(c[k] * k, 0))
      end
      if CX.abs(d) < 1e-280 then break end
      local nz = CX.sub(z, CX.div(f, d))
      if CX.abs(CX.sub(nz, z)) < 1e-16 then z = nz; break end
      z = nz
    end
    if abs(z.im) < 1e-9 * (1 + abs(z.re)) then z = cx(z.re, 0) end
    out[#out + 1] = z
  end
  table.sort(out, function(a, b)
    if a.im == 0 and b.im ~= 0 then return true end
    if b.im == 0 and a.im ~= 0 then return false end
    if abs(a.re - b.re) > 1e-12 then return a.re < b.re end
    return a.im < b.im
  end)
  return out
end

-- ----------------------------------------------------------------------------
-- 10. Step recorder
-- ----------------------------------------------------------------------------

local function newSteps()
  return { list = {}, n = 0 }
end

-- kind: "given" | "work" | "answer" | "check" | "note" | "warn" | "head"
local function addStep(S, kind, title, body, note)
  S.n = S.n + 1
  S.list[S.n] = { kind = kind, title = title, body = body, note = note }
  return S.list[S.n]
end

-- Exact rational evaluation of an AST (nil when the value is irrational).
local function astQ(node, env)
  local k = node.k
  if k == "num" then return node.v end
  if k == "var" then return env[node.v] end
  if k == "neg" then
    local a = astQ(node.a, env); if not a then return nil end; return -a
  end
  if k == "add" or k == "sub" or k == "mul" or k == "div" or k == "pow" then
    local a = astQ(node.a, env); if not a then return nil end
    local b = astQ(node.b, env); if not b then return nil end
    local ok, res = pcall(function()
      if k == "add" then return a + b end
      if k == "sub" then return a - b end
      if k == "mul" then return a * b end
      if k == "div" then
        if qz(b) then return nil end
        return a / b
      end
      if not qisint(b) or abs(b.n) > 40 then return nil end
      return qpow(a, b.n)
    end)
    if not ok then return nil end
    return res
  end
  if k == "fn" then
    local arg = node.args and node.args[1]
    if not arg then return nil end   -- pi has no exact rational value
    local a = astQ(arg, env)
    if not a then return nil end
    if node.name == "abs" then return qabs(a) end
    if node.name == "sqrt" then return qsqrt(a) end
    return nil
  end
  return nil
end

-- ----------------------------------------------------------------------------
-- 11. Solving
-- ----------------------------------------------------------------------------

-- sqrt of a non-negative rational as  coefficient * sqrt(radicand)
function ENG.sqrtQ(x)
  local inside = checkInt(x.n * x.d, "A discriminant")
  local k, m = simplifySurd(inside)
  return q(k, x.d), m
end

-- Exact roots of a x^2 + b x + c = 0.
function ENG.quadraticRoots(a, b, c)
  local disc = b * b - q(4) * a * c
  local twoA = TWO * a
  if qz(disc) then
    return { ENG.rootRational(-b / twoA, 2) }, disc
  end
  local exactSqrt = (disc.n > 0) and qsqrt(disc) or nil
  if exactSqrt then
    local r1 = (-b + exactSqrt) / twoA
    local r2 = (-b - exactSqrt) / twoA
    if r2 < r1 then r1, r2 = r2, r1 end
    return { ENG.rootRational(r1), ENG.rootRational(r2) }, disc
  end
  if disc.n > 0 then
    local coef, rad = ENG.sqrtQ(disc)
    local base = -b / twoA
    local spread = coef / twoA
    local lo = ENG.rootSurd(base, -qabs(spread), rad)
    local hi = ENG.rootSurd(base, qabs(spread), rad)
    return { lo, hi }, disc
  end
  local coef, rad = ENG.sqrtQ(-disc)
  local base = -b / twoA
  local spread = qabs(coef / twoA)
  return { ENG.rootComplex(base, -spread, rad), ENG.rootComplex(base, spread, rad) }, disc
end

local DEGREE_NAME = {
  [1] = "linear", [2] = "quadratic", [3] = "cubic", [4] = "quartic", [5] = "quintic",
}

function ENG.degreeName(n)
  return DEGREE_NAME[n] or ("degree " .. intStr(n))
end

-- Narrates ax^2 + bx + c = 0 given that it factors, returning the two numbers
-- used by the ac-method (or nil when the factorisation is not of that shape).
function ENG.acNumbers(fac, a, b, c, v)
  local lins = {}
  for _, f in ipairs(fac.factors) do
    if pdegIn(f.p, v) == 1 then
      local co = uniCoeffs(f.p, v)
      if not co then return nil end
      for _ = 1, f.k do lins[#lins + 1] = { p = co[1], qq = co[0] } end
    else
      return nil
    end
  end
  if #lins ~= 2 then return nil end
  local k = fac.const
  -- (k*p1 x + k*q1)(p2 x + q2): distribute the constant onto the first factor
  local m = lins[1].p * lins[2].qq * k
  local n = lins[2].p * lins[1].qq * k
  if m + n == b and m * n == a * c then return m, n end
  m, n = lins[1].p * lins[2].qq, lins[2].p * lins[1].qq
  local kk = k
  if (m + n) * kk == b and m * n * kk * kk == a * c then return m * kk, n * kk end
  return nil
end

-- Solves a polynomial (coefficient array) = 0, writing the reasoning into S.
-- Returns the list of root records.
function ENG.solvePolySteps(c0, v, S, opts)
  opts = opts or {}
  local c = uniTrim(uniCopy(c0))

  -- clear fractional coefficients
  local den = 1
  for i = 0, c.deg do den = ilcm(den, c[i].d) end
  if den > 1 then
    for i = 0, c.deg do c[i] = c[i] * q(den) end
    addStep(S, "work", "Clear the fractions",
      pstr(uniPoly(v, c, c.deg), v) .. " = 0",
      "Multiply every term by the least common denominator, " .. intStr(den) .. ".")
  end
  -- divide out a common integer factor
  local g = 0
  for i = 0, c.deg do g = igcd(g, c[i].n) end
  if g > 1 then
    for i = 0, c.deg do c[i] = c[i] / q(g) end
    addStep(S, "work", "Divide out the common factor",
      pstr(uniPoly(v, c, c.deg), v) .. " = 0",
      "Every coefficient is divisible by " .. intStr(g) .. ", so divide both sides by it.")
  end
  -- prefer a positive leading coefficient
  if c[c.deg].n < 0 then
    for i = 0, c.deg do c[i] = -c[i] end
    addStep(S, "work", "Make the leading coefficient positive",
      pstr(uniPoly(v, c, c.deg), v) .. " = 0",
      "Multiply both sides by -1. The right side stays 0.")
  end

  local poly = uniPoly(v, c, c.deg)

  if c.deg == 0 then
    if qz(c[0]) then
      addStep(S, "answer", "Every number works",
        "Both sides are identical, so the equation is true for every value of " .. v .. ".")
      return {}, "identity"
    end
    addStep(S, "answer", "No solution",
      "The variable cancelled and left " .. qstr(c[0]) .. " = 0, which is false.")
    return {}, "none"
  end

  if c.deg == 1 then
    local a, b = c[1], c[0]
    addStep(S, "note", "This is a linear equation",
      "Degree 1, so there is exactly one solution. Undo the operations around " .. v .. ".")
    if not qz(b) then
      local verb = (b.n > 0)
        and ("Subtract " .. qstr(qabs(b)) .. " from both sides")
        or  ("Add " .. qstr(qabs(b)) .. " to both sides")
      addStep(S, "work", verb,
        qstrCoef(a) .. v .. " = " .. qstr(-b),
        "That clears the constant off the " .. v .. " side.")
    end
    local root = -b / a
    if a == ONE then
      addStep(S, "answer", "Solution", v .. " = " .. qstr(root))
    else
      local raw = qstr(-b) .. "/" .. qstr(a)
      local red = qstr(root)
      addStep(S, "work", "Divide both sides by " .. qstr(a),
        v .. " = " .. ((raw == red) and red or (raw .. " = " .. red)),
        "Dividing by the coefficient of " .. v .. " leaves " .. v .. " on its own.")
    end
    return { ENG.rootRational(root) }, "linear"
  end

  if c.deg == 2 then
    local a, b, cc = c[2], c[1], c[0]
    addStep(S, "note", "This is a quadratic equation",
      "Standard form  a" .. v .. "^2 + b" .. v .. " + c = 0  with a = " .. qstr(a) ..
      ", b = " .. qstr(b) .. ", c = " .. qstr(cc) .. ".")
    local fac = ENG.factorPoly(poly)
    local factorable = ENG.isFactored(fac)
    if factorable then
      local m, n = ENG.acNumbers(fac, a, b, cc, v)
      local shown = false
      if qz(cc) then
        addStep(S, "work", "Factor out the common " .. v,
          ENG.factorStr(fac, v) .. " = 0",
          "There is no constant term, so every term contains " .. v .. ".")
        shown = true
      elseif m and n then
        if a == ONE then
          addStep(S, "work", "Factor by inspection",
            qstr(m) .. " and " .. qstr(n),
            "Look for two numbers that multiply to c = " .. qstr(cc) ..
            " and add to b = " .. qstr(b) .. ". Those two numbers go straight into the brackets.")
        else
          addStep(S, "work", "Factor with the AC method",
            qstr(m) .. " and " .. qstr(n),
            "Look for two numbers that multiply to a*c = " .. qstr(a * cc) ..
            " and add to b = " .. qstr(b) .. ", then split the middle term into " ..
            qstrCoef(m) .. v .. " + " .. qstrCoef(n) .. v .. " and factor by grouping.")
        end
      end
      if not shown then
        addStep(S, "work", "Factored form", ENG.factorStr(fac, v) .. " = 0")
      end
      addStep(S, "note", "Zero Product Property",
        "If a product is 0 then one of its factors is 0, so set each factor equal to 0.")
    else
      local disc = b * b - q(4) * a * cc
      addStep(S, "work", "Use the discriminant",
        "D = b^2 - 4ac = (" .. qstr(b) .. ")^2 - 4(" .. qstr(a) .. ")(" .. qstr(cc) ..
        ") = " .. qstr(disc),
        "No pair of rational numbers factors this, so use the formula instead. D " ..
        (disc.n > 0 and "> 0, so there are two real solutions."
         or (qz(disc) and "= 0, so there is one repeated solution."
                       or "< 0, so the two solutions are complex.")))
      addStep(S, "work", "Quadratic formula",
        v .. " = (" .. qstr(-b) .. " " .. PLUSMIN .. " " .. SQRT_CH .. qstr(disc) .. ") / " ..
        qstr(TWO * a),
        "From  " .. v .. " = (-b " .. PLUSMIN .. " " .. SQRT_CH .. "D) / (2a).")
    end
    local roots = ENG.quadraticRoots(a, b, cc)
    return roots, "quadratic"
  end

  -- degree 3 and up
  addStep(S, "note", "This is a " .. ENG.degreeName(c.deg) .. " equation",
    "A degree-" .. intStr(c.deg) .. " polynomial has " .. intStr(c.deg) ..
    " roots counting multiplicity. Factor it as far as possible, then solve each factor.")
  local fac = ENG.factorPoly(poly)
  local roots = {}
  if ENG.isFactored(fac) then
    addStep(S, "work", "Factor completely", ENG.factorStr(fac, v) .. " = 0",
      "Rational Root Theorem: the candidates are (factors of the constant term) / (factors of the leading coefficient).")
    addStep(S, "note", "Zero Product Property", "Set each factor equal to 0 and solve.")
    for _, f in ipairs(fac.factors) do
      local fc = uniCoeffs(f.p, v)
      local d = fc and fc.deg or 0
      if d == 1 then
        local r = -fc[0] / fc[1]
        addStep(S, "work", pstr(f.p, v) .. " = 0", v .. " = " .. qstr(r) ..
          (f.k > 1 and "   (multiplicity " .. intStr(f.k) .. ")" or ""))
        roots[#roots + 1] = ENG.rootRational(r, f.k)
      elseif d == 2 then
        local rs, disc = ENG.quadraticRoots(fc[2], fc[1], fc[0])
        addStep(S, "work", pstr(f.p, v) .. " = 0",
          "Quadratic formula with a = " .. qstr(fc[2]) .. ", b = " .. qstr(fc[1]) ..
          ", c = " .. qstr(fc[0]) .. ";  D = " .. qstr(disc))
        for _, r in ipairs(rs) do
          r.mult = r.mult * f.k
          roots[#roots + 1] = r
        end
      elseif d and d >= 3 then
        addStep(S, "work", pstr(f.p, v) .. " = 0",
          "This factor has no rational roots, so its roots are found numerically.")
        for _, z in ipairs(ENG.numericRoots(fc)) do
          if z.im == 0 then
            roots[#roots + 1] = ENG.rootNumeric(z.re, f.k)
          else
            roots[#roots + 1] = { kind = "complex", exact = decStr(z.re, 6) ..
              (z.im < 0 and " - " or " + ") .. decStr(abs(z.im), 6) .. "i",
              re = z.re, im = z.im, approxOnly = true, mult = f.k }
          end
        end
      end
    end
  else
    addStep(S, "work", "No rational roots",
      "Every candidate from the Rational Root Theorem was tested and none is a root, " ..
      "so this polynomial cannot be factored over the rationals.",
      "Solving numerically instead.")
    for _, z in ipairs(ENG.numericRoots(c)) do
      if z.im == 0 then
        roots[#roots + 1] = ENG.rootNumeric(z.re)
      else
        roots[#roots + 1] = { kind = "complex", exact = decStr(z.re, 6) ..
          (z.im < 0 and " - " or " + ") .. decStr(abs(z.im), 6) .. "i",
          re = z.re, im = z.im, approxOnly = true, mult = 1 }
      end
    end
  end
  return roots, "polynomial"
end

-- ----------------------------------------------------------------------------
-- 12. Printing an AST back to text (used for "Given" and for check lines,
--     where the variable is replaced by the value being substituted)
-- ----------------------------------------------------------------------------

local function astStr(node, env, need)
  need = need or 0
  local s, prec
  local k = node.k
  if k == "num" then
    s = qstr(node.v)
    prec = (node.v.n < 0) and 3 or ((node.v.d ~= 1) and 2 or 5)
  elseif k == "var" then
    s = (env and env[node.v]) or node.v
    prec = (env and env[node.v]) and 2 or 5
  elseif k == "neg" then
    s = "-" .. astStr(node.a, env, 3); prec = 3
  elseif k == "fn" then
    if node.name == "pi" then
      s = "pi"
    elseif node.name == "abs" and node.args and node.args[1] then
      s = "|" .. astStr(node.args[1], env, 0) .. "|"
    else
      local parts = {}
      for i, a in ipairs(node.args) do parts[i] = astStr(a, env, 0) end
      s = node.name .. "(" .. table.concat(parts, ", ") .. ")"
    end
    prec = 5
  elseif k == "pow" then
    s = astStr(node.a, env, 5) .. "^" .. astStr(node.b, env, 3); prec = 4
  elseif k == "add" then
    s = astStr(node.a, env, 1) .. " + " .. astStr(node.b, env, 1); prec = 1
  elseif k == "sub" then
    s = astStr(node.a, env, 1) .. " - " .. astStr(node.b, env, 2); prec = 1
  elseif k == "mul" then
    local left = astStr(node.a, env, 2)
    local right = astStr(node.b, env, 3)
    local glue = "*"
    if node.a.k == "num" and node.a.v.n >= 0 and node.a.v.d == 1 and
       (node.b.k == "var" or node.b.k == "fn" or node.b.k == "pow" or
        right:sub(1, 1) == "(") then
      glue = ""
    end
    s = left .. glue .. right; prec = 2
  elseif k == "div" then
    s = astStr(node.a, env, 2) .. "/" .. astStr(node.b, env, 3); prec = 2
  else
    s = "?"; prec = 5
  end
  if prec < need then return "(" .. s .. ")" end
  return s
end

-- ----------------------------------------------------------------------------
-- 13. The handheld's own CAS, used only as a fallback / cross-check
-- ----------------------------------------------------------------------------

function ENG.cas(expr)
  if type(math.evalStr) ~= "function" then return nil end
  local ok, res = pcall(math.evalStr, expr)
  if ok and type(res) == "string" and res ~= "" then return res end
  return nil
end

-- Sign-change scan + bisection: finds real solutions of anything the exact
-- engine cannot touch (trig, logs, exponentials).
function ENG.numericScan(lhs, rhs, v, lo, hi, samples)
  lo = lo or -30; hi = hi or 30; samples = samples or 3000
  local f = function(x)
    local a = astNum(lhs, { [v] = x })
    local b = astNum(rhs, { [v] = x })
    if a == nil or b == nil then return nil end
    local d = a - b
    if d ~= d or d == math.huge or d == -math.huge then return nil end
    return d
  end
  local out = {}
  local step = (hi - lo) / samples
  local px, pv = nil, nil
  for i = 0, samples do
    local x = lo + i * step
    local y = f(x)
    if y then
      if y == 0 then
        out[#out + 1] = x
      elseif pv and ((pv < 0 and y > 0) or (pv > 0 and y < 0)) then
        local a, b = px, x
        for _ = 1, 80 do
          local m = (a + b) / 2
          local fm = f(m)
          if fm == nil then break end
          if (fm < 0) == (pv < 0) then a = m else b = m end
        end
        out[#out + 1] = (a + b) / 2
      end
      px, pv = x, y
    else
      px, pv = nil, nil
    end
    if #out > 40 then break end
  end
  -- de-duplicate
  local uniq = {}
  for _, x in ipairs(out) do
    local dup = false
    for _, y in ipairs(uniq) do
      if abs(x - y) < 1e-7 * (1 + abs(x)) then dup = true; break end
    end
    if not dup then uniq[#uniq + 1] = x end
  end
  return uniq
end

local VAR_PREFERENCE = { "x", "y", "z", "t", "n", "a", "b", "u", "v", "w" }

function ENG.pickVar(list)
  for _, want in ipairs(VAR_PREFERENCE) do
    for _, have in ipairs(list) do
      if have == want then return have end
    end
  end
  return list[1]
end

-- ----------------------------------------------------------------------------
-- 14. Removing sqrt / abs atoms by squaring
-- ----------------------------------------------------------------------------

function ENG.eliminateAtoms(N, ctx, v, S, disp)
  local squared = false
  for _, name in ipairs(ctx.order) do
    local atom = ctx.atoms[name]
    if atom.rule and pdegIn(N, name) > 0 then
      local ruleR = atom.rule.value
      if not pisconst(ruleR.d) then
        fail("unsupported", "A radical over a variable denominator needs the CAS.")
      end
      local ruleP = pscale(ruleR.n, ONE / pconstval(ruleR.d))
      local co = pcoeffsIn(N, name)
      for i = co.deg, 2, -1 do
        co[i - 2] = co[i - 2] + co[i] * ruleP
        co[i] = pnew()
      end
      local A, B = co[0], co[1] or pnew()
      if not piszero(B) then
        local what = (atom.kind == "abs") and "absolute value" or "radical"
        addStep(S, "work", "Isolate the " .. what,
          pstr(A, v, disp) .. " = " .. pstr((-B) * pvar(name), v, disp),
          "Get the " .. what .. " alone on one side before squaring.")
        addStep(S, "work", "Square both sides",
          "(" .. pstr(A, v, disp) .. ")^2 = " .. pstr(B * B * ruleP, v, disp),
          "Squaring removes the " .. what .. ", but it can create solutions that do not " ..
          "fit the original equation, so every answer gets checked at the end.")
        N = A * A - B * B * ruleP
        squared = true
      else
        N = A
      end
    end
  end
  return N, squared
end

-- ----------------------------------------------------------------------------
-- 15. Checking an answer against the ORIGINAL input
-- ----------------------------------------------------------------------------

-- Returns ok(boolean), description(string). Exact when the arithmetic allows.
function ENG.checkRoot(lhs, rhs, v, root)
  if root.q then
    local a = astQ(lhs, { [v] = root.q })
    local b = astQ(rhs, { [v] = root.q })
    if a and b then
      local lstr = astStr(lhs, { [v] = qstr(root.q) })
      return (a == b),
        lstr .. " = " .. qstr(a) .. "   and   " ..
        astStr(rhs, { [v] = qstr(root.q) }) .. " = " .. qstr(b)
    end
  end
  if root.num == nil then return nil, nil end
  local a = astNum(lhs, { [v] = root.num })
  local b = astNum(rhs, { [v] = root.num })
  if a == nil or b == nil then
    return false, "substituting " .. v .. " = " .. root.exact ..
      " makes the expression undefined"
  end
  local tol = 1e-6 * (1 + abs(a) + abs(b))
  return (abs(a - b) <= tol),
    "left side " .. APPROX .. " " .. decStr(a, 6) ..
    ",  right side " .. APPROX .. " " .. decStr(b, 6)
end

-- ----------------------------------------------------------------------------
-- 16. The Solve driver
-- ----------------------------------------------------------------------------

-- Anything in this set has to go to the CAS / numeric path.
local TRANSCENDENTAL = {
  sin = true, cos = true, tan = true, asin = true, acos = true,
  atan = true, ln = true, log = true, exp = true,
}

function ENG.solveFallback(text, lhs, rhs, v, S, why)
  addStep(S, "warn", "Outside the exact step engine",
    why or "This equation mixes algebra with functions that have no general algebraic solution.",
    "Showing the handheld's CAS answer plus a numeric search instead.")
  local answers = {}
  local casExpr = "solve(" .. astStr(lhs) .. "=" .. astStr(rhs) .. "," .. v .. ")"
  local casRes = ENG.cas(casExpr)
  if casRes then
    addStep(S, "work", "Ask the built-in CAS", casExpr, casRes)
    answers[#answers + 1] = casRes
  end
  local hits = ENG.numericScan(lhs, rhs, v)
  if #hits > 0 then
    local parts = {}
    for i, x in ipairs(hits) do parts[i] = v .. " " .. APPROX .. " " .. decStr(x, 8) end
    addStep(S, "work", "Numeric search on -30 " .. ARROW .. " 30",
      "Sample the difference (left side - right side) and bisect wherever it changes sign:",
      table.concat(parts, ",   "))
    if #answers == 0 then
      for _, p in ipairs(parts) do answers[#answers + 1] = p end
    end
    if #hits >= 8 then
      addStep(S, "note", "Periodic equation",
        "Solutions repeat outside the scanned window - only those between -30 and 30 are listed.")
    end
  end
  if #answers == 0 then
    addStep(S, "answer", "No real solution found",
      "Nothing in -30 " .. ARROW .. " 30 satisfies the equation, and the CAS is not available here.")
  else
    addStep(S, "answer", "Solutions", table.concat(answers, "\n"))
  end
  return { ok = true, steps = S.list, variable = v, answers = answers, approximate = true }
end

function ENG.solve(text, opts)
  opts = opts or {}
  local S = newSteps()
  local st = parseOne(text)
  local lhs = st.lhs
  local rhs = st.rhs or { k = "num", v = ZERO }

  local varsSet = astVars(lhs); astVars(rhs, varsSet)
  local vlist = sortedKeys(varsSet)

  local givenNote = nil
  if not st.eq then
    givenNote = "No '=' was typed, so the expression is set equal to 0."
  end
  addStep(S, "given", "Given", astStr(lhs) .. " = " .. astStr(rhs), givenNote)

  if #vlist == 0 then
    local a, b = astNum(lhs, {}), astNum(rhs, {})
    if a and b then
      local same = abs(a - b) <= 1e-9 * (1 + abs(a) + abs(b))
      addStep(S, "answer", same and "True statement" or "False statement",
        decStr(a, 8) .. " = " .. decStr(b, 8),
        same and "There is no variable to solve for." or "The two sides are not equal.")
      return { ok = true, steps = S.list, answers = { same and "true" or "false" } }
    end
    return { ok = false, error = "There is no variable in this equation." }
  end

  local v = opts.variable or ENG.pickVar(vlist)
  if not varsSet[v] then
    return { ok = false, error = "'" .. v .. "' does not appear in this equation." }
  end
  if #vlist > 1 then
    addStep(S, "note", "Solving for " .. v,
      "Variables present: " .. table.concat(vlist, ", ") ..
      ". The others are treated as constants.")
  end

  local funcs = astFuncs(lhs); astFuncs(rhs, funcs)
  for name in pairs(funcs) do
    if TRANSCENDENTAL[name] then
      return ENG.solveFallback(text, lhs, rhs, v, S,
        name .. "() has no general algebraic inverse here.")
    end
  end

  local ctx = newCtx()
  local ok, res = pcall(ENG.solveExact, lhs, rhs, v, S, ctx)
  if ok then return res end
  if type(res) == "table" and res.eqsolver and
     (res.code == "unsupported" or res.code == "overflow") then
    return ENG.solveFallback(text, lhs, rhs, v, S, res.msg)
  end
  error(res, 0)
end

function ENG.solveExact(lhs, rhs, v, S, ctx)
  local L = astToR(lhs, ctx)
  local Rr = astToR(rhs, ctx)
  local E = L - Rr
  local disp = atomDisp(ctx)
  local N, D = E.n, E.d
  local restrictions = {}

  if not pisconst(D) then
    local dc = uniCoeffs(D, v)
    if dc and dc.deg >= 1 then
      for _, z in ipairs(ENG.numericRoots(dc)) do
        if z.im == 0 then restrictions[#restrictions + 1] = z.re end
      end
    end
    local rtxt = ""
    if #restrictions > 0 then
      local parts = {}
      for i, x in ipairs(restrictions) do parts[i] = v .. " " .. NEQ .. " " .. decStr(x, 6) end
      rtxt = "Restrictions: " .. table.concat(parts, ", ") .. "."
    end
    addStep(S, "note", "This is a rational equation",
      "The variable appears in a denominator, so first combine everything over the common " ..
      "denominator " .. pstr(D, v, disp) .. ".", rtxt)
    addStep(S, "work", "Multiply both sides by the denominator",
      "A fraction equals 0 only when its numerator is 0:",
      pstr(N, v, disp) .. " = 0")
  else
    local dc = pconstval(D)
    if not (dc == ONE) then N = pscale(N, ONE / dc) end
    addStep(S, "work", "Write it in standard form",
      pstr(N, v, disp) .. " = 0",
      "Move every term to one side and combine like terms.")
  end

  local squared
  N, squared = ENG.eliminateAtoms(N, ctx, v, S, disp)

  local others = {}
  for _, name in ipairs(pvars(N)) do
    if name ~= v then others[#others + 1] = name end
  end

  local roots, shape
  if #others > 0 then
    roots, shape = ENG.solveLiteral(N, v, S, disp, others)
    return {
      ok = true, steps = S.list, variable = v, literal = true,
      answers = roots, shape = shape,
    }
  end

  local c = uniCoeffs(N, v)
  if not c then return { ok = false, error = "Could not reduce this to a polynomial." } end
  roots, shape = ENG.solvePolySteps(c, v, S)

  -- keep only the roots that survive a substitution into the original input
  local kept, dropped = {}, {}
  for _, r in ipairs(roots) do
    local keep = true
    if r.kind ~= "complex" and (squared or #restrictions > 0) then
      for _, x in ipairs(restrictions) do
        if r.num and abs(r.num - x) < 1e-9 * (1 + abs(x)) then keep = false end
      end
      if keep then
        local good = ENG.checkRoot(lhs, rhs, v, r)
        if good == false then keep = false end
      end
    end
    if keep then kept[#kept + 1] = r else dropped[#dropped + 1] = r end
  end

  if #dropped > 0 then
    local parts = {}
    for i, r in ipairs(dropped) do parts[i] = v .. " = " .. r.exact end
    addStep(S, "warn", "Extraneous - throw these out",
      table.concat(parts, ",   "),
      (squared and "Squaring both sides created these; they do not satisfy the original equation."
               or "These values make a denominator zero, so they are not in the domain."))
  end

  -- present real solutions in increasing order, complex ones last
  table.sort(kept, function(a, b)
    local ar = (a.kind == "complex") and 1 or 0
    local br = (b.kind == "complex") and 1 or 0
    if ar ~= br then return ar < br end
    local an = a.num or a.re or 0
    local bn = b.num or b.re or 0
    if abs(an - bn) > 1e-12 then return an < bn end
    return (a.im or 0) < (b.im or 0)
  end)

  local answers = {}
  for _, r in ipairs(kept) do
    local line = v .. " = " .. r.exact
    if r.mult and r.mult > 1 then line = line .. "   (multiplicity " .. intStr(r.mult) .. ")" end
    if not r.approxOnly and r.kind == "real" and r.num and
       (r.q == nil or not qisint(r.q)) then
      line = line .. "   " .. APPROX .. " " .. decStr(r.num, 6)
    end
    answers[#answers + 1] = line
  end

  if #answers == 0 then
    if shape == "identity" then
      answers[1] = "every real number (identity)"
    elseif shape == "none" then
      answers[1] = "no solution"
    else
      answers[1] = "no solution"
      addStep(S, "answer", "No solution", "Nothing satisfies the original equation.")
    end
  else
    addStep(S, "answer", (#answers == 1 and "Solution" or "Solutions"),
      table.concat(answers, "\n"))
    for i, r in ipairs(kept) do
      if i <= 3 and r.kind == "real" then
        local good, desc = ENG.checkRoot(lhs, rhs, v, r)
        if desc then
          addStep(S, "check", "Check " .. v .. " = " .. r.exact, desc,
            good and "Both sides agree." or "Does not check out.")
        end
      end
    end
  end

  return { ok = true, steps = S.list, variable = v, answers = answers, roots = kept, shape = shape }
end

-- Rearranging a formula: the target variable's coefficient is itself an
-- expression in the other letters.
function ENG.solveLiteral(N, v, S, disp, others)
  local co = pcoeffsIn(N, v)
  addStep(S, "note", "Solving a formula",
    "Treat " .. table.concat(others, ", ") .. " as constant and isolate " .. v .. ".")

  if co.deg == 0 then
    addStep(S, "answer", "No solution for " .. v,
      v .. " cancelled out, leaving " .. pstr(co[0], nil, disp) .. " = 0.")
    return {}, "none"
  end

  if co.deg == 1 then
    local A, B = co[1], co[0]
    addStep(S, "work", "Collect the " .. v .. " terms",
      pstrP(A, nil, disp) .. v .. " = " .. pstr(-B, nil, disp))
    local ans = rmake(-B, A)
    addStep(S, "work", "Divide both sides by the coefficient of " .. v,
      v .. " = " .. rstr(ans, nil, disp),
      "Valid as long as " .. pstr(A, nil, disp) .. " " .. NEQ .. " 0.")
    addStep(S, "answer", "Solution", v .. " = " .. rstr(ans, nil, disp))
    return { v .. " = " .. rstr(ans, nil, disp) }, "linear"
  end

  if co.deg == 2 then
    local A, B, C = co[2], co[1], co[0]
    addStep(S, "note", "Quadratic in " .. v,
      "a = " .. pstr(A, nil, disp) .. ",  b = " .. pstr(B, nil, disp) ..
      ",  c = " .. pstr(C, nil, disp))
    local disc = B * B - pconst(q(4)) * A * C
    local sq = ENG.polySqrt(disc)
    addStep(S, "work", "Discriminant", "D = b^2 - 4ac = " .. pstr(disc, nil, disp))
    local rad = sq and pstrP(sq, nil, disp) or (SQRT_CH .. "(" .. pstr(disc, nil, disp) .. ")")
    local ans = v .. " = (" .. pstr(-B, nil, disp) .. " " .. PLUSMIN .. " " .. rad ..
                ") / " .. pstrP(pconst(TWO) * A, nil, disp)
    addStep(S, "work", "Quadratic formula", ans)
    addStep(S, "answer", "Solution", ans)
    return { ans }, "quadratic"
  end

  fail("unsupported", "Formulas of degree 3 or more in " .. v .. " need the CAS.")
end

-- ----------------------------------------------------------------------------
-- 17. The other modes
-- ----------------------------------------------------------------------------

-- Turns a parsed statement into a single expression (lhs - rhs when an '='
-- was typed) plus a rational-function form of it.
local function statementToR(st, ctx)
  local node = st.lhs
  if st.rhs then node = { k = "sub", a = st.lhs, b = st.rhs } end
  return node, astToR(node, ctx)
end

function ENG.doFactor(text)
  local S = newSteps()
  local st = parseOne(text)
  local ctx = newCtx()
  local node, E = statementToR(st, ctx)
  local disp = atomDisp(ctx)
  addStep(S, "given", "Given", astStr(node),
    st.rhs and "An '=' was typed, so the right side is moved over and the difference is factored."
            or nil)

  local function factorPart(poly, label)
    local v = ENG.pickVar(pvars(poly)) or "x"
    local fac = ENG.factorPoly(poly)
    if label then
      addStep(S, "work", label, pstr(poly, v, disp))
    else
      addStep(S, "work", "Write it in standard form", pstr(poly, v, disp) ..
        "   (degree " .. intStr(pdegIn(poly, v)) .. " in " .. v .. ")")
    end
    if not (fac.const == ONE) or #fac.factors > 1 then
      local mono = {}
      for _, f in ipairs(fac.factors) do
        local count = 0
        for _ in pairs(f.p.t) do count = count + 1 end
        if count == 1 then mono[#mono + 1] = f end
      end
      if not (fac.const == ONE) or #mono > 0 then
        local gcfRes = { const = fac.const, factors = mono }
        addStep(S, "work", "Greatest common factor",
          "Pull out " .. ENG.factorStr(gcfRes, v, disp) .. " first.")
      end
    end
    for _, n in ipairs(fac.notes or {}) do
      addStep(S, "note", "Pattern used", n)
    end
    local out = ENG.factorStr(fac, v, disp)
    if ENG.isFactored(fac) then
      addStep(S, "answer", "Factored", out)
      local back = pconst(fac.const)
      for _, f in ipairs(fac.factors) do back = back * ppow(f.p, f.k) end
      addStep(S, "check", "Check by multiplying back out",
        pstr(back, v, disp), (back == poly) and "Matches the original." or "Does not match.")
    else
      addStep(S, "answer", "Already fully factored", out,
        "This is prime over the rationals - it has no factorisation with rational coefficients.")
      if pdegIn(poly, v) == 2 then
        local c = uniCoeffs(poly, v)
        if c then
          local d = c[1] * c[1] - q(4) * c[2] * c[0]
          addStep(S, "note", "Why", "The discriminant b^2 - 4ac = " .. qstr(d) ..
            " is not a perfect square, so there are no rational roots.")
        end
      end
    end
    return out
  end

  local answer
  if pisconst(E.d) then
    local poly = pscale(E.n, ONE / pconstval(E.d))
    answer = factorPart(poly)
  else
    addStep(S, "note", "This is a rational expression",
      "Factor the top and the bottom separately, then cancel anything common.")
    local function parenIfSum(str)
      if str:find(" %+ ") or str:find(" %- ") then return "(" .. str .. ")" end
      return str
    end
    local topStr = parenIfSum(factorPart(E.n, "Numerator"))
    local botStr = parenIfSum(factorPart(E.d, "Denominator"))
    answer = topStr .. "/" .. botStr
    addStep(S, "answer", "Factored form", answer,
      "Common factors were already cancelled when the expression was simplified.")
  end
  return { ok = true, steps = S.list, answers = { answer } }
end

function ENG.doExpand(text)
  local S = newSteps()
  local st = parseOne(text)
  local ctx = newCtx()
  local node, E = statementToR(st, ctx)
  local disp = atomDisp(ctx)
  addStep(S, "given", "Given", astStr(node))
  local v = ENG.pickVar(pvars(E.n)) or ENG.pickVar(pvars(E.d)) or "x"

  addStep(S, "note", "Method",
    "Multiply out every product and power (distributive property), then add the like terms - " ..
    "terms with exactly the same variables and exponents.")
  local answer
  if pisconst(E.d) then
    local poly = pscale(E.n, ONE / pconstval(E.d))
    answer = pstr(poly, v, disp)
    addStep(S, "answer", "Expanded", answer)
    local deg = pdegIn(poly, v)
    if deg > 0 then
      local co = pcoeffsIn(poly, v)
      addStep(S, "note", "About the result",
        "Degree " .. intStr(deg) .. " in " .. v ..
        ",  leading coefficient " .. pstr(co[deg], nil, disp) ..
        ",  constant term " .. pstr(co[0], nil, disp) ..
        ",  " .. intStr(#psortedTerms(poly)) .. " terms.")
    end
  else
    answer = rstr(E, v, disp)
    addStep(S, "answer", "Simplified", answer,
      "Numerator and denominator are already reduced to lowest terms.")
  end
  return { ok = true, steps = S.list, answers = { answer } }
end

function ENG.doEvaluate(text)
  local S = newSteps()
  local parts = splitStatements(text)
  if #parts == 0 then return { ok = false, error = "Nothing to evaluate." } end

  local exprText = parts[1]
  local env, envStr, order = {}, {}, {}
  for i = 2, #parts do
    local a = parseOne(parts[i])
    if not a.eq or a.lhs.k ~= "var" then
      return { ok = false, error = "Write each value like  x=3  after a comma." }
    end
    local val = astQ(a.rhs, {})
    if not val then
      local n = astNum(a.rhs, {})
      if not n then return { ok = false, error = "Could not read the value of " .. a.lhs.v .. "." } end
      val = q(floor(n * 1000000 + 0.5), 1000000)
    end
    env[a.lhs.v] = val
    envStr[a.lhs.v] = "(" .. qstr(val) .. ")"
    order[#order + 1] = a.lhs.v .. " = " .. qstr(val)
  end

  local st = parseOne(exprText)
  addStep(S, "given", "Given", astStr(st.lhs) .. (st.rhs and (" = " .. astStr(st.rhs)) or ""),
    #order > 0 and ("with  " .. table.concat(order, ",  ")) or nil)

  local function evalSide(node, label)
    addStep(S, "work", "Substitute" .. (label and (" into the " .. label) or ""),
      astStr(node, envStr))
    local exact = astQ(node, env)
    if exact then
      local line = qstr(exact)
      if not qisint(exact) then line = line .. "   " .. APPROX .. " " .. decStr(qnum(exact), 6) end
      return line, exact, qnum(exact)
    end
    local numenv = {}
    for k2, val in pairs(env) do numenv[k2] = qnum(val) end
    local n = astNum(node, numenv)
    if n == nil then return nil end
    return APPROX .. " " .. decStr(n, 8), nil, n
  end

  if st.rhs then
    local ls, _, ln = evalSide(st.lhs, "left side")
    local rs, _, rn = evalSide(st.rhs, "right side")
    if not ls or not rs then
      return { ok = false, error = "That value is outside the domain (divide by zero or root of a negative)." }
    end
    addStep(S, "work", "Compare", "left = " .. ls .. "\nright = " .. rs)
    local same = abs(ln - rn) <= 1e-9 * (1 + abs(ln) + abs(rn))
    addStep(S, "answer", same and "True - the values satisfy the equation"
                              or "False - the two sides are different",
      "left = " .. ls .. ",  right = " .. rs)
    return { ok = true, steps = S.list, answers = { same and "true" or "false" } }
  end

  local s1 = evalSide(st.lhs)
  if not s1 then
    return { ok = false, error = "That value is outside the domain (divide by zero or root of a negative)." }
  end
  addStep(S, "answer", "Value", s1)
  return { ok = true, steps = S.list, answers = { s1 } }
end

-- Roots without any narration (Analyze mode wants the values, not the lecture).
function ENG.rootsOf(c, v)
  local throwaway = newSteps()
  local roots = ENG.solvePolySteps(uniCopy(c), v, throwaway)
  table.sort(roots, function(a, b)
    local ac = (a.kind == "complex") and 1 or 0
    local bc = (b.kind == "complex") and 1 or 0
    if ac ~= bc then return ac < bc end
    local an, bn = a.num or a.re or 0, b.num or b.re or 0
    if abs(an - bn) > 1e-12 then return an < bn end
    return (a.im or 0) < (b.im or 0)
  end)
  return roots
end

function ENG.doSystem(text)
  local S = newSteps()
  local parts = splitStatements(text)
  if #parts ~= 2 then
    return { ok = false, error = "Type two equations separated by a comma, e.g.  2x+y=7, x-y=2" }
  end
  local ctx = newCtx()
  local sts, polys = {}, {}
  local varsSet = {}
  for i = 1, 2 do
    local st = parseOne(parts[i])
    if not st.eq then return { ok = false, error = "Equation " .. i .. " needs an '=' sign." } end
    sts[i] = st
    astVars(st.lhs, varsSet); astVars(st.rhs, varsSet)
    local _, E = statementToR(st, ctx)
    if not pisconst(E.d) then
      return { ok = false, error = "Systems with variable denominators are not supported." }
    end
    polys[i] = pscale(E.n, ONE / pconstval(E.d))
  end
  local vlist = sortedKeys(varsSet)
  if #vlist ~= 2 then
    return { ok = false, error = "Two equations need exactly two unknowns (found " ..
             intStr(#vlist) .. ")." }
  end
  local vx, vy = vlist[1], vlist[2]
  if vx == "y" and vy == "x" then vx, vy = "x", "y" end

  addStep(S, "given", "Given",
    astStr(sts[1].lhs) .. " = " .. astStr(sts[1].rhs) .. "\n" ..
    astStr(sts[2].lhs) .. " = " .. astStr(sts[2].rhs),
    "Two equations, two unknowns (" .. vx .. " and " .. vy .. ").")

  local function linearParts(p)
    if pdegIn(p, vx) > 1 or pdegIn(p, vy) > 1 then return nil end
    local co = pcoeffsIn(p, vx)
    if co.deg == 1 and pdegIn(co[1], vy) > 0 then return nil end
    local a = (co.deg >= 1) and pconstval(co[1]) or ZERO
    local rest = pcoeffsIn(co[0], vy)
    local b = (rest.deg >= 1) and pconstval(rest[1]) or ZERO
    local c = pconstval(rest[0])
    return a, b, c
  end

  local a1, b1, c1 = linearParts(polys[1])
  local a2, b2, c2 = linearParts(polys[2])

  if a1 and a2 then
    -- ---- linear system: elimination -------------------------------------
    local function eqStr(a, b, c)
      return pstr(pconst(a) * pvar(vx) + pconst(b) * pvar(vy), vx) .. " = " .. qstr(-c)
    end
    addStep(S, "work", "Put both equations in standard form",
      eqStr(a1, b1, c1) .. "\n" .. eqStr(a2, b2, c2))
    local det = a1 * b2 - a2 * b1
    if qz(det) then
      local prop = (a1 * c2 == a2 * c1) and (b1 * c2 == b2 * c1)
      if prop then
        addStep(S, "answer", "Infinitely many solutions",
          "The two equations describe the same line.",
          "Every point on " .. eqStr(a1, b1, c1) .. " is a solution.")
        return { ok = true, steps = S.list, answers = { "infinitely many solutions (same line)" } }
      end
      addStep(S, "answer", "No solution",
        "The lines are parallel: the " .. vx .. " and " .. vy ..
        " coefficients are proportional but the constants are not.")
      return { ok = true, steps = S.list, answers = { "no solution (parallel lines)" } }
    end

    local m1, m2 = b2, b1
    local g = igcd(igcd(m1.n, m2.n), 0)
    if not qz(b1) and not qz(b2) then
      addStep(S, "work", "Eliminate " .. vy,
        "Multiply equation 1 by " .. qstr(b2) .. " and equation 2 by " .. qstr(b1) ..
        " so the " .. vy .. " terms match, then subtract.",
        eqStr(a1 * m1, b1 * m1, c1 * m1) .. "\n" .. eqStr(a2 * m2, b2 * m2, c2 * m2))
    else
      addStep(S, "work", "Eliminate " .. vy,
        "One equation already has no " .. vy .. " term, so subtract directly.")
    end
    local xval = (b1 * c2 - b2 * c1) / det
    addStep(S, "work", "Subtract to remove " .. vy,
      qstrCoef(det) .. vx .. " = " .. qstr(b1 * c2 - b2 * c1),
      vx .. " = " .. qstr(xval))
    local yval
    if not qz(b1) then
      yval = (-c1 - a1 * xval) / b1
      addStep(S, "work", "Back-substitute into equation 1",
        qstrCoef(a1) .. "(" .. qstr(xval) .. ") + " .. qstrCoef(b1) .. vy .. " = " .. qstr(-c1),
        vy .. " = " .. qstr(yval))
    else
      yval = (-c2 - a2 * xval) / b2
      addStep(S, "work", "Back-substitute into equation 2",
        qstrCoef(a2) .. "(" .. qstr(xval) .. ") + " .. qstrCoef(b2) .. vy .. " = " .. qstr(-c2),
        vy .. " = " .. qstr(yval))
    end
    local ans = { vx .. " = " .. qstr(xval), vy .. " = " .. qstr(yval) }
    addStep(S, "answer", "Solution", table.concat(ans, ",   ") ..
      "     (the point where the two lines cross)")
    local env = { [vx] = xval, [vy] = yval }
    local ok1 = qz(pevalQ(polys[1], env) or ONE)
    local ok2 = qz(pevalQ(polys[2], env) or ONE)
    addStep(S, "check", "Check in both equations",
      "equation 1: " .. (ok1 and "true" or "FAILS") ..
      "\nequation 2: " .. (ok2 and "true" or "FAILS"))
    return { ok = true, steps = S.list, answers = ans }
  end

  -- ---- at least one equation is non-linear: substitution -----------------
  local subIdx, subVar, other
  for i = 1, 2 do
    for _, v in ipairs({ vy, vx }) do
      if pdegIn(polys[i], v) == 1 and not subIdx then
        local co = pcoeffsIn(polys[i], v)
        if pisconst(co[1]) or pdegIn(co[1], (v == vx) and vy or vx) == 0 then
          subIdx, subVar = i, v
          other = (v == vx) and vy or vx
        end
      end
    end
  end
  if not subIdx then
    return { ok = false, error = "Neither equation can be solved for one variable in terms of the other." }
  end

  local co = pcoeffsIn(polys[subIdx], subVar)
  local A, B = co[1], co[0]
  local expr = rmake(-B, A)
  addStep(S, "note", "Use substitution",
    "Equation " .. intStr(subIdx) .. " is linear in " .. subVar ..
    ", so solve it for " .. subVar .. " and put that into the other equation.")
  addStep(S, "work", "Solve equation " .. intStr(subIdx) .. " for " .. subVar,
    subVar .. " = " .. rstr(expr, other))

  local target = polys[3 - subIdx]
  local tc = pcoeffsIn(target, subVar)
  local elim = pnew()
  for i = 0, tc.deg do
    elim = elim + tc[i] * ppow(-B, i) * ppow(A, tc.deg - i)
  end
  addStep(S, "work", "Substitute into equation " .. intStr(3 - subIdx) .. " and clear denominators",
    pstr(elim, other) .. " = 0")

  local ec = uniCoeffs(elim, other)
  if not ec then return { ok = false, error = "The substitution did not reduce to one variable." } end
  local roots = ENG.solvePolySteps(ec, other, S)

  local ans = {}
  for _, r in ipairs(roots) do
    if r.kind == "real" and r.num then
      local pair
      if r.q then
        local av = pevalQ(A, { [other] = r.q })
        local bv = pevalQ(B, { [other] = r.q })
        if av and bv and not qz(av) then
          pair = other .. " = " .. qstr(r.q) .. ",  " .. subVar .. " = " .. qstr(-bv / av)
        end
      end
      if not pair then
        local an = pevalNum(A, { [other] = r.num })
        local bn = pevalNum(B, { [other] = r.num })
        if an and bn and an ~= 0 then
          pair = other .. " " .. APPROX .. " " .. decStr(r.num, 6) .. ",  " ..
                 subVar .. " " .. APPROX .. " " .. decStr(-bn / an, 6)
        end
      end
      if pair then ans[#ans + 1] = pair end
    end
  end
  if #ans == 0 then
    addStep(S, "answer", "No real solutions", "The curves never meet at a real point.")
    ans[1] = "no real solution"
  else
    addStep(S, "answer", (#ans == 1 and "Solution" or "Solutions"), table.concat(ans, "\n"),
      "Back-substitute each " .. other .. " value to get its partner.")
  end
  return { ok = true, steps = S.list, answers = ans }
end

function ENG.doAnalyze(text)
  local S = newSteps()
  local st = parseOne(text)
  local ctx = newCtx()
  local node = st.lhs
  if st.rhs then
    if st.lhs.k == "var" then node = st.rhs else node = { k = "sub", a = st.lhs, b = st.rhs } end
  end
  local E = astToR(node, ctx)
  local disp = atomDisp(ctx)
  if not pisconst(E.d) then
    return { ok = false, error = "Analyze works on polynomials, not rational expressions." }
  end
  local poly = pscale(E.n, ONE / pconstval(E.d))
  local vs = pvars(poly)
  if #vs == 0 then return { ok = false, error = "That is a constant, not a function." } end
  if #vs > 1 then return { ok = false, error = "Analyze needs a polynomial in one variable." } end
  local v = vs[1]
  local c = uniCoeffs(poly, v)
  local deg = c.deg

  addStep(S, "given", "Function", "f(" .. v .. ") = " .. pstr(poly, v, disp))
  addStep(S, "note", "Shape",
    "Degree " .. intStr(deg) .. " (" .. ENG.degreeName(deg) .. "),  leading coefficient " ..
    qstr(c[deg]) .. ",  constant term " .. qstr(c[0]) .. ".")
  addStep(S, "work", "y-intercept", "f(0) = " .. qstr(c[0]) .. "   " ..
    ARROW .. "   the point (0, " .. qstr(c[0]) .. ")")

  local fac = ENG.factorPoly(poly)
  addStep(S, "work", "Factored form", ENG.factorStr(fac, v, disp),
    ENG.isFactored(fac) and "Each factor gives an x-intercept."
                        or "Prime over the rationals.")

  local roots = ENG.rootsOf(c, v)
  local realParts, cxParts = {}, {}
  for _, r in ipairs(roots) do
    local line = v .. " = " .. r.exact
    if r.mult > 1 then line = line .. " (multiplicity " .. intStr(r.mult) .. ")" end
    if r.kind == "complex" then cxParts[#cxParts + 1] = line
    else
      if r.num and (r.q == nil or not qisint(r.q)) then
        line = line .. " " .. APPROX .. " " .. decStr(r.num, 6)
      end
      realParts[#realParts + 1] = line
    end
  end
  addStep(S, "work", "Real zeros (x-intercepts)",
    #realParts > 0 and table.concat(realParts, "\n") or "none - the graph never crosses the x-axis")
  if #cxParts > 0 then
    addStep(S, "note", "Complex zeros", table.concat(cxParts, "\n"),
      "These do not appear on a real graph.")
  end

  if deg == 1 then
    addStep(S, "note", "Straight line",
      "slope = " .. qstr(c[1]) .. ",  y-intercept = " .. qstr(c[0]) ..
      ",  so  y = " .. pstr(poly, v, disp) .. " in slope-intercept form.")
  elseif deg == 2 then
    local a, b, cc = c[2], c[1], c[0]
    local h = -b / (TWO * a)
    local kk = pevalQ(poly, { [v] = h })
    local up = a.n > 0
    addStep(S, "work", "Vertex",
      v .. " = -b/(2a) = " .. qstr(h) .. ",   f(" .. qstr(h) .. ") = " .. qstr(kk),
      "Vertex (" .. qstr(h) .. ", " .. qstr(kk) .. ")   " ..
      APPROX .. " (" .. decStr(qnum(h), 4) .. ", " .. decStr(qnum(kk), 4) .. ")")
    addStep(S, "note", "Axis of symmetry and direction",
      "Axis: " .. v .. " = " .. qstr(h) .. "\nOpens " .. (up and "upward" or "downward") ..
      " (a " .. (up and "> 0" or "< 0") .. "), so the vertex is a " ..
      (up and "minimum" or "maximum") .. " of " .. qstr(kk) .. ".")
    local vertexForm = qstrCoef(a) .. "(" .. v ..
      (h.n > 0 and " - " or " + ") .. qstr(qabs(h)) .. ")^2" ..
      (kk.n < 0 and " - " or " + ") .. qstr(qabs(kk))
    if a == ONE then vertexForm = vertexForm:gsub("^1", "") end
    addStep(S, "work", "Vertex form (completing the square)", "f(" .. v .. ") = " .. vertexForm)
    local d = b * b - q(4) * a * cc
    addStep(S, "note", "Discriminant", "D = b^2 - 4ac = " .. qstr(d) .. "   " .. ARROW .. "   " ..
      (d.n > 0 and "two distinct real roots" or (qz(d) and "one repeated real root"
                                                      or "no real roots (two complex ones)")))
  end

  local leadPos = c[deg].n > 0
  local even = (deg % 2 == 0)
  local rightUp = leadPos
  local leftUp = even and leadPos or not leadPos
  addStep(S, "note", "End behaviour",
    "As " .. v .. " " .. ARROW .. " +inf,  f(" .. v .. ") " .. ARROW .. " " ..
    (rightUp and "+inf" or "-inf") .. "\nAs " .. v .. " " .. ARROW .. " -inf,  f(" ..
    v .. ") " .. ARROW .. " " .. (leftUp and "+inf" or "-inf"),
    "Driven by the leading term " .. termBody(c[deg], { [v] = deg }, v) .. ".")

  local summary = {}
  for _, r in ipairs(realParts) do summary[#summary + 1] = r end
  if #summary == 0 then summary[1] = "no real zeros" end
  return { ok = true, steps = S.list, answers = summary }
end

-- ============================================================================
-- 18. USER INTERFACE
-- ============================================================================

-- "solve for h" / "..., h" both name the variable to isolate.
function ENG.doSolveFor(text)
  local body, want = text:match("^(.-)%s+for%s+([%a])%s*$")
  if not body then
    body, want = text:match("^(.-)%s*,%s*([%a])%s*$")
  end
  if not body then body = text end
  if want then want = want:lower() end
  return ENG.solve(body, { variable = want })
end

local MODES = {
  { id = "solve",   name = "Solve equation",    run = ENG.solve,
    hint = "3x + 7 = 22",
    blurb = "Full worked solution of an equation in one variable.",
    examples = { "3x + 7 = 22", "2(x+3) = 5x - 4", "x^2 - 5x + 6 = 0",
                 "x^2 + x - 1 = 0", "x^3 - 6x^2 + 11x - 6 = 0",
                 "1/x + 1/(x+1) = 1/2", "sqrt(x+4) = x - 2", "abs(2x-3) = 7",
                 "x/2 + 1/3 = 5/6", "x^4 - 5x^2 + 4 = 0" } },
  { id = "factor",  name = "Factor",            run = ENG.doFactor,
    hint = "x^2 - 5x + 6",
    blurb = "Factor a polynomial completely over the rationals.",
    examples = { "x^2 - 5x + 6", "6x^2 + 11x + 3", "x^3 - 8", "x^4 - 16",
                 "2x^3 - 4x^2 - 6x", "x^2 + 2xy + y^2", "xy + x + y + 1",
                 "12x^2y - 27y^3", "x^4 + 5x^2 + 6" } },
  { id = "expand",  name = "Expand / simplify", run = ENG.doExpand,
    hint = "(x+3)(x-2)",
    blurb = "Multiply everything out and collect like terms.",
    examples = { "(x+3)(x-2)", "(2x-1)^3", "(x+y)^2", "3(x-1) + 2(x+4)",
                 "(x+1)(x-1)(x+2)", "(a+b)^4" } },
  { id = "solvefor", name = "Solve for variable", run = ENG.doSolveFor,
    hint = "a = 1/2 b h  for h",
    blurb = "Rearrange a formula to isolate one letter.",
    examples = { "a = 1/2*b*h for h", "v = pi*r^2*h for h", "f = 9/5*c + 32 for c",
                 "2x + 3y = 12 for y", "p = 2l + 2w for w", "e = m*c^2 for m" } },
  { id = "eval",    name = "Evaluate",          run = ENG.doEvaluate,
    hint = "x^2 + 3x - 1, x = 2",
    blurb = "Substitute values and work out the number.",
    examples = { "x^2 + 3x - 1, x = 2", "2x + y, x = 1, y = 3",
                 "x^2 = 4, x = -2", "(x-1)/(x+2), x = 5", "sqrt(x) + x^2, x = 9" } },
  { id = "system",  name = "System of 2 eqns",  run = ENG.doSystem,
    hint = "2x + y = 7, x - y = 2",
    blurb = "Two equations, two unknowns, by elimination or substitution.",
    examples = { "2x + y = 7, x - y = 2", "3x + 2y = 16, 5x - y = 9",
                 "x + y = 3, 2x + 2y = 7", "y = x^2, y = x + 2",
                 "x + y = 10, x - y = 4" } },
  { id = "analyze", name = "Analyze polynomial", run = ENG.doAnalyze,
    hint = "x^2 - 4x + 1",
    blurb = "Degree, zeros, vertex, intercepts and end behaviour.",
    examples = { "x^2 - 4x + 1", "2x^2 + 8x + 6", "x^3 - x", "3x + 6",
                 "x^4 - 5x^2 + 4", "-x^2 + 6x - 5" } },
}

local C = {
  bg        = { 246, 247, 250 },
  panel     = { 255, 255, 255 },
  header    = { 38,  70,  124 },
  headerTx  = { 255, 255, 255 },
  text      = { 22,  26,  34  },
  dim       = { 112, 120, 134 },
  accent    = { 12,  104, 176 },
  rule      = { 216, 221, 230 },
  chip      = { 232, 237, 246 },
  chipEdge  = { 150, 166, 194 },
  sel       = { 38,  70,  124 },
  selTx     = { 255, 255, 255 },
  ansBg     = { 226, 244, 231 },
  ansEdge   = { 120, 186, 140 },
  ansTx     = { 17,  106, 52  },
  warnBg    = { 253, 236, 226 },
  warnEdge  = { 226, 150, 110 },
  warnTx    = { 172, 62,  18  },
  errTx     = { 190, 40,  40  },
  checkTx   = { 84,  104, 140 },
  caret     = { 20,  100, 190 },
}

local W, H = 318, 212

local app = {
  screen   = "input",   -- input | menu | examples | result | help
  mode     = 1,
  text     = "",
  caret    = 0,
  inScroll = 0,
  menuSel  = 1,
  exSel    = 1,
  result   = nil,
  error    = nil,
  lines    = nil,       -- laid-out render lines for the scroll pane
  layoutW  = -1,
  scroll   = 0,
  history  = {},
  histPos  = 0,
  busy     = false,
  lastEvent = "none yet",
  eventCount = 0,
  kpRow    = 1,
  kpCol    = 1,
  focus    = "entry",   -- "mode" (the drop-down) or "entry" (the text line)
  menuTop  = 1,         -- first visible row of the open drop-down
}

-- On-screen keyboard. The whole program has to be usable with nothing but the
-- arrow keys and ENTER, because some hosts hand a script its arrow keys
-- without ever delivering on.charIn. Each cell is { label, action }; with no
-- action the label is inserted literally.
local KEYPAD = {
  { { "7" }, { "8" }, { "9" }, { "(" }, { ")" }, { "^" } },
  { { "4" }, { "5" }, { "6" }, { "+" }, { "-" }, { "*" } },
  { { "1" }, { "2" }, { "3" }, { "/" }, { "=" }, { "." } },
  { { "0" }, { "x" }, { "y" }, { "z" }, { "a" }, { "b" } },
  { { "sqrt(" }, { "abs(" }, { "pi" }, { "," }, { "_", "space" }, { "DEL", "del" } },
  { { "CLEAR", "clear" }, { "SOLVE", "run" }, { "CLOSE", "back" } },
}

local UI = {}

local function setColor(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

-- ---- UTF-8 aware string handling -------------------------------------------

local function isCont(b) return b and b >= 128 and b < 192 end

local function utf8Prev(s, i)
  if i <= 0 then return 0 end
  i = i - 1
  while i > 0 and isCont(s:byte(i + 1)) do i = i - 1 end
  return i
end

local function utf8Next(s, i)
  local n = #s
  if i >= n then return n end
  i = i + 1
  while i < n and isCont(s:byte(i + 1)) do i = i + 1 end
  return i
end

-- Splits a string into a list of whole UTF-8 characters.
local function utf8Chars(s)
  local out, i = {}, 1
  while i <= #s do
    local j = i + 1
    while j <= #s and isCont(s:byte(j)) do j = j + 1 end
    out[#out + 1] = s:sub(i, j - 1)
    i = j
  end
  return out
end

-- ---- text layout ------------------------------------------------------------

-- Greedy word wrap that also hard-splits words wider than the line.
local function wrapText(gc, text, maxw)
  local out = {}
  for rawLine in (text .. "\n"):gmatch("([^\n]*)\n") do
    if rawLine == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in rawLine:gmatch("%S+") do
        local trial = (line == "") and word or (line .. " " .. word)
        if gc:getStringWidth(trial) <= maxw then
          line = trial
        else
          if line ~= "" then out[#out + 1] = line; line = "" end
          if gc:getStringWidth(word) <= maxw then
            line = word
          else
            -- break the long token character by character
            local piece = ""
            for _, ch in ipairs(utf8Chars(word)) do
              if gc:getStringWidth(piece .. ch) <= maxw then
                piece = piece .. ch
              else
                out[#out + 1] = piece
                piece = ch
              end
            end
            line = piece
          end
        end
      end
      if line ~= "" then out[#out + 1] = line end
    end
  end
  if #out == 0 then out[1] = "" end
  return out
end

local STYLE = {
  head   = { font = { "sansserif", "b", 9  }, color = C.accent,   h = 13, indent = 0  },
  title  = { font = { "sansserif", "b", 9  }, color = C.accent,   h = 13, indent = 0  },
  body   = { font = { "sansserif", "r", 9  }, color = C.text,     h = 12, indent = 10 },
  math   = { font = { "sansserif", "b", 10 }, color = C.text,     h = 14, indent = 10 },
  note   = { font = { "sansserif", "r", 8  }, color = C.dim,      h = 11, indent = 10 },
  answer = { font = { "sansserif", "b", 10 }, color = C.ansTx,    h = 14, indent = 10 },
  warn   = { font = { "sansserif", "r", 9  }, color = C.warnTx,   h = 12, indent = 10 },
  check  = { font = { "sansserif", "r", 8  }, color = C.checkTx,  h = 11, indent = 10 },
  rule   = { font = { "sansserif", "r", 8  }, color = C.rule,     h = 7,  indent = 0  },
}

local function pushLines(out, gc, style, text, width, bullet)
  local st = STYLE[style]
  gc:setFont(st.font[1], st.font[2], st.font[3])
  local avail = width - st.indent - (bullet and gc:getStringWidth(bullet) or 0)
  if avail < 20 then avail = 20 end
  local first = true
  for _, l in ipairs(wrapText(gc, text, avail)) do
    out[#out + 1] = {
      style = style,
      text = (first and bullet) and (bullet .. l) or l,
      indent = st.indent + ((first and bullet) and 0 or (bullet and gc:getStringWidth(bullet) or 0)),
    }
    first = false
  end
end

-- Turns a solver result into the flat list of drawable lines.
function UI.layoutResult(gc, res, width)
  local out = {}
  local stepNo = 0
  for _, s in ipairs(res.steps or {}) do
    if s.kind ~= "given" then out[#out + 1] = { style = "rule", text = "", indent = 0 } end
    local label
    if s.kind == "work" or s.kind == "answer" then
      stepNo = stepNo + 1
      label = "Step " .. intStr(stepNo) .. ".  "
    elseif s.kind == "given" then
      label = ""
    elseif s.kind == "check" then
      label = "Check.  "
    elseif s.kind == "warn" then
      label = "! "
    else
      label = ""
    end
    pushLines(out, gc, "title", s.title or "", width, label ~= "" and label or nil)
    if s.body and s.body ~= "" then
      local style = "math"
      if s.kind == "answer" then style = "answer"
      elseif s.kind == "warn" then style = "warn"
      elseif s.kind == "check" then style = "check"
      elseif s.kind == "note" then style = "body" end
      pushLines(out, gc, style, s.body, width)
    end
    if s.note and s.note ~= "" then
      pushLines(out, gc, "note", s.note, width)
    end
  end
  return out
end

function UI.layoutHelp(gc, width)
  local out = {}
  local function head(t) pushLines(out, gc, "title", t, width) end
  local function body(t) pushLines(out, gc, "body", t, width) end
  local function note(t) pushLines(out, gc, "note", t, width) end

  head("What this does")
  body("Type an algebra problem, pick a mode from the drop-down, and get the full " ..
       "worked solution - every step with the reason for it - plus the answer.")
  out[#out + 1] = { style = "rule", text = "", indent = 0 }
  head("Keys")
  body("TAB  open the mode drop-down")
  body("ENTER  run the current mode")
  body("ESC  drop-down (from the entry line) / back (from a solution)")
  body("left / right  move the cursor")
  body("up / down  recall what you typed before (entry line)")
  body("up / down  scroll one line (solution)")
  body("left / right  scroll one page (solution)")
  body("DEL  delete the character before the cursor")
  out[#out + 1] = { style = "rule", text = "", indent = 0 }
  head("How to type maths")
  body("Powers: x^2, x^3      Roots: sqrt(x)  or  " .. SQRT_CH .. "x")
  body("Absolute value: abs(x-3)  or  |x-3|")
  body("Multiplying: 2x, 3(x+1) and (x+1)(x-2) all work - the * is optional.")
  body("Fractions: (x+1)/2 . Decimals like 0.25 become exact fractions.")
  body("pi is understood; two letters side by side means a product (xy = x times y).")
  note("Capital letters are read as lower case, so X and x are the same variable.")
  out[#out + 1] = { style = "rule", text = "", indent = 0 }
  head("Modes")
  for i, m in ipairs(MODES) do
    body(intStr(i) .. ".  " .. m.name .. " - " .. m.blurb)
    note("example:  " .. m.hint)
  end
  out[#out + 1] = { style = "rule", text = "", indent = 0 }
  head("How the answers are checked")
  body("The algebra runs on exact fractions, never decimals, so 1/3 stays 1/3. " ..
       "Every factorisation is multiplied back out and compared with what you typed, " ..
       "and every solution is substituted into the original equation before it is shown. " ..
       "Solutions that only appeared because both sides were squared, or that make a " ..
       "denominator zero, are listed separately as extraneous.")
  out[#out + 1] = { style = "rule", text = "", indent = 0 }
  head("When it hands over to the CAS")
  body("Trig, logs and exponentials have no general step-by-step method, so those go to " ..
       "the handheld's own CAS (and a numeric search from -30 to 30). Everything " ..
       "polynomial or rational is solved here, with steps.")
  return out
end

-- ---- chrome -----------------------------------------------------------------

local TRI_DOWN = "\226\150\188"

local function drawHeader(gc, title, right)
  setColor(gc, C.header)
  gc:fillRect(0, 0, W, 21)
  setColor(gc, C.headerTx)
  gc:setFont("sansserif", "b", 10)
  gc:drawString(title, 6, 4, "top")
  if right then
    gc:setFont("sansserif", "r", 8)
    local w = gc:getStringWidth(right)
    gc:drawString(right, W - 6 - w, 6, "top")
  end
  return 21
end

local function drawFooter(gc, text, right)
  setColor(gc, C.chip)
  gc:fillRect(0, H - 15, W, 15)
  setColor(gc, C.rule)
  gc:drawLine(0, H - 15, W, H - 15)
  setColor(gc, C.dim)
  gc:setFont("sansserif", "r", 7)
  gc:drawString(text, 5, H - 13, "top")
  if right then
    local w = gc:getStringWidth(right)
    gc:drawString(right, W - 5 - w, H - 13, "top")
  end
  return H - 15
end

-- The host can report a window taller than the area it actually shows, which
-- puts anything pinned to H (a bottom footer) out of sight. Key hints live
-- here instead, immediately below the header, where they cannot be cut off.
local function drawHintBar(gc, y, text, right)
  setColor(gc, C.chip)
  gc:fillRect(0, y, W, 13)
  setColor(gc, C.rule)
  gc:drawLine(0, y + 13, W, y + 13)
  setColor(gc, C.dim)
  gc:setFont("sansserif", "r", 7)
  gc:drawString(text, 5, y + 1, "top")
  if right then
    local w = gc:getStringWidth(right)
    if 5 + gc:getStringWidth(text) + 8 < W - 5 - w then
      gc:drawString(right, W - 5 - w, y + 1, "top")
    end
  end
  return y + 14
end

local function drawPane(gc, lines, top, bottom, scroll)
  local y = top + 2
  local shown = 0
  for i = scroll + 1, #lines do
    local ln = lines[i]
    local st = STYLE[ln.style] or STYLE.body
    if y + st.h > bottom then break end
    if ln.style == "rule" then
      setColor(gc, C.rule)
      gc:drawLine(6, y + 3, W - 8, y + 3)
    else
      gc:setFont(st.font[1], st.font[2], st.font[3])
      setColor(gc, st.color)
      gc:drawString(ln.text, 6 + ln.indent, y, "top")
    end
    y = y + st.h
    shown = shown + 1
  end
  -- scrollbar
  if #lines > shown and shown > 0 then
    local trackTop, trackH = top + 2, bottom - top - 4
    setColor(gc, C.rule)
    gc:fillRect(W - 4, trackTop, 3, trackH)
    local frac = shown / #lines
    local barH = trackH * frac
    if barH < 8 then barH = 8 end
    local pos = trackTop + (trackH - barH) * (scroll / math.max(1, #lines - shown))
    setColor(gc, C.chipEdge)
    gc:fillRect(W - 4, pos, 3, barH)
  end
  return shown
end

-- ---- screens ----------------------------------------------------------------

function UI.paintInput(gc)
  setColor(gc, C.bg); gc:fillRect(0, 0, W, H)
  local y = drawHeader(gc, "Step-by-Step Solver")
  y = drawHintBar(gc, y,
        (app.focus == "mode")
          and "ENTER open list   <- -> change mode   down to type"
          or  (app.text == "" and "type here   up = mode list   down = keyboard"
                               or "ENTER solve   up = mode list   DEL erase"),
        "keys " .. intStr(app.eventCount) .. ":" .. app.lastEvent) + 4
  local m = MODES[app.mode]

  gc:setFont("sansserif", "r", 8)
  setColor(gc, C.dim)
  gc:drawString("Mode", 6, y + 4, "top")
  local chipX = 6 + gc:getStringWidth("Mode") + 6
  local chipW = W - chipX - 6
  app.chipRect = { 0, y - 4, W, 27 }
  app.chipAnchor = { chipX, y, chipW, 19 }
  local modeFocused = (app.focus == "mode")
  setColor(gc, C.chip); gc:fillRect(chipX, y, chipW, 19)
  if modeFocused then
    setColor(gc, C.accent)
    gc:drawRect(chipX, y, chipW, 19)
    gc:drawRect(chipX + 1, y + 1, chipW - 2, 17)
  else
    setColor(gc, C.chipEdge); gc:drawRect(chipX, y, chipW, 19)
  end
  setColor(gc, C.header); gc:setFont("sansserif", "b", 9)
  gc:drawString(m.name, chipX + 6, y + 3, "top")
  setColor(gc, modeFocused and C.accent or C.chipEdge); gc:setFont("sansserif", "r", 8)
  gc:drawString(TRI_DOWN, chipX + chipW - 14, y + 4, "top")
  y = y + 25

  setColor(gc, C.dim); gc:setFont("sansserif", "r", 8)
  gc:drawString(m.blurb, 6, y, "top")
  y = y + 13

  local boxX, boxW, boxH = 6, W - 12, 26
  app.boxRect = { boxX, y, boxW, boxH }
  setColor(gc, C.panel); gc:fillRect(boxX, y, boxW, boxH)
  if app.focus == "entry" then
    setColor(gc, C.accent)
    gc:drawRect(boxX, y, boxW, boxH)
    gc:drawRect(boxX + 1, y + 1, boxW - 2, boxH - 2)
  else
    setColor(gc, C.chipEdge); gc:drawRect(boxX, y, boxW, boxH)
  end

  -- Long entries are handled by trimming the string to what fits, NOT by
  -- gc:clipRect. On a real handheld the clipped region came out blank -
  -- hint, text and caret all invisible - so nothing here may rely on it.
  gc:setFont("sansserif", "b", 11)
  local inner = boxW - 12
  local caretX = boxX + 6
  if app.text == "" then
    setColor(gc, C.dim); gc:setFont("sansserif", "r", 10)
    gc:drawString(m.hint, boxX + 6, y + 6, "top")
    gc:setFont("sansserif", "b", 11)
  else
    local before = app.text:sub(1, app.caret)
    local after = app.text:sub(app.caret + 1)
    -- drop characters from the left until the text before the caret fits
    while #before > 0 and gc:getStringWidth(before) > inner do
      before = before:sub(utf8Next(before, 0) + 1)
    end
    -- then fill whatever room is left with the text after the caret
    local room = inner - gc:getStringWidth(before)
    while #after > 0 and gc:getStringWidth(after) > room do
      after = after:sub(1, utf8Prev(after, #after))
    end
    setColor(gc, C.text)
    gc:drawString(before .. after, boxX + 6, y + 5, "top")
    caretX = boxX + 6 + gc:getStringWidth(before)
  end
  setColor(gc, C.caret)
  gc:fillRect(caretX, y + 4, 2, boxH - 9)
  y = y + boxH + 6

  if app.error then
    setColor(gc, C.warnBg); gc:fillRect(6, y, W - 12, 30)
    setColor(gc, C.warnEdge); gc:drawRect(6, y, W - 12, 30)
    setColor(gc, C.errTx); gc:setFont("sansserif", "r", 8)
    local i = 0
    for _, l in ipairs(wrapText(gc, app.error, W - 24)) do
      if i < 3 then gc:drawString(l, 11, y + 4 + i * 9, "top") end
      i = i + 1
    end
  elseif app.result and app.result.answers then
    setColor(gc, C.ansBg); gc:fillRect(6, y, W - 12, 30)
    setColor(gc, C.ansEdge); gc:drawRect(6, y, W - 12, 30)
    setColor(gc, C.dim); gc:setFont("sansserif", "r", 7)
    gc:drawString("last answer  (ENTER on a blank line to review)", 11, y + 2, "top")
    setColor(gc, C.ansTx); gc:setFont("sansserif", "b", 9)
    local joined = table.concat(app.result.answers, "   ")
    local lines = wrapText(gc, joined, W - 24)
    gc:drawString(lines[1] or "", 11, y + 13, "top")
    if #lines > 1 then
      gc:setFont("sansserif", "r", 7)
      gc:drawString((lines[2] or "") .. (#lines > 2 and " ..." or ""), 11, y + 23, "top")
    end
  end

  drawFooter(gc, "ENTER solve   ESC/TAB menu   <- -> mode when line is empty",
             "keys " .. intStr(app.eventCount) .. ":" .. app.lastEvent)
end

function UI.paintMenu(gc)
  UI.paintInput(gc)
  local rows = {}
  for i, m in ipairs(MODES) do rows[i] = m.name end
  rows[#rows + 1] = "On-screen keyboard"
  rows[#rows + 1] = "Examples for this mode"
  rows[#rows + 1] = "Help / how to type maths"
  app.menuRows = rows

  -- Drop down from the chip itself rather than floating in the middle, and
  -- size the list to the space actually below it so nothing is cut off on a
  -- host that over-reports its height.
  local anchor = app.chipAnchor or { 6, 46, W - 12, 19 }
  local px = anchor[1]
  local panelW = anchor[3]
  local py = anchor[2] + anchor[4] - 1
  local rowH = 15
  -- leave the footer band clear, or the last row is drawn over
  local room = (H - 22) - py
  if room > 150 then room = 150 end
  local fits = math.floor((room - 4) / rowH)
  if fits < 3 then fits = 3 end
  if fits > #rows then fits = #rows end

  if app.menuSel < app.menuTop then app.menuTop = app.menuSel end
  if app.menuSel > app.menuTop + fits - 1 then app.menuTop = app.menuSel - fits + 1 end
  if app.menuTop < 1 then app.menuTop = 1 end

  local panelH = rowH * fits + 4
  app.menuRect = { px, py, panelW, panelH, rowH }

  setColor(gc, C.panel); gc:fillRect(px, py, panelW, panelH)
  setColor(gc, C.accent); gc:drawRect(px, py, panelW, panelH)

  for slot = 0, fits - 1 do
    local i = app.menuTop + slot
    local label = rows[i]
    if label then
      local ry = py + 2 + slot * rowH
      if i == app.menuSel then
        setColor(gc, C.sel); gc:fillRect(px + 2, ry, panelW - 4, rowH)
        setColor(gc, C.selTx)
      else
        setColor(gc, C.text)
      end
      gc:setFont("sansserif", (i == app.menuSel) and "b" or "r", 9)
      local tag = (i <= #MODES) and (intStr(i) .. ".  ") or "     "
      gc:drawString(tag .. label, px + 6, ry + 1, "top")
    end
  end
  -- scroll marks when the list is longer than the space
  setColor(gc, C.chipEdge); gc:setFont("sansserif", "r", 7)
  if app.menuTop > 1 then
    gc:drawString("\226\150\178", px + panelW - 12, py + 1, "top")
  end
  if app.menuTop + fits - 1 < #rows then
    gc:drawString(TRI_DOWN, px + panelW - 12, py + panelH - 11, "top")
  end
  drawFooter(gc, "up/down choose   ENTER select   ESC close")
end

function UI.paintExamples(gc)
  setColor(gc, C.bg); gc:fillRect(0, 0, W, H)
  local m = MODES[app.mode]
  local list = UI.exampleList()
  local top = drawHeader(gc, "Examples - " .. m.name, intStr(app.exSel) .. "/" .. intStr(#list))
  local bottom = H - 15
  local rowH = 16
  local fits = math.floor((bottom - top - 4) / rowH)
  local first = 1
  if app.exSel > fits then first = app.exSel - fits + 1 end
  app.exFirst, app.exRowH, app.exTop = first, rowH, top + 2
  for i = first, math.min(#list, first + fits - 1) do
    local ry = top + 2 + (i - first) * rowH
    if i == app.exSel then
      setColor(gc, C.sel); gc:fillRect(4, ry, W - 8, rowH)
      setColor(gc, C.selTx)
    else
      setColor(gc, C.text)
    end
    gc:setFont("sansserif", (i == app.exSel) and "b" or "r", 9)
    gc:drawString(list[i], 10, ry + 2, "top")
  end
  drawFooter(gc, "up/down choose   ENTER load into the entry line   ESC back")
end

function UI.paintKeypad(gc)
  setColor(gc, C.bg); gc:fillRect(0, 0, W, H)
  local y = drawHeader(gc, "On-screen keyboard")
  y = drawHintBar(gc, y, "arrows move   ENTER press   ESC close",
        "keys " .. intStr(app.eventCount) .. ":" .. app.lastEvent) + 3

  -- what has been built so far
  setColor(gc, C.panel); gc:fillRect(6, y, W - 12, 22)
  setColor(gc, C.accent); gc:drawRect(6, y, W - 12, 22)
  gc:setFont("sansserif", "b", 10)
  local shown = app.text
  if shown == "" then
    setColor(gc, C.dim); gc:setFont("sansserif", "r", 9)
    gc:drawString(MODES[app.mode].hint, 12, y + 5, "top")
  else
    -- keep the tail visible when the expression is longer than the box
    while #shown > 0 and gc:getStringWidth(shown) > W - 28 do
      shown = shown:sub(2)
    end
    setColor(gc, C.text)
    gc:drawString(shown, 12, y + 4, "top")
    setColor(gc, C.caret)
    gc:fillRect(12 + gc:getStringWidth(shown) + 1, y + 4, 2, 14)
  end
  y = y + 26

  local cols = 6
  local cw = math.floor((W - 12) / cols)
  local ch = 17
  app.kpGeom = { x = 6, y = y, cw = cw, ch = ch }
  for r, row in ipairs(KEYPAD) do
    for c, cell in ipairs(row) do
      local cx = 6 + (c - 1) * cw
      local cy = y + (r - 1) * ch
      local wide = (#row < cols) and math.floor((W - 12) / #row) or cw
      if #row < cols then cx = 6 + (c - 1) * wide end
      local selected = (r == app.kpRow and c == app.kpCol)
      if selected then
        setColor(gc, C.sel); gc:fillRect(cx + 1, cy + 1, wide - 3, ch - 3)
        setColor(gc, C.selTx)
      else
        setColor(gc, C.panel); gc:fillRect(cx + 1, cy + 1, wide - 3, ch - 3)
        setColor(gc, C.chipEdge); gc:drawRect(cx + 1, cy + 1, wide - 3, ch - 3)
        setColor(gc, cell[2] and C.accent or C.text)
      end
      gc:setFont("sansserif", "b", (#cell[1] > 3) and 8 or 10)
      local label = (cell[2] == "space") and "space" or cell[1]
      local tw = gc:getStringWidth(label)
      gc:drawString(label, cx + math.floor((wide - tw) / 2), cy + 3, "top")
    end
  end
end

function UI.keypadPress()
  local row = KEYPAD[app.kpRow]
  local cell = row and row[app.kpCol]
  if not cell then return end
  local action = cell[2]
  if action == nil then
    UI.insert(cell[1])
  elseif action == "space" then
    UI.insert(" ")
  elseif action == "del" then
    if app.caret > 0 then
      local prev = utf8Prev(app.text, app.caret)
      app.text = app.text:sub(1, prev) .. app.text:sub(app.caret + 1)
      app.caret = prev
    end
  elseif action == "clear" then
    app.text, app.caret, app.inScroll = "", 0, 0
  elseif action == "run" then
    UI.run()
  elseif action == "back" then
    app.screen = "input"
  end
end

function UI.keypadMove(key)
  if key == "up" then
    app.kpRow = (app.kpRow - 2) % #KEYPAD + 1
  elseif key == "down" then
    app.kpRow = app.kpRow % #KEYPAD + 1
  elseif key == "left" then
    app.kpCol = app.kpCol - 1
  elseif key == "right" then
    app.kpCol = app.kpCol + 1
  end
  local n = #KEYPAD[app.kpRow]
  if app.kpCol < 1 then app.kpCol = n end
  if app.kpCol > n then app.kpCol = 1 end
end

function UI.paintPane(gc, title, right, footer)
  setColor(gc, C.bg); gc:fillRect(0, 0, W, H)
  local top = drawHeader(gc, title, right)
  top = drawHintBar(gc, top, footer or "")
  local bottom = H - 15

  if app.screen == "result" and app.result and app.result.answers then
    gc:setFont("sansserif", "b", 10)
    local joined = table.concat(app.result.answers, "    ")
    local lines = wrapText(gc, joined, W - 20)
    local nshow = math.min(#lines, 3)
    local bh = 8 + nshow * 12
    setColor(gc, C.ansBg); gc:fillRect(0, top, W, bh)
    setColor(gc, C.ansEdge); gc:drawLine(0, top + bh, W, top + bh)
    setColor(gc, C.ansTx)
    for i = 1, nshow do
      gc:drawString(lines[i] .. ((i == 3 and #lines > 3) and " ..." or ""), 8, top + 3 + (i - 1) * 12, "top")
    end
    top = top + bh + 1
  end

  app.paneTop, app.paneBottom = top, bottom
  app.visible = drawPane(gc, app.lines or {}, top, bottom, app.scroll)
  drawFooter(gc, footer)
end

function UI.ensureLayout(gc)
  local width = W - 14
  if app.lines and app.layoutW == width then return end
  if app.screen == "help" then
    app.lines = UI.layoutHelp(gc, width)
  elseif app.result then
    app.lines = UI.layoutResult(gc, app.result, width)
  else
    app.lines = {}
  end
  app.layoutW = width
  if app.scroll > #app.lines - 1 then app.scroll = math.max(0, #app.lines - 1) end
end

-- ---- actions ----------------------------------------------------------------

function UI.run()
  local m = MODES[app.mode]
  local text = app.text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    -- Nothing to solve: open the on-screen keyboard rather than complain.
    -- On a host that never delivers on.charIn this is the only way in.
    UI.openKeypad()
    return
  end
  app.error = nil
  local ok, res = pcall(m.run, text)
  if not ok then
    if type(res) == "table" and res.eqsolver then
      app.error = res.msg or "That input could not be read."
    else
      app.error = "Unexpected problem: " .. tostring(res)
    end
    app.result = nil
    return
  end
  if not res or not res.ok then
    app.error = (res and res.error) or "That could not be worked out."
    app.result = nil
    return
  end
  app.result = res
  app.lines, app.layoutW, app.scroll = nil, -1, 0
  app.screen = "result"
  if app.history[#app.history] ~= text then
    app.history[#app.history + 1] = text
    while #app.history > 15 do table.remove(app.history, 1) end
  end
  app.histPos = #app.history + 1
end

function UI.insert(s)
  app.text = app.text:sub(1, app.caret) .. s .. app.text:sub(app.caret + 1)
  app.caret = app.caret + #s
  app.error = nil
end

function UI.openMenu()
  app.menuSel = app.mode
  app.menuTop = 1
  app.focus = "mode"
  app.screen = "menu"
end

-- The Examples list also carries what you entered earlier, most recent first,
-- now that the arrow keys drive the drop-down instead of a history ring.
function UI.exampleList()
  local out = {}
  for _, ex in ipairs(MODES[app.mode].examples) do out[#out + 1] = ex end
  for i = #app.history, 1, -1 do
    local h = app.history[i]
    local dup = false
    for _, e in ipairs(out) do
      if e == h then dup = true; break end
    end
    if not dup then out[#out + 1] = h end
  end
  return out
end

function UI.openKeypad()
  app.kpRow, app.kpCol = 1, 1
  app.error = nil
  app.screen = "keys"
end

function UI.chooseMenu()
  local n = #MODES
  if app.menuSel <= n then
    app.mode = app.menuSel
    app.screen = "input"
    app.focus = "entry"
    app.error = nil
  elseif app.menuSel == n + 1 then
    UI.openKeypad()
  elseif app.menuSel == n + 2 then
    app.exSel = 1
    app.screen = "examples"
  else
    app.screen = "help"
    app.lines, app.layoutW, app.scroll = nil, -1, 0
  end
end

function UI.scrollBy(delta)
  local maxScroll = math.max(0, #(app.lines or {}) - math.max(1, app.visible or 1))
  app.scroll = app.scroll + delta
  if app.scroll < 0 then app.scroll = 0 end
  if app.scroll > maxScroll then app.scroll = maxScroll end
end

-- ---- event dispatch ---------------------------------------------------------

local function errText(e)
  if type(e) == "table" then return e.msg or e.code or "internal error" end
  return tostring(e)
end

local function refresh() platform.window:invalidate() end

-- The footer shows the last event and a running count. If those never move
-- while you press keys, the script is not receiving them (a focus problem in
-- the host software) rather than mishandling them.
local function logEvent(name)
  app.lastEvent = name
  app.eventCount = app.eventCount + 1
end

function on.resize(w, h)
  if type(w) == "number" and w > 40 then W = w end
  if type(h) == "number" and h > 40 then H = h end
  app.lines, app.layoutW = nil, -1
  refresh()
end

function on.paint(gc)
  local ok, err = pcall(function()
    if app.screen == "result" or app.screen == "help" then UI.ensureLayout(gc) end
    if app.screen == "input" then
      UI.paintInput(gc)
    elseif app.screen == "menu" then
      UI.paintMenu(gc)
    elseif app.screen == "examples" then
      UI.paintExamples(gc)
    elseif app.screen == "keys" then
      UI.paintKeypad(gc)
    elseif app.screen == "result" then
      local total = math.max(1, #(app.lines or {}))
      UI.paintPane(gc, MODES[app.mode].name,
        intStr(math.min(app.scroll + 1, total)) .. "/" .. intStr(total),
        "up/down scroll   <- -> page   ENTER edit   ESC back")
    elseif app.screen == "help" then
      UI.paintPane(gc, "Help", nil, "up/down scroll   <- -> page   ESC back")
    else
      app.screen = "input"
      UI.paintInput(gc)
    end
  end)
  if not ok then
    setColor(gc, C.bg); gc:fillRect(0, 0, W, H)
    setColor(gc, C.errTx); gc:setFont("sansserif", "r", 9)
    gc:drawString("Could not draw this screen:", 6, 24, "top")
    gc:setFont("sansserif", "r", 8)
    gc:drawString(errText(err):sub(1, 60), 6, 40, "top")
    gc:drawString("Press ESC to go back.", 6, 56, "top")
  end
end

function on.charIn(ch)
  logEvent("char " .. tostring(ch))
  if type(ch) ~= "string" or ch == "" then return end
  if app.screen == "input" then
    UI.insert(ch)
  elseif app.screen == "menu" then
    local d = tonumber(ch)
    if d and d >= 1 and d <= #MODES then
      app.menuSel = d
      UI.chooseMenu()
    end
  elseif app.screen == "examples" then
    local d = tonumber(ch)
    local ex = UI.exampleList()
    if d and d >= 1 and d <= #ex then app.exSel = d end
  elseif app.screen == "keys" then
    UI.insert(ch)
  elseif app.screen == "result" or app.screen == "help" then
    if ch == "+" then UI.scrollBy(-1) elseif ch == "-" then UI.scrollBy(1) end
  end
  refresh()
end

function on.enterKey()
  logEvent("enter")
  if app.screen == "input" then
    if app.focus == "mode" then
      UI.openMenu()
    else
      UI.run()
    end
  elseif app.screen == "keys" then
    UI.keypadPress()
  elseif app.screen == "menu" then
    UI.chooseMenu()
  elseif app.screen == "examples" then
    local ex = UI.exampleList()[app.exSel]
    if ex then
      app.text = ex
      app.caret = #ex
      app.inScroll = 0
      app.error = nil
    end
    app.focus = "entry"
    app.screen = "input"
  elseif app.screen == "result" or app.screen == "help" then
    app.screen = "input"
  end
  refresh()
end

function on.escapeKey()
  logEvent("esc")
  if app.screen == "input" then
    UI.openMenu()
  elseif app.screen == "menu" then
    app.screen = "input"
  else
    app.screen = "input"
  end
  refresh()
end

function on.tabKey()
  logEvent("tab")
  UI.openMenu()
  refresh()
end

function on.backtabKey()
  logEvent("backtab")
  UI.openMenu()
  refresh()
end

function on.backspaceKey()
  logEvent("del")
  if app.screen == "input" and app.caret > 0 then
    local prev = utf8Prev(app.text, app.caret)
    app.text = app.text:sub(1, prev) .. app.text:sub(app.caret + 1)
    app.caret = prev
    app.error = nil
  end
  refresh()
end

function on.deleteKey()
  logEvent("fwd-del")
  if app.screen == "input" and app.caret < #app.text then
    local nxt = utf8Next(app.text, app.caret)
    app.text = app.text:sub(1, app.caret) .. app.text:sub(nxt + 1)
    app.error = nil
  end
  refresh()
end

function on.clearKey()
  logEvent("clear")
  if app.screen == "input" then
    app.text, app.caret, app.inScroll, app.error = "", 0, 0, nil
  end
  refresh()
end

function on.arrowKey(key)
  logEvent(tostring(key))
  if app.screen == "input" then
    if app.focus == "mode" then
      -- the drop-down is selected: left/right step through the modes,
      -- down moves on to the entry line
      if key == "left" then
        app.mode = (app.mode - 2) % #MODES + 1
      elseif key == "right" then
        app.mode = app.mode % #MODES + 1
      else
        app.focus = "entry"
      end
    elseif key == "left" then
      -- nothing to move the caret through on an empty line, so step the mode
      if app.text == "" then
        app.mode = (app.mode - 2) % #MODES + 1
      else
        app.caret = utf8Prev(app.text, app.caret)
      end
    elseif key == "right" then
      if app.text == "" then
        app.mode = app.mode % #MODES + 1
      else
        app.caret = utf8Next(app.text, app.caret)
      end
    elseif key == "up" then
      app.focus = "mode"
    elseif key == "down" then
      UI.openKeypad()
    end
  elseif app.screen == "menu" then
    local n = #(app.menuRows or MODES)
    if key == "up" then app.menuSel = (app.menuSel - 2) % n + 1 end
    if key == "down" then app.menuSel = app.menuSel % n + 1 end
    if key == "left" then app.screen = "input" end
  elseif app.screen == "keys" then
    UI.keypadMove(key)
  elseif app.screen == "examples" then
    local n = #UI.exampleList()
    if key == "up" then app.exSel = (app.exSel - 2) % n + 1 end
    if key == "down" then app.exSel = app.exSel % n + 1 end
  elseif app.screen == "result" or app.screen == "help" then
    local page = math.max(1, (app.visible or 8) - 1)
    if key == "up" then UI.scrollBy(-1)
    elseif key == "down" then UI.scrollBy(1)
    elseif key == "left" then UI.scrollBy(-page)
    elseif key == "right" then UI.scrollBy(page) end
  end
  refresh()
end

local function inRect(r, x, y)
  return r and x >= r[1] and x <= r[1] + r[3] and y >= r[2] and y <= r[2] + r[4]
end

function on.mouseDown(x, y)
  logEvent("click")
  if app.screen == "input" then
    if inRect(app.chipRect, x, y) then
      UI.openMenu()
    elseif inRect(app.boxRect, x, y) then
      app.focus = "entry"
      -- place the caret at the clicked character when measuring is available
      local target = x - app.boxRect[1] - 6 + app.inScroll
      local placed = pcall(function()
        platform.withGC(function(gc)
          gc:setFont("sansserif", "b", 11)
          local pos, best = 0, 0
          for _, ch in ipairs(utf8Chars(app.text)) do
            local nextPos = pos + #ch
            if gc:getStringWidth(app.text:sub(1, nextPos)) <= target then
              best = nextPos
            end
            pos = nextPos
          end
          app.caret = best
        end)
      end)
      if not placed then app.caret = #app.text end
    end
  elseif app.screen == "menu" then
    local r = app.menuRect
    if r then
      local idx = math.floor((y - r[2] - 18) / r[5]) + 1
      if idx >= 1 and idx <= #(app.menuRows or {}) then
        app.menuSel = idx
        UI.chooseMenu()
      elseif not inRect({ r[1], r[2], r[3], r[4] }, x, y) then
        app.screen = "input"
      end
    end
  elseif app.screen == "examples" then
    local idx = math.floor((y - (app.exTop or 0)) / (app.exRowH or 16)) + (app.exFirst or 1)
    local ex = UI.exampleList()
    if idx >= 1 and idx <= #ex then
      app.exSel = idx
      app.text = ex[idx]
      app.caret = #app.text
      app.focus = "entry"
      app.screen = "input"
    end
  elseif app.screen == "keys" then
    local g = app.kpGeom
    if g and y >= g.y then
      local r = math.floor((y - g.y) / g.ch) + 1
      if KEYPAD[r] then
        local wide = (#KEYPAD[r] < 6) and math.floor((W - 12) / #KEYPAD[r]) or g.cw
        local c = math.floor((x - g.x) / wide) + 1
        if KEYPAD[r][c] then
          app.kpRow, app.kpCol = r, c
          UI.keypadPress()
        end
      end
    end
  elseif app.screen == "result" or app.screen == "help" then
    if y < H / 2 then UI.scrollBy(-3) else UI.scrollBy(3) end
  end
  refresh()
end

function on.help()
  app.screen = "help"
  app.lines, app.layoutW, app.scroll = nil, -1, 0
  refresh()
end

function on.save()
  return { mode = app.mode, text = app.text, history = app.history }
end

function on.restore(state)
  pcall(function()
    if type(state) ~= "table" then return end
    if type(state.mode) == "number" and MODES[state.mode] then app.mode = state.mode end
    if type(state.text) == "string" then
      app.text = state.text
      app.caret = #app.text
    end
    if type(state.history) == "table" then
      app.history = state.history
      app.histPos = #app.history + 1
    end
  end)
end

-- ---- native Nspire menu ------------------------------------------------------

-- The handheld's own menu (the `menu` key, or Document Tools in the computer
-- software) is registered with every mode. It is the most reliable control
-- path: TAB and ESC can be claimed by the host for moving between page
-- objects, but this menu belongs to the script.
local function registerMenu()
  local modeMenu = { "Mode" }
  for i, m in ipairs(MODES) do
    modeMenu[#modeMenu + 1] = { m.name, function()
      app.mode = i
      app.screen = "input"
      app.error = nil
      logEvent("menu")
      refresh()
    end }
  end

  local actions = { "Solver",
    { "Solve it now", function() logEvent("menu"); UI.run(); refresh() end },
    { "On-screen keyboard", function() logEvent("menu"); UI.openKeypad(); refresh() end },
    { "Examples for this mode", function()
        logEvent("menu"); app.exSel = 1; app.screen = "examples"; refresh()
      end },
    { "Clear the entry line", function()
        logEvent("menu")
        app.text, app.caret, app.inScroll, app.error = "", 0, 0, nil
        app.screen = "input"
        refresh()
      end },
    { "Help", function() logEvent("menu"); on.help() end },
  }

  toolpalette.register({ modeMenu, actions })
end

-- toolpalette exists on every OS that runs Lua scripts, but never let a
-- missing one stop the program from starting.
pcall(registerMenu)

-- ---- boot -------------------------------------------------------------------

pcall(function()
  local w, h = platform.window:width(), platform.window:height()
  if type(w) == "number" and w > 40 then W = w end
  if type(h) == "number" and h > 40 then H = h end
end)

-- Test hook: tests/probe.lua and tests/run_tests.lua set this global before
-- loading the file so the algebra engine can be exercised directly. It is nil
-- on a calculator, where nothing is exported.
if rawget(_G, "__eqsolver_test") then
  _G.__eqsolver_test.ENG = ENG
  _G.__eqsolver_test.UI = UI
  _G.__eqsolver_test.MODES = MODES
  _G.__eqsolver_test.KEYPAD = KEYPAD
  _G.__eqsolver_test.app = app
  _G.__eqsolver_test.parseOne = parseOne
  _G.__eqsolver_test.wrapText = wrapText
  _G.__eqsolver_test.astStr = astStr
  _G.__eqsolver_test.astNum = astNum
  _G.__eqsolver_test.newCtx = newCtx
  _G.__eqsolver_test.astToR = astToR
  _G.__eqsolver_test.pstr = pstr
  _G.__eqsolver_test.pisconst = pisconst
  _G.__eqsolver_test.pconstval = pconstval
  _G.__eqsolver_test.pscale = pscale
  _G.__eqsolver_test.pvars = pvars
  _G.__eqsolver_test.uniCoeffs = uniCoeffs
  _G.__eqsolver_test.ONE = ONE
  _G.__eqsolver_test.q = q
  _G.__eqsolver_test.qstr = qstr
  _G.__eqsolver_test.qnum = qnum
  _G.__eqsolver_test.setW = function(w, h) W, H = w, h end
end
