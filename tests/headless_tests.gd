extends SceneTree
## tests/headless_tests.gd — 純邏輯無頭測試（不需要 GPU、場景或匯入快取）
## 執行：godot --headless --path . --script res://tests/headless_tests.gd
## 全部通過時輸出一行「RESULT: PASS」並以 exit code 0 結束，否則 exit code 1。

const SM = preload("res://scripts/space_model.gd")
const ST = preload("res://scripts/storage.gd")
const RB = preload("res://scripts/room_builder.gd")
const PS = preload("res://scripts/portal_system.gd")
const PC = preload("res://scripts/player_controller.gd")
const MV = preload("res://scripts/memory_node_view.gd")
const FS = preload("res://scripts/font_setup.gd")

var _checks := 0
var _failures := 0


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("  FAIL: %s" % msg)


func near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps


func near_v3(a: Vector3, b: Vector3, eps: float = 1e-4) -> bool:
	return (a - b).length() <= eps


func _init() -> void:
	_run()


func _run() -> void:
	test_split_and_stretch()
	test_stretch_z_axis()
	test_portal_placement()
	test_layer_allocation()
	test_deletions()
	test_structure_adjust()
	test_font_setup()
	test_portal_matrix()
	test_hashing_and_assets()
	test_import_sources()
	test_save_store()
	test_backup()
	test_settings()
	test_room_builder_logic()
	test_portal_system_logic()
	test_memory_loaders()
	test_memory_views()
	test_player_logic()
	await test_player_physics()
	await test_player_stairs()
	await test_player_step_up()
	await test_main_scene()
	print("checks=%d failures=%d" % [_checks, _failures])
	var ok := _failures == 0
	print("RESULT: PASS" if ok else "RESULT: FAIL")
	quit(0 if ok else 1)


# ------------------------------------------------------------------ 共用輔助

func _place(m, cell_id: String, wall: int, pos: Vector3, size: Vector2 = Vector2.ZERO, snap_floor: bool = false):
	var r: Dictionary = m.place_portal(cell_id, wall, pos, size, false, snap_floor)
	check(r["ok"], "放置傳送門（牆 %d）應成功：%s" % [wall, str(r.get("error", ""))])
	return r.get("portal")


## 同一平面上的門不可重疊，也不可超出該平面
func _portals_valid(m) -> bool:
	for cid in m.cells:
		var c = m.cells[cid]
		var by_wall := {}
		for pid in c.portals:
			var p = m.portals[pid]
			var rect: Rect2 = SM.PalaceModel.portal_rect(p)
			var dims: Vector2 = SM.PalaceModel.plane_dims(c.size, p.wall_index)
			if rect.position.x < -1e-4 or rect.position.y < -1e-4 or rect.end.x > dims.x + 1e-4 or rect.end.y > dims.y + 1e-4:
				return false
			if not by_wall.has(p.wall_index):
				by_wall[p.wall_index] = []
			for other: Rect2 in by_wall[p.wall_index]:
				if rect.intersects(other, false):
					return false
			by_wall[p.wall_index].append(rect)
	return true


# ------------------------------------------------------------------ (1) Split & Stretch：X 軸

func test_split_and_stretch() -> void:
	print("[1] Split & Stretch（X 軸）：建材與六向傳送門")
	var m = SM.PalaceModel.new()
	var c = m.create_cell("主廳", "ivory", Vector3(10, 3, 6))
	var X: int = SM.PalaceModel.AXIS_X
	var cut := 5.0
	var delta := 4.0

	# 建材：斜坡
	var r_neg = m.add_ramp(c.id, Vector3(2, 0, 1), Vector3.RIGHT, 1.0, 2.0, 1.0)            # [2,4] 負側
	var r_pos = m.add_ramp(c.id, Vector3(6, 0, 1), Vector3.RIGHT, 1.0, 2.0, 1.0)            # [6,8] 正側
	var r_line = m.add_ramp(c.id, Vector3(5, 0, 3), Vector3.RIGHT, 1.0, 2.0, 1.0)           # [5,7] 壓線
	var r_cross = m.add_ramp(c.id, Vector3(3, 0, 5), Vector3.RIGHT, 1.0, 4.0, 1.0)          # [3,7] 穿過
	var r_negdir = m.add_ramp(c.id, Vector3(7, 0, 4.2), Vector3.LEFT, 1.0, 4.0, 1.0)        # 朝 -X：[3,7] 穿過
	var r_across = m.add_ramp(c.id, Vector3(5.3, 0, 0.5), Vector3.BACK, 1.0, 2.0, 1.0)      # 沿 Z；寬度方向 x∈[4.8,5.8] 穿過
	# 建材：二樓地板平台
	var plat_neg = m.add_platform(c.id, Vector3(1, 2.5, 1), Vector2(3, 2))                  # [1,4]
	var plat_cross = m.add_platform(c.id, Vector3(4, 2.5, 1), Vector2(4, 2))                # [4,8] 穿過
	var plat_pos = m.add_platform(c.id, Vector3(6, 2.5, 3), Vector2(3, 2))                  # [6,9]
	var plat_line = m.add_platform(c.id, Vector3(5, 2.5, 3), Vector2(2, 2))                 # [5,7] 壓線
	var plat_touch = m.add_platform(c.id, Vector3(1, 2.5, 4), Vector2(4, 1))                # [1,5] 終點恰在切割線 → 負側
	# 建材：欄桿
	var rail_cross = m.add_railing(c.id, Vector3(3, 0, 0.2), Vector3.RIGHT, 4.0)            # [3,7] 穿過
	var rail_negdir = m.add_railing(c.id, Vector3(9, 0, 5), Vector3.LEFT, 6.0)              # [3,9] 穿過
	var rail_perp_neg = m.add_railing(c.id, Vector3(4, 0, 1), Vector3.BACK, 2.0)            # 垂直於切割軸，x=4
	var rail_perp_pos = m.add_railing(c.id, Vector3(6, 0, 1), Vector3.BACK, 2.0)            # x=6
	var rail_perp_line = m.add_railing(c.id, Vector3(5, 0, 1), Vector3.BACK, 2.0)           # x=5 壓線

	# 傳送門（六向）
	var big := Vector2(1.2, 2.4)
	var p_neg = _place(m, c.id, 2, Vector3(2, 1.2, 0), big)
	var p_line = _place(m, c.id, 2, Vector3(5, 1.2, 0), big)
	var p_pos = _place(m, c.id, 3, Vector3(7, 1.2, 6), big)
	var p_wall1 = _place(m, c.id, 1, Vector3(10, 1.2, 2), big)
	var h_neg = _place(m, c.id, 4, Vector3(3, 0, 2))
	var h_pos = _place(m, c.id, 4, Vector3(7, 0, 2))
	var h_c1 = _place(m, c.id, 4, Vector3(4.8, 0, 4))      # 範圍橫跨切割線，但中心在負側
	var h_c2 = _place(m, c.id, 4, Vector3(5.2, 0, 5))      # 範圍橫跨切割線，中心在正側
	var ceil_wide = _place(m, c.id, 5, Vector3(3, 3, 2), Vector2(2, 1))
	var full0 = m.place_portal(c.id, 0, Vector3.ZERO, Vector2.ZERO, true)
	check(full0["ok"], "-X 牆滿版門")
	var p_full0 = full0["portal"]

	# 記憶物件
	var n1 = m.add_memory_node(c.id, "", "", Vector3(1, 1, 1))
	var n2 = m.add_memory_node(c.id, "", "", Vector3(5, 1, 2))
	var n3 = m.add_memory_node(c.id, "", "", Vector3(9, 1, 4.5))
	check(m.validate().is_empty(), "建立後 validate() 應為空")
	check(_portals_valid(m), "建立後所有門互不重疊、不超出平面")
	var gap_before: float = n3.pos.x - n1.pos.x
	var slope_before: float = r_cross.slope_angle_deg()

	var res: Dictionary = m.split_and_stretch(c.id, X, cut, delta)
	check(res["ok"], "X 軸拉長應成功")
	check(near(c.size.x, 14.0, 1e-6), "size.x = 10 + 4 = 14（實得 %f）" % c.size.x)
	check(near(c.size.y, 3.0, 1e-6) and near(c.size.z, 6.0, 1e-6), "其餘兩軸長度不變")

	# 斜坡
	check(near_v3(r_neg.pos, Vector3(2, 0, 1), 1e-6) and near(r_neg.length, 2.0), "負側斜坡不動")
	check(near_v3(r_pos.pos, Vector3(10, 0, 1), 1e-6) and near(r_pos.length, 2.0), "正側斜坡整體平移 +4")
	check(near_v3(r_line.pos, Vector3(9, 0, 3), 1e-6), "壓線斜坡視為正側，整體平移 +4")
	check(near_v3(r_cross.pos, Vector3(3, 0, 5), 1e-6) and near(r_cross.length, 8.0), "穿過的斜坡：起點不動、水平跨度 4→8")
	check(near(r_cross.height, 1.0), "穿過的斜坡：高度不變")
	check(r_cross.slope_angle_deg() < slope_before and near(r_cross.slope_angle_deg(), rad_to_deg(atan(1.0 / 8.0)), 0.01), "穿過的斜坡：坡度變緩為 atan(1/8)")
	check(near(r_negdir.pos.x, 11.0, 1e-6) and near(r_negdir.length, 8.0), "朝 -X 的穿過斜坡：高端(起點)平移、跨度 4→8，低端 x=3 不動")
	check(near(r_across.width, 5.0, 1e-6) and near(r_across.pos.x, 7.3, 1e-5) and near(r_across.length, 2.0), "橫向被切開的斜坡：寬度 1→5、低側 x=4.8 不動")
	check(near(r_across.span(X).x, 4.8, 1e-5) and near(r_across.span(X).y, 9.8, 1e-5), "橫向被切開的斜坡：範圍 [4.8, 9.8]")
	# 平台
	check(near_v3(plat_neg.pos, Vector3(1, 2.5, 1), 1e-6) and near(plat_neg.size.x, 3.0), "負側平台不動")
	check(near(plat_cross.pos.x, 4.0, 1e-6) and near(plat_cross.size.x, 8.0, 1e-6) and near(plat_cross.size.y, 2.0), "穿過的平台：x 長度 4→8，z 不變")
	check(near(plat_pos.pos.x, 10.0, 1e-6) and near(plat_pos.size.x, 3.0), "正側平台整體平移")
	check(near(plat_line.pos.x, 9.0, 1e-6), "壓線平台整體平移")
	check(near(plat_touch.pos.x, 1.0, 1e-6) and near(plat_touch.size.x, 4.0), "終點恰在切割線上的平台視為負側，不動")
	# 欄桿
	check(near(rail_cross.pos.x, 3.0, 1e-6) and near(rail_cross.length, 8.0, 1e-6), "穿過的欄桿：長度 4→8")
	check(near(rail_negdir.pos.x, 13.0, 1e-6) and near(rail_negdir.length, 10.0, 1e-6), "朝 -X 的穿過欄桿：起點平移、長度 6→10，低端 x=3 不動")
	check(near(rail_perp_neg.pos.x, 4.0, 1e-6), "垂直欄桿在負側：不動")
	check(near(rail_perp_pos.pos.x, 10.0, 1e-6) and near(rail_perp_line.pos.x, 9.0, 1e-6), "垂直欄桿在正側 / 壓線：整體平移")
	check(res["shifted"]["structures_stretched"] == 6 and res["shifted"]["structures_shifted"] == 6, "建材：拉長 6 個、平移 6 個")

	# 傳送門：依中心點
	check(near_v3(p_neg.local_pos, Vector3(2, 1.2, 0), 1e-5), "負側牆門不動")
	check(near_v3(p_line.local_pos, Vector3(9, 1.2, 0), 1e-5), "壓線牆門平移")
	check(near_v3(p_pos.local_pos, Vector3(11, 1.2, 6), 1e-5), "正側牆門平移")
	check(near_v3(p_wall1.local_pos, Vector3(14, 1.2, 2), 1e-5), "+X 牆上的門隨牆移到 x=14")
	check(near_v3(h_neg.local_pos, Vector3(3, 0, 2), 1e-5), "負側地板開口不動")
	check(near_v3(h_pos.local_pos, Vector3(11, 0, 2), 1e-5), "正側地板開口平移")
	check(near_v3(h_c1.local_pos, Vector3(4.8, 0, 4), 1e-5), "範圍橫跨切割線但中心在負側的開口：不動")
	check(near_v3(h_c2.local_pos, Vector3(9.2, 0, 5), 1e-5), "範圍橫跨切割線但中心在正側的開口：整體平移")
	check(near_v3(ceil_wide.local_pos, Vector3(3, 3, 2), 1e-5), "負側天花板開口不動")
	check(near(p_full0.size.x, 6.0, 1e-6), "-X 牆滿版門寬度不變")
	check(res["shifted"]["portals"] == 5, "平移的非滿版門共 5 個（實得 %d）" % res["shifted"]["portals"])
	check(_portals_valid(m), "拉長後所有門仍互不重疊、不超出平面")

	# 記憶物件
	check(near_v3(n1.pos, Vector3(1, 1, 1), 1e-6), "負側記憶物件不動")
	check(near_v3(n2.pos, Vector3(9, 1, 2), 1e-6) and near_v3(n3.pos, Vector3(13, 1, 4.5), 1e-6), "壓線 / 正側記憶物件平移")
	check(near((n3.pos.x - n1.pos.x) - gap_before, 4.0, 1e-6), "跨線物件間距恰好增加 delta")
	check(m.validate().is_empty(), "拉長後 validate() 應為空")

	# 非法輸入不得改動資料
	var before: Vector3 = c.size
	check(not m.split_and_stretch(c.id, X, 0.0, 1.0)["ok"], "cut=0 應被拒絕")
	check(not m.split_and_stretch(c.id, X, 3.0, -1.0)["ok"], "delta<0 應被拒絕")
	check(not m.split_and_stretch(c.id, X, 99.0, 1.0)["ok"], "cut 超出房間應被拒絕")
	check(not m.split_and_stretch(c.id, 5, 3.0, 1.0)["ok"], "未知軸應被拒絕")
	check(not m.split_and_stretch("nope", X, 3.0, 1.0)["ok"], "未知房間應被拒絕")
	check(near_v3(c.size, before, 1e-6), "被拒絕的操作不改變房間尺寸")

	# 在 +X 牆正上方切割（cut = size.x）等同於在尾端延伸
	var tail_before: float = p_wall1.local_pos.x
	res = m.split_and_stretch(c.id, X, c.size.x, 2.0)
	check(res["ok"] and near(p_wall1.local_pos.x, tail_before + 2.0, 1e-5), "cut=size.x：+X 牆門框跟著牆移動")


