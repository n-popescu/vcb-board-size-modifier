extends PanelContainer

# board_panel.gd — the "Board" category injected into the circuit-editor side panel, directly
# BELOW the always-visible "Cursor Info" card (HoveredInk) and ABOVE the scrollable card list whose
# first entry is the "Inks" zone — i.e. it sits between Cursor Info and Inks. Being a direct child
# of the side panel's root VBoxContainer — which circuit_editor.gd's update_visibility() never
# touches — it stays visible in both edit and simulation modes, exactly like the multiplayer
# "Players" roster (mp_players_panel.gd), which this panel is modelled on.
#
# It replaces the old toolbar-button + Popup UI: a single narrow size field + an Apply button that
# resize the square board. It talks only to the resizer node at /root/BoardSizeSync
# (get_current_side / is_editor_mode / request_resize / broadcast_pending_text) and never touches
# board state directly. When a multiplayer session is live the field value is mirrored to the other
# player as you type (before Apply), so both players always share one pending number.
#
# The resizer drives this panel back through the SAME two methods the old popup exposed —
# reflect_side(side) after a (local or remote) resize, and set_pending_text(text) as the peer types
# — so the multiplayer RPC path in board_resizer.gd keeps working unchanged.

const MIN_SIDE := 2048
const RECOMMENDED_SIDE := 8192   # advisory only — there is deliberately NO hard upper cap

var _size_edit: LineEdit = null
var _status: Label = null
var _suppress_broadcast := false


func _ready() -> void:
	name = "BoardSizePanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_adopt_panel_style()
	_build_ui()
	reflect_side(_current_side())


# Match the neighbouring "Cursor Info" card's panel look by reusing its panel stylebox.
func _adopt_panel_style() -> void:
	var parent = get_parent()
	if parent == null:
		return
	var hovered = parent.get_node_or_null("HoveredInk")
	if hovered != null:
		var sb = hovered.get_stylebox("panel")
		if sb != null:
			add_stylebox_override("panel", sb)


func _build_ui() -> void:
	var vb = VBoxContainer.new()
	vb.add_constant_override("separation", 4)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(vb)

	# Header — mirror the "Cursor Info" header's theme so the section title matches the other cards.
	var header = Label.new()
	header.text = "Board"
	var parent = get_parent()
	if parent != null:
		var cursor_header = parent.get_node_or_null("HoveredInk/VBoxContainer2/Label3")
		if cursor_header != null and cursor_header.theme != null:
			header.theme = cursor_header.theme
	vb.add_child(header)

	# Short blurb: what it does + the limits (kept deliberately terse).
	var note = Label.new()
	note.text = "Resize the square board (min 2048). Bigger boards need a stronger PC — recommended max 8192."
	note.autowrap = true
	vb.add_child(note)

	# Size field + Apply on one row. The field is intentionally narrow (fits ~4 digits) and does
	# NOT expand, so it reads as a compact input, not a long bar; longer values simply scroll
	# horizontally inside it.
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_edit = LineEdit.new()
	_size_edit.rect_min_size = Vector2(54, 0)
	_size_edit.align = LineEdit.ALIGN_RIGHT
	_size_edit.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_size_edit.connect("text_changed", self, "_on_text_changed")
	_size_edit.connect("text_entered", self, "_on_text_entered")
	row.add_child(_size_edit)
	var apply_btn = Button.new()
	apply_btn.text = "Apply"
	apply_btn.focus_mode = Control.FOCUS_NONE
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_btn.connect("pressed", self, "_on_apply")
	row.add_child(apply_btn)
	vb.add_child(row)

	# Transient validation / confirmation feedback; empty when idle so it adds no clutter.
	_status = Label.new()
	_status.autowrap = true
	vb.add_child(_status)


# --- resizer interface (same method names the old popup exposed) ---------------------------------

# Set the field to a concrete side (on build + after a resize). Does not broadcast.
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
	var resizer = _resizer()
	if resizer != null and resizer.has_method("get_current_side"):
		return int(resizer.get_current_side())
	return MIN_SIDE


func _resizer() -> Node:
	return get_tree().root.get_node_or_null("BoardSizeSync")


# Live-mirror the field value to the peer as the user types (before Apply).
func _on_text_changed(new_text: String) -> void:
	if _suppress_broadcast:
		return
	var resizer = _resizer()
	if resizer != null and resizer.has_method("broadcast_pending_text"):
		resizer.broadcast_pending_text(new_text)


func _on_text_entered(_text: String) -> void:
	_on_apply()


func _on_apply() -> void:
	var side = _parse(_size_edit)
	if side < 0:
		_set_status("Enter a whole number.")
		return
	if side < MIN_SIDE:
		_set_status("Minimum is " + str(MIN_SIDE) + ".")
		return
	var resizer = _resizer()
	if resizer == null or not resizer.has_method("request_resize"):
		_set_status("Resizer not ready.")
		return
	if resizer.has_method("is_editor_mode") and not resizer.is_editor_mode():
		_set_status("Exit simulation to resize.")
		return
	var applied = int(resizer.request_resize(side))
	reflect_side(applied)
	_set_status("Set to " + str(applied) + "×" + str(applied) + ".")


func _parse(edit: LineEdit) -> int:
	if edit == null:
		return -1
	var t = edit.text.strip_edges()
	if not t.is_valid_integer():
		return -1
	return int(t)


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg
