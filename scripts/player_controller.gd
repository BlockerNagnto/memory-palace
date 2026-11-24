extends CharacterBody3D
## player_controller.gd — 第一人稱玩家：觸控搖桿 + 滑動視角 + 點擊互動 + 穿過傳送門
##
## 觸控操作（預設）：
##   螢幕左半 = 浮動搖桿（手指按下處為中心）；螢幕右半 = 拖曳轉視角；右半「短點一下」= 點選記憶節點。
##   swap_sides = true 時左右互換。
## 桌面測試：WASD / 方向鍵移動、空白鍵跳、滑鼠拖曳轉視角、點一下 = 點選。
##
## 世界約定（與 space_model / portal_system 一致）：
##   - 每間房的本地座標 = 世界座標；各房間靠視覺層 / 物理層分開（房間物理層 N 的牆只和 mask 含 N 的物體碰撞）。
##   - 玩家在物理層 21，碰撞遮罩每個物理幀依「目前房間」的物理層更新。
##   - 記憶節點的點選碰撞體在物理層 23（INTERACT_BIT）。
##   - 玩家節點原點在腳底；攝影機在 EYE_HEIGHT。穿門以「眼睛」位置判定，傳送後用整數矩陣 M 轉換位置與朝向。
##
## 純邏輯集中在 Logic（無節點、可無頭測試）。

const SM = preload("res://scripts/space_model.gd")

signal tapped(screen_pos: Vector2)                      # 右半螢幕短點（未必點到東西）
signal node_picked(node_id: String)                     # 點到記憶節點
signal cell_entered(cell_id: String, portal_id: String)  # 穿過傳送門進入新房間
signal respawned()                                      # 掉出世界，被送回最後安全位置

const EYE_HEIGHT := 1.6
const BODY_RADIUS := 0.3
const BODY_HEIGHT := 1.75
const PLAYER_LAYER_BIT := 1 << 20     # 物理層 21
const INTERACT_BIT := 1 << 22         # 物理層 23
const PICK_DISTANCE := 8.0
const MAX_PICK_STEPS := 8


## ====================================================================== 純邏輯
class Logic:
	const JOY_DEADZONE := 0.12
	const TAP_MAX_SECONDS := 0.28
	const TAP_MAX_MOVE_PX := 20.0
	const MAX_PITCH := deg_to_rad(85.0)
	const OOB_MARGIN := 6.0

	## 搖桿向量：回傳長度 ≤ 1 的 Vector2（右 = +x、螢幕下 = +y；往上推 = 前進）。
	static func joystick_vector(origin: Vector2, pos: Vector2, radius: float) -> Vector2:
		if radius <= 0.0:
			return Vector2.ZERO
		var d := (pos - origin) / radius
		var mag := d.length()
		if mag < JOY_DEADZONE:
			return Vector2.ZERO
		# 死區外重新映射到 0~1，避免一出死區就突然起步
		var scaled := (minf(mag, 1.0) - JOY_DEADZONE) / (1.0 - JOY_DEADZONE)
		return d / mag * scaled

	## 依輸入與朝向（yaw，弧度，繞 Y）算出水平期望速度
	static func wish_velocity(input: Vector2, yaw: float, speed: float) -> Vector3:
		var v := Vector3(input.x, 0.0, input.y)
		if v.length() > 1.0:
			v = v.normalized()
		return Basis.from_euler(Vector3(0.0, yaw, 0.0)) * v * speed

	## 基底的水平朝向（forward = −Z）換成 yaw；與 Basis.from_euler(0, yaw, 0) 互逆
	static func yaw_of(b: Basis) -> float:
		var f := -b.z
		return atan2(-f.x, -f.z)

	static func clamp_pitch(p: float) -> float:
		return clampf(p, -MAX_PITCH, MAX_PITCH)

	static func is_tap(duration_sec: float, moved_px: float) -> bool:
		return duration_sec <= TAP_MAX_SECONDS and moved_px <= TAP_MAX_MOVE_PX

	## 穿過傳送門後的玩家位置與 yaw（傳送門矩陣只含繞 Y 的旋轉與平移，所以保持直立）
	static func teleported(pos: Vector3, yaw: float, m: Transform3D) -> Dictionary:
		var new_basis: Basis = m.basis * Basis.from_euler(Vector3(0.0, yaw, 0.0))
		return {"pos": m * pos, "yaw": yaw_of(new_basis)}

	## 由天花板門向上穿過（出口在對側的地板門）
	static func is_upward(src, dst) -> bool:
		return src.is_horizontal() and dst.is_horizontal() and src.normal.y < 0.0 and dst.normal.y > 0.0

	## 向上穿過門時，腳會落在出口地板門「下方」（眼睛剛好在門平面上），
	## 這個位移把玩家抬到出口房間的地板上、並往前推出門洞外；鏡頭以相反偏移緩升，畫面不會跳。
	static func climb_out_offset(new_pos: Vector3, yaw: float, dst) -> Vector3:
		var lift := maxf(dst.local_pos.y - new_pos.y, 0.0)
		var fwd := -Basis.from_euler(Vector3(0.0, yaw, 0.0)).z
		var reach := maxf(dst.size.x, dst.size.y) * 0.5 + 0.3 + 0.15
		return Vector3(0.0, lift, 0.0) + fwd * reach

	## 掉出世界：離房間範圍太遠（地板門下墜是正常的，所以下方容許量較大，但最終仍會被拉回）
	static func out_of_bounds(pos: Vector3, cell_size: Vector3) -> bool:
		return pos.y < -OOB_MARGIN or pos.y > cell_size.y + OOB_MARGIN \
			or pos.x < -OOB_MARGIN or pos.x > cell_size.x + OOB_MARGIN \
			or pos.z < -OOB_MARGIN or pos.z > cell_size.z + OOB_MARGIN

	static func inside_cell(pos: Vector3, cell_size: Vector3) -> bool:
		return pos.x >= 0.0 and pos.x <= cell_size.x and pos.z >= 0.0 and pos.z <= cell_size.z \
			and pos.y >= -0.05 and pos.y <= cell_size.y


