# VCB Board Size Modifier

A runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) mod for
[Virtual Circuit Board](https://store.steampowered.com/app/1885690/Virtual_Circuit_Board/) that
lets you **grow the board past the default 2048×2048**, live, from inside the game — no save/load
round-trip needed.

It adds a **"Board"** category to the circuit-editor **side panel** (docked between the **Cursor
Info** card and the **Inks** zone) with a small **Board size** field and an **Apply** button.
Existing board content is preserved. It's **compatible with the
[VCB Multiplayer](https://github.com/n-popescu/vcb-multiplayer) mod**: when a multiplayer session
is live, the size field is **mirrored to the other player as you type** (before you even press
Apply, so the two players can't end up on different numbers), and Apply resizes both boards.

Like the multiplayer mod, this is **pure GDScript** and loads at runtime — it **never replaces
`vcb.pck`** and adds its own nodes at runtime, so it coexists with other Mod Loader mods.

## Boards are square (why there's really one size)

VCB's simulation is a **closed-source native engine**. Reverse-engineering it
([`vcb-engine-recovery`](https://github.com/n-popescu/vcb-engine-recovery)) shows the compiler
reads the board dimension **dynamically** from the layer image (`side = image.width`) rather than
hardcoding 2048 — which is exactly why a bigger board can compile and simulate at all. But the
same code uses that single `side` for **both** axes (its pixel scan loops `x, y` in `[0, side)`),
so the board must be **square**. A non-square image would silently truncate (if taller) or read
out of bounds (if wider).

So this mod always produces a **square `side × side` board**. The side-panel card has a single
**Board size** field — **2048 minimum** by design, with **no hard upper limit** (the size is
effectively *unbounded*). Bigger boards just need a more powerful PC, so the field only
**recommends** staying at or under **8192**; go higher at your own (memory/GPU) risk — see
*Limitations*.

## Install & run

1. In the [vcb-launcher](https://github.com/n-popescu/vcb-launcher), open the **Runtime
   modding** tab and click **Enable modding** (patches `vcb.pck` once with the Mod Loader).
2. Grab `npopescu-VCBBoardSizeModifier.zip` from the
   [latest release](https://github.com/n-popescu/vcb-board-size-modifier/releases/latest), or
   build it yourself: `./build.sh`.
3. Drop that zip into the game's `mods/` folder (**📁 Mods folder** in the launcher).
4. Press **▶ Launch game**, find the **Board** card in the circuit-editor side panel (between
   **Cursor Info** and **Inks**), enter a size, and press **Apply**.

## How it works

VCB caches the board size in a lot of places. On **Apply**, the mod reconfigures all of the
*mutable* ones and rebuilds the board so everything agrees on the new square side:

- the shared `C.CIRCUIT` size/rect (read live by the color picker, in-sim clicks, the compiler's
  render size, saving, and the multiplayer board-digest);
- the `Editor`'s cached `CIRCUIT_SPAN / CIRCUIT_SIZE / CIRCUIT_RECT`, plus a rebuild of the four
  layer images (`LOGIC / PAINT_ON / PAINT_OFF / DATA`) at the new size with the old content
  copied in;
- the native `TransistorEditorHelper` (`initialize(side)` — used by bucket-fill / transpose);
- `History` (cleared, since old undo snapshots are a different size) and its cached size;
- the `Camera` pan limits, the `Board` panel, and the `CircuitRenderer` prepass viewport + rects.

All of this happens from the mod's own nodes; no game file is edited. Multiplayer sync is a single
node at `/root/BoardSizeSync` with `remote` RPCs, riding the same ENet peer the multiplayer mod
already set up: the **field value is mirrored live as you type** (so both players share one pending
number), and **Apply resizes both boards**. With the multiplayer mod absent it simply resizes
locally.

## The board texture grows too (v1.2.0)

The visible board — the tinted, grid-lined square, plus the ink-symbol overlay — is drawn by
shaders that baked the board size as a constant, so earlier versions left it a 2048 island you
could draw *outside* of. It now **grows with the board**: on Apply the mod rewrites those shaders
for the new size (and resizes the background quad), so the grid and overlay cover the whole board.

**Drawing on a big board is also fast now.** The game re-uploaded all three full-board layer
textures on every mouse-move while drawing — negligible at 2048, but hundreds of megabytes per
move at 8192 (the "it lags a lot when I draw" you'd have hit). The mod now uploads **only the
region a stroke actually changed**, so drawing cost tracks the brush, not the board. This kicks
in only past 2048; a default board is unchanged.

## Limitations

- **Square only** — an engine constraint, not a UI shortcut (see above).
- **Big boards are heavy.** An `N×N` board is four `N×N` RGBA images plus an `N×N` render target;
  memory and per-frame render cost grow with `N²`, so at 8192 that's already on the order of a
  gigabyte of image memory — and since there's **no cap**, anything beyond the recommended 8192
  climbs fast and needs a genuinely powerful PC. Start modest (e.g. 4096). Starting a stroke still
  re-uploads the layer once (to re-sync), so the very first click of a stroke on a huge board can
  hitch briefly; the drawing itself stays smooth.
- **Entity-highlight hover** (during simulation) reads a `const` rect that can't be changed at
  runtime, so hovering to highlight an entity only works within the original 2048×2048 region.
- **Loading a project** re-creates the layers at the *saved* size, which can disagree with the
  render pipeline's current size until you Apply again. Resizing is meant for the live session.
- **Multiplayer:** both players need this mod installed. The size field syncs live and Apply
  resizes both boards; a client that joins *after* a resize isn't auto-told the current size (same
  limitation as project-load sync in the multiplayer mod), so resize once both are connected.

## Building

```bash
./build.sh          # → npopescu-VCBBoardSizeModifier.zip
```

CI (`.github/workflows/build.yml`) builds the zip on every push/PR and **auto-publishes a GitHub
Release** when `version_number` in `mods-unpacked/npopescu-VCBBoardSizeModifier/manifest.json` is
bumped on `main` (version-gated). A manual `v*` tag push also publishes.

## Caveat — needs on-device testing

There is **no Godot binary in CI**, so the GDScript here can't be parse-checked or run
automatically. It was written to match VCB's own patterns and reviewed line-by-line, but please
verify in-game. Mod Loader logs are written to the game's `user://` data dir (`ModLoader.log`).
