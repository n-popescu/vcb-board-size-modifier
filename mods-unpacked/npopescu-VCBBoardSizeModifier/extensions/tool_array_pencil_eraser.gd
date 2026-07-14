extends "res://src/editor/tool_array_pencil_eraser.gd"

# Board Size Modifier — hand the CircuitRenderer just the rectangle a stroke changed, so drawing
# on a big board uploads O(brush) pixels per mouse-move instead of the whole board three times
# over (see extensions/circuit_renderer.gd for why that's the lag).
#
# We only do this while the board is larger than the default 2048 (where vanilla is already
# fine), and only for moves within a stroke — the first event of each stroke (is_just_pressed)
# still triggers a full rebuild, which re-syncs the cached textures so any imprecision in a
# dirty rect can never accumulate. E.echo is synchronous, so arming before super.draw() and
# flushing after brackets exactly the one ed_layers_resources_change that draw() emits.

const _BSM_RENDERER_PATH := "Main/World/CircuitRenderer"


func draw(pixel: Vector2, is_just_pressed: bool, is_draw: bool) -> void:
	var renderer := _bsm_renderer()
	var use_partial: bool = (
		renderer != null
		and not is_just_pressed
		and _bsm_is_big_board()
		and renderer.has_method("board_size_mod_arm"))
	var p0: Vector2 = last_pos
	if use_partial:
		renderer.board_size_mod_arm()
	.draw(pixel, is_just_pressed, is_draw)
	if use_partial:
		var p1: Vector2 = last_pos
		renderer.board_size_mod_flush(ED.active_layer, _bsm_dirty_rect(p0, p1), ED.images)


func _bsm_renderer() -> Node:
	var root := get_tree().root
	if root == null:
		return null
	return root.get_node_or_null(_BSM_RENDERER_PATH)


# Only optimise past the default size — at 2048 the vanilla full rebuild is cheap and we'd rather
# keep the exact stock path.
func _bsm_is_big_board() -> bool:
	if typeof(ED.images) == TYPE_ARRAY and ED.images.size() > 0 and ED.images[0] is Image:
		return ED.images[0].get_width() > 2048
	return false


# Bounding box of the segment p0->p1 grown by the active brush's extent (a safe over-estimate of
# the pixels draw() touched this call).
func _bsm_dirty_rect(p0: Vector2, p1: Vector2) -> Rect2:
	var ext := _bsm_brush_extent()
	var minx: float = min(p0.x, p1.x) - ext.x
	var miny: float = min(p0.y, p1.y) - ext.y
	var maxx: float = max(p0.x, p1.x) + ext.x
	var maxy: float = max(p0.y, p1.y) + ext.y
	return Rect2(minx, miny, (maxx - minx) + 1.0, (maxy - miny) + 1.0)


# Max +1 offset magnitude across the active brush's stamp (array offsets or pencil pixels).
func _bsm_brush_extent() -> Vector2:
	var pxs = array_pixels if (ED.editor_tool == Editor.TOOL.ARRAY) else pencil_pxs_filled
	var ex := 1
	var ey := 1
	if typeof(pxs) == TYPE_ARRAY:
		for px in pxs:
			if typeof(px) == TYPE_ARRAY and px.size() >= 2:
				ex = int(max(ex, abs(int(px[0])) + 1))
				ey = int(max(ey, abs(int(px[1])) + 1))
	return Vector2(ex, ey)
