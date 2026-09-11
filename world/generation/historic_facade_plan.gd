class_name HistoricFacadePlan
extends RefCounted
## Openings are structural plan data, shared by shell construction and validation.

static func for_wing(spec: Dictionary) -> Array:
	var result: Array = []
	var fp: Rect2 = spec.rect
	var interior := InteriorPlan.build_for_building(spec)
	for floor_plan: Dictionary in interior.floors:
		var fi: int = floor_plan.floor_i
		var elevations: Array = []
		for side in 4:
			var openings: Array[Dictionary] = []
			var horizontal := side == 0 or side == 2
			var length := fp.size.x if horizontal else fp.size.y
			var entrance: bool = fi == 0 and (side == int(spec.door_edge) or (spec.get("extra_door_edges", []) as Array).has(side))
			for room: Dictionary in floor_plan.rooms:
				var r: Rect2 = room.rect
				var touches := [absf(r.position.y - fp.position.y - 0.37) < 0.02,
					absf(r.end.x - fp.end.x + 0.37) < 0.02,
					absf(r.end.y - fp.end.y + 0.37) < 0.02,
					absf(r.position.x - fp.position.x - 0.37) < 0.02]
				if not touches[side]:
					continue
				var start := r.position.x - fp.position.x if horizontal else r.position.y - fp.position.y
				var span := r.size.x if horizontal else r.size.y
				var service: bool = bool(room.service) or room.kind in [&"landing", &"stair_hall"]
				var shop: bool = fi == 0 and side == int(spec.door_edge) and room.kind in [&"sales", &"taproom", &"workshop", &"office"]
				var spacing := 3.2 if shop else (2.9 if str(spec.get("archetype", "")) in ["wealthy_compound", "institutional"] else 2.5)
				var bays := maxi(1, floori(span / spacing))
				for bay in bays:
					var center := start + span * (float(bay) + 0.5) / bays
					var width := minf(span / bays - 0.7, 1.9 if shop else (0.8 if service else 1.25))
					if width < 0.6 or (entrance and absf(center - length * 0.5) < float(spec.get("door_w", 1.5)) * 0.5 + width * 0.5 + 0.3):
						continue
					openings.append({"c": center, "wd": width, "bot": 0.5 if shop else (1.1 if service else 0.85),
						"h": 1.9 if shop else (1.0 if service else (1.55 if fi == 1 else 1.35)), "glass": true,
						"room_id": room.id, "kind": "shopfront" if shop else ("service" if service else "chamber")})
			elevations.append(openings)
		result.append(elevations)
	return result