## ====================================================================== 狀態
var model = null                   # SM.PalaceModel
var portal_system = null           # portal_system.gd 的實例
var camera: Camera3D = null
var head: Node3D = null

var current_cell_id := ""
var enabled := true                # false 時不處理輸入也不移動（例如開著設定面板）

# 可由設定檔調整
var move_speed := 3.0
var look_sensitivity := 0.0042     # 弧度 / 像素
var swap_sides := false
var invert_y := false
var joystick_radius := 110.0       # 像素
var gravity := 12.0
var jump_speed := 4.6
var acceleration := 28.0

# 給 HUD 讀取（畫搖桿圈圈用）
var joystick_active := false
var joystick_origin := Vector2.ZERO
var joystick_pos := Vector2.ZERO
var move_input := Vector2.ZERO     # 搖桿 + 鍵盤合併後的輸入（也可由測試直接設定）
var key_input := Vector2.ZERO

var _yaw := 0.0
var _pitch := 0.0
var _jump_queued := false
var _joy_touch := -1
var _look_touches: Dictionary = {}     # 觸控 index -> {start, last, t0, moved}
var _mouse_drag: Dictionary = {}
var _last_safe := Vector3.ZERO
var _safe_timer := 0.0
var _cam_offset := Vector3.ZERO       # 向上穿過天花板門後，鏡頭從門平面緩緩升到站立眼高


func _ready() -> void:
	collision_layer = PLAYER_LAYER_BIT
	collision_mask = 0
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(55.0)
	floor_snap_length = 0.35
	floor_stop_on_slope = true
	floor_constant_speed = true
	max_slides = 6
	if get_node_or_null("Body") == null:
		var cs := CollisionShape3D.new()
		cs.name = "Body"
		var cap := CapsuleShape3D.new()
		cap.radius = BODY_RADIUS
		cap.height = BODY_HEIGHT
		cs.shape = cap
		cs.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
		add_child(cs)
	if head == null:
		head = Node3D.new()
		head.name = "Head"
		head.position = Vector3(0.0, EYE_HEIGHT, 0.0)
		add_child(head)
		camera = Camera3D.new()
		camera.name = "Camera"
		camera.fov = 75.0
		camera.far = 200.0
		camera.current = true
		head.add_child(camera)
	process_priority = -10      # 早於 portal_system（100），讓它用同一幀最新的攝影機位置


## 綁定資料與傳送門系統。呼叫後再用 place_in_cell 放置玩家。
func setup(p_model, p_portal_system) -> void:
	model = p_model
	portal_system = p_portal_system
	if portal_system != null and camera != null:
		portal_system.setup(model, camera)


