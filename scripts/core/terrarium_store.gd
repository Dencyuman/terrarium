class_name TerrariumStore
extends RefCounted

# v0.1.0-phase4.5 から導入した永続化バックエンド。
# godot-sqlite プラグイン(SQLite クラス)を使い、3 テーブル構成で保存する:
#   terrariums: マップ・キャスト・config を一塊にした再利用可能なシード定義
#   runs:       1 terrarium を走らせた 1 回分。コスト/トークン/生存者などのサマリ
#   events:     run 下の全イベント(action / event / llm_request / llm_response / tick_boundary)
# 既存の RunLogger (jsonl) は廃止し、main.gd からの同一シグネチャを本クラスが担う。

const DB_PATH: String = "user://terrarium.db"

var db = null                  # SQLite (godot-sqlite のクラス、動的取得)
var current_run_id: int = -1
var current_terrarium_id: int = -1
var current_terrarium_title: String = ""

# --- lifecycle ---

func open() -> bool:
	# godot-sqlite は GDExtension で "SQLite" クラスを ClassDB に登録する。
	if not ClassDB.class_exists("SQLite"):
		push_error("TerrariumStore: SQLite class not registered. Enable godot-sqlite plugin and relaunch editor.")
		return false
	db = ClassDB.instantiate("SQLite")
	db.path = DB_PATH
	if not db.open_db():
		push_error("TerrariumStore: cannot open db at %s" % DB_PATH)
		return false
	_ensure_schema()
	print("[TerrariumStore] opened %s" % ProjectSettings.globalize_path(DB_PATH))
	return true

func close() -> void:
	if db != null:
		db.close_db()
		db = null

func _ensure_schema() -> void:
	db.query("""
		CREATE TABLE IF NOT EXISTS terrariums (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL,
			description TEXT,
			created_at TEXT NOT NULL,
			world_size INTEGER NOT NULL,
			world_seed INTEGER NOT NULL,
			tick_per_day INTEGER NOT NULL,
			terrain_json TEXT,
			cast_json TEXT NOT NULL,
			config_json TEXT NOT NULL
		)
	""")
	db.query("""
		CREATE TABLE IF NOT EXISTS runs (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			terrarium_id INTEGER NOT NULL,
			title TEXT,
			started_at TEXT NOT NULL,
			ended_at TEXT,
			final_tick INTEGER DEFAULT 0,
			final_alive INTEGER DEFAULT 0,
			final_total INTEGER DEFAULT 0,
			provider TEXT,
			model TEXT,
			input_tokens INTEGER DEFAULT 0,
			output_tokens INTEGER DEFAULT 0,
			cost_usd REAL DEFAULT 0.0,
			state_json TEXT
		)
	""")
	# 既存 DB 用のマイグレーション: state_json カラムが無い場合は追加。
	# godot-sqlite は失敗時に error_message をセットし false を返すだけなので、
	# 既に存在する場合はそのまま無視する。
	db.query("ALTER TABLE runs ADD COLUMN state_json TEXT")
	db.query("""
		CREATE TABLE IF NOT EXISTS events (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			run_id INTEGER NOT NULL,
			tick INTEGER NOT NULL,
			ts TEXT NOT NULL,
			type TEXT NOT NULL,
			agent_id INTEGER,
			agent_name TEXT,
			kind TEXT,
			data_json TEXT NOT NULL
		)
	""")
	db.query("CREATE INDEX IF NOT EXISTS idx_events_run_tick ON events(run_id, tick)")
	db.query("CREATE INDEX IF NOT EXISTS idx_events_agent ON events(run_id, agent_id)")
	db.query("CREATE INDEX IF NOT EXISTS idx_events_type ON events(run_id, type)")
	db.query("""
		CREATE TABLE IF NOT EXISTS run_snapshots (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			run_id INTEGER NOT NULL,
			tick INTEGER NOT NULL,
			state_json TEXT NOT NULL
		)
	""")
	db.query("CREATE INDEX IF NOT EXISTS idx_snapshots_run_tick ON run_snapshots(run_id, tick)")

# --- terrariums ---

