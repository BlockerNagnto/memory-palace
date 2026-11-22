extends RefCounted
## room_builder.gd — 依資料模型生成房間的 3D 節點（全部 Unshaded，無光影計算）
##
## 產生的結構（根節點 Cell_<id>，meta cell_id）：
##   Shell        MeshInstance3D：六個面（牆 / 地板 / 天花板），傳送門位置已挖洞，每面一個 surface
##   ShellBody    StaticBody3D  ：與 Shell 相同的三角網格碰撞（雙面碰撞）
##   Struct_<id>  Node3D        ：斜坡 / 平台 / 欄桿（視覺 + 碰撞），meta structure_id
##   Frame_<id>   Node3D        ：傳送門的薄框（滿版門無框），meta portal_id
##   Plug_<id>    MeshInstance3D：門洞上的霧色封板（法線朝房內）。沒有任何傳送門視圖時、
##                              或遞迴深度超過上限時，看進去就是霧色，而不是穿幫的空洞。
##
## 使用前請先 model.activate_cell(cell_id) 取得層位，build_cell 會把所有 VisualInstance3D 設到該房間的視覺層、
## 所有碰撞體設到該房間的物理層（collision_mask 為 0，玩家的 mask 要包含該層位元）。
##
## 純邏輯（無節點、可無頭測試）：face_rects、add_tri 的繞向規則。

const SM = preload("res://scripts/space_model.gd")

const TILE_M := 1.0                       # 紋理重複一次對應的公尺數
const FRAME_BORDER := 0.06                # 門框寬度
const FRAME_DEPTH := 0.04                 # 門框凸出牆面的深度
const FOG_COLOR := Color(0.07, 0.08, 0.12)
const EPS := 1e-5

const THEMES := {
	"default": {
		"wall": Color(0.62, 0.66, 0.72), "floor": Color(0.42, 0.44, 0.48),
		"ceiling": Color(0.80, 0.82, 0.86), "line": Color(0.32, 0.35, 0.40), "accent": Color(0.86, 0.72, 0.42),
	},
	"ivory": {
		"wall": Color(0.90, 0.87, 0.78), "floor": Color(0.66, 0.58, 0.46),
		"ceiling": Color(0.96, 0.94, 0.88), "line": Color(0.62, 0.56, 0.46), "accent": Color(0.55, 0.36, 0.22),
	},
	"night": {
		"wall": Color(0.16, 0.19, 0.32), "floor": Color(0.10, 0.12, 0.20),
		"ceiling": Color(0.12, 0.14, 0.26), "line": Color(0.32, 0.38, 0.62), "accent": Color(0.95, 0.82, 0.40),
	},
	"forest": {
		"wall": Color(0.33, 0.52, 0.36), "floor": Color(0.22, 0.34, 0.24),
		"ceiling": Color(0.55, 0.70, 0.52), "line": Color(0.16, 0.28, 0.18), "accent": Color(0.88, 0.76, 0.46),
	},
	"ocean": {
		"wall": Color(0.28, 0.54, 0.70), "floor": Color(0.16, 0.34, 0.48),
		"ceiling": Color(0.62, 0.82, 0.90), "line": Color(0.12, 0.28, 0.40), "accent": Color(0.96, 0.84, 0.60),
	},
	"rose": {
		"wall": Color(0.82, 0.55, 0.60), "floor": Color(0.52, 0.30, 0.36),
		"ceiling": Color(0.94, 0.80, 0.82), "line": Color(0.48, 0.26, 0.32), "accent": Color(0.98, 0.90, 0.70),
	},
}

static var _mat_cache := {}
static var _tex_cache := {}


# ================================================================== 純邏輯

