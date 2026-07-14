extends "res://src/editor/file_system.gd"

# Board Size Modifier — persist the board size inside the saved .vcb, under a shared "modded" field.
#
# VCB projects are JSON. The vanilla loader (parse_project) seeds a skeleton then copies EVERY key
# from the file, so an extra top-level key survives a load/save round-trip untouched. We use that to
# add a namespaced container:
#
#   "modded": { "<mod-id>": { ...that mod's data... }, ... }
#
# The convention (see CLAUDE.md §7) is general: any mod stores its own data under its own id, so the
# presence of a NON-EMPTY "modded" object marks a file as "made with mods" (an empty/absent one means
# the file is vanilla and opens in the stock game). The multiplayer mod, for instance, needs nothing
# here. This mod stores only the board side:
#
#   "modded": { "npopescu-VCBBoardSizeModifier": { "side": 4096 } }
#
# We MERGE (never replace) the object so other mods' entries round-trip even though we don't read
# them, and we only write our entry when the board is a non-default size — a 2048 board saves clean,
# so it stays a vanilla-openable file.
#
# On load we resize the board to the saved side BEFORE the user sees it. The saved size is read from
# our "modded" entry; as a robust fallback (older files, or an autosave that skipped the field) we
# use the loaded LOGIC layer's own width, which the game already recreated at the file's real size.

const _BSM_MOD_ID := "npopescu-VCBBoardSizeModifier"
const _BSM_MODDED_KEY := "modded"
const _BSM_DEFAULT_SIDE := 2048


# --- save: stamp our entry into the project that's about to be written --------------------------
# save_file uses `project` verbatim for a MANUAL save and a fresh skeleton for autosaves. Autosaves
# re-serialize the live board, so their layers already carry the real size and load correctly via
# the layer-width fallback; we only need to stamp the explicit marker on the manual path, which is
# the copy a user keeps and shares.
func save_file(path: String, savemode: int) -> void:
	_bsm_stamp_modded(project)
	.save_file(path, savemode)


# Merge our board-size entry into `d["modded"]`, or remove it (and an emptied container) when the
# board is back at the default size — so a default board yields a clean, vanilla-openable file.
func _bsm_stamp_modded(d) -> void:
	if typeof(d) != TYPE_DICTIONARY:
		return
	var side := _bsm_current_side()
	var modded = d.get(_BSM_MODDED_KEY)
	if typeof(modded) != TYPE_DICTIONARY:
		modded = {}
	if side != _BSM_DEFAULT_SIDE:
		modded[_BSM_MOD_ID] = {"side": side}
	else:
		modded.erase(_BSM_MOD_ID)
	if modded.empty():
		d.erase(_BSM_MODDED_KEY)
	else:
		d[_BSM_MODDED_KEY] = modded


# --- load: resize the board to the saved side ---------------------------------------------------
# The base open_file loads the layer images (at their saved size) and sets `project` before it
# yields, so by the time this super-call returns those are in place and we can act on them.
func open_file(path: String) -> void:
	.open_file(path)
	_bsm_restore_size()


func _bsm_restore_size() -> void:
	var side := _bsm_saved_side()
	if side <= 0:
		side = _bsm_loaded_layer_side()
	if side <= 0:
		return
	var resizer := get_tree().root.get_node_or_null("BoardSizeSync")
	if resizer == null or not resizer.has_method("apply_board_size"):
		return
	if resizer.has_method("get_current_side") and int(resizer.get_current_side()) == side:
		return  # already the right size — don't rebuild/clear-history for nothing
	# broadcast = true: in a live multiplayer session this mirrors the size to the peer (the
	# resizer's own _live_session guard makes it a no-op otherwise).
	resizer.apply_board_size(side, true)


# The side recorded in our "modded" entry, or -1 if absent/malformed.
func _bsm_saved_side() -> int:
	if typeof(project) != TYPE_DICTIONARY:
		return -1
	var modded = project.get(_BSM_MODDED_KEY)
	if typeof(modded) != TYPE_DICTIONARY:
		return -1
	var entry = modded.get(_BSM_MOD_ID)
	if typeof(entry) != TYPE_DICTIONARY or not entry.has("side"):
		return -1
	return int(entry["side"])


# Fallback: the width the game recreated the loaded LOGIC layer at (its real saved size).
func _bsm_loaded_layer_side() -> int:
	var editor := _bsm_editor()
	if editor == null:
		return -1
	var imgs = editor.get("images")
	if typeof(imgs) != TYPE_ARRAY or imgs.empty() or not (imgs[0] is Image):
		return -1
	return int(imgs[0].get_width())


func _bsm_current_side() -> int:
	if typeof(C.CIRCUIT.SIZE) == TYPE_VECTOR2:
		return int(C.CIRCUIT.SIZE.x)
	return _BSM_DEFAULT_SIDE


func _bsm_editor() -> Node:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	var ed := main.get_node_or_null("Systems/Editor")
	if ed == null:
		ed = main.find_node("Editor", true, false)
	return ed