# data/config.json + data/names.json を 1 行の terrarium として登録(初回のみ)。
# 既に「default」が存在する場合はその ID を返すだけ。
func ensure_default_terrarium(config: Dictionary, names_data: Dictionary) -> int:
	var rows: Array = db.select_rows("terrariums", "title = 'default'", ["id"])
	if rows.size() > 0:
		var id_val: int = int(rows[0]["id"])
		current_terrarium_id = id_val
		current_terrarium_title = "default"
		return id_val
	var world_cfg: Dictionary = config.get("world", {})
	var cast: Array = names_data.get("agents", [])
	db.insert_row("terrariums", {
		"title": "default",
		"description": "data/config.json + data/names.json から自動生成された初期テラリウム",
		"created_at": _iso_now(),
		"world_size": int(world_cfg.get("size", 20)),
		"world_seed": int(world_cfg.get("seed", 0)),
		"tick_per_day": int(world_cfg.get("tick_per_day", 10)),
		"terrain_json": "",   # null だと seed から再生成される約束
		"cast_json": JSON.stringify(cast),
		"config_json": JSON.stringify(config),
	})
	var rows2: Array = db.select_rows("terrariums", "title = 'default'", ["id"])
	current_terrarium_id = int(rows2[0]["id"]) if rows2.size() > 0 else -1
	current_terrarium_title = "default"
	return current_terrarium_id

# 全 terrarium を新しい順で返す。各行に run_count と is_editable (action イベント 0 件なら編集可) を付加。
func list_terrariums() -> Array:
	if db == null:
		return []
	db.query("""
		SELECT
			t.id, t.title, t.description, t.created_at,
			t.world_size, t.world_seed, t.tick_per_day,
			(SELECT COUNT(*) FROM runs r WHERE r.terrarium_id = t.id) AS run_count,
			(SELECT COUNT(*) FROM events e JOIN runs r ON e.run_id = r.id
			 WHERE r.terrarium_id = t.id AND e.type = 'action') AS action_count
		FROM terrariums t
		ORDER BY t.id DESC
	""")
	var out: Array = []
	for row in db.query_result:
		var is_editable: bool = int(row.get("action_count", 0)) == 0
		row["is_editable"] = is_editable
		out.append(row)
	return out

func get_terrarium(terrarium_id: int) -> Dictionary:
	if db == null:
		return {}
	var rows: Array = db.select_rows("terrariums", "id = %d" % terrarium_id, ["*"])
	if rows.is_empty():
		return {}
	return rows[0]

func is_terrarium_editable(terrarium_id: int) -> bool:
	if db == null:
		return false
	db.query("""
		SELECT COUNT(*) AS c FROM events e
		JOIN runs r ON e.run_id = r.id
		WHERE r.terrarium_id = %d AND e.type = 'action'
	""" % terrarium_id)
	if db.query_result.is_empty():
		return true
	return int(db.query_result[0].get("c", 0)) == 0

# new terrarium を挿入。title / world_size / world_seed / tick_per_day / cast_json / config_json を渡す。
# terrain_json はオプション(空文字で seed 生成にフォールバック)。
func create_terrarium(data: Dictionary) -> int:
	if db == null:
		return -1
	db.insert_row("terrariums", {
		"title": str(data.get("title", "untitled")),
		"description": str(data.get("description", "")),
		"created_at": _iso_now(),
		"world_size": int(data.get("world_size", 20)),
		"world_seed": int(data.get("world_seed", 0)),
		"tick_per_day": int(data.get("tick_per_day", 10)),
		"terrain_json": str(data.get("terrain_json", "")),
		"cast_json": str(data.get("cast_json", "[]")),
		"config_json": str(data.get("config_json", "{}")),
	})
	db.query("SELECT last_insert_rowid() AS id")
	var res: Array = db.query_result
	return int(res[0]["id"]) if res.size() > 0 else -1

# 編集可能(action イベント 0 件)なら title / cast_json / config_json / world_seed 等を差し替える。
# 動作済みテラリウムには適用しない。
func update_terrarium(terrarium_id: int, data: Dictionary) -> bool:
	if not is_terrarium_editable(terrarium_id):
		return false
	var fields: Dictionary = {}
	for k in ["title", "description", "world_size", "world_seed", "tick_per_day", "terrain_json", "cast_json", "config_json"]:
		if data.has(k):
			fields[k] = data[k]
	if fields.is_empty():
		return true
	db.update_rows("terrariums", "id = %d" % terrarium_id, fields)
	return true