## 把 Rect2(0,0,dims) 扣掉 holes 之後，用格線切成互不重疊的矩形（面積總和 = 總面積 − 洞面積）。
static func face_rects(dims: Vector2, holes: Array) -> Array:
	var us: Array = [0.0, dims.x]
	var vs: Array = [0.0, dims.y]
	for h: Rect2 in holes:
		us.append(clampf(h.position.x, 0.0, dims.x))
		us.append(clampf(h.end.x, 0.0, dims.x))
		vs.append(clampf(h.position.y, 0.0, dims.y))
		vs.append(clampf(h.end.y, 0.0, dims.y))
	us.sort()
	vs.sort()
	var out: Array = []
	for i in range(us.size() - 1):
		for j in range(vs.size() - 1):
			var w: float = us[i + 1] - us[i]
			var h2: float = vs[j + 1] - vs[j]
			if w <= EPS or h2 <= EPS:
				continue
			var cell := Rect2(us[i], vs[j], w, h2)
			var center := cell.get_center()
			var in_hole := false
			for h: Rect2 in holes:
				if h.has_point(center):
					in_hole = true
					break
			if not in_hole:
				out.append(cell)
	return out


## Godot 的正面是「順時針」：正面法線 = (c − a) × (b − a)。必要時交換 b、c 讓三角形朝向 normal。
static func add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, uva: Vector2, uvb: Vector2, uvc: Vector2, normal: Vector3) -> void:
	if (c - a).cross(b - a).dot(normal) < 0.0:
		var tp := b
		b = c
		c = tp
		var tu := uvb
		uvb = uvc
		uvc = tu
	st.set_normal(normal)
	st.set_uv(uva)
	st.add_vertex(a)
	st.set_normal(normal)
	st.set_uv(uvb)
	st.add_vertex(b)
	st.set_normal(normal)
	st.set_uv(uvc)
	st.add_vertex(c)


static func add_quad(st: SurfaceTool, c: PackedVector3Array, uv: PackedVector2Array, normal: Vector3) -> void:
	add_tri(st, c[0], c[1], c[2], uv[0], uv[1], uv[2], normal)
	add_tri(st, c[0], c[2], c[3], uv[0], uv[2], uv[3], normal)


## 凸多邊形面（扇形切三角形），法線自動朝外（相對 body_center）
static func add_convex_face(st: SurfaceTool, pts: PackedVector3Array, body_center: Vector3) -> void:
	var n := (pts[1] - pts[0]).cross(pts[2] - pts[0]).normalized()
	var centroid := Vector3.ZERO
	for p in pts:
		centroid += p
	centroid /= float(pts.size())
	if n.dot(centroid - body_center) < 0.0:
		n = -n
	for i in range(1, pts.size() - 1):
		add_tri(st, pts[0], pts[i], pts[i + 1], _world_uv(pts[0]), _world_uv(pts[i]), _world_uv(pts[i + 1]), n)


static func _world_uv(p: Vector3) -> Vector2:
	return Vector2(p.x + p.z, p.y) / TILE_M


static func add_box(st: SurfaceTool, mn: Vector3, mx: Vector3) -> void:
	var c := (mn + mx) * 0.5
	var p := [
		Vector3(mn.x, mn.y, mn.z), Vector3(mx.x, mn.y, mn.z), Vector3(mx.x, mn.y, mx.z), Vector3(mn.x, mn.y, mx.z),
		Vector3(mn.x, mx.y, mn.z), Vector3(mx.x, mx.y, mn.z), Vector3(mx.x, mx.y, mx.z), Vector3(mn.x, mx.y, mx.z),
	]
	var faces := [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [3, 2, 6, 7], [0, 3, 7, 4], [1, 2, 6, 5]]
	for f in faces:
		add_convex_face(st, PackedVector3Array([p[f[0]], p[f[1]], p[f[2]], p[f[3]]]), c)


# ================================================================== 材質（程式化主題、Unshaded）

static func face_kind(wall_index: int) -> String:
	if wall_index == 4:
		return "floor"
	if wall_index == 5:
		return "ceiling"
	return "wall"


