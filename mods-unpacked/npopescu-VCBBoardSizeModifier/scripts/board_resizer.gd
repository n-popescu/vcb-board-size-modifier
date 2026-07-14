extends Node

# board_resizer.gd — core resize routine + multiplayer sync point for the Board Size Modifier.
#
# VCB's board is SQUARE: the native compiler takes side = image.width and uses it for BOTH axes
# (see vcb-engine-recovery/docs/compiler_pipeline.md — "Circuits are square, so side is used for
# both dimensions"). A non-square image would truncate (tall) or read out of bounds (wide), so
# this only ever produces a square side x side board, side in [MIN_SIDE, MAX_SIDE].
#
# apply_board_size() reconfigures every piece of board-size state the game caches — the shared
# C.CIRCUIT const dict (mutable at runtime in GDScript 3.5) and the cached copies on the Editor /
# History / Camera / Board / CircuitRenderer nodes — rebuilds the four editor layer images
# (preserving content) and re-inits the native TransistorEditorHelper. Nothing here edits a game
# file; it only writes to live nodes/singletons.
#
# This node lives at /root/BoardSizeSync (a stable path) so that, when the VCB Multiplayer mod
# has a live peer, one player's resize is mirrored to the other over the same ENet peer (keeping
# both boards the same size, which the multiplayer mirroring requires).

const MIN_SIDE := 2048
const MAX_SIDE := 8192

# Board-texture shaders. The visible board (the tinted, grid-lined square) is drawn by the
# background shader on a padded quad; the ink-symbol overlay tiles per board pixel. Both bake
# the board size as `const float board_size = 2048.0` (the background also bakes the quad
# `size`/`origin`). A runtime mod can't set a shader const via set_shader_param, but it CAN
# rewrite the shader source and recompile it in place — which is what _apply_board_textures does.
const BG_SHADER_PATH := "res://src/graphics/shaders/background.shader"
const INK_SHADER_PATH := "res://src/graphics/shaders/ink_symbols_overlay.shader"
const BG_PAD := 3072            # padding kept around the board inside the background quad (vanilla)
const BG_BASE := 8192.0         # vanilla quad size (2048 + 2*3072) — the grid's reference scale

var _applying_remote := false
var _mp_connected := false

# Pristine shader sources, cached on first use so repeated resizes always patch from vanilla.
var _bg_src := ""
var _ink_src := ""
var _bg_src_loaded := false
var _ink_src_loaded := false


func _ready() -> void:
	# Watch for a multiplayer session so a peer that joins AFTER we've grown the board still gets
	# our size (the MP board-content sync requires equal sizes). MP is built by a separate mod and
	# may come up a little after us, so retry the connection for a short while.
	_bsm_connect_mp_deferred()


func get_current_side() -> int:
	if typeof(C.CIRCUIT.SIZE) == TYPE_VECTOR2:
		return int(C.CIRCUIT.SIZE.x)
	return MIN_SIDE


# True when the editor is in edit mode (not simulating). Resizing should be initiated only in
# edit mode — mid-simulation the running model is size-independent but the display would desync.
func is_editor_mode() -> bool:
	var editor := _editor()
	if editor == null:
		return true
	var v = editor.get("is_in_editor")
	if typeof(v) == TYPE_BOOL:
		return v
	return true


func clamp_side(side: int) -> int:
	if side < MIN_SIDE:
		side = MIN_SIDE
	if side > MAX_SIDE:
		side = MAX_SIDE
	return side


# UI entry point: clamp, apply locally, mirror to the MP peer if a session is live. Returns the
# side that was actually applied.
func request_resize(side: int) -> int:
	side = clamp_side(side)
	apply_board_size(side, true)
	return side


