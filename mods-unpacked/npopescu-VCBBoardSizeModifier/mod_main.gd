extends Node

# mod_main.gd — Mod Loader entry point for the VCB Board Size Modifier.
#
# Adds an in-game control (a toolbar "Board" button that toggles a small window with Width /
# Height fields and an Apply button) that grows the board past the default 2048×2048. VCB boards
# are SQUARE — the native compiler reads side = image.width and uses it for both axes — so a
# resize always yields a square side×side board, side >= 2048. Existing board content is kept.
#
# Nothing here edits a game file. Like the multiplayer mod's mod_main, it waits for the Main scene
# and then grafts on its own nodes: a resizer/sync node at /root/BoardSizeSync (which does the
# actual work and, when the multiplayer mod has a live peer, mirrors the resize to the other
# player), plus a CanvasLayer holding the window and a toolbar button.

const MOD_DIR := "npopescu-VCBBoardSizeModifier"
const MOD_ROOT := "res://mods-unpacked/npopescu-VCBBoardSizeModifier"
const SCRIPTS := MOD_ROOT + "/scripts"
const EXTENSIONS := MOD_ROOT + "/extensions"
const MAIN_THEME := "res://src/gui/themes/main_theme.tres"

var _built := false


func _init() -> void:
	ModLoaderLog.info("Installing VCB Board Size Modifier…", MOD_DIR)
	# Script extensions that make drawing on a grown board fast: the tool reports the changed
	# rectangle and the renderer uploads only that region (instead of the whole board, three
	# textures, every mouse-move) AND renders the full-board prepass viewport on demand while
	# editing (instead of every frame). They no-op at the default 2048 size, so a stock board is
	# unaffected. See extensions/circuit_renderer.gd.
	ModLoaderMod.install_script_extension(EXTENSIONS + "/circuit_renderer.gd")
	ModLoaderMod.install_script_extension(EXTENSIONS + "/tool_array_pencil_eraser.gd")
	# Save/restore the board size inside .vcb projects (via a generic "modded" section any mod can
	# use — see scripts/mod_save_registry.gd). Hooks the game's file save/open; file_system.gd is
	# extended by nothing else, so this is collision-free.
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
	_build(root, main)


func _build(root: Node, main: Node) -> void:
	var theme_res = load(MAIN_THEME)

	# Generic "modded save" registry at /root/ModSaveData: lets any mod persist its own data inside
	# saved .vcb projects (this mod stores the board size). extensions/file_system.gd drives it.
	var registry: Node = root.get_node_or_null("ModSaveData")
	if registry == null:
		registry = _new_script(SCRIPTS + "/mod_save_registry.gd")
		if registry != null:
			registry.name = "ModSaveData"
			root.add_child(registry)

	# The resizer + MP sync node at a stable path so rpc() resolves on both peers.
	if root.get_node_or_null("BoardSizeSync") == null:
		var resizer = _new_script(SCRIPTS + "/board_resizer.gd")
		if resizer == null:
			return
		resizer.name = "BoardSizeSync"
		root.add_child(resizer)

	# Register the board size as this mod's saved-project data.
	var resizer_node := root.get_node_or_null("BoardSizeSync")
	if registry != null and resizer_node != null and registry.has_method("register_provider"):
		registry.register_provider(MOD_DIR, resizer_node, "mod_save_data", "mod_load_data")

	# The window, on its own CanvasLayer so it floats above the board. Built detached, then the
	# whole layer is added to Main — which fires the window's _ready (after the resizer exists).
	var window: Node = null
	if main.get_node_or_null("BoardSizeModifierUI") == null:
		var layer := CanvasLayer.new()
		layer.name = "BoardSizeModifierUI"
		layer.layer = 128
		window = _new_script(SCRIPTS + "/gui/board_size_window.gd")
		if window != null:
			window.name = "BoardSizeWindow"
			if theme_res is Theme:
				window.theme = theme_res
			layer.add_child(window)
		main.add_child(layer)

	# Toolbar button that toggles the window (FileControls is the header HBoxContainer).
	var file_controls := main.find_node("FileControls", true, false)
	if file_controls != null and file_controls.get_node_or_null("BtnBoardSize") == null:
		var btn := Button.new()
		btn.name = "BtnBoardSize"
		btn.text = "Board"
		btn.focus_mode = Control.FOCUS_NONE
		btn.hint_tooltip = "Resize the board (square, min 2048)"
		if theme_res is Theme:
			btn.theme = theme_res
		if window != null:
			btn.connect("pressed", window, "toggle")
		file_controls.add_child(btn)


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
