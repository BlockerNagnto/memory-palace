extends Node3D
## memory_node_view.gd — 記憶節點的 3D 外觀（三層記憶的前兩層：形狀 + 15 字提示）
##
##   沒有素材       → 金色線框方塊（佔位符）
##   assetType=image → 圖片貼在直立的方片上（長邊 = TARGET_SIZE × scale）
##   assetType=model → GLB / OBJ 模型，縮放到最長邊 = TARGET_SIZE × scale、置中於節點位置
##   素材遺失 / 解碼失敗 / 面數過多 → 紅色線框方塊，status 記錄原因
##
## 所有材質一律 Unshaded（沒有燈光）：GLB 內的材質會被轉成 Unshaded（保留貼圖與顏色），
## OBJ 沒有材質檔時用「依法線的固定明暗」假光影，讓形狀看得出立體感。
## 房間之間靠視覺層分開：呼叫 set_render_layer(cell.render_layer)；互動碰撞體固定在物理層 23。
##
## 房間節點樹用法（見 populate_cell）：
##   RB.rebuild_cell(cell_root, model, cell_id)          # 會清掉所有子節點
##   MemoryNodeView.populate_cell(cell_root, model, cell_id, assets)   # 再補上記憶節點

const SM = preload("res://scripts/space_model.gd")
const RB = preload("res://scripts/room_builder.gd")
const ST = preload("res://scripts/storage.gd")
const FS = preload("res://scripts/font_setup.gd")

const TARGET_SIZE := 0.8            # 長邊（公尺）；再乘上 MemoryNode.scale
const PLACEHOLDER_SIZE := 0.4
const INTERACT_BIT := 1 << 22       # 物理層 23
const MAX_IMAGE_SIDE := 1024        # 超過就縮小，省行動裝置的記憶體
const MAX_TRIANGLES := 100000       # 超過視為過重（階段二會做減面壓縮）
const LABEL_SHOW_DISTANCE := 4.0
const COLOR_PLACEHOLDER := Color(0.95, 0.85, 0.45)
const COLOR_ERROR := Color(0.9, 0.3, 0.3)
const FAKE_LIGHT := Vector3(0.35, 0.8, 0.5)


## ====================================================================== 載入器（純資料處理，無需 GPU）
class Loader:
	## 解碼圖片（PNG / JPG / WebP），長邊超過 max_side 時縮小。失敗回傳 null。
	static func decode_image(bytes: PackedByteArray, max_side: int) -> Image:
		var info: Dictionary = ST.AssetStore.detect(bytes)
		if info.is_empty() or info["type"] != "image":
			return null
		var img := Image.new()
		var err := OK
		match info["ext"]:
			"png":
				err = img.load_png_from_buffer(bytes)
			"jpg":
				err = img.load_jpg_from_buffer(bytes)
			"webp":
				err = img.load_webp_from_buffer(bytes)
			_:
				return null
		if err != OK or img.is_empty():
			return null
		var longest := maxi(img.get_width(), img.get_height())
		if longest > max_side:
			var k := float(max_side) / float(longest)
			img.resize(maxi(int(img.get_width() * k), 1), maxi(int(img.get_height() * k), 1), Image.INTERPOLATE_BILINEAR)
		return img

	## 圖片顯示尺寸：長邊 = target
	static func image_display_size(w: int, h: int, target: float) -> Vector2:
		if w <= 0 or h <= 0:
			return Vector2(target, target)
		var k := target / float(maxi(w, h))
		return Vector2(w * k, h * k)

	## 把一個縮放因子算出來，使 aabb 的最長邊 = target
	static func fit_scale(aabb: AABB, target: float) -> float:
		var longest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
		if longest <= 1e-6:
			return 1.0
		return target / longest

	## 解析 OBJ 文字：支援 v / vt / f（含 v/vt、v//vn、v/vt/vn、負索引、多邊形扇形切分）。
	## 回傳 {ok, mesh, triangles, aabb} 或 {ok=false, error}
	static func parse_obj(text: String) -> Dictionary:
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		var out_v := PackedVector3Array()
		var out_uv := PackedVector2Array()
		var out_c := PackedColorArray()
		var light := FAKE_LIGHT.normalized()
		var tris := 0
		for raw in text.split("\n", false):
			var line := raw.strip_edges()
			if line.length() < 2 or line.begins_with("#"):
				continue
			var parts := line.split(" ", false)
			match parts[0]:
				"v":
					if parts.size() < 4:
						return {"ok": false, "error": "bad_vertex"}
					verts.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
				"vt":
					if parts.size() < 3:
						return {"ok": false, "error": "bad_uv"}
					uvs.append(Vector2(parts[1].to_float(), 1.0 - parts[2].to_float()))
				"f":
					if parts.size() < 4:
						continue
					var idx: Array = []
					for i in range(1, parts.size()):
						var comp := parts[i].split("/")
						var vi := _resolve(comp[0].to_int(), verts.size())
						if vi < 0:
							return {"ok": false, "error": "bad_face_index"}
						var ti := -1
						if comp.size() > 1 and comp[1] != "":
							ti = _resolve(comp[1].to_int(), uvs.size())
						idx.append([vi, ti])
					for k in range(1, idx.size() - 1):
						tris += 1
						if tris > MAX_TRIANGLES:
							return {"ok": false, "error": "too_many_triangles"}
						var a: Vector3 = verts[idx[0][0]]
						var b: Vector3 = verts[idx[k][0]]
						var c: Vector3 = verts[idx[k + 1][0]]
						# Godot 的正面是順時針；OBJ 是逆時針，所以輸出順序 a, c, b
						var n := (c - a).cross(b - a)
						var shade := 0.55 + 0.45 * absf(n.normalized().dot(light)) if n.length() > 1e-12 else 0.7
						var col := Color(shade, shade, shade)
						var ua := Vector2.ZERO
						var ub := Vector2.ZERO
						var uc := Vector2.ZERO
						if idx[0][1] >= 0 and idx[k][1] >= 0 and idx[k + 1][1] >= 0:
							ua = uvs[idx[0][1]]
							ub = uvs[idx[k][1]]
							uc = uvs[idx[k + 1][1]]
						out_v.append(a)
						out_v.append(c)
						out_v.append(b)
						out_uv.append(ua)
						out_uv.append(uc)
						out_uv.append(ub)
						out_c.append(col)
						out_c.append(col)
						out_c.append(col)
		if tris == 0:
			return {"ok": false, "error": "no_faces"}
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = out_v
		arrays[Mesh.ARRAY_TEX_UV] = out_uv
		arrays[Mesh.ARRAY_COLOR] = out_c
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.albedo_color = Color(0.82, 0.84, 0.9)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.surface_set_material(0, mat)
		return {"ok": true, "mesh": mesh, "triangles": tris, "aabb": mesh.get_aabb()}

	## OBJ 索引（1 起算；負數 = 從尾端倒數）轉 0 起算；超出範圍回傳 -1
	static func _resolve(i: int, count: int) -> int:
		var r := i - 1 if i > 0 else count + i
		return r if (i != 0 and r >= 0 and r < count) else -1

	## 載入 GLB。回傳 {ok, root, triangles, aabb} 或 {ok=false, error}
	static func load_glb(bytes: PackedByteArray) -> Dictionary:
		# 先自行檢查 GLB 檔頭，壞檔不要丟給引擎（引擎會印出錯誤訊息）
		if bytes.size() < 28 or bytes.decode_u32(0) != 0x46546C67 or bytes.decode_u32(16) != 0x4E4F534A \
				or bytes.decode_u32(8) > bytes.size():
			return {"ok": false, "error": "glb_bad_header"}
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_buffer(bytes, "", state)
		if err != OK:
			return {"ok": false, "error": "glb_parse_failed:%d" % err}
		var scene: Node = doc.generate_scene(state)
		if scene == null or not (scene is Node3D):
			if scene != null:
				scene.free()
			return {"ok": false, "error": "glb_no_scene"}
		var root: Node3D = scene
		_strip_non_visual(root)
		var tris := count_triangles(root)
		if tris == 0:
			root.free()
			return {"ok": false, "error": "no_mesh"}
		if tris > MAX_TRIANGLES:
			root.free()
			return {"ok": false, "error": "too_many_triangles"}
		force_unshaded(root)
		return {"ok": true, "root": root, "triangles": tris, "aabb": merged_aabb(root)}

	## 刪除模型裡的燈光、攝影機、動畫（記憶節點只要靜態外觀）
	static func _strip_non_visual(node: Node) -> void:
		for ch in node.get_children():
			if ch is Light3D or ch is Camera3D or ch is AnimationPlayer:
				node.remove_child(ch)
				ch.free()
			else:
				_strip_non_visual(ch)

	static func force_unshaded(node: Node) -> void:
		if node is MeshInstance3D and node.mesh != null:
			var mi: MeshInstance3D = node
			for s in range(mi.mesh.get_surface_count()):
				var m: Material = mi.get_active_material(s)
				var base: BaseMaterial3D
				if m is BaseMaterial3D:
					base = m.duplicate()
				else:
					base = StandardMaterial3D.new()
					base.albedo_color = Color(0.82, 0.84, 0.9)
				base.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mi.set_surface_override_material(s, base)
		for ch in node.get_children():
			force_unshaded(ch)

	static func count_triangles(node: Node) -> int:
		var n := 0
		if node is MeshInstance3D and node.mesh != null:
			var mesh: Mesh = node.mesh
			for s in range(mesh.get_surface_count()):
				var arrays := mesh.surface_get_arrays(s)
				if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null and (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
					n += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				elif arrays[Mesh.ARRAY_VERTEX] != null:
					n += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		for ch in node.get_children():
			n += count_triangles(ch)
		return n

	## 整棵子樹（含自己的 transform）在 root 本地空間的包圍盒
	static func merged_aabb(root: Node3D) -> AABB:
		var acc := {"aabb": AABB(), "has": false}
		_aabb_rec(root, Transform3D.IDENTITY, acc)
		return acc["aabb"] if acc["has"] else AABB()

	static func _aabb_rec(node: Node, xf: Transform3D, acc: Dictionary) -> void:
		if node is MeshInstance3D and node.mesh != null:
			var box: AABB = xf * node.mesh.get_aabb()
			if acc["has"]:
				acc["aabb"] = (acc["aabb"] as AABB).merge(box)
			else:
				acc["aabb"] = box
				acc["has"] = true
		for ch in node.get_children():
			if ch is Node3D:
				_aabb_rec(ch, xf * (ch as Node3D).transform, acc)


## ====================================================================== 節點本體
var node_id := ""
var cell_id := ""
var status := "placeholder"     # ok | placeholder | missing_asset | decode_failed | too_heavy | unsupported
var content: Node3D = null
var hit_body: StaticBody3D = null
var label: Label3D = null
var content_size := Vector3.ONE * PLACEHOLDER_SIZE   # 內容在節點本地空間的大小（已含 scale）
var content_center := Vector3.ZERO
var labels_near_only := true

var _selected_box: MeshInstance3D = null
var _selected := false
var _label_timer := 0.0


## 依資料建立外觀。assets 為 storage.gd 的 AssetStore（可為 null → 一律佔位符）。
func setup(mem, assets) -> void:
	node_id = mem.id
	cell_id = mem.cell_id
	name = "Mem_" + mem.id
	position = mem.pos
	rotation = mem.rot

	var bytes := PackedByteArray()
	if mem.asset_hash != "" and mem.asset_type != "":
		if assets == null or not assets.has_asset(mem.asset_hash):
			status = "missing_asset"
		else:
			bytes = assets.read_asset(mem.asset_hash)
	else:
		status = "placeholder"

	var built := false
	if bytes.size() > 0:
		match mem.asset_type:
			"image":
				built = _build_image(bytes, mem.scale)
			"model":
				built = _build_model(bytes, mem.scale)
			_:
				status = "unsupported"
	if not built:
		_build_placeholder(mem.scale, status == "placeholder")
	_build_hit_body()
	_build_label(mem.prompt15)
	set_selected(false)


func _build_placeholder(scale_v: Vector3, neutral: bool) -> void:
	var size := Vector3(PLACEHOLDER_SIZE, PLACEHOLDER_SIZE, PLACEHOLDER_SIZE) * scale_v
	var wire := RB.make_wire_box(size, COLOR_PLACEHOLDER if neutral else COLOR_ERROR)
	wire.name = "Content"
	add_child(wire)
	content = wire
	content_size = size
	content_center = Vector3.ZERO


func _build_image(bytes: PackedByteArray, scale_v: Vector3) -> bool:
	var img := Loader.decode_image(bytes, MAX_IMAGE_SIDE)
	if img == null:
		status = "decode_failed"
		return false
	var tex := ImageTexture.create_from_image(img)
	var dims := Loader.image_display_size(img.get_width(), img.get_height(), TARGET_SIZE)
	var mi := MeshInstance3D.new()
	mi.name = "Content"
	mi.mesh = RB.make_quad_mesh(dims)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if img.detect_alpha() != Image.ALPHA_NONE else BaseMaterial3D.TRANSPARENCY_DISABLED
	mi.material_override = mat
	mi.scale = Vector3(scale_v.x, scale_v.y, 1.0)
	add_child(mi)
	content = mi
	content_size = Vector3(dims.x * scale_v.x, dims.y * scale_v.y, 0.04)
	content_center = Vector3.ZERO
	status = "ok"
	return true


func _build_model(bytes: PackedByteArray, scale_v: Vector3) -> bool:
	var info: Dictionary = ST.AssetStore.detect(bytes, "obj")
	if info.is_empty() or info["type"] != "model":
		status = "unsupported"
		return false
	var node: Node3D
	var box: AABB
	if info["ext"] == "glb":
		var r := Loader.load_glb(bytes)
		if not r["ok"]:
			status = "too_heavy" if str(r["error"]) == "too_many_triangles" else "decode_failed"
			return false
		node = r["root"]
		box = r["aabb"]
	else:
		var r2 := Loader.parse_obj(bytes.get_string_from_utf8())
		if not r2["ok"]:
			status = "too_heavy" if str(r2["error"]) == "too_many_triangles" else "decode_failed"
			return false
		var mi := MeshInstance3D.new()
		mi.mesh = r2["mesh"]
		node = mi
		box = r2["aabb"]
	var k := Loader.fit_scale(box, TARGET_SIZE)
	var holder := Node3D.new()
	holder.name = "Content"
	node.position = -box.get_center()            # 讓模型中心落在節點位置
	var inner := Node3D.new()
	inner.add_child(node)
	inner.scale = Vector3.ONE * k
	holder.add_child(inner)
	holder.scale = scale_v
	add_child(holder)
	content = holder
	content_size = box.size * k * scale_v
	content_center = Vector3.ZERO
	status = "ok"
	return true


func _build_hit_body() -> void:
	hit_body = StaticBody3D.new()
	hit_body.name = "Hit"
	hit_body.collision_layer = INTERACT_BIT
	hit_body.collision_mask = 0
	hit_body.set_meta("memory_node_id", node_id)
	hit_body.set_meta("cell_id", cell_id)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(content_size.x, 0.25), maxf(content_size.y, 0.25), maxf(content_size.z, 0.25))
	cs.shape = box
	cs.position = content_center
	hit_body.add_child(cs)
	add_child(hit_body)


func _build_label(text: String) -> void:
	label = Label3D.new()
	label.name = "Prompt"
	label.text = text
	var cjk: Font = FS.load_cjk()
	if cjk != null:
		label.font = cjk
	label.font_size = 40
	label.pixel_size = 0.004
	label.outline_size = 10
	label.outline_modulate = Color(0.05, 0.05, 0.08, 0.9)
	label.modulate = Color(1, 1, 1)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.shaded = false
	label.double_sided = true
	label.no_depth_test = false
	label.position = content_center + Vector3(0.0, content_size.y * 0.5 + 0.14, 0.0)
	label.visible = false
	add_child(label)


## 更新提示文字（編輯後）
func set_prompt(text: String) -> void:
	if label != null:
		label.text = text


func set_selected(on: bool) -> void:
	_selected = on
	if on and _selected_box == null:
		_selected_box = RB.make_wire_box(content_size * 1.08, Color(0.4, 0.85, 1.0))
		_selected_box.name = "Selected"
		_selected_box.position = content_center
		add_child(_selected_box)
		_apply_visual_layers(_selected_box, _layer_bits)
	if _selected_box != null:
		_selected_box.visible = on
	_refresh_label(true)


func is_selected() -> bool:
	return _selected


var _layer_bits := 1


## 套用房間的視覺層（cell.render_layer，1~20）。互動碰撞體的物理層不受影響。
func set_render_layer(render_layer: int) -> void:
	if render_layer <= 0:
		return
	_layer_bits = SM.PalaceModel.layer_bit(render_layer)
	_apply_visual_layers(self, _layer_bits)


static func _apply_visual_layers(node: Node, bits: int) -> void:
	if node is VisualInstance3D:
		node.layers = bits
	for ch in node.get_children():
		_apply_visual_layers(ch, bits)


func _process(delta: float) -> void:
	_label_timer += delta
	if _label_timer < 0.15:
		return
	_label_timer = 0.0
	_refresh_label(false)


func _refresh_label(_force: bool) -> void:
	if label == null or label.text == "":
		return
	var show := _selected
	if not show and labels_near_only:
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			show = cam.global_position.distance_to(global_position) <= LABEL_SHOW_DISTANCE
	elif not show:
		show = true
	label.visible = show


## ---------------------------------------------------------------- 房間層級的工廠
## 在房間根節點下建立（或重建）名為 "Memories" 的容器，內含該房間所有記憶節點。
## 回傳 {node_id: view}。
static func populate_cell(root: Node3D, model, cell_id: String, assets) -> Dictionary:
	var old := root.get_node_or_null("Memories")
	if old != null:
		root.remove_child(old)
		old.queue_free()
	var out := {}
	var cell = model.cells.get(cell_id)
	if cell == null:
		return out
	var holder := Node3D.new()
	holder.name = "Memories"
	root.add_child(holder)
	var ids: Array = model.memory_nodes.keys()
	ids.sort()
	var script: GDScript = load("res://scripts/memory_node_view.gd")
	for nid in ids:
		var mem = model.memory_nodes[nid]
		if mem.cell_id != cell_id:
			continue
		var v = script.new()
		holder.add_child(v)
		v.setup(mem, assets)
		v.set_render_layer(cell.render_layer)
		out[nid] = v
	return out
