extends RefCounted
## storage.gd — 雜湊、資源庫、A/B 雙緩衝存檔、設定檔、備份包
##
## 本檔只使用 FileAccess / DirAccess / HashingContext / JSON / ZIPPacker / ZIPReader，
## 完全不碰 RenderingServer、Texture、Mesh 或場景樹，因此可在 godot --headless（CI）下完整測試。
## 圖片轉立牌、GLB/OBJ 減面等需要 GPU 資源的工作，放在 memory_node_view.gd（第 3 批），
## 它們只呼叫本檔的 AssetStore 取得位元組。
##
## 用法：
##   const ST = preload("res://scripts/storage.gd")
##   var assets = ST.AssetStore.new("user://")   # root 可為 user:// 或任一可寫目錄


class Hashing:
	static func sha256_bytes(data: PackedByteArray) -> String:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		if data.size() > 0:
			ctx.update(data)
		return ctx.finish().hex_encode()

	static func sha256_text(text: String) -> String:
		return sha256_bytes(text.to_utf8_buffer())


class Io:
	static func ensure_dir(path: String) -> Error:
		if DirAccess.dir_exists_absolute(path):
			return OK
		return DirAccess.make_dir_recursive_absolute(path)

	static func read_bytes(path: String) -> PackedByteArray:
		if not FileAccess.file_exists(path):
			return PackedByteArray()
		return FileAccess.get_file_as_bytes(path)

	static func read_text(path: String) -> String:
		if not FileAccess.file_exists(path):
			return ""
		return FileAccess.get_file_as_string(path)

	## 解析 JSON；失敗回傳 null（不會在引擎輸出錯誤訊息）
	static func parse_json(text: String) -> Variant:
		var j := JSON.new()
		if j.parse(text) != OK:
			return null
		return j.data

	## 先寫 .tmp → 重新計算 SHA-256 驗證 → 才替換正式檔。
	static func write_verified(path: String, bytes: PackedByteArray) -> Error:
		var tmp := path + ".tmp"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			return FileAccess.get_open_error()
		f.store_buffer(bytes)
		f.flush()
		f.close()
		f = null
		if FileAccess.get_sha256(tmp) != Hashing.sha256_bytes(bytes):
			DirAccess.remove_absolute(tmp)
			return ERR_FILE_CORRUPT
		var err := DirAccess.rename_absolute(tmp, path)
		if err != OK:
			# 部分平台 rename 不會覆蓋既有檔案
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
			err = DirAccess.rename_absolute(tmp, path)
		if err != OK:
			DirAccess.remove_absolute(tmp)
		return err

	static func remove_tree(path: String) -> void:
		var d := DirAccess.open(path)
		if d == null:
			return
		for f in d.get_files():
			DirAccess.remove_absolute(path.path_join(f))
		for sub in d.get_directories():
			remove_tree(path.path_join(sub))
		DirAccess.remove_absolute(path)


