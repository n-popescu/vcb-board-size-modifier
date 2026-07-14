extends "res://src/editor/tool_array_pencil_eraser.gd"

# Board Size Modifier — hand the CircuitRenderer just the rectangle a stroke changed, so drawing
# on a big board uploads O(brush) pixels per event instead of rebuilding the whole board three
# times over (see extensions/circuit_renderer.gd for why that full rebuild is the lag).
#
# We do this for EVERY event of a stroke — including the first click (is_just_pressed) — whenever
# the board is larger than the default 2048 (at 2048 vanilla is already cheap, so we keep the
# stock path). The renderer keeps its cached textures byte-in-sync with ED.images (every change
# is uploaded, and any non-stroke edit re-syncs via a full rebuild), so a partial upload on the
# first click is safe; if the cache isn't ready yet the renderer falls back to a full rebuild.
# E.echo is synchronous, so arming before super.draw() and flushing after brackets exactly the
# one ed_layers_resources_change that draw() emits.

const _BSM_RENDERER_PATH := "Main/World/CircuitRenderer"


func draw(pixel: Vector2, is_just_pressed: bool, is_draw: bool) -> void:
	var renderer := _bsm_renderer()
	var use_partial: bool = (
		renderer != null
		and _bsm_is_big_board()
		and renderer.has_method("board_size_mod_arm"))
	var p0: Vector2 = last_pos
	if use_partial:
		renderer.board_size_mod_arm()
	.draw(pixel, is_just_pressed, is_draw)
	if use_partial:
		var p1: Vector2 = last_pos
		# On the first event of a stroke vanilla only stamps the brush at the press pixel (the
		# Bresenham segment is zero-length), so the changed region is the brush around p1 — using
		# the p0->p1 span would give a board-crossing rect (p0 is the PREVIOUS stroke's end) and
		# defeat the point. For mid-stroke moves the span p0->p1 is the swept segment.
		var rect := _bsm_dirty_rect(p1, p1) if is_just_pressed else _bsm_dirty_rect(p0, p1)
		renderer.board_size_mod_flush(ED.active_layer, rect, ED.images)


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
