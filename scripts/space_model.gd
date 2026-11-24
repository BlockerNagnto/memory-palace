extends RefCounted
## space_model.gd — 記憶宮殿的純邏輯資料模型（不依賴場景樹 / GPU，可在 godot --headless 下測試）
##
## 座標約定：每個 Cell 的局部座標即世界座標（各 Cell 靠視覺層 / 物理層隔離，彼此可以重疊）。
## Cell 佔據 x∈[0,size.x]、y∈[0,size.y]、z∈[0,size.z]。
##
## 六個傳送門平面（wall_index），法線皆指向房內：
##   0 = -X 牆(x=0)      法線 +X    平面座標 (u,v) = (z, y)
##   1 = +X 牆(x=size.x) 法線 -X    (u,v) = (z, y)
##   2 = -Z 牆(z=0)      法線 +Z    (u,v) = (x, y)
##   3 = +Z 牆(z=size.z) 法線 -Z    (u,v) = (x, y)
##   4 = 地板(y=0)       法線 +Y    (u,v) = (x, z)
##   5 = 天花板(y=size.y) 法線 -Y   (u,v) = (x, z)
## 傳送門的 size = (沿 u 的寬, 沿 v 的高/長)，local_pos = 門洞中心。
##
## 用法（不依賴 class_name，避免 CI 上全域類別快取尚未建立）：
##   const SM = preload("res://scripts/space_model.gd")
##   var m = SM.PalaceModel.new()