## 內容定址資源庫：檔名 = <SHA-256>.<副檔名>，相同雜湊只存一份。
class AssetStore:
	const MAX_BYTES := 64 * 1024 * 1024
	const TYPE_IMAGE := "image"
	const TYPE_MODEL := "model"

	var dir: String

	func _init(root: String) -> void:
		dir = root.path_join("assets")
		Io.ensure_dir(dir)

	## 以內容魔數判斷類型；OBJ 為純文字，需 hint_ext == "obj" 且前段含頂點行。
	## 回傳 {"type","ext"}，無法辨識則回傳空字典。
	static func detect(bytes: PackedByteArray, hint_ext: String = "") -> Dictionary:
		var n := bytes.size()
		if n >= 8 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
			return {"type": TYPE_IMAGE, "ext": "png"}
		if n >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
			return {"type": TYPE_IMAGE, "ext": "jpg"}
		if n >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 \
				and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
			return {"type": TYPE_IMAGE, "ext": "webp"}
		if n >= 12 and bytes[0] == 0x67 and bytes[1] == 0x6C and bytes[2] == 0x54 and bytes[3] == 0x46:
			return {"type": TYPE_MODEL, "ext": "glb"}
		# OBJ 是純文字：副檔名是 obj，或（Android 內容 URI 常看不到副檔名時）內容同時有頂點行 v 與面行 f
		if n > 0 and n < MAX_BYTES:
			var head := bytes.slice(0, mini(n, 8192)).get_string_from_utf8()
			var padded := "\n" + head
			var has_v := padded.contains("\nv ")
			if has_v and (hint_ext.to_lower() == "obj" or padded.contains("\nf ")):
				return {"type": TYPE_MODEL, "ext": "obj"}
		return {}

	func import_bytes(bytes: PackedByteArray, hint_ext: String = "") -> Dictionary:
		if bytes.size() == 0:
			return {"ok": false, "error": "empty"}
		if bytes.size() > MAX_BYTES:
			return {"ok": false, "error": "too_large"}
		var info := detect(bytes, hint_ext)
		if info.is_empty():
			return {"ok": false, "error": "unsupported_format"}
		var h := Hashing.sha256_bytes(bytes)
		var ext: String = info["ext"]
		var dest := dir.path_join("%s.%s" % [h, ext])
		var deduped := FileAccess.file_exists(dest)
		if not deduped:
			var err := Io.write_verified(dest, bytes)
			if err != OK:
				return {"ok": false, "error": "write_failed:%d" % err}
		return {"ok": true, "hash": h, "type": info["type"], "ext": ext, "path": dest, "deduped": deduped, "size": bytes.size()}

	## 由路徑匯入（桌面路徑、或 Android 檔案選擇器回傳的路徑 / content:// URI）。
	## 不用 file_exists 預先判斷（content URI 不一定支援），直接開啟並回報錯誤碼。
	func import_file(path: String) -> Dictionary:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			var code := FileAccess.get_open_error()
			return {"ok": false, "error": "file_not_found" if code == ERR_FILE_NOT_FOUND else "open_failed:%d" % code}
		var bytes := f.get_buffer(f.get_length())
		f.close()
		return import_bytes(bytes, path.get_extension())

	func find_path(hash: String) -> String:
		for f in DirAccess.get_files_at(dir):
			if f.begins_with(hash + "."):
				return dir.path_join(f)
		return ""

	func has_asset(hash: String) -> bool:
		return find_path(hash) != ""

	func read_asset(hash: String) -> PackedByteArray:
		var p := find_path(hash)
		return Io.read_bytes(p) if p != "" else PackedByteArray()

	## 重新計算檔案雜湊並與檔名比對
	func verify_asset(hash: String) -> bool:
		var p := find_path(hash)
		return p != "" and FileAccess.get_sha256(p) == hash

	func list_hashes() -> Array:
		var out: Array = []
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".tmp"):
				continue
			out.append(f.get_basename())
		out.sort()
		return out

	func count() -> int:
		return list_hashes().size()


