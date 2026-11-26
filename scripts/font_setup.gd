extends RefCounted
## font_setup.gd — 讓介面與 3D 文字能顯示中文
##
## Android 匯出的 App 不含中文字型，而 Godot 的內建字型只有拉丁字母，結果中文全變成方框（豆腐塊）。
## 解法：啟動時從手機系統字型資料夾找一個中文字型檔，載入成 FontFile，設為全域預設字型。
## 找不到時回傳 null、維持引擎預設（桌面測試環境通常如此）。
##
## 純函式 rank_name / pick 可無頭測試；實際讀檔只在 Android（或有這些資料夾的系統）上發生。

const FONT_DIRS := [
	"/system/fonts", "/system/font", "/product/fonts", "/system_ext/fonts",
	"/vendor/fonts", "/system/fonts/cjk",
]

## 優先順序：愈前面愈好（精確檔名，全小寫比對）
const PREFERRED := [
	"notosanstc-regular.otf", "notosanscjktc-regular.otf", "notosanscjk-regular.ttc",
	"notosanscjk-regular.otf", "sourcehansanstc-regular.otf", "notosanshant-regular.otf",
	"notosanssc-regular.otf", "notosanscjksc-regular.otf", "droidsansfallback.ttf",
	"droidsansfallbackfull.ttf", "sourcehansanscn-regular.otf",
]

const WEIGHT_WORDS := ["bold", "black", "thin", "light", "medium", "italic", "mono", "condensed", "demilight", "semibold"]
const CJK_TOKENS := ["cjk", "hant", "sourcehan", "notosanstc", "notosanssc", "droidsansfallback", "fallback", "seccjk", "misans", "hanyi", "harmonyos_sans_tc", "harmonyos_sans_sc"]

static var _font: Font = null
static var _tried := false
static var status := "未載入"      # 給除錯與提示用


## 檔名分數：越小越好；−1 = 不是可用的中文字型
static func rank_name(file_name: String) -> int:
	var n := file_name.to_lower()
	var ext := n.get_extension()
	if ext != "otf" and ext != "ttf" and ext != "ttc":
		return -1
	var idx := PREFERRED.find(n)
	if idx >= 0:
		return idx
	var base := 100
	var is_cjk := false
	for t in CJK_TOKENS:
		if n.contains(t):
			is_cjk = true
			break
	if not is_cjk:
		return -1
	if n.contains("tc") or n.contains("hant") or n.contains("tw") or n.contains("hk"):
		base = 40
	elif n.contains("cjk") or n.contains("sourcehan"):
		base = 50
	elif n.contains("fallback"):
		base = 60
	else:
		base = 70
	for w in WEIGHT_WORDS:
		if n.contains(w):
			base += 100
			break
	if n.contains("serif") and not n.contains("sans"):
		base += 100
	return base


## 從檔名清單挑最佳的一個；沒有可用回傳 ""
static func pick(files: PackedStringArray) -> String:
	var best := ""
	var best_rank := 1 << 30
	for f in files:
		var r := rank_name(f)
		if r >= 0 and r < best_rank:
			best_rank = r
			best = f
	return best


## 掃描系統字型資料夾，載入最佳的中文字型。結果會快取。
static func load_cjk() -> Font:
	if _tried:
		return _font
	_tried = true
	var best_path := ""
	var best_rank := 1 << 30
	for d in FONT_DIRS:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			var r := rank_name(f)
			if r >= 0 and r < best_rank:
				best_rank = r
				best_path = String(d).path_join(f)
	if best_path == "":
		status = "找不到系統中文字型"
		return null
	var ff := FontFile.new()
	var err := ff.load_dynamic_font(best_path)
	if err != OK:
		status = "載入失敗 %s（%d）" % [best_path, err]
		return null
	ff.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	ff.allow_system_fallback = true
	_font = ff
	status = "已載入 %s" % best_path
	return _font


## 設為全域預設字型。回傳是否成功載入中文字型。
static func install() -> bool:
	var f := load_cjk()
	if f == null:
		return false
	ThemeDB.fallback_font = f
	return true