static func _pattern_texture(base: Color, line: Color, kind: String) -> ImageTexture:
	var key := "%s|%s|%s" % [base.to_html(), line.to_html(), kind]
	if _tex_cache.has(key):
		return _tex_cache[key]
	const N := 64
	const HALF := 32
	var img := Image.create_empty(N, N, false, Image.FORMAT_RGBA8)
	img.fill(base)
	if kind == "floor":
		var dark := base.darkened(0.10)
		for y in range(HALF):
			for x in range(HALF):
				img.set_pixel(x, y, dark)
				img.set_pixel(x + HALF, y + HALF, dark)
	for i in range(N):
		img.set_pixel(i, 0, line)
		img.set_pixel(0, i, line)
	if kind == "wall":
		for x in range(N):
			img.set_pixel(x, HALF, line.lerp(base, 0.6))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


## kind：wall / floor / ceiling / accent（建材與門框用）
static func theme_material(theme_id: String, kind: String) -> StandardMaterial3D:
	var key := "%s|%s" % [theme_id, kind]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var theme: Dictionary = THEMES.get(theme_id, THEMES["default"])
	var color: Color = theme.get(kind, theme["wall"])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _pattern_texture(color, theme["line"], "wall" if kind == "accent" else kind)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_mat_cache[key] = mat
	return mat


static func fog_material() -> StandardMaterial3D:
	if _mat_cache.has("fog"):
		return _mat_cache["fog"]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = FOG_COLOR
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_mat_cache["fog"] = mat
	return mat


# ================================================================== 組裝

static func build_cell(model, cell_id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Cell_" + cell_id
	root.set_meta("cell_id", cell_id)
	populate(root, model, cell_id)
	return root


## 清掉舊內容並重建（Split & Stretch、門框縮放 / 平移之後呼叫）
static func rebuild_cell(root: Node3D, model, cell_id: String) -> void:
	for ch in root.get_children():
		root.remove_child(ch)
		ch.queue_free()
	populate(root, model, cell_id)


static func populate(root: Node3D, model, cell_id: String) -> void:
	var cell = model.cells.get(cell_id)
	if cell == null:
		return
	_build_shell(root, model, cell)
	for sid in cell.structures:
		var s = model.structures.get(sid)
		if s != null:
			_build_structure(root, cell, s)
	for pid in cell.portals:
		var p = model.portals.get(pid)
		if p != null:
			_build_portal_parts(root, cell, p)
	apply_layers(root, cell.render_layer, cell.physics_layer)


## 把視覺層 / 物理層套到整棵子樹（層位 0 = 尚未分配，不改動）
static func apply_layers(node: Node, render_layer: int, physics_layer: int) -> void:
	if node is VisualInstance3D and render_layer > 0:
		node.layers = SM.PalaceModel.layer_bit(render_layer)
	if node is CollisionObject3D and physics_layer > 0:
		node.collision_layer = SM.PalaceModel.layer_bit(physics_layer)
		node.collision_mask = 0
	for ch in node.get_children():
		apply_layers(ch, render_layer, physics_layer)


static func _build_shell(root: Node3D, model, cell) -> void:
	var mesh := ArrayMesh.new()
	var tris := PackedVector3Array()
	for wall in range(6):
		var dims := SM.PalaceModel.plane_dims(cell.size, wall)
		var holes: Array = []
		for pid in cell.portals:
			var p = model.portals.get(pid)
			if p != null and p.wall_index == wall:
				holes.append(SM.PalaceModel.portal_rect(p))
		var rects := face_rects(dims, holes)
		if rects.is_empty():
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var n := SM.PalaceModel.wall_normal(wall)
		for r: Rect2 in rects:
			var p00 := SM.PalaceModel.plane_point(cell.size, wall, r.position.x, r.position.y)
			var p10 := SM.PalaceModel.plane_point(cell.size, wall, r.end.x, r.position.y)
			var p11 := SM.PalaceModel.plane_point(cell.size, wall, r.end.x, r.end.y)
			var p01 := SM.PalaceModel.plane_point(cell.size, wall, r.position.x, r.end.y)
			var uv := PackedVector2Array([
				Vector2(r.position.x, r.position.y) / TILE_M, Vector2(r.end.x, r.position.y) / TILE_M,
				Vector2(r.end.x, r.end.y) / TILE_M, Vector2(r.position.x, r.end.y) / TILE_M,
			])
			add_quad(st, PackedVector3Array([p00, p10, p11, p01]), uv, n)
			tris.append_array(PackedVector3Array([p00, p10, p11, p00, p11, p01]))
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, theme_material(cell.theme_id, face_kind(wall)))

	var shell := MeshInstance3D.new()
	shell.name = "Shell"
	shell.mesh = mesh
	root.add_child(shell)

	if tris.size() > 0:
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(tris)
		var body := StaticBody3D.new()
		body.name = "ShellBody"
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		root.add_child(body)


