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
> wide) or reads out of bounds (wider than tall). The UI is a single **Board size** field with a
> **floor of `MIN_SIDE` = 2048** and **no hard upper cap** — the size is effectively unbounded
> ("infinite"); larger boards just need a more powerful PC, so the field only *recommends* staying
> at/under **8192** (advisory text, not a clamp). The field lives in the side-panel **Board**
> category (see §5), not a popup.

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

### 2a. Board TEXTURE + draw performance (v1.2.0, extended v1.4.0)

Three things a resize used to *not* do, now handled:

- **The board texture grows with the board.** The visible board (the tinted, grid-lined
  square) is drawn by `background.shader`, and the ink-symbol tiling by
  `ink_symbols_overlay.shader`; both bake `const float board_size = 2048.0` (the background
  also bakes the quad `size = 8192.0` / `origin = 3072.0`). A runtime mod can't set a shader
  `const` via `set_shader_param`, but it *can* rewrite the shader source and recompile it. So
  `board_resizer.gd :: _apply_board_textures(side)` takes the **pristine** source (from the
  game's `<shader>.gd` companion — the same code `gdshader_loader.gd` loads at startup),
  substitutes the sizes for the current board, and sets `material.shader.code` **in place**
  (same `Shader` object, so material params and CircuitRenderer's cached `symbmat`/`mat` stay
  valid). For the background it also resizes the `World/Background` quad to `side + 2*3072` and
  keeps the grid's world cell-size/line-weight identical to vanilla (pin the weight to the
  8192 quad; scale the grid frequency by `size/8192`). Sources are cached pristine on first
  use so repeated resizes never patch already-patched code.
- **Drawing on a grown board stays fast.** Vanilla rebuilds three full-board `ImageTexture`s
  on every `ed_layers_resources_change`, and a stroke fires that per mouse-move — an
  O(side²) upload each move (≈768 MB/move at 8192). Two **script extensions** fix it:
  `extensions/tool_array_pencil_eraser.gd` reports the exact rectangle a stroke changed, and
  `extensions/circuit_renderer.gd` uploads only that rectangle for the one changed layer via
  `VisualServer.texture_set_data_partial`. **Every** event of a stroke takes this path — including
  the first click (v1.3.0): its dirty rect is anchored at the clicked pixel alone (not from the
  stale `last_pos` left by the previous stroke), so starting a stroke no longer re-uploads the
  whole board (the ≈768 MB/click hitch at 8192). The cache stays authoritative because every
  non-stroke change (undo/redo, bucket, selection, resize, load, remote MP draw) still runs the
  full rebuild, and the flush falls back to a full rebuild whenever the cache isn't ready. It's
  **gated to boards larger than 2048** — a default board is byte-for-byte the stock path. `E.echo`
  is synchronous, so arming the renderer before `super.draw()` and flushing after brackets exactly
  the one event `draw()` emits.
- **The board isn't re-rendered every frame when nothing changed (v1.4.0).** The board is composited
  by an offscreen `PrepassViewport` whose scene sets `render_target_update_mode = UPDATE_ALWAYS`, so
  it re-renders every visible board pixel *every frame* regardless of change. At 8192 that's ~67 M
  fragments × many texture samples per frame — it pins the GPU and drags the whole app's frame-rate
  down (felt as lag while drawing **and** while merely viewing/panning). In **edit** mode the prepass
  output only changes on discrete events, so `extensions/circuit_renderer.gd` switches it to render
  **on demand**: a dirty flag re-arms `UPDATE_ONCE` when the board changed (draw/undo/layer/palette/
  overlay/resize/load), plus a low-frequency heartbeat (~4/s) as a safety net for anything not
  explicitly tracked (e.g. VMEM/vinput blink while those panels are open). During **simulation** the
  state changes every tick, so it keeps the vanilla `UPDATE_ALWAYS`. Gated to boards > 2048 (a 2048
  board keeps the exact vanilla always-on path). Panning/zooming a static board now re-renders the
  prepass **zero** times (the cached `ViewportTexture` is reused; only the screen-bounded
  post-processing redraws).

**Values that are `const` in game scripts still can't be changed** from a runtime mod: notably
`circuit_renderer.gd`'s `const CIRCUIT_RECT` (only used for entity-highlight hover — so
hover-highlight past the original 2048 region is still off). The background / ink-symbol shader
consts are no longer a limitation (see above); don't claim they are.

**What the on-demand prepass does NOT fix, and why chunking isn't done.** On-demand rendering
removes *redundant* full-board renders (idle, panning, between strokes), but it does **not** shrink
the cost of a single prepass render: a fast continuous stroke still triggers one full-board render
per changed frame, so a huge board can still cost per-frame O(area) *while actively dragging* on a
weak GPU. The only true fix is tiled/chunked rendering (re-render only the 2048-ish tile the stroke
touched). That was analysed and **rejected** for now: the prepass is a single full-board `Viewport`
(a Viewport always re-renders its whole size — you can't render a sub-rect), splitting it into N
tile-viewports risks seams where the shader reads neighbouring pixels (ink-symbol tiling, cross/
tunnel/bus context), gives **zero** benefit during simulation (the whole state texture changes every
tick → every tile dirty), and requires rebuilding the game's `main.tscn` render graph + display/
post-processing path from a runtime mod — far more invasive than rewriting shader `code` in place.
(Multiplayer is *not* a blocker: rendering is local/visual and not part of the deterministic sim.)
A separate, still-open per-stroke cost is the undo snapshot: `history.gd::_add_to_stack` duplicates
+ ZSTD-compresses + hex-encodes the whole layer on each stroke *release* (O(area)); it's left alone
because `history.gd` is extended by the multiplayer mod (this mod deliberately avoids the scripts MP
extends — see §5).

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

**Late-join size sync (v1.4.0).** The MP mod starts every join on a blank board and transfers the
host's board to a late joiner only via the host's manual **"Recheck board sync"** (a tiled digest
in `mp_draw_sync.gd`) — but that digest is size-relative and **bails on a size mismatch**, so a
joiner still at 2048 could never receive a 4096 host board. Fixed from this mod only (no MP change):
- `board_resizer.gd` polls for the `MP` autoload (load order isn't fixed) and connects to its
  `player_connected` signal. When a peer connects and **we are the host** with a non-default board,
  we `rpc_id(peer, "_rpc_apply_size", side)` so the newcomer resizes to match *before* the content
  sync. (Only the host acts; a joiner's `player_connected` for the host is ignored.)
- `apply_board_size` calls `MPDrawSync._reset_digest()` (soft, `has_method`-guarded) after every
  resize so the tiled sync recomputes tile counts at the new size. Runs on both peers (the resize is
  mirrored), so "resize → Recheck board sync" works even mid-session.
Known limitation: the digest still pulls at most `_DIGEST_MAX_TILES_PER_REQ` (64) tiles per click,
so fully transferring a large board to a fresh joiner needs several "Recheck board sync" presses.

## 3a. Saving the board size in the .vcb (v1.4.0)

`.vcb` projects are JSON; the vanilla loader (`file_system.gd::parse_project`) seeds a skeleton then
copies **every** key from the file, so an extra top-level key survives a load/save round-trip.
`extensions/file_system.gd` uses that for a **shared, namespaced** container — the general convention
for any mod to persist per-file data (see the vcb-mp `CLAUDE.md`):

```
"modded": { "<mod-id>": { …that mod's data… }, … }
```

A **non-empty** `"modded"` marks a file as "made with mods"; an empty/absent one is a vanilla file
(the multiplayer mod, e.g., stores nothing here). This mod stores only `{"side": <n>}` under
`"npopescu-VCBBoardSizeModifier"`, and:
- **Save** (`save_file` override) **merges** its entry into `project["modded"]` on a MANUAL save
  (never replacing other mods' entries), and **removes** it when the board is back at 2048 — so a
  default board saves as a clean, vanilla-openable file. Autosaves skip the stamp but still load
  correctly via the fallback below (they re-serialize the live layers, which carry the real size).
- **Load** (`open_file` override) resizes the board to the saved side *after* the base loads the
  layers (it sets `project` and loads the layer images before its `yield`, so the super-call returns
  with both in place). The side is read from the `"modded"` entry, falling back to the loaded LOGIC
  layer's own width (robust for older files / autosaves). In a live MP session the load-resize
  broadcasts, so opening a sized project on the host also resizes the peer.

## 3b. If you add a `Popup` dialog UI — avoid the "empty space beneath everything" bug

Any mod window built as a `Popup` whose content is a container (VBox/PanelContainer, as ours and
the multiplayer window are) must **re-fit on the next idle frame**, or it opens with a tall,
invisible dead zone hanging below the visible content (it looks like "a zone beneath everything
that extends", and it still swallows clicks). Why: `set_as_minsize()` runs *synchronously*, but a
container only recomputes its `rect_min_size` on the **next idle frame** — so calling
`set_as_minsize()` right after `popup_centered()` sizes the popup to the *stale, pre-layout*
minimum (usually too tall). The one-liner fix, applied on every open (and again whenever the set of
visible child sections changes):

```gdscript
popup_centered()
set_as_minsize()
_refit()               # yield(get_tree(), "idle_frame"); set_as_minsize(); re-center

func _refit() -> void:
	yield(get_tree(), "idle_frame")
	if not visible:
		return
	set_as_minsize()
	_center()          # re-center against U.get_global_viewport_size_scaled() to match flux
```

> **The canonical popup skeleton is the multiplayer window** —
> `vcb-multiplayer/.../scripts/gui/mp_window.gd` (`open_window` / `_refit` / `_center`). Copy that
> shape for any new popup: a `PanelContainer` + `MarginContainer` + `VBoxContainer` styled with the
> dark `StyleBoxFlat`, presented via `res://src/gui/flux/flux_mod_popup.tscn` for the shared dimmed
> backdrop + scale/fade entrance, and re-fit as above.

Note: **this mod no longer ships a popup** — its Board size field moved into the side-panel
**Board** category (§5), so there's no dead zone to hit here anymore. The guidance above is kept
for the next mod that *does* add a popup. (The old `board_size_window.gd` carried the same fix; see
its git history if you need the concrete before/after.)

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
├── mod_main.gd               installs the script extensions, then waits for Main and builds the
│                             /root/BoardSizeSync node (no popup/toolbar — the UI is a side-panel card)
├── scripts/
│   ├── board_resizer.gd      the resize routine (incl. board-texture shader rebuild), the
│   │                         /root/BoardSizeSync MP RPC node + late-join size sync, AND the lazy
│   │                         injection of the side-panel "Board" category (_maybe_build_panel)
│   └── gui/board_panel.gd    the side-panel "Board" category: a narrow size field + Apply, docked
│                             between the "Cursor Info" card and the "Inks" zone (models the MP
│                             "Players" panel, mp_players_panel.gd). Exposes reflect_side /
│                             set_pending_text so the resizer's MP RPCs drive it
└── extensions/               script extensions (installed in mod_main _init)
    ├── circuit_renderer.gd        caches layer textures + partial-uploads the changed rect,
    │                              and renders the prepass on-demand in edit mode (perf)
    ├── tool_array_pencil_eraser.gd   reports the changed rect around a stroke to the renderer
    └── file_system.gd            persists/restores the board size in the .vcb "modded" field
```

The extensions are installed with `ModLoaderMod.install_script_extension` in `mod_main`'s
`_init()` (same convention as the multiplayer mod). They target `res://src/world/circuit_renderer.gd`,
`res://src/editor/tool_array_pencil_eraser.gd`, and `res://src/editor/file_system.gd` — scripts the
multiplayer mod does *not* extend, so the two mods coexist. Super-calls use `.method()` (GDScript 3.5).

Versioning: bump `manifest.json` `version_number` (semver) on every functional change; a bump
landing on `main` auto-cuts a Release.

## 6. Git / PR workflow for agents

- Branch from `origin/main` (`git fetch origin main` first).
- **Branch names MUST start with `claude/` and END WITH the current session id**, or `git push`
  fails with HTTP 403. Example: `claude/<topic>-<sessionid>`.
- Commits are auto-signed (ssh). Don't disable signing/hooks.
- Open PRs against `main`; squash-merge. Note that changes are unverified in-engine and give a
  test recipe (find the **Board** card in the circuit-editor side panel — between "Cursor Info" and
  "Inks" — set e.g. 4096, Apply; draw/simulate in the new area; with the multiplayer mod, type in
  the field on one peer and confirm the other's field updates live, then Apply and confirm both
  boards resize). For v1.4.0 also check: panning/zooming a large board is
  smooth (no per-frame prepass); a fast stroke on a large board still costs per-frame render
  (expected — see §2a); **save** a 4096 board and reopen it → it reopens at 4096 (and the file's
  JSON has a `"modded"` block); save a 2048 board → no `"modded"` block; **late-join** MP after the
  host resized → the joiner's board resizes to match, then "Recheck board sync" transfers content.
