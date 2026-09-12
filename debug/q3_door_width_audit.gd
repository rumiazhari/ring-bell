extends Node
## Door-width audit: every city door the plan emits, with the kind-based width
## the single authoritative table in WorldConstants hands out. Proves the
## human-scale band on the REAL generated city instead of on a sample render.
## Run: --q3doorwidthaudit

func _ready() -> void:
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var hist := {}
	var lo := INF
	var hi := 0.0
	var total := 0
	var kinds := {}
	for spec: Dictionary in plan.city_buildings():
		for d: Dictionary in (spec.get("doors", []) as Array):
			var w := float(d.get("width", 0.0))
			var h := float(d.get("height", 0.0))
			var kind := str(d.get("kind", "?"))
			total += 1
			hist[w] = int(hist.get(w, 0)) + 1
			kinds[kind] = int(kinds.get(kind, 0)) + 1
			lo = minf(lo, w)
			hi = maxf(hi, w)
			if w < WorldConstants.CONTRACT_DOOR_W_MIN or w > WorldConstants.CONTRACT_DOOR_W_MAX:
				print("[DoorWidth] OUT OF BAND %s edge=%d width=%.3f h=%.3f" % [
					str(spec.get("id", "?")), int(d.get("edge", -1)), w, h])
	print("[DoorWidth] buildings=%d doors=%d min=%.3f max=%.3f band=[%.2f,%.2f]" % [
		plan.city_buildings().size(), total, lo, hi,
		WorldConstants.CONTRACT_DOOR_W_MIN, WorldConstants.CONTRACT_DOOR_W_MAX])
	var widths: Array = hist.keys()
	widths.sort()
	for w: float in widths:
		print("[DoorWidth] width=%.2f count=%d" % [w, int(hist[w])])
	var kk: Array = kinds.keys()
	kk.sort()
	for k: String in kk:
		print("[DoorWidth] kind=%s count=%d" % [k, int(kinds[k])])
	get_tree().quit(0)