static func _build_structure(root: Node3D, cell, s) -> void:
	var node := Node3D.new()
	node.name = "Struct_" + s.id
	node.set_meta("structure_id", s.id)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shape: Shape3D
	var shape_pos := Vector3.ZERO

	match s.kind:
		"ramp":
			var pts: PackedVector3Array = s.convex_points()
			var c := Vector3.ZERO
			for p in pts:
				c += p
			c /= float(pts.size())
			add_convex_face(st, PackedVector3Array([pts[0], pts[1], pts[3], pts[2]]), c)   # 底
			add_convex_face(st, PackedVector3Array([pts[0], pts[1], pts[5], pts[4]]), c)   # 斜面
			add_convex_face(st, PackedVector3Array([pts[2], pts[3], pts[5], pts[4]]), c)   # 高端立面
			add_convex_face(st, PackedVector3Array([pts[0], pts[2], pts[4]]), c)           # 側面
			add_convex_face(st, PackedVector3Array([pts[1], pts[3], pts[5]]), c)
			var cv := ConvexPolygonShape3D.new()
			cv.points = pts
			shape = cv
		"platform":
			var mn := Vector3(s.pos.x, s.pos.y - s.thickness, s.pos.z)
			var mx := Vector3(s.pos.x + s.size.x, s.pos.y, s.pos.z + s.size.y)
			add_box(st, mn, mx)
			var bx := BoxShape3D.new()
			bx.size = mx - mn
			shape = bx
			shape_pos = (mn + mx) * 0.5
		"railing":
			var a: Vector3 = s.pos
			var b: Vector3 = s.end_pos()
			var lo := Vector3(minf(a.x, b.x), a.y, minf(a.z, b.z))
			var hi := Vector3(maxf(a.x, b.x), a.y + s.height, maxf(a.z, b.z))
			var t := 0.04
			# 上欄、中欄
			add_box(st, Vector3(lo.x - t, hi.y - 2.0 * t, lo.z - t), Vector3(hi.x + t, hi.y, hi.z + t))
			add_box(st, Vector3(lo.x - t * 0.5, lo.y + s.height * 0.5 - t * 0.5, lo.z - t * 0.5), Vector3(hi.x + t * 0.5, lo.y + s.height * 0.5 + t * 0.5, hi.z + t * 0.5))
			# 立柱：每約 1 m 一根，頭尾必有
			var count := maxi(2, int(ceil(s.length / 1.0)) + 1)
			for i in range(count):
				var k := float(i) / float(count - 1)
				var q := a.lerp(b, k)
				add_box(st, Vector3(q.x - t, lo.y, q.z - t), Vector3(q.x + t, hi.y, q.z + t))
			var rb := BoxShape3D.new()
			var span := hi - lo
			rb.size = Vector3(maxf(span.x, 0.08), s.height, maxf(span.z, 0.08))
			shape = rb
			shape_pos = Vector3((lo.x + hi.x) * 0.5, lo.y + s.height * 0.5, (lo.z + hi.z) * 0.5)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = st.commit()
	mi.material_override = theme_material(cell.theme_id, "accent")
	node.add_child(mi)
	if shape != null:
		var body := StaticBody3D.new()
		body.name = "Body"
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.position = shape_pos
		body.add_child(cs)
		node.add_child(body)
	root.add_child(node)


