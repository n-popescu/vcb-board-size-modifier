extends WindowDialog

# board_size_window.gd — the little "Board Size" window: two labelled fields (Width / Height)
# and an Apply button. VCB boards are square, so Apply uses a single side (the larger of the two
# entered values, clamped to [MIN_SIDE, MAX_SIDE]) and reports what it did in a status line.
#
# It talks to the resizer node at /root/BoardSizeSync; it does not touch board state directly.

const MIN_SIDE := 2048
const MAX_SIDE := 8192

var _width_edit: LineEdit
var _height_edit: LineEdit
var _status: Label


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
		+ "Boards are square, so width = height.\n"
		+ "Range: 2048–8192. Existing content is kept.")
	note.autowrap = true
	vb.add_child(note)

	_width_edit = _add_field(vb, "Width")
	_height_edit = _add_field(vb, "Height")

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.connect("pressed", self, "_on_apply")
	vb.add_child(apply_btn)

	_status = Label.new()
	_status.autowrap = true
	vb.add_child(_status)

	reflect_side(_current_side())


func _add_field(parent: Node, label_text: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.rect_min_size = Vector2(64, 0)
	row.add_child(lbl)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.align = LineEdit.ALIGN_RIGHT
	edit.connect("text_entered", self, "_on_text_entered")
	row.add_child(edit)
	parent.add_child(row)
	return edit


# Toggle from the toolbar button.
func toggle() -> void:
	if visible:
		hide()
	else:
		reflect_side(_current_side())
		_set_status("")
		popup_centered(Vector2(320, 230))


# Set both fields to the given side (used on open + after a remote resize).
func reflect_side(side: int) -> void:
	if _width_edit != null:
		_width_edit.text = str(side)
	if _height_edit != null:
		_height_edit.text = str(side)


func _current_side() -> int:
	var resizer := _resizer()
	if resizer != null and resizer.has_method("get_current_side"):
		return int(resizer.get_current_side())
	return MIN_SIDE


func _resizer() -> Node:
	return get_tree().root.get_node_or_null("BoardSizeSync")


func _on_text_entered(_text: String) -> void:
	_on_apply()


func _on_apply() -> void:
	var w := _parse(_width_edit)
	var h := _parse(_height_edit)
	if w < 0 or h < 0:
		_set_status("Enter whole numbers for width and height.")
		return
	var side := int(max(w, h))
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
	var msg := "Board set to " + str(applied) + "×" + str(applied) + "."
	if w != h:
		msg += "  (squared to the larger side)"
	_set_status(msg)


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
