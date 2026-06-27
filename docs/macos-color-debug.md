# macOS black-and-white effects — debugging notes

## Symptom

On macOS, all effects render in black and white in real (tattoy) mode, even
though the Mac terminal has been confirmed to support true color. Effects look
correct on Linux.

## Most likely cause: truecolor is never advertised to tattoy

In real mode, effects do **not** draw to the terminal themselves. The pipeline is:

```
launcher.py  →  os.execvp(tattoy)  →  tattoy renders the composited frame to the terminal
```

Effects emit colors as RGBA floats over JSON (`clippy/types.py`). **tattoy** (the
Rust compositor) is what decides whether to write 24-bit color escapes
(`\033[38;2;r;g;b m`) or downgrade to 256/16-color/monochrome. That decision is
made by tattoy's terminal-capability detection, which conventionally keys off the
**`COLORTERM`** environment variable (`truecolor` or `24bit`). There is no
reliable in-band way to *query* a terminal for truecolor, so programs rely on
this out-of-band env signal.

The launcher hands off to tattoy here (`clippy/launcher.py`, end of `main()`):

```python
os.execvp(tattoy_path, [tattoy_path, "--config-dir", config_path])
```

It sets `PYTHONPATH`, `CLIPPY_EFFECTS`, and `CLIPPY_SHAKE` — but it **never sets
`COLORTERM`**. tattoy inherits whatever environment the user's shell had.

Confirmed: `COLORTERM` and `TERM` appear nowhere in the codebase
(`grep -ri 'COLORTERM\|truecolor\|24bit' .` only hits comments/escape builders).

### Why this hits macOS specifically

- On Linux, the desktop terminal almost always exports `COLORTERM=truecolor`,
  so tattoy detects it and renders full color. (This is why it "works on our
  machines.")
- On macOS that is frequently **not** set, even on truecolor-capable terminals:
  Apple's Terminal.app never exports it; iTerm2 does, but login-shell / tmux /
  SSH setups commonly strip it.

So the terminal genuinely supports truecolor, but the running tattoy process is
never told, falls back to a degraded color mode, and effects appear black & white.

The "the Mac terminal supports true colour" fact is real but beside the point —
what matters is whether the *process* sees the advertisement in its environment,
not whether the emulator is capable.

## How to confirm (on a Mac)

1. Run `clippy --demo fire`. Demo mode (`clippy/demo.py`) emits 24-bit escapes
   **directly**, bypassing tattoy. If the demo is colorful but real mode is B&W,
   the problem is isolated to the tattoy launch path — strongly confirming the
   env-detection theory.
2. Check the environment in that terminal:
   ```bash
   echo "COLORTERM=$COLORTERM  TERM=$TERM"
   ```
   If `COLORTERM` is empty (or `TERM` is a bare `xterm` rather than
   `xterm-256color`), that's the smoking gun.
3. Quick proof: `COLORTERM=truecolor clippy`. If color comes back, confirmed.

## Proposed fix (small)

Have the launcher guarantee the signal before exec'ing tattoy — set it only if
absent, so a deliberate user override (e.g. `COLORTERM=` to force a downgrade) is
respected. Right before the `execvp` in `main()`:

```python
# Advertise truecolor to tattoy if the environment hasn't already.
# macOS terminals often support truecolor without exporting COLORTERM.
os.environ.setdefault("COLORTERM", "truecolor")
```

`COLORTERM` is the variable that gates truecolor; `TERM` mainly affects the
256-color tier. Start with `COLORTERM`. A test should assert the launcher sets it
before `execvp` (and does not clobber an existing value).

## Caveats

- This is a hypothesis grounded in the code, **not** a verified repro — it has
  not been reproduced on a Mac. Step 1 above is the cheap test.
- If the demo **also** renders B&W on the Mac, then it is not the environment at
  all and the problem is further upstream (terminal profile / SSH / tmux `Tc`
  capability), which would need to be chased separately.