## 把玩家放進某間房（啟動、載入存檔、跳到搜尋結果時用）。該房間需已 activate_cell 並建好節點。
func place_in_cell(cell_id: String, pos: Vector3, yaw: float = 0.0, pitch: float = 0.0) -> void:
	current_cell_id = cell_id
	global_position = pos
	_yaw = yaw
	_pitch = Logic.clamp_pitch(pitch)
	velocity = Vector3.ZERO
	_last_safe = pos
	_apply_look()
	_sync_mask()
	if portal_system != null:
		portal_system.set_current_cell(cell_id)


func get_yaw() -> float:
	return _yaw


func get_pitch() -> float:
	return _pitch


func eye_position() -> Vector3:
	return camera.global_position if camera != null else global_position + Vector3(0.0, EYE_HEIGHT, 0.0)


## 開 / 關操作（開著面板時關掉，並放開所有卡住的觸控狀態）
func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		_joy_touch = -1
		joystick_active = false
		move_input = Vector2.ZERO
		_look_touches.clear()
		_mouse_drag = {}


func jump() -> void:
	_jump_queued = true


## 轉視角（像素）。HUD 的自訂按鈕群也可以呼叫。
func look_by(delta_px: Vector2) -> void:
	_yaw -= delta_px.x * look_sensitivity
	var dy := delta_px.y * look_sensitivity
	_pitch = Logic.clamp_pitch(_pitch - (-dy if invert_y else dy))
	_apply_look()


func _apply_look() -> void:
	global_transform = Transform3D(Basis.from_euler(Vector3(0.0, _yaw, 0.0)), global_position)
	if head != null:
		head.rotation = Vector3(_pitch, 0.0, 0.0)


# ---------------------------------------------------------------- 輸入

func _is_move_zone(pos: Vector2) -> bool:
	var w := get_viewport().get_visible_rect().size.x
	return (pos.x < w * 0.5) != swap_sides


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)
	elif event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		_on_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		jump()


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		if _is_move_zone(e.position):
			if _joy_touch == -1:
				_joy_touch = e.index
				joystick_active = true
				joystick_origin = e.position
				joystick_pos = e.position
		else:
			_look_touches[e.index] = {"start": e.position, "last": e.position, "t0": Time.get_ticks_msec(), "moved": 0.0}
	else:
		if e.index == _joy_touch:
			_joy_touch = -1
			joystick_active = false
			move_input = Vector2.ZERO
		elif _look_touches.has(e.index):
			var info: Dictionary = _look_touches[e.index]
			_look_touches.erase(e.index)
			var dur := float(Time.get_ticks_msec() - int(info["t0"])) / 1000.0
			if Logic.is_tap(dur, float(info["moved"])):
				_handle_tap(e.position)


func _on_drag(e: InputEventScreenDrag) -> void:
	if e.index == _joy_touch:
		joystick_pos = e.position
		# 手指拖出搖桿圈外時，讓圈心跟著走，之後反向操作不會卡住
		var off := joystick_pos - joystick_origin
		if off.length() > joystick_radius * 1.5:
			joystick_origin = joystick_pos - off.normalized() * joystick_radius * 1.5
		move_input = Logic.joystick_vector(joystick_origin, joystick_pos, joystick_radius)
	elif _look_touches.has(e.index):
		var info: Dictionary = _look_touches[e.index]
		info["moved"] = float(info["moved"]) + e.relative.length()
		info["last"] = e.position
		look_by(e.relative)


func _on_mouse_button(e: InputEventMouseButton) -> void:
	if e.button_index != MOUSE_BUTTON_LEFT and e.button_index != MOUSE_BUTTON_RIGHT:
		return
	if e.pressed:
		_mouse_drag = {"start": e.position, "t0": Time.get_ticks_msec(), "moved": 0.0}
	elif not _mouse_drag.is_empty():
		var dur := float(Time.get_ticks_msec() - int(_mouse_drag["t0"])) / 1000.0
		if Logic.is_tap(dur, float(_mouse_drag["moved"])):
			_handle_tap(e.position)
		_mouse_drag = {}


func _on_mouse_motion(e: InputEventMouseMotion) -> void:
	if _mouse_drag.is_empty():
		return
	_mouse_drag["moved"] = float(_mouse_drag["moved"]) + e.relative.length()
	look_by(e.relative)


func _poll_keys() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		v.y += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		v.x += 1.0
	return v


# ---------------------------------------------------------------- 點選 / 射線

func _handle_tap(screen_pos: Vector2) -> void:
	tapped.emit(screen_pos)
	var id := pick_node(screen_pos)
	if id != "":
		node_picked.emit(id)


