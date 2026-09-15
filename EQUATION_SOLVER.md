# Step-by-Step Equation Solver — TI-Nspire CX II

`src/eqsolver.lua` is a full algebra assistant for the TI-Nspire CX / CX II
(CAS or non-CAS). You type a problem, pick a mode from the drop-down, and it
shows **the whole worked solution** — every step, in order, with the reason
for it — and the answer at the top.

It is not a wrapper around the CAS. The algebra runs on an exact
rational-arithmetic engine written into the file, so the steps are real work
rather than a pretty-printed `solve()` result. The handheld's CAS is used only
as a fallback for things that have no step-by-step method (trig, logs,
exponentials).

Runs as a normal Lua **Script Editor** page — no Ndless, no jailbreak.

---

## Modes (the drop-down)

Press **TAB** anywhere to open it.

| # | Mode | What you type | What you get |
|---|---|---|---|
| 1 | **Solve equation** | `2(x+3) = 5x - 4` | Every step to the answer, plus a substitution check |
| 2 | **Factor** | `6x^2 + 11x + 3` | GCF, the identity used, the factors, and a multiply-back check |
| 3 | **Expand / simplify** | `(2x-1)^3` | Distributed and collected, with degree and leading coefficient |
| 4 | **Solve for variable** | `a = 1/2*b*h for h` | A formula rearranged for one letter |
| 5 | **Evaluate** | `x^2+3x-1, x=2` | Substitution shown, then the exact value |
| 6 | **System of 2 eqns** | `2x+y=7, x-y=2` | Elimination (or substitution), back-substitution, check |
| 7 | **Analyze polynomial** | `x^2-4x+1` | Degree, zeros, y-intercept, vertex, axis, end behaviour |

The drop-down also has **Examples for this mode** (a picker that fills the
entry line for you) and **Help**.

---

## Keys

Everything is keyboard-driven, so it works the same on Clickpad and Touchpad.
A mouse works too in the computer software.

### Entry line
| Key | Action |
|---|---|
| **ENTER** | Run the current mode |
| **menu key** / Document Tools | Native Nspire menu: pick any mode (always works) |
| **TAB** or **ESC** | Open the mode drop-down (the host may swallow these) |
| **left / right** on an empty line | Cycle through the modes |
| **left / right** | Move the cursor |
| **up / down** | Recall earlier entries |
| **DEL** | Delete the character before the cursor |
| **clear** | Empty the entry line |

### Solution screen
| Key | Action |
|---|---|
| **up / down** | Scroll one line |
| **left / right** | Scroll one page |
| **ENTER** | Back to the entry line, keeping what you typed |
| **ESC** | Back to the entry line |
| **TAB** | Change mode |

---

## If it does not respond to the keyboard

The footer of the entry screen shows a counter: `keys 7:char x`. That is the
number of events the script has received and the last one. **Press any key and
watch that counter.**

**The counter does not move.** The script is not getting your keypresses — the
host software is keeping them. Nothing is wrong with the program.

- In the computer software, **close the Script Editor pane** after you run the
  script (Ctrl+B / *Set Script*). While that pane is open it holds the
  keyboard. Then **click once on the page itself** so the page has focus, and
  type.
- On the handheld, press **ctrl+tab** until the script's page is the active
  one, then type.
- Make sure you are on the page with the script, not still in the editor.

**The counter moves but nothing changes on screen.** Then events arrive and the
program is at fault — tell me the counter text you see and what you pressed.

### Changing mode when TAB does nothing

TAB and ESC belong to the Nspire itself, which uses them to move between page
objects, so the host can swallow them before the script sees them. There are
three other ways in, and at least one always works:

1. **The `menu` key** (handheld) or **Document Tools ▸ Mode** (computer
   software). The script registers a real Nspire menu listing every mode, plus
   Solve / Examples / Clear / Help. This is the most reliable route because the
   menu belongs to the script rather than to the keyboard.
2. **Left / right arrow while the entry line is empty** cycles through the
   modes. With text on the line those arrows move the cursor instead.
3. **Click the mode bar** at the top of the screen (computer software, or a
   Touchpad handheld).

---

## How to type maths

