extends "res://src/editor/file_system.gd"

# Board Size Modifier — "modded" project data in saved .vcb files.
#
# VCB projects are JSON. This extension adds one optional top-level object, "modded", so any mod
# can persist its own state inside a saved project (see scripts/mod_save_registry.gd for the
# generic API). For THIS mod it records the board size, so a grown board reopens grown.
#
#   • SAVE (manual): before the game serializes `project`, we set project["modded"] to the
#     collected per-mod data — or delete the key entirely when nothing non-vanilla is stored, so a
#     default-size board still writes a byte-vanilla file that opens in the stock game.
#   • OPEN: after the game has parsed the file and loaded the layers, we hand each mod its own
#     sub-object, then reconcile the board size to the layers actually loaded (the layer images
#     carry their own width/height in the .vcb, so this also fixes older/grown saves that predate
#     the "modded" section).
#
# file_system.gd is extended by neither the multiplayer mod nor anything else, so this is a
# collision-free seam. Everything degrades gracefully: with the registry node absent it's inert.

const _BSM_MODDED_KEY := "modded"


# MANUAL save serializes `project` (autosaves use a fresh skeleton and intentionally omit the
# modded section — board size is still recoverable on open from the layer dimensions). Refresh
# project["modded"] from the live registry right before the game writes the file.
func save_file(path: String, savemode: int) -> void:
	if typeof(project) == TYPE_DICTIONARY:
		var modded := _bsm_collect_modded()
		if modded.empty():
			project.erase(_BSM_MODDED_KEY)  # keep default-board files byte-vanilla
		else:
			project[_BSM_MODDED_KEY] = modded
	.save_file(path, savemode)


# Runs the vanilla open (which parses the file into `project` and emits fs_project_change so the
# editor loads the layers), then applies any modded data. .open_file() yields on an idle_frame at
# its very end, but everything we depend on has already run synchronously by the time it returns.
func open_file(path: String) -> void:
	.open_file(path)
	_bsm_after_open(path)


func _bsm_after_open(path: String) -> void:
	# file_path is only set to `path` on a successful load; bail on the error paths.
	if file_path != path:
		return
	var modded = null
	if typeof(project) == TYPE_DICTIONARY:
		modded = project.get(_BSM_MODDED_KEY, null)
	var reg := _bsm_registry()
	if reg != null and reg.has_method("dispatch") and typeof(modded) == TYPE_DICTIONARY:
		reg.dispatch(modded)
	# Safety net, independent of the modded section: the loaded layer images ARE the true board
	# size, so make the engine match them. Idempotent — a no-op if dispatch already resized us.
	var resizer := _bsm_resizer()
	if resizer != null and resizer.has_method("reconcile_to_loaded_layers"):
		resizer.reconcile_to_loaded_layers()


func _bsm_collect_modded() -> Dictionary:
	var reg := _bsm_registry()
	if reg != null and reg.has_method("collect"):
		var m = reg.collect()
		if typeof(m) == TYPE_DICTIONARY:
			return m
	return {}


func _bsm_registry() -> Node:
	return get_tree().root.get_node_or_null("ModSaveData")


func _bsm_resizer() -> Node:
	return get_tree().root.get_node_or_null("BoardSizeSync")