## 序列化輔助：Vector / Array 與 JSON 友善陣列互轉
class Ser:
	static func v3(v: Vector3) -> Array:
		return [v.x, v.y, v.z]

	static func to_v3(a: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
		if a is Array and a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		return fallback

	static func v2(v: Vector2) -> Array:
		return [v.x, v.y]

	static func to_v2(a: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
		if a is Array and a.size() >= 2:
			return Vector2(float(a[0]), float(a[1]))
		return fallback

	static func to_arr(a: Variant) -> Array:
		if a is Array:
			return (a as Array).duplicate()
		return []

	static func str_arr(p: PackedStringArray) -> Array:
		var out: Array = []
		for s in p:
			out.append(s)
		return out

	static func to_str_arr(a: Variant) -> PackedStringArray:
		var out := PackedStringArray()
		if a is Array:
			for s in a:
				out.append(str(s))
		return out

	static func float_arr(p: PackedFloat32Array) -> Array:
		var out: Array = []
		for f in p:
			out.append(f)
		return out

	static func to_floats(a: Variant) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		if a is Array:
			for f in a:
				out.append(float(f))
		return out

	static func to_id_list(a: Variant) -> Array:
		var out: Array = []
		if a is Array:
			for s in a:
				out.append(str(s))
		return out


## 長方體房間
class Cell extends RefCounted:
	var id := ""
	var name := ""
	var theme_id := "default"
	var size := Vector3(6, 3, 6)
	var render_layer := 0   # 1~20；0 = 未分配（僅執行期有效，不跨存檔）
	var physics_layer := 0  # 1~20；0 = 未分配（21~32 保留給玩家 / 觸發器 / 射線）
	var structures: Array = []   # Structure id（斜坡 / 平台 / 欄桿）
	var portals: Array = []      # Portal id
	var semantic_tags := PackedStringArray()     # Phase 3 預留
	var summary_vector := PackedFloat32Array()   # Phase 3 預留

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"name": name,
			"themeId": theme_id,
			"size": Ser.v3(size),
			"renderLayer": render_layer,
			"physicsLayer": physics_layer,
			"structures": structures.duplicate(),
			"portals": portals.duplicate(),
			"semantic_tags": Ser.str_arr(semantic_tags),
			"summary_vector": Ser.float_arr(summary_vector),
		}

	static func from_dict(d: Dictionary) -> Cell:
		var c := Cell.new()
		c.id = str(d.get("id", ""))
		c.name = str(d.get("name", ""))
		c.theme_id = str(d.get("themeId", "default"))
		c.size = Ser.to_v3(d.get("size"), Vector3(6, 3, 6))
		c.render_layer = int(d.get("renderLayer", 0))
		c.physics_layer = int(d.get("physicsLayer", 0))
		c.structures = Ser.to_id_list(d.get("structures"))
		c.portals = Ser.to_id_list(d.get("portals"))
		c.semantic_tags = Ser.to_str_arr(d.get("semantic_tags"))
		c.summary_vector = Ser.to_floats(d.get("summary_vector"))
		return c


## 統一建材基底。所有建材都「不阻擋」Split & Stretch 切割線，規則由 span / shift / extend 三個方法表達：
##   span(axis)        建材沿切割軸向的占據範圍 (lo, hi)
##   shift(axis, d)    整體平移
##   extend(axis, d)   保持 lo 不動、hi 端延伸 d（切割線穿過建材內部時使用）
## axis 以 0 = X、1 = Z 表示（與 PalaceModel.AXIS_X / AXIS_Z 相同）。
class Structure extends RefCounted:
	const KIND_RAMP := "ramp"
	const KIND_PLATFORM := "platform"
	const KIND_RAILING := "railing"
	const AXIS_X := 0
	const AXIS_Z := 1

	var id := ""
	var cell_id := ""
	var kind := ""
	var pos := Vector3.ZERO

	static func comp(v: Vector3, axis: int) -> float:
		return v.x if axis == AXIS_X else v.z

	static func bump(v: Vector3, axis: int, d: float) -> Vector3:
		if axis == AXIS_X:
			v.x += d
		else:
			v.z += d
		return v

	## 把任意方向吸附成 ±X 或 ±Z 的單位向量
	static func snap_dir(d: Vector3) -> Vector3:
		if absf(d.x) >= absf(d.z):
			return Vector3(-1.0 if d.x < 0.0 else 1.0, 0.0, 0.0)
		return Vector3(0.0, 0.0, -1.0 if d.z < 0.0 else 1.0)

	func span(axis: int) -> Vector2:
		var c := comp(pos, axis)
		return Vector2(c, c)

	func shift(axis: int, delta: float) -> void:
		pos = bump(pos, axis, delta)

	func extend(_axis: int, _delta: float) -> void:
		pass

	func to_dict() -> Dictionary:
		return {}


## 方正斜坡（楔形）。pos = 起點底邊中心；direction = 軸向上坡方向（吸附為 ±X / ±Z）。
class Ramp extends Structure:
	var direction := Vector3.RIGHT
	var width := 1.0     # 預設 1 m（對齊 1 m 的水平傳送門）
	var length := 2.0
	var height := 1.0

	func _init() -> void:
		kind = KIND_RAMP

	func horizontal_dir() -> Vector3:
		return snap_dir(direction)

	func along_axis() -> int:
		return AXIS_X if absf(horizontal_dir().x) > 0.5 else AXIS_Z

	func along_sign() -> float:
		var d := horizontal_dir()
		return d.x + d.z

	func end_pos() -> Vector3:
		return pos + horizontal_dir() * length

	func slope_angle_deg() -> float:
		return rad_to_deg(atan2(height, length))

	func span(axis: int) -> Vector2:
		var c := comp(pos, axis)
		if axis == along_axis():
			var e := c + along_sign() * length
			return Vector2(minf(c, e), maxf(c, e))
		return Vector2(c - width * 0.5, c + width * 0.5)

	## 沿上坡方向切開：水平跨度 length 增加 delta，height 不變（坡度變緩）。
	## 橫向（寬度方向）被切開：width 增加 delta。
	func extend(axis: int, delta: float) -> void:
		if axis == along_axis():
			length += delta
			if along_sign() < 0.0:
				pos = bump(pos, axis, delta)   # 起點在 hi 端，hi 端要跟著移動
		else:
			width += delta
			pos = bump(pos, axis, delta * 0.5)

	## 供 ConvexPolygonShape3D 與視覺網格共用的 6 個頂點（單純楔形，無鋸齒台階）。
	func convex_points() -> PackedVector3Array:
		var dir := horizontal_dir()
		var side := Vector3.UP.cross(dir) * (width * 0.5)
		var e := pos + dir * length
		var up := Vector3.UP * height
		return PackedVector3Array([
			pos - side, pos + side,
			e - side, e + side,
			e - side + up, e + side + up,
		])

	func to_dict() -> Dictionary:
		return {
			"kind": kind,
			"id": id,
			"cellId": cell_id,
			"pos": Ser.v3(pos),
			"direction": Ser.v3(horizontal_dir()),
			"width": width,
			"length": length,
			"height": height,
		}

	static func from_dict(d: Dictionary) -> Ramp:
		var r := Ramp.new()
		r.id = str(d.get("id", ""))
		r.cell_id = str(d.get("cellId", ""))
		r.pos = Ser.to_v3(d.get("pos"))
		r.direction = snap_dir(Ser.to_v3(d.get("direction"), Vector3.RIGHT))
		r.width = float(d.get("width", 1.0))
		r.length = float(d.get("length", 2.0))
		r.height = float(d.get("height", 1.0))
		return r


## 二樓地板平台。pos = (x 最小值, 頂面高度 y, z 最小值)；size = (x 方向長, z 方向長)。
class Platform extends Structure:
	var size := Vector2(2.0, 2.0)
	var thickness := 0.2

	func _init() -> void:
		kind = KIND_PLATFORM

	func span(axis: int) -> Vector2:
		var lo := comp(pos, axis)
		return Vector2(lo, lo + (size.x if axis == AXIS_X else size.y))

	func extend(axis: int, delta: float) -> void:
		if axis == AXIS_X:
			size.x += delta
		else:
			size.y += delta

	func to_dict() -> Dictionary:
		return {
			"kind": kind,
			"id": id,
			"cellId": cell_id,
			"pos": Ser.v3(pos),
			"size": Ser.v2(size),
			"thickness": thickness,
		}

	static func from_dict(d: Dictionary) -> Platform:
		var p := Platform.new()
		p.id = str(d.get("id", ""))
		p.cell_id = str(d.get("cellId", ""))
		p.pos = Ser.to_v3(d.get("pos"))
		p.size = Ser.to_v2(d.get("size"), Vector2(2, 2))
		p.thickness = float(d.get("thickness", 0.2))
		return p


## 欄桿（直線段，沿 ±X 或 ±Z）。pos = 起點（底部）；direction = 延伸方向。
class Railing extends Structure:
	var direction := Vector3.RIGHT
	var length := 2.0
	var height := 1.0

	func _init() -> void:
		kind = KIND_RAILING

	func horizontal_dir() -> Vector3:
		return snap_dir(direction)

	func along_axis() -> int:
		return AXIS_X if absf(horizontal_dir().x) > 0.5 else AXIS_Z

	func along_sign() -> float:
		var d := horizontal_dir()
		return d.x + d.z

	func end_pos() -> Vector3:
		return pos + horizontal_dir() * length

	## 垂直於切割軸的欄桿厚度視為 0（一個點），只會整體不動或整體平移。
	func span(axis: int) -> Vector2:
		var c := comp(pos, axis)
		if axis == along_axis():
			var e := c + along_sign() * length
			return Vector2(minf(c, e), maxf(c, e))
		return Vector2(c, c)

	func extend(axis: int, delta: float) -> void:
		if axis != along_axis():
			return
		length += delta
		if along_sign() < 0.0:
			pos = bump(pos, axis, delta)

	func to_dict() -> Dictionary:
		return {
			"kind": kind,
			"id": id,
			"cellId": cell_id,
			"pos": Ser.v3(pos),
			"direction": Ser.v3(horizontal_dir()),
			"length": length,
			"height": height,
		}

	static func from_dict(d: Dictionary) -> Railing:
		var r := Railing.new()
		r.id = str(d.get("id", ""))
		r.cell_id = str(d.get("cellId", ""))
		r.pos = Ser.to_v3(d.get("pos"))
		r.direction = snap_dir(Ser.to_v3(d.get("direction"), Vector3.RIGHT))
		r.length = float(d.get("length", 2.0))
		r.height = float(d.get("height", 1.0))
		return r


## 傳送門框。local_pos = 門洞中心；normal = 指向房內；frame 的 +Z 軸 = normal。
class Portal extends RefCounted:
	var id := ""
	var cell_id := ""
	var wall_index := 0
	var local_pos := Vector3.ZERO
	var normal := Vector3.RIGHT
	var size := Vector2(1.2, 2.2)
	var is_full_wall := false
	var target_portal_id := ""
	var is_bidirectional := false

	func is_horizontal() -> bool:
		return absf(normal.y) > 0.5

	func frame() -> Transform3D:
		var z := normal.normalized()
		var x := Vector3.UP.cross(z)
		if x.length_squared() < 1e-8:
			x = Vector3.RIGHT   # 水平開口：x 軸固定為世界 +X
		x = x.normalized()
		var y := z.cross(x)
		return Transform3D(Basis(x, y, z), local_pos)

	## 穿過 src 後出現在 dst 的變換矩陣：M = F_dst · R · F_src⁻¹
	## 垂直牆面門：R = 繞門框 Y 軸轉 180°（穿牆而過，方向連續）。
	## 水平開口（地板↔天花板）：R = 繞門框 X 軸轉 180°，結果是純平移，上方向與水平朝向都不變。
	## 兩種旋轉都用精確整數矩陣表示，避免 sin(π) 的浮點誤差。
	static func teleport_between(src: Portal, dst: Portal) -> Transform3D:
		var flip := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)), Vector3.ZERO)
		if src.is_horizontal() and dst.is_horizontal():
			flip = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, -1)), Vector3.ZERO)
		return dst.frame() * flip * src.frame().affine_inverse()

	## ‖A − B‖（Frobenius，3x4 仿射矩陣）
	static func transform_distance(a: Transform3D, b: Transform3D) -> float:
		var s := 0.0
		s += (a.basis.x - b.basis.x).length_squared()
		s += (a.basis.y - b.basis.y).length_squared()
		s += (a.basis.z - b.basis.z).length_squared()
		s += (a.origin - b.origin).length_squared()
		return sqrt(s)

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"cellId": cell_id,
			"wallIndex": wall_index,
			"localPos": Ser.v3(local_pos),
			"normal": Ser.v3(normal),
			"size": Ser.v2(size),
			"isFullWall": is_full_wall,
			"targetPortalId": target_portal_id,
			"isBidirectional": is_bidirectional,
		}

	static func from_dict(d: Dictionary) -> Portal:
		var p := Portal.new()
		p.id = str(d.get("id", ""))
		p.cell_id = str(d.get("cellId", ""))
		p.wall_index = int(d.get("wallIndex", 0))
		p.local_pos = Ser.to_v3(d.get("localPos"))
		p.normal = Ser.to_v3(d.get("normal"), Vector3.RIGHT)
		p.size = Ser.to_v2(d.get("size"), Vector2(1.2, 2.2))
		p.is_full_wall = bool(d.get("isFullWall", false))
		p.target_portal_id = str(d.get("targetPortalId", ""))
		p.is_bidirectional = bool(d.get("isBidirectional", false))
		return p


