extends Node

# mod_save_registry.gd — a tiny, GENERIC "modded save" registry, mounted at /root/ModSaveData.
#
# VCB's .vcb project files are JSON. This mod adds one extra top-level object, "modded", so that
# any installed mod can persist its own state inside a saved project WITHOUT the mods having to
# know about each other:
#
#     { … vanilla project keys … ,
#       "modded": {
#         "npopescu-VCBBoardSizeModifier": { "side": 4096 },
#         "some-other-mod":               { … its own fields … }
#       } }
#
# Each mod owns exactly one sub-object keyed by its mod id, so their data never collides. If the
# "modded" object is absent or empty, no mod stored anything on this file → it's a plain vanilla
# project and opens unchanged in the stock game.
#
# The write/read is driven by extensions/file_system.gd (which hooks the game's save/open). This
# node only keeps the provider list and does the collect/dispatch. Any mod can use it:
#
#     var reg = get_tree().root.get_node_or_null("ModSaveData")
#     if reg != null:
#         reg.register_provider("my-namespace-MyMod", self, "my_save_fn", "my_load_fn")
#
#   • save fn: func() -> Dictionary                     (return {} to store nothing)
#   • load fn: func(data: Dictionary) -> void           (called on open when the file has your key)

var _providers := {}  # mod_id (String) -> {"target": Object, "save": String, "load": String}


# Register (or replace) a provider. `target` supplies `save_method()` (returns a Dictionary to
# store) and `load_method(data)` (applies a loaded Dictionary). Safe to call more than once.
func register_provider(mod_id: String, target: Object, save_method: String, load_method: String) -> void:
	if mod_id == "" or target == null:
		return
	_providers[mod_id] = {"target": target, "save": save_method, "load": load_method}


func unregister_provider(mod_id: String) -> void:
	if _providers.has(mod_id):
		_providers.erase(mod_id)


# Build the "modded" object to write into a saved project: {mod_id: provider.save()} for every
# provider that returns a non-empty Dictionary. Never raises — a bad provider is just skipped.
func collect() -> Dictionary:
	var out := {}
	for mod_id in _providers.keys():
		var p = _providers[mod_id]
		var target = p["target"]
		if target == null or not is_instance_valid(target):
			continue
		if not target.has_method(p["save"]):
			continue
		var data = target.call(p["save"])
		if typeof(data) == TYPE_DICTIONARY and not data.empty():
			out[str(mod_id)] = data
	return out


# Hand each registered provider its own sub-object from a loaded "modded" dictionary (if present).
func dispatch(modded) -> void:
	if typeof(modded) != TYPE_DICTIONARY:
		return
	for mod_id in _providers.keys():
		if not modded.has(mod_id):
			continue
		var p = _providers[mod_id]
		var target = p["target"]
		if target == null or not is_instance_valid(target):
			continue
		if target.has_method(p["load"]):
			target.call(p["load"], modded[mod_id])
