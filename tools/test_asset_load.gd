extends SceneTree
func _init():
	var s = load("res://art/asset_catalog.gd")
	print("load result", s)
	if s != null:
		print("has AssetCatalog", s.get_global_name() if s.has_method("get_global_name") else "no")
		var inst = s.new()
		print("inst", inst)
		var has = s.has("wall", &"wall_2m")
		print("has wall", has)
	quit()