# ------------------------------------------------------------------ (1) Split & Stretch：Z 軸

func test_stretch_z_axis() -> void:
	print("[1b] Split & Stretch（Z 軸）")
	var m = SM.PalaceModel.new()
	var c = m.create_cell("側廳", "t", Vector3(10, 3, 6))
	var Z: int = SM.PalaceModel.AXIS_Z
	var r_neg = m.add_ramp(c.id, Vector3(2, 0, 1), Vector3.BACK, 1.0, 0.8, 0.5)          # 沿 Z：[1,1.8] 負側
	var r_cross = m.add_ramp(c.id, Vector3(2, 0, 0.5), Vector3.BACK, 1.0, 2.0, 1.0)      # [0.5,2.5] 穿過 cut=2
	var r_pos = m.add_ramp(c.id, Vector3(4, 0, 3), Vector3.BACK, 1.0, 2.0, 1.0)          # [3,5] 正側
	var plat_cross = m.add_platform(c.id, Vector3(1, 2.5, 1), Vector2(3, 2))             # z∈[1,3] 穿過
	var rail = m.add_railing(c.id, Vector3(8, 0, 1), Vector3.BACK, 3.0)                  # z∈[1,4] 穿過
	var rail_perp = m.add_railing(c.id, Vector3(6, 0, 4), Vector3.RIGHT, 2.0)            # 沿 X，z=4 → 正側
	var wall3 = _place(m, c.id, 3, Vector3(5, 1.1, 6))
	var wall0 = _place(m, c.id, 0, Vector3(0, 1.1, 1))                                   # 中心 z=1 負側
	var wall1 = _place(m, c.id, 1, Vector3(10, 1.1, 4))                                  # 中心 z=4 正側
	var floor_p = _place(m, c.id, 4, Vector3(3, 0, 2))                                   # 中心 z=2 壓線
	var full_c = m.place_portal(c.id, 5, Vector3.ZERO, Vector2.ZERO, true)["portal"]
	var n1 = m.add_memory_node(c.id, "", "", Vector3(1, 1, 1))
	var n2 = m.add_memory_node(c.id, "", "", Vector3(1, 1, 2))

	var res: Dictionary = m.split_and_stretch(c.id, Z, 2.0, 1.5)
	check(res["ok"], "Z 軸拉長應成功")
	check(near(c.size.z, 7.5, 1e-6) and near(c.size.x, 10.0, 1e-6), "size.z = 6 + 1.5，size.x 不變")
	check(near(r_neg.pos.z, 1.0, 1e-6), "Z：負側斜坡不動")
	check(near(r_cross.pos.z, 0.5, 1e-6) and near(r_cross.length, 3.5, 1e-6) and near(r_cross.height, 1.0), "Z：穿過的斜坡 length 2→3.5，高度不變")
	check(near(r_pos.pos.z, 4.5, 1e-6), "Z：正側斜坡平移 +1.5")
	check(near(plat_cross.size.y, 3.5, 1e-6) and near(plat_cross.size.x, 3.0, 1e-6) and near(plat_cross.pos.z, 1.0, 1e-6), "Z：穿過的平台 z 長度 2→3.5")
	check(near(rail.length, 4.5, 1e-6) and near(rail.pos.z, 1.0, 1e-6), "Z：穿過的欄桿 3→4.5")
	check(near(rail_perp.pos.z, 5.5, 1e-6), "Z：沿 X 的欄桿在正側，平移 +1.5")
	check(near(wall3.local_pos.z, 7.5, 1e-5), "Z：+Z 牆上的門隨牆移到 z=7.5")
	check(near(wall0.local_pos.z, 1.0, 1e-5), "Z：中心在負側的 -X 牆門不動")
	check(near(wall1.local_pos.z, 5.5, 1e-5), "Z：中心在正側的 +X 牆門平移")
	check(near(floor_p.local_pos.z, 3.5, 1e-5), "Z：中心壓線的地板開口平移")
	check(near(full_c.size.x, 10.0) and near(full_c.size.y, 7.5) and near(full_c.local_pos.z, 3.75, 1e-5), "Z：天花板滿版門重新貼合 10×7.5")
	check(near(n1.pos.z, 1.0, 1e-6) and near(n2.pos.z, 3.5, 1e-6), "Z：記憶物件依位置平移")
	check(_portals_valid(m) and m.validate().is_empty(), "Z：拉長後資料一致")


# ------------------------------------------------------------------ 傳送門放置 / 縮放 / 平移

func test_portal_placement() -> void:
	print("[1c] 傳送門：中心錨定縮放、雙端邊界、平移")
	var m = SM.PalaceModel.new()
	var c = m.create_cell("廳", "t", Vector3(10, 3, 6))

	var a = _place(m, c.id, 2, Vector3(5, 1.1, 0))
	check(near(a.size.x, 1.2) and near(a.size.y, 2.2), "牆面門預設 1.2×2.2")
	var center_before: Vector3 = a.local_pos
	var r: Dictionary = m.resize_portal(a.id, Vector2(3.0, 2.2))
	check(r["ok"] and near(a.size.x, 3.0), "對稱放大寬度到 3.0")
	check(near_v3(a.local_pos, center_before, 1e-6), "縮放以中心為錨點，中心不動")

	var b = _place(m, c.id, 2, Vector3(7.0, 1.1, 0))
	check(near(b.size.x, 1.0), "放置時右側門在 6.5 處擋住：寬度被限制為 1.0（實得 %f）" % b.size.x)
	var rb: Dictionary = m.place_portal(c.id, 0, Vector3(0, 1.1, 3.0), Vector2(1.0, 2.2))
	check(rb["ok"] and not rb["limited_u"], "不受阻擋時不標記 limited")

	r = m.resize_portal(a.id, Vector2(10.0, 2.2))
	check(r["ok"] and r["limited_u"] and r["reason_u"] == "portal" and near(a.size.x, 3.0), "放大到 10：被相鄰門限制在 3.0，原因 portal")
	r = m.resize_portal(a.id, Vector2(3.0, 5.0))
	check(r["ok"] and r["limited_v"] and r["reason_v"] == "wall" and near(a.size.y, 2.2), "放大高度到 5：被地板限制在 2.2（中心高 1.1），原因 wall")
	check(near_v3(a.local_pos, center_before, 1e-6), "多次縮放後中心仍不動")
	r = m.resize_portal(a.id, Vector2(1.0, 1.0))
	check(r["ok"] and near(a.size.x, 1.0) and near(a.size.y, 1.0), "可縮小")

	var corner = _place(m, c.id, 3, Vector3(0.4, 1.1, 6))
	check(near(corner.size.x, 0.8), "靠近牆角放置：寬度被牆角限制為 0.8（實得 %f）" % corner.size.x)
	var rc: Dictionary = m.place_portal(c.id, 3, Vector3(0.4, 1.1, 6))
	check(not rc["ok"] and rc["error"] == "overlaps_portal", "中心落在既有門內 → overlaps_portal")
	check(not m.place_portal(c.id, 2, Vector3(0.1, 1.1, 0))["ok"], "距牆角太近（寬 < 0.3）→ no_room")
	check(m.place_portal(c.id, 2, Vector3(0.1, 1.1, 0))["error"] == "no_room", "錯誤碼為 no_room")
	check(m.place_portal(c.id, 2, Vector3(-1, 1.1, 0))["error"] == "out_of_wall", "牆外座標 → out_of_wall")
	check(m.place_portal(c.id, 2, Vector3(10.5, 1.1, 0))["error"] == "out_of_wall", "牆外座標（右側）→ out_of_wall")
	check(m.place_portal(c.id, 7, Vector3.ZERO)["error"] == "bad_wall", "不存在的牆 → bad_wall")

	# 平移
	var mv: Dictionary = m.move_portal(b.id, Vector3(9.9, 1.1, 0))
	check(mv["ok"] and mv["limited"], "平移超出牆面：滑到邊界並標記 limited")
	check(near(b.local_pos.x, 9.5, 1e-5) or near(b.local_pos.x, 10.0 - b.size.x * 0.5, 1e-5), "平移後門緊貼右牆")
	var pos_before: Vector3 = b.local_pos
	mv = m.move_portal(b.id, Vector3(5.0, 1.1, 0))
	check(not mv["ok"] and mv["error"] == "overlaps_portal", "平移到與其他門重疊 → 拒絕")
	check(near_v3(b.local_pos, pos_before, 1e-6), "被拒絕的平移不改動位置")
	mv = m.move_portal(b.id, Vector3(7.0, 1.4, 0))
	check(mv["ok"] and not mv["limited"] and near(b.local_pos.y, 1.4, 1e-5), "合法平移（含高度）成功")
	check(near(b.local_pos.z, 0.0), "平移後仍貼在牆平面上")

	# 貼地
	var snapped = _place(m, c.id, 1, Vector3(10, 1.7, 3), Vector2(1.2, 2.2), true)
	check(near(snapped.local_pos.y, 1.1, 1e-5) and near(snapped.local_pos.y - snapped.size.y * 0.5, 0.0, 1e-5), "snap_floor：門底貼地")

	# 水平開口
	var h = _place(m, c.id, 4, Vector3(3, 0, 2))
	check(near(h.size.x, 1.0) and near(h.size.y, 1.0), "水平開口預設 1×1")
	check(near_v3(h.normal, Vector3.UP) and near(h.local_pos.y, 0.0), "地板開口法線向上、位於 y=0")
	r = m.resize_portal(h.id, Vector2(2.0, 3.0))
	check(r["ok"] and near(h.size.x, 2.0) and near(h.size.y, 3.0) and not r["limited_v"], "水平開口自訂寬長 2×3")
	r = m.resize_portal(h.id, Vector2(2.0, 6.0))
	check(r["ok"] and r["limited_v"] and near(h.size.y, 4.0), "水平開口長度被牆限制：中心 z=2 → 最長 4")
	var ceil_p = _place(m, c.id, 5, Vector3(3, 3, 2))
	check(near_v3(ceil_p.normal, Vector3.DOWN) and near(ceil_p.local_pos.y, 3.0), "天花板開口法線向下、位於 y=size.y")

	# 滿版
	var fresh = m.create_cell("空房", "t", Vector3(6, 3, 6))
	var fw: Dictionary = m.place_portal(fresh.id, 0, Vector3.ZERO, Vector2.ZERO, true)
	check(fw["ok"] and near(fw["portal"].size.x, 6.0) and near(fw["portal"].size.y, 3.0), "空平面可放滿版門")
	check(not m.resize_portal(fw["portal"].id, Vector2(2, 2))["ok"], "滿版門不可縮放")
	check(not m.move_portal(fw["portal"].id, Vector3(0, 1, 1))["ok"], "滿版門不可平移")
	check(m.place_portal(fresh.id, 0, Vector3(0, 1.1, 3))["error"] == "overlaps_portal", "滿版門的平面不能再放其他門")
	check(m.place_portal(c.id, 2, Vector3.ZERO, Vector2.ZERO, true)["error"] == "plane_not_empty", "已有門的平面不能放滿版門")
	check(_portals_valid(m), "整體仍互不重疊")


