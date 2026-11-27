extends Node3D
## main.gd — 把所有零件接起來：讀檔 / 存檔、房間節點的建立與回收、玩家、傳送門、介面與各種操作。
##
## 場景樹（全部在執行時建立）：
##   Main
##   ├─ WorldEnvironment
##   ├─ Cells          各房間的節點（只保留目前房間與沿門 2 步內的房間）
##   ├─ PortalSystem
##   ├─ Player（含攝影機）
##   └─ Hud
##
## 存檔內容：{"palace": 空間模型, "session": {cell, pos, yaw, pitch}}，走 A/B 雙緩衝。
## 任何修改只標記 dirty，約 1.2 秒後自動存；App 進背景 / 返回鍵 / 離開時立刻存。

const SM = preload("res://scripts/space_model.gd")
const ST = preload("res://scripts/storage.gd")
const RB = preload("res://scripts/room_builder.gd")
const MV = preload("res://scripts/memory_node_view.gd")
const PS = preload("res://scripts/portal_system.gd")
const PC = preload("res://scripts/player_controller.gd")
const HUD = preload("res://scripts/ui_hud.gd")
const FS = preload("res://scripts/font_setup.gd")

const APP_ROOT := "user://palace"
const THEME_ORDER := ["default", "ivory", "night", "forest", "ocean", "rose"]
const NEW_ROOM_SIZE := Vector3(6.0, 3.0, 6.0)
const BASE_LOOK_SENS := 0.0042
const SAVE_DELAY := 1.2
const STAIR_LENGTH := 4.0
const STAIR_HEADROOM := 0.2
const STAIR_START_GAP := 1.0

const ERROR_TEXT := {
	"overlaps_portal": "這個位置已經有門了",
	"no_room": "這個位置放不下門，換個地方試試",
	"out_of_wall": "門超出牆面範圍",
	"bad_wall": "這裡不能開門",
	"plane_not_empty": "這個位置不能放門",
	"full_wall": "這面牆放不下門",
	"orientation_mismatch": "門的方向不相容",
	"horizontal_needs_floor_and_ceiling": "上下樓的門必須是「地板」配「天花板」",
	"no_room_for_resize": "已到上限：這間或對面那間放不下更大的門了",
}

var model = null
var saves = null
var assets = null
var settings = null
var imports = null

var cells_root: Node3D
var player = null
var portal_system = null
var hud = null

var cell_nodes: Dictionary = {}       # cell_id -> Node3D
var memory_views: Dictionary = {}     # node_id -> MemoryNodeView
var _dirty := false
var _save_timer := 0.0
var _selected_node := ""
var _stretch: Dictionary = {}
var _pending_import_kind := ""


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)
	DisplayServer.screen_set_keep_on(true)
	var font_ok: bool = FS.install()      # 先裝好中文字型，介面才不會變豆腐塊
	_setup_environment()
	_open_stores()

	cells_root = Node3D.new()
	cells_root.name = "Cells"
	add_child(cells_root)
	portal_system = PS.new()
	portal_system.name = "PortalSystem"
	add_child(portal_system)
	player = PC.new()
	player.name = "Player"
	add_child(player)
	hud = HUD.new()
	hud.name = "Hud"
	add_child(hud)
	hud.bind_player(player)
	_connect_signals()

	var loaded := _load_world()
	_apply_settings()
	_start_world(loaded["session"])
	if not font_ok and OS.get_name() == "Android":
		hud.toast("找不到系統中文字型，文字可能顯示成方框（%s）" % FS.status, 8.0)
	elif loaded["message"] != "":
		hud.toast(loaded["message"], 5.0)
	elif loaded["fresh"]:
		hud.toast("歡迎！左手搖桿移動、右手滑動看四周，點金色方塊看記憶，點「選單」蓋房間。", 7.0)


# ====================================================================== 初始化

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = RB.FOG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED      # 省電；畫質靠設定裡的解析度比例


func _open_stores() -> void:
	saves = ST.SaveStore.new(APP_ROOT)
	assets = ST.AssetStore.new(APP_ROOT)
	settings = ST.SettingsStore.new(APP_ROOT)
	settings.load_settings()
	imports = ST.ImportSources.new(APP_ROOT)


func _connect_signals() -> void:
	hud.modal_changed.connect(func(open: bool): player.set_enabled(not open))
	hud.add_requested.connect(_on_add_requested)
	hud.door_requested.connect(_on_door_requested)
	hud.stretch_begin_requested.connect(_begin_stretch)
	hud.stretch_changed.connect(_on_stretch_changed)
	hud.stretch_dir_requested.connect(_on_stretch_dir)
	hud.stretch_offset_step.connect(_on_stretch_offset_step)
	hud.stretch_crosshair_requested.connect(_on_stretch_crosshair)
	hud.stretch_confirmed.connect(_confirm_stretch)
	hud.stretch_cancelled.connect(_end_stretch)
	hud.node_saved.connect(_on_node_saved)
	hud.node_deleted.connect(_on_node_deleted)
	hud.node_move_requested.connect(_on_node_move)
	hud.node_edit_cancelled.connect(_on_node_edit_cancelled)
	hud.viewer_closed.connect(_deselect)
	hud.edit_requested.connect(_on_edit_requested)
	hud.room_selected.connect(_goto_room)
	hud.rooms_requested.connect(_show_rooms)
	hud.settings_requested.connect(func(): hud.show_settings(settings.values))
	hud.room_theme_next_requested.connect(_next_theme)
	hud.settings_changed.connect(_on_settings_changed)
	hud.backup_export_requested.connect(_backup_export)
	hud.backup_import_requested.connect(_backup_import)
	hud.edit_target_requested.connect(_on_edit_target_requested)
	hud.build_requested.connect(_on_build_requested)
	hud.edit_action.connect(_on_edit_action)
	hud.editor_closed.connect(_close_target)
	player.node_picked.connect(_on_node_picked)
	player.cell_entered.connect(_on_cell_entered)
	player.respawned.connect(func(): hud.toast("掉出房間了，已送回上一個安全位置"))


## 讀存檔；失敗或沒有存檔就建立預設宮殿。回傳 {session, fresh, message}
func _load_world() -> Dictionary:
	var out := {"session": {}, "fresh": false, "message": ""}
	var r: Dictionary = saves.load_latest()
	if r["ok"]:
		var payload := _model_from_payload(r["data"])
		if payload["ok"]:
			model = payload["model"]
			out["session"] = payload["session"]
			if r["recovered"]:
				out["message"] = "上一份存檔損毀，已自動回復到前一份完整存檔"
			return out
		out["message"] = "存檔內容無法使用（%s），已建立新的宮殿；舊檔仍保留在存檔槽位中" % payload["error"]
	model = _default_palace()
	out["fresh"] = true
	return out


## 從存檔 payload 還原模型。回傳 {ok, model, session} 或 {ok=false, error}
func _model_from_payload(data: Dictionary) -> Dictionary:
	var pal: Variant = data.get("palace")
	if not (pal is Dictionary):
		return {"ok": false, "error": "no_palace"}
	var m = SM.PalaceModel.from_dict(pal)
	if m.cells.is_empty():
		return {"ok": false, "error": "empty"}
	var problems: Array = m.validate()
	if not problems.is_empty():
		return {"ok": false, "error": str(problems[0])}
	var sess: Variant = data.get("session", {})
	return {"ok": true, "model": m, "session": sess if sess is Dictionary else {}}


