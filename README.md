# TI-Nspire CX II Casino

A full-color, multi-game casino for the **TI-Nspire CX II** (or any color
Nspire), written as a native Lua Script Editor document — **no jailbreak /
Ndless required**. It runs as a normal document on your calculator, just
like any TI-Nspire app.

The calculator acts as the dealer for:

- **Roulette** (the flagship game) — full European wheel (single zero),
  animated spin, and a **hotkey quick-bet menu** so you can drop bets in a
  couple of keypresses instead of hunting around a tiny betting grid.
- **Blackjack** — standard rules, dealer stands on 17, blackjack pays 3:2,
  hit/stand/double.
- **Slot Machine** — 3-reel slots with a weighted symbol table and a
  jackpot payout list shown right on screen.

All three games share one bankroll ("Bank") that persists as you move
between games, and is saved with the document (via `on.save`/`on.restore`)
so your balance survives closing and reopening the `.tns` file.

Everything is **keyboard-only by design** — it works identically whether
your handheld has a Clickpad or a Touchpad, and it's genuinely faster than
pointing/clicking at a cramped 320×240 betting table.

## Files

- `src/casino.lua` — the entire app (single script, ~700 lines).

## Installing it on your calculator

TI-Nspire documents (`.tns`) can only be authored with TI's own tools —
there's no way to hand-build a valid `.tns` file from source. Pick whichever
of these you have available:

### Option A — TI-Nspire Student/Teacher Software (easiest, needs a computer)

1. Install the free trial or full version of **TI-Nspire™ CX Student
   Software** (or Teacher Software) from education.ti.com. It runs on
   Windows/macOS and includes a full on-screen emulator plus the Script
   Editor authoring tool.
2. Create a new document → **Insert → Script Editor**.
3. Open `src/casino.lua` from this repo, copy its entire contents, and
   paste it into the Script Editor page, replacing the placeholder text.
4. Click outside the editor to run it — the software's emulator will run
   the casino immediately so you can try it on your computer first.
5. Save the document as `Casino.tns`.
6. Connect your TI-Nspire CX II via USB. The software shows it as a
   connected handheld — right-click the document (or use **File → Transfer
   Documents**) and send `Casino.tns` to the calculator.
7. On the calculator: **On** → **My Documents** → open `Casino.tns`.

### Option B — Directly on the calculator (no computer needed)

TI-Nspire CX/CX II handhelds have a built-in Script Editor too:

1. On the calculator, press **doc ▸ Insert ▸ Script Editor** (or from the
   home screen, start a new document and add a Script Editor page).
2. You'll need to type the contents of `src/casino.lua` in using the
   calculator's keypad, or paste it if you have a way to get text onto the
   clipboard (e.g. TI-Nspire Link software's remote screen can be used to
   type/paste while connected). Typing ~700 lines by hand on the keypad is
   painful — Option A is strongly recommended if you have any access to a
   computer, even briefly at a library or school.
3. Press **ctrl + R** (or the Script Editor's "Run" action) to execute it.
4. Save the document from **doc ▸ File ▸ Save**.

### Testing without a calculator first

TI also publishes the free **Firebird Emulator** (open-source,
`firebird-emu.org`) which can run `.tns` documents on your computer and is
much faster to iterate with than transferring to real hardware every time.
The TI-Nspire Student Software's built-in emulator (Option A, step 4) works
just as well for this.

> **Note on testing:** This script was written and logic-tested (bet
> resolution, payouts, balance accounting, state transitions) against a
> desktop Lua 5.1 interpreter with a mock of the Nspire drawing API — over
> 500 simulated rounds across all three games ran without error and the
> bankroll never went negative. It has **not** been run inside the real
> TI-Nspire firmware or the Firebird emulator, since neither is available
> in this environment. The Nspire Lua API is small and well-documented, so
> the code sticks to the well-established core (`gc:fillRect/fillArc/
> drawString`, `on.paint/on.charIn/on.enterKey/on.escapeKey/on.arrowKey/
> on.timer`, `timer.start/stop`). If the calculator's error console reports
> a line number when you first run it, send it over and it's a quick fix.

## Controls

The footer bar at the bottom of the screen always shows the current
game's hotkeys. Full reference:

### Lobby
| Key | Action |
|---|---|
| Up / Down | Move selection |
| Enter | Open selected game |
| 1-5 | Jump straight to that menu item |

### Roulette
| Key | Action |
|---|---|
| **1** | Bet on Red |
| **2** | Bet on Black |
| **3** | Bet on Even |
| **4** | Bet on Odd |
| **5** | Bet on 1-18 |
| **6** | Bet on 19-36 |
| **7 / 8 / 9** | Bet on 1st / 2nd / 3rd dozen (2:1) |
| **0** | Type a straight-up number 0-36 (35:1), Enter to confirm |
| Up / Down | Change chip value ($1 / $5 / $25 / $100 / $500) |
| **G** | Spin the wheel (locks in current bets) |
| **C** | Clear all bets (refunded) |
| Backspace | Undo the last bet placed |
| Esc | Cancel bets and return to lobby |

Each number key instantly drops one chip of the current denomination on
that bet — press it repeatedly (or switch chip size with Up/Down) to stack
bets quickly, then hit **G** to spin. You can have as many simultaneous
bets as you like, straight-up and outside bets together, exactly like a
real table.

### Blackjack
| Key | Action |
|---|---|
| Up / Down | Change chip value |
| Enter | Add a chip to your bet |
| Backspace | Remove last chip from bet |
| C | Clear bet |
| **G** | Deal |
| **H** | Hit |
| **S** | Stand |
| **D** | Double down (first two cards only) |
| Esc | Return to lobby |

### Slot Machine
| Key | Action |
|---|---|
| Up / Down | Change bet amount |
| **G** | Spin |
| Esc | Return to lobby |

## Game rules implemented

**Roulette** — European wheel, 37 pockets (0-36, single zero). Straight-up
pays 35:1, dozens pay 2:1, Red/Black/Even/Odd/Low/High pay 1:1. (Split,
street, corner and column bets aren't included in this version — the
hotkey menu focuses on the bets you can place fastest; straight-up covers
every number if you want long-shot odds.)

**Blackjack** — single reshuffled shoe, dealer stands on all 17s, blackjack
pays 3:2, push returns your bet, double down available on the first two
cards for balance permitting.

**Slots** — 3 reels, 6 weighted symbols (Cherry/Lemon/Star/Bell/Bar/7),
payouts shown on screen, plus a small consolation payout for exactly 2
cherries.

## Customizing

Everything is in `src/casino.lua`, organized into clearly separated
sections per game. A few obvious knobs if you want to tweak it:

- `chipValues` (top of file) — the five chip denominations.
- `balance = 1000` — starting/reset bankroll.
- `SLOT_PAYOUT` / `SLOT_WEIGHTS` — slot machine odds and payouts.
- `WHEEL_ORDER` — the physical wheel pocket sequence (used for the spin
  animation only; the actual winning number is drawn independently with
  `math.random`, so table layout changes are purely cosmetic).