## 記憶物件
class MemoryNode extends RefCounted:
	const PROMPT_MAX_CHARS := 15

	var id := ""
	var cell_id := ""
	var container_slot_id := ""   # Phase 2 置物櫃預留
	var asset_hash := ""
	var asset_type := ""          # "image" | "model" | ""（線框佔位符）
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO       # 歐拉角（弧度）
	var scale := Vector3.ONE
	var prompt15 := ""
	var detail_note := ""
	var timestamp := 0
	var is_priority := false
	var semantic_tags := PackedStringArray()

	func set_prompt(text: String) -> void:
		prompt15 = text.substr(0, PROMPT_MAX_CHARS)

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"cellId": cell_id,
			"containerSlotId": container_slot_id,
			"assetHash": asset_hash,
			"assetType": asset_type,
			"pos": Ser.v3(pos),
			"rot": Ser.v3(rot),
			"scale": Ser.v3(scale),
			"prompt15": prompt15,
			"detailNote": detail_note,
			"timestamp": timestamp,
			"isPriority": is_priority,
			"semantic_tags": Ser.str_arr(semantic_tags),
		}

	static func from_dict(d: Dictionary) -> MemoryNode:
		var n := MemoryNode.new()
		n.id = str(d.get("id", ""))
		n.cell_id = str(d.get("cellId", ""))
		n.container_slot_id = str(d.get("containerSlotId", ""))
		n.asset_hash = str(d.get("assetHash", ""))
		n.asset_type = str(d.get("assetType", ""))
		n.pos = Ser.to_v3(d.get("pos"))
		n.rot = Ser.to_v3(d.get("rot"))
		n.scale = Ser.to_v3(d.get("scale"), Vector3.ONE)
		n.set_prompt(str(d.get("prompt15", "")))
		n.detail_note = str(d.get("detailNote", ""))
		n.timestamp = int(d.get("timestamp", 0))
		n.is_priority = bool(d.get("isPriority", false))
		n.semantic_tags = Ser.to_str_arr(d.get("semantic_tags"))
		return n