# ------------------------------------------------------------------ 層位分配

func test_layer_allocation() -> void:
	print("[1d] 視覺層 / 物理層分配與回收")
	var m = SM.PalaceModel.new()
	var ids: Array = []
	for i in range(22):
		ids.append(m.create_cell("房%d" % i, "t", Vector3(4, 3, 4)).id)
	var seen := {}
	for i in range(20):
		var r: Dictionary = m.activate_cell(ids[i])
		check(r["ok"] and r["evicted"] == "", "前 20 間房不應有回收")
		seen[r["render_layer"]] = true
	check(seen.size() == 20 and seen.has(1) and seen.has(20), "20 間房取得 1~20 不重複的層位")
	check(m.activate_cell(ids[0])["render_layer"] == 1, "重複啟用回傳同一層位")

	var dist := {}
	for i in range(20):
		dist[ids[i]] = float(i)
	dist[ids[7]] = 99.0   # 最遠
	var victim_layer: int = m.cells[ids[7]].render_layer
	var r2: Dictionary = m.activate_cell(ids[20], dist)
	check(r2["ok"] and r2["evicted"] == ids[7], "第 21 間房回收距離最遠的房間")
	check(r2["render_layer"] == victim_layer, "沿用被回收房間的層位")
	check(m.cells[ids[7]].render_layer == 0 and m.cells[ids[7]].physics_layer == 0, "被回收房間的層位歸零")

	dist = {}
	for cid in m.cells:
		dist[cid] = 1.0
	dist[ids[3]] = 50.0
	dist[ids[4]] = 40.0
	var r3: Dictionary = m.activate_cell(ids[21], dist, [ids[3]])
	check(r3["ok"] and r3["evicted"] == ids[4], "pinned 房間不被回收")

	m.release_cell(ids[21])
	check(m.cells[ids[21]].render_layer == 0, "release_cell 歸還層位")
	check(SM.PalaceModel.layer_bit(1) == 1 and SM.PalaceModel.layer_bit(20) == (1 << 19) and SM.PalaceModel.layer_bit(0) == 0, "layer_bit 位元遮罩")

	# 鄰近房間（沿已配對的門走）
	var n = SM.PalaceModel.new()
	var a = n.create_cell("A", "t", Vector3(8, 3, 5))
	var b = n.create_cell("B", "t", Vector3(8, 3, 5))
	var cc = n.create_cell("C", "t", Vector3(8, 3, 5))
	var d = n.create_cell("D", "t", Vector3(8, 3, 5))
	var pa = _place(n, a.id, 1, Vector3(8, 1.1, 2))
	var pb1 = _place(n, b.id, 0, Vector3(0, 1.1, 2))
	var pb2 = _place(n, b.id, 1, Vector3(8, 1.1, 2))
	var pc1 = _place(n, cc.id, 0, Vector3(0, 1.1, 2))
	var pc2 = _place(n, cc.id, 1, Vector3(8, 1.1, 2))
	var pd = _place(n, d.id, 0, Vector3(0, 1.1, 2))
	n.link_portals(pa.id, pb1.id)
	n.link_portals(pb2.id, pc1.id)
	n.link_portals(pc2.id, pd.id)
	var near2: Array = n.neighbor_cells(a.id, 2)
	check(near2.has(a.id) and near2.has(b.id) and near2.has(cc.id) and not near2.has(d.id), "neighbor_cells(depth=2)：A、B、C，不含 D")
	check(n.neighbor_cells(a.id, 1).size() == 2, "neighbor_cells(depth=1)：A、B")
	check(n.neighbor_cells(a.id, 3).has(d.id), "neighbor_cells(depth=3) 含 D")


# ------------------------------------------------------------------ (2) 傳送門矩陣

func _wall_point(size: Vector3, w: int) -> Vector3:
	match w:
		0:
			return Vector3(0.0, 1.2, 1.7)
		1:
			return Vector3(size.x, 1.2, 2.1)
		2:
			return Vector3(3.3, 1.2, 0.0)
		3:
			return Vector3(2.9, 1.2, size.z)
		4:
			return Vector3(3.3, 0.0, 2.1)
		_:
			return Vector3(2.9, size.y, 1.7)


func _check_pair_math(pa, pb, label: String) -> float:
	var m_ab: Transform3D = SM.Portal.teleport_between(pa, pb)
	var m_ba: Transform3D = SM.Portal.teleport_between(pb, pa)
	var err: float = SM.Portal.transform_distance(m_ba * m_ab, Transform3D.IDENTITY)
	check(err < 1e-5, "%s：‖M_BA·M_AB − I‖ = %s 應 < 1e-5" % [label, String.num_scientific(err)])
	check(near(m_ab.basis.determinant(), 1.0, 1e-5), "%s：矩陣保持手性（det=1）" % label)
	check(near_v3(m_ab * pa.local_pos, pb.local_pos, 1e-4), "%s：門中心對應門中心" % label)
	check(near_v3(m_ab.basis * pa.normal, -pb.normal, 1e-5), "%s：法線反向對接" % label)
	var crossed: Vector3 = pa.local_pos - pa.normal * 0.3   # 剛穿過 A 門 0.3 m
	check(near_v3(m_ab * crossed, pb.local_pos + pb.normal * 0.3, 1e-4), "%s：穿越後出現在 B 門前 0.3 m" % label)
	check(near_v3(m_ab.basis * Vector3.UP, Vector3.UP, 1e-5), "%s：穿越後『上』方向不變" % label)
	return err


func test_portal_matrix() -> void:
	print("[2] 六向傳送門配對與矩陣可逆性")
	var worst := 0.0
	var names := ["-X牆", "+X牆", "-Z牆", "+Z牆", "地板", "天花板"]
	var psize := Vector2(1.2, 2.4)
	# 垂直牆面：4×4 全組合
	for wa in range(4):
		for wb in range(4):
			var m = SM.PalaceModel.new()
			var a = m.create_cell("A", "t", Vector3(8, 3, 5))
			var b = m.create_cell("B", "t", Vector3(6, 3, 9))
			var pa = _place(m, a.id, wa, _wall_point(a.size, wa), psize)
			var pb = _place(m, b.id, wb, _wall_point(b.size, wb), psize)
			worst = maxf(worst, _check_pair_math(pa, pb, "%s→%s" % [names[wa], names[wb]]))
			check(m.link_portals(pa.id, pb.id)["ok"], "%s→%s 可配對" % [names[wa], names[wb]])
	# 水平開口：地板 ↔ 天花板（兩種方向）
	for pair in [[4, 5], [5, 4]]:
		var m = SM.PalaceModel.new()
		var a = m.create_cell("下層", "t", Vector3(8, 3, 5))
		var b = m.create_cell("上層", "t", Vector3(6, 3, 9))
		var pa = _place(m, a.id, pair[0], _wall_point(a.size, pair[0]))
		var pb = _place(m, b.id, pair[1], _wall_point(b.size, pair[1]))
		var lbl := "%s→%s" % [names[pair[0]], names[pair[1]]]
		worst = maxf(worst, _check_pair_math(pa, pb, lbl))
		var mab: Transform3D = SM.Portal.teleport_between(pa, pb)
		check(mab.basis.is_equal_approx(Basis.IDENTITY), "%s：純平移（水平朝向與上方向都不變）" % lbl)
		check(m.link_portals(pa.id, pb.id)["ok"], "%s 可配對" % lbl)
	print("    垂直 16 組 + 水平 2 組最大誤差 = %s" % String.num_scientific(worst))

	# 配對規則
	var m = SM.PalaceModel.new()
	var a = m.create_cell("A", "t", Vector3(8, 3, 5))
	var b = m.create_cell("B", "t", Vector3(6, 3, 9))
	var wa1 = _place(m, a.id, 1, Vector3(8, 1.2, 2.5), psize)
	var wb2 = _place(m, b.id, 2, Vector3(3, 1.2, 0), psize)
	var fa = _place(m, a.id, 4, Vector3(3, 0, 2))
	var fb = _place(m, b.id, 4, Vector3(3, 0, 2))
	var cb = _place(m, b.id, 5, Vector3(3, 3, 2))
	check(m.link_portals(wa1.id, fa.id)["error"] == "orientation_mismatch", "牆面門不能接水平開口")
	check(m.link_portals(fa.id, fb.id)["error"] == "horizontal_needs_floor_and_ceiling", "地板不能接地板")
	check(m.link_portals(fa.id, cb.id)["ok"], "地板 ↔ 天花板可接")
	check(m.link_portals(wa1.id, wb2.id, true)["ok"], "雙向配對應成功")
	check(m.has_teleport(wa1.id) and m.has_teleport(wb2.id), "雙向配對後兩端都可傳送")
	var mab: Transform3D = m.teleport_matrix(wa1.id)
	var mba: Transform3D = m.teleport_matrix(wb2.id)
	check(SM.Portal.transform_distance(mba * mab, Transform3D.IDENTITY) < 1e-5, "model 內的 M_BA·M_AB 為單位矩陣")
	check(not m.link_portals(wa1.id, wb2.id, true)["ok"], "已綁定的門不可重複配對")
	check(not m.link_portals(wa1.id, wa1.id, true)["ok"], "不可自己連自己")

	var pc = _place(m, a.id, 0, Vector3(0, 1.2, 1), psize)
	check(m.link_portals(pc.id, wb2.id, false)["error"] == "b_already_targeted", "已被指定為目標的門不可再被指定")
	var pd = _place(m, b.id, 3, Vector3(2, 1.2, 9), psize)
	check(m.link_portals(pc.id, pd.id, false)["ok"], "單向配對應成功")
	check(m.has_teleport(pc.id) and not m.has_teleport(pd.id), "單向：只有起點可傳送")
	m.unlink_portal(pc.id)
	check(not m.has_teleport(pc.id), "unlink 後不可傳送")
	m.unlink_portal(wa1.id)
	check(not m.has_teleport(wa1.id) and not m.has_teleport(wb2.id), "雙向 unlink 兩端都解除")
	check(m.teleport_matrix(wa1.id) == Transform3D.IDENTITY, "未連通時回傳單位矩陣")

	# 同房間內的滿版轉角門（轉角無縫轉向）
	var m2 = SM.PalaceModel.new()
	var room = m2.create_cell("轉角", "t", Vector3(8, 3, 5))
	var q1 = m2.place_portal(room.id, 1, Vector3.ZERO, Vector2.ZERO, true)["portal"]
	var q2 = m2.place_portal(room.id, 3, Vector3.ZERO, Vector2.ZERO, true)["portal"]
	check(m2.link_portals(q1.id, q2.id, true)["ok"], "同房間轉角滿版門可配對")
	check(SM.Portal.transform_distance(m2.teleport_matrix(q2.id) * m2.teleport_matrix(q1.id), Transform3D.IDENTITY) < 1e-5, "轉角傳送矩陣可逆")

	# 斜坡楔形幾何
	var ramp = m2.add_ramp(room.id, Vector3(1, 0, 1), Vector3.RIGHT)
	check(near(ramp.width, 1.0), "斜坡預設寬度 1 m")
	check(ramp.convex_points().size() == 6, "斜坡楔形有 6 個頂點")
	check(near(ramp.slope_angle_deg(), 26.565, 0.01), "斜坡角度 atan(1/2) ≈ 26.57°")
	check(ramp.slope_angle_deg() < 46.0, "斜坡在 46° 可行走上限內")
	var diag = m2.add_ramp(room.id, Vector3(1, 0, 1), Vector3(1, 0, 0.9))
	check(near_v3(diag.horizontal_dir(), Vector3.RIGHT), "斜坡方向吸附為軸向")


