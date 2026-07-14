extends "res://src/world/circuit_renderer.gd"

# Board Size Modifier — big-board render performance for the editor board.
#
# Two independent costs scale with board area and are addressed here:
#
# 1. PARTIAL GPU UPLOAD (the changed rectangle, not the whole board).
#    Vanilla rebuilds THREE full-board ImageTextures (create_from_image) on every
#    ed_layers_resources_change — and a pencil/array/eraser stroke fires that on every mouse-move.
#    That's an O(side*side) upload per move: fine at 2048 (48 MB), crippling at 8192 (~768 MB per
#    move). So we cache the three textures and, when the drawing tool hands us the exact changed
#    rectangle (board_size_mod_arm before its emit, board_size_mod_flush after), upload only that
#    rectangle for the one changed layer via VisualServer.texture_set_data_partial — for every event
#    of a stroke, including its first click. Everything else (editor init, project load, resize,
#    undo/redo, bucket, selection) still does a full rebuild identical to vanilla; the flush falls
#    back to a full rebuild whenever the cache isn't ready. Gated to boards > 2048 (a 2048 board is
#    byte-for-byte vanilla).
#
# 2. ON-DEMAND PREPASS (don't re-render the whole board every frame when nothing changed).
#    The board is composited by an offscreen PrepassViewport whose scene sets
#    render_target_update_mode = UPDATE_ALWAYS — it re-renders every visible board pixel EVERY frame
#    whether or not anything changed. At 2048 that's cheap; at 8192 it's ~67 M fragments * many
#    texture samples every frame, which pins the GPU and drops the whole app's frame-rate (felt as
#    lag while drawing AND while merely viewing/panning a large board). In EDIT mode the prepass
#    output only changes on discrete events (a draw, undo, layer switch, palette/overlay toggle,
#    resize, load), so we switch the viewport to render ON DEMAND: a dirty flag re-arms UPDATE_ONCE
#    when the board changed, plus a low-frequency heartbeat as a safety net for any change we don't
#    explicitly track (e.g. VMEM/vinput blink while those panels are open). During SIMULATION the
#    board state changes every tick, so we keep the vanilla UPDATE_ALWAYS there. Gated to boards
#    > 2048, so a 2048 board keeps the exact vanilla always-on behaviour. Panning/zooming a static
#    board no longer re-renders the prepass at all — the cached ViewportTexture is reused and only
#    the (screen-bounded) post-processing redraws. NOTE: this does not shrink the cost of a single
#    prepass render, so a fast continuous stroke on a huge board can still cost one full-board render
#    per changed frame — a true fix for that needs tiled/chunked rendering (see CLAUDE.md §2a).

var _bsm_tex := {}        # Editor.LAYER int -> the ImageTexture currently bound to the shader
var _bsm_armed := false   # a draw stroke is about to emit; skip the full rebuild, it'll flush

# On-demand prepass state.
const _BSM_DEFAULT_SIDE := 2048   # at/below this, keep vanilla UPDATE_ALWAYS (no change)
const _BSM_HEARTBEAT := 15        # frames between safety re-renders when idle on a big board (~4/s)
var _bsm_sim := false             # true while simulating (keep the prepass always-on)
var _bsm_dirty := true            # the prepass needs a render (start true for the first frame)
var _bsm_hb := 0                  # frames since the last heartbeat render


func _ready() -> void:
	._ready()
	# Drive the on-demand prepass from _process (the base script has no _process of its own).
	set_process(true)


# Per-frame: pick the PrepassViewport's update mode. Simulation or a default-size board → vanilla
# UPDATE_ALWAYS. A big board in edit mode → render only when the board changed (dirty) or on the
# periodic heartbeat; UPDATE_ONCE renders a single frame and Godot reverts it to UPDATE_DISABLED.
func _process(_delta: float) -> void:
	var vp := get_node_or_null("PrepassViewport")
	if vp == null:
		return
	if _bsm_sim or not _bsm_is_big_board():
		if vp.render_target_update_mode != Viewport.UPDATE_ALWAYS:
			vp.render_target_update_mode = Viewport.UPDATE_ALWAYS
		return
	_bsm_hb += 1
	if _bsm_dirty or _bsm_hb >= _BSM_HEARTBEAT:
		_bsm_dirty = false
		_bsm_hb = 0
		vp.render_target_update_mode = Viewport.UPDATE_ONCE
	elif vp.render_target_update_mode == Viewport.UPDATE_ALWAYS:
		# Just crossed into big+edit (e.g. after a resize); stop the always-on render. The dirty
		# path above renders the current board once, so nothing is left stale.
		vp.render_target_update_mode = Viewport.UPDATE_DISABLED


func _bsm_mark_dirty() -> void:
	_bsm_dirty = true


# True once the board has grown past the default — the only case we change behaviour for.
func _bsm_is_big_board() -> bool:
	return typeof(C.CIRCUIT.SIZE) == TYPE_VECTOR2 and int(C.CIRCUIT.SIZE.x) > _BSM_DEFAULT_SIDE


