class_name AssetCatalog
extends RefCounted
## Deterministic asset registry — pure, no Node, no scene tree.
## Fallback policy: missing file → vertex-colored box a8a090.
## Scale/collision policy: scale 1.0, visual only unless has_collision true.
## Thread-safe via Mutex for worker/main access, deterministic across seeds/workers.
## No RNG, no autoload, no project setting.

static var _entries: Dictionary = {}
static var _mutex: Mutex = Mutex.new()

static func _ensure_default() -> void:
	# Register default wall_2m if empty (lazy init, deterministic).
	if not _entries.is_empty():
		return
	# Direct inline without lock recursion: caller holds lock if needed.
	var key := "wall:wall_2m"
	if not _entries.has(key):
		_entries[key] = {
			"category": &"wall",
			"id": &"wall_2m",
			"res_path": "res://art/modules/wall_2m.glb",
			"fallback_color": Color("a8a090"),
			"scale": 1.0,
			"has_collision": false,
		}

static func register(category: StringName, id: StringName, res_path: String, fallback_color: Color, scale: float, has_collision: bool) -> void:
	_mutex.lock()
	var key := String(category) + ":" + String(id)
	_entries[key] = {
		"category": category,
		"id": id,
		"res_path": res_path,
		"fallback_color": fallback_color,
		"scale": scale,
		"has_collision": has_collision,
	}
	_mutex.unlock()

static func has(category: StringName, id: StringName) -> bool:
	_mutex.lock()
	_ensure_default()
	var key := String(category) + ":" + String(id)
	var exists := _entries.has(key)
	_mutex.unlock()
	return exists

static func list(category: StringName) -> Array[StringName]:
	_mutex.lock()
	_ensure_default()
	var out: Array[StringName] = []
	for k in _entries.keys():
		var e: Dictionary = _entries[k] as Dictionary
		if StringName(e.get("category", "")) == category:
			out.append(e.get("id", &"") as StringName)
	_mutex.unlock()
	return out

static func resolve(category: StringName, id: StringName) -> Dictionary:
	_mutex.lock()
	_ensure_default()
	var key := String(category) + ":" + String(id)
	if not _entries.has(key):
		_mutex.unlock()
		return {
			"scene": null,
			"res_path": "",
			"fallback_color": Color("a8a090"),
			"scale": 1.0,
			"has_collision": false,
			"exists": false,
		}
	var e: Dictionary = _entries[key] as Dictionary
	var res_path: String = e.get("res_path", "") as String
	var fallback_color: Color = e.get("fallback_color", Color("a8a090")) as Color
	var scale_v: float = float(e.get("scale", 1.0))
	var has_collision_v: bool = bool(e.get("has_collision", false))
	# Probe existence without caching RNG — filesystem probe is seed-independent.
	var exists: bool = FileAccess.file_exists(res_path) or ResourceLoader.exists(res_path, "PackedScene")
	var scene = null
	if exists:
		# Guarded load — never hard crash if missing/invalid.
		if ResourceLoader.exists(res_path, "PackedScene"):
			var loaded = ResourceLoader.load(res_path)
			if loaded != null and loaded is PackedScene:
				scene = loaded
		elif FileAccess.file_exists(res_path):
			# Try load as PackedScene; may be glb awaiting import.
			var loaded2 = ResourceLoader.load(res_path)
			if loaded2 != null and loaded2 is PackedScene:
				scene = loaded2
			else:
				scene = null
		if scene != null and not (scene is PackedScene):
			scene = null
	var result := {
		"scene": scene,
		"res_path": res_path,
		"fallback_color": fallback_color,
		"scale": scale_v,
		"has_collision": has_collision_v,
		"exists": exists,
	}
	_mutex.unlock()
	return result

static func catalog() -> Dictionary:
	_mutex.lock()
	_ensure_default()
	var copy := _entries.duplicate(true)
	_mutex.unlock()
	return copy

static func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_mutex.unlock()

static func _catalog_version() -> int:
	return WorldConstants.ASSET_CATALOG_VERSION
