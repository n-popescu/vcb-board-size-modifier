extends Popup

# board_size_window.gd — the "Board Size" window: a single "Board size" field + Apply.
#
# VCB boards are square, so there is one side value (2048–8192). When a multiplayer session is
# live, the field value is mirrored to the other player *as you type* (before Apply) so both
# players always see the same pending number and can't drift apart; Apply then resizes both
# boards. It talks to the resizer node at /root/BoardSizeSync; it never touches board state
# directly.
#
# Presentation matches the stock dialogs (and the Multiplayer window): a centered, native-styled
# dark panel that fades in over a dimmed/blurred backdrop, via the game's own popup helper
# (flux_mod_popup) added as a child. See src/gui/flux/flux_mod_popup.gd and
# src/gui/dialogs/background_for_dialogs.gd.

const MIN_SIDE := 2048
const MAX_SIDE := 8192

# The stock game's popup helper. Added as a child of this Popup it gives us the exact same
# presentation as the built-in dialogs: the shared dimmed backdrop (BackgroundForDialogs, via the
# mn_popup_visibility "is_dialog" event), a scale + fade entrance, and keep-centered-on-resize.
const FluxModPopupScene := preload("res://src/gui/flux/flux_mod_popup.tscn")

var _size_edit: LineEdit
var _status: Label
var _suppress_broadcast := false


func _ready() -> void:
	_build_ui()
	reflect_side(_current_side())


# ---------------------------------------------------------------- UI construction --
func _build_ui() -> void:
	# opaque, rounded dark panel (matches the stock dialogs)
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.add_stylebox_override("panel", _make_panel_style())
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_constant_override("margin_left", 30)
	margin.add_constant_override("margin_right", 30)
	margin.add_constant_override("margin_top", 20)
	margin.add_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_constant_override("separation", 8)
	margin.add_child(root)

	var title := Label.new()
	title.text = "Board Size"
	title.align = Label.ALIGN_CENTER
	root.add_child(title)
	root.add_child(HSeparator.new())

	var note := Label.new()
	note.text = ("Grow the board past 2048×2048.\n"
		+ "Boards are square (one size). Range: 2048–8192.\n"
		+ "Existing content is kept.")
	note.autowrap = true
	root.add_child(note)

	var row := HBoxContainer.new()
	row.add_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Board size"
	lbl.rect_min_size = Vector2(80, 0)
	row.add_child(lbl)
	_size_edit = LineEdit.new()
	_size_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_edit.align = LineEdit.ALIGN_RIGHT
	_size_edit.connect("text_changed", self, "_on_text_changed")
	_size_edit.connect("text_entered", self, "_on_text_entered")
	row.add_child(_size_edit)
	root.add_child(row)

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.connect("pressed", self, "_on_apply")
	root.add_child(apply_btn)

	_status = Label.new()
	_status.autowrap = true
	root.add_child(_status)

	root.add_child(HSeparator.new())
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.connect("pressed", self, "hide")
	root.add_child(close_btn)

	rect_min_size = Vector2(320, 0)

	# Attach the shared popup helper so this window presents exactly like the stock dialogs:
	# it fades in the dimmed backdrop behind the centered box, animates a scale + fade entrance,
	# and keeps the box centered when the window is resized.
	var flux := FluxModPopupScene.instance()
	flux.is_keep_centered_on_resize = true
	add_child(flux)


func _make_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0745098, 0.0941176, 0.12549, 1)
	sb.border_color = Color(0.164706, 0.207843, 0.254902, 1)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.corner_detail = 5
	sb.shadow_color = Color(0.054902, 0.0745098, 0.117647, 0.156863)
	sb.shadow_size = 16
	# Godot 3.5 has no set_content_margin_all(); set each side's default (content) margin.
	sb.set_default_margin(MARGIN_LEFT, 4)
	sb.set_default_margin(MARGIN_TOP, 4)
	sb.set_default_margin(MARGIN_RIGHT, 4)
	sb.set_default_margin(MARGIN_BOTTOM, 4)
	return sb