## 門洞的薄框 + 霧色封板
static func _build_portal_parts(root: Node3D, cell, p) -> void:
	var n: Vector3 = p.normal
	var dims := SM.PalaceModel.plane_dims(cell.size, p.wall_index)
	var rect := SM.PalaceModel.portal_rect(p)

	# 霧色封板（滿版門 = 整面；一般門 = 門洞矩形）
	var plug_st := SurfaceTool.new()
	plug_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p00 := SM.PalaceModel.plane_point(cell.size, p.wall_index, rect.position.x, rect.position.y)
	var p10 := SM.PalaceModel.plane_point(cell.size, p.wall_index, rect.end.x, rect.position.y)
	var p11 := SM.PalaceModel.plane_point(cell.size, p.wall_index, rect.end.x, rect.end.y)
	var p01 := SM.PalaceModel.plane_point(cell.size, p.wall_index, rect.position.x, rect.end.y)
	add_quad(plug_st, PackedVector3Array([p00, p10, p11, p01]), PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]), n)
	var plug := MeshInstance3D.new()
	plug.name = "Plug_" + p.id
	plug.mesh = plug_st.commit()
	plug.material_override = fog_material()
	plug.set_meta("portal_id", p.id)
	root.add_child(plug)

	if p.is_full_wall:
		return

	# 門框：洞口四周的四條薄板（超出牆面的部分裁掉，所以貼地的門沒有下框）
	var frame := Node3D.new()
	frame.name = "Frame_" + p.id
	frame.set_meta("portal_id", p.id)
	var b := FRAME_BORDER
	var strips := [
		Rect2(rect.position.x - b, rect.position.y - b, b, rect.size.y + 2.0 * b),   # 左
		Rect2(rect.end.x, rect.position.y - b, b, rect.size.y + 2.0 * b),             # 右
		Rect2(rect.position.x, rect.end.y, rect.size.x, b),                           # 上
		Rect2(rect.position.x, rect.position.y - b, rect.size.x, b),                  # 下
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for r: Rect2 in strips:
		var clipped := r.intersection(Rect2(Vector2.ZERO, dims))
		if clipped.size.x <= EPS or clipped.size.y <= EPS:
			continue
		var a := SM.PalaceModel.plane_point(cell.size, p.wall_index, clipped.position.x, clipped.position.y)
		var c := SM.PalaceModel.plane_point(cell.size, p.wall_index, clipped.end.x, clipped.end.y) + n * FRAME_DEPTH
		add_box(st, Vector3(minf(a.x, c.x), minf(a.y, c.y), minf(a.z, c.z)), Vector3(maxf(a.x, c.x), maxf(a.y, c.y), maxf(a.z, c.z)))
		any = true
	if any:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = st.commit()
		mi.material_override = theme_material(cell.theme_id, "accent")
		frame.add_child(mi)
		root.add_child(frame)
	else:
		frame.free()


# ================================================================== 傳送門表面用的區域網格（供 portal_system 使用）

## 朝 +Z 的平面（門框區域座標，XY 平面），尺寸 size
static func make_quad_mesh(size: Vector2) -> ArrayMesh:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_quad(st, PackedVector3Array([Vector3(-hx, -hy, 0), Vector3(hx, -hy, 0), Vector3(hx, hy, 0), Vector3(-hx, hy, 0)]),
		PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]), Vector3.BACK)
	return st.commit()


