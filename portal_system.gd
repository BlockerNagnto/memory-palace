extends Node3D
## portal_system.gd — 傳送門的渲染、近距離防穿幫與穿越傳送
##
## 渲染原理（單一 World3D、各房間靠視覺層隔離）：
##   · 主攝影機只看「目前房間的視覺層」+ 視覺層 21（L0：目前房間裡有分到視圖的門表面）。
##   · 每個有分到視圖的門 = 一個 SubViewport + 一支虛擬攝影機，位置 = M_AB · 主攝影機，
##     cull_mask 只含目標房間的視覺層 → 畫出「從門看過去」的畫面；門表面用 portal_clip.gdshader
##     以螢幕座標取樣這張貼圖。
##   · 遞迴深度 2：一級視圖裡看得到的門，若還有預算，就用視覺層 22~32 的「複本表面」顯示二級視圖；
##     更深的、或超出同時可見上限的門，一律顯示霧色封板（room_builder 的 Plug_*，每個房間本來就有）。
##   · 同時存在的視圖總數（含一、二級）不超過 max_visible（預設 6，上限 11，受視覺層 22~32 的數量限制）。
##   · 近距離（距門平面 < 0.1 m 且在門洞範圍附近）時，把平面換成向門內凹陷 0.15 m 的 U 型盒，
##     貼門或穿越瞬間轉頭都不會切穿門平面看到門後的空洞。
##
## 穿越：每個物理幀把「眼睛上一幀 / 這一幀位置」交給 try_teleport()，偵測是否由正面穿過門洞；
##   穿過就換目前房間並回傳變換矩陣，玩家要自己套用：global_transform = matrix * global_transform，
##   速度 = matrix.basis * velocity，並把碰撞 mask 換成新房間的物理層位元。
##
## 純邏輯集中在 Logic（無節點、可無頭測試）：可見性評分、視圖規劃與預算、穿越判定、凹陷判定。

const SM = preload("res://scripts/space_model.gd")
const RB = preload("res://scripts/room_builder.gd")
const CLIP_SHADER = preload("res://shaders/portal_clip.gdshader")

signal teleported(from_portal_id: String, to_cell_id: String, matrix: Transform3D)


## ====================================================================== 純邏輯
class Logic:
	const L0_LAYER_BIT := 1 << 20        # 視覺層 21
	const CLONE_FIRST_BIT_INDEX := 21    # 視覺層 22 起
	const MAX_CLONE_SLOTS := 11          # 視覺層 22~32
	const NEAR_RECESS_DISTANCE := 0.1
	const RECESS_DEPTH := 0.15
	const SURFACE_OFFSET := 0.003        # 表面略往房內偏移，避免與霧色封板共面閃爍
	const FOG_COLOR := Color(0.07, 0.08, 0.12)

	## 門在攝影機視野裡的優先分數（越小越優先）；看不到（背面、視野外）回傳 INF。
	static func visible_score(p, cam: Transform3D, fov_deg: float, aspect: float) -> float:
		var to_p: Vector3 = p.local_pos - cam.origin
		var dist := to_p.length()
		if (cam.origin - p.local_pos).dot(p.normal) <= 0.0:
			return INF   # 攝影機在門的背面
		if dist < 0.05:
			return 0.0
		var forward: Vector3 = -cam.basis.z
		var cos_a := clampf((to_p / dist).dot(forward), -1.0, 1.0)
		var half_v := deg_to_rad(fov_deg) * 0.5
		var half_diag := atan(tan(half_v) * sqrt(1.0 + aspect * aspect))
		var radius := 0.5 * sqrt(p.size.x * p.size.x + p.size.y * p.size.y)
		if acos(cos_a) > half_diag + atan2(radius, dist):
			return INF   # 整扇門都在視野外
		return dist * (2.0 - cos_a)

	static func _by_score(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return str(a[1]) + str(a[2] if a.size() > 2 else "") < str(b[1]) + str(b[2] if b.size() > 2 else "")

	## 規劃本幀要渲染的視圖。回傳 Array[Dictionary]：
	##   {depth, portal_id, parent, cell_id, exit_portal_id, xf, score}
	## 一級視圖（depth 1）先按分數取滿 budget；剩餘預算分給二級視圖（depth 2，parent = 一級視圖的索引）。
	static func plan_views(model, cell_id: String, cam: Transform3D, fov_deg: float, aspect: float, budget: int) -> Array:
		var views: Array = []
		var cell = model.cells.get(cell_id)
		if cell == null or budget <= 0:
			return views
		var cands: Array = []
		for pid in cell.portals:
			if not model.has_teleport(pid):
				continue
			var sc := visible_score(model.portals[pid], cam, fov_deg, aspect)
			if sc < INF:
				cands.append([sc, pid])
		cands.sort_custom(_by_score)
		var n1 := mini(cands.size(), budget)
		for i in range(n1):
			var pid: String = cands[i][1]
			var p = model.portals[pid]
			var q = model.portals[p.target_portal_id]
			var m: Transform3D = SM.Portal.teleport_between(p, q)
			views.append({"depth": 1, "portal_id": pid, "parent": -1, "cell_id": q.cell_id,
				"exit_portal_id": q.id, "xf": m * cam, "score": cands[i][0]})
		var remaining := budget - n1
		if remaining <= 0:
			return views
		var c2: Array = []
		for vi in range(n1):
			var v1: Dictionary = views[vi]
			var tcell = model.cells.get(v1["cell_id"])
			if tcell == null:
				continue
			for qid in tcell.portals:
				if qid == v1["exit_portal_id"] or not model.has_teleport(qid):
					continue
				var sc2 := visible_score(model.portals[qid], v1["xf"], fov_deg, aspect)
				if sc2 < INF:
					c2.append([sc2, vi, qid])
		c2.sort_custom(_by_score)
		for k in range(mini(c2.size(), remaining)):
			var parent: int = c2[k][1]
			var qid2: String = c2[k][2]
			var q2 = model.portals[qid2]
			var r = model.portals[q2.target_portal_id]
			var m2: Transform3D = SM.Portal.teleport_between(q2, r)
			views.append({"depth": 2, "portal_id": qid2, "parent": parent, "cell_id": r.cell_id,
				"exit_portal_id": r.id, "xf": m2 * views[parent]["xf"], "score": c2[k][0]})
		return views

	## 點是否落在門洞矩形內（門框區域座標），margin 為額外容許量
	static func inside_rect(p, point: Vector3, margin: float) -> bool:
		var local: Vector3 = p.frame().affine_inverse() * point
		return absf(local.x) <= p.size.x * 0.5 + margin and absf(local.y) <= p.size.y * 0.5 + margin

	## 這一步是否由正面穿過門平面，且穿越點落在門洞內
	static func crossed(p, prev_pos: Vector3, new_pos: Vector3) -> bool:
		var d0: float = (prev_pos - p.local_pos).dot(p.normal)
		var d1: float = (new_pos - p.local_pos).dot(p.normal)
		if not (d0 > 0.0 and d1 <= 0.0):
			return false
		var t := d0 / (d0 - d1)
		return inside_rect(p, prev_pos.lerp(new_pos, t), 0.0)

	## 是否需要把平面換成凹陷 U 型盒
	static func recess_needed(p, cam_pos: Vector3) -> bool:
		var d: float = (cam_pos - p.local_pos).dot(p.normal)
		if absf(d) >= NEAR_RECESS_DISTANCE:
			return false
		return inside_rect(p, cam_pos, NEAR_RECESS_DISTANCE)


## ====================================================================== 門表面（平面 + 凹陷盒）
class Surface extends Node3D:
	var quad: MeshInstance3D
	var box: MeshInstance3D
	var material: ShaderMaterial
	var _size := Vector2(-1.0, -1.0)

	func _init(shader: Shader) -> void:
		material = ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("fog_color", Logic.FOG_COLOR)
		quad = MeshInstance3D.new()
		box = MeshInstance3D.new()
		quad.material_override = material
		box.material_override = material
		add_child(quad)
		add_child(box)
		box.visible = false
		visible = false

	## 依目前的門資料更新位置 / 尺寸 / 視覺層
	func configure(p, layer_bits: int) -> void:
		var xf: Transform3D = p.frame()
		xf.origin += p.normal.normalized() * Logic.SURFACE_OFFSET
		transform = xf
		quad.layers = layer_bits
		box.layers = layer_bits
		if not p.size.is_equal_approx(_size):
			_size = p.size
			quad.mesh = RB.make_quad_mesh(p.size)
			box.mesh = RB.make_recess_box_mesh(p.size, Logic.RECESS_DEPTH)
		# 凹陷盒只在門平面後方；clip 平面用不含偏移的原始門平面
		var n: Vector3 = p.normal.normalized()
		material.set_shader_parameter("clip_plane", Vector4(n.x, n.y, n.z, -n.dot(p.local_pos)))

	func set_texture(tex: Texture2D) -> void:
		material.set_shader_parameter("viewport_tex", tex)

	func set_recessed(on: bool) -> void:
		quad.visible = not on
		box.visible = on
		material.set_shader_parameter("clip_enabled", on)


## ====================================================================== 視圖（SubViewport + 虛擬攝影機）
class PortalView extends RefCounted:
	var viewport: SubViewport
	var camera: Camera3D
	var active := false

	func set_active(on: bool) -> void:
		if on == active:
			return
		active = on
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


## ====================================================================== 節點本體
var model = null                    # SM.PalaceModel
var main_camera: Camera3D = null
var current_cell_id := ""
var max_visible := 6                # 同時存在的視圖上限（含一、二級）；實際上限 11
var resolution_scale := 0.5         # 視圖解析度 = 主視窗 × 此值（行動裝置效能）

var _l0: Dictionary = {}            # portal_id -> Surface（目前房間）
var _clones: Dictionary = {}        # "slot|portal_id" -> Surface（深度 2 複本）
var _views: Array = []              # PortalView 物件池（依規劃索引使用）
var _view_size := Vector2i(64, 64)


func _ready() -> void:
	process_priority = 100   # 晚於玩家與攝影機移動，用的是同一幀最新的攝影機位置


func setup(p_model, p_camera: Camera3D) -> void:
	model = p_model
	main_camera = p_camera
	if main_camera != null:
		main_camera.near = 0.03


## 切換目前房間（啟動、傳送後呼叫）。呼叫前該房間必須已 activate_cell 並建好節點。
func set_current_cell(cell_id: String) -> void:
	current_cell_id = cell_id
	_update_main_mask()
	rebuild_surfaces()


## 傳送門資料變動（放置 / 縮放 / 平移 / 拉長 / 配對）之後呼叫
func refresh() -> void:
	rebuild_surfaces()


func rebuild_surfaces() -> void:
	for s in _l0.values():
		s.queue_free()
	_l0.clear()
	for s in _clones.values():
		s.queue_free()
	_clones.clear()
	if model == null:
		return
	var cell = model.cells.get(current_cell_id)
	if cell == null:
		return
	for pid in cell.portals:
		var s := Surface.new(CLIP_SHADER)
		add_child(s)
		_l0[pid] = s


func _update_main_mask() -> void:
	if main_camera == null or model == null:
		return
	var cell = model.cells.get(current_cell_id)
	if cell != null and cell.render_layer > 0:
		main_camera.cull_mask = SM.PalaceModel.layer_bit(cell.render_layer) | Logic.L0_LAYER_BIT


func _process(_delta: float) -> void:
	if model == null or main_camera == null or current_cell_id == "":
		return
	var cell = model.cells.get(current_cell_id)
	if cell == null or cell.render_layer <= 0:
		return
	_update_main_mask()
	var vp := get_viewport().get_visible_rect().size
	_ensure_view_size(vp)
	var aspect := vp.x / maxf(vp.y, 1.0)
	var budget := mini(max_visible, Logic.MAX_CLONE_SLOTS)
	var plan := Logic.plan_views(model, current_cell_id, main_camera.global_transform, main_camera.fov, aspect, budget)
	_apply_plan(plan, main_camera.global_position)


func _ensure_view_size(vp: Vector2) -> void:
	var s := Vector2i(maxi(int(vp.x * resolution_scale), 64), maxi(int(vp.y * resolution_scale), 64))
	if s == _view_size:
		return
	_view_size = s
	for v: PortalView in _views:
		v.viewport.size = s


func _get_view(index: int) -> PortalView:
	while _views.size() <= index:
		var v := PortalView.new()
		v.viewport = SubViewport.new()
		v.viewport.own_world_3d = false        # 與主視窗共用同一個 World3D
		v.viewport.transparent_bg = false
		v.viewport.msaa_3d = Viewport.MSAA_DISABLED
		v.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		v.viewport.size = _view_size
		v.camera = Camera3D.new()
		v.camera.current = true
		v.viewport.add_child(v.camera)
		add_child(v.viewport)
		_views.append(v)
	return _views[index]


func _get_clone(slot: int, portal_id: String) -> Surface:
	var key := "%d|%s" % [slot, portal_id]
	if _clones.has(key):
		return _clones[key]
	var s := Surface.new(CLIP_SHADER)
	add_child(s)
	_clones[key] = s
	return s


func _apply_plan(plan: Array, cam_pos: Vector3) -> void:
	for s in _l0.values():
		s.visible = false
	for s in _clones.values():
		s.visible = false

	var slot_of_view := {}   # 規劃索引 -> 一級視圖的複本槽位
	var dead := {}           # 目標房間尚未啟用（沒有視覺層）的視圖，改顯示霧色
	var next_slot := 0
	for i in range(plan.size()):
		var spec: Dictionary = plan[i]
		var view := _get_view(i)
		var tcell = model.cells.get(spec["cell_id"])
		var parent: int = spec["parent"]
		if tcell == null or tcell.render_layer <= 0 or (parent >= 0 and dead.has(parent)):
			dead[i] = true
			view.set_active(false)
			continue
		view.set_active(true)
		var cam := view.camera
		cam.global_transform = spec["xf"]
		cam.fov = main_camera.fov
		cam.near = main_camera.near
		cam.far = main_camera.far
		cam.keep_aspect = main_camera.keep_aspect
		var mask := SM.PalaceModel.layer_bit(tcell.render_layer)
		if spec["depth"] == 1:
			slot_of_view[i] = next_slot
			mask |= 1 << (Logic.CLONE_FIRST_BIT_INDEX + next_slot)
			next_slot += 1
		cam.cull_mask = mask

		var p = model.portals[spec["portal_id"]]
		var tex := view.viewport.get_texture()
		if spec["depth"] == 1:
			var s: Surface = _l0.get(p.id)
			if s != null:
				s.configure(p, Logic.L0_LAYER_BIT)
				s.set_texture(tex)
				s.set_recessed(Logic.recess_needed(p, cam_pos))
				s.visible = true
		else:
			var slot: int = slot_of_view.get(parent, -1)
			if slot >= 0:
				var c := _get_clone(slot, p.id)
				c.configure(p, 1 << (Logic.CLONE_FIRST_BIT_INDEX + slot))
				c.set_texture(tex)
				c.set_recessed(false)
				c.visible = true
	for j in range(plan.size(), _views.size()):
		_views[j].set_active(false)


## 偵測眼睛由 prev_eye 走到 eye 是否穿過目前房間的某扇已配對傳送門。
## 穿過時已切換 current_cell_id，回傳 {ok, portal_id, target_cell_id, matrix}；玩家需自行套用 matrix。
func try_teleport(prev_eye: Vector3, eye: Vector3) -> Dictionary:
	if model == null:
		return {"ok": false}
	var cell = model.cells.get(current_cell_id)
	if cell == null:
		return {"ok": false}
	var ids: Array = cell.portals.duplicate()
	ids.sort()
	for pid in ids:
		if not model.has_teleport(pid):
			continue
		var p = model.portals[pid]
		if Logic.crossed(p, prev_eye, eye):
			var m: Transform3D = model.teleport_matrix(pid)
			var q = model.portals[p.target_portal_id]
			set_current_cell(q.cell_id)
			teleported.emit(pid, q.cell_id, m)
			return {"ok": true, "portal_id": pid, "target_cell_id": q.cell_id, "matrix": m}
	return {"ok": false}


## 目前應保持啟用（有視覺層、已建好節點）的房間：目前房間與沿已配對的門 2 步內的房間
func required_cells() -> Array:
	if model == null or current_cell_id == "":
		return []
	return model.neighbor_cells(current_cell_id, 2)