func _default_palace():
	var m = SM.PalaceModel.new()
	var c = m.create_cell("入口大廳", "ivory", Vector3(8, 3, 8))
	var n = m.add_memory_node(c.id, "", "", Vector3(4, 1.5, 3.2))
	n.set_prompt("點我看看")
	n.detail_note = "這是第三層「詳情」，點開才看得到。\n把想記的東西放進方塊，用 15 字提示一眼想起來。"
	return m


func _start_world(session: Dictionary) -> void:
	var first_id := _first_cell_id()
	var cid: String = str(session.get("cell", first_id))
	if not model.cells.has(cid):
		cid = first_id
	var cell = model.cells[cid]
	var pos := Vector3(cell.size.x * 0.5, 0.05, cell.size.z * 0.5)
	var yaw := 0.0
	var pitch := 0.0
	var pa: Variant = session.get("pos")
	if pa is Array and pa.size() == 3:
		var cand := Vector3(float(pa[0]), float(pa[1]), float(pa[2]))
		if PC.Logic.inside_cell(cand, cell.size):
			pos = cand
			yaw = float(session.get("yaw", 0.0))
			pitch = float(session.get("pitch", 0.0))
	elif cell.size.z > 4.0:
		pos.z = cell.size.z - 1.5      # 新宮殿：站在後方，面向前方的方塊
	_sync_cells(cid)
	player.setup(model, portal_system)
	player.place_in_cell(cid, pos, yaw, pitch)
	hud.set_room_name(cell.name)


func _first_cell_id() -> String:
	var ids: Array = model.cells.keys()
	ids.sort()
	return str(ids[0])


# ====================================================================== 房間節點管理

## 讓「中心房間 + 沿門 2 步內的房間」保持啟用（有層位、有節點），其餘回收
func _sync_cells(center_id: String) -> void:
	var need: Array = model.neighbor_cells(center_id, 2)
	var dist := {}
	for cid in model.cells:
		dist[cid] = 99
	for cid in need:
		dist[cid] = 1
	dist[center_id] = 0
	for cid in need:
		var cell = model.cells[cid]
		if cell.render_layer <= 0:
			var r: Dictionary = model.activate_cell(cid, dist, need)
			if not r.get("ok", false):
				continue
			var evicted: String = str(r.get("evicted", ""))
			if evicted != "":
				_free_cell_node(evicted)
	for cid in model.cells.keys():
		var c = model.cells[cid]
		if c.render_layer > 0 and not need.has(cid):
			model.release_cell(cid)
			_free_cell_node(cid)
	for cid in need:
		if model.cells[cid].render_layer > 0 and not cell_nodes.has(cid):
			_build_cell_node(cid)


func _build_cell_node(cid: String) -> void:
	var node: Node3D = RB.build_cell(model, cid)
	cells_root.add_child(node)
	cell_nodes[cid] = node
	var views: Dictionary = MV.populate_cell(node, model, cid, assets)
	for k in views:
		memory_views[k] = views[k]


func _free_cell_node(cid: String) -> void:
	var node: Node3D = cell_nodes.get(cid)
	if node != null:
		node.queue_free()
	cell_nodes.erase(cid)
	for k in memory_views.keys():
		if memory_views[k].cell_id == cid:
			memory_views.erase(k)


## 房間幾何改變（擴建、開門、換主題）後重建該房間的節點
func _rebuild_cell(cid: String) -> void:
	var node: Node3D = cell_nodes.get(cid)
	if node == null:
		return
	RB.rebuild_cell(node, model, cid)
	for k in memory_views.keys():
		if memory_views[k].cell_id == cid:
			memory_views.erase(k)
	var views: Dictionary = MV.populate_cell(node, model, cid, assets)
	for k in views:
		memory_views[k] = views[k]
	if cid == player.current_cell_id:
		portal_system.refresh()


func _on_cell_entered(cell_id: String, _portal_id: String) -> void:
	_sync_cells(cell_id)
	hud.set_room_name(model.cells[cell_id].name)
	_mark_dirty()


func _goto_room(cell_id: String) -> void:
	if not model.cells.has(cell_id):
		return
	var cell = model.cells[cell_id]
	_sync_cells(cell_id)
	player.place_in_cell(cell_id, Vector3(cell.size.x * 0.5, 0.05, cell.size.z * 0.5), 0.0, 0.0)
	hud.set_room_name(cell.name)
	_mark_dirty()


func _show_rooms() -> void:
	var rooms: Array = []
	var ids: Array = model.cells.keys()
	ids.sort()
	for cid in ids:
		rooms.append({"id": cid, "name": model.cells[cid].name})
	hud.show_rooms(rooms, player.current_cell_id)


func _next_theme() -> void:
	var cell = model.cells[player.current_cell_id]
	var i := THEME_ORDER.find(cell.theme_id)
	cell.theme_id = THEME_ORDER[(i + 1) % THEME_ORDER.size()]
	_rebuild_cell(cell.id)
	_mark_dirty()
	hud.toast("主題：%s" % cell.theme_id)


# ====================================================================== 記憶節點

func _facing_dir() -> Vector3:
	return -Basis.from_euler(Vector3(0.0, player.get_yaw(), 0.0)).z


## 準心對準的位置（表面前 0.3 m）；沒打到東西就放在前方 2 m。已限制在房間內。
func _placement_point() -> Vector3:
	var cell = model.cells[player.current_cell_id]
	var vp := get_viewport().get_visible_rect().size
	var hit: Dictionary = player.raycast_surface(vp * 0.5)
	var p: Vector3
	if hit.is_empty():
		p = player.eye_position() + _facing_dir() * 2.0
	else:
		p = hit["position"] + hit["normal"] * 0.3
	var m := 0.25
	return Vector3(clampf(p.x, m, cell.size.x - m), clampf(p.y, m, cell.size.y - m), clampf(p.z, m, cell.size.z - m))


func _facing_player_rot(p: Vector3) -> Vector3:
	var d: Vector3 = player.global_position - p
	return Vector3(0.0, atan2(d.x, d.z), 0.0)


func _add_memory(hash: String, type: String, pos: Vector3):
	var n = model.add_memory_node(player.current_cell_id, hash, type, pos)
	n.rot = _facing_player_rot(pos)
	_spawn_view(n)
	_mark_dirty()
	return n


func _spawn_view(n) -> void:
	var node: Node3D = cell_nodes.get(n.cell_id)
	if node == null:
		return
	var holder: Node = node.get_node_or_null("Memories")
	if holder == null:
		MV.populate_cell(node, model, n.cell_id, assets)
		for k in memory_views.keys():
			if memory_views[k].cell_id == n.cell_id:
				memory_views.erase(k)
		for ch in node.get_node("Memories").get_children():
			memory_views[ch.node_id] = ch
		return
	var v = MV.new()
	holder.add_child(v)
	v.setup(n, assets)
	v.set_render_layer(model.cells[n.cell_id].render_layer)
	memory_views[n.id] = v