## 向門內（-Z）凹陷 depth 的無蓋 U 型盒：背板 + 四面側壁，面朝盒內。
static func make_recess_box_mesh(size: Vector2, depth: float) -> ArrayMesh:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var z := -depth
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var uv := PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN])
	add_quad(st, PackedVector3Array([Vector3(-hx, -hy, z), Vector3(hx, -hy, z), Vector3(hx, hy, z), Vector3(-hx, hy, z)]), uv, Vector3.BACK)
	add_quad(st, PackedVector3Array([Vector3(-hx, -hy, 0), Vector3(-hx, -hy, z), Vector3(-hx, hy, z), Vector3(-hx, hy, 0)]), uv, Vector3.RIGHT)
	add_quad(st, PackedVector3Array([Vector3(hx, -hy, 0), Vector3(hx, -hy, z), Vector3(hx, hy, z), Vector3(hx, hy, 0)]), uv, Vector3.LEFT)
	add_quad(st, PackedVector3Array([Vector3(-hx, hy, 0), Vector3(hx, hy, 0), Vector3(hx, hy, z), Vector3(-hx, hy, z)]), uv, Vector3.DOWN)
	add_quad(st, PackedVector3Array([Vector3(-hx, -hy, 0), Vector3(hx, -hy, 0), Vector3(hx, -hy, z), Vector3(-hx, -hy, z)]), uv, Vector3.UP)
	return st.commit()


# ================================================================== 線框佔位符、切割面預覽

## 尚未匯入資源的記憶物件：以線框方塊（以原點為中心）顯示
static func make_wire_box(size: Vector3, color: Color = Color(0.95, 0.85, 0.45)) -> MeshInstance3D:
	var h := size * 0.5
	var c := PackedVector3Array([
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	])
	var edges := [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(c[e[0]])
		verts.append(c[e[1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	var mi := MeshInstance3D.new()
	mi.name = "WireBox"
	mi.mesh = mesh
	mi.material_override = mat
	return mi


## Split & Stretch 的切割面預覽：垂直於 axis 的半透明面 + 邊框線，位於 axis 座標 = cut
static func make_cut_preview(cell_size: Vector3, axis: int, cut: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "CutPreview"
	mi.mesh = _cut_preview_mesh(cell_size, axis, cut)
	return mi


static func update_cut_preview(mi: MeshInstance3D, cell_size: Vector3, axis: int, cut: float) -> void:
	mi.mesh = _cut_preview_mesh(cell_size, axis, cut)


static func _cut_preview_mesh(cell_size: Vector3, axis: int, cut: float) -> ArrayMesh:
	var c: PackedVector3Array
	if axis == SM.PalaceModel.AXIS_X:
		c = PackedVector3Array([Vector3(cut, 0, 0), Vector3(cut, 0, cell_size.z), Vector3(cut, cell_size.y, cell_size.z), Vector3(cut, cell_size.y, 0)])
	else:
		c = PackedVector3Array([Vector3(0, 0, cut), Vector3(cell_size.x, 0, cut), Vector3(cell_size.x, cell_size.y, cut), Vector3(0, cell_size.y, cut)])
	var mesh := ArrayMesh.new()

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([c[0], c[1], c[2], c[0], c[2], c[3]])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var fill := StandardMaterial3D.new()
	fill.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill.albedo_color = Color(0.30, 0.80, 1.0, 0.32)
	fill.cull_mode = BaseMaterial3D.CULL_DISABLED
	fill.render_priority = 10
	mesh.surface_set_material(0, fill)

	var lines := []
	lines.resize(Mesh.ARRAY_MAX)
	lines[Mesh.ARRAY_VERTEX] = PackedVector3Array([c[0], c[1], c[1], c[2], c[2], c[3], c[3], c[0]])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, lines)
	var edge := StandardMaterial3D.new()
	edge.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge.albedo_color = Color(0.55, 0.92, 1.0, 1.0)
	edge.render_priority = 11
	mesh.surface_set_material(1, edge)
	return mesh