# Toggle from the toolbar button.
func toggle() -> void:
	if visible:
		hide()
	else:
		reflect_side(_current_side())
		_set_status("")
		popup_centered()
		set_as_minsize()  # shrink to the content's min size, like the stock dialogs
		# Containers only recompute their minimum size on the NEXT idle frame, so the
		# set_as_minsize() above runs on the stale (pre-layout) size and leaves the popup TALLER
		# than its visible content — an empty, invisible dead zone that extends beneath everything
		# (and still eats clicks). This is the exact bug the multiplayer window hit; the fix is the
		# same (see mp_window.gd::_refit, the canonical popup skeleton). Re-fit once the layout has
		# settled so the panel hugs its content.
		_refit()


# Shrink the popup to its currently-visible content and re-center, AFTER the containers have
# recomputed their minimum size (next idle frame). No-ops if the window was hidden meanwhile.
func _refit() -> void:
	yield(get_tree(), "idle_frame")
	if not visible:
		return
	set_as_minsize()
	_center()


func _center() -> void:
	var ws: Vector2 = get_viewport().get_visible_rect().size
	# Match the flux popup helper's centering (it uses the UI-scaled viewport size) so the re-fit
	# doesn't shift the box away from where the entrance animation placed it.
	var u = get_tree().root.get_node_or_null("U")
	if u != null and u.has_method("get_global_viewport_size_scaled"):
		ws = u.get_global_viewport_size_scaled()
	rect_position = ((ws - rect_size) / 2.0).floor()


# Set the field to a concrete side (on open + after a resize). Does not broadcast.
func reflect_side(side: int) -> void:
	_set_text_silently(str(side))


# Set the field to whatever the other player typed (raw text). Does not broadcast.
func set_pending_text(text: String) -> void:
	_set_text_silently(text)


func _set_text_silently(text: String) -> void:
	if _size_edit == null:
		return
	_suppress_broadcast = true
	_size_edit.text = text
	# Don't yank the caret if the local user is mid-edit; only reposition when unfocused.
	if not _size_edit.has_focus():
		_size_edit.caret_position = text.length()
	_suppress_broadcast = false


func _current_side() -> int:
	var resizer := _resizer()
	if resizer != null and resizer.has_method("get_current_side"):
		return int(resizer.get_current_side())
	return MIN_SIDE


func _resizer() -> Node:
	return get_tree().root.get_node_or_null("BoardSizeSync")


# Live-mirror the field value to the peer as the user types (before Apply).
func _on_text_changed(new_text: String) -> void:
	if _suppress_broadcast:
		return
	var resizer := _resizer()
	if resizer != null and resizer.has_method("broadcast_pending_text"):
		resizer.broadcast_pending_text(new_text)


func _on_text_entered(_text: String) -> void:
	_on_apply()


func _on_apply() -> void:
	var side := _parse(_size_edit)
	if side < 0:
		_set_status("Enter a whole number.")
		return
	if side < MIN_SIDE:
		_set_status("Minimum board size is " + str(MIN_SIDE) + " — smaller values aren't allowed.")
		return
	if side > MAX_SIDE:
		side = MAX_SIDE
	var resizer := _resizer()
	if resizer == null or not resizer.has_method("request_resize"):
		_set_status("Resizer unavailable (mod not fully loaded yet).")
		return
	if resizer.has_method("is_editor_mode") and not resizer.is_editor_mode():
		_set_status("Exit simulation before resizing the board.")
		return
	var applied := int(resizer.request_resize(side))
	reflect_side(applied)
	_set_status("Board set to " + str(applied) + "×" + str(applied) + ".")


func _parse(edit: LineEdit) -> int:
	if edit == null:
		return -1
	var t := edit.text.strip_edges()
	if not t.is_valid_integer():
		return -1
	return int(t)


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg
