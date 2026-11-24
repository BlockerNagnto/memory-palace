extends CanvasLayer
## ui_hud.gd — 觸控介面（全部用程式建立，不需要編輯器）
##
##   常駐：左上 ☰ 選單、右下 ＋（放記憶方塊）與 ↑（跳）、準心、搖桿圈、房間名稱與提示訊息。
##   面板：選單、記憶內容編輯、記憶檢視（三層：形狀 → 15 字提示 → 點開才看到的詳情）、
##         擴建（拉開空間）、房間列表、設定、確認視窗。
##   HUD 只發出訊號、顯示資料；所有資料修改都在 main.gd。
##   面板開啟時 modal_open = true，main 會暫停玩家操作。

signal jump_pressed
signal add_requested(kind: String)            # "blank" | "import_native" | "import_drop"
signal door_requested(kind: String)           # "front" | "up" | "down"
signal stretch_begin_requested
signal stretch_changed(delta: float)
signal stretch_confirmed(delta: float)
signal stretch_cancelled
signal node_saved(node_id: String, prompt: String, detail: String, is_new: bool)
signal node_deleted(node_id: String)
signal node_move_requested(node_id: String)
signal node_edit_cancelled(node_id: String, is_new: bool)
signal viewer_closed
signal room_selected(cell_id: String)
signal rooms_requested
signal settings_requested
signal edit_requested(node_id: String)
signal room_theme_next_requested
signal settings_changed(values: Dictionary)
signal backup_export_requested
signal backup_import_requested
signal modal_changed(open: bool)

const PROMPT_MAX := 15
const COLOR_PANEL := Color(0.07, 0.08, 0.12, 0.93)
const COLOR_BTN := Color(0.20, 0.23, 0.32, 0.95)
const COLOR_BTN_HOT := Color(0.30, 0.52, 0.78, 1.0)
const COLOR_ACCENT := Color(0.95, 0.85, 0.45)

var player = null
var modal_open := false

var _root: Control
var _overlay: Control
var _toast: Label
var _toast_tween: Tween
var _room_label: Label
var _panels: Dictionary = {}          # 名稱 -> Control
var _current_panel := ""
var _confirm_cb := Callable()

# 編輯器 / 檢視器 / 擴建 的狀態
var _edit_id := ""
var _edit_is_new := false
var _prompt_edit: LineEdit
var _detail_edit: TextEdit
var _edit_extra_row: HBoxContainer
var _viewer_prompt: Label
var _viewer_detail: Label
var _viewer_show_btn: Button
var _viewer_id := ""
var _stretch_label: Label
var _stretch_delta := 2.0
var _stretch_info := ""
var _rooms_box: VBoxContainer
var _settings_values := {}
var _settings_labels: Dictionary = {}
var _confirm_label: Label


## 畫準心與搖桿
class Overlay extends Control:
	var hud = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, 4.0, Color(1, 1, 1, 0.85))
		draw_arc(c, 12.0, 0.0, TAU, 24, Color(1, 1, 1, 0.45), 2.0)
		var pl = hud.player if hud != null else null
		if pl != null and pl.joystick_active:
			draw_circle(pl.joystick_origin, pl.joystick_radius, Color(1, 1, 1, 0.10))
			draw_arc(pl.joystick_origin, pl.joystick_radius, 0.0, TAU, 48, Color(1, 1, 1, 0.45), 3.0)
			var knob: Vector2 = pl.joystick_pos - pl.joystick_origin
			if knob.length() > pl.joystick_radius:
				knob = knob.normalized() * pl.joystick_radius
			draw_circle(pl.joystick_origin + knob, pl.joystick_radius * 0.38, Color(1, 1, 1, 0.35))


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.name = "HudRoot"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var th := Theme.new()
	th.default_font_size = 34
	_root.theme = th
	add_child(_root)

	_overlay = Overlay.new()
	_overlay.hud = self
	_root.add_child(_overlay)

	_build_hud_buttons()
	_build_menu()
	_build_editor()
	_build_viewer()
	_build_stretch()
	_build_rooms()
	_build_settings()
	_build_confirm()


# ====================================================================== 對外 API

func bind_player(p) -> void:
	player = p


func set_room_name(text: String) -> void:
	_room_label.text = text


func toast(text: String, seconds: float = 3.0) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast.visible = true
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(seconds)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.5)
	_toast_tween.tween_callback(func(): _toast.visible = false)


func is_panel_open() -> bool:
	return _current_panel != ""


func close_panel() -> void:
	_open("")


## 返回鍵：有面板就關掉並回傳 true
func handle_back() -> bool:
	if _current_panel == "":
		return false
	match _current_panel:
		"editor":
			node_edit_cancelled.emit(_edit_id, _edit_is_new)
		"stretch":
			stretch_cancelled.emit()
		"viewer":
			viewer_closed.emit()
	_open("")
	return true


func open_node_editor(mem, is_new: bool) -> void:
	_edit_id = mem.id
	_edit_is_new = is_new
	_prompt_edit.text = mem.prompt15
	_detail_edit.text = mem.detail_note
	_edit_extra_row.visible = not is_new
	_open("editor")
	_prompt_edit.grab_focus()


func show_node_viewer(mem) -> void:
	_viewer_id = mem.id
	_viewer_prompt.text = mem.prompt15 if mem.prompt15 != "" else "（還沒有提示文字）"
	_viewer_detail.text = mem.detail_note if mem.detail_note != "" else "（還沒有詳情）"
	_viewer_detail.visible = false
	_viewer_show_btn.text = "顯示詳情"
	_open("viewer")


func show_stretch(info: String, start_delta: float) -> void:
	_stretch_info = info
	_stretch_delta = start_delta
	_refresh_stretch_label()
	_open("stretch")


func show_rooms(rooms: Array, current_id: String) -> void:
	for ch in _rooms_box.get_children():
		_rooms_box.remove_child(ch)
		ch.queue_free()
	for r in rooms:
		var label: String = str(r["name"])
		if r["id"] == current_id:
			label += "（目前）"
		var cid: String = r["id"]
		_rooms_box.add_child(_btn(label, func():
			_open("")
			room_selected.emit(cid)))
	_open("rooms")


func show_settings(values: Dictionary) -> void:
	_settings_values = values.duplicate()
	_refresh_settings_labels()
	_open("settings")


func confirm(text: String, on_yes: Callable) -> void:
	_confirm_label.text = text
	_confirm_cb = on_yes
	_open("confirm")


# ====================================================================== 建立介面

func _btn(text: String, cb: Callable, min_size: Vector2 = Vector2(0, 100)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	var n := StyleBoxFlat.new()
	n.bg_color = COLOR_BTN
	n.set_corner_radius_all(14)
	n.set_content_margin_all(14)
	var h := n.duplicate()
	h.bg_color = COLOR_BTN_HOT
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", n)
	b.add_theme_stylebox_override("pressed", h)
	b.add_theme_stylebox_override("focus", n)
	b.pressed.connect(cb)
	return b


func _label(text: String, size: int = 34, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## 建立一個面板：回傳內層 VBox；anchor = "center" 或 "bottom"
func _make_panel(name: String, title: String, anchor: String, width: float) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.name = name
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.set_corner_radius_all(22)
	sb.set_content_margin_all(28)
	sb.border_color = Color(0.35, 0.42, 0.6, 0.9)
	sb.set_border_width_all(2)
	pc.add_theme_stylebox_override("panel", sb)
	pc.mouse_filter = Control.MOUSE_FILTER_STOP
	pc.visible = false
	pc.custom_minimum_size = Vector2(width, 0)
	_root.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	pc.add_child(v)
	if title != "":
		v.add_child(_label(title, 40, COLOR_ACCENT))
	_panels[name] = pc
	pc.set_meta("anchor", anchor)
	return v


func _build_hud_buttons() -> void:
	_room_label = _label("", 34)
	_room_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_room_label.add_theme_constant_override("outline_size", 8)
	_room_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 30)
	_room_label.position.y = 28
	_room_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_room_label)

	_toast = _label("", 36)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_toast.add_theme_constant_override("outline_size", 10)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.custom_minimum_size = Vector2(1300, 0)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast.position = Vector2(310, 150)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_root.add_child(_toast)

	var menu := _btn("☰", func(): _open("menu"), Vector2(130, 130))
	menu.add_theme_font_size_override("font_size", 56)
	menu.position = Vector2(30, 30)
	_root.add_child(menu)

	var add := _btn("＋", func(): add_requested.emit("blank"), Vector2(150, 150))
	add.add_theme_font_size_override("font_size", 72)
	_root.add_child(add)
	add.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 40)
	add.position -= Vector2(0, 190)

	var jmp := _btn("↑", func(): jump_pressed.emit(), Vector2(150, 150))
	jmp.add_theme_font_size_override("font_size", 72)
	_root.add_child(jmp)
	jmp.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 40)