# ------------------------------------------------------------------ (3) 雜湊 / 資源庫

func test_hashing_and_assets() -> void:
	print("[3a] SHA-256 與 AssetStore 去重")
	check(ST.Hashing.sha256_text("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256('abc') 已知向量")
	check(ST.Hashing.sha256_bytes(PackedByteArray()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256(空) 已知向量")

	var root := "user://_headless_test_assets_%d" % Time.get_ticks_usec()
	var store = ST.AssetStore.new(root)
	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
	var r1: Dictionary = store.import_bytes(png, "png")
	var r2: Dictionary = store.import_bytes(png, "png")
	check(r1["ok"] and not r1["deduped"], "第一次匯入成功且非重複")
	check(r2["ok"] and r2["deduped"] and r2["hash"] == r1["hash"], "相同內容第二次匯入判定為重複")
	check(store.count() == 1, "相同雜湊只存一份")
	check(r1["hash"] == ST.Hashing.sha256_bytes(png), "回傳雜湊 = 內容 SHA-256")
	check(store.verify_asset(r1["hash"]), "完整資源通過 verify")
	check(store.read_asset(r1["hash"]) == png, "讀回位元組一致")

	var glb := "glTF".to_utf8_buffer() + PackedByteArray([2, 0, 0, 0, 12, 0, 0, 0])
	var r3: Dictionary = store.import_bytes(glb, "glb")
	check(r3["ok"] and r3["type"] == "model" and r3["ext"] == "glb", "GLB 以魔數辨識為 model")
	var obj := "# test\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".to_utf8_buffer()
	var r4: Dictionary = store.import_bytes(obj, "obj")
	check(r4["ok"] and r4["type"] == "model" and r4["ext"] == "obj", "OBJ 以頂點行辨識為 model")
	var jpg := PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2])
	check(store.import_bytes(jpg, "jpg")["ext"] == "jpg", "JPEG 魔數")
	var webp := "RIFF".to_utf8_buffer() + PackedByteArray([0, 0, 0, 0]) + "WEBP".to_utf8_buffer()
	check(store.import_bytes(webp, "webp")["ext"] == "webp", "WebP 魔數")
	check(store.count() == 5, "共 5 份不同資源")
	check(not store.import_bytes(PackedByteArray([1, 2, 3]), "png")["ok"], "副檔名說是 png 但內容不是 → 拒絕")
	check(not store.import_bytes(PackedByteArray(), "")["ok"], "空檔案拒絕")

	var tmp_file := root.path_join("sample.png")
	var f := FileAccess.open(tmp_file, FileAccess.WRITE)
	f.store_buffer(png)
	f.close()
	var r5: Dictionary = store.import_file(tmp_file)
	check(r5["ok"] and r5["deduped"], "import_file 同內容仍去重")
	check(store.import_file(root.path_join("missing.png"))["error"] == "file_not_found", "不存在的檔案回傳 file_not_found")

	var path: String = store.find_path(r1["hash"])
	var g := FileAccess.open(path, FileAccess.WRITE)
	g.store_buffer(PackedByteArray([9, 9, 9]))
	g.close()
	check(not store.verify_asset(r1["hash"]), "檔案被改動後 verify 失敗")

	ST.Io.remove_tree(root)


# ------------------------------------------------------------------ (3) 匯入來源：原生選擇器 + 備用資料夾

func _write_file(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func test_import_sources() -> void:
	print("[3e] 匯入來源：原生選擇器退場與 import_drop 備用")
	check(not ST.ImportSources.native_supported(), "無頭環境沒有原生檔案選擇器")
	check(ST.ImportSources.open_native(Callable()) == ERR_UNAVAILABLE, "不支援時 open_native 回傳 ERR_UNAVAILABLE（不當機）")

	var root := "user://_headless_test_import_%d" % Time.get_ticks_usec()
	var assets = ST.AssetStore.new(root)
	var src = ST.ImportSources.new(root)
	check(src.drop_dir == root.path_join("import_drop") and DirAccess.dir_exists_absolute(src.drop_dir), "備用資料夾 import_drop 會自動建立")
	check(src.scan_drop().is_empty(), "空資料夾掃描結果為空")

	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9, 9])
	var glb := "glTF".to_utf8_buffer() + PackedByteArray([2, 0, 0, 0, 12, 0, 0, 0, 1])
	_write_file(src.drop_dir.path_join("good.png"), png)
	_write_file(src.drop_dir.path_join("Model.GLB"), glb)
	_write_file(src.drop_dir.path_join("fake.png"), PackedByteArray([1, 2, 3, 4]))
	_write_file(src.drop_dir.path_join("notes.txt"), "忽略我".to_utf8_buffer())
	DirAccess.make_dir_recursive_absolute(src.drop_dir.path_join("subdir"))
	check(src.scan_drop().size() == 3, "只列出支援副檔名的檔案（大小寫不拘、略過資料夾與 .txt）")

	var res: Dictionary = src.import_drop(assets)
	check(res["ok"] and res["results"].size() == 2, "兩個有效檔案匯入成功")
	check(res["failed"].size() == 1 and str(res["failed"][0]["path"]).ends_with("fake.png"), "內容不符的 fake.png 被拒絕並回報")
	check(res["moved"] == 2 and assets.count() == 2, "成功的檔案移走、資源庫有 2 份")
	check(FileAccess.file_exists(src.drop_dir.path_join("_imported").path_join("good.png")), "已匯入檔案移到 _imported/")
	check(src.scan_drop().size() == 1, "備用資料夾只剩失敗的檔案")
	var types := {}
	for r in res["results"]:
		types[r["type"]] = true
	check(types.has("image") and types.has("model"), "結果帶有類型（image / model）供 UI 建立記憶物件")

	# 同內容再放一次：去重，不新增
	_write_file(src.drop_dir.path_join("good.png"), png)
	var res2: Dictionary = src.import_drop(assets)
	check(res2["deduped"] == 1 and assets.count() == 2, "相同內容再次匯入判定為重複")
	check(FileAccess.file_exists(src.drop_dir.path_join("_imported").path_join("good.png")), "移動時遇到同名檔不覆蓋、不失敗")

	# 原生選擇器回傳的路徑（含不存在的 / 無副檔名的 OBJ）
	var noext := root.path_join("model_noext")
	_write_file(noext, "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".to_utf8_buffer())
	var res3: Dictionary = src.import_paths(PackedStringArray([noext, root.path_join("gone.png")]), assets)
	check(res3["ok"] and res3["results"].size() == 1 and res3["results"][0]["type"] == "model", "沒有副檔名的 OBJ 以內容判斷")
	check(res3["failed"].size() == 1 and res3["failed"][0]["error"] == "file_not_found", "不存在的路徑回報 file_not_found")
	var only_v := root.path_join("only_v")
	_write_file(only_v, "v 0 0 0\nv 1 1 1\n".to_utf8_buffer())
	check(not assets.import_file(only_v)["ok"], "只有頂點行、沒有面行也沒有 .obj 副檔名 → 不當成模型")

	ST.Io.remove_tree(root)


# ------------------------------------------------------------------ (3) A/B 雙緩衝存檔

func _build_sample_model():
	var m = SM.PalaceModel.new()
	var a = m.create_cell("甲", "ivory", Vector3(8, 3, 5))
	var b = m.create_cell("乙", "night", Vector3(6, 3, 9))
	m.add_ramp(a.id, Vector3(1, 0, 1), Vector3.RIGHT, 1.0, 2.0, 1.0)
	m.add_platform(a.id, Vector3(4, 2.5, 1), Vector2(3, 2))
	m.add_railing(a.id, Vector3(4, 2.5, 1), Vector3.BACK, 2.0)
	var psize := Vector2(1.2, 2.4)
	var pa = _place(m, a.id, 1, Vector3(8, 1.2, 2.5), psize)
	var pb = _place(m, b.id, 2, Vector3(3, 1.2, 0), psize)
	m.link_portals(pa.id, pb.id, true)
	var fa = _place(m, a.id, 5, Vector3(2, 3, 2))        # 甲的天花板開口
	var fb = _place(m, b.id, 4, Vector3(4, 0, 3))        # 乙的地板開口
	m.link_portals(fa.id, fb.id, true)
	var n = m.add_memory_node(a.id, "abc", "image", Vector3(2, 1, 2))
	n.set_prompt("這是一段超過十五個字的提示文字，應該被截斷")
	n.detail_note = "細節"
	return m


func test_save_store() -> void:
	print("[3b] A/B 雙緩衝存檔完整性")
	var root := "user://_headless_test_save_%d" % Time.get_ticks_usec()
	var s = ST.SaveStore.new(root)
	check(not s.load_latest()["ok"], "空目錄沒有可載入的存檔")

	check(s.save({"n": 1, "文字": "測試"}) == OK, "第 1 次存檔")
	var l1: Dictionary = s.load_latest()
	check(l1["ok"] and int(l1["data"]["n"]) == 1 and l1["data"]["文字"] == "測試" and l1["seq"] == 1, "讀回第 1 次存檔（含中文）")
	check(not l1["recovered"], "首次存檔不算 recovered")
	check(s.save({"n": 2}) == OK and s.save({"n": 3}) == OK, "第 2、3 次存檔")
	var l3: Dictionary = s.load_latest()
	check(int(l3["data"]["n"]) == 3 and l3["seq"] == 3, "最新為第 3 次")
	var sa: Dictionary = s.read_slot("a")
	var sb: Dictionary = s.read_slot("b")
	check(sa["valid"] and sb["valid"], "兩個槽位同時有效")
	var older: Dictionary = sa if sa["seq"] < sb["seq"] else sb
	check(int(older["data"]["n"]) == 2, "較舊槽位保留上一版快照（n=2）")
	check(not FileAccess.file_exists(s.slot_path("a") + ".tmp") and not FileAccess.file_exists(s.slot_path("b") + ".tmp"), "存檔完成後沒有殘留 .tmp")

	var newest_slot: String = l3["slot"]
	var bad := FileAccess.open(s.slot_path(newest_slot), FileAccess.WRITE)
	bad.store_string("{這不是合法的 JSON")
	bad.close()
	var lr: Dictionary = s.load_latest()
	check(lr["ok"] and int(lr["data"]["n"]) == 2 and lr["recovered"], "最新槽位損毀時回退到上一版並標記 recovered")
	check(s.save({"n": 4}) == OK, "損毀後再存檔可自我修復")
	var l4: Dictionary = s.load_latest()
	check(int(l4["data"]["n"]) == 4 and l4["seq"] == 3 and not l4["recovered"], "修復後最新為 n=4（seq 接續 2+1）且兩槽位皆有效")

	var raw: String = ST.Io.read_text(s.slot_path(l4["slot"]))
	var tampered := raw.replace("\\\"n\\\":4", "\\\"n\\\":5")
	check(tampered != raw, "（測試前置）竄改字串確實有替換")
	var t := FileAccess.open(s.slot_path(l4["slot"]), FileAccess.WRITE)
	t.store_string(tampered)
	t.close()
	var rs: Dictionary = s.read_slot(l4["slot"])
	check(not rs["valid"] and rs["reason"] == "hash_mismatch", "內容被改但雜湊沒變 → hash_mismatch")

	var stray := FileAccess.open(s.slot_path("a") + ".tmp", FileAccess.WRITE)
	stray.store_string("半寫入")
	stray.close()
	var s2 = ST.SaveStore.new(root)
	check(not FileAccess.file_exists(s2.slot_path("a") + ".tmp"), "重新開啟時清除殘留 .tmp")

	for slot in ["a", "b"]:
		var w := FileAccess.open(s2.slot_path(slot), FileAccess.WRITE)
		w.store_string("xxx")
		w.close()
	check(not s2.load_latest()["ok"], "兩槽位皆損毀 → 回報失敗而非回傳垃圾")

	# 宮殿模型完整往返（含三種建材與四個傳送門）
	var root2 := "user://_headless_test_model_%d" % Time.get_ticks_usec()
	var s3 = ST.SaveStore.new(root2)
	var model = _build_sample_model()
	check(s3.save(model.to_dict()) == OK, "宮殿模型存檔")
	var loaded: Dictionary = s3.load_latest()
	check(loaded["ok"], "宮殿模型讀回")
	var m2 = SM.PalaceModel.from_dict(loaded["data"])
	check(m2.cells.size() == 2 and m2.structures.size() == 3 and m2.portals.size() == 4 and m2.memory_nodes.size() == 1, "往返後物件數量一致（房 2、建材 3、門 4、記憶物件 1）")
	check(m2.validate().is_empty(), "往返後 validate() 為空")
	var kinds := {}
	for sid in m2.structures:
		kinds[m2.structures[sid].kind] = true
	check(kinds.has("ramp") and kinds.has("platform") and kinds.has("railing"), "三種建材類型都還原")
	var linked := 0
	for pid in m2.portals:
		if m2.has_teleport(pid):
			linked += 1
			var back: String = m2.portals[pid].target_portal_id
			check(m2.portals[back].target_portal_id == pid, "雙向配對往返保留")
			check(SM.Portal.transform_distance(m2.teleport_matrix(pid) * m2.teleport_matrix(back), Transform3D.IDENTITY) < 1e-5, "往返後矩陣仍可逆")
	check(linked == 4, "四個門都保持連通")
	var nid: String = m2.memory_nodes.keys()[0]
	check(m2.memory_nodes[nid].prompt15.length() == 15 and m2.memory_nodes[nid].detail_note == "細節", "prompt15 截斷為 15 字、備註保留")
	check(near_v3(m2.memory_nodes[nid].pos, Vector3(2, 1, 2)), "記憶物件座標往返一致")
	var ids_before: Array = model.cells.keys()
	ids_before.sort()
	var ids_after: Array = m2.cells.keys()
	ids_after.sort()
	check(ids_before == ids_after, "房間 ID 往返一致")
	check(not (m2.create_cell("新", "t", Vector3(3, 3, 3)).id in ids_before), "載入後新建房間不會與舊 ID 衝突")

	ST.Io.remove_tree(root)
	ST.Io.remove_tree(root2)


