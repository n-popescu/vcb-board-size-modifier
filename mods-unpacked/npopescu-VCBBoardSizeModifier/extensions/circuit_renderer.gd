extends "res://src/world/circuit_renderer.gd"

# Board Size Modifier — big-board draw performance. TWO independent costs scale with board AREA;
# this extension cuts both. Both are gated to boards larger than the default 2048, so a stock
# board is byte-for-byte vanilla behaviour.
#
# 1) PARTIAL LAYER UPLOAD (per edit).
#    Vanilla rebuilds THREE full-board ImageTextures (create_from_image) on every
#    ed_layers_resources_change — and a pencil/array/eraser stroke fires that on every mouse-move.
#    That's an O(side*side) upload per move: fine at 2048 (48 MB), crippling at 8192 (~768 MB per
#    move). So we cache the three textures and, when the drawing tool hands us the exact changed
#    rectangle (board_size_mod_arm before its emit, board_size_mod_flush after), upload only that
#    rectangle for the one changed layer via VisualServer.texture_set_data_partial — for every event
#    of a stroke, including its first click. Everything else (editor init, project load, resize,
#    undo/redo, bucket, selection) still does a full rebuild identical to vanilla, which keeps the
#    cache authoritative between strokes; and the flush itself falls back to a full rebuild whenever
#    the cache isn't ready (cold, size mismatch, or partial upload unavailable).
#
# 2) ON-DEMAND PREPASS (per frame).
#    The board is drawn through a full-board Viewport ("PrepassViewport") whose
#    render_target_update_mode is UPDATE_ALWAYS in the scene — it re-renders the ENTIRE board every
#    frame, a constant O(side*side) GPU cost independent of drawing. THIS is why even panning,
#    zooming or just hovering lags on a big board, and why the per-move fix above didn't feel like
#    enough. But in EDIT mode the prepass output is STATIC: the circuit shader's only per-frame term
#    (the entity-highlight pulse) is gated behind `is_render_mode_simulation`, and the VMEM/VInput
#    blinkers stop processing outside simulation. So while editing a grown board we switch the
#    prepass to render ON DEMAND — UPDATE_ONCE whenever the board actually changes, idle otherwise —
#    and keep vanilla UPDATE_ALWAYS during simulation (state animates every tick) and at the default
#    2048 size. The two niche edit-mode animations (VMEM / VInput pixel blink) briefly force
#    continuous rendering while they run so they aren't frozen.

const _BSM_DEFAULT_SIDE := 2048

var _bsm_tex := {}            # Editor.LAYER int -> the ImageTexture currently bound to the shader
var _bsm_armed := false       # a draw stroke is about to emit; skip the full rebuild, it'll flush
var _bsm_simulating := false  # tracked from mi_mode_change_confirmed (UPDATE_ALWAYS while true)
var _bsm_blink_until := 0      # OS.get_ticks_msec() until which the prepass must render continuously


func _ready() -> void:
	._ready()
	# We only need per-frame processing while a blink animation is playing (see _bsm_note_blink);
	# Godot auto-enables it because _process is defined, so turn it off until then.
	set_process(false)
	# Also watch the two edit-mode blink animations so on-demand rendering doesn't freeze them.
	E.follow_events(self, [E.vd_vmem_pixels_blink, E.vd_vinput_pixels_blink])
	_bsm_refresh_prepass()


# Called by the tool right before super.draw() emits ed_layers_resources_change.
func board_size_mod_arm() -> void:
	_bsm_armed = true


func _ev_ed_layers_resources_change(_mode: int, _args: Dictionary) -> void:
	if _bsm_armed:
		return  # a stroke is feeding us; board_size_mod_flush() will do the partial upload
	var p_layers = _args[E.ed_layers_resources_change.p_layers]
	_bsm_full_rebuild(p_layers)
	_bsm_refresh_prepass()


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


# Upload only `rect` of `layer` (the stroke's changed region), then render the prepass once. Falls
# back to a full rebuild if the cache isn't ready, the sizes don't match, or partial upload isn't
# available. Always refreshes the prepass so the change is shown on the next frame.
func board_size_mod_flush(layer: int, rect: Rect2, layers) -> void:
	_bsm_armed = false
	_bsm_do_flush(layer, rect, layers)
	_bsm_refresh_prepass()


func _bsm_do_flush(layer: int, rect: Rect2, layers) -> void:
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


# --- on-demand prepass -------------------------------------------------------------------------

# Layer switching and the LED palette change what the prepass draws; re-render once after each.
func _on_ed_layer_changed(new_layer: int) -> void:
	._on_ed_layer_changed(new_layer)
	_bsm_refresh_prepass()


func _ev_ed_led_palette_change(_mode: int, _args: Dictionary) -> void:
	._ev_ed_led_palette_change(_mode, _args)
	_bsm_refresh_prepass()


# Track edit vs simulation. In simulation the prepass must stay live (state animates every tick),
# so we restore vanilla UPDATE_ALWAYS; on returning to edit we render once then idle.
func _on_mi_mode_change_confirmed(is_simulating: bool) -> void:
	._on_mi_mode_change_confirmed(is_simulating)
	_bsm_simulating = is_simulating
	_bsm_refresh_prepass()


func _ev_vd_vmem_pixels_blink(_mode: int, _args: Dictionary) -> void:
	_bsm_note_blink()


func _ev_vd_vinput_pixels_blink(_mode: int, _args: Dictionary) -> void:
	_bsm_note_blink()


# A VMEM/VInput cell just started its ~1.8s blink animation. Keep the prepass rendering
# continuously for a touch longer than that so the animation plays even in on-demand mode.
func _bsm_note_blink() -> void:
	_bsm_blink_until = OS.get_ticks_msec() + 2000
	if not _bsm_simulating and _bsm_big_board():
		set_process(true)
		_bsm_set_prepass(Viewport.UPDATE_ALWAYS)


func _process(_delta: float) -> void:
	if OS.get_ticks_msec() >= _bsm_blink_until:
		set_process(false)
		_bsm_refresh_prepass()  # blink finished — back to on-demand (renders the settled frame)


# Set the prepass update mode from the current sim/size/blink state. In on-demand mode this issues
# a single UPDATE_ONCE render (Godot renders one frame then auto-disables the target), so calling
# it repeatedly in a frame coalesces to at most one render.
func _bsm_refresh_prepass() -> void:
	if _bsm_simulating or not _bsm_big_board() or OS.get_ticks_msec() < _bsm_blink_until:
		_bsm_set_prepass(Viewport.UPDATE_ALWAYS)
	else:
		_bsm_set_prepass(Viewport.UPDATE_ONCE)


func _bsm_set_prepass(mode: int) -> void:
	var vp := get_node_or_null("PrepassViewport")
	if vp != null:
		vp.render_target_update_mode = mode


func _bsm_big_board() -> bool:
	return typeof(C.CIRCUIT.SIZE) == TYPE_VECTOR2 and C.CIRCUIT.SIZE.x > _BSM_DEFAULT_SIDE
