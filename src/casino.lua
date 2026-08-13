-- ============================================================================
-- TI-NSPIRE CX II CASINO
-- A multi-game casino (Roulette, Blackjack, Slot Machine) with a shared
-- bankroll, built as a native Lua "Script Editor" object for TI-Nspire.
--
-- CONTROLS ARE 100% KEYBOARD DRIVEN so this works identically on Clickpad
-- and Touchpad keypads. See README.md for install + full control reference.
-- ============================================================================

platform.apilevel = '2.5'

-- ----------------------------------------------------------------------------
-- Global state
-- ----------------------------------------------------------------------------

local W, H = 318, 212
local screen = "lobby"
local timerRunning = false

local balance = 1000
local chipValues = { 1, 5, 25, 100, 500 }

local screens = {} -- filled in below: screens.lobby, screens.roulette, ...

-- ----------------------------------------------------------------------------
-- Palette + small drawing helpers
-- ----------------------------------------------------------------------------

local COLOR = {
  felt      = { 10, 84, 46 },
  feltDark  = { 6, 58, 32 },
  bar       = { 12, 40, 24 },
  gold      = { 218, 180, 60 },
  white     = { 255, 255, 255 },
  cream     = { 232, 224, 200 },
  black     = { 18, 18, 18 },
  red       = { 190, 24, 24 },
  redBright = { 226, 40, 40 },
  green     = { 20, 130, 60 },
  gray      = { 120, 120, 120 },
  navy      = { 20, 40, 90 },
  win       = { 90, 220, 110 },
  lose      = { 230, 90, 90 },
}

