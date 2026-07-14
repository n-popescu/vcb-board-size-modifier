extends "res://src/world/circuit_renderer.gd"

# Board Size Modifier — partial GPU upload for the editor layer textures.
#
# Vanilla rebuilds THREE full-board ImageTextures (create_from_image) on every
# ed_layers_resources_change — and a pencil/array/eraser stroke fires that on every mouse-move.
# That's an O(side*side) upload per move: fine at 2048 (48 MB), crippling at 8192 (~768 MB per
# move) — the "lags a lot when drawing on a big board" the mod otherwise causes.
#
# So we cache the three textures and, when the drawing tool hands us the exact changed rectangle
# (board_size_mod_arm before its emit, board_size_mod_flush after), upload only that rectangle
# for the one changed layer via VisualServer.texture_set_data_partial. Everything else (editor
# init, project load, resize, undo/redo, bucket, selection, the first event of each stroke) still
# does a full rebuild identical to vanilla, so anything we don't explicitly optimize is unchanged.
# The tool only arms this on boards larger than the default, so a normal 2048 board is byte-for-
# byte vanilla behavior.

var _bsm_tex := {}        # Editor.LAYER int -> the ImageTexture currently bound to the shader
var _bsm_armed := false   # a draw stroke is about to emit; skip the full rebuild, it'll flush


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
