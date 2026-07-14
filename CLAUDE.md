# CLAUDE.md — agent context for `vcb-board-size-modifier`

Read this first. Dense on purpose, for an AI coding agent. If it conflicts with the code, the
code wins — but verify before assuming this file is stale.

---

## 0. What this repo is

- A **runtime [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) mod** for
  **Virtual Circuit Board** that grows the board past the default 2048×2048. Pure GDScript +
  assets; it loads at runtime from the game's `mods/` folder and **never replaces `vcb.pck`**.
- It runs on the **original, closed-source VCB engine**. The native `Transistor*` classes are
  provided by the game at runtime; the "unknown class" editor warning for them is EXPECTED —
  never stub them. This mod touches exactly one native call: `TransistorEditorHelper.initialize`.
- It is **independent of, but compatible with**, the [VCB Multiplayer](https://github.com/n-popescu/vcb-multiplayer)
  mod. It never requires it; when a multiplayer session is live it mirrors a resize to the peer.

## 1. The core constraint: boards are SQUARE

The closed engine's compiler reads the board dimension dynamically (`side = image.width`) — that
is why a larger board can compile/simulate at all — but it uses that single `side` for **both**
axes (`scan_pixels` loops `x, y` in `[0, side)`; see
`vcb-engine-recovery/docs/compiler_pipeline.md`, "Circuits are square, so `side` is used for both
dimensions"). So:

> **Only ever produce a square `side × side` board.** A non-square image truncates (taller than
> wide) or reads out of bounds (wider than tall). The UI is a single **Board size** field
> clamped to `[MIN_SIDE, MAX_SIDE]` = `[2048, 8192]`.

## 2. How the resize works (what state must move together)

VCB caches the board size in many places. `board_resizer.gd :: apply_board_size(side, broadcast)`
reconfigures every **mutable** one, in this order, then rebuilds the board:

1. `C.CIRCUIT.SIZE / SIDE / RECT` — a `const` Dictionary, but GDScript 3.5 allows mutating const
   collection *contents* at runtime (this is the linchpin; it's read live by the color picker,
   editor cursor logic, simulator in-sim clicks, the compiler's render `size`, `file_system`
   save, and the multiplayer board-digest tiling).
2. `Editor` (`Main/Systems/Editor`): `CIRCUIT_SPAN/SIZE/RECT`; rebuild the 4 layer images
   (`editor.images`) at the new size, copying old content top-left; resize `vmem_image` /
   `vinput_image` if present; `TEH.initialize(side)`; clear + resize `History`; then emit
   `E.ed_layers_resources_change` so the renderer picks up the new textures.
3. `Main/World/Board` panel rect, `Main/World/Camera.CIRCUIT_SIZE` (pan limits), and
   `Main/World/CircuitRenderer` (its `rect_size`, `PrepassViewport.size`, and the
   `PrepassColorRect / DownsamplingPostProcessing / InkSymbolsOverlay` min sizes).

**Values that are `const` in game scripts can't be changed** from a runtime mod: notably
`circuit_renderer.gd`'s `const CIRCUIT_RECT` (only used for entity-highlight hover) and the
`board_size = 2048.0` baked into the background / ink-symbol shaders (cosmetic). These are the
documented v1 limitations — don't pretend they're fixed.

## 3. Multiplayer sync

`board_resizer.gd` is added at `/root/BoardSizeSync` (a stable path so `rpc()` resolves on both
peers). Two `remote` RPCs ride the multiplayer mod's ENet peer (this mod never opens its own):

- **`_rpc_set_pending_size(text)`** — the size field is mirrored **live as the user types**
  (`board_size_window.gd :: _on_text_changed` → `broadcast_pending_text`), so both players always
  see the same pending number before anyone presses Apply. Raw text is sent (clamping is deferred
  to Apply). The receiver sets the field via `set_pending_text`, guarded by `_suppress_broadcast`
  so it doesn't echo, and it won't yank the caret if that peer is mid-edit.
- **`_rpc_apply_size(side)`** — Apply resizes locally and mirrors the resize to the peer, which
  applies with `broadcast = false` (guarded by `_applying_remote`) so it never echoes back.

Both are gated on `_live_session()` (`/root/MP` present, `get_tree().network_peer != null`, and
MP's `is_connected` + `is_game_started` true — all via `get_node_or_null` / `Object.get(...)` so
the mod still works with the multiplayer mod absent). Both players must have this mod installed
for the RPCs to resolve.

## 4. Engine / GDScript constraints

- **Godot 3.5.1**, GDScript 3.5 semantics — **not** Godot 4. No Godot-4 syntax.
- **Tabs, not spaces**, in every `.gd`. Quick check: `grep -nP '^\t* +\S' <file>` must be empty
  for lines you add.
- `C` and `E` are the game's autoload singletons and are always present — reference them directly
  (as VCB's own code does). `MP` / `MPDrawSync` belong to the *multiplayer* mod and may be
  absent, so **never** reference them as globals — look them up with `get_node_or_null("MP")`.
- You **cannot run or parse-check GDScript** in CI here — review carefully and verify in-game.
  Mod Loader logs go to the game's `user://ModLoader.log`.

## 5. Layout

```
.github/workflows/build.yml   zips the package + auto-releases on version bump
build.sh                      → npopescu-VCBBoardSizeModifier.zip
mods-unpacked/npopescu-VCBBoardSizeModifier/
├── manifest.json             Mod Loader manifest (id = npopescu-VCBBoardSizeModifier)
├── mod_main.gd               waits for Main, builds the /root/BoardSizeSync node + window + toolbar button
└── scripts/
    ├── board_resizer.gd      the resize routine + the /root/BoardSizeSync MP RPC node
    └── gui/board_size_window.gd   the WindowDialog: a single Board size field + Apply
```

Versioning: bump `manifest.json` `version_number` (semver) on every functional change; a bump
landing on `main` auto-cuts a Release.

## 6. Git / PR workflow for agents

- Branch from `origin/main` (`git fetch origin main` first).
- **Branch names MUST start with `claude/` and END WITH the current session id**, or `git push`
  fails with HTTP 403. Example: `claude/<topic>-<sessionid>`.
- Commits are auto-signed (ssh). Don't disable signing/hooks.
- Open PRs against `main`; squash-merge. Note that changes are unverified in-engine and give a
  test recipe (open **Board**, set e.g. 4096, Apply; draw/simulate in the new area; with the
  multiplayer mod, type in the field on one peer and confirm the other's field updates live, then
  Apply and confirm both boards resize).
