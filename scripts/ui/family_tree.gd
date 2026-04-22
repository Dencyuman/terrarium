class_name FamilyTreeView
extends Node2D

const VIEW_WIDTH: int = 720
const VIEW_HEIGHT: int = 720
const NODE_RADIUS: int = 16
const LABEL_FONT_SIZE: int = 11

var agents: Array = []
var font_bold: SystemFont

# 計算済みの世代レイアウト: generation_idx -> Array[Agent]
var _gen_rows: Array = []
# id -> {x, y} 座標
var _positions: Dictionary = {}

func _ready() -> void:
	font_bold = SystemFont.new()
	font_bold.font_names = PackedStringArray([
		"Hiragino Kaku Gothic Pro",
		"Hiragino Sans",
		"Noto Sans CJK JP",
		"Yu Gothic",
		"Meiryo",
	])
	font_bold.font_weight = 700

func set_agents(a: Array) -> void:
	agents = a
	_compute_layout()
	queue_redraw()

# 世代分類: parent_ids が空 = G1、parent_ids のうち世代が確定した祖先の最大世代 + 1 = 自分の世代。
# 親が agents リストに無い(誕生時の親がすでに vanished なケース)は無視。
func _compute_layout() -> void:
	_gen_rows = []
	_positions = {}
	if agents.is_empty():
		return
	var by_id: Dictionary = {}
	for a in agents:
		by_id[a.id] = a
	# 各 agent の世代を決める(トポロジカル順)
	var gen_of: Dictionary = {}
	var remaining: Array = []
	for a in agents:
		remaining.append(a)
	var safety: int = 0
	while not remaining.is_empty() and safety < 1000:
		safety += 1
		var progressed: bool = false
		var next_round: Array = []
		for a in remaining:
			var parents_known: bool = true
			var parent_gen_max: int = -1
			for pid in a.parent_ids:
				if not by_id.has(pid):
					continue   # 親が居なければその親は無視
				if not gen_of.has(pid):
					parents_known = false
					break
				parent_gen_max = max(parent_gen_max, int(gen_of[pid]))
			if parents_known:
				if a.parent_ids.is_empty() or parent_gen_max < 0:
					gen_of[a.id] = 0
				else:
					gen_of[a.id] = parent_gen_max + 1
				progressed = true
			else:
				next_round.append(a)
		remaining = next_round
		if not progressed:
			# 祖先が循環か欠損 → 残りは G0 に落とす(レイアウトを止めない)
			for a in remaining:
				gen_of[a.id] = 0
			break
	# 各世代の agent リストを構築
	var max_gen: int = 0
	for id_ in gen_of.keys():
		max_gen = max(max_gen, int(gen_of[id_]))
	_gen_rows.resize(max_gen + 1)
	for g in range(max_gen + 1):
		_gen_rows[g] = []
	for a in agents:
		var g: int = int(gen_of.get(a.id, 0))
		_gen_rows[g].append(a)
	# 各世代内で id 順に並べる(一貫した左右配置)
	for g in range(_gen_rows.size()):
		_gen_rows[g].sort_custom(func(x, y): return x.id < y.id)
	# 座標を割り当てる
	var top_y: float = 110.0
	var bottom_y: float = VIEW_HEIGHT - 80.0
	var rows: int = _gen_rows.size()
	var gen_step: float = 120.0 if rows <= 5 else max(80.0, (bottom_y - top_y) / float(max(1, rows - 1)))
	var margin: float = 40.0
	for g in range(rows):
		var row: Array = _gen_rows[g]
		var count: int = row.size()
		if count == 0:
			continue
		var row_w: float = float(VIEW_WIDTH) - margin * 2
		var step: float = row_w / float(max(1, count - 1)) if count > 1 else 0.0
		var start_x: float = margin if count > 1 else float(VIEW_WIDTH) / 2.0
		var y: float = top_y + float(g) * gen_step
		for i in range(count):
			var x: float = start_x + step * float(i)
			_positions[row[i].id] = Vector2(x, y)

func _draw() -> void:
	# 毎 redraw でレイアウトを再計算。reproduce による追加や死亡に即時追従させるため。
	_compute_layout()
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.137, 0.153, 0.184, 1), true)
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.208, 0.227, 0.263, 1), false, 1.0)
	_draw_header()
	_draw_parent_child_edges()
	_draw_generation_labels()
	_draw_nodes()
	_draw_legend()