func apply_board_size(side: int, do_broadcast: bool) -> void:
	side = clamp_side(side)
	var new_size := Vector2(side, side)
	var new_rect := Rect2(Vector2.ZERO, new_size)

	# 1) Shared C.CIRCUIT const dict. GDScript 3.5 allows mutating a const Dictionary's contents
	#    at runtime — the game itself relies on this (events.gd::_init mutates its const event
	#    dicts the same way). Live readers include tool_color_picker, the editor cursor logic,
	#    simulator in-sim clicks, the compiler's render size, file_system save, and the
	#    multiplayer board-digest tiling.
	var circ = C.CIRCUIT
	circ.SIZE = new_size
	circ.SIDE = side
	circ.RECT = new_rect

	# 2) Editor: cached copies + rebuild the 4 layers + native helper + history.
	var editor := _editor()
	if editor != null:
		editor.CIRCUIT_SPAN = side
		editor.CIRCUIT_SIZE = new_size
		editor.CIRCUIT_RECT = new_rect
		_resize_layer_array(editor, side)
		_resize_aux_image(editor, "vmem_image", side)
		_resize_aux_image(editor, "vinput_image", side)
		var teh = editor.get("TEH")
		if teh != null:
			teh.initialize(side)
		var history = editor.get_node_or_null("History")
		if history != null:
			history.CIRCUIT_SIZE = new_size
			# Old undo snapshots are a different size; clear the stack so undo can't mix sizes.
			if history.has_method("public_clear_history"):
				history.public_clear_history()
		_emit_layers_change(editor)

	# 3) World: board panel, camera pan limits, render pipeline sizes.
	var board := _n("Main/World/Board")
	if board != null:
		board.rect_min_size = new_size
		board.rect_size = new_size
	var camera := _n("Main/World/Camera")
	if camera != null:
		camera.CIRCUIT_SIZE = new_size
	_resize_renderer(new_size)

	# 4) Grow the board TEXTURE too: the background grid + ink-symbol shaders bake the board
	#    size as a shader const, so without this the visible board stays a 2048 island you can
	#    draw outside of. This rebuilds those shaders for the new side.
	_apply_board_textures(side)

	# 5) Mirror to the multiplayer peer, if a live session exists.
	if do_broadcast and not _applying_remote:
		_broadcast(side)


func _resize_layer_array(editor: Node, side: int) -> void:
	var imgs = editor.images
	if typeof(imgs) != TYPE_ARRAY:
		return
	for i in imgs.size():
		imgs[i] = _grown_copy(imgs[i], side)


func _resize_aux_image(editor: Node, prop: String, side: int) -> void:
	var old_img = editor.get(prop)
	if not (old_img is Image):
		return
	editor.set(prop, _grown_copy(old_img, side))


# A new side x side RGBA8 image with the old content copied top-left (clipped when shrinking).
func _grown_copy(old_img, side: int) -> Image:
	var new_img := Image.new()
	new_img.create(side, side, false, Image.FORMAT_RGBA8)
	if old_img is Image and old_img.get_width() > 0 and old_img.get_height() > 0:
		var cw := int(min(old_img.get_width(), side))
		var ch := int(min(old_img.get_height(), side))
		new_img.blit_rect(old_img, Rect2(0, 0, cw, ch), Vector2.ZERO)
	return new_img


func _emit_layers_change(editor: Node) -> void:
	E.echo(E.ed_layers_resources_change, {
		E.ed_layers_resources_change.p_layers: editor.images,
	})


func _resize_renderer(new_size: Vector2) -> void:
	var cr := _n("Main/World/CircuitRenderer")
	if cr == null:
		return
	cr.rect_size = new_size
	var vp := cr.get_node_or_null("PrepassViewport")
	if vp != null:
		vp.size = new_size
	var pcr := cr.get_node_or_null("PrepassViewport/PrepassColorRect")
	if pcr != null:
		pcr.rect_min_size = new_size
	var dpp := cr.get_node_or_null("DownsamplingPostProcessing")
	if dpp != null:
		dpp.rect_min_size = new_size
	var iso := cr.get_node_or_null("InkSymbolsOverlay")
	if iso != null:
		iso.rect_min_size = new_size


# --- board textures (background grid + ink-symbol overlay) --------------------------------
# Rebuild the two board-size-baking shaders for `side`. Both mutate the shader `code` in place
# (same Shader object) so the material keeps its param values and any cached references (e.g.
# CircuitRenderer's `symbmat`) stay valid. Best-effort and additive: if a node/material/source
# is missing, we skip it — the resize still works, the texture just doesn't grow.
func _apply_board_textures(side: int) -> void:
	_apply_background_texture(side)
	_apply_ink_symbols_texture(side)