func _build_menu() -> void:
	var outer := _make_panel("menu", "", "center", 980)
	outer.add_child(_label("記憶宮殿", 44, COLOR_ACCENT))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 640)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	scroll.add_child(v)
	var items := [
		["放一個空白記憶方塊", "blank"],
		["匯入圖片 / 3D 模型（系統選檔）", "import_native"],
		["掃描匯入資料夾（備用）", "import_drop"],
		["前方開門 → 新房間", "door_front"],
		["蓋樓梯上樓 → 新房間", "door_up"],
		["挖樓梯下樓 → 新房間", "door_down"],
		["擴建：在這裡拉開空間", "stretch"],
		["房間列表 / 前往", "rooms"],
		["換這間房的主題", "theme"],
		["設定", "settings"],
		["備份匯出", "backup_export"],
		["還原備份", "backup_import"],
	]
	for it in items:
		var tag: String = it[1]
		v.add_child(_btn(it[0], func(): _menu_pick(tag)))
	outer.add_child(_btn("關閉", func(): _open("")))


func _menu_pick(tag: String) -> void:
	_open("")
	match tag:
		"blank", "import_native", "import_drop":
			add_requested.emit(tag)
		"door_front":
			door_requested.emit("front")
		"door_up":
			door_requested.emit("up")
		"door_down":
			door_requested.emit("down")
		"stretch":
			stretch_begin_requested.emit()
		"rooms":
			rooms_requested.emit()
		"theme":
			room_theme_next_requested.emit()
		"settings":
			settings_requested.emit()
		"backup_export":
			backup_export_requested.emit()
		"backup_import":
			backup_import_requested.emit()


func _build_editor() -> void:
	var v := _make_panel("editor", "記憶內容", "center", 1100)
	v.add_child(_label("提示（最多 %d 字，看一眼就想起來）" % PROMPT_MAX, 30))
	_prompt_edit = LineEdit.new()
	_prompt_edit.max_length = PROMPT_MAX
	_prompt_edit.custom_minimum_size = Vector2(0, 100)
	_prompt_edit.add_theme_font_size_override("font_size", 40)
	_prompt_edit.placeholder_text = "例：蘋果 = apple"
	v.add_child(_prompt_edit)
	v.add_child(_label("詳情（第三層：點開才會看到）", 30))
	_detail_edit = TextEdit.new()
	_detail_edit.custom_minimum_size = Vector2(0, 230)
	_detail_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_detail_edit.add_theme_font_size_override("font_size", 34)
	v.add_child(_detail_edit)
	_edit_extra_row = HBoxContainer.new()
	_edit_extra_row.add_theme_constant_override("separation", 12)
	_edit_extra_row.add_child(_btn("移到準心位置", func():
		_open("")
		node_move_requested.emit(_edit_id), Vector2(0, 90)))
	_edit_extra_row.add_child(_btn("刪除", func():
		var id := _edit_id
		confirm("確定要刪除這個記憶嗎？", func(): node_deleted.emit(id)), Vector2(0, 90)))
	for ch in _edit_extra_row.get_children():
		ch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_edit_extra_row)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var ok := _btn("確定", func():
		_open("")
		node_saved.emit(_edit_id, _prompt_edit.text.substr(0, PROMPT_MAX), _detail_edit.text, _edit_is_new))
	var cancel := _btn("取消", func():
		_open("")
		node_edit_cancelled.emit(_edit_id, _edit_is_new))
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ok)
	row.add_child(cancel)
	v.add_child(row)


func _build_viewer() -> void:
	var v := _make_panel("viewer", "", "bottom", 1300)
	_viewer_prompt = _label("", 52, COLOR_ACCENT)
	v.add_child(_viewer_prompt)
	_viewer_detail = _label("", 34)
	_viewer_detail.visible = false
	v.add_child(_viewer_detail)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_viewer_show_btn = _btn("顯示詳情", func():
		_viewer_detail.visible = not _viewer_detail.visible
		_viewer_show_btn.text = "隱藏詳情" if _viewer_detail.visible else "顯示詳情", Vector2(0, 90))
	var edit := _btn("編輯", func():
		var id := _viewer_id
		_open("")
		viewer_closed.emit()
		edit_requested.emit(id), Vector2(0, 90))
	var close := _btn("關閉", func():
		_open("")
		viewer_closed.emit(), Vector2(0, 90))
	for b in [_viewer_show_btn, edit, close]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	v.add_child(row)


func _build_stretch() -> void:
	var v := _make_panel("stretch", "擴建", "bottom", 1300)
	_stretch_label = _label("", 34)
	v.add_child(_stretch_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	for step in [-2.0, -0.5, 0.5, 2.0]:
		var s: float = step
		var b := _btn("%+.1f" % s, func(): _stretch_step(s), Vector2(0, 90))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	v.add_child(row)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 12)
	var ok := _btn("拉開", func():
		_open("")
		stretch_confirmed.emit(_stretch_delta), Vector2(0, 90))
	var cancel := _btn("取消", func():
		_open("")
		stretch_cancelled.emit(), Vector2(0, 90))
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(ok)
	row2.add_child(cancel)
	v.add_child(row2)


func _stretch_step(s: float) -> void:
	_stretch_delta = clampf(_stretch_delta + s, 0.5, 12.0)
	_refresh_stretch_label()
	stretch_changed.emit(_stretch_delta)


func _refresh_stretch_label() -> void:
	_stretch_label.text = "%s\n拉開 %.1f 公尺（藍色面 = 切線與新牆）" % [_stretch_info, _stretch_delta]


func _build_rooms() -> void:
	var v := _make_panel("rooms", "房間列表", "center", 900)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 560)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_rooms_box = VBoxContainer.new()
	_rooms_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_rooms_box)
	v.add_child(_btn("關閉", func(): _open("")))


func _build_settings() -> void:
	var v := _make_panel("settings", "設定", "center", 900)
	for def in [
		["look_sensitivity", "視角靈敏度", 0.2, 0.4, 3.0],
		["max_visible_portals", "同時顯示的門數量", 1.0, 1.0, 11.0],
	]:
		var key: String = def[0]
		var step: float = def[2]
		var lo: float = def[3]
		var hi: float = def[4]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lab := _label("", 32)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_settings_labels[key] = [lab, def[1]]
		row.add_child(lab)
		row.add_child(_btn("−", func(): _settings_step(key, -step, lo, hi), Vector2(100, 90)))
		row.add_child(_btn("＋", func(): _settings_step(key, step, lo, hi), Vector2(100, 90)))
		v.add_child(row)
	var swap := _btn("", func():
		_settings_values["mirror_ui"] = not bool(_settings_values.get("mirror_ui", false))
		_refresh_settings_labels()
		settings_changed.emit(_settings_values.duplicate()))
	_settings_labels["mirror_ui"] = [swap, "左右互換（搖桿在右、視角在左）"]
	v.add_child(swap)
	v.add_child(_btn("關閉", func(): _open("")))


func _settings_step(key: String, d: float, lo: float, hi: float) -> void:
	var cur: float = float(_settings_values.get(key, lo))
	var nv := clampf(cur + d, lo, hi)
	_settings_values[key] = int(round(nv)) if key == "max_visible_portals" else snappedf(nv, 0.01)
	_refresh_settings_labels()
	settings_changed.emit(_settings_values.duplicate())


func _refresh_settings_labels() -> void:
	for key in _settings_labels:
		var pair: Array = _settings_labels[key]
		var node: Control = pair[0]
		var title: String = pair[1]
		var v: Variant = _settings_values.get(key)
		if key == "mirror_ui":
			(node as Button).text = "%s：%s" % [title, "開" if bool(v) else "關"]
		elif key == "look_sensitivity":
			(node as Label).text = "%s　%.1f" % [title, float(v)]
		else:
			(node as Label).text = "%s　%d" % [title, int(v)]


func _build_confirm() -> void:
	var v := _make_panel("confirm", "請確認", "center", 900)
	_confirm_label = _label("", 36)
	v.add_child(_confirm_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var yes := _btn("確定", func():
		var cb := _confirm_cb
		_open("")
		if cb.is_valid():
			cb.call())
	var no := _btn("取消", func(): _open(""))
	yes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(yes)
	row.add_child(no)
	v.add_child(row)


# ====================================================================== 面板切換

func _open(name: String) -> void:
	for k in _panels:
		var pc: Control = _panels[k]
		pc.visible = (k == name)
		if k == name:
			_place_panel(pc)
	_current_panel = name
	var now_modal := name != ""
	if now_modal != modal_open:
		modal_open = now_modal
		modal_changed.emit(modal_open)


func _place_panel(pc: Control) -> void:
	pc.reset_size()
	var vp := _root.size
	if vp.x <= 0.0:
		vp = Vector2(1920, 1080)
	await get_tree().process_frame
	var sz := pc.size
	if str(pc.get_meta("anchor", "center")) == "bottom":
		pc.position = Vector2((vp.x - sz.x) * 0.5, vp.y - sz.y - 30)
	else:
		pc.position = Vector2((vp.x - sz.x) * 0.5, maxf((vp.y - sz.y) * 0.5, 10.0))