func _draw_header() -> void:
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	draw_string(font_bold, Vector2(20, 32), "家系図", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, header_color)
	var summary := "世代: %d  ·  生存 %d / 総数 %d" % [
		_gen_rows.size(), _count_alive(), agents.size()
	]
	draw_string(font_bold, Vector2(20, 54), summary, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)
	draw_string(font_bold, Vector2(20, 72), "縦軸: 世代(上ほど古い) · 線: 親→子の血縁",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, sub_color)

func _count_alive() -> int:
	var n: int = 0
	for a in agents:
		if a.is_alive():
			n += 1
	return n

func _draw_generation_labels() -> void:
	var gen_color := Color(0.980, 0.820, 0.280, 1)
	for g in range(_gen_rows.size()):
		var row: Array = _gen_rows[g]
		if row.is_empty():
			continue
		var y: float = _positions[row[0].id].y
		draw_string(font_bold, Vector2(20, y + 5), "G%d" % (g + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, gen_color)

func _draw_parent_child_edges() -> void:
	var edge_alive := Color(0.74, 0.73, 0.70, 0.65)
	var edge_dead := Color(0.50, 0.50, 0.52, 0.30)
	for a in agents:
		if not _positions.has(a.id):
			continue
		var child_pos: Vector2 = _positions[a.id]
		for pid in a.parent_ids:
			if not _positions.has(pid):
				continue
			var parent_pos: Vector2 = _positions[pid]
			var parent_alive: bool = true
			for p in agents:
				if p.id == pid:
					parent_alive = p.is_alive()
					break
			var col: Color = edge_alive if (a.is_alive() and parent_alive) else edge_dead
			draw_line(parent_pos, child_pos, col, 1.2)

func _draw_nodes() -> void:
	for a in agents:
		if not _positions.has(a.id):
			continue
		var pos: Vector2 = _positions[a.id]
		if a.is_alive():
			var color: Color = a.badge_color()
			draw_circle(pos + Vector2(0, 2), NODE_RADIUS, Color(0, 0, 0, 0.35))
			draw_circle(pos, NODE_RADIUS, color)
			draw_arc(pos, NODE_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.8), 1.3)
			_draw_label(a.agent_name, pos, Color(1, 1, 1, 0.95))
		else:
			var base := Color(0.32, 0.32, 0.34, 0.85)
			draw_circle(pos + Vector2(0, 2), NODE_RADIUS, Color(0, 0, 0, 0.25))
			draw_circle(pos, NODE_RADIUS, base)
			draw_arc(pos, NODE_RADIUS, 0, TAU, 48, Color(0.10, 0.12, 0.16, 0.7), 1.0)
			_draw_label(a.agent_name, pos, Color(0.75, 0.72, 0.68, 0.70))
			# ✕ 印
			var r: float = NODE_RADIUS - 3
			var x_color := Color(0.88, 0.88, 0.88, 0.70)
			draw_line(pos + Vector2(-r, -r), pos + Vector2(r, r), x_color, 1.5)
			draw_line(pos + Vector2(-r, r), pos + Vector2(r, -r), x_color, 1.5)

func _draw_label(text: String, center: Vector2, color: Color) -> void:
	var text_size: Vector2 = font_bold.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, LABEL_FONT_SIZE)
	var ascent: float = font_bold.get_ascent(LABEL_FONT_SIZE)
	var descent: float = font_bold.get_descent(LABEL_FONT_SIZE)
	var baseline := Vector2(
		center.x - text_size.x / 2.0,
		center.y + (ascent - descent) / 2.0
	)
	draw_string(font_bold, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, color)

func _draw_legend() -> void:
	var lx := 20.0
	var ly := VIEW_HEIGHT - 50.0
	var sub := Color(0.541, 0.525, 0.502, 1)
	var body := Color(0.74, 0.73, 0.70, 1)
	draw_string(font_bold, Vector2(lx, ly), "凡例", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub)
	draw_string(font_bold, Vector2(lx, ly + 18), "生者: 色付き丸  ·  死者: 灰 ✕  ·  線: 親から子へ",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, body)