# ------------------------------------------------------------------ 備份包

func test_backup() -> void:
	print("[3c] 備份包匯出 / 匯入")
	var root1 := "user://_headless_test_bk1_%d" % Time.get_ticks_usec()
	var root2 := "user://_headless_test_bk2_%d" % Time.get_ticks_usec()
	var saves1 = ST.SaveStore.new(root1)
	var assets1 = ST.AssetStore.new(root1)
	var settings1 = ST.SettingsStore.new(root1)
	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7, 7])
	var glb := "glTF".to_utf8_buffer() + PackedByteArray([2, 0, 0, 0, 12, 0, 0, 0, 5])
	assets1.import_bytes(png, "png")
	assets1.import_bytes(glb, "glb")
	settings1.set_value("look_sensitivity", 1.7)
	var model = _build_sample_model()
	check(saves1.save(model.to_dict()) == OK, "備份前置：存檔")

	var zip_path := root1.path_join("backup.zip")
	check(ST.Backup.export_backup(zip_path, saves1, assets1, settings1) == OK, "匯出備份包")

	var assets2 = ST.AssetStore.new(root2)
	var res: Dictionary = ST.Backup.import_backup(zip_path, assets2)
	check(res["ok"], "匯入備份包成功：%s" % str(res.get("error", "")))
	if res["ok"]:
		check(res["assets_imported"] == 2 and res["assets_deduped"] == 0, "匯入 2 份新資源")
		check(assets2.count() == 2 and assets2.verify_asset(ST.Hashing.sha256_bytes(png)), "資源完整還原")
		check(res["palace"]["cells"].size() == 2 and res["palace"]["structures"].size() == 3, "宮殿資料還原")
		check(near(float(res["settings"]["look_sensitivity"]), 1.7), "設定還原")
		var again: Dictionary = ST.Backup.import_backup(zip_path, assets2)
		check(again["ok"] and again["assets_imported"] == 0 and again["assets_deduped"] == 2, "重複匯入全部去重")

	var bad_zip := root1.path_join("bad_hash.zip")
	_write_zip(bad_zip, {"palace.json": "{}".to_utf8_buffer()}, {"palace.json": "0".repeat(64)})
	check(not ST.Backup.import_backup(bad_zip, assets2)["ok"], "雜湊不符的備份被拒絕")

	var evil_zip := root1.path_join("evil.zip")
	var evil := "evil".to_utf8_buffer()
	_write_zip(evil_zip, {"../evil.txt": evil}, {"../evil.txt": ST.Hashing.sha256_bytes(evil)})
	var er: Dictionary = ST.Backup.import_backup(evil_zip, assets2)
	check(not er["ok"] and str(er["error"]).begins_with("bad_entry"), "含 ../ 的條目被拒絕")

	var lie_zip := root1.path_join("lie.zip")
	var fake_name := "assets/" + "a".repeat(64) + ".png"
	_write_zip(lie_zip, {"palace.json": "{}".to_utf8_buffer(), fake_name: png}, {"palace.json": ST.Hashing.sha256_text("{}"), fake_name: ST.Hashing.sha256_bytes(png)})
	check(not ST.Backup.import_backup(lie_zip, assets2)["ok"], "檔名雜湊與內容不符的資源被拒絕")

	var junk := FileAccess.open(root1.path_join("junk.zip"), FileAccess.WRITE)
	junk.store_string("not a zip")
	junk.close()
	check(not ST.Backup.import_backup(root1.path_join("junk.zip"), assets2)["ok"], "非 zip 檔被拒絕")

	ST.Io.remove_tree(root1)
	ST.Io.remove_tree(root2)


func _write_zip(path: String, entries: Dictionary, manifest_hashes: Dictionary) -> void:
	var zp := ZIPPacker.new()
	zp.open(path)
	for k in entries:
		zp.start_file(k)
		zp.write_file(entries[k])
		zp.close_file()
	zp.start_file("manifest.json")
	zp.write_file(JSON.stringify({"format": 1, "files": manifest_hashes}).to_utf8_buffer())
	zp.close_file()
	zp.close()


# ------------------------------------------------------------------ 設定檔

func test_settings() -> void:
	print("[3d] 設定檔")
	var root := "user://_headless_test_settings_%d" % Time.get_ticks_usec()
	var st = ST.SettingsStore.new(root)
	check(st.load_settings() == OK and int(st.get_value("max_visible_portals")) == 4, "預設門渲染上限為 4")
	st.set_value("max_visible_portals", 99)
	check(int(st.get_value("max_visible_portals")) == 12, "門渲染上限夾在 12 以內")
	st.set_value("look_sensitivity", 0.0)
	check(near(float(st.get_value("look_sensitivity")), 0.2), "靈敏度夾在 0.2 以上")
	check(int(st.get_value("max_fps")) == 30 and near(float(st.get_value("render_scale")), 0.75), "預設 30 fps、畫質 0.75")
	st.set_value("max_fps", 144)
	st.set_value("render_scale", 0.9)
	check(int(st.get_value("max_fps")) == 60 and near(float(st.get_value("render_scale")), 1.0), "fps 只能是 30 / 60；畫質吸附到 0.5 / 0.75 / 1.0")
	st.set_value("max_fps", 30)
	st.set_value("render_scale", 0.75)
	st.set_value("mirror_ui", true)
	st.set_value("unknown_key", 1)
	check(not st.values.has("unknown_key"), "未知設定鍵被忽略")
	check(st.save_settings() == OK, "儲存設定")
	var st2 = ST.SettingsStore.new(root)
	check(st2.load_settings() == OK and int(st2.get_value("max_visible_portals")) == 12 and bool(st2.get_value("mirror_ui")), "設定往返一致")
	var g := FileAccess.open(root.path_join("settings.json"), FileAccess.WRITE)
	g.store_string("壞掉")
	g.close()
	var st3 = ST.SettingsStore.new(root)
	check(st3.load_settings() == ERR_FILE_CORRUPT and int(st3.get_value("max_visible_portals")) == 4, "設定檔損毀時回到預設值")
	ST.Io.remove_tree(root)


# ------------------------------------------------------------------ (4) 房間建構與傳送門系統：純邏輯

func _area(rects: Array) -> float:
	var s := 0.0
	for r: Rect2 in rects:
		s += r.get_area()
	return s


func test_room_builder_logic() -> void:
	print("[4a] room_builder 面分割")
	var dims := Vector2(8, 3)
	var none: Array = RB.face_rects(dims, [])
	check(near(_area(none), 24.0), "無洞：面積 = 24")
	check(none.size() == 1, "無洞：只有一塊")
	var holes: Array = [Rect2(1, 0.0, 1.2, 2.2), Rect2(5, 0.5, 1.0, 1.0)]
	var parts: Array = RB.face_rects(dims, holes)
	check(near(_area(parts), 24.0 - 1.2 * 2.2 - 1.0), "兩洞：面積守恆")
	var overlap_ok := true
	for i in range(parts.size()):
		for h: Rect2 in holes:
			if parts[i].intersects(h, false):
				overlap_ok = false
		for j in range(i + 1, parts.size()):
			if parts[i].intersects(parts[j], false):
				overlap_ok = false
	check(overlap_ok, "兩洞：碎片互不重疊、也不與洞重疊")
	var edge: Array = RB.face_rects(dims, [Rect2(0, 0, 8, 3)])
	check(edge.is_empty(), "整面都是洞：沒有碎片")
	var out: Array = RB.face_rects(dims, [Rect2(7, 2, 3, 3)])
	check(near(_area(out), 24.0 - 1.0), "洞超出邊界：只扣掉界內部分")


func _two_cell_model() -> Array:
	var m = SM.PalaceModel.new()
	var a = m.create_cell("甲", "ivory", Vector3(8, 3, 5))
	var b = m.create_cell("乙", "night", Vector3(6, 3, 9))
	var pa = _place(m, a.id, 1, Vector3(8, 1.2, 2.5), Vector2(1.2, 2.2))
	var pb = _place(m, b.id, 2, Vector3(3, 1.2, 0), Vector2(1.2, 2.2))
	m.link_portals(pa.id, pb.id, true)
	return [m, a, b, pa, pb]


func test_portal_system_logic() -> void:
	print("[4b] portal_system 視圖規劃與穿越判定")
	var L = PS.Logic
	var set_up: Array = _two_cell_model()
	var m = set_up[0]
	var a = set_up[1]
	var b = set_up[2]
	var pa = set_up[3]
	var pb = set_up[4]
	var cam := Transform3D(Basis.from_euler(Vector3(0, -PI / 2.0, 0)), Vector3(4, 1.5, 2.5))
	# 朝 +X 看：門在正前方
	check(L.visible_score(pa, cam, 75.0, 1.8) < INF, "面向牆上的門：看得見")
	var away := Transform3D(Basis.from_euler(Vector3(0, PI / 2.0, 0)), Vector3(4, 1.5, 2.5))
	check(L.visible_score(pa, away, 75.0, 1.8) == INF, "背對門：看不見")
	var behind := Transform3D(cam.basis, Vector3(9, 1.5, 2.5))
	check(L.visible_score(pa, behind, 75.0, 1.8) == INF, "攝影機在門背面：看不見")

	var views: Array = L.plan_views(m, a.id, cam, 75.0, 1.8, 6)
	check(views.size() >= 1, "規劃出至少一個視圖")
	if views.size() >= 1:
		check(views[0]["portal_id"] == pa.id and views[0]["depth"] == 1, "一級視圖是甲的門")
		check(views[0]["cell_id"] == b.id, "一級視圖目的地是乙")
		check(views[0]["exit_portal_id"] == pb.id, "一級視圖記錄出口門")
		var expect: Transform3D = SM.Portal.teleport_between(pa, pb) * cam
		check(near_v3(views[0]["xf"].origin, expect.origin), "虛擬攝影機位置 = M·主攝影機")
	for v in views:
		check(v["depth"] == 1 or (v["parent"] >= 0 and v["parent"] < views.size()), "二級視圖有合法 parent")
		check(v["depth"] != 2 or v["portal_id"] != pb.id, "二級視圖不包含剛穿出的出口門")
	check(L.plan_views(m, a.id, away, 75.0, 1.8, 6).is_empty(), "背對門：無視圖")
	check(L.plan_views(m, a.id, cam, 75.0, 1.8, 0).is_empty(), "預算 0：無視圖")
	check(L.plan_views(m, "不存在", cam, 75.0, 1.8, 6).is_empty(), "不存在的房間：無視圖")

	# 二級視圖：乙再接一個通往丙的門
	var c = m.create_cell("丙", "forest", Vector3(5, 3, 5))
	var pb2 = _place(m, b.id, 3, Vector3(3, 1.2, 9), Vector2(1.2, 2.2))
	var pc = _place(m, c.id, 2, Vector3(2.5, 1.2, 0), Vector2(1.2, 2.2))
	m.link_portals(pb2.id, pc.id, true)
	var v2: Array = L.plan_views(m, a.id, cam, 75.0, 1.8, 6)
	var depth2 := 0
	for v in v2:
		if v["depth"] == 2:
			depth2 += 1
	check(depth2 <= 1, "二級視圖數量不超過預算")
	check(L.plan_views(m, a.id, cam, 75.0, 1.8, 1).size() == 1, "預算 1：只有一級視圖")

	# 穿越判定：門在 +X 牆，法線朝 −X
	check(L.crossed(pa, Vector3(7.9, 1.2, 2.5), Vector3(8.1, 1.2, 2.5)), "由正面穿過門中心：成立")
	check(not L.crossed(pa, Vector3(8.1, 1.2, 2.5), Vector3(7.9, 1.2, 2.5)), "由背面往回：不成立")
	check(not L.crossed(pa, Vector3(7.9, 1.2, 4.5), Vector3(8.1, 1.2, 4.5)), "穿過牆但不在門洞內：不成立")
	check(not L.crossed(pa, Vector3(7.0, 1.2, 2.5), Vector3(7.5, 1.2, 2.5)), "沒到門平面：不成立")

	# 凹陷判定
	check(L.recess_needed(pa, Vector3(7.95, 1.2, 2.5)), "貼近門且在門洞前：需要凹陷")
	check(not L.recess_needed(pa, Vector3(6.0, 1.2, 2.5)), "離門很遠：不需要")
	check(not L.recess_needed(pa, Vector3(7.95, 1.2, 4.5)), "貼牆但不在門洞前：不需要")