## 時間車廂（Phase 3 預留：只有資料結構與序列化，無視覺與行為）
class TimeCarriage extends RefCounted:
	var date_str := ""
	var wall_color := Color(0.8, 0.8, 0.8)
	var seat_anchors: Array = []     # Vector3
	var priority_seats: Array = []   # int（seat_anchors 索引）

	func to_dict() -> Dictionary:
		var anchors: Array = []
		for a in seat_anchors:
			anchors.append(Ser.v3(a))
		return {
			"dateStr": date_str,
			"wallColor": wall_color.to_html(false),
			"seatAnchors": anchors,
			"prioritySeats": priority_seats.duplicate(),
		}

	static func from_dict(d: Dictionary) -> TimeCarriage:
		var t := TimeCarriage.new()
		t.date_str = str(d.get("dateStr", ""))
		t.wall_color = Color.html(str(d.get("wallColor", "cccccc")))
		for a in Ser.to_arr(d.get("seatAnchors")):
			t.seat_anchors.append(Ser.to_v3(a))
		for i in Ser.to_arr(d.get("prioritySeats")):
			t.priority_seats.append(int(i))
		return t


## 整個宮殿：容器、ID、層位分配、Split & Stretch、傳送門放置 / 縮放 / 平移 / 配對、序列化
class PalaceModel extends RefCounted:
	const FORMAT_VERSION := 2
	const RENDER_SLOTS := 20            # 視覺層 1~20 給房間（物理層同號）
	const PLAYER_PHYSICS_LAYER := 21    # 物理層 21~32 保留給玩家 / 觸發器 / 射線
	const PORTAL_TRIGGER_PHYSICS_LAYER := 22
	const INTERACT_RAY_PHYSICS_LAYER := 23
	const AXIS_X := 0
	const AXIS_Z := 1
	const EPS := 1e-5
	const MIN_DIM := 1.0
	const MIN_PORTAL_DIM := 0.3
	const DEFAULT_WALL_PORTAL_SIZE := Vector2(1.2, 2.2)
	const DEFAULT_HORIZONTAL_PORTAL_SIZE := Vector2(1.0, 1.0)
	const DEFAULT_RAMP_WIDTH := 1.0

	var cells := {}
	var structures := {}   # id -> Ramp / Platform / Railing
	var portals := {}
	var memory_nodes := {}
	var carriages := {}    # Phase 3 預留：dateStr -> TimeCarriage
	var _counter := 0
	var _slot_owner: Array = []

	func _init() -> void:
		_slot_owner.resize(RENDER_SLOTS)
		_slot_owner.fill("")

	func next_id(prefix: String) -> String:
		_counter += 1
		return "%s_%04d" % [prefix, _counter]

	# ---------------------------------------------------------------- 平面幾何（靜態）

	static func wall_normal(wall_index: int) -> Vector3:
		match wall_index:
			0:
				return Vector3(1, 0, 0)
			1:
				return Vector3(-1, 0, 0)
			2:
				return Vector3(0, 0, 1)
			3:
				return Vector3(0, 0, -1)
			4:
				return Vector3(0, 1, 0)
			_:
				return Vector3(0, -1, 0)

	static func is_horizontal_wall(wall_index: int) -> bool:
		return wall_index >= 4

	static func default_portal_size(wall_index: int) -> Vector2:
		return DEFAULT_HORIZONTAL_PORTAL_SIZE if wall_index >= 4 else DEFAULT_WALL_PORTAL_SIZE

	## 該平面的 (u 長度, v 長度)
	static func plane_dims(size: Vector3, wall_index: int) -> Vector2:
		match wall_index:
			0, 1:
				return Vector2(size.z, size.y)
			2, 3:
				return Vector2(size.x, size.y)
			_:
				return Vector2(size.x, size.z)

	## 平面座標 (u,v) → 房間座標
	static func plane_point(size: Vector3, wall_index: int, u: float, v: float) -> Vector3:
		match wall_index:
			0:
				return Vector3(0.0, v, u)
			1:
				return Vector3(size.x, v, u)
			2:
				return Vector3(u, v, 0.0)
			3:
				return Vector3(u, v, size.z)
			4:
				return Vector3(u, 0.0, v)
			_:
				return Vector3(u, size.y, v)

	## 房間座標 → 平面座標 (u,v)
	static func plane_uv(wall_index: int, p: Vector3) -> Vector2:
		match wall_index:
			0, 1:
				return Vector2(p.z, p.y)
			2, 3:
				return Vector2(p.x, p.y)
			_:
				return Vector2(p.x, p.z)

	## 傳送門在其平面上占據的矩形（u0, v0, 寬, 高）
	static func portal_rect(p: Portal) -> Rect2:
		var c := plane_uv(p.wall_index, p.local_pos)
		return Rect2(c - p.size * 0.5, p.size)

	static func _rects_overlap(a: Rect2, b: Rect2) -> bool:
		return a.position.x < b.end.x - EPS and a.end.x > b.position.x + EPS \
			and a.position.y < b.end.y - EPS and a.end.y > b.position.y + EPS

	static func _point_strictly_inside(r: Rect2, p: Vector2) -> bool:
		return p.x > r.position.x + EPS and p.x < r.end.x - EPS \
			and p.y > r.position.y + EPS and p.y < r.end.y - EPS

	## 圖層索引（1 起算）轉 cull_mask / collision 位元；0 → 0
	static func layer_bit(layer: int) -> int:
		if layer <= 0:
			return 0
		return 1 << (layer - 1)

	static func _fail(error: String) -> Dictionary:
		return {"ok": false, "error": error}

	# ---------------------------------------------------------------- 建立：房間 / 建材

	func create_cell(cell_name: String, theme_id: String, size: Vector3) -> Cell:
		var c := Cell.new()
		c.id = next_id("cell")
		c.name = cell_name
		c.theme_id = theme_id
		c.size = Vector3(maxf(size.x, MIN_DIM), maxf(size.y, MIN_DIM), maxf(size.z, MIN_DIM))
		cells[c.id] = c
		return c

	func _register_structure(s: Structure, c: Cell) -> void:
		structures[s.id] = s
		c.structures.append(s.id)

	func add_ramp(cell_id: String, pos: Vector3, direction: Vector3, width: float = DEFAULT_RAMP_WIDTH, length: float = 2.0, height: float = 1.0) -> Ramp:
		var c: Cell = cells.get(cell_id)
		if c == null:
			return null
		var r := Ramp.new()
		r.id = next_id("ramp")
		r.cell_id = cell_id
		r.pos = pos
		r.direction = Structure.snap_dir(direction)
		r.width = maxf(width, 0.1)
		r.length = maxf(length, 0.1)
		r.height = maxf(height, 0.01)
		_register_structure(r, c)
		return r

	func add_platform(cell_id: String, pos: Vector3, size: Vector2, thickness: float = 0.2) -> Platform:
		var c: Cell = cells.get(cell_id)
		if c == null:
			return null
		var p := Platform.new()
		p.id = next_id("plat")
		p.cell_id = cell_id
		p.pos = pos
		p.size = Vector2(maxf(size.x, 0.1), maxf(size.y, 0.1))
		p.thickness = maxf(thickness, 0.02)
		_register_structure(p, c)
		return p

	func add_railing(cell_id: String, pos: Vector3, direction: Vector3, length: float, height: float = 1.0) -> Railing:
		var c: Cell = cells.get(cell_id)
		if c == null:
			return null
		var r := Railing.new()
		r.id = next_id("rail")
		r.cell_id = cell_id
		r.pos = pos
		r.direction = Structure.snap_dir(direction)
		r.length = maxf(length, 0.1)
		r.height = maxf(height, 0.1)
		_register_structure(r, c)
		return r

	func add_memory_node(cell_id: String, asset_hash: String, asset_type: String, pos: Vector3) -> MemoryNode:
		if not cells.has(cell_id):
			return null
		var n := MemoryNode.new()
		n.id = next_id("node")
		n.cell_id = cell_id
		n.asset_hash = asset_hash
		n.asset_type = asset_type
		n.pos = pos
		n.timestamp = int(Time.get_unix_time_from_system())
		memory_nodes[n.id] = n
		return n

	func remove_memory_node(node_id: String) -> bool:
		return memory_nodes.erase(node_id)

	## 刪除一扇門（同時解除配對、從所屬房間的清單移除）
	func delete_portal(portal_id: String) -> bool:
		var p: Portal = portals.get(portal_id)
		if p == null:
			return false
		unlink_portal(portal_id)
		# 別的門若單向指向它，也一併清掉，避免留下懸空目標
		for oid in portals:
			var o: Portal = portals[oid]
			if o.target_portal_id == portal_id:
				o.target_portal_id = ""
				o.is_bidirectional = false
		var c: Cell = cells.get(p.cell_id)
		if c != null:
			c.portals.erase(portal_id)
		portals.erase(portal_id)
		return true

	## 刪除房間（連同其建材、記憶物件與未配對的門）。房間仍有已配對的門時拒絕，需先解除配對 / 刪門。
	func remove_cell(cell_id: String) -> Dictionary:
		var c: Cell = cells.get(cell_id)
		if c == null:
			return _fail("cell_not_found")
		for pid in c.portals:
			var p: Portal = portals.get(pid)
			if p == null:
				continue
			if p.target_portal_id != "":
				return _fail("cell_has_links")
			for oid in portals:
				if portals[oid].target_portal_id == pid:
					return _fail("cell_has_links")
		for pid in c.portals.duplicate():
			portals.erase(pid)
		for sid in c.structures.duplicate():
			structures.erase(sid)
		for nid in memory_nodes.keys():
			if memory_nodes[nid].cell_id == cell_id:
				memory_nodes.erase(nid)
		release_cell(cell_id)
		cells.erase(cell_id)
		return {"ok": true}

	# ---------------------------------------------------------------- 傳送門：放置 / 縮放 / 平移

	func _plane_rects(c: Cell, wall_index: int, exclude_id: String) -> Array:
		var out: Array = []
		for pid in c.portals:
			var o: Portal = portals.get(pid)
			if o != null and o.wall_index == wall_index and o.id != exclude_id:
				out.append(portal_rect(o))
		return out

	## 沿單一軸向求中心對稱的最大半長。axis 0 = u、1 = v；
	## other_lo / other_hi 是另一軸向目前占據的範圍，只有在該範圍內重疊的傳送門才會擋住這個方向。
	func _limit_axis(center: float, length: float, want_half: float, others: Array, axis: int, other_lo: float, other_hi: float) -> Dictionary:
		var avail_lo := center
		var avail_hi := length - center
		var reason_lo := "wall"
		var reason_hi := "wall"
		for r: Rect2 in others:
			var o_lo: float = r.position.y if axis == 0 else r.position.x
			var o_hi: float = r.end.y if axis == 0 else r.end.x
			if o_hi <= other_lo + EPS or o_lo >= other_hi - EPS:
				continue
			var a_lo: float = r.position.x if axis == 0 else r.position.y
			var a_hi: float = r.end.x if axis == 0 else r.end.y
			if a_lo >= center - EPS:
				if a_lo - center < avail_hi:
					avail_hi = a_lo - center
					reason_hi = "portal"
			elif a_hi <= center + EPS:
				if center - a_hi < avail_lo:
					avail_lo = center - a_hi
					reason_lo = "portal"
			# 其餘情況：另一個門在本軸向上包住中心 → 交給另一軸向去避開
		var half := minf(want_half, minf(avail_lo, avail_hi))
		var reason := ""
		if half < want_half - EPS:
			reason = reason_lo if avail_lo <= avail_hi else reason_hi
		return {"half": maxf(half, 0.0), "reason": reason}

	## 以 center（平面座標）為錨點，求在不撞牆角 / 其他門的前提下，最接近 req 的對稱尺寸。
	## 先處理寬（u）再處理高（v）；任一方向被擋，該方向就只擴張到先碰到的那一端。
	func _fit_rect(c: Cell, wall_index: int, center: Vector2, req: Vector2, exclude_id: String) -> Dictionary:
		var dims := plane_dims(c.size, wall_index)
		var others := _plane_rects(c, wall_index, exclude_id)
		for r: Rect2 in others:
			if _point_strictly_inside(r, center):
				return _fail("overlaps_portal")
		var res_u := _limit_axis(center.x, dims.x, req.x * 0.5, others, 0, center.y - req.y * 0.5, center.y + req.y * 0.5)
		var uh: float = res_u["half"]
		var res_v := _limit_axis(center.y, dims.y, req.y * 0.5, others, 1, center.x - uh, center.x + uh)
		var vh: float = res_v["half"]
		if uh * 2.0 < MIN_PORTAL_DIM - EPS or vh * 2.0 < MIN_PORTAL_DIM - EPS:
			return _fail("no_room")
		return {
			"ok": true,
			"size": Vector2(uh * 2.0, vh * 2.0),
			"limited_u": res_u["reason"] != "",
			"limited_v": res_v["reason"] != "",
			"reason_u": res_u["reason"],
			"reason_v": res_v["reason"],
		}

	## 放置傳送門。local_pos 只用到平面座標（法線方向的分量會被吸附到該平面）。
	## size 為 Vector2.ZERO 時採預設：牆面 1.2×2.2、水平開口 1×1。
	## snap_floor：牆面門貼地（門底在地板上，中心高度 = 高度/2）。
	func place_portal(cell_id: String, wall_index: int, local_pos: Vector3, size: Vector2 = Vector2.ZERO, is_full_wall: bool = false, snap_floor: bool = false) -> Dictionary:
		var c: Cell = cells.get(cell_id)
		if c == null:
			return _fail("cell_not_found")
		if wall_index < 0 or wall_index > 5:
			return _fail("bad_wall")
		var p := Portal.new()
		p.cell_id = cell_id
		p.wall_index = wall_index
		p.normal = wall_normal(wall_index)
		p.is_full_wall = is_full_wall
		if is_full_wall:
			if not _plane_rects(c, wall_index, "").is_empty():
				return _fail("plane_not_empty")
			p.id = next_id("portal")
			portals[p.id] = p
			c.portals.append(p.id)
			refit_full_wall(p)
			return {"ok": true, "portal": p, "limited_u": false, "limited_v": false, "reason_u": "", "reason_v": ""}

		var req := size
		if req.x <= 0.0 or req.y <= 0.0:
			req = default_portal_size(wall_index)
		req = Vector2(maxf(req.x, MIN_PORTAL_DIM), maxf(req.y, MIN_PORTAL_DIM))
		var dims := plane_dims(c.size, wall_index)
		var uv := plane_uv(wall_index, local_pos)
		if uv.x <= EPS or uv.x >= dims.x - EPS or uv.y <= EPS or uv.y >= dims.y - EPS:
			return _fail("out_of_wall")
		if snap_floor and wall_index < 4:
			uv.y = minf(req.y, dims.y) * 0.5
		var fit := _fit_rect(c, wall_index, uv, req, "")
		if not fit["ok"]:
			return fit
		p.id = next_id("portal")
		p.size = fit["size"]
		p.local_pos = plane_point(c.size, wall_index, uv.x, uv.y)
		portals[p.id] = p
		c.portals.append(p.id)
		fit["portal"] = p
		return fit

	## 相容用：失敗時回傳 null
	func add_portal(cell_id: String, wall_index: int, local_pos: Vector3, size: Vector2, is_full_wall: bool) -> Portal:
		var res := place_portal(cell_id, wall_index, local_pos, size, is_full_wall)
		var p: Variant = res.get("portal")
		return p

	## 以中心為錨點對稱調整尺寸；兩端撞到牆角或其他門時，該方向只擴張到先碰到的那一端。
	func resize_portal(portal_id: String, new_size: Vector2) -> Dictionary:
		var p: Portal = portals.get(portal_id)
		if p == null:
			return _fail("portal_not_found")
		if p.is_full_wall:
			return _fail("full_wall")
		var c: Cell = cells.get(p.cell_id)
		if c == null:
			return _fail("cell_not_found")
		var req := Vector2(maxf(new_size.x, MIN_PORTAL_DIM), maxf(new_size.y, MIN_PORTAL_DIM))
		var fit := _fit_rect(c, p.wall_index, plane_uv(p.wall_index, p.local_pos), req, p.id)
		if not fit["ok"]:
			return fit
		p.size = fit["size"]
		return fit

	## 平移傳送門（尺寸不變）。超出牆面時滑到邊界並標記 limited；與其他門重疊則拒絕且不改動。
	func move_portal(portal_id: String, new_pos: Vector3) -> Dictionary:
		var p: Portal = portals.get(portal_id)
		if p == null:
			return _fail("portal_not_found")
		if p.is_full_wall:
			return _fail("full_wall")
		var c: Cell = cells.get(p.cell_id)
		if c == null:
			return _fail("cell_not_found")
		var dims := plane_dims(c.size, p.wall_index)
		var half := p.size * 0.5
		var want := plane_uv(p.wall_index, new_pos)
		var target := Vector2(clampf(want.x, half.x, dims.x - half.x), clampf(want.y, half.y, dims.y - half.y))
		var rect := Rect2(target - half, p.size)
		for r: Rect2 in _plane_rects(c, p.wall_index, p.id):
			if _rects_overlap(rect, r):
				return _fail("overlaps_portal")
		p.local_pos = plane_point(c.size, p.wall_index, target.x, target.y)
		return {"ok": true, "limited": not target.is_equal_approx(want), "center": p.local_pos}

	## 滿版無框門：寬高自動貼合整面（牆 / 地板 / 天花板）
	func refit_full_wall(p: Portal) -> void:
		var c: Cell = cells.get(p.cell_id)
		if c == null:
			return
		var dims := plane_dims(c.size, p.wall_index)
		p.size = dims
		p.local_pos = plane_point(c.size, p.wall_index, dims.x * 0.5, dims.y * 0.5)

	# ---------------------------------------------------------------- Split & Stretch

	static func _coord(v: Vector3, axis: int) -> float:
		return v.x if axis == AXIS_X else v.z

	## 無損推擠拉長：房間沿 axis 增加 delta。
	##  建材（斜坡 / 平台 / 欄桿）：整體在切割線負側 → 不動；整體在正側（含壓線）→ 整體平移 delta；
	##    被切割線穿過內部 → 沿該軸向延伸 delta（平台與欄桿變長，斜坡水平跨度變長、高度不變）。
	##  傳送門（含六向）：以中心點所在側決定不動或整體平移 delta；滿版門依新牆面重新貼合。
	##  記憶物件：座標在正側（含壓線）則平移。
	func split_and_stretch(cell_id: String, axis: int, cut: float, delta: float) -> Dictionary:
		var cell: Cell = cells.get(cell_id)
		if cell == null:
			return _fail("cell_not_found")
		if axis != AXIS_X and axis != AXIS_Z:
			return _fail("bad_axis")
		if delta <= EPS:
			return _fail("delta_must_be_positive")
		var length: float = cell.size.x if axis == AXIS_X else cell.size.z
		if cut <= EPS or cut > length + EPS:
			return _fail("cut_out_of_range")
		var line: float = minf(cut, length)
		var offset := Vector3(delta, 0.0, 0.0) if axis == AXIS_X else Vector3(0.0, 0.0, delta)
		var report := {"structures_shifted": 0, "structures_stretched": 0, "portals": 0, "memory_nodes": 0}

		for sid in cell.structures:
			var s: Structure = structures.get(sid)
			if s == null:
				continue
			var sp := s.span(axis)
			if sp.x < line - EPS and sp.y > line + EPS:
				s.extend(axis, delta)
				report["structures_stretched"] += 1
			elif sp.x >= line - EPS:
				s.shift(axis, delta)
				report["structures_shifted"] += 1

		for pid in cell.portals:
			var p: Portal = portals.get(pid)
			if p != null and not p.is_full_wall and _coord(p.local_pos, axis) >= line - EPS:
				p.local_pos += offset
				report["portals"] += 1

		for nid in memory_nodes:
			var n: MemoryNode = memory_nodes[nid]
			if n.cell_id == cell_id and _coord(n.pos, axis) >= line - EPS:
				n.pos += offset
				report["memory_nodes"] += 1

		cell.size += offset

		for pid in cell.portals:
			var fp: Portal = portals.get(pid)
			if fp != null and fp.is_full_wall:
				refit_full_wall(fp)

		return {"ok": true, "new_size": cell.size, "shifted": report}

	# ---------------------------------------------------------------- 傳送門配對

	func link_portals(a_id: String, b_id: String, bidirectional: bool = true) -> Dictionary:
		var a: Portal = portals.get(a_id)
		var b: Portal = portals.get(b_id)
		if a == null or b == null:
			return _fail("portal_not_found")
		if a_id == b_id:
			return _fail("same_portal")
		# 垂直牆面門只能接牆面門；水平開口只能「地板 ↔ 天花板」（避免上下顛倒或重力翻轉）
		if a.is_horizontal() != b.is_horizontal():
			return _fail("orientation_mismatch")
		if a.is_horizontal() and a.wall_index == b.wall_index:
			return _fail("horizontal_needs_floor_and_ceiling")
		if a.target_portal_id != "":
			return _fail("a_already_linked")
		for pid in portals:
			var other: Portal = portals[pid]
			if other.id != a_id and other.target_portal_id == b_id:
				return _fail("b_already_targeted")
		if bidirectional and b.target_portal_id != "":
			return _fail("b_already_linked")
		a.target_portal_id = b_id
		a.is_bidirectional = bidirectional
		if bidirectional:
			b.target_portal_id = a_id
			b.is_bidirectional = true
		return {"ok": true}

	func unlink_portal(portal_id: String) -> void:
		var a: Portal = portals.get(portal_id)
		if a == null or a.target_portal_id == "":
			return
		var b: Portal = portals.get(a.target_portal_id)
		if b != null and a.is_bidirectional and b.target_portal_id == portal_id:
			b.target_portal_id = ""
			b.is_bidirectional = false
		a.target_portal_id = ""
		a.is_bidirectional = false

	func has_teleport(from_id: String) -> bool:
		var a: Portal = portals.get(from_id)
		return a != null and a.target_portal_id != "" and portals.has(a.target_portal_id)

	## 從 from_id 穿越到其目標門的矩陣；未連通時回傳單位矩陣
	func teleport_matrix(from_id: String) -> Transform3D:
		if not has_teleport(from_id):
			return Transform3D.IDENTITY
		var a: Portal = portals[from_id]
		var b: Portal = portals[a.target_portal_id]
		return Portal.teleport_between(a, b)

	# ---------------------------------------------------------------- 層位分配

	## 為房間分配視覺層 / 物理層（槽位 1~20，兩者同號）。
	## 槽位用盡時，回收「距離最遠且未被 pinned」的房間；distances 缺漏的房間視為無限遠（最先被回收），
	## 呼叫端應替所有使用中的房間提供距離。回傳 evicted 讓呼叫端釋放其節點。
	func activate_cell(cell_id: String, distances: Dictionary = {}, pinned: Array = []) -> Dictionary:
		var cell: Cell = cells.get(cell_id)
		if cell == null:
			return _fail("cell_not_found")
		if cell.render_layer > 0:
			return {"ok": true, "render_layer": cell.render_layer, "physics_layer": cell.physics_layer, "evicted": ""}
		var slot: int = _slot_owner.find("")
		var evicted := ""
		if slot < 0:
			var worst := -1.0
			var worst_slot := -1
			for i in range(RENDER_SLOTS):
				var occupant: String = _slot_owner[i]
				if pinned.has(occupant):
					continue
				var dist: float = float(distances.get(occupant, INF))
				if dist > worst:
					worst = dist
					worst_slot = i
			if worst_slot < 0:
				return _fail("no_evictable_cell")
			slot = worst_slot
			evicted = _slot_owner[slot]
			var victim: Cell = cells.get(evicted)
			if victim != null:
				victim.render_layer = 0
				victim.physics_layer = 0
		_slot_owner[slot] = cell_id
		cell.render_layer = slot + 1
		cell.physics_layer = slot + 1
		return {"ok": true, "render_layer": cell.render_layer, "physics_layer": cell.physics_layer, "evicted": evicted}

	func release_cell(cell_id: String) -> void:
		var cell: Cell = cells.get(cell_id)
		if cell == null or cell.render_layer <= 0:
			return
		_slot_owner[cell.render_layer - 1] = ""
		cell.render_layer = 0
		cell.physics_layer = 0

	# ---------------------------------------------------------------- 鄰近房間

	## 從 cell_id 出發、沿「已配對的傳送門」最多走 depth 步可到達的房間（含自己），供預載與層位保留。
	func neighbor_cells(cell_id: String, depth: int = 2) -> Array:
		var seen := {cell_id: 0}
		var frontier: Array = [cell_id]
		for step in range(depth):
			var next: Array = []
			for cid in frontier:
				var c: Cell = cells.get(cid)
				if c == null:
					continue
				for pid in c.portals:
					var p: Portal = portals.get(pid)
					if p == null or p.target_portal_id == "":
						continue
					var q: Portal = portals.get(p.target_portal_id)
					if q != null and not seen.has(q.cell_id):
						seen[q.cell_id] = step + 1
						next.append(q.cell_id)
			frontier = next
		return seen.keys()

	# ---------------------------------------------------------------- 序列化 / 驗證

	func to_dict() -> Dictionary:
		var out := {
			"format": FORMAT_VERSION,
			"counter": _counter,
			"cells": [],
			"structures": [],
			"portals": [],
			"memory_nodes": [],
			"carriages": [],
		}
		for k in _sorted_keys(cells):
			out["cells"].append(cells[k].to_dict())
		for k in _sorted_keys(structures):
			out["structures"].append(structures[k].to_dict())
		for k in _sorted_keys(portals):
			out["portals"].append(portals[k].to_dict())
		for k in _sorted_keys(memory_nodes):
			out["memory_nodes"].append(memory_nodes[k].to_dict())
		for k in _sorted_keys(carriages):
			out["carriages"].append(carriages[k].to_dict())
		return out

	static func _sorted_keys(d: Dictionary) -> Array:
		var keys := d.keys()
		keys.sort()
		return keys

	static func structure_from_dict(d: Dictionary) -> Structure:
		match str(d.get("kind", "")):
			Structure.KIND_RAMP:
				return Ramp.from_dict(d)
			Structure.KIND_PLATFORM:
				return Platform.from_dict(d)
			Structure.KIND_RAILING:
				return Railing.from_dict(d)
		return null

	static func from_dict(d: Dictionary) -> PalaceModel:
		var m := PalaceModel.new()
		m._counter = int(d.get("counter", 0))
		for cd in Ser.to_arr(d.get("cells")):
			if cd is Dictionary:
				var c := Cell.from_dict(cd)
				c.render_layer = 0   # 層位為執行期資源，載入後重新分配
				c.physics_layer = 0
				m.cells[c.id] = c
		for sd in Ser.to_arr(d.get("structures")):
			if sd is Dictionary:
				var s := structure_from_dict(sd)
				if s != null:
					m.structures[s.id] = s
		for pd in Ser.to_arr(d.get("portals")):
			if pd is Dictionary:
				var p := Portal.from_dict(pd)
				m.portals[p.id] = p
		for nd in Ser.to_arr(d.get("memory_nodes")):
			if nd is Dictionary:
				var n := MemoryNode.from_dict(nd)
				m.memory_nodes[n.id] = n
		for td in Ser.to_arr(d.get("carriages")):
			if td is Dictionary:
				var t := TimeCarriage.from_dict(td)
				m.carriages[t.date_str] = t
		return m

	## 回傳完整性問題清單（空陣列 = 正常）
	func validate() -> Array:
		var problems: Array = []
		for cid in cells:
			var c: Cell = cells[cid]
			for sid in c.structures:
				if not structures.has(sid):
					problems.append("cell %s 缺少建材 %s" % [cid, sid])
			for pid in c.portals:
				if not portals.has(pid):
					problems.append("cell %s 缺少門框 %s" % [cid, pid])
		for sid in structures:
			if not cells.has(structures[sid].cell_id):
				problems.append("建材 %s 指向不存在的房間" % sid)
		for pid in portals:
			var p: Portal = portals[pid]
			if not cells.has(p.cell_id):
				problems.append("門框 %s 指向不存在的房間" % pid)
			if p.target_portal_id != "" and not portals.has(p.target_portal_id):
				problems.append("門框 %s 的目標 %s 不存在" % [pid, p.target_portal_id])
		for nid in memory_nodes:
			if not cells.has(memory_nodes[nid].cell_id):
				problems.append("記憶物件 %s 指向不存在的房間" % nid)
		return problems