## 外部檔案匯入來源：
##   1. 主要：Godot 4.4 原生系統檔案選擇器 DisplayServer.file_dialog_show（Android 10+ 可用，走系統 SAF，免權限）。
##   2. 保底：掃描 <root>/import_drop/ 資料夾（備用按鈕），匯入成功的檔案移到 import_drop/_imported/。
## 兩者最後都交給 AssetStore（魔數辨識 + SHA-256 去重），所以挑到非支援格式只會被拒絕、不會污染資料。
class ImportSources:
	const DROP_DIR_NAME := "import_drop"
	const DONE_DIR_NAME := "_imported"
	const EXTENSIONS := ["png", "jpg", "jpeg", "webp", "glb", "obj"]

	var drop_dir: String

	func _init(root: String) -> void:
		drop_dir = root.path_join(DROP_DIR_NAME)
		Io.ensure_dir(drop_dir)

	## 目前這個執行環境是否有原生檔案選擇器（無頭 / 舊版 Android 為 false）
	static func native_supported() -> bool:
		return DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)

	## 開啟原生選擇器（可多選）。callback 簽名：func(status: bool, paths: PackedStringArray, filter_index: int)
	## 不支援時回傳 ERR_UNAVAILABLE，呼叫端應改顯示「備用匯入」按鈕。
	## Android 不傳副檔名過濾：該平台的過濾是 MIME 型別，.glb / .obj 常沒有對應 MIME 而被系統灰掉；
	## 改由 AssetStore 以檔案內容判斷格式。
	static func open_native(callback: Callable, title: String = "選擇圖片或 3D 模型") -> Error:
		if not native_supported():
			return ERR_UNAVAILABLE
		var filters := PackedStringArray()
		if OS.get_name() != "Android":
			filters.append("*.png, *.jpg, *.jpeg, *.webp, *.glb, *.obj; 圖片與 3D 模型")
		return DisplayServer.file_dialog_show(title, "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILES, filters, callback)

	static func is_supported_name(file_name: String) -> bool:
		return EXTENSIONS.has(file_name.get_extension().to_lower())

	## 備用資料夾中待匯入的檔案（完整路徑，已排序）
	func scan_drop() -> Array:
		var out: Array = []
		for f in DirAccess.get_files_at(drop_dir):
			if is_supported_name(f):
				out.append(drop_dir.path_join(f))
		out.sort()
		return out

	## 匯入一批路徑。results 內每筆含 path / hash / type / deduped，供 UI 建立記憶物件。
	func import_paths(paths: Variant, assets) -> Dictionary:
		var results: Array = []
		var failed: Array = []
		var deduped := 0
		for p in paths:
			var path := str(p)
			var r: Dictionary = assets.import_file(path)
			if r["ok"]:
				results.append({"path": path, "hash": r["hash"], "type": r["type"], "deduped": r["deduped"]})
				if r["deduped"]:
					deduped += 1
			else:
				failed.append({"path": path, "error": r["error"]})
		return {"ok": results.size() > 0, "results": results, "failed": failed, "deduped": deduped}

	## 備用按鈕：掃描 import_drop/ → 匯入 → 把成功的檔案移到 _imported/（避免重複列出）
	func import_drop(assets) -> Dictionary:
		var summary := import_paths(scan_drop(), assets)
		var done_dir := drop_dir.path_join(DONE_DIR_NAME)
		Io.ensure_dir(done_dir)
		var moved := 0
		for r in summary["results"]:
			var src: String = r["path"]
			var dst := done_dir.path_join(src.get_file())
			if FileAccess.file_exists(dst):
				dst = done_dir.path_join("%d_%s" % [Time.get_ticks_usec(), src.get_file()])
			if DirAccess.rename_absolute(src, dst) == OK:
				moved += 1
		summary["moved"] = moved
		summary["drop_dir"] = drop_dir
		return summary


## A/B 雙緩衝存檔：兩個槽位輪流寫入，每個槽位是帶序號與 SHA-256 的信封檔。
## 寫入流程：選「較舊 / 無效」的槽位 → 寫 .tmp → 驗證雜湊 → 替換 → 再讀回驗證。
## 另一個槽位保持不動，因此任何時刻至少有一份完整存檔（也就是上一版快照）。
class SaveStore:
	const FORMAT := 1

	var dir: String

	func _init(root: String) -> void:
		dir = root.path_join("saves")
		Io.ensure_dir(dir)
		for s in ["a", "b"]:
			var stale: String = slot_path(s) + ".tmp"
			if FileAccess.file_exists(stale):
				DirAccess.remove_absolute(stale)

	func slot_path(slot: String) -> String:
		return dir.path_join("slot_%s.json" % slot)

	func read_slot(slot: String) -> Dictionary:
		var res := {"slot": slot, "valid": false, "seq": 0, "data": {}, "reason": ""}
		var path := slot_path(slot)
		if not FileAccess.file_exists(path):
			res["reason"] = "missing"
			return res
		var env: Variant = Io.parse_json(Io.read_text(path))
		if not (env is Dictionary):
			res["reason"] = "bad_envelope"
			return res
		var e: Dictionary = env
		if not (e.has("payload") and e.has("sha256") and e.has("seq")):
			res["reason"] = "bad_envelope"
			return res
		var payload := str(e["payload"])
		if Hashing.sha256_text(payload) != str(e["sha256"]):
			res["reason"] = "hash_mismatch"
			return res
		var data: Variant = Io.parse_json(payload)
		if not (data is Dictionary):
			res["reason"] = "bad_payload"
			return res
		res["valid"] = true
		res["seq"] = int(e["seq"])
		res["data"] = data
		return res

	func save(data: Dictionary) -> Error:
		var a := read_slot("a")
		var b := read_slot("b")
		var target := "a"
		var seq := 1
		if a["valid"] and (not b["valid"] or int(a["seq"]) >= int(b["seq"])):
			target = "b"
			seq = int(a["seq"]) + 1
		elif b["valid"]:
			target = "a"
			seq = int(b["seq"]) + 1
		var payload := JSON.stringify(data)
		var env := {
			"format": FORMAT,
			"seq": seq,
			"sha256": Hashing.sha256_text(payload),
			"payload": payload,
		}
		var err := Io.write_verified(slot_path(target), JSON.stringify(env).to_utf8_buffer())
		if err != OK:
			return err
		var check := read_slot(target)
		if not check["valid"] or int(check["seq"]) != seq:
			return ERR_FILE_CORRUPT
		return OK

	## 讀取最新的有效存檔；若另一個槽位損毀（非單純不存在）則 recovered = true
	func load_latest() -> Dictionary:
		var a := read_slot("a")
		var b := read_slot("b")
		var best: Dictionary
		var other: Dictionary
		if a["valid"] and (not b["valid"] or int(a["seq"]) >= int(b["seq"])):
			best = a
			other = b
		elif b["valid"]:
			best = b
			other = a
		else:
			return {"ok": false, "error": "no_valid_slot", "recovered": false, "data": {}, "slot": "", "seq": 0}
		var recovered: bool = (not other["valid"]) and other["reason"] != "missing"
		return {"ok": true, "data": best["data"], "slot": best["slot"], "seq": best["seq"], "recovered": recovered}


## 獨立設定檔（靈敏度、門渲染上限、預留的按鍵佈局 / 左右鏡像）
class SettingsStore:
	const DEFAULTS := {
		"look_sensitivity": 1.0,
		"max_visible_portals": 6,
		"button_layout": "default",  # 預留
		"mirror_ui": false,          # 預留
	}

	var path: String
	var values: Dictionary = {}

	func _init(root: String) -> void:
		Io.ensure_dir(root)
		path = root.path_join("settings.json")
		values = DEFAULTS.duplicate(true)

	static func sanitize(raw: Dictionary) -> Dictionary:
		var out: Dictionary = DEFAULTS.duplicate(true)
		if raw.has("look_sensitivity"):
			out["look_sensitivity"] = clampf(float(raw["look_sensitivity"]), 0.2, 3.0)
		if raw.has("max_visible_portals"):
			out["max_visible_portals"] = clampi(int(raw["max_visible_portals"]), 1, 12)
		if raw.has("button_layout"):
			out["button_layout"] = "default"
		if raw.has("mirror_ui"):
			out["mirror_ui"] = bool(raw["mirror_ui"])
		return out

	func load_settings() -> Error:
		if not FileAccess.file_exists(path):
			values = DEFAULTS.duplicate(true)
			return OK
		var parsed: Variant = Io.parse_json(Io.read_text(path))
		if not (parsed is Dictionary):
			values = DEFAULTS.duplicate(true)
			return ERR_FILE_CORRUPT
		values = sanitize(parsed)
		return OK

	func save_settings() -> Error:
		return Io.write_verified(path, JSON.stringify(values, "\t").to_utf8_buffer())

	func set_value(key: String, v: Variant) -> void:
		if not DEFAULTS.has(key):
			return
		var merged: Dictionary = values.duplicate()
		merged[key] = v
		values = sanitize(merged)

	func get_value(key: String) -> Variant:
		return values.get(key, DEFAULTS.get(key))


## 備份包（標準 .zip）：manifest.json 記錄每個檔案的 SHA-256；匯入時逐檔驗證，
## 且只接受固定檔名樣式，拒絕任何路徑穿越。
class Backup:
	const MANIFEST := "manifest.json"
	const PALACE := "palace.json"
	const SETTINGS := "settings.json"
	const ASSET_PATTERN := "^assets/[0-9a-f]{64}\\.(png|jpg|webp|glb|obj)$"

	static func _put(packer: ZIPPacker, entry: String, bytes: PackedByteArray, files: Dictionary) -> Error:
		var err := packer.start_file(entry)
		if err != OK:
			return err
		err = packer.write_file(bytes)
		packer.close_file()
		files[entry] = Hashing.sha256_bytes(bytes)
		return err

	static func export_backup(zip_path: String, saves: SaveStore, assets: AssetStore, settings: SettingsStore) -> Error:
		var latest := saves.load_latest()
		if not latest["ok"]:
			return ERR_DOES_NOT_EXIST
		var packer := ZIPPacker.new()
		var err := packer.open(zip_path)
		if err != OK:
			return err
		var files := {}
		err = _put(packer, PALACE, JSON.stringify(latest["data"]).to_utf8_buffer(), files)
		if err == OK:
			err = _put(packer, SETTINGS, JSON.stringify(settings.values).to_utf8_buffer(), files)
		if err == OK:
			for h in assets.list_hashes():
				var p := assets.find_path(h)
				err = _put(packer, "assets/" + p.get_file(), Io.read_bytes(p), files)
				if err != OK:
					break
		if err == OK:
			var manifest := {
				"format": 1,
				"app": "app.memorypalace.offline",
				"created": int(Time.get_unix_time_from_system()),
				"files": files,
			}
			err = _put(packer, MANIFEST, JSON.stringify(manifest).to_utf8_buffer(), {})
		packer.close()
		return err

	## 驗證全部檔案後才回傳資料；資源寫入走 AssetStore（內容定址，重複匯入無害）。
	## 回傳 {"ok","palace","settings","assets_imported","assets_deduped"} 或 {"ok":false,"error"}
	static func import_backup(zip_path: String, assets: AssetStore) -> Dictionary:
		var reader := ZIPReader.new()
		var err := reader.open(zip_path)
		if err != OK:
			return {"ok": false, "error": "open_failed:%d" % err}
		var names := reader.get_files()
		if not names.has(MANIFEST):
			reader.close()
			return {"ok": false, "error": "no_manifest"}
		var manifest: Variant = Io.parse_json(reader.read_file(MANIFEST).get_string_from_utf8())
		if not (manifest is Dictionary) or not (manifest.get("files") is Dictionary):
			reader.close()
			return {"ok": false, "error": "bad_manifest"}
		var listed: Dictionary = manifest["files"]
		var re := RegEx.new()
		re.compile(ASSET_PATTERN)

		var palace: Variant = null
		var settings_data: Dictionary = {}
		var imported := 0
		var deduped := 0
		for entry in listed:
			var entry_name := str(entry)
			var is_asset := re.search(entry_name) != null
			if not (is_asset or entry_name == PALACE or entry_name == SETTINGS):
				reader.close()
				return {"ok": false, "error": "bad_entry:%s" % entry_name}
			if not names.has(entry_name):
				reader.close()
				return {"ok": false, "error": "missing_entry:%s" % entry_name}
			var bytes := reader.read_file(entry_name)
			if Hashing.sha256_bytes(bytes) != str(listed[entry]):
				reader.close()
				return {"ok": false, "error": "hash_mismatch:%s" % entry_name}
			if is_asset:
				var res := assets.import_bytes(bytes, entry_name.get_extension())
				if not res["ok"] or res["hash"] != entry_name.get_file().get_basename():
					reader.close()
					return {"ok": false, "error": "bad_asset:%s" % entry_name}
				if res["deduped"]:
					deduped += 1
				else:
					imported += 1
			else:
				var parsed: Variant = Io.parse_json(bytes.get_string_from_utf8())
				if not (parsed is Dictionary):
					reader.close()
					return {"ok": false, "error": "bad_json:%s" % entry_name}
				if entry_name == PALACE:
					palace = parsed
				else:
					settings_data = parsed
		reader.close()
		if palace == null:
			return {"ok": false, "error": "no_palace"}
		return {"ok": true, "palace": palace, "settings": settings_data, "assets_imported": imported, "assets_deduped": deduped}