func delete_terrarium(terrarium_id: int) -> bool:
	if not is_terrarium_editable(terrarium_id):
		return false
	db.delete_rows("terrariums", "id = %d" % terrarium_id)
	return true

# --- runs ---

func start_run(terrarium_id: int, provider: String, model: String) -> int:
	db.insert_row("runs", {
		"terrarium_id": terrarium_id,
		"started_at": _iso_now(),
		"provider": provider,
		"model": model,
	})
	# last_insert_rowid() で id を取得
	db.query("SELECT last_insert_rowid() AS id")
	var res: Array = db.query_result
	current_run_id = int(res[0]["id"]) if res.size() > 0 else -1
	print("[TerrariumStore] started run id=%d (terrarium=%d, %s/%s)" % [current_run_id, terrarium_id, provider, model])
	return current_run_id

func list_all_runs() -> Array:
	# 全 run を新しい順で返す。terrarium_title を JOIN。
	if db == null:
		return []
	db.query("""
		SELECT
			r.id, r.terrarium_id, r.started_at, r.ended_at,
			r.final_tick, r.final_alive, r.final_total,
			r.provider, r.model, r.input_tokens, r.output_tokens, r.cost_usd,
			t.title AS terrarium_title
		FROM runs r
		LEFT JOIN terrariums t ON t.id = r.terrarium_id
		ORDER BY r.id DESC
	""")
	return db.query_result

func get_run(run_id: int) -> Dictionary:
	if db == null:
		return {}
	db.query("""
		SELECT
			r.*, t.title AS terrarium_title, t.world_size, t.world_seed
		FROM runs r
		LEFT JOIN terrariums t ON t.id = r.terrarium_id
		WHERE r.id = %d
	""" % run_id)
	if db.query_result.is_empty():
		return {}
	return db.query_result[0]

# 表示用イベントストリーム。llm_request / llm_response はノイズが多いので除外、
# action は succeeded=true のみ通す(失敗は wait 相当で流れが読みづらくなる)。
# agent_name_filter: 空配列なら全員、1 件以上なら該当 agent のみ
func list_events_for_run(run_id: int, agent_name_filter: Array = [], include_failed: bool = false) -> Array:
	if db == null:
		return []
	var where := "run_id = %d AND type IN ('action', 'event')" % run_id
	if agent_name_filter.size() > 0:
		var escaped: Array = []
		for name in agent_name_filter:
			escaped.append("'%s'" % str(name).replace("'", "''"))
		where += " AND agent_name IN (%s)" % ",".join(escaped)
	db.query("SELECT tick, ts, type, agent_name, kind, data_json FROM events WHERE " + where + " ORDER BY id ASC")
	var out: Array = []
	for row in db.query_result:
		if not include_failed and str(row["type"]) == "action":
			var d = JSON.parse_string(str(row.get("data_json", "{}")))
			if d is Dictionary and not bool(d.get("succeeded", true)):
				continue
		out.append(row)
	return out

func list_run_agent_names(run_id: int) -> Array:
	if db == null:
		return []
	db.query("SELECT DISTINCT agent_name FROM events WHERE run_id = %d AND agent_name != '' ORDER BY agent_name" % run_id)
	var out: Array = []
	for row in db.query_result:
		out.append(str(row["agent_name"]))
	return out

func find_active_run(terrarium_id: int) -> int:
	# ended_at が NULL の最新 run を返す。無ければ -1。
	if db == null:
		return -1
	db.query("""
		SELECT id FROM runs
		WHERE terrarium_id = %d AND (ended_at IS NULL OR ended_at = '')
		ORDER BY id DESC LIMIT 1
	""" % terrarium_id)
	if db.query_result.is_empty():
		return -1
	return int(db.query_result[0].get("id", -1))

func attach_run(run_id: int, terrarium_title: String) -> void:
	# 再開時に既存 run_id を引き継ぐ
	current_run_id = run_id
	current_terrarium_title = terrarium_title

func save_state(state: Dictionary) -> void:
	if current_run_id < 0 or db == null:
		return
	db.update_rows("runs", "id = %d" % current_run_id, {
		"state_json": JSON.stringify(state),
	})

func save_tick_snapshot(tick: int, state: Dictionary) -> void:
	# tick 境界ごとのビジュアルリプレイ用ヒストリカルスナップショット。
	# 既に同じ (run_id, tick) があれば上書きする。
	if current_run_id < 0 or db == null:
		return
	var where := "run_id = %d AND tick = %d" % [current_run_id, tick]
	db.delete_rows("run_snapshots", where)
	db.insert_row("run_snapshots", {
		"run_id": current_run_id,
		"tick": tick,
		"state_json": JSON.stringify(state),
	})

func list_snapshot_ticks(run_id: int) -> Array:
	if db == null:
		return []
	db.query("SELECT DISTINCT tick FROM run_snapshots WHERE run_id = %d ORDER BY tick ASC" % run_id)
	var out: Array = []
	for row in db.query_result:
		out.append(int(row["tick"]))
	return out

func load_tick_snapshot(run_id: int, tick: int) -> Dictionary:
	if db == null:
		return {}
	var rows: Array = db.select_rows("run_snapshots", "run_id = %d AND tick = %d" % [run_id, tick], ["state_json"])
	if rows.is_empty():
		return {}
	var s: String = str(rows[0].get("state_json", ""))
	if s == "":
		return {}
	var parsed = JSON.parse_string(s)
	return parsed if parsed is Dictionary else {}

func load_state(run_id: int) -> Dictionary:
	if db == null:
		return {}
	var rows: Array = db.select_rows("runs", "id = %d" % run_id, ["state_json"])
	if rows.is_empty():
		return {}
	var s: String = str(rows[0].get("state_json", ""))
	if s == "":
		return {}
	var parsed = JSON.parse_string(s)
	return parsed if parsed is Dictionary else {}

func end_run(final_tick: int, final_alive: int, final_total: int, in_tokens: int, out_tokens: int, cost_usd: float) -> void:
	if current_run_id < 0 or db == null:
		return
	db.update_rows("runs", "id = %d" % current_run_id, {
		"ended_at": _iso_now(),
		"final_tick": final_tick,
		"final_alive": final_alive,
		"final_total": final_total,
		"input_tokens": in_tokens,
		"output_tokens": out_tokens,
		"cost_usd": cost_usd,
	})

# run 進行中の軽量更新。tick 境界で呼んで DB に現況を反映する(ended_at は触らない)。
func update_run_stats(final_tick: int, final_alive: int, final_total: int, in_tokens: int, out_tokens: int, cost_usd: float) -> void:
	if current_run_id < 0 or db == null:
		return
	db.update_rows("runs", "id = %d" % current_run_id, {
		"final_tick": final_tick,
		"final_alive": final_alive,
		"final_total": final_total,
		"input_tokens": in_tokens,
		"output_tokens": out_tokens,
		"cost_usd": cost_usd,
	})

# --- event writers (RunLogger 互換のシグネチャ) ---

func log_event(tick: int, event: Dictionary) -> void:
	_insert_event(tick, "event", -1, "", str(event.get("kind", "")), event)

func log_action(tick: int, agent_name: String, action: Dictionary) -> void:
	_insert_event(tick, "action", _agent_id_from_action(action), agent_name, str(action.get("kind", "")), action)

func log_llm_request(tick: int, agent_name: String, user_prompt: String) -> void:
	_insert_event(tick, "llm_request", -1, agent_name, "", {"user_prompt": user_prompt})

func log_llm_response(tick: int, agent_name: String, body: String, latency_ms: int) -> void:
	_insert_event(tick, "llm_response", -1, agent_name, "", {"body": body, "latency_ms": latency_ms})

func log_tick_boundary(tick: int, day: int, alive: int) -> void:
	_insert_event(tick, "tick_boundary", -1, "", "", {"day": day, "alive": alive})

func _insert_event(tick: int, type_: String, agent_id: int, agent_name: String, kind: String, data: Dictionary) -> void:
	if current_run_id < 0 or db == null:
		return
	db.insert_row("events", {
		"run_id": current_run_id,
		"tick": tick,
		"ts": _iso_now(),
		"type": type_,
		"agent_id": agent_id,
		"agent_name": agent_name,
		"kind": kind,
		"data_json": JSON.stringify(data),
	})

func _agent_id_from_action(action: Dictionary) -> int:
	# action data は {kind, direction, target_id, ...} 形式。agent_id は main.gd 側が知るが、
	# シグネチャ互換のため agent_name だけで保持しているので -1 に倒す。
	return -1

# --- utility ---

func _iso_now() -> String:
	return Time.get_datetime_string_from_system()