func _current_cell():
	if model == null:
		return null
	return model.cells.get(current_cell_id)


## 由螢幕座標射線找記憶節點 id（沒點到回傳 ""）。
## 射線同時看「目前房間的牆 / 建材」（擋住視線）與所有房間的互動體；其他房間的互動體會被略過。
func pick_node(screen_pos: Vector2) -> String:
	var cell = _current_cell()
	if cell == null or camera == null:
		return ""
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * PICK_DISTANCE
	var space := get_world_3d().direct_space_state
	var excluded: Array[RID] = []
	for i in range(MAX_PICK_STEPS):
		var q := PhysicsRayQueryParameters3D.create(from, to, SM.PalaceModel.layer_bit(cell.physics_layer) | INTERACT_BIT)
		q.exclude = excluded
		q.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return ""
		var col: Object = hit["collider"]
		if col != null and col.has_meta("memory_node_id"):
			if str(col.get_meta("cell_id", "")) == current_cell_id:
				return str(col.get_meta("memory_node_id"))
			excluded.append(hit["rid"])    # 別間房的互動體：穿過去繼續找
			continue
		return ""                           # 先打到自己房間的牆 / 建材
	return ""


## 射線打到目前房間表面的位置與法線（放置記憶節點用）。回傳 {} 或 {position, normal}
func raycast_surface(screen_pos: Vector2) -> Dictionary:
	var cell = _current_cell()
	if cell == null or camera == null:
		return {}
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * PICK_DISTANCE
	var q := PhysicsRayQueryParameters3D.create(from, to, SM.PalaceModel.layer_bit(cell.physics_layer))
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {}
	return {"position": hit["position"], "normal": hit["normal"]}


# ---------------------------------------------------------------- 物理 / 穿門

func _sync_mask() -> void:
	var cell = _current_cell()
	collision_mask = SM.PalaceModel.layer_bit(cell.physics_layer) if cell != null else 0


func _process(delta: float) -> void:
	if head == null:
		return
	if _cam_offset.length_squared() > 1e-8:
		_cam_offset *= exp(-10.0 * delta)
		if _cam_offset.length_squared() < 1e-6:
			_cam_offset = Vector3.ZERO
	head.position = Vector3(0.0, EYE_HEIGHT, 0.0) + global_transform.basis.inverse() * _cam_offset


func _physics_process(delta: float) -> void:
	if model == null or not enabled or _current_cell() == null:
		return
	_sync_mask()
	key_input = _poll_keys()
	var input := move_input + key_input
	if input.length() > 1.0:
		input = input.normalized()
	var wish := Logic.wish_velocity(input, _yaw, move_speed)
	velocity.x = move_toward(velocity.x, wish.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, wish.z, acceleration * delta)
	if is_on_floor():
		if _jump_queued:
			velocity.y = jump_speed
	else:
		velocity.y -= gravity * delta
	_jump_queued = false

	var prev_eye := eye_position()
	move_and_slide()
	var eye := eye_position()

	if portal_system != null:
		var r: Dictionary = portal_system.try_teleport(prev_eye, eye)
		if r.get("ok", false):
			_apply_teleport(r)
			return

	var cell = _current_cell()
	_safe_timer += delta
	if _safe_timer >= 0.4 and is_on_floor() and Logic.inside_cell(global_position, cell.size):
		_safe_timer = 0.0
		_last_safe = global_position
	if Logic.out_of_bounds(global_position, cell.size):
		global_position = _last_safe
		velocity = Vector3.ZERO
		respawned.emit()


func _apply_teleport(r: Dictionary) -> void:
	var m: Transform3D = r["matrix"]
	var t: Dictionary = Logic.teleported(global_position, _yaw, m)
	_yaw = t["yaw"]
	var new_pos: Vector3 = t["pos"]
	var src = model.portals.get(str(r["portal_id"]))
	var dst = null
	if src != null:
		dst = model.portals.get(src.target_portal_id)
	var lifted := Vector3.ZERO
	if src != null and dst != null and Logic.is_upward(src, dst):
		lifted = Logic.climb_out_offset(new_pos, _yaw, dst)
		new_pos += lifted
		velocity = Vector3.ZERO
	else:
		velocity = m.basis * velocity
	global_position = new_pos
	_cam_offset = -lifted
	_apply_look()
	current_cell_id = str(r["target_cell_id"])
	_last_safe = global_position
	_sync_mask()
	cell_entered.emit(current_cell_id, str(r["portal_id"]))