local function setColor(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

local function fmtMoney(n)
  n = math.floor(n + 0.5)
  return "$" .. tostring(n)
end

local function centerText(gc, text, cx, y)
  local w = gc:getStringWidth(text)
  gc:drawString(text, cx - w / 2, y, "top")
end

local function rightText(gc, text, rx, y)
  local w = gc:getStringWidth(text)
  gc:drawString(text, rx - w, y, "top")
end

local function fillCircle(gc, cx, cy, r)
  gc:fillArc(cx - r, cy - r, 2 * r, 2 * r, 0, 360)
end

-- Shared chrome: felt background + title bar + footer legend.
-- Returns the y-coordinate where screen-specific content should start.
local function drawChrome(gc, title, footer)
  setColor(gc, COLOR.felt)
  gc:fillRect(0, 0, W, H)
  -- subtle darker felt border
  setColor(gc, COLOR.feltDark)
  gc:drawRect(1, 1, W - 2, H - 2)

  -- top bar
  setColor(gc, COLOR.bar)
  gc:fillRect(0, 0, W, 20)
  setColor(gc, COLOR.gold)
  gc:setFont("sansserif", "b", 10)
  gc:drawString(title, 4, 4, "top")
  gc:setFont("sansserif", "r", 9)
  setColor(gc, COLOR.cream)
  rightText(gc, "Bank " .. fmtMoney(balance), W - 4, 5)

  -- footer bar
  if footer then
    setColor(gc, COLOR.bar)
    gc:fillRect(0, H - 14, W, 14)
    setColor(gc, COLOR.cream)
    gc:setFont("sansserif", "r", 7)
    gc:drawString(footer, 3, H - 12, "top")
  end

  return 22
end

-- ----------------------------------------------------------------------------
-- Timer management (single shared timer drives whichever screen is animating)
-- ----------------------------------------------------------------------------

local function startTimer()
  if not timerRunning then
    timerRunning = true
    timer.start(0.04)
  end
end

local function stopTimer()
  if timerRunning then
    timerRunning = false
    timer.stop()
  end
end

local function switchScreen(name)
  stopTimer()
  screen = name
  if screens[name].enter then screens[name].enter() end
  platform.window:invalidate()
end

-- ============================================================================
-- LOBBY
-- ============================================================================

local lobby = { sel = 1 }
local lobbyItems = { "Roulette", "Blackjack", "Slot Machine", "How To Play", "Reset Bankroll" }

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
  local pick = lobbyItems[lobby.sel]
  if pick == "Roulette" then switchScreen("roulette")
  elseif pick == "Blackjack" then switchScreen("blackjack")
  elseif pick == "Slot Machine" then switchScreen("slots")
  elseif pick == "How To Play" then switchScreen("help")
  elseif pick == "Reset Bankroll" then
    balance = 1000
    platform.window:invalidate()
  end
end

function lobby.charIn(ch)
  local n = tonumber(ch)
  if n and n >= 1 and n <= #lobbyItems then
    lobby.sel = n
    lobby.enterKey()
  end
end

function lobby.paint(gc)
  drawChrome(gc, "TI-NSPIRE CASINO", "Up/Down + Enter, or press a number  -  pick a game")

  gc:setFont("sansserif", "b", 20)
  setColor(gc, COLOR.gold)
  centerText(gc, "* CASINO *", W / 2, 34)

  gc:setFont("sansserif", "r", 11)
  local y = 70
  for i, item in ipairs(lobbyItems) do
    if i == lobby.sel then
      setColor(gc, COLOR.gold)
      gc:fillRect(40, y - 2, W - 80, 18)
      setColor(gc, COLOR.black)
    else
      setColor(gc, COLOR.cream)
    end
    centerText(gc, i .. ". " .. item, W / 2, y)
    y = y + 22
  end
end

screens.lobby = lobby

-- ============================================================================
-- HELP SCREEN
-- ============================================================================

local help = {}
local helpLines = {
  "ROULETTE",
  " 1-9 = instant bet on Red/Black/Even/Odd/",
  "       Low/High/1st12/2nd12/3rd12",
  " 0   = type a straight-up number (0-36)",
  " Up/Down = change chip value",
  " G = spin   C = clear bets   Bksp = undo",
  "",
  "BLACKJACK",
  " Up/Down = chip   Enter = add chip to bet",
  " G = deal   H = hit   S = stand   D = double",
  "",
  "SLOT MACHINE",
  " Up/Down = bet amount   G = spin",
  "",
  "Esc always returns to the lobby.",
}

function help.escapeKey() switchScreen("lobby") end
function help.enterKey() switchScreen("lobby") end

function help.paint(gc)
  drawChrome(gc, "HOW TO PLAY", "Esc or Enter - back to lobby")
  gc:setFont("sansserif", "r", 8)
  setColor(gc, COLOR.cream)
  local y = 26
  for _, line in ipairs(helpLines) do
    if line:match("^%u+$") then
      setColor(gc, COLOR.gold)
      gc:setFont("sansserif", "b", 9)
    else
      setColor(gc, COLOR.cream)
      gc:setFont("sansserif", "r", 8)
    end
    gc:drawString(line, 6, y, "top")
    y = y + 11
  end
end

screens.help = help

-- ============================================================================
-- ROULETTE
-- ============================================================================

local roulette = {}

-- Standard European single-zero wheel order (37 pockets)
local WHEEL_ORDER = {
  0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5,
  24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26
}
local RED_SET = {}
for _, n in ipairs({ 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36 }) do
  RED_SET[n] = true
end

local QUICK_KEYS = { "red", "black", "even", "odd", "low", "high", "d1", "d2", "d3" }
local QUICK_LABEL = {
  red = "Red", black = "Black", even = "Even", odd = "Odd",
  low = "1-18", high = "19-36", d1 = "1st 12", d2 = "2nd 12", d3 = "3rd 12",
}
local QUICK_MULT = { red = 1, black = 1, even = 1, odd = 1, low = 1, high = 1, d1 = 2, d2 = 2, d3 = 2 }

local function colorOf(n)
  if n == 0 then return "green" end
  if RED_SET[n] then return "red" end
  return "black"
end

local function pocketColorRGB(n)
  local c = colorOf(n)
  if c == "green" then return COLOR.green end
  if c == "red" then return COLOR.red end
  return COLOR.black
end

function roulette.enter()
  roulette.state = "betting"
  roulette.bets = { straight = {}, outside = {} }
  roulette.undoStack = {}
  roulette.chipIndex = 2
  roulette.numEntry = nil
  roulette.angle = roulette.angle or 0
  roulette.winningNumber = nil
  roulette.resultLines = nil
end

local function rl_currentChip() return chipValues[roulette.chipIndex] end

local function rl_totalWagered()
  local total = 0
  for _, amt in pairs(roulette.bets.outside) do total = total + amt end
  for _, amt in pairs(roulette.bets.straight) do total = total + amt end
  return total
end

local function rl_placeOutside(key)
  local amt = rl_currentChip()
  if amt > balance then return end
  balance = balance - amt
  roulette.bets.outside[key] = (roulette.bets.outside[key] or 0) + amt
  table.insert(roulette.undoStack, { kind = "outside", key = key, amount = amt })
end

local function rl_placeStraight(n)
  local amt = rl_currentChip()
  if amt > balance then return end
  balance = balance - amt
  roulette.bets.straight[n] = (roulette.bets.straight[n] or 0) + amt
  table.insert(roulette.undoStack, { kind = "straight", key = n, amount = amt })
end

local function rl_undo()
  local last = table.remove(roulette.undoStack)
  if not last then return end
  balance = balance + last.amount
  if last.kind == "outside" then
    roulette.bets.outside[last.key] = (roulette.bets.outside[last.key] or 0) - last.amount
    if roulette.bets.outside[last.key] <= 0 then roulette.bets.outside[last.key] = nil end
  else
    roulette.bets.straight[last.key] = (roulette.bets.straight[last.key] or 0) - last.amount
    if roulette.bets.straight[last.key] <= 0 then roulette.bets.straight[last.key] = nil end
  end
end

local function rl_clearAll()
  balance = balance + rl_totalWagered()
  roulette.bets = { straight = {}, outside = {} }
  roulette.undoStack = {}
end

local function rl_resolve()
  local lines = {}
  local credited = 0
  for key, amt in pairs(roulette.bets.outside) do
    local win = false
    local n = roulette.winningNumber
    if key == "red" then win = colorOf(n) == "red"
    elseif key == "black" then win = colorOf(n) == "black"
    elseif key == "even" then win = n ~= 0 and n % 2 == 0
    elseif key == "odd" then win = n ~= 0 and n % 2 == 1
    elseif key == "low" then win = n >= 1 and n <= 18
    elseif key == "high" then win = n >= 19 and n <= 36
    elseif key == "d1" then win = n >= 1 and n <= 12
    elseif key == "d2" then win = n >= 13 and n <= 24
    elseif key == "d3" then win = n >= 25 and n <= 36
    end
    if win then
      local ret = amt * (QUICK_MULT[key] + 1)
      credited = credited + ret
      table.insert(lines, { text = QUICK_LABEL[key] .. "  " .. fmtMoney(amt), win = true, amt = ret })
    else
      table.insert(lines, { text = QUICK_LABEL[key] .. "  " .. fmtMoney(amt), win = false, amt = 0 })
    end
  end
  for n, amt in pairs(roulette.bets.straight) do
    if n == roulette.winningNumber then
      local ret = amt * 36
      credited = credited + ret
      table.insert(lines, { text = "#" .. n .. "  " .. fmtMoney(amt), win = true, amt = ret })
    else
      table.insert(lines, { text = "#" .. n .. "  " .. fmtMoney(amt), win = false, amt = 0 })
    end
  end
  balance = balance + credited
  roulette.resultLines = lines
  roulette.credited = credited
end

function roulette.startSpin()
  if roulette.state ~= "betting" then return end
  if rl_totalWagered() <= 0 then return end
  roulette.winningIndex = math.random(1, 37)
  roulette.winningNumber = WHEEL_ORDER[roulette.winningIndex]
  local sliceDeg = 360 / 37
  local pocketCenter = (roulette.winningIndex - 1) * sliceDeg + sliceDeg / 2
  local desiredFinal = (90 - pocketCenter) % 360
  local extraSpins = 6
  roulette.spinStartAngle = roulette.angle or 0
  roulette.totalRotation = extraSpins * 360 + ((desiredFinal - (roulette.spinStartAngle % 360)) % 360)
  roulette.spinTick = 0
  roulette.spinDuration = 90
  roulette.state = "spinning"
  startTimer()
end

function roulette.timerTick()
  if roulette.state ~= "spinning" then return end
  roulette.spinTick = roulette.spinTick + 1
  local t = roulette.spinTick / roulette.spinDuration
  if t > 1 then t = 1 end
  local e = 1 - (1 - t) ^ 4
  roulette.angle = (roulette.spinStartAngle + roulette.totalRotation * e) % 360
  if t >= 1 then
    stopTimer()
    roulette.state = "result"
    rl_resolve()
  end
  platform.window:invalidate()
end

local function rl_finishRound()
  roulette.bets = { straight = {}, outside = {} }
  roulette.undoStack = {}
  roulette.numEntry = nil
  roulette.state = "betting"
end

function roulette.charIn(ch)
  local c = ch:lower()
  if roulette.state ~= "betting" then return end

  if roulette.numEntry then
    if c:match("%d") and #roulette.numEntry < 2 then
      roulette.numEntry = roulette.numEntry .. c
    end
    return
  end

  if c == "0" then
    roulette.numEntry = ""
    return
  end
  local idx = tonumber(c)
  if idx and idx >= 1 and idx <= 9 then
    rl_placeOutside(QUICK_KEYS[idx])
    return
  end
  if c == "c" then rl_clearAll()
  elseif c == "g" then roulette.startSpin()
  end
end

function roulette.enterKey()
  if roulette.numEntry ~= nil then
    local n = tonumber(roulette.numEntry)
    if n and n >= 0 and n <= 36 then rl_placeStraight(n) end
    roulette.numEntry = nil
  elseif roulette.state == "result" then
    rl_finishRound()
  elseif roulette.state == "betting" then
    roulette.startSpin()
  end
end

function roulette.escapeKey()
  if roulette.numEntry ~= nil then
    roulette.numEntry = nil
  elseif roulette.state == "betting" then
    rl_clearAll()
    switchScreen("lobby")
  elseif roulette.state == "result" then
    rl_finishRound()
    switchScreen("lobby")
  end
end

function roulette.backspaceKey()
  if roulette.numEntry ~= nil then
    roulette.numEntry = roulette.numEntry:sub(1, -2)
  elseif roulette.state == "betting" then
    rl_undo()
  end
end

function roulette.arrowKey(key)
  if roulette.state ~= "betting" then return end
  if key == "up" then
    roulette.chipIndex = math.min(#chipValues, roulette.chipIndex + 1)
  elseif key == "down" then
    roulette.chipIndex = math.max(1, roulette.chipIndex - 1)
  end
end

local function rl_drawWheel(gc, cx, cy, r)
  local sliceDeg = 360 / 37
  for i = 1, 37 do
    local n = WHEEL_ORDER[i]
    setColor(gc, pocketColorRGB(n))
    local start = (roulette.angle + (i - 1) * sliceDeg)
    gc:fillArc(cx - r, cy - r, 2 * r, 2 * r, start, sliceDeg + 0.6)
  end
  setColor(gc, COLOR.gold)
  gc:drawArc(cx - r, cy - r, 2 * r, 2 * r, 0, 360)
  setColor(gc, { 210, 190, 140 })
  fillCircle(gc, cx, cy, r * 0.28)
  setColor(gc, COLOR.gold)
  -- fixed pointer flag above the wheel
  gc:fillRect(cx - 2, cy - r - 9, 4, 9)
end

function roulette.paint(gc)
  local footer
  if roulette.state == "betting" then
    footer = "1-9 quick bet  0 # bet  Up/Dn chip  G spin  C clr  Bksp undo  Esc"
  elseif roulette.state == "spinning" then
    footer = "Spinning..."
  else
    footer = "Enter: bet again    Esc: lobby"
  end
  drawChrome(gc, "ROULETTE", footer)

  local wcx, wcy, wr = W - 52, 62, 40
  rl_drawWheel(gc, wcx, wcy, wr)

  gc:setFont("sansserif", "r", 8)
  setColor(gc, COLOR.cream)
  gc:drawString("Chip: " .. fmtMoney(rl_currentChip()), 4, 26, "top")

  if roulette.state == "betting" then
    local labels = { "1 Red", "2 Black", "3 Even", "4 Odd", "5 1-18",
                      "6 19-36", "7 1st12", "8 2nd12", "9 3rd12" }
    local y = 40
    for i = 1, 9, 1 do
      local key = QUICK_KEYS[i]
      local amt = roulette.bets.outside[key]
      local txt = labels[i] .. (amt and ("  " .. fmtMoney(amt)) or "")
      if key == "red" then setColor(gc, COLOR.redBright)
      elseif key == "black" then setColor(gc, COLOR.cream)
      else setColor(gc, COLOR.cream) end
      gc:drawString(txt, 4, y, "top")
      y = y + 11
    end
    gc:drawString("0 Straight # (35:1)", 4, y, "top")
    y = y + 13

    if roulette.numEntry ~= nil then
      setColor(gc, COLOR.gold)
      gc:setFont("sansserif", "b", 10)
      gc:drawString("Number: " .. roulette.numEntry .. "_  (Enter=OK, Esc=cancel)", 4, y, "top")
      y = y + 12
    end

    local straightCount = 0
    for _ in pairs(roulette.bets.straight) do straightCount = straightCount + 1 end
    if straightCount > 0 then
      local parts = {}
      for n, amt in pairs(roulette.bets.straight) do
        table.insert(parts, "#" .. n .. ":" .. fmtMoney(amt))
      end
      setColor(gc, COLOR.cream)
      gc:setFont("sansserif", "r", 8)
      gc:drawString(table.concat(parts, " "), 4, y, "top")
      y = y + 11
    end

    setColor(gc, COLOR.gold)
    gc:setFont("sansserif", "b", 9)
    gc:drawString("Total wagered: " .. fmtMoney(rl_totalWagered()), 4, H - 30, "top")

  elseif roulette.state == "spinning" then
    setColor(gc, COLOR.cream)
    gc:setFont("sansserif", "b", 12)
    centerText(gc, "No more bets...", 110, 100)

  elseif roulette.state == "result" then
    local n = roulette.winningNumber
    local col = colorOf(n)
    setColor(gc, pocketColorRGB(n))
    fillCircle(gc, 40, 44, 16)
    setColor(gc, COLOR.white)
    gc:setFont("sansserif", "b", 12)
    centerText(gc, tostring(n), 40, 37)
    gc:setFont("sansserif", "r", 8)
    setColor(gc, COLOR.cream)
    centerText(gc, col:upper(), 40, 62)

    gc:setFont("sansserif", "r", 8)
    local y = 40
    for _, line in ipairs(roulette.resultLines or {}) do
      if line.win then
        setColor(gc, COLOR.win)
        gc:drawString(line.text .. "  WIN " .. fmtMoney(line.amt), 82, y, "top")
      else
        setColor(gc, COLOR.lose)
        gc:drawString(line.text .. "  lost", 82, y, "top")
      end
      y = y + 10
      if y > H - 40 then break end
    end

    setColor(gc, COLOR.gold)
    gc:setFont("sansserif", "b", 10)
    gc:drawString("Returned: " .. fmtMoney(roulette.credited or 0), 4, H - 30, "top")
  end
end

screens.roulette = roulette

-- ============================================================================
-- BLACKJACK
-- ============================================================================

local blackjack = {}

local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUITS = { "S", "H", "D", "C" } -- Spades, Hearts, Diamonds, Clubs
local RED_SUIT = { H = true, D = true }

local function bj_newShoe()
  local deck = {}
  for _, s in ipairs(SUITS) do
    for _, r in ipairs(RANKS) do
      table.insert(deck, { rank = r, suit = s })
    end
  end
  for i = #deck, 2, -1 do
    local j = math.random(1, i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  return deck
end

local function bj_cardValue(card)
  if card.rank == "A" then return 11 end
  if card.rank == "J" or card.rank == "Q" or card.rank == "K" then return 10 end
  return tonumber(card.rank)
end

local function bj_handValue(hand)
  local sum, aces = 0, 0
  for _, c in ipairs(hand) do
    sum = sum + bj_cardValue(c)
    if c.rank == "A" then aces = aces + 1 end
  end
  while sum > 21 and aces > 0 do
    sum = sum - 10
    aces = aces - 1
  end
  return sum
end

local function bj_isBlackjack(hand)
  return #hand == 2 and bj_handValue(hand) == 21
end

local function bj_draw(hand)
  if #blackjack.deck == 0 then blackjack.deck = bj_newShoe() end
  table.insert(hand, table.remove(blackjack.deck))
end

function blackjack.enter()
  blackjack.state = "betting"
  blackjack.bet = 0
  blackjack.chipIndex = 2
  blackjack.playerHand = {}
  blackjack.dealerHand = {}
  blackjack.deck = blackjack.deck or bj_newShoe()
  blackjack.message = ""
  blackjack.dealerTimer = 0
end

local function bj_currentChip() return chipValues[blackjack.chipIndex] end

function blackjack.arrowKey(key)
  if blackjack.state ~= "betting" then return end
  if key == "up" then
    blackjack.chipIndex = math.min(#chipValues, blackjack.chipIndex + 1)
  elseif key == "down" then
    blackjack.chipIndex = math.max(1, blackjack.chipIndex - 1)
  end
end

local function bj_deal()
  if blackjack.bet <= 0 then return end
  blackjack.playerHand = {}
  blackjack.dealerHand = {}
  bj_draw(blackjack.playerHand)
  bj_draw(blackjack.dealerHand)
  bj_draw(blackjack.playerHand)
  bj_draw(blackjack.dealerHand)
  blackjack.message = ""
  if bj_isBlackjack(blackjack.playerHand) then
    blackjack.state = "dealer"
    blackjack.dealerTimer = 10
  else
    blackjack.state = "player"
  end
  startTimer()
end

local function bj_resolve()
  local pv, dv = bj_handValue(blackjack.playerHand), bj_handValue(blackjack.dealerHand)
  local pbj, dbj = bj_isBlackjack(blackjack.playerHand), bj_isBlackjack(blackjack.dealerHand)
  local bet = blackjack.bet
  local ret, msg

  if pv > 21 then
    ret, msg = 0, "Bust! You lose " .. fmtMoney(bet)
  elseif pbj and dbj then
    ret, msg = bet, "Push (both Blackjack)"
  elseif pbj then
    ret, msg = math.floor(bet * 2.5), "Blackjack! +" .. fmtMoney(math.floor(bet * 1.5))
  elseif dbj then
    ret, msg = 0, "Dealer Blackjack. You lose " .. fmtMoney(bet)
  elseif dv > 21 then
    ret, msg = bet * 2, "Dealer busts! +" .. fmtMoney(bet)
  elseif pv > dv then
    ret, msg = bet * 2, "You win! +" .. fmtMoney(bet)
  elseif pv < dv then
    ret, msg = 0, "Dealer wins. You lose " .. fmtMoney(bet)
  else
    ret, msg = bet, "Push."
  end

  balance = balance + ret
  blackjack.message = msg
  blackjack.state = "result"
  stopTimer()
end

function blackjack.timerTick()
  if blackjack.state ~= "dealer" then return end
  blackjack.dealerTimer = blackjack.dealerTimer - 1
  if blackjack.dealerTimer <= 0 then
    if bj_handValue(blackjack.playerHand) <= 21 and bj_handValue(blackjack.dealerHand) < 17 then
      bj_draw(blackjack.dealerHand)
      blackjack.dealerTimer = 10
    else
      bj_resolve()
    end
  end
  platform.window:invalidate()
end

function blackjack.charIn(ch)
  local c = ch:lower()
  if blackjack.state == "betting" then
    if c == "g" then bj_deal()
    elseif c == "c" then
      balance = balance + blackjack.bet
      blackjack.bet = 0
    end
  elseif blackjack.state == "player" then
    if c == "h" then
      bj_draw(blackjack.playerHand)
      if bj_handValue(blackjack.playerHand) > 21 then
        bj_resolve()
      end
    elseif c == "s" then
      blackjack.state = "dealer"
      blackjack.dealerTimer = 10
      startTimer()
    elseif c == "d" then
      if #blackjack.playerHand == 2 and blackjack.bet <= balance then
        balance = balance - blackjack.bet
        blackjack.bet = blackjack.bet * 2
        bj_draw(blackjack.playerHand)
        if bj_handValue(blackjack.playerHand) > 21 then
          bj_resolve()
        else
          blackjack.state = "dealer"
          blackjack.dealerTimer = 10
          startTimer()
        end
      end
    end
  end
end

function blackjack.enterKey()
  if blackjack.state == "betting" then
    local amt = bj_currentChip()
    if amt <= balance then
      balance = balance - amt
      blackjack.bet = blackjack.bet + amt
    end
  elseif blackjack.state == "result" then
    blackjack.bet = 0
    blackjack.playerHand = {}
    blackjack.dealerHand = {}
    blackjack.state = "betting"
  end
end

function blackjack.backspaceKey()
  if blackjack.state == "betting" and blackjack.bet > 0 then
    local amt = bj_currentChip()
    if amt > blackjack.bet then amt = blackjack.bet end
    blackjack.bet = blackjack.bet - amt
    balance = balance + amt
  end
end

function blackjack.escapeKey()
  if blackjack.state == "betting" then
    balance = balance + blackjack.bet
    blackjack.bet = 0
    switchScreen("lobby")
  elseif blackjack.state == "result" then
    switchScreen("lobby")
  end
end

local function bj_drawHand(gc, hand, x, y, hideFirst)
  for i, card in ipairs(hand) do
    local cx = x + (i - 1) * 30
    if hideFirst and i == 1 then
      setColor(gc, COLOR.navy)
      gc:fillRect(cx, y, 26, 36)
      setColor(gc, COLOR.gold)
      gc:drawRect(cx, y, 26, 36)
    else
      setColor(gc, COLOR.white)
      gc:fillRect(cx, y, 26, 36)
      setColor(gc, COLOR.black)
      gc:drawRect(cx, y, 26, 36)
      if RED_SUIT[card.suit] then setColor(gc, COLOR.red) else setColor(gc, COLOR.black) end
      gc:setFont("sansserif", "b", 9)
      gc:drawString(card.rank, cx + 3, y + 2, "top")
      gc:setFont("sansserif", "r", 8)
      gc:drawString(card.suit, cx + 3, y + 22, "top")
    end
  end
end

function blackjack.paint(gc)
  local footer
  if blackjack.state == "betting" then
    footer = "Up/Dn chip  Enter add  Bksp remove  C clr  G deal  Esc"
  elseif blackjack.state == "player" then
    footer = "H hit   S stand   D double"
  elseif blackjack.state == "dealer" then
    footer = "Dealer playing..."
  else
    footer = "Enter: new hand    Esc: lobby"
  end
  drawChrome(gc, "BLACKJACK", footer)

  setColor(gc, COLOR.cream)
  gc:setFont("sansserif", "r", 8)
  gc:drawString("Dealer", 6, 26, "top")
  local hideHole = (blackjack.state == "player")
  bj_drawHand(gc, blackjack.dealerHand, 6, 38, hideHole)
  if not hideHole and #blackjack.dealerHand > 0 then
    gc:drawString("= " .. bj_handValue(blackjack.dealerHand), 6 + (#blackjack.dealerHand) * 30 + 4, 46, "top")
  end

  gc:drawString("Player", 6, 100, "top")
  bj_drawHand(gc, blackjack.playerHand, 6, 112, false)
  if #blackjack.playerHand > 0 then
    gc:drawString("= " .. bj_handValue(blackjack.playerHand), 6 + (#blackjack.playerHand) * 30 + 4, 120, "top")
  end

  setColor(gc, COLOR.gold)
  gc:setFont("sansserif", "b", 10)
  gc:drawString("Bet: " .. fmtMoney(blackjack.bet), 6, 156, "top")
  if blackjack.state == "betting" then
    gc:setFont("sansserif", "r", 8)
    setColor(gc, COLOR.cream)
    gc:drawString("Chip: " .. fmtMoney(bj_currentChip()), 6, 170, "top")
  end

  if blackjack.state == "result" then
    setColor(gc, COLOR.gold)
    gc:setFont("sansserif", "b", 11)
    centerText(gc, blackjack.message, W / 2, 186)
  end
end

screens.blackjack = blackjack

-- ============================================================================
-- SLOT MACHINE
-- ============================================================================

local slots = {}

local SLOT_SYMBOLS = { "CHERRY", "LEMON", "STAR", "BELL", "BAR", "7" }
local SLOT_WEIGHTS  = { 30, 24, 18, 14, 10, 4 } -- higher = more common
local SLOT_PAYOUT   = { CHERRY = 4, LEMON = 6, STAR = 10, BELL = 15, BAR = 20, ["7"] = 50 }
local SLOT_TOTAL_W = 0
for _, w in ipairs(SLOT_WEIGHTS) do SLOT_TOTAL_W = SLOT_TOTAL_W + w end

local function slot_pick()
  local roll = math.random(1, SLOT_TOTAL_W)
  local acc = 0
  for i, w in ipairs(SLOT_WEIGHTS) do
    acc = acc + w
    if roll <= acc then return SLOT_SYMBOLS[i] end
  end
  return SLOT_SYMBOLS[1]
end

function slots.enter()
  slots.state = "idle"
  slots.chipIndex = 2
  slots.reel = { "7", "7", "7" }
  slots.message = ""
  slots.tick = 0
end

local function slot_bet() return chipValues[slots.chipIndex] end

function slots.arrowKey(key)
  if slots.state ~= "idle" and slots.state ~= "result" then return end
  if key == "up" then
    slots.chipIndex = math.min(#chipValues, slots.chipIndex + 1)
  elseif key == "down" then
    slots.chipIndex = math.max(1, slots.chipIndex - 1)
  end
end

function slots.charIn(ch)
  local c = ch:lower()
  if c == "g" and (slots.state == "idle" or slots.state == "result") then
    local bet = slot_bet()
    if bet > balance then return end
    balance = balance - bet
    slots.finalReel = { slot_pick(), slot_pick(), slot_pick() }
    slots.stopAt = { 20, 35, 50 }
    slots.tick = 0
    slots.state = "spinning"
    slots.message = ""
    startTimer()
  end
end

function slots.enterKey()
  slots.charIn("g")
end

function slots.escapeKey()
  switchScreen("lobby")
end

local function slot_evaluate()
  local bet = slot_bet()
  local r1, r2, r3 = slots.reel[1], slots.reel[2], slots.reel[3]
  local ret = 0
  if r1 == r2 and r2 == r3 then
    local win = bet * SLOT_PAYOUT[r1]
    ret = bet + win
    slots.message = "JACKPOT! " .. r1 .. " x3  +" .. fmtMoney(win)
  else
    local cherries = 0
    for _, s in ipairs({ r1, r2, r3 }) do if s == "CHERRY" then cherries = cherries + 1 end end
    if cherries == 2 then
      local win = bet * 2
      ret = bet + win
      slots.message = "2x CHERRY  +" .. fmtMoney(win)
    else
      slots.message = "No match. -" .. fmtMoney(bet)
    end
  end
  balance = balance + ret
end

function slots.timerTick()
  if slots.state ~= "spinning" then return end
  slots.tick = slots.tick + 1
  for i = 1, 3 do
    if slots.tick < slots.stopAt[i] then
      slots.reel[i] = SLOT_SYMBOLS[math.random(1, #SLOT_SYMBOLS)]
    else
      slots.reel[i] = slots.finalReel[i]
    end
  end
  if slots.tick >= slots.stopAt[3] then
    slots.state = "result"
    slot_evaluate()
    stopTimer()
  end
  platform.window:invalidate()
end

local SLOT_GLYPH = { CHERRY = "()", LEMON = "<>", STAR = "*", BELL = "^", BAR = "==", ["7"] = "7" }

local function slot_drawReel(gc, x, y, sym)
  setColor(gc, COLOR.white)
  gc:fillRect(x, y, 70, 60)
  setColor(gc, COLOR.black)
  gc:drawRect(x, y, 70, 60)
  setColor(gc, COLOR.red)
  gc:setFont("sansserif", "b", 16)
  centerText(gc, SLOT_GLYPH[sym] or "?", x + 35, y + 12)
  gc:setFont("sansserif", "r", 7)
  setColor(gc, COLOR.black)
  centerText(gc, sym, x + 35, y + 42)
end

function slots.paint(gc)
  local footer
  if slots.state == "spinning" then
    footer = "Spinning..."
  else
    footer = "Up/Dn bet   G spin   Esc lobby"
  end
  drawChrome(gc, "SLOT MACHINE", footer)

  slot_drawReel(gc, 12, 40, slots.reel[1])
  slot_drawReel(gc, 90, 40, slots.reel[2])
  slot_drawReel(gc, 168, 40, slots.reel[3])

  setColor(gc, COLOR.gold)
  gc:setFont("sansserif", "b", 10)
  gc:drawString("Bet: " .. fmtMoney(slot_bet()), 12, 112, "top")

  gc:setFont("sansserif", "r", 7)
  setColor(gc, COLOR.cream)
  local y = 130
  for i, s in ipairs(SLOT_SYMBOLS) do
    gc:drawString(SLOT_GLYPH[s] .. " " .. s .. " x3 = " .. SLOT_PAYOUT[s] .. ":1", 12, y, "top")
    y = y + 10
  end

  if slots.state == "result" then
    setColor(gc, COLOR.gold)
    gc:setFont("sansserif", "b", 11)
    centerText(gc, slots.message, W / 2, 20 + 5)
  end
end

screens.slots = slots

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

function on.timer()
  if screens[screen].timerTick then screens[screen].timerTick() end
end

function on.save()
  return { balance = balance }
end

function on.restore(state)
  pcall(function()
    if type(state) == "table" and type(state.balance) == "number" then
      balance = state.balance
    end
  end)
end

-- ----------------------------------------------------------------------------
-- Boot
-- ----------------------------------------------------------------------------

math.randomseed(os.time and os.time() or 12345)
lobby.enter()
