class_name BuildingSpec
extends RefCounted
## Universal Building Contract (G10-P2A) spec factory + aperture math.
##
## A BuildingSpec is PLAIN DATA - a Dictionary - exactly like every plan
## layer already produces (CityPlan, FringePlan, RuralBuildingPlan...).
## This class is the contract's canonical *shape*: it normalises generator
## vocab onto contract vocab (quality, archetype), derives the reference
## aperture math that the BUILDING path must match (windows - never fake),
## and is the only place a plan-facing dictionary is recognised as a
## building spec.
##
## Spec keys (FULL_BUILDING):
##   id, quality, archetype, use, district, source
##   footprint: EITHER rect:Rect2 (city) OR center:Vector2 + footprint:Vector2
##              + yaw:float (rural) - irregular polygon mode arrives via
##              `points:PackedVector2Array` (see polygon_area); the assembler
##              must reject polygon mode until implemented, never fake it.
##   floors, floor_h, ground_y, building_ground_y
##   foundation_modules:Array[Dictionary] (optional elevated-ground support),
##   access:Dictionary (optional porch/veranda/none + exterior ramp)
##   door_edge (city), doors:Array[Dictionary] (city) OR door_pos/door_width/
##   door_height (rural), circulation:{kind}, interior:Dictionary (rural),
##   style:Dictionary, use (city)
##
## QUALITY TYPES (enforced): FULL_BUILDING / DISTANT_LOD / PROP_STRUCTURE.
## A house, inn, apartment, factory, etc. cannot be PROPed to dodge an
## interior (see BuildingArchetype.min_quality and the validator).

const WALL_T := 0.35            # reference: BuildingBuilder.WALL_T
const DOOR_W := 1.5             # reference: BuildingBuilder.DOOR_W
const DOOR_FRAME := 0.06
const DOOR_H := 2.25
const WIN_W := 1.15
const WIN_H := 1.35
const WIN_SILL := 0.85
const WIN_SPACING := 2.4


## Normalise a generator dictionary into a contract spec IN PLACE-CONTEXT:
## returns a NEW dictionary with quality/archetype/source defaults filled in,
## preserving every original key (lossless - the assembled geometry must
## match generator intent byte for byte for deterministic streaming).
static func normalize(spec: Dictionary, source: StringName = &"") -> Dictionary:
	var out := (spec.duplicate(true) as Dictionary)
	if not out.has("quality"):
		out["quality"] = WorldConstants.BUILDING_QUALITY_FULL_BUILDING
	if not out.has("archetype"):
		var kind := StringName(str(out.get("kind", "")))
		var use := StringName(str(out.get("use", out.get("style", {}).get("room_type", ""))))
		var arch: StringName = BuildingArchetype.archetype_for(kind) if kind != &"" else BuildingArchetype.archetype_for(use)
		out["archetype"] = arch
	if source != &"" and not out.has("source"):
		out["source"] = source
	return out


## MUTATES `spec` in place with the contract classification defaults
## (quality FULL_BUILDING unless set, archetype mapped from kind/use, and -
## for rural dicts without a rect - circulation intent so upper storeys are
## provably reachable: ladder for two-storey, none for single-storey).
## Called by UniversalBuildingAssembler before assembly; idempotent.
## Returns the same dictionary (void-compatible call sites also work).
static func contractualize(spec: Dictionary) -> Dictionary:
	if not spec.has("quality"):
		spec["quality"] = WorldConstants.BUILDING_QUALITY_FULL_BUILDING
	if not spec.has("archetype"):
		var kind := StringName(str(spec.get("kind", "")))
		var use := StringName(str(spec.get("use", spec.get("style", {}).get("room_type", ""))))
		var arch: StringName = BuildingArchetype.archetype_for(kind) if kind != &"" else BuildingArchetype.archetype_for(use)
		spec["archetype"] = arch
	if not spec.has("circulation") and not spec.has("rect"):
		var floors: int = 2 if float(spec.get("height", 4.2)) > 6.0 else 1
		spec["circulation"] = {
			&"kind": (&"ladder" if floors >= 2 else &"none"),
			&"note": "rural ladder circulation (contract grammar)",
		}
	return spec