| You want | Type |
|---|---|
| `x²` | `x^2` (or the calculator's own `x²` key) |
| `√(x+4)` | `sqrt(x+4)` or `√(x+4)` |
| `\|x-3\|` | `abs(x-3)` or `\|x-3\|` |
| `2x`, `3(x+1)`, `(x+1)(x-2)` | exactly that — the `*` is optional |
| `xy` | `xy` means x times y |
| a fraction | `(x+1)/2` |
| π | `pi` or `π` |

Decimals become exact fractions (`0.25` → `1/4`), so answers stay exact.
Capital letters are read as lower case. Two letters side by side are a
product, not a two-letter variable name — this matches how algebra is
written on paper (and is the opposite of the CAS entry line, where `st`
would be one variable).

---

## Installing it

TI-Nspire documents (`.tns`) can only be authored with TI's own tools, so
the file has to go through the computer software or the on-calculator
Script Editor.

### With TI-Nspire CX CAS Student Software (easiest)

1. **File ▸ New Document**, then **Insert ▸ Script Editor ▸ Insert Script**.
2. Name it `eqsolver`.
3. Open `src/eqsolver.lua` from this repo in any text editor, select all,
   copy, and paste it into the Script Editor, replacing the template text.
4. **Ctrl+B** (or the Script Editor's *Set Script* / focus-out) to run it.
   The solver appears straight away in the software's emulator — try it
   there first.
5. **File ▸ Save Document As…** → `EqSolver.tns`.
6. Plug in the handheld over USB, open the **Content Explorer**, and drag
   `EqSolver.tns` onto the calculator.
7. On the handheld: **On ▸ My Documents ▸ EqSolver**.

### On the calculator itself

**doc ▸ Insert ▸ Script Editor**, then type or paste the script in. ~3900
lines is a lot to key in by hand, so the computer route is strongly
preferred.

---

## What it can and cannot do

**Full step-by-step, exact:**

- Linear equations, including ones with fractions
- Quadratics — by factoring (inspection or the AC method), or by
  discriminant + quadratic formula with exact surds like `(-1 + √5)/2`
- Polynomials of any degree — GCF, Rational Root Theorem with synthetic
  division, difference of squares, sum/difference of cubes, grouping,
  quadratic-in-x^k substitution, and quartics that split into two quadratics
- Rational equations (variable in a denominator), with excluded values
  tracked and extraneous roots thrown out
- Radical and absolute-value equations, solved by squaring, with every
  candidate checked against the original
- Formula rearrangement, 2×2 systems, evaluation, polynomial analysis
- Complex roots, reported exactly (`x = -2i`)

**Handed to the CAS / a numeric search:**

- Trig, logarithm and exponential equations. There is no general
  step-by-step method for these, so the solver says so plainly, asks the
  handheld's CAS via `math.evalStr`, and also runs its own sign-change
  scan from −30 to 30 so you still get real answers on a non-CAS handheld.
- Degree 3+ polynomials with no rational roots fall back to a built-in
  numeric root finder (Durand–Kerner), which needs no CAS at all.

**Not supported:** systems larger than 2×2, inequalities, calculus,
matrices, fractional exponents other than ½.

---

## How the answers are checked

This is the part that makes it trustworthy rather than merely confident:

- All arithmetic is **exact rational**, never floating point, so `1/3`
  stays `1/3` and there is no rounding drift through a long derivation.
- Every **factorisation is multiplied back out** and compared with the
  input. If it does not match exactly, it is discarded rather than shown.
- Every **solution is substituted into the original equation** — exactly
  when the arithmetic allows, numerically otherwise. Roots that only
  appeared because both sides were squared, or that make a denominator
  zero, are listed separately under "Extraneous — throw these out".
- Integer overflow past 2^53 is detected and reported instead of silently
  producing garbage.

---

## Testing

The repo carries a test suite that runs the real `src/eqsolver.lua` against a
mock of the Nspire graphics API:

```sh
lua5.1 tests/run_tests.lua     # 5.1 is what the handheld runs
lua5.3 tests/run_tests.lua     # catches version-specific slips
```

1455 assertions: parser cases and rejections, a table of known
factorisations, 400 randomised factorisations checked against the uniqueness
of factorisation over ℚ, 300 randomised polynomials built from known roots,
every mode's expected answers, round-trip checks (printed answers are parsed
back and compared), extraneous-root handling, word-wrap invariants, every
screen painted at three sizes with an overflow check on every drawn string,
3000 fuzzed expressions and 4000 random key/mouse events with no raw error.

`tests/probe.lua` splices a scratch file onto the end of the source so you
can poke at internals during development:

```sh
lua5.1 tests/probe.lua tests/bodies/show_steps.lua
```

> **Tested on:** desktop Lua 5.1.5 and 5.3.6 against a mock of the Nspire
> API. It has **not** been run on real hardware or in an emulator, because
> neither was available where this was built. The code sticks to the
> long-established core of the Nspire Lua API (`on.paint` / `on.charIn` /
> `on.enterKey` / `on.escapeKey` / `on.tabKey` / `on.backspaceKey` /
> `on.arrowKey` / `on.mouseDown` / `on.save` / `on.restore`,
> `gc:drawString` / `fillRect` / `drawRect` / `drawLine` / `clipRect` /
> `getStringWidth` / `setFont` / `setColorRGB`), and every optional call
> (`platform.withGC`, `math.evalStr`) is wrapped in `pcall` with a
> fallback. If the first run reports an error with a line number, that is a
> quick fix — send the number over.

---

## Customising

Everything is in one file, in numbered sections.

- `MODES` (section 18) — the drop-down: names, one-line blurbs, and the
  example lists.
- `C` (section 18) — the colour palette.
- `STYLE` (section 18) — fonts, colours and line heights for each kind of
  step line.
- `ENG.numericScan` (section 13) — the `-30 … 30` window used for
  trig/log/exponential equations.
- `VAR_PREFERENCE` (section 13) — which letter is picked as "the variable"
  when an equation has several.
