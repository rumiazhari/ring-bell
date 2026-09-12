extends Node
## What a tree costs, per species and per detail tier.
##
## The city planting pass has to buy coverage (blank space filled) and quality
## (a crown that reads as a tree, not a stub) out of the same chunk box budget
## the buildings already dominate, so the tier it plants at has to be chosen
## against real numbers rather than by eye. `TreeBuilder.build` returns the
## manifest it emitted, so this needs no chunk, no terrain and no renderer.
##
## Launch: python tools/run_suite.py --treecost 300 0

const DETAILS := [TreeBuilder.Detail.IMPOSTOR, TreeBuilder.Detail.STREET,
	TreeBuilder.Detail.CITY, TreeBuilder.Detail.FEATURE]
const NAMES := ["IMPOSTOR", "STREET", "CITY", "FEATURE"]


func _ready() -> void:
	_run()


func _run() -> void:
	var species: Array[StringName] = [&"linden", &"oak", &"pine", &"spruce",
		&"birch", &"beech", &"maple", &"ash", &"chestnut", &"locust"]
	for i in DETAILS.size():
		var detail: int = DETAILS[i]
		var parts_total := 0
		var verts_total := 0
		var worst_parts := 0
		var worst_verts := 0
		var worst_species := &""
		var line: Array[String] = []
		for j in species.size():
			var b := MeshBatcher.new()
			var info := TreeBuilder.build(b, Vector3.ZERO, species[j], {
				"seed": 4242 + j * 977, "yaw": 0.3, "detail": detail})
			var parts := int(info["parts"])
			var verts := int(info["verts"])
			parts_total += parts
			verts_total += verts
			if verts > worst_verts:
				worst_verts = verts
				worst_parts = parts
				worst_species = species[j]
			line.append("%s=%d/%d" % [species[j], parts, verts])
		print("[TreeCost] %s mean_parts=%.1f mean_verts=%.0f worst=%s %d/%.0f  |  %s" % [
			NAMES[i], float(parts_total) / species.size(),
			float(verts_total) / species.size(), worst_species, worst_parts,
			float(worst_verts), " ".join(line)])
	print("[TreeCost] a 64 m city chunk is budgeted 30000 boxes / 13500 colliders / 700000 verts (debug/chunk_budget_test.gd); the dense core chunk already spends ~27000 boxes on buildings")
	get_tree().quit(0)