## THE rural window aperture layout - must stay consistent with the rural
## house grammar (art/universal_building_art.gd -> _append_facade_with_openings)
## so windows are REAL holes with sill + lintel + pane, never painted on.
## Mirrors the legacy RuralArt placement: one main window on the window side,
## one on the opposite-ish side, one on the remaining side; the DOOR facade
## keeps a small flanking pair on the ground floor only.
## Returns openings {c, wd, bot, h, glass:true} in the facade's local frame.
static func rural_window_openings(side: int, door_side: int, along_half: float,
		floor_i: int, two_storey: bool) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var win_w := WorldConstants.RURAL_CONTRACT_WIN_W
	var win_h := WorldConstants.RURAL_CONTRACT_WIN_H
	var sill := WorldConstants.RURAL_CONTRACT_WIN_SILL
	var small_w := WorldConstants.RURAL_CONTRACT_SECOND_WIN_W
	var small_h := WorldConstants.RURAL_CONTRACT_SECOND_WIN_H
	# Door facade: small flanking pair at the (centred-by-construction) door.
	if side == door_side:
		if floor_i == 0:
			var door_off := WorldConstants.RURAL_CONTRACT_DOOR_W * 0.5 + 0.72
			for off: float in [-door_off, door_off]:
				var c := off
				if absf(c) + small_w * 0.5 + 0.2 <= along_half:
					out.append({"c": c, "wd": small_w, "bot": sill, "h": small_h, "glass": true})
		return out
	var window_side: int = 2 if door_side != 2 else 3
	var other_side: int = 3 if door_side == 0 or door_side == 1 else 0
	var extra_side := -1
	for s in 4:
		if s != door_side and s != window_side and s != other_side:
			extra_side = s
			break
	var c := clampf(0.0, -along_half + win_w * 0.5 + 0.2, along_half - win_w * 0.5 - 0.2)
	if along_half - win_w * 0.5 - 0.2 >= 0.1:
		if side == window_side or side == other_side or side == extra_side:
			var w := win_w if side != extra_side else small_w
			var h := win_h if side != extra_side else small_h
			out.append({"c": c, "wd": w, "bot": sill, "h": h, "glass": true})
	return out


## Door manifests (city convention) -> entrance list {pos:Vector2, width,
## height, ground_y, edge}. Positions taken from the manifest's world
## position. `edge` rides through so aperture scans orient N/S vs E/W
## regions correctly.
static func city_entrances(spec: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ground := float(spec.get("ground_y", 0.0))
	for dm: Dictionary in spec.get("doors", []):
		var pos_v: Vector3 = dm.get("position", Vector3.ZERO) as Vector3
		if dm.get("position", null) is Vector2:
			var p2: Vector2 = dm["position"]
			pos_v = Vector3(p2.x, 0.0, p2.y)
		out.append({
			"pos": Vector2(pos_v.x, pos_v.z),
			"width": float(dm.get("width", DOOR_W)),
			"height": float(dm.get("height", DOOR_H)),
			"ground_y": float(dm.get("ground_y", ground)),
			"id": str(dm.get("id", "")),
			"edge": int(dm.get("edge", 0)),
		})
	return out


## Rural entrance (plan convention) -> entrance list (single door).
static func rural_entrance(spec: Dictionary, ground: float) -> Array[Dictionary]:
	if not spec.has("door_pos"):
		return [] as Array[Dictionary]
	var dp: Vector2 = spec.get("door_pos", Vector2.ZERO) as Vector2
	return [{
		"pos": dp,
		"width": float(spec.get("door_width", WorldConstants.RURAL_CONTRACT_DOOR_W)),
		"height": float(spec.get("door_height", WorldConstants.RURAL_CONTRACT_DOOR_H)),
		"ground_y": ground,
		"id": str(spec.get("id", "")) + "_door",
	}] as Array[Dictionary]


## Polygon footprint area (m2) - the designed irregular-footprint extension.
## Today's generators pass rect/center+footprint; polygon mode is validated
## but NOT yet assembled (assembler rejects with a clear error).
static func polygon_area(pts: PackedVector2Array) -> float:
	if pts.size() < 3:
		return 0.0
	var area := 0.0
	for i in pts.size():
		var j := (i + 1) % pts.size()
		area += pts[i].x * pts[j].y - pts[j].x * pts[i].y
	return absf(area) * 0.5


## THE reference window aperture formula - must stay byte-identical with
## BuildingBuilder._facade_with_openings so the validator scans REAL holes.
## Returns window openings {c, wd, bot, h, glass} for one facade length.
static func city_window_openings(length: float, is_entrance: bool) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var count := int(floor((length - 1.6) / WIN_SPACING))
	for i in count:
		var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
		if is_entrance and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
			continue   # keep the entrance clear (mirrors the builder)
		out.append({"c": t, "wd": WIN_W, "bot": WIN_SILL, "h": WIN_H, "glass": true})
	return out