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

var _applying_remote := false


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

	# 4) Mirror to the multiplayer peer, if a live session exists.
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
func _broadcast(side: int) -> void:
	var mp := get_tree().root.get_node_or_null("MP")
	if mp == null:
		return
	if get_tree().network_peer == null:
		return
	if not (mp.get("is_connected") and mp.get("is_game_started")):
		return
	rpc("_rpc_apply_size", side)


remote func _rpc_apply_size(side: int) -> void:
	_applying_remote = true
	apply_board_size(int(side), false)
	_applying_remote = false
	var win := _window()
	if win != null and win.has_method("reflect_side"):
		win.reflect_side(int(side))


func _window() -> Node:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	return main.find_node("BoardSizeWindow", true, false)