func _apply_background_texture(side: int) -> void:
	var bg := _n("Main/World/Background")
	if bg == null:
		return
	# Grow the background quad so the padded board region fits (anchors are 0, so margins are
	# absolute world positions; the quad must be exactly (side + 2*pad) to match the shader's
	# `size`, positioned so local (pad,pad) maps to world (0,0)).
	bg.margin_left = -float(BG_PAD)
	bg.margin_top = -float(BG_PAD)
	bg.margin_right = float(side + BG_PAD)
	bg.margin_bottom = float(side + BG_PAD)
	var mat = bg.get("material")
	if not (mat is ShaderMaterial):
		return
	var src := _background_source(mat)
	if src == "":
		return
	var total := side + 2 * BG_PAD
	var code := src
	code = _set_const_float(code, "size", float(total))
	code = _set_const_float(code, "board_size", float(side))
	code = _set_const_float(code, "origin", float(BG_PAD))
	# Keep the grid's world cell-size and line weight identical to vanilla as the quad grows:
	# pin the line-weight to the vanilla 8192 quad, and scale the grid frequency by size/8192 so
	# cells stay the same size in world space (at side 2048 both are no-ops).
	code = code.replace("(gridscale / size)", "(gridscale / 8192.0)")
	code = code.replace(
		"sin(fract(UV * amount) * PI)",
		"sin(fract(UV * amount * (size / 8192.0)) * PI)")
	_recompile_in_place(mat, code)


func _apply_ink_symbols_texture(side: int) -> void:
	var iso := _n("Main/World/CircuitRenderer/InkSymbolsOverlay")
	if iso == null:
		return
	var mat = iso.get("material")
	if not (mat is ShaderMaterial):
		return
	var src := _ink_source(mat)
	if src == "":
		return
	# The overlay rect is sized to the board, so UV*board_size must equal the board pixel — use
	# the real board side (not the padded quad size).
	_recompile_in_place(mat, _set_const_float(src, "board_size", float(side)))


# Recompile the material's shader from `code`, in place (same Shader object → params + cached
# references survive). No-op if there's no shader to recompile.
func _recompile_in_place(mat, code: String) -> void:
	if not (mat is ShaderMaterial) or mat.shader == null:
		return
	mat.shader.code = code


# Replace `const float <name> = <number>;` with `= <value>;`. No-op (returns code unchanged) if
# the declaration isn't found, so an upstream shader change degrades gracefully. Uses a plain
# Array (not the PoolStringArray from split) so in-place element assignment is well-defined.
func _set_const_float(code: String, cname: String, value: float) -> String:
	var lines := Array(code.split("\n"))
	var needle := "const float " + cname + " ="
	var replacement := "const float " + cname + " = " + str(int(round(value))) + ".0;"
	for i in range(lines.size()):
		if str(lines[i]).strip_edges().begins_with(needle):
			lines[i] = replacement
			break
	return PoolStringArray(lines).join("\n")


func _background_source(mat) -> String:
	if not _bg_src_loaded:
		_bg_src = _shader_source(BG_SHADER_PATH, mat)
		_bg_src_loaded = true
	return _bg_src


func _ink_source(mat) -> String:
	if not _ink_src_loaded:
		_ink_src = _shader_source(INK_SHADER_PATH, mat)
		_ink_src_loaded = true
	return _ink_src


# Pristine shader source: prefer the game's `<path>.gd` companion (the same source the game's
# GDshaderLoader reads at startup); fall back to the live material code if it's still vanilla.
func _shader_source(path: String, mat) -> String:
	var gd_path := path + ".gd"
	if ResourceLoader.exists(gd_path):
		var res = load(gd_path)
		if res != null:
			var inst = res.new()
			if inst != null:
				var code = inst.get("shader_code")
				if typeof(code) == TYPE_STRING and not (code as String).empty():
					return str(code)
	if mat is ShaderMaterial and mat.shader != null:
		var live := str(mat.shader.code)
		if live.find("board_size") != -1:
			return live
	return ""


func _editor() -> Node:
	var ed := _n("Main/Systems/Editor")
	if ed == null:
		var main := get_tree().root.get_node_or_null("Main")
		if main != null:
			ed = main.find_node("Editor", true, false)
	return ed


func _n(rel: String) -> Node:
	var root := get_tree().root
	if root == null:
		return null
	return root.get_node_or_null(rel)


# --- multiplayer sync ---------------------------------------------------------------------
# True when a live multiplayer session exists (the VCB Multiplayer mod is loaded, connected and
# in-game). Queried via get_node_or_null + Object.get so this mod also works with MP absent.
func _live_session() -> bool:
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null:
		return false
	if get_tree().network_peer == null:
		return false
	return bool(mp.get("is_connected")) and bool(mp.get("is_game_started"))


