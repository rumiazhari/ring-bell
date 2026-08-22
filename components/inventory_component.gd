class_name InventoryComponent
extends Node
## Simple stack-based inventory: {item_id(StringName): count}.
##
## Item semantics live in ItemDB; this component only stores counts.
## Used by player, NPCs (they feed themselves) and world containers.

signal changed

var items := {}  # StringName -> int


func add(id: StringName, count: int = 1) -> void:
	if count <= 0:
		return
	items[id] = int(items.get(id, 0)) + count
	changed.emit()


## Returns how many were actually removed.
func remove(id: StringName, count: int = 1) -> int:
	var have := int(items.get(id, 0))
	var taken := mini(have, count)
	if taken > 0:
		items[id] = have - taken
		if items[id] == 0:
			items.erase(id)
		changed.emit()
	return taken


func count(id: StringName) -> int:
	return int(items.get(id, 0))


func is_empty() -> bool:
	return items.is_empty()


## First item id whose ItemDB kind matches (e.g. "food"), or &"" when none.
func find_item_of_kind(kind: StringName) -> StringName:
	for id: StringName in items:
		var def := ItemDB.get_def(id)
		if def.get("kind", &"") == kind:
			return id
	return &""


## Moves up to `count` of `id` from `source` inventory into this one.
func take_from(source: InventoryComponent, id: StringName, count: int = 1) -> int:
	var moved := source.remove(id, count)
	if moved > 0:
		add(id, moved)
	return moved


func summary() -> String:
	if items.is_empty():
		return "(empty)"
	var parts: PackedStringArray = []
	for id: StringName in items:
		parts.append("%sx%d" % [ItemDB.item_name(id), items[id]])
	return ", ".join(parts)


func save_state() -> Dictionary:
	var out := {}
	for id: StringName in items:
		out[str(id)] = items[id]
	return out


func load_state(data: Dictionary) -> void:
	items.clear()
	for id in data:
		items[StringName(id)] = int(data[id])