func _drop_view(node_id: String) -> void:
	var v = memory_views.get(node_id)
	if v != null:
		v.queue_free()
	memory_views.erase(node_id)


func _refresh_view(node_id: String) -> void:
	_drop_view(node_id)
	var n = model.memory_nodes.get(node_id)
	if n != null:
		_spawn_view(n)


func _on_node_picked(node_id: String) -> void:
	if hud.is_panel_open() or not model.memory_nodes.has(node_id):
		return
	_deselect()
	_selected_node = node_id
	var v = memory_views.get(node_id)
	if v != null:
		v.set_selected(true)
	hud.show_node_viewer(model.memory_nodes[node_id])


func _deselect() -> void:
	var v = memory_views.get(_selected_node)
	if v != null:
		v.set_selected(false)
	_selected_node = ""


func _on_edit_requested(node_id: String) -> void:
	var n = model.memory_nodes.get(node_id)
	if n != null:
		hud.open_node_editor(n, false)


func _on_node_saved(node_id: String, prompt: String, detail: String, _is_new: bool) -> void:
	var n = model.memory_nodes.get(node_id)
	if n == null:
		return
	n.set_prompt(prompt)
	n.detail_note = detail
	var v = memory_views.get(node_id)
	if v != null:
		v.set_prompt(n.prompt15)
	_mark_dirty()


func _on_node_deleted(node_id: String) -> void:
	_deselect()
	model.remove_memory_node(node_id)
	_drop_view(node_id)
	_mark_dirty()
	hud.toast("已刪除")


func _on_node_move(node_id: String) -> void:
	var n = model.memory_nodes.get(node_id)
	if n == null or n.cell_id != player.current_cell_id:
		hud.toast("只能在記憶所在的房間裡移動")
		return
	n.pos = _placement_point()
	n.rot = _facing_player_rot(n.pos)
	_refresh_view(node_id)
	_mark_dirty()
	hud.toast("已移到準心位置")


func _on_node_edit_cancelled(node_id: String, is_new: bool) -> void:
	if is_new:
		model.remove_memory_node(node_id)
		_drop_view(node_id)
		_mark_dirty()


# ====================================================================== 新增 / 匯入

func _on_add_requested(kind: String) -> void:
	match kind:
		"blank":
			var n = _add_memory("", "", _placement_point())
			hud.open_node_editor(n, true)
		"import_native":
			var err: Error = ST.ImportSources.open_native(_on_native_files)
			if err == ERR_UNAVAILABLE:
				hud.toast("這台裝置沒有系統選檔視窗。請改用「掃描匯入資料夾」，檔案放在：\n%s" % ProjectSettings.globalize_path(imports.drop_dir), 8.0)
			elif err != OK:
				hud.toast("無法開啟選檔視窗（錯誤 %d），可改用「掃描匯入資料夾」" % err, 6.0)
		"import_drop":
			_place_imported(imports.import_drop(assets), true)


## 原生選檔回呼（可能不在主執行緒）：轉回主執行緒處理
func _on_native_files(status: bool, paths: PackedStringArray, _filter_index: int) -> void:
	if not status or paths.is_empty():
		return
	call_deferred("_import_paths", paths)


func _import_paths(paths: PackedStringArray) -> void:
	_place_imported(imports.import_paths(paths, assets), false)


func _place_imported(summary: Dictionary, from_drop: bool) -> void:
	var results: Array = summary["results"]
	var failed: Array = summary["failed"]
	if results.is_empty():
		if failed.is_empty():
			hud.toast("沒有找到可匯入的圖片或模型" + ("\n請把檔案放到：" + ProjectSettings.globalize_path(imports.drop_dir) if from_drop else ""), 7.0)
		else:
			hud.toast("匯入失敗：%s" % _import_error_text(str(failed[0]["error"])), 6.0)
		return
	var base := _placement_point()
	var right: Vector3 = Basis.from_euler(Vector3(0.0, player.get_yaw(), 0.0)).x
	var last = null
	for i in range(results.size()):
		var r: Dictionary = results[i]
		var off := (float(i) - float(results.size() - 1) * 0.5) * 0.9
		var cell = model.cells[player.current_cell_id]
		var pos := base + right * off
		pos = Vector3(clampf(pos.x, 0.25, cell.size.x - 0.25), pos.y, clampf(pos.z, 0.25, cell.size.z - 0.25))
		last = _add_memory(r["hash"], r["type"], pos)
	var msg := "已匯入 %d 個" % results.size()
	if int(summary["deduped"]) > 0:
		msg += "（%d 個之前已匯入過）" % int(summary["deduped"])
	if not failed.is_empty():
		msg += "；%d 個失敗：%s" % [failed.size(), _import_error_text(str(failed[0]["error"]))]
	if results.size() == 1 and last != null:
		hud.toast(msg)
		hud.open_node_editor(last, true)
	else:
		hud.toast(msg + "。點一下方塊就能編輯文字", 5.0)


func _import_error_text(code: String) -> String:
	if code == "unsupported_format":
		return "不支援的檔案格式（支援 png / jpg / webp / glb / obj）"
	if code == "too_large":
		return "檔案太大（上限 64 MB）"
	if code == "empty":
		return "檔案是空的"
	if code.begins_with("open_failed") or code == "file_not_found":
		return "無法讀取檔案（%s）" % code
	return code


# ====================================================================== 開門 / 樓梯

func _next_theme_for(cell) -> String:
	var i := THEME_ORDER.find(cell.theme_id)
	return THEME_ORDER[(i + 1) % THEME_ORDER.size()]


func _new_room_name() -> String:
	return "房間 %d" % (model.cells.size() + 1)


func _error_text(r: Dictionary) -> String:
	return ERROR_TEXT.get(str(r.get("error", "")), "無法建立（%s）" % str(r.get("error", "?")))


func _on_door_requested(kind: String) -> void:
	match kind:
		"front":
			_door_front()
		"up":
			_stairs_up()
		"down":
			_stairs_down()


## 準心對準的牆面 → 房間牆面編號（−1 = 不是房間外殼，例如打到建材）
func _wall_for_hit(cell, hit: Dictionary) -> int:
	var pos: Vector3 = hit["position"]
	var n: Vector3 = hit["normal"]
	for w in range(4):
		if n.dot(SM.PalaceModel.wall_normal(w)) > 0.95:
			var on_plane := false
			match w:
				0:
					on_plane = absf(pos.x) < 0.05
				1:
					on_plane = absf(pos.x - cell.size.x) < 0.05
				2:
					on_plane = absf(pos.z) < 0.05
				3:
					on_plane = absf(pos.z - cell.size.z) < 0.05
			return w if on_plane else -1
	return -1


func _opposite_wall(w: int) -> int:
	return w ^ 1