# ------------------------------------------------------------------ (5) 記憶節點外觀、玩家控制

func _png_bytes(w: int, h: int) -> PackedByteArray:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.6, 0.9))
	return img.save_png_to_buffer()


## 手工組一個只有一個三角形的 GLB（POSITION + 16 位元索引）
func _glb_triangle_bytes() -> PackedByteArray:
	var bin := StreamPeerBuffer.new()
	for f in [0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 4.0, 0.0]:
		bin.put_float(f)
	for i in [0, 1, 2]:
		bin.put_u16(i)
	bin.put_u16(0)    # 補齊到 4 位元組倍數
	var bin_bytes: PackedByteArray = bin.data_array
	var js := {
		"asset": {"version": "2.0"},
		"scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
		"meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
		"buffers": [{"byteLength": bin_bytes.size()}],
		"bufferViews": [
			{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962},
			{"buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963},
		],
		"accessors": [
			{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [2, 4, 0]},
			{"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"},
		],
	}
	var json_bytes := JSON.stringify(js).to_utf8_buffer()
	while json_bytes.size() % 4 != 0:
		json_bytes.append(0x20)
	var out := StreamPeerBuffer.new()
	out.put_u32(0x46546C67)
	out.put_u32(2)
	out.put_u32(12 + 8 + json_bytes.size() + 8 + bin_bytes.size())
	out.put_u32(json_bytes.size())
	out.put_u32(0x4E4F534A)
	out.put_data(json_bytes)
	out.put_u32(bin_bytes.size())
	out.put_u32(0x004E4942)
	out.put_data(bin_bytes)
	return out.data_array


const _OBJ_CUBE := """# cube
v 0 0 0
v 2 0 0
v 2 2 0
v 0 2 0
v 0 0 2
v 2 0 2
v 2 2 2
v 0 2 2
f 1 2 3 4
f 5 8 7 6
f 1 5 6 2
f 2 6 7 3
f 3 7 8 4
f 5 1 4 8
"""


func test_memory_loaders() -> void:
	print("[5a] 記憶節點載入器：圖片 / OBJ / GLB")
	var L = MV.Loader
	var png := _png_bytes(40, 20)
	var img: Image = L.decode_image(png, 1024)
	check(img != null and img.get_width() == 40 and img.get_height() == 20, "PNG 解碼尺寸正確")
	var small: Image = L.decode_image(_png_bytes(400, 200), 100)
	check(small != null and small.get_width() == 100 and small.get_height() == 50, "超過上限時等比縮小")
	check(L.decode_image(PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]), 1024) == null, "亂碼解碼回傳 null")
	check(L.decode_image("v 0 0 0".to_utf8_buffer(), 1024) == null, "非圖片內容回傳 null")
	var ds: Vector2 = L.image_display_size(40, 20, 0.8)
	check(near(ds.x, 0.8) and near(ds.y, 0.4), "圖片顯示尺寸：長邊 = 0.8")
	check(near(L.fit_scale(AABB(Vector3.ZERO, Vector3(2, 4, 1)), 0.8), 0.2), "fit_scale：最長邊縮到 0.8")
	check(near(L.fit_scale(AABB(), 0.8), 1.0), "fit_scale：空包圍盒不爆")

	var obj: Dictionary = L.parse_obj(_OBJ_CUBE)
	check(obj["ok"], "OBJ 立方體解析成功")
	if obj["ok"]:
		check(obj["triangles"] == 12, "OBJ：6 個四邊形 = 12 個三角形（實際 %d）" % obj["triangles"])
		check(near_v3(obj["aabb"].size, Vector3(2, 2, 2)), "OBJ：包圍盒 2×2×2")
	check(not L.parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 9\n")["ok"], "OBJ：索引越界被拒絕")
	check(not L.parse_obj("v 0 0 0\n")["ok"], "OBJ：沒有面被拒絕")
	var neg: Dictionary = L.parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\n")
	check(neg["ok"] and neg["triangles"] == 1, "OBJ：支援負索引")
	var tex: Dictionary = L.parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nf 1/1/1 2/2/1 3/3/1\n")
	check(tex["ok"], "OBJ：v/vt/vn 格式可解析")

	var glb: Dictionary = L.load_glb(_glb_triangle_bytes())
	check(glb["ok"], "GLB 三角形載入成功：%s" % str(glb.get("error", "")))
	if glb["ok"]:
		check(glb["triangles"] == 1, "GLB：1 個三角形")
		check(near_v3(glb["aabb"].size, Vector3(2, 4, 0)), "GLB：包圍盒 2×4×0")
		glb["root"].free()
	check(not L.load_glb("glTF-壞掉的檔案-壞掉的檔案".to_utf8_buffer())["ok"], "壞 GLB 被拒絕且不崩潰")


func test_memory_views() -> void:
	print("[5b] 記憶節點外觀與互動碰撞體")
	var m = SM.PalaceModel.new()
	var a = m.create_cell("甲", "ivory", Vector3(8, 3, 5))
	m.activate_cell(a.id)
	var tmp := "user://mv_test_%d" % Time.get_ticks_usec()
	var assets = ST.AssetStore.new(tmp)
	var img_r: Dictionary = assets.import_bytes(_png_bytes(40, 20))
	var obj_r: Dictionary = assets.import_bytes(_OBJ_CUBE.to_utf8_buffer(), "obj")
	var glb_r: Dictionary = assets.import_bytes(_glb_triangle_bytes())
	check(img_r["ok"] and obj_r["ok"] and glb_r["ok"], "測試素材匯入成功")

	var n_blank = m.add_memory_node(a.id, "", "", Vector3(1, 1, 1))
	var n_img = m.add_memory_node(a.id, img_r["hash"], "image", Vector3(2, 1, 1))
	var n_obj = m.add_memory_node(a.id, obj_r["hash"], "model", Vector3(3, 1, 1))
	var n_glb = m.add_memory_node(a.id, glb_r["hash"], "model", Vector3(4, 1, 1))
	var n_miss = m.add_memory_node(a.id, "0".repeat(64), "image", Vector3(5, 1, 1))
	var n_bad = m.add_memory_node(a.id, img_r["hash"], "model", Vector3(6, 1, 1))   # 型別與內容不符
	n_img.set_prompt("單字：apple")
	n_img.scale = Vector3(2, 2, 1)

	var root := Node3D.new()
	var views: Dictionary = MV.populate_cell(root, m, a.id, assets)
	check(views.size() == 6, "房間內 6 個記憶節點都有外觀")
	check(views[n_blank.id].status == "placeholder", "無素材：佔位符")
	check(views[n_img.id].status == "ok", "圖片：ok")
	check(views[n_obj.id].status == "ok", "OBJ：ok")
	check(views[n_glb.id].status == "ok", "GLB：ok")
	check(views[n_miss.id].status == "missing_asset", "素材遺失：紅框")
	check(views[n_bad.id].status in ["decode_failed", "unsupported"], "型別不符：退回紅框（%s）" % views[n_bad.id].status)
	var vi = views[n_img.id]
	check(near(vi.content_size.x, 1.6) and near(vi.content_size.y, 0.8), "圖片 scale 2×2 → 內容 1.6×0.8")
	check(near_v3(vi.position, Vector3(2, 1, 1)), "外觀位置 = 節點位置")
	check(vi.label.text == "單字：apple", "提示文字顯示")
	var vo = views[n_obj.id]
	check(near(maxf(vo.content_size.x, maxf(vo.content_size.y, vo.content_size.z)), 0.8, 1e-3), "OBJ 最長邊縮到 0.8")
	check(vo.hit_body.collision_layer == (1 << 22) and vo.hit_body.collision_mask == 0, "互動碰撞體在物理層 23")
	check(vo.hit_body.get_meta("memory_node_id") == n_obj.id and vo.hit_body.get_meta("cell_id") == a.id, "互動碰撞體帶節點與房間 id")
	var vis_ok := true
	for v in views.values():
		v.set_render_layer(a.render_layer)
		for ch in v.get_children():
			if ch is VisualInstance3D and ch.layers != SM.PalaceModel.layer_bit(a.render_layer):
				vis_ok = false
	check(vis_ok, "視覺層套用到所有可見子節點")
	# 重建不留舊容器
	var again: Dictionary = MV.populate_cell(root, m, a.id, assets)
	await_free_holder(root)
	check(again.size() == 6, "重建後仍是 6 個")
	root.free()
	ST.Io.remove_tree(tmp)


func await_free_holder(root: Node3D) -> void:
	var count := 0
	for ch in root.get_children():
		if ch.name.begins_with("Memories"):
			count += 1
	check(count <= 2, "重建時舊的 Memories 容器已移除（待釋放）")


func test_player_logic() -> void:
	print("[5c] 玩家控制：純邏輯")
	var L = PC.Logic
	check(L.joystick_vector(Vector2(100, 100), Vector2(105, 100), 110.0) == Vector2.ZERO, "搖桿死區內：不動")
	var full: Vector2 = L.joystick_vector(Vector2(100, 100), Vector2(100, -200), 110.0)
	check(near(full.length(), 1.0) and full.y < 0.0, "搖桿往上推到底：長度 1、y 為負（前進）")
	var half: Vector2 = L.joystick_vector(Vector2.ZERO, Vector2(55, 0), 110.0)
	check(half.x > 0.0 and half.x < 0.6, "搖桿半推：介於 0~0.6")
	check(L.joystick_vector(Vector2.ZERO, Vector2(50, 0), 0.0) == Vector2.ZERO, "半徑 0 不爆")

	var fwd: Vector3 = L.wish_velocity(Vector2(0, -1), 0.0, 3.0)
	check(near_v3(fwd, Vector3(0, 0, -3)), "yaw=0 往前 = −Z")
	var right: Vector3 = L.wish_velocity(Vector2(1, 0), -PI / 2.0, 3.0)
	check(near_v3(right, Vector3(0, 0, 3)), "朝 +X（yaw=−90°）時往右 = +Z")
	var diag: Vector3 = L.wish_velocity(Vector2(1, -1), 0.0, 3.0)
	check(near(diag.length(), 3.0), "斜向速度不超過上限")

	for yaw in [0.0, 0.7, -2.1, PI / 2.0, -PI / 2.0]:
		check(near(L.yaw_of(Basis.from_euler(Vector3(0, yaw, 0))), yaw, 1e-4), "yaw_of 與 from_euler 互逆（%.2f）" % yaw)
	check(near(L.clamp_pitch(5.0), deg_to_rad(85.0)) and near(L.clamp_pitch(-5.0), -deg_to_rad(85.0)), "俯仰角限制 ±85°")
	check(L.is_tap(0.1, 5.0) and not L.is_tap(0.5, 5.0) and not L.is_tap(0.1, 40.0), "點擊判定：短且幾乎沒動")

	var set_up: Array = _two_cell_model()
	var m = set_up[0]
	var pa = set_up[3]
	var pb = set_up[4]
	var mat: Transform3D = m.teleport_matrix(pa.id)
	var t: Dictionary = L.teleported(Vector3(8.0, 0.0, 2.5), -PI / 2.0, mat)
	check(near_v3(t["pos"], Vector3(3, 0, 0)), "穿門：位置落在出口門的平面上（%s）" % str(t["pos"]))
	var out_fwd := -Basis.from_euler(Vector3(0, t["yaw"], 0)).z
	check(near_v3(out_fwd, pb.normal), "穿門：朝向變成出口門的法線方向（走進房間）")
	# 往回傳送再轉回來 = 原樣
	var back: Transform3D = m.teleport_matrix(pb.id)
	var t2: Dictionary = L.teleported(t["pos"], t["yaw"], back)
	check(near_v3(t2["pos"], Vector3(8, 0, 2.5)) and near(L.yaw_of(Basis.from_euler(Vector3(0, t2["yaw"], 0))), -PI / 2.0, 1e-3), "來回傳送恢復原位與朝向")

	check(L.out_of_bounds(Vector3(4, -7, 2), Vector3(8, 3, 5)), "掉到太低：視為出界")
	check(not L.out_of_bounds(Vector3(4, -1.5, 2), Vector3(8, 3, 5)), "穿過地板門下墜的過程不算出界")
	check(L.inside_cell(Vector3(4, 0, 2), Vector3(8, 3, 5)) and not L.inside_cell(Vector3(9, 0, 2), Vector3(8, 3, 5)), "inside_cell")


## 真的跑物理：站上地板、走路、穿過傳送門、點選記憶節點
func test_player_physics() -> void:
	print("[5d] 玩家控制：物理走路 + 穿過傳送門 + 點選")
	await process_frame    # 等 SceneTree 真正啟動，節點才算在樹內
	var m = SM.PalaceModel.new()
	var a = m.create_cell("甲", "ivory", Vector3(8, 3, 5))
	var b = m.create_cell("乙", "night", Vector3(6, 3, 9))
	var pa = _place(m, a.id, 1, Vector3(8, 1.1, 2.5), Vector2(1.2, 2.2), true)
	var pb = _place(m, b.id, 2, Vector3(3, 1.1, 0), Vector2(1.2, 2.2), true)
	m.link_portals(pa.id, pb.id, true)
	m.activate_cell(a.id)
	m.activate_cell(b.id)
	var mem = m.add_memory_node(a.id, "", "", Vector3(4, 1.6, 2.5))
	var far_mem = m.add_memory_node(b.id, "", "", Vector3(4, 1.6, 2.5))   # 別間房、同座標：不可被點到

	var scene := Node3D.new()
	root.add_child(scene)
	var cells := {}
	for c in [a, b]:
		var node = RB.build_cell(m, c.id)
		scene.add_child(node)
		MV.populate_cell(node, m, c.id, null)
		cells[c.id] = node
	var ps = PS.new()
	scene.add_child(ps)
	var player = PC.new()
	scene.add_child(player)
	player.setup(m, ps)
	player.place_in_cell(a.id, Vector3(2, 0.5, 2.5), -PI / 2.0)

	for i in range(40):
		await physics_frame
	check(player.is_on_floor(), "玩家落地站穩")
	check(absf(player.global_position.y) < 0.05, "站在地板上（y=%.3f）" % player.global_position.y)
	check(player.current_cell_id == a.id, "目前房間是甲")

	# 點選：朝 +X 看，記憶節點在正前方 2m
	player.camera.force_update_transform()
	var vp_center: Vector2 = player.get_viewport().get_visible_rect().size * 0.5
	var picked: String = player.pick_node(vp_center)
	check(picked == mem.id, "正前方射線點到甲房的記憶節點（得到 %s）" % picked)
	check(picked != far_mem.id, "不會點到乙房同座標的節點")
	var surf: Dictionary = player.raycast_surface(vp_center + Vector2(0, 500))
	check(not surf.is_empty() and surf["normal"].y > 0.9, "往下的射線打到地板（法線朝上）")
	check(player.pick_node(vp_center + Vector2(0, 500)) == "", "點地板：沒有節點")

	# 往 +X 走，穿過傳送門
	var entered := []
	player.cell_entered.connect(func(cid, pid): entered.append([cid, pid]))
	player.move_input = Vector2(0, -1)
	var start_x: float = player.global_position.x
	for i in range(30):
		await physics_frame
	check(player.global_position.x > start_x + 1.0 or player.current_cell_id != a.id, "往前推搖桿，玩家會移動")
	for i in range(240):
		await physics_frame
		if player.current_cell_id != a.id:
			break
	check(player.current_cell_id == b.id, "走進傳送門後目前房間變成乙")
	check(entered.size() == 1 and entered[0][0] == b.id and entered[0][1] == pa.id, "cell_entered 訊號：進入乙、經過甲的門")
	check(ps.current_cell_id == b.id, "傳送門系統同步切到乙")
	check(player.collision_mask == SM.PalaceModel.layer_bit(b.physics_layer), "碰撞遮罩換成乙房的物理層")
	player.move_input = Vector2.ZERO
	for i in range(60):
		await physics_frame
	check(player.is_on_floor() and absf(player.global_position.y) < 0.05, "傳送後站在乙房地板上（y=%.3f）" % player.global_position.y)
	var p: Vector3 = player.global_position
	check(p.x > 0.0 and p.x < 6.0 and p.z > 0.0 and p.z < 9.0, "傳送後仍在乙房範圍內（%s）" % str(p))
	var f: Vector3 = -Basis.from_euler(Vector3(0, player.get_yaw(), 0)).z
	check(f.dot(pb.normal) > 0.9, "傳送後朝向房內（沒有面向牆）")

	# 掉出世界會被拉回
	var resp := [0]
	player.respawned.connect(func(): resp[0] += 1)
	player.global_position = Vector3(3, -20, 3)
	await physics_frame
	await physics_frame
	check(resp[0] >= 1 and player.global_position.y > -1.0, "掉出世界：送回最後安全位置")

	scene.queue_free()
	await process_frame


# ------------------------------------------------------------------ (1e) 刪除：記憶物件 / 門 / 房間

func test_deletions() -> void:
	print("[1e] 刪除記憶物件 / 門 / 房間")
	var set_up: Array = _two_cell_model()
	var m = set_up[0]
	var a = set_up[1]
	var b = set_up[2]
	var pa = set_up[3]
	var pb = set_up[4]
	var n1 = m.add_memory_node(a.id, "", "", Vector3(1, 1, 1))
	check(m.remove_memory_node(n1.id) and not m.memory_nodes.has(n1.id), "刪除記憶物件")
	check(not m.remove_memory_node(n1.id), "重複刪除回傳 false")
	check(m.remove_cell(a.id).get("error", "") == "cell_has_links", "房間仍有配對的門：拒絕刪除")
	check(m.delete_portal(pa.id), "刪除門")
	check(not m.portals.has(pa.id) and not a.portals.has(pa.id), "門從資料與房間清單移除")
	check(m.portals[pb.id].target_portal_id == "" and not m.portals[pb.id].is_bidirectional, "對側的門自動解除配對")
	check(m.validate().is_empty(), "刪門後資料仍完整")
	m.add_memory_node(a.id, "", "", Vector3(2, 1, 2))
	m.add_ramp(a.id, Vector3(1, 0, 1), Vector3.RIGHT, 1.0, 2.0, 1.0)
	m.activate_cell(a.id)
	check(m.remove_cell(a.id).get("ok", false), "解除配對後可刪房間")
	check(not m.cells.has(a.id) and m.memory_nodes.is_empty() and m.structures.is_empty(), "房間的記憶物件與建材一併移除")
	check(m.validate().is_empty(), "刪房後資料仍完整")
	check(m.activate_cell(b.id).get("ok", false), "刪房後層位槽位可正常使用")


## 斜坡 + 天花板開口 → 上樓；地板開口 → 下樓（掉進下方房間）
func test_player_stairs() -> void:
	print("[5e] 玩家控制：斜坡上樓（天花板門 → 地板門）與跳下樓")
	await process_frame
	var m = SM.PalaceModel.new()
	var a = m.create_cell("一樓", "ivory", Vector3(6, 3, 6))
	var b = m.create_cell("二樓", "night", Vector3(6, 3, 6))
	m.add_ramp(a.id, Vector3(0.8, 0, 3), Vector3.RIGHT, 1.0, 4.0, 2.8)
	var up_a = _place(m, a.id, 5, Vector3(2.7, 3, 3))          # 一樓天花板開口（預設 1m×1m）
	var up_b = _place(m, b.id, 4, Vector3(3, 0, 3))            # 二樓地板開口
	check(m.link_portals(up_a.id, up_b.id, true)["ok"], "天花板門 ↔ 地板門配對")
	m.activate_cell(a.id)
	m.activate_cell(b.id)
	var scene := Node3D.new()
	root.add_child(scene)
	for c in [a, b]:
		scene.add_child(RB.build_cell(m, c.id))
	var ps = PS.new()
	scene.add_child(ps)
	var player = PC.new()
	scene.add_child(player)
	player.setup(m, ps)
	player.place_in_cell(a.id, Vector3(0.4, 0.05, 3), -PI / 2.0)
	for i in range(30):
		await physics_frame
	check(player.is_on_floor(), "起點站穩")
	player.move_input = Vector2(0, -1)
	var guard := 0
	while player.current_cell_id == a.id and guard < 500:
		await physics_frame
		guard += 1
	var climbed: bool = player.current_cell_id == b.id
	check(climbed, "沿斜坡走上去，穿過天花板門進入二樓（走了 %d 幀，位置 %s）" % [guard, str(player.global_position)])
	player.move_input = Vector2.ZERO
	for i in range(90):
		await physics_frame
	if climbed:
		check(player.current_cell_id == b.id, "沒有被彈回一樓（不會在門口來回震盪）")
		check(player.is_on_floor() and absf(player.global_position.y) < 0.05, "站在二樓地板上（y=%.3f）" % player.global_position.y)
		var p: Vector3 = player.global_position
		check(p.x > 3.5 and p.x < 5.9 and absf(p.z - 3.0) < 0.6, "被推到門洞外的實心地板上（%s）" % str(p))

		# 往回：跳下二樓地板門，回到一樓天花板下方自由落下
		var down := [0]
		player.cell_entered.connect(func(cid, _pid): down[0] += 1 if cid == a.id else 0)
		player.place_in_cell(b.id, Vector3(3, 0.05, 3), 0.0)   # 站在洞上方（洞沒有碰撞）
		for i in range(240):
			await physics_frame
			if player.current_cell_id == a.id:
				break
		check(player.current_cell_id == a.id and down[0] == 1, "從地板門掉下去，回到一樓")
		for i in range(120):
			await physics_frame
		check(player.is_on_floor() and player.global_position.y < 2.9, "落回一樓斜坡（洞正下方就是斜坡）（y=%.2f）" % player.global_position.y)
	scene.queue_free()
	await process_frame


# ------------------------------------------------------------------ (6) 主場景整合：開門 / 樓梯 / 擴建 / 存檔重讀

func test_main_scene() -> void:
	print("[6] 主場景整合（用 main.tscn 實際操作）")
	ST.Io.remove_tree("user://palace")
	await process_frame
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	for i in range(40):
		await physics_frame
	check(main.model.cells.size() == 1 and main.player.is_on_floor(), "全新啟動：一間入口大廳、玩家站穩")
	check(main.model.memory_nodes.size() == 1 and main.memory_views.size() == 1, "附一個示範記憶方塊")
	check(main.hud != null and main.hud._panels.size() >= 8, "介面面板都建立了")

	main._on_add_requested("blank")
	check(main.model.memory_nodes.size() == 2, "＋ 新增空白方塊並開啟編輯")
	main.hud.handle_back()      # 取消編輯 → 新方塊被移除
	check(main.model.memory_nodes.size() == 1, "取消編輯：新方塊被移除")

	main.player.place_in_cell(main.player.current_cell_id, Vector3(4, 0.05, 4), -PI / 2.0)
	for i in range(5):
		await physics_frame
	main._door_front()
	check(main.model.cells.size() == 2 and main.model.portals.size() == 2, "前方開門：新房間 + 一對門")
	check(main.model.validate().is_empty(), "開門後資料完整")
	for i in range(12):
		await physics_frame
		await process_frame
	check(main.portal_system.is_frozen(), "站著不動：傳送門視圖停止更新（省電）")
	main.player.move_input = Vector2(0, 1)
	for i in range(6):
		await physics_frame
		await process_frame
	check(not main.portal_system.is_frozen(), "一移動就恢復更新")
	main.player.move_input = Vector2.ZERO

	# 編輯面板：準心對準門 → 縮放 / 平移（中心對稱、遇到邊界停住）
	main.player.camera.force_update_transform()
	var tgt: Dictionary = main._pick_target()
	check(tgt.get("kind", "") == "portal", "準心對準門：選到傳送門（%s）" % str(tgt))
	if tgt.get("kind", "") == "portal":
		main._open_target("portal", tgt["id"])
		check(main.hud.is_panel_open() and not main.hud.modal_open, "編輯面板開著，但不阻擋走動")
		var pt = main.model.portals[tgt["id"]]
		var w0: float = pt.size.x
		var c0: Vector3 = pt.local_pos
		main._on_edit_action("pw+")
		check(near(pt.size.x, w0 + 0.2), "門變寬 0.2 m")
		check(near(pt.local_pos.z, c0.z) or near(pt.local_pos.x, c0.x), "從中心對稱縮放：中心不動")
		for i in range(40):
			main._on_edit_action("pw+")
		check(pt.size.x <= 8.0 and pt.size.x >= w0 + 0.2, "一直加寬會停在牆面邊界（寬 %.1f）" % pt.size.x)
		main._on_edit_action("pm:left")
		check(main.model.validate().is_empty(), "平移後資料完整")
		main._on_edit_action("pw-")
		main.hud.handle_back()
		check(not main.hud.is_panel_open(), "返回鍵關閉編輯面板")

	# 放平台 → 調整 → 刪除
	var n_struct_before: int = main.model.structures.size()
	main._on_build_requested("platform")
	check(main.model.structures.size() == n_struct_before + 1, "選單：放平台")
	var plat_id: String = main._target.get("id", "")
	check(plat_id != "" and main.model.structures.has(plat_id), "放好後自動打開平台編輯面板")
	var plat = main.model.structures[plat_id]
	var y0: float = plat.pos.y
	main._on_edit_action("ph+")
	check(near(plat.pos.y, y0 + 0.5), "平台升高 0.5 m")
	var area0: float = plat.size.x * plat.size.y
	main._on_edit_action("ps:w+")
	main._on_edit_action("ps:l+")
	check(plat.size.x * plat.size.y > area0, "平台變寬 / 變長")
	main._on_edit_action("sdel")
	main.hud._confirm_cb.call()
	check(not main.model.structures.has(plat_id) and main.model.validate().is_empty(), "刪除平台")
	main._on_build_requested("railing")
	var rail_id: String = main._target.get("id", "")
	check(rail_id != "" and main.model.structures[rail_id].kind == "railing", "選單：放欄桿")
	var len0: float = main.model.structures[rail_id].length
	main._on_edit_action("rl-")
	check(near(main.model.structures[rail_id].length, len0 - 0.5), "欄桿縮短 0.5 m")
	main._on_edit_action("rl+")
	check(near(main.model.structures[rail_id].length, len0), "欄桿再加長 0.5 m 回到原長")
	main._on_edit_action("rrot")
	main.hud.handle_back()
	main.model.structures.erase(rail_id)
	main.model.cells["cell_0001"].structures.erase(rail_id)
	main._rebuild_cell("cell_0001")

	# 蓋樓梯，再實際走上去
	main.player.place_in_cell("cell_0001", Vector3(4, 0.05, 6.5), 0.0)
	for i in range(5):
		await physics_frame
	main._stairs_up()
	check(main.model.cells.size() == 3 and main.model.structures.size() == 1, "蓋樓梯：新房間 + 斜坡")
	var before: String = main.player.current_cell_id
	var ids: Array = main.model.cells.keys()
	ids.sort()
	var up_id: String = ids[ids.size() - 1]
	main.player.move_input = Vector2(0, -1)
	var guard := 0
	while main.player.current_cell_id == before and guard < 600:
		await physics_frame
		guard += 1
	main.player.move_input = Vector2.ZERO
	check(main.player.current_cell_id == up_id, "沿著自動蓋的樓梯走上去，抵達新房間（%d 幀，目前 %s）" % [guard, main.player.current_cell_id])
	for i in range(90):
		await physics_frame
	check(main.player.is_on_floor() and absf(main.player.global_position.y) < 0.05, "在新房間站穩")
	check(main.cell_nodes.has("cell_0001") and main.cell_nodes.has(up_id), "兩端房間節點都保持載入")

	# 擴建
	main._goto_room("cell_0001")
	var z_before: float = main.model.cells["cell_0001"].size.z
	main.player.place_in_cell("cell_0001", Vector3(4, 0.05, 4), 0.0)
	main._begin_stretch()
	main._confirm_stretch(2.0)
	check(near(main.model.cells["cell_0001"].size.z, z_before + 2.0), "擴建：沿前進方向拉開 2 公尺")
	check(main.model.validate().is_empty(), "擴建後資料完整")

	# 存檔 → 重新啟動 → 內容一致
	check(main.save_now() == OK, "存檔成功")
	var cell_count: int = main.model.cells.size()
	var portal_count: int = main.model.portals.size()
	main.queue_free()
	await process_frame
	var main2 = load("res://scenes/main.tscn").instantiate()
	root.add_child(main2)
	await process_frame
	await process_frame
	check(main2.model.cells.size() == cell_count and main2.model.portals.size() == portal_count, "重新啟動後房間與門數量一致")
	check(main2.player.current_cell_id == "cell_0001", "回到離開時的房間")
	check(main2.save_now() == OK, "重讀後可再次存檔（A/B 輪替）")
	main2.queue_free()
	await process_frame
	ST.Io.remove_tree("user://palace")


# ------------------------------------------------------------------ (1f) 建材調整：夾在房間內、旋轉、移動

func test_structure_adjust() -> void:
	print("[1f] 建材調整（平台 / 欄桿 / 斜坡）")
	var m = SM.PalaceModel.new()
	var c = m.create_cell("甲", "ivory", Vector3(8, 3, 6))
	var pl = m.add_platform(c.id, Vector3(1, 0.3, 1), Vector2(2, 2), 0.3)
	check(m.adjust_structure(pl.id, "size_x", 1.0)["changed"] and near(pl.size.x, 3.0), "平台加寬 1 m")
	m.adjust_structure(pl.id, "size_x", 100.0)
	check(near(pl.size.x, 7.0), "平台寬度夾在房間內（x=1 → 最多 7）")
	m.adjust_structure(pl.id, "size_z", -100.0)
	check(near(pl.size.y, 0.5), "平台最小 0.5 m")
	m.adjust_structure(pl.id, "height", 0.5)
	check(near(pl.pos.y, 0.8), "平台高度 +0.5")
	m.adjust_structure(pl.id, "height", 100.0)
	check(near(pl.pos.y, 2.7), "平台高度最高到天花板下 0.3 m")
	check(not m.adjust_structure(pl.id, "length", 1.0)["ok"], "平台沒有 length 操作")
	m.move_structure(pl.id, Vector3(100, 0.3, -5))
	check(near(pl.pos.x, 7.5) and near(pl.pos.z, 0.0), "平台移動後夾在房間內")
	check(near(pl.size.x, 0.5), "平台靠邊時尺寸跟著縮到放得下")

	var rl = m.add_railing(c.id, Vector3(2, 0, 2), Vector3.RIGHT, 2.0)
	m.adjust_structure(rl.id, "length", 1.0)
	check(near(rl.length, 3.0), "欄桿加長")
	m.adjust_structure(rl.id, "length", 100.0)
	check(near(rl.length, 6.0), "欄桿長度夾在牆內（x=2 往 +X 最多 6）")
	m.adjust_structure(rl.id, "rotate")
	check(rl.horizontal_dir().is_equal_approx(Vector3(0, 0, 1)), "欄桿轉 90°：+X → +Z")
	check(near(rl.length, 4.0), "轉向後長度夾到新方向可用空間（z=2 往 +Z 最多 4）")
	m.adjust_structure(rl.id, "rotate")
	m.adjust_structure(rl.id, "rotate")
	m.adjust_structure(rl.id, "rotate")
	check(rl.horizontal_dir().is_equal_approx(Vector3(1, 0, 0)), "轉四次回到原方向")

	var rp = m.add_ramp(c.id, Vector3(1, 0, 3), Vector3.RIGHT, 1.0, 2.0, 1.0)
	m.adjust_structure(rp.id, "height", 0.5)
	m.adjust_structure(rp.id, "length", 1.0)
	m.adjust_structure(rp.id, "width", 1.0)
	check(near(rp.height, 1.5) and near(rp.length, 3.0) and near(rp.width, 2.0), "斜坡高 / 長 / 寬各自調整")
	m.adjust_structure(rp.id, "width", 100.0)
	check(near(rp.width, 6.0), "斜坡寬度夾在兩側牆內（z=3 → 最寬 6）")
	m.adjust_structure(rp.id, "height", 100.0)
	check(near(rp.height, 2.8), "斜坡最高 = 房高 − 0.2")
	check(not m.adjust_structure("nope", "length", 1.0)["ok"], "找不到建材")
	check(m.validate().is_empty(), "調整後資料完整")
	# 擴建仍可作用在調整後的建材
	var r: Dictionary = m.split_and_stretch(c.id, 0, 4.0, 2.0)
	check(r["ok"] and m.validate().is_empty(), "調整後的建材可以正常擴建")


func test_font_setup() -> void:
	print("[1g] 系統中文字型挑選")
	check(FS.rank_name("NotoSansTC-Regular.otf") == 0, "NotoSansTC 排第一")
	check(FS.rank_name("NotoSansCJK-Regular.ttc") < FS.rank_name("DroidSansFallback.ttf"), "CJK 合集優先於 DroidSansFallback")
	check(FS.rank_name("Roboto-Regular.ttf") == -1, "拉丁字型不算中文字型")
	check(FS.rank_name("readme.txt") == -1, "非字型檔略過")
	check(FS.rank_name("NotoSansCJK-Bold.ttc") > FS.rank_name("NotoSansCJK-Regular.ttc"), "粗體排在一般體之後")
	var files := PackedStringArray(["Roboto-Regular.ttf", "NotoSansCJK-Bold.ttc", "DroidSansFallback.ttf", "NotoSansCJK-Regular.ttc", "x.txt"])
	check(FS.pick(files) == "NotoSansCJK-Regular.ttc", "pick 選出 NotoSansCJK-Regular.ttc")
	check(FS.pick(PackedStringArray(["Roboto-Regular.ttf"])) == "", "沒有中文字型 → 空字串")
	check(FS.pick(PackedStringArray(["SECCJK-Regular.otf"])) == "SECCJK-Regular.otf", "三星字型也認得")


## 自動跨階：0.3 m 的台階走得上去，0.6 m 的擋得住
func test_player_step_up() -> void:
	print("[5f] 玩家控制：膝蓋自動跨階（0.35 m）")
	await process_frame
	var m = SM.PalaceModel.new()
	var a = m.create_cell("甲", "ivory", Vector3(10, 3, 6))
	m.add_platform(a.id, Vector3(3, 0.3, 1), Vector2(3, 4), 0.3)      # 頂面 0.3：低台階
	m.add_platform(a.id, Vector3(7, 0.6, 1), Vector2(2, 4), 0.6)      # 頂面 0.6：太高
	m.activate_cell(a.id)
	var scene := Node3D.new()
	root.add_child(scene)
	scene.add_child(RB.build_cell(m, a.id))
	var player = PC.new()
	scene.add_child(player)
	player.setup(m, null)
	player.place_in_cell(a.id, Vector3(1, 0.05, 3), -PI / 2.0)
	for i in range(30):
		await physics_frame
	player.move_input = Vector2(0, -1)
	for i in range(100):
		await physics_frame
		if player.global_position.x > 4.0:
			break
	check(player.global_position.x > 4.0 and absf(player.global_position.y - 0.3) < 0.06, "0.3 m 台階：自動跨上去（x=%.2f y=%.2f）" % [player.global_position.x, player.global_position.y])
	for i in range(150):
		await physics_frame
		if player.global_position.x > 6.0:
			break
	check(player.global_position.x > 5.8, "走過台階頂面（x=%.2f）" % player.global_position.x)
	for i in range(120):
		await physics_frame
	check(player.global_position.x < 7.0 and player.global_position.y < 0.1, "從台階走下來後被 0.6 m 的高台擋住（x=%.2f y=%.2f）" % [player.global_position.x, player.global_position.y])
	player.move_input = Vector2.ZERO
	scene.queue_free()
	await process_frame
