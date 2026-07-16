extends Node

# mod_main.gd — Mod Loader entry point for the VCB Board Size Modifier.
#
# Adds a "Board" category to the circuit-editor side panel (a small Board size field + Apply) that
# grows the board past the default 2048×2048. VCB boards are SQUARE — the native compiler reads
# side = image.width and uses it for both axes — so a resize always yields a square side×side
# board, side >= 2048 (no hard upper cap). Existing board content is kept.
#
# Nothing here edits a game file. Like the multiplayer mod's mod_main, it waits for the Main scene
# and then grafts on its own node: a resizer/sync node at /root/BoardSizeSync. That node does the
# actual resize work, injects the side-panel "Board" category (see board_resizer.gd), and — when
# the multiplayer mod has a live peer — mirrors the resize (and the pending field text) to the
# other player.

const MOD_DIR := "npopescu-VCBBoardSizeModifier"
const MOD_ROOT := "res://mods-unpacked/npopescu-VCBBoardSizeModifier"
const SCRIPTS := MOD_ROOT + "/scripts"
const EXTENSIONS := MOD_ROOT + "/extensions"

var _built := false


func _init() -> void:
	ModLoaderLog.info("Installing VCB Board Size Modifier…", MOD_DIR)
	# Script extensions that make drawing on a grown board fast: the tool reports the changed
	# rectangle and the renderer uploads only that region (instead of the whole board, three
	# textures, every mouse-move). They no-op at the default 2048 size, so a stock board is
	# unaffected. See extensions/circuit_renderer.gd.
	ModLoaderMod.install_script_extension(EXTENSIONS + "/circuit_renderer.gd")
	ModLoaderMod.install_script_extension(EXTENSIONS + "/tool_array_pencil_eraser.gd")
	# Persist the board size inside saved .vcb files (under a shared "modded" field) and restore it
	# on load. See extensions/file_system.gd.
	ModLoaderMod.install_script_extension(EXTENSIONS + "/file_system.gd")


func _ready() -> void:
	# Poll for the Main scene, then build once (so we run after the game's own _ready).
	set_process(true)


func _process(_delta: float) -> void:
	if _built:
		set_process(false)
		return
	var root := get_tree().root
	var main := root.get_node_or_null("Main")
	if main == null:
		return
	var editor := main.get_node_or_null("Systems/Editor")
	if editor == null:
		editor = main.find_node("Editor", true, false)
	var world := main.get_node_or_null("World")
	if editor == null or world == null:
		return
	_built = true
	set_process(false)
	_build(root)


func _build(root: Node) -> void:
	# The resizer + MP sync node at a stable path so rpc() resolves on both peers. It also injects
	# the "Board" side-panel category (see board_resizer.gd::_maybe_build_panel), so there is no
	# separate window/toolbar node to build here anymore.
	if root.get_node_or_null("BoardSizeSync") == null:
		var resizer = _new_script(SCRIPTS + "/board_resizer.gd")
		if resizer == null:
			return
		resizer.name = "BoardSizeSync"
		root.add_child(resizer)


# Instance a mod script, or null (logged) if it can't be loaded — never dereference a null.
func _new_script(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_warning("[VCB-BoardSize] missing script, skipping: " + path)
		return null
	var scr = load(path)
	if scr == null:
		push_warning("[VCB-BoardSize] failed to load script: " + path)
		return null
	var inst = scr.new()
	if inst == null:
		push_warning("[VCB-BoardSize] failed to instance script: " + path)
		return null
	return inst