func _door_front() -> void:
	var cell = model.cells[player.current_cell_id]
	var vp := get_viewport().get_visible_rect().size
	var hit: Dictionary = player.raycast_surface(vp * 0.5)
	if hit.is_empty() or absf(hit["normal"].y) > 0.3:
		hud.toast("請面向一面牆，把準心對準要開門的位置")
		return
	var wall := _wall_for_hit(cell, hit)
	if wall < 0:
		hud.toast("準心要對準房間的牆（建材上不能開門）")
		return
	var dst_wall := _opposite_wall(wall)
	var new_cell = model.create_cell(_new_room_name(), _next_theme_for(cell), NEW_ROOM_SIZE)
	var dims := SM.PalaceModel.plane_dims(new_cell.size, dst_wall)
	var door_h: float = SM.PalaceModel.default_portal_size(wall).y
	var dst_pos := SM.PalaceModel.plane_point(new_cell.size, dst_wall, dims.x * 0.5, door_h * 0.5)
	var pb: Dictionary = model.place_portal(new_cell.id, dst_wall, dst_pos, Vector2.ZERO, false, true)
	if not pb["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(pb))
		return
	var pa: Dictionary = model.place_portal(cell.id, wall, hit["position"], Vector2.ZERO, false, true)
	if not pa["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(pa))
		return
	var lk: Dictionary = model.link_portals(pa["portal"].id, pb["portal"].id, true)
	if not lk["ok"]:
		model.delete_portal(pa["portal"].id)
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(lk))
		return
	_after_topology_change(cell.id, "已開門，通往「%s」。走進去看看！" % new_cell.name)


func _after_topology_change(cid: String, message: String) -> void:
	_sync_cells(player.current_cell_id)
	_rebuild_cell(cid)
	portal_system.refresh()
	_mark_dirty()
	hud.toast(message, 5.0)


## 樓梯規劃：沿 dir（±X / ±Z）從 from_pos 前方 STAIR_START_GAP 開始，長 STAIR_LENGTH、高 size.y − headroom。
## 回傳 {ok, start, dir, height, hole} 或 {ok=false}；hole = 天花板開口中心（剛好在眼睛穿過天花板的位置上方）
static func plan_stairs(size: Vector3, from_pos: Vector3, dir: Vector3) -> Dictionary:
	var d := Vector3(signf(dir.x), 0.0, 0.0) if absf(dir.x) >= absf(dir.z) else Vector3(0.0, 0.0, signf(dir.z))
	var along_x := absf(d.x) > 0.5
	var along_len := size.x if along_x else size.z
	var lat_len := size.z if along_x else size.x
	var c0 := (from_pos.x if along_x else from_pos.z) + (d.x + d.z) * STAIR_START_GAP
	var c1 := c0 + (d.x + d.z) * STAIR_LENGTH
	var margin := 0.4
	if minf(c0, c1) < margin or maxf(c0, c1) > along_len - margin or lat_len < 1.8:
		return {"ok": false, "error": "no_space"}
	var lat := clampf(from_pos.z if along_x else from_pos.x, 0.9, lat_len - 0.9)
	var height := size.y - STAIR_HEADROOM
	var eye_h := PC.EYE_HEIGHT
	var cross := (size.y - eye_h) * STAIR_LENGTH / height - 0.1   # 眼睛到天花板高度時，沿坡走了多遠（略提前，讓頭先進洞）
	var start := Vector3(c0, 0.0, lat) if along_x else Vector3(lat, 0.0, c0)
	var hole := start + d * cross
	hole.y = size.y
	return {"ok": true, "start": start, "dir": d, "height": height, "hole": hole}


func _stairs_up() -> void:
	var cell = model.cells[player.current_cell_id]
	var plan := plan_stairs(cell.size, player.global_position, _facing_dir())
	if not plan["ok"]:
		hud.toast("前方空間不夠蓋樓梯（需要約 5 公尺長的空地）。換個位置，或先用「擴建」拉長房間", 6.0)
		return
	var new_cell = model.create_cell(_new_room_name(), _next_theme_for(cell), NEW_ROOM_SIZE)
	var pb: Dictionary = model.place_portal(new_cell.id, 4, Vector3(NEW_ROOM_SIZE.x * 0.5, 0.0, NEW_ROOM_SIZE.z * 0.5))
	if not pb["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(pb))
		return
	var pa: Dictionary = model.place_portal(cell.id, 5, plan["hole"])
	if not pa["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(pa))
		return
	var lk: Dictionary = model.link_portals(pa["portal"].id, pb["portal"].id, true)
	if not lk["ok"]:
		model.delete_portal(pa["portal"].id)
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(lk))
		return
	model.add_ramp(cell.id, plan["start"], plan["dir"], SM.PalaceModel.DEFAULT_RAMP_WIDTH, STAIR_LENGTH, plan["height"])
	_after_topology_change(cell.id, "已蓋好樓梯。沿斜坡走上去，就會從「%s」的地板洞口出來。" % new_cell.name)


func _stairs_down() -> void:
	var cell = model.cells[player.current_cell_id]
	var new_cell = model.create_cell(_new_room_name(), _next_theme_for(cell), NEW_ROOM_SIZE)
	# 下面那間房的樓梯：從 (0.8, 0, 中線) 往 +X
	var plan := plan_stairs(new_cell.size, Vector3(-0.2, 0.0, new_cell.size.z * 0.5), Vector3.RIGHT)
	if not plan["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast("無法建立下樓房間")
		return
	var pb: Dictionary = model.place_portal(new_cell.id, 5, plan["hole"])
	if not pb["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(pb))
		return
	var foot := Vector3(clampf(player.global_position.x, 0.6, cell.size.x - 0.6), 0.0, clampf(player.global_position.z, 0.6, cell.size.z - 0.6))
	var pa: Dictionary = model.place_portal(cell.id, 4, foot)
	if not pa["ok"]:
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(pa))
		return
	var lk: Dictionary = model.link_portals(pa["portal"].id, pb["portal"].id, true)
	if not lk["ok"]:
		model.delete_portal(pa["portal"].id)
		model.remove_cell(new_cell.id)
		hud.toast(_error_text(lk))
		return
	model.add_ramp(new_cell.id, plan["start"], plan["dir"], SM.PalaceModel.DEFAULT_RAMP_WIDTH, STAIR_LENGTH, plan["height"])
	_after_topology_change(cell.id, "已在腳下挖出洞口。走進洞口就會掉進「%s」，那裡有樓梯可以走回來。" % new_cell.name)


# ====================================================================== 擴建（Split & Stretch）

const STRETCH_MIN_OFFSET := 0.3
const STRETCH_DIR_NAMES := ["前方", "後方", "左邊", "右邊"]


static func _cardinal(v: Vector3) -> Vector3:
	if absf(v.x) >= absf(v.z) and absf(v.x) > 1e-6:
		return Vector3(signf(v.x), 0.0, 0.0)
	if absf(v.z) > 1e-6:
		return Vector3(0.0, 0.0, signf(v.z))
	return Vector3(0.0, 0.0, -1.0)


## 以目前視角為準，把「前 / 後 / 左 / 右」換成房間座標軸上的方向（單位向量）
func _stretch_dir_vec(kind: int) -> Vector3:
	var f := _cardinal(_facing_dir())
	match kind:
		1:
			return -f
		2:
			return Vector3(f.z, 0.0, -f.x)
		3:
			return Vector3(-f.z, 0.0, f.x)
		_:
			return f


## 目前擴建設定換算成：沿哪條軸、切線在哪、玩家會不會被推到另一側
func _stretch_plan() -> Dictionary:
	var cell = model.cells[_stretch["cell"]]
	var v: Vector3 = _stretch["vec"]
	var axis: int = SM.PalaceModel.AXIS_X if absf(v.x) > 0.5 else SM.PalaceModel.AXIS_Z
	var sgn: float = v.x if axis == SM.PalaceModel.AXIS_X else v.z
	var coord: float = player.global_position.x if axis == SM.PalaceModel.AXIS_X else player.global_position.z
	var length: float = cell.size.x if axis == SM.PalaceModel.AXIS_X else cell.size.z
	var raw: float = coord + sgn * float(_stretch["offset"])
	var cut := clampf(raw, 0.1, length)
	return {
		"axis": axis, "sign": sgn, "coord": coord, "cut": cut, "length": length,
		"delta": float(_stretch["delta"]),
		"clamped": absf(raw - cut) > 1e-4,
		"player_shifts": SM.PalaceModel.shifts_with_stretch(coord, cut),
	}


func _begin_stretch() -> void:
	_end_stretch()
	_stretch = {"cell": player.current_cell_id, "delta": 2.0, "offset": 1.0, "kind": 0,
		"vec": _stretch_dir_vec(0), "slab": null, "sig": ""}
	_update_stretch_preview()
	hud.show_stretch(_stretch_info_text(), 2.0, 0)


func _stretch_info_text() -> String:
	var pl := _stretch_plan()
	var kind: int = _stretch["kind"]
	var txt := "新空間在你的%s，深 %.1f 公尺；切線離你 %.1f 公尺。" % [STRETCH_DIR_NAMES[kind], pl["delta"], absf(pl["cut"] - pl["coord"])]
	if pl["clamped"]:
		txt += "\n（切線已貼到牆邊）"
	if pl["player_shifts"]:
		txt += "\n你會跟著被推到新空間的另一側。"
	else:
		txt += "\n你會留在原地。"
	txt += "\n綠色方塊 = 即將多出來的空間。"
	return txt


func _refresh_stretch_ui() -> void:
	_update_stretch_preview()
	hud.update_stretch(_stretch_info_text(), _stretch["delta"], _stretch["kind"])


func _update_stretch_preview() -> void:
	if _stretch.is_empty():
		return
	var cid: String = _stretch["cell"]
	var cell = model.cells[cid]
	var node: Node3D = cell_nodes.get(cid)
	if node == null:
		return
	var pl := _stretch_plan()
	var sig := "%d|%.3f|%.3f" % [pl["axis"], pl["cut"], pl["delta"]]
	if sig == _stretch["sig"] and _stretch["slab"] != null:
		return
	_stretch["sig"] = sig
	var pv: MeshInstance3D = _stretch["slab"]
	if pv == null:
		pv = RB.make_slab_preview(cell.size, pl["axis"], pl["cut"], pl["delta"])
		node.add_child(pv)
		RB.apply_layers(pv, cell.render_layer, 0)
		_stretch["slab"] = pv
	else:
		RB.update_slab_preview(pv, cell.size, pl["axis"], pl["cut"], pl["delta"])


func _on_stretch_dir(kind: int) -> void:
	if _stretch.is_empty():
		return
	_stretch["kind"] = kind
	_stretch["vec"] = _stretch_dir_vec(kind)
	_refresh_stretch_ui()


func _on_stretch_changed(delta: float) -> void:
	if _stretch.is_empty():
		return
	_stretch["delta"] = delta
	_refresh_stretch_ui()


func _on_stretch_offset_step(step: float) -> void:
	if _stretch.is_empty():
		return
	_stretch["offset"] = clampf(float(_stretch["offset"]) + step, STRETCH_MIN_OFFSET, 30.0)
	_refresh_stretch_ui()


## 把切線設在準心對準的位置（沿目前選的方向量距離）
func _on_stretch_crosshair() -> void:
	if _stretch.is_empty():
		return
	var vp := get_viewport().get_visible_rect().size
	var hit: Dictionary = player.raycast_surface(vp * 0.5)
	if hit.is_empty():
		hud.toast("準心沒有對到任何東西")
		return
	var v: Vector3 = _stretch["vec"]
	var d: float = (hit["position"] - player.global_position).dot(v)
	if d < STRETCH_MIN_OFFSET:
		hud.toast("準心要對在新空間那一側的前方")
		return
	_stretch["offset"] = snappedf(d, 0.1)
	_refresh_stretch_ui()


func _confirm_stretch(delta: float = -1.0) -> void:
	if _stretch.is_empty():
		return
	if delta > 0.0:
		_stretch["delta"] = delta
	var cid: String = _stretch["cell"]
	var pl := _stretch_plan()
	_end_stretch()
	var r: Dictionary = model.split_and_stretch(cid, pl["axis"], pl["cut"], pl["delta"])
	if not r["ok"]:
		hud.toast("無法擴建（%s）" % str(r.get("error", "?")))
		return
	# 玩家和其他東西同一條規則：在切線正側的整個被推開
	if pl["player_shifts"] and player.current_cell_id == cid:
		var push := Vector3(pl["delta"], 0.0, 0.0) if pl["axis"] == SM.PalaceModel.AXIS_X else Vector3(0.0, 0.0, pl["delta"])
		player.global_position += push
	_rebuild_cell(cid)
	portal_system.refresh()
	_mark_dirty()
	hud.toast("已拉開 %.1f 公尺的新空間" % pl["delta"])


func _end_stretch() -> void:
	if not _stretch.is_empty():
		var pv = _stretch.get("slab")
		if pv != null and is_instance_valid(pv):
			pv.queue_free()
	_stretch = {}


# ====================================================================== 設定

func _apply_settings() -> void:
	var real_display := DisplayServer.get_name() != "headless"
	Engine.max_fps = int(settings.get_value("max_fps")) if real_display else 0
	if real_display:
		OS.low_processor_usage_mode = true            # 畫面沒變就不重畫，靜止時幾乎不耗電
		OS.low_processor_usage_mode_sleep_usec = 6900
	get_viewport().scaling_3d_scale = float(settings.get_value("render_scale"))
	player.look_sensitivity = BASE_LOOK_SENS * float(settings.get_value("look_sensitivity"))
	player.swap_sides = bool(settings.get_value("mirror_ui"))
	portal_system.max_visible = int(settings.get_value("max_visible_portals"))


func _on_settings_changed(values: Dictionary) -> void:
	for k in values:
		settings.set_value(k, values[k])
	settings.save_settings()
	_apply_settings()


# ====================================================================== 存檔 / 備份

func _mark_dirty() -> void:
	_dirty = true
	_save_timer = SAVE_DELAY


func _payload() -> Dictionary:
	var p: Vector3 = player.global_position
	return {
		"palace": model.to_dict(),
		"session": {
			"cell": player.current_cell_id,
			"pos": [p.x, p.y, p.z],
			"yaw": player.get_yaw(),
			"pitch": player.get_pitch(),
		},
	}


func save_now() -> Error:
	if model == null or player == null or player.current_cell_id == "":
		return ERR_UNCONFIGURED
	var err: Error = saves.save(_payload())
	if err == OK:
		_dirty = false
	else:
		hud.toast("存檔失敗（錯誤 %d）" % err, 5.0)
	return err


func _process(delta: float) -> void:
	if not _stretch.is_empty():
		var old_sig: String = _stretch["sig"]
		_update_stretch_preview()
		if _stretch["sig"] != old_sig:
			hud.update_stretch(_stretch_info_text(), _stretch["delta"], _stretch["kind"])
	if _dirty:
		_save_timer -= delta
		if _save_timer <= 0.0:
			save_now()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			save_now()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if hud != null and hud.handle_back():
				return
			save_now()
			get_tree().quit()
		NOTIFICATION_WM_CLOSE_REQUEST:
			save_now()
			get_tree().quit()


func _backup_export() -> void:
	if save_now() != OK:
		return
	var dir := APP_ROOT.path_join("backups")
	ST.Io.ensure_dir(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := dir.path_join("memory-palace-%s.zip" % stamp)
	var err: Error = ST.Backup.export_backup(path, saves, assets, settings)
	if err != OK:
		hud.toast("備份失敗（錯誤 %d）" % err, 5.0)
		return
	_pending_import_kind = path
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		var ferr := DisplayServer.file_dialog_show("選擇備份存放位置", "", "memory-palace-%s.zip" % stamp, false,
			DisplayServer.FILE_DIALOG_MODE_SAVE_FILE, PackedStringArray(), _on_backup_target)
		if ferr == OK:
			hud.toast("請選擇要把備份存到哪裡", 5.0)
			return
	_copy_backup_to_documents(path)


func _on_backup_target(status: bool, paths: PackedStringArray, _idx: int) -> void:
	if not status or paths.is_empty():
		call_deferred("_copy_backup_to_documents", _pending_import_kind)
		return
	call_deferred("_write_backup_to", _pending_import_kind, str(paths[0]))


func _write_backup_to(src: String, dest: String) -> void:
	var bytes := ST.Io.read_bytes(src)
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null or bytes.is_empty():
		_copy_backup_to_documents(src)
		return
	f.store_buffer(bytes)
	f.close()
	hud.toast("備份已存到你選的位置", 5.0)


func _copy_backup_to_documents(src: String) -> void:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "":
		var dest_dir := docs.path_join("記憶宮殿備份")
		DirAccess.make_dir_recursive_absolute(dest_dir)
		var dest := dest_dir.path_join(src.get_file())
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(src), dest) == OK:
			hud.toast("備份已存到：%s" % dest, 7.0)
			return
	hud.toast("備份已存在 App 內：%s\n（無法複製到手機的文件資料夾）" % ProjectSettings.globalize_path(src), 8.0)


func _backup_import() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		hud.toast("這台裝置沒有系統選檔視窗。請把備份 zip 放進 App 內的 import_drop 資料夾後再試", 7.0)
		return
	var filters := PackedStringArray()
	if OS.get_name() != "Android":
		filters.append("*.zip; 備份檔")
	var err := DisplayServer.file_dialog_show("選擇備份檔", "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters, _on_backup_picked)
	if err != OK:
		hud.toast("無法開啟選檔視窗（錯誤 %d）" % err)


func _on_backup_picked(status: bool, paths: PackedStringArray, _idx: int) -> void:
	if not status or paths.is_empty():
		return
	var path := str(paths[0])
	call_deferred("_confirm_restore", path)


func _confirm_restore(path: String) -> void:
	hud.confirm("還原備份會取代目前的整個宮殿，確定嗎？", func(): _restore_backup(path))


func _restore_backup(path: String) -> void:
	# Android 的選擇結果可能是 content:// URI，先讀成位元組寫到暫存檔再交給備份讀取器
	var tmp := APP_ROOT.path_join("restore_tmp.zip")
	var bytes := ST.Io.read_bytes(path)
	if bytes.is_empty():
		hud.toast("讀不到這個檔案", 5.0)
		return
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		hud.toast("無法建立暫存檔", 5.0)
		return
	f.store_buffer(bytes)
	f.close()
	var r: Dictionary = ST.Backup.import_backup(tmp, assets)
	DirAccess.remove_absolute(tmp)
	if not r["ok"]:
		hud.toast("還原失敗：%s" % str(r["error"]), 7.0)
		return
	var payload := _model_from_payload(r["palace"])
	if not payload["ok"]:
		hud.toast("備份內容無法使用：%s" % str(payload["error"]), 7.0)
		return
	for k in r["settings"]:
		settings.set_value(k, r["settings"][k])
	settings.save_settings()
	_replace_world(payload["model"], payload["session"])
	save_now()
	hud.toast("已還原（匯入 %d 個素材）" % int(r["assets_imported"]), 5.0)


func _replace_world(new_model, session: Dictionary) -> void:
	_end_stretch()
	_deselect()
	for cid in cell_nodes.keys():
		cell_nodes[cid].queue_free()
	cell_nodes.clear()
	memory_views.clear()
	model = new_model
	_apply_settings()
	_start_world(session)


# ====================================================================== 放置平台 / 欄桿

func _anchor_point() -> Vector3:
	var vp := get_viewport().get_visible_rect().size
	var hit: Dictionary = player.raycast_surface(vp * 0.5)
	if hit.is_empty():
		var far: Vector3 = player.eye_position() + _facing_dir() * 2.0
		far.y = 0.0
		return far
	var pos: Vector3 = hit["position"]
	var n: Vector3 = hit["normal"]
	if n.y > 0.7:
		return pos                                   # 地板或平台頂面：就放在那裡
	return Vector3(pos.x + n.x, 0.0, pos.z + n.z)    # 打到牆：放在牆前 1 公尺的地面


func _on_build_requested(kind: String) -> void:
	var cell = model.cells[player.current_cell_id]
	var a := _anchor_point()
	var s = null
	if kind == "platform":
		s = model.add_platform(cell.id, Vector3(a.x - 1.0, maxf(a.y, 0.0) + 0.3, a.z - 1.0), Vector2(2.0, 2.0), 0.3)
		model.move_structure(s.id, s.pos)
	elif kind == "railing":
		s = model.add_railing(cell.id, a, _facing_dir(), 2.0, 1.0)
		model.move_structure(s.id, s.pos)
	if s == null:
		return
	_rebuild_cell(cell.id)
	_mark_dirty()
	_open_target("structure", s.id)


# ====================================================================== 編輯門與建材

var _target: Dictionary = {}         # {kind, id, box}


func _structure_id_of(collider: Object) -> String:
	var n: Node = collider as Node
	while n != null:
		if n.has_meta("structure_id"):
			return str(n.get_meta("structure_id"))
		n = n.get_parent()
	return ""


## 準心對準的門或建材。回傳 {kind, id} 或 {}
func _pick_target() -> Dictionary:
	var cell = model.cells[player.current_cell_id]
	var cam: Camera3D = player.camera
	var c := get_viewport().get_visible_rect().size * 0.5
	var from := cam.project_ray_origin(c)
	var dir := cam.project_ray_normal(c)
	var best_t := INF
	var best_pid := ""
	for pid in cell.portals:
		var p = model.portals[pid]
		var n: Vector3 = p.normal.normalized()
		var denom := dir.dot(n)
		if denom > -0.01:
			continue
		var t: float = (p.local_pos - from).dot(n) / denom
		if t <= 0.0 or t > PC.PICK_DISTANCE or t >= best_t:
			continue
		if PS.Logic.inside_rect(p, from + dir * t, 0.15):
			best_t = t
			best_pid = pid
	var hit: Dictionary = player.raycast_surface(c)
	if not hit.is_empty():
		var sid := _structure_id_of(hit["collider"])
		if sid != "" and model.structures.has(sid) and (best_pid == "" or float(hit["distance"]) < best_t - 0.02):
			return {"kind": "structure", "id": sid}
	if best_pid != "":
		return {"kind": "portal", "id": best_pid}
	return {}


func _on_edit_target_requested() -> void:
	if hud.is_panel_open():
		return
	var t := _pick_target()
	if t.is_empty():
		hud.toast("請把準心對準一扇門，或一個平台 / 欄桿 / 斜坡，再按「編輯」", 4.0)
		return
	_open_target(str(t["kind"]), str(t["id"]))


func _open_target(kind: String, id: String) -> void:
	_close_target_box()
	_target = {"kind": kind, "id": id, "box": null}
	_refresh_target()


func _close_target() -> void:
	_close_target_box()
	_target = {}


func _close_target_box() -> void:
	var b = _target.get("box")
	if b != null and is_instance_valid(b):
		b.queue_free()
	if not _target.is_empty():
		_target["box"] = null


func _target_exists() -> bool:
	if _target.is_empty():
		return false
	return model.portals.has(_target["id"]) if _target["kind"] == "portal" else model.structures.has(_target["id"])


func _structure_aabb(s) -> AABB:
	if s.kind == "platform":
		return AABB(Vector3(s.pos.x, s.pos.y - s.thickness, s.pos.z), Vector3(s.size.x, s.thickness, s.size.y))
	if s.kind == "railing":
		var a: Vector3 = s.pos
		var b: Vector3 = s.end_pos()
		var lo := Vector3(minf(a.x, b.x), a.y, minf(a.z, b.z))
		var hi := Vector3(maxf(a.x, b.x), a.y + s.height, maxf(a.z, b.z))
		return AABB(lo, hi - lo)
	var pts: PackedVector3Array = s.convex_points()
	var bb := AABB(pts[0], Vector3.ZERO)
	for q in pts:
		bb = bb.expand(q)
	return bb


func _portal_aabb(p) -> AABB:
	var cell = model.cells[p.cell_id]
	var rect := SM.PalaceModel.portal_rect(p)
	var a := SM.PalaceModel.plane_point(cell.size, p.wall_index, rect.position.x, rect.position.y)
	var b := SM.PalaceModel.plane_point(cell.size, p.wall_index, rect.end.x, rect.end.y)
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	return AABB(lo, hi - lo).grow(0.05)


func _show_target_box() -> void:
	_close_target_box()
	if not _target_exists():
		return
	var cid: String
	var box: AABB
	if _target["kind"] == "portal":
		var p = model.portals[_target["id"]]
		cid = p.cell_id
		box = _portal_aabb(p)
	else:
		var s = model.structures[_target["id"]]
		cid = s.cell_id
		box = _structure_aabb(s).grow(0.04)
	var node: Node3D = cell_nodes.get(cid)
	if node == null:
		return
	var mi: MeshInstance3D = RB.make_wire_box(box.size, Color(0.4, 0.85, 1.0))
	mi.position = box.get_center()
	node.add_child(mi)
	RB.apply_layers(mi, model.cells[cid].render_layer, 0)
	_target["box"] = mi


## 依目前選取的門 / 建材重畫編輯面板與外框
func _refresh_target() -> void:
	if not _target_exists():
		_close_target()
		hud.close_panel()
		return
	_show_target_box()
	if _target["kind"] == "portal":
		_show_portal_panel(model.portals[_target["id"]])
	else:
		_show_structure_panel(model.structures[_target["id"]])


func _show_portal_panel(p) -> void:
	var horiz: bool = p.is_horizontal()
	var wlab := "寬"
	var hlab := "長" if horiz else "高"
	var linked := "已連通" if p.target_portal_id != "" else "尚未連通"
	var kind_name := "地板開口" if p.wall_index == 4 else ("天花板開口" if p.wall_index == 5 else "牆上的門")
	var info := "%s　%s %.1f × %s %.1f 公尺　（%s）\n從中心往兩側縮放，碰到牆會自動挪開；連通的另一邊會同時變成一樣大。" % [kind_name, wlab, p.size.x, hlab, p.size.y, linked]
	var rows: Array = [
		[[wlab + " -", "pw-"], [wlab + " +", "pw+"], [hlab + " -", "ph-"], [hlab + " +", "ph+"]],
	]
	if horiz:
		rows.append([["左移", "pm:left"], ["右移", "pm:right"], ["前移", "pm:forward"], ["後移", "pm:back"]])
	else:
		rows.append([["左移", "pm:left"], ["右移", "pm:right"], ["上移", "pm:up"], ["下移", "pm:down"]])
	rows.append([["移到準心位置", "pcross"], ["刪除這扇門", "pdel"]])
	hud.show_editor("編輯：%s" % kind_name, info, rows)


func _show_structure_panel(s) -> void:
	var rows: Array = []
	var info := ""
	var title := ""
	if s.kind == "platform":
		title = "編輯：平台"
		info = "長寬 %.1f × %.1f 公尺，頂面高度 %.1f 公尺。\n低於 0.35 公尺的台階可以直接走上去；更高的需要斜坡。" % [s.size.x, s.size.y, s.pos.y]
		rows = [
			[["變窄", "ps:w-"], ["變寬", "ps:w+"], ["變短", "ps:l-"], ["變長", "ps:l+"]],
			[["降低", "ph-"], ["升高", "ph+"]],
		]
	elif s.kind == "railing":
		title = "編輯：欄桿"
		info = "長度 %.1f 公尺，高 %.1f 公尺。" % [s.length, s.height]
		rows = [[["縮短", "rl-"], ["加長", "rl+"], ["轉 90 度", "rrot"]]]
	else:
		title = "編輯：斜坡"
		var slope: float = s.slope_angle_deg()
		info = "長 %.1f、高 %.1f、寬 %.1f 公尺，坡度 %.0f 度。" % [s.length, s.height, s.width, slope]
		if slope > 50.0:
			info += "\n太陡了，走不上去，請加長或降低。"
		rows = [
			[["變短", "rp:l-"], ["變長", "rp:l+"], ["降低", "rp:h-"], ["升高", "rp:h+"]],
			[["變窄", "rp:w-"], ["變寬", "rp:w+"], ["轉 90 度", "rrot"]],
		]
	rows.append([["移到準心位置", "scross"], ["刪除", "sdel"]])
	hud.show_editor(title, info, rows)


## 視角「右方」與「前方」（水平）
func _view_right() -> Vector3:
	return Basis.from_euler(Vector3(0.0, player.get_yaw(), 0.0)).x


## 把任意水平向量吸附成 ±X 或 ±Z
func _snap_axis(v: Vector3) -> Vector3:
	if absf(v.x) >= absf(v.z):
		return Vector3(signf(v.x), 0.0, 0.0)
	return Vector3(0.0, 0.0, signf(v.z))


## 以目前視角為準，哪一條世界軸算「寬」（左右方向）；回傳 "size_x" 或 "size_z"
func _wide_op() -> String:
	return "size_x" if absf(_view_right().x) >= absf(_view_right().z) else "size_z"


func _narrow_op() -> String:
	return "size_z" if _wide_op() == "size_x" else "size_x"


func _on_edit_action(action: String) -> void:
	if not _target_exists():
		return
	if _target["kind"] == "portal":
		_portal_action(action)
	else:
		_structure_action(action)


func _portal_action(action: String) -> void:
	var p = model.portals[_target["id"]]
	var cid: String = p.cell_id
	var step := 0.2
	var changed := false
	match action:
		"pw-", "pw+", "ph-", "ph+":
			var d := -step if action.ends_with("-") else step
			var want: Vector2 = p.size + (Vector2(d, 0.0) if action.begins_with("pw") else Vector2(0.0, d))
			var before: Vector2 = p.size
			var r: Dictionary = model.resize_portal(p.id, want)
			if not r["ok"]:
				hud.toast(_error_text(r))
				return
			changed = not p.size.is_equal_approx(before)
			if changed and r.get("shifted", false):
				hud.toast("碰到牆了，門自動往反方向挪開")
			if not changed and d > 0.0:
				hud.toast(ERROR_TEXT["no_room_for_resize"])
		"pm:left", "pm:right", "pm:forward", "pm:back", "pm:up", "pm:down":
			var dirv := Vector3.ZERO
			match action:
				"pm:left":
					dirv = -_view_right()
				"pm:right":
					dirv = _view_right()
				"pm:forward":
					dirv = _facing_dir()
				"pm:back":
					dirv = -_facing_dir()
				"pm:up":
					dirv = Vector3.UP
				"pm:down":
					dirv = Vector3.DOWN
			var n: Vector3 = p.normal.normalized()
			dirv -= n * dirv.dot(n)                      # 只能沿門所在的平面移動
			if absf(dirv.y) > maxf(absf(dirv.x), absf(dirv.z)):
				dirv = Vector3(0.0, signf(dirv.y), 0.0)
			else:
				dirv = _snap_axis(dirv)
			if dirv.length() < 0.5:
				return
			var before: Vector3 = p.local_pos
			var r2: Dictionary = model.move_portal(p.id, p.local_pos + dirv * step)
			if not r2["ok"]:
				hud.toast(_error_text(r2))
				return
			changed = not p.local_pos.is_equal_approx(before)
			if not changed:
				hud.toast("再往那個方向就撞到牆角或別的門了")
		"pcross":
			var hit: Dictionary = player.raycast_surface(get_viewport().get_visible_rect().size * 0.5)
			if hit.is_empty() or hit["normal"].dot(p.normal.normalized()) < 0.9:
				hud.toast("請把準心對準「同一面牆（或同一個地板 / 天花板）」上要移動到的位置")
				return
			var r3: Dictionary = model.move_portal(p.id, hit["position"])
			if not r3["ok"]:
				hud.toast(_error_text(r3))
				return
			changed = true
		"pdel":
			var pid: String = p.id
			hud.confirm("確定要刪除這扇門嗎？（對面的門會變成沒有連通）", func():
				model.delete_portal(pid)
				_close_target()
				hud.close_panel()
				_after_topology_change(cid, "已刪除門"))
			return
	if changed:
		_rebuild_cell(cid)
		var mate = model.partner_of(p.id) if model.portals.has(p.id) else null
		if mate != null and mate.cell_id != cid and cell_nodes.has(mate.cell_id):
			_rebuild_cell(mate.cell_id)   # 對面那扇門也一起變了
		portal_system.refresh()
		_mark_dirty()
	_refresh_target()


func _structure_action(action: String) -> void:
	var s = model.structures[_target["id"]]
	var cid: String = s.cell_id
	var r: Dictionary = {"ok": true, "changed": false}
	match action:
		"ps:w-":
			r = model.adjust_structure(s.id, _wide_op(), -0.5)
		"ps:w+":
			r = model.adjust_structure(s.id, _wide_op(), 0.5)
		"ps:l-":
			r = model.adjust_structure(s.id, _narrow_op(), -0.5)
		"ps:l+":
			r = model.adjust_structure(s.id, _narrow_op(), 0.5)
		"ph-":
			r = model.adjust_structure(s.id, "height", -0.5)
		"ph+":
			r = model.adjust_structure(s.id, "height", 0.5)
		"rl-":
			r = model.adjust_structure(s.id, "length", -0.5)
		"rl+":
			r = model.adjust_structure(s.id, "length", 0.5)
		"rp:l-":
			r = model.adjust_structure(s.id, "length", -0.5)
		"rp:l+":
			r = model.adjust_structure(s.id, "length", 0.5)
		"rp:h-":
			r = model.adjust_structure(s.id, "height", -0.5)
		"rp:h+":
			r = model.adjust_structure(s.id, "height", 0.5)
		"rp:w-":
			r = model.adjust_structure(s.id, "width", -0.5)
		"rp:w+":
			r = model.adjust_structure(s.id, "width", 0.5)
		"rrot":
			r = model.adjust_structure(s.id, "rotate")
		"scross":
			var hit: Dictionary = player.raycast_surface(get_viewport().get_visible_rect().size * 0.5)
			if hit.is_empty() or _structure_id_of(hit["collider"]) == s.id:
				hud.toast("請把準心對準地面上要移動到的位置（不要對準它自己）")
				return
			var hp: Vector3 = hit["position"]
			var np := hp
			if s.kind == "platform":
				np = Vector3(hp.x - s.size.x * 0.5, s.pos.y, hp.z - s.size.y * 0.5)
			elif s.kind == "ramp":
				np = Vector3(hp.x, 0.0, hp.z)
			elif hit["normal"].y <= 0.7:
				np = Vector3(hp.x, s.pos.y, hp.z)
			r = model.move_structure(s.id, np)
		"sdel":
			var sid: String = s.id
			var cell = model.cells[cid]
			hud.confirm("確定要刪除這個建材嗎？", func():
				model.structures.erase(sid)
				cell.structures.erase(sid)
				_close_target()
				hud.close_panel()
				_rebuild_cell(cid)
				_mark_dirty()
				hud.toast("已刪除"))
			return
	if not r.get("ok", false):
		hud.toast("無法調整（%s）" % str(r.get("error", "?")))
		return
	if r.get("changed", false):
		_rebuild_cell(cid)
		_mark_dirty()
	else:
		hud.toast("已到上限（房間邊界或最小尺寸）")
	_refresh_target()