# Track sim/edit so the prepass is always-on while simulating (board state changes every tick) and
# on-demand while editing. Re-render once on the transition back to editing.
func _on_mi_mode_change_confirmed(is_simulating: bool) -> void:
	._on_mi_mode_change_confirmed(is_simulating)
	_bsm_sim = is_simulating
	_bsm_mark_dirty()


# Called by the tool right before super.draw() emits ed_layers_resources_change.
func board_size_mod_arm() -> void:
	_bsm_armed = true


func _ev_ed_layers_resources_change(_mode: int, _args: Dictionary) -> void:
	if _bsm_armed:
		return  # a stroke is feeding us; board_size_mod_flush() will do the partial upload
	var p_layers = _args[E.ed_layers_resources_change.p_layers]
	_bsm_full_rebuild(p_layers)


# Identical to the vanilla handler, but caches the three textures so we can update them in place.
func _bsm_full_rebuild(p_layers) -> void:
	if typeof(p_layers) != TYPE_ARRAY or p_layers.size() < 3:
		return
	var tex_a := ImageTexture.new()
	tex_a.create_from_image(p_layers[Editor.LAYER.LOGIC], 0)
	mat.set_shader_param("smp_ed_logic", tex_a)
	symbmat.set_shader_param("smp_ed_logic", tex_a)
	var tex_b := ImageTexture.new()
	tex_b.create_from_image(p_layers[Editor.LAYER.PAINT_ON], 0)
	mat.set_shader_param("smp_ed_paint_on", tex_b)
	var tex_c := ImageTexture.new()
	tex_c.create_from_image(p_layers[Editor.LAYER.PAINT_OFF], 0)
	mat.set_shader_param("smp_ed_paint_off", tex_c)
	_bsm_tex[Editor.LAYER.LOGIC] = tex_a
	_bsm_tex[Editor.LAYER.PAINT_ON] = tex_b
	_bsm_tex[Editor.LAYER.PAINT_OFF] = tex_c
	_bsm_mark_dirty()


# Upload only `rect` of `layer` (the stroke's changed region). Falls back to a full rebuild if the
# cache isn't ready, the sizes don't match, or partial upload isn't available.
func board_size_mod_flush(layer: int, rect: Rect2, layers) -> void:
	_bsm_armed = false
	if typeof(layers) != TYPE_ARRAY or layers.size() < 3:
		return
	if not _bsm_ready(layers):
		_bsm_full_rebuild(layers)
		return
	var tex = _bsm_tex.get(layer, null)
	var img = layers[layer]
	if tex == null or not (tex is ImageTexture) or not (img is Image):
		_bsm_full_rebuild(layers)
		return
	if not VisualServer.has_method("texture_set_data_partial"):
		_bsm_full_rebuild(layers)
		return
	var r := _bsm_clamp(rect, img.get_width(), img.get_height())
	if int(r.size.x) < 1 or int(r.size.y) < 1:
		return
	VisualServer.texture_set_data_partial(
		tex.get_rid(), img,
		int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y),
		int(r.position.x), int(r.position.y), 0, 0)
	_bsm_mark_dirty()


# The three layer textures exist and match the current layer image dimensions.
func _bsm_ready(layers) -> bool:
	for layer in [Editor.LAYER.LOGIC, Editor.LAYER.PAINT_ON, Editor.LAYER.PAINT_OFF]:
		var tex = _bsm_tex.get(layer, null)
		if tex == null or not (tex is ImageTexture):
			return false
		var img = layers[layer]
		if not (img is Image):
			return false
		if int(tex.get_width()) != img.get_width() or int(tex.get_height()) != img.get_height():
			return false
	return true


# Integer rectangle clamped to [0, w) x [0, h); zero-size if it falls entirely outside.
func _bsm_clamp(rect: Rect2, w: int, h: int) -> Rect2:
	var x := int(max(0.0, floor(rect.position.x)))
	var y := int(max(0.0, floor(rect.position.y)))
	var x2 := int(min(float(w), ceil(rect.position.x + rect.size.x)))
	var y2 := int(min(float(h), ceil(rect.position.y + rect.size.y)))
	if x2 <= x or y2 <= y:
		return Rect2(0, 0, 0, 0)
	return Rect2(x, y, x2 - x, y2 - y)


# Prepass-affecting param writes that DON'T go through ed_layers_resources_change (which already
# marks dirty via _bsm_full_rebuild / board_size_mod_flush). Both call super, then re-render once so
# the change shows immediately instead of waiting for the heartbeat.
func generate_led_palette(palette: Array) -> void:
	.generate_led_palette(palette)
	_bsm_mark_dirty()


func _ev_sm_paint_overlay_toggle_tw(_mode: int, _args: Dictionary) -> void:
	._ev_sm_paint_overlay_toggle_tw(_mode, _args)
	_bsm_mark_dirty()