func _broadcast(side: int) -> void:
	if not _live_session():
		return
	rpc("_rpc_apply_size", side)


remote func _rpc_apply_size(side: int) -> void:
	_applying_remote = true
	apply_board_size(int(side), false)
	_applying_remote = false
	var win := _window()
	if win != null and win.has_method("reflect_side"):
		win.reflect_side(int(side))


# Live-mirror the pending field text (as the other player types, before Apply) so both players'
# fields always show the same value. Sends the raw text — clamping happens only on Apply.
func broadcast_pending_text(text: String) -> void:
	if not _live_session():
		return
	rpc("_rpc_set_pending_size", text)


remote func _rpc_set_pending_size(text) -> void:
	var win := _window()
	if win != null and win.has_method("set_pending_text"):
		win.set_pending_text(str(text))


func _window() -> Node:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	return main.find_node("BoardSizeWindow", true, false)


# --- multiplayer late-join size sync ------------------------------------------------------
# The live resize mirroring above only reaches peers already in the session. A peer that joins
# AFTER we grew the board starts on a fresh 2048 board, and the MP board-content sync refuses to
# run while the two sizes differ. So, as the host, we push our current size to a newcomer (and on
# game start) so its board matches ours before any content sync.
func _bsm_connect_mp_deferred() -> void:
	# /root/MP is created by the multiplayer mod, possibly a few frames after us. Poll briefly.
	for _i in range(60):
		if _bsm_try_connect_mp():
			return
		yield(get_tree(), "idle_frame")


func _bsm_try_connect_mp() -> bool:
	if _mp_connected:
		return true
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null:
		return false
	if mp.has_signal("player_connected") and not mp.is_connected("player_connected", self, "_bsm_on_mp_player_connected"):
		mp.connect("player_connected", self, "_bsm_on_mp_player_connected")
	if mp.has_signal("game_started") and not mp.is_connected("game_started", self, "_bsm_on_mp_game_started"):
		mp.connect("game_started", self, "_bsm_on_mp_game_started")
	_mp_connected = true
	return true


func _bsm_on_mp_player_connected(id: int) -> void:
	_bsm_push_size(int(id))


func _bsm_on_mp_game_started() -> void:
	_bsm_push_size(0)


func _bsm_push_size(target_id: int) -> void:
	if not _bsm_is_host_session():
		return
	var side := get_current_side()
	if side <= MIN_SIDE:
		return  # default size — nothing to sync
	# Let the newcomer's on-connect new_file() settle before we resize its board.
	yield(get_tree().create_timer(0.5), "timeout")
	if not _bsm_is_host_session() or get_tree().network_peer == null:
		return
	if int(target_id) == 0:
		rpc("_rpc_apply_size", side)
	else:
		rpc_id(int(target_id), "_rpc_apply_size", side)


func _bsm_is_host_session() -> bool:
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null or get_tree().network_peer == null:
		return false
	return bool(mp.get("is_host")) and bool(mp.get("is_connected"))


# --- modded save data ---------------------------------------------------------------------
# Persist the board size inside saved .vcb projects via the generic /root/ModSaveData registry
# (see scripts/mod_save_registry.gd + extensions/file_system.gd). Registered from mod_main.

# What we store under modded["npopescu-VCBBoardSizeModifier"]. Returns {} at the default size so a
# normal board still writes a byte-vanilla file (an empty/absent "modded" section).
func mod_save_data() -> Dictionary:
	var side := get_current_side()
	if side <= MIN_SIDE:
		return {}
	return {"side": side}


# Apply our slice of a loaded file's modded section: resize to the saved board size.
func mod_load_data(data) -> void:
	if typeof(data) != TYPE_DICTIONARY or not data.has("side"):
		return
	var side := clamp_side(int(data["side"]))
	if side != get_current_side():
		apply_board_size(side, false)


# Safety net after any project load: the loaded layer images carry the true board size in the
# .vcb, so make the engine match them even for files with no "modded" section (older/grown saves).
# No-op when already consistent.
func reconcile_to_loaded_layers() -> void:
	var editor := _editor()
	if editor == null:
		return
	var imgs = editor.get("images")
	if typeof(imgs) != TYPE_ARRAY or imgs.empty() or not (imgs[0] is Image):
		return
	var loaded := clamp_side(int(imgs[0].get_width()))
	if loaded != get_current_side():
		apply_board_size(loaded, false)
