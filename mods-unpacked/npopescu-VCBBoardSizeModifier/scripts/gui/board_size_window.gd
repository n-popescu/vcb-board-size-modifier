extends WindowDialog

# board_size_window.gd — the "Board Size" window: a single "Board size" field + Apply.
#
# VCB boards are square, so there is one side value (2048–8192). When a multiplayer session is
# live, the field value is mirrored to the other player *as you type* (before Apply) so both
# players always see the same pending number and can't drift apart; Apply then resizes both
# boards. It talks to the resizer node at /root/BoardSizeSync; it never touches board state
# directly.

const MIN_SIDE := 2048
const MAX_SIDE := 8192

var _size_edit: LineEdit
var _status: Label
var _suppress_broadcast := false


func _ready() -> void:
	window_title = "Board Size"
	resizable = false
	rect_size = Vector2(320, 0)

	var margin := MarginContainer.new()
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	margin.add_constant_override("margin_left", 12)
	margin.add_constant_override("margin_right", 12)
	margin.add_constant_override("margin_top", 12)
	margin.add_constant_override("margin_bottom", 12)
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_constant_override("separation", 8)
	margin.add_child(vb)

	var note := Label.new()
	note.text = ("Grow the board past 2048×2048.\n"
		+ "Boards are square (one size). Range: 2048–8192.\n"
		+ "Existing content is kept.")
	note.autowrap = true
	vb.add_child(note)

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
	vb.add_child(row)

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.connect("pressed", self, "_on_apply")
	vb.add_child(apply_btn)

	_status = Label.new()
	_status.autowrap = true
	vb.add_child(_status)

	reflect_side(_current_side())


# Toggle from the toolbar button.
func toggle() -> void:
	if visible:
		hide()
	else:
		reflect_side(_current_side())
		_set_status("")
		popup_centered(Vector2(320, 200))


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
