class_name BuildingBuilder
extends RefCounted
## Emits ONE procedural building into a MeshBatcher: exterior shell, storey
## slabs with a stairwell shaft, a usable switchback staircase (walkable ramp
## colliders + decorative treads), roof deck with parapet, pitched roof shell,
## bulkhead roof exit, balconies, windows/shopfronts and chimney.
##
## COLLISION POLICY (auditable via MeshBatcher.add_structural_box):
##   STRUCTURAL: every wall segment incl. door-wall pieces + lintels,
##     ground slab, all storey slabs, stair ramps + landings, guard rails,
##     parapets, bulkhead walls + rooflet, chimneys, flat-roof caps.
##   VISUAL ONLY: windows, signboards, shopfront panels, stair treads,
##     pitched roof shells, dormer dressing.
##
## DOORS: this builder emits the WALL OPENING only (segments + lintel). The
## movable door leaf is a dynamic Door entity spawned by ChunkBuilder from
## spec.doors manifests produced by CityPlan - never baked into static mesh.
##
## STAIRS target 30-35 deg (PITCH_DEG); ramps overlap landings by RAMP_OVERLAP
## so there is no step at flight/landing seams; shaft holes are cut through
## EVERY intermediate slab including collision.
##
## Local frame: origin = spec.rect.position, X east, Rect2.y = Z (south),
## heights in Y. Ground top surface at y = 0.

const WALL_T := 0.35
const SLAB_T := 0.22
const LANE_W := 1.25                 # stair lane width
const LAND := 1.25                   # landing depth at each stairwell end
const STAIR_MARGIN_X := 0.5          # stairwell inset from west wall
const STAIR_MARGIN_Z := 0.5
const PITCH_DEG := 34.0              # within safe CharacterBody floor angle
const RAMP_T := 0.22                 # ramp collider thickness
const RAMP_OVERLAP := 0.2            # flight tucks onto landings (no step)
const RAIL_SETBACK := 0.6            # rail stops this far short of each flight end
const DOOR_W := 1.5
const DOOR_H := 2.25
const DOOR_FRAME := 0.06               # jamb clearance: aperture = DOOR_W + this
const WIN_W := 1.15
const WIN_H := 1.35
const WIN_SILL := 0.85
const WIN_SPACING := 2.4
const GLASS_T := 0.2                   # pane thickness inside the WALL_T aperture
const PARAPET_H := 0.9
const PROP_CLEARANCE := 0.35       # minimum gap between adjacent roof props
const BULKHEAD_RING := 1.2         # approach ring around the stair bulkhead
const TOWER_FOOTPRINT := Vector2(1.8, 1.8)  # water-tower leg spread (base)
const TOWER_MIN_AREA := 90.0       # only the largest retail decks get one
const BH_CAP_OVERHANG := 0.3       # bulkhead cap overhang beyond bz walls
const BH_RAIL_H := 0.45            # Phase H roof-exit rim height (grab lip)
const BH_RAIL_T := 0.08            # rim member thickness

# --- Phase K: facade balconies (AC-style climbable-city parkour feature) -----
const BAL_PROJ := 0.7             # balcony deck protrusion beyond the wall face
const BAL_W := 2.2                # balcony deck width (along the facade)
const BAL_DECK_T := 0.16          # deck slab thickness
const BAL_RAIL_H := 0.5           # railing lip height (grabbable parkour ledge)
const BAL_RAIL_T := 0.07          # railing member thickness
const BAL_PROB := 0.7             # chance a given (floor, side) gets a balcony
const BAL_MIN_SIDE := 6.0         # skip balconies on facades shorter than this

# --- Phase L: street awnings (AC-style climbable-city parkour feature) -------
const AWN_PROJ := 1.1             # canopy protrusion beyond the wall face
const AWN_W := 2.4                # canopy width (along the facade)
const AWN_DECK_T := 0.12          # canopy slab thickness
const AWN_DECK_Y := 2.3           # canopy DECK TOP height above grade (standable)
const AWN_RAIL_H := 0.45          # front lip height (grabbable parkour ledge)
const AWN_RAIL_T := 0.07          # front-lip member thickness
const AWN_PROB := 0.55            # chance a given ground-floor facade gets one
const AWN_MIN_SIDE := 5.0         # skip awnings on facades shorter than this

# --- Phase O: construction scaffolding on plaza-adjacent historic facades ---
const SCAFF_PROJ := 1.0           # scaffold depth beyond the wall face
const SCAFF_W := 3.4              # scaffold width along the facade
const SCAFF_PLANK_T := 0.10       # plank deck thickness
const SCAFF_POLE_S := 0.08        # pole square section
const SCAFF_PROB := 0.45          # chance a plaza-adjacent historic building gets one
const SCAFF_MIN_SIDE := 6.0       # skip scaffolds on facades shorter than this

# --- Phase P: facade cornices + pilasters (AC ledge/pillar parkour network) ----
const CORN_PROJ := 0.26           # cornice protrusion beyond the wall face
const CORN_H := 0.18              # cornice band height (grabbable ledge thickness)
const CORN_PROB := 0.62           # chance a given historic long facade grows cornices
const CORN_MIN_SIDE := 6.0        # skip cornices on facades shorter than this
const PIL_W := 0.32               # pilaster width along the facade
const PIL_PROJ := 0.24            # pilaster protrusion beyond the wall
const PIL_PROB := 0.58            # chance a given historic long facade grows pilasters
const PIL_MIN_SIDE := 6.0         # skip pilasters on facades shorter than this
const PIL_SPACING := 3.2          # nominal interval between pilaster centres

# --- Phase Q: post-apoc facade decay (visual-only historic dressing) ------
const DECAY_T := 0.02             # decal thickness (thin plane pressed to wall)
const DECAY_MIN_SIDE := 5.0       # skip decals on facades shorter than this
const DECAY_GRAFF_PROB := 0.55    # chance a historic facade gets a graffiti tag
const DECAY_RUST_PROB := 0.48     # chance a historic facade gets a rust streak
const DECAY_MOSS_PROB := 0.40     # chance a historic facade gets a moss base strip
const DECAY_GRAFF_W_MIN := 1.0
const DECAY_GRAFF_W_MAX := 1.9
const DECAY_GRAFF_H_MIN := 0.6
const DECAY_GRAFF_H_MAX := 1.0
const DECAY_RUST_W := 0.28
const DECAY_RUST_H_MIN := 1.2
const DECAY_RUST_H_MAX := 2.0
const DECAY_MOSS_H := 0.32

# --- Phase R: broken windows + street litter (visual historic decay) -------
const BROKEN_WIN_PROB := 0.30    # chance a historic window pane is missing
const BROKEN_MIN_SIDE := 5.0     # skip on facades shorter than this
const BROKEN_DARK_T := 0.03      # interior darkness plane thickness
const LITTER_PROB := 0.58        # chance a historic facade seeds sidewalk litter
const LITTER_MIN_SIDE := 5.0
const LITTER_Y := 0.035          # litter sits just above the pavement visual

# --- Phase U: interior window glow — faint warm light behind intact glass --
const WINDOW_GLOW_PROB := 0.32   # chance an intact historic window glows at night
const WINDOW_GLOW_MIN_SIDE := 5.0
const WINDOW_GLOW_RANGE := 5.5
const WINDOW_GLOW_ENERGY := 1.15
const WINDOW_GLOW_COLOR := Color(1.0, 0.88, 0.62)
const WINDOW_GLOW_INSET := 0.65  # distance inside wall face to place the point light

# --- Phase X: Prague facade signage — shop signs + house numbers (post-apoc faded) ---
const SIGNAGE_T := 0.02          # thin plaque pressed to wall (visual-only)
const SIGNAGE_MIN_SIDE := 5.0    # skip on facades shorter than this
const SIGNAGE_SHOP_PROB := 0.48  # chance a historic non-entrance facade gets a faded shop sign
const SIGNAGE_HOUSE_PROB := 0.60 # chance the entrance facade gets a house-number plaque
const SIGNAGE_SHOP_W_MIN := 0.85
const SIGNAGE_SHOP_W_MAX := 1.45
const SIGNAGE_SHOP_H := 0.42
const SIGNAGE_HOUSE_S := 0.32    # square plaque

# --- Phase Y: Prague facade drainpipes + eave gutters (historic patina) ---
const DRAIN_T := 0.06            # pipe/gutter thin dimension (square pipe section)
const DRAIN_MIN_SIDE := 5.0      # skip on facades shorter than this
const DRAIN_PIPE_PROB := 0.62    # chance a historic long facade grows a pipe+gutter
const DRAIN_GUTTER_H := 0.07     # gutter height (thin lip at the eave)
const DRAIN_GUTTER_T := 0.08     # gutter protrusion beyond wall face

# --- Phase Z: Prague window shutters (hinged wooden shutters flanking windows) ---
const SHUTTER_T := 0.025         # thin plane pressed to wall (visual-only)
const SHUTTER_W := 0.30          # shutter width along facade
const SHUTTER_H := 1.22          # shutter height (fits inside WIN_H 1.35 with margin)
const SHUTTER_GAP := 0.04        # gap from window edge to shutter inner edge
const SHUTTER_MIN_SIDE := 5.0    # skip on facades shorter than this
const SHUTTER_PROB := 0.52       # chance a historic window grows a pair of shutters

# --- Phase AA: Prague window flower boxes (trailing greenery under sills) ---
const FLOWER_W := 1.38           # trough width along facade (WIN_W 1.15 + 0.23 overhang)
const FLOWER_H := 0.18           # trough height
const FLOWER_D := 0.22           # trough depth protrusion beyond wall face
const FLOWER_BLOOM_H := 0.12     # foliage/bloom mass height atop trough
const FLOWER_MIN_SIDE := 5.0     # skip on facades shorter than this
const FLOWER_PROB := 0.42        # chance a historic window grows a sill flower box

# --- Phase AB: Prague window stone lintels (header trim above historic windows) --
const WINDOW_TRIM_T := 0.05            # thin stone header thickness protruding beyond wall
const WINDOW_TRIM_W_EXTRA := 0.26      # width beyond WIN_W (WIN_W 1.15 -> 1.41)
const WINDOW_TRIM_H := 0.14            # header height
const WINDOW_TRIM_MIN_SIDE := 5.0      # skip on facades shorter than this
const WINDOW_TRIM_PROB := 0.58         # chance a historic window grows a stone lintel

# --- Phase AC: Prague window stone sills (sill ledge below historic windows) --
const SILL_T := 0.06                   # thin stone sill thickness protruding beyond wall
const SILL_W_EXTRA := 0.24             # width beyond WIN_W (WIN_W 1.15 -> 1.39)
const SILL_H := 0.09                   # sill ledge height (thinner than lintel)
const SILL_MIN_SIDE := 5.0             # skip on facades shorter than this
const SILL_PROB := 0.60                # chance a historic window grows a stone sill

# --- Phase AD: Prague window stone jambs (vertical reveals flanking historic windows) --
const JAMB_W := 0.11                   # stone jamb width along facade
const JAMB_T := 0.04                   # thin stone jamb thickness protruding beyond wall
const JAMB_MIN_SIDE := 5.0             # skip on facades shorter than this
const JAMB_PROB := 0.56                # chance a historic window grows a pair of stone jambs

# --- Phase AE: Prague window stone keystones (central header stone above historic windows) --
const KEYSTONE_W := 0.28               # keystone width along facade (central, narrow)
const KEYSTONE_H := 0.18               # keystone height (taller than lintel band)
const KEYSTONE_T := 0.055              # thin stone keystone thickness protruding beyond wall
const KEYSTONE_MIN_SIDE := 5.0         # skip on facades shorter than this
const KEYSTONE_PROB := 0.52            # chance a historic window grows a keystone

# --- Phase AF: Prague window sill corbels (stone brackets under historic sills) --
const CORBEL_W := 0.13                 # corbel width along facade (small bracket)
const CORBEL_H := 0.16                 # corbel height (vertical support)
const CORBEL_D := 0.09                 # corbel depth protruding beyond wall
const CORBEL_MIN_SIDE := 5.0           # skip on facades shorter than this
const CORBEL_PROB := 0.50              # chance a historic window sill grows a bracket pair

# --- Phase AG: Prague doorway stone portal (framed historic entrance) ---
const PORTAL_JAMB_W := 0.16               # stone jamb width along facade
const PORTAL_JAMB_H := 2.25               # stone jamb height (DOOR_H, from grade to lintel underside)
const PORTAL_JAMB_T := 0.05               # thin stone jamb thickness protruding beyond wall
const PORTAL_LINTEL_H := 0.18             # lintel/header height above doorway
const PORTAL_LINTEL_T := 0.055            # thin stone lintel thickness protruding beyond wall
const PORTAL_LINTEL_EXTRA := 0.40         # extra width beyond DOOR_W+2*JAMB_W (lintel overhang)
const PORTAL_MIN_SIDE := 5.0              # skip on facades shorter than this
const PORTAL_PROB := 0.65                 # chance a historic entrance grows a stone portal

# --- Phase AH: Prague facade quoins — rusticated corner stones ----------
const QUOIN_W := 0.44               # stone block width along facade (rusticated corner)
const QUOIN_T := 0.06               # thin stone block thickness protruding beyond wall
const QUOIN_MIN_SIDE := 5.0         # skip on facades shorter than this
const QUOIN_PROB := 0.60            # chance a historic building grows quoins (per building roll)

# Prague-flavored placeholder palettes.
const WALL_COLORS := [
	Color("d8cfc0"), Color("c9a86b"), Color("c4938a"), Color("a9b6bb"),
	Color("a8b39a"), Color("b3aca1"), Color("c7b299"), Color("ded7ca"),
]
const ROOF_COLORS := [
	Color("a34a30"), Color("b5563a"), Color("8f4630"), Color("96502f"),
	Color("6e5550"),
]
const SIGN_COLORS := [
	Color("27556c"), Color("6d2230"), Color("2f4a2f"), Color("2b3350"),
]
const PLINTH_COLOR := Color("8a8074")
const FLOOR_COLOR := Color("6b5843")
const WINDOW_COLOR := Color("232e36")
const DOOR_COLOR := Color("4a3623")
const RAIL_COLOR := Color("3c3833")
const DECK_COLOR := Color("7d7268")

## Stair zone length for a given floor height (CityPlan mirrors this).
static func stair_zone_len(fh: float) -> float:
	return fh / tan(deg_to_rad(PITCH_DEG)) + 2.0 * LAND


## True when the footprint can host the stairwell for `n` floors.
## Minimums guarantee the ENTRANCE door (facade midpoint, ~1.5 m inward
## leaf swing) can never reach the diagonally-opposite stair zone even on
## the smallest eligible lot.
static func has_stairs_for(fp: Vector2, fh: float, n: int) -> bool:
	return n >= 2 and fp.x >= 4.7 \
			and fp.y >= stair_zone_len(fh) + 2.0


## Local-footprint rect of the stairwell zone: EXPLICIT per-edge mapping
## (P0-6). The zone anchors to the side OPPOSITE the entrance facade so
## stairs and the swinging door leaf never share floor space on any lot:
##   N entrance (0) -> SOUTH stair zone     S entrance (2) -> NORTH stair zone
##   E entrance (1) -> WEST stair zone      W entrance (3) -> EAST stair zone
## Every edge is spelled out - no broad condition may collapse two opposite
## edges onto the same anchor again.
static func _zone_rect(fp_size: Vector2, fh: float, door_edge: int) -> Rect2:
	var zx := STAIR_MARGIN_X
	var zy := STAIR_MARGIN_Z
	match door_edge:
		0:   # N entrance -> zone against the SOUTH wall
			zy = fp_size.y - STAIR_MARGIN_Z - stair_zone_len(fh)
		1:   # E entrance -> zone against the WEST wall
			zx = STAIR_MARGIN_X
		2:   # S entrance -> zone against the NORTH wall
			zy = STAIR_MARGIN_Z
		_:   # W entrance (3) -> zone against the EAST wall
			zx = fp_size.x - STAIR_MARGIN_X - LANE_W * 2.0
	return Rect2(zx, zy, LANE_W * 2.0, stair_zone_len(fh))


## World-space rect of the stairwell zone for a spec (plan-layer usable).
static func stair_zone_world(spec: Dictionary) -> Rect2:
	var fp: Rect2 = spec["rect"]
	var local := _zone_rect(fp.size, float(spec["floor_h"]),
			int(spec.get("door_edge", 0)))
	local.position += fp.position
	return local


## Horizontal run of one flight: the shaft length minus both landing depths.
static func flight_run(fh: float) -> float:
	return stair_zone_len(fh) - 2.0 * LAND


## The ACTUAL ramp inclination for a floor height - derived from the fixed
## run, never assumed. PITCH_DEG is only the design target that sizes the
## shaft; the real slope is atan2(fh, flight_run).
static func flight_angle(fh: float) -> float:
	return atan2(fh, flight_run(fh))


## Height of the ramp's walkable TOP surface at shaft-local z (world z
## relative like zone.position.y). Linear between the flush endpoints.
static func ramp_height_at(z: float, base_y: float, fh: float,
		zone_y: float) -> float:
	var t := clampf((z - (zone_y + LAND)) / maxf(flight_run(fh), 0.001),
			0.0, 1.0)
	return base_y + t * fh


static func build(b: MeshBatcher, spec: Dictionary) -> void:
	var fp: Rect2 = spec["rect"]
	var style: Dictionary = spec["style"]
	var wall_c: Color = WALL_COLORS[style["wall"] % WALL_COLORS.size()]
	var roof_c: Color = ROOF_COLORS[style["roof"] % ROOF_COLORS.size()]
	var fh: float = spec["floor_h"]
	var n: int = mini(int(spec["floors"]), 8)
	var total_h := n * fh

	# Interior-reveal LAYER tag for this building: "<id>:f<storey>" and
	# "<id>:roof" let the world hide storeys ABOVE the player's floor.
	var tag := "%s" % str(spec.get("id", "b"))

	var has_stairs := has_stairs_for(fp.size, fh, n)
	var zone := _zone_rect(fp.size, fh, int(spec.get("door_edge", 0)))

	var off := Vector3(fp.position.x, 0.0, fp.position.y)
	var w := fp.size.x
	var d := fp.size.y

	# --- ground slab (STRUCTURAL, top FLUSH with street level y=0) -------------
	# A raised plinth here used to put a 22 cm vertical lip in every doorway -
	# an impassable wall for a CharacterBody3D (no step-up support). The slab
	# now sits fully below grade so entrances are truly walkable.
	b.push_layer(tag + ":f0")
	b.add_structural_box(off + Vector3(w * 0.5, -SLAB_T * 0.5 - 0.02, d * 0.5),
			Vector3(w, SLAB_T, d), FLOOR_COLOR)
	# Thin VISUAL floor finish so interiors still read as floored.
	b.add_visual_box(off + Vector3(w * 0.5, 0.01, d * 0.5),
			Vector3(w - WALL_T, 0.02, d - WALL_T), FLOOR_COLOR.lightened(0.08))
	b.pop_layer()

	# --- storey slabs with stairwell hole (levels 1 .. n) ----------------------
	# Slab at lvl*fh is tagged f<lvl>: it is the CEILING of storey lvl-1, so
	# hiding layers ABOVE the player's floor opens their room to the sky.
	for lvl in range(1, n + 1):
		b.push_layer(tag + ":f%d" % lvl)
		if has_stairs:
			_slab_with_hole(b, off, w, d, zone, lvl * fh)
		else:
			_emit_slab_panels(b, off, Rect2(WALL_T, WALL_T,
					maxf(w - 2.0 * WALL_T, 0.0),
					maxf(d - 2.0 * WALL_T, 0.0)),
					lvl * fh - SLAB_T * 0.5)
		b.pop_layer()

	# --- walls + windows + furniture ---------------------------------------------
	# One aperture-composing facade generator handles doors AND windows.
	var door_edge := int(spec.get("door_edge", 0))
	for f in n:
		b.push_layer(tag + ":f%d" % f)
		var y0 := f * fh
		var col := PLINTH_COLOR if f == 0 else wall_c
		_storey_walls(b, off, w, d, y0, fh, col, f,
				door_edge if f == 0 else -1, tag,
				str(spec.get("district", "")) == "historic")
		if f == 0:
			# Shopfront dressing on the street-facing ground wall (visual) - retail only.
			if str(style.get("room_type", "residential")) == "retail":
				_shopfront(b, off, w, d, spec)
		_furnish(b, off, w, d, fh, f, tag, zone,
				door_edge if f == 0 else -1,
				str(style.get("room_type", "residential")))
		# Phase K: AC-style facade balconies on the upper storeys - a
		# cantilevered concrete deck + steel railing lip that doubles as a
		# grabbable parkour ledge. Deterministic per (floor, side, building),
		# gated to human-scale storeys above ground, on the long facades only.
		if f >= 1:
			_balconies(b, off, w, d, fh, f, tag, spec)
		# Phase L: AC-style street awnings - a sloped canopy deck projects
		# from the GROUND-floor facade (shopfront wall), capped by a steel
		# front lip that doubles as a grabbable parkour ledge. Deterministic
		# per (side, building), gated to the entrance/retail street wall, and
		# only where the facade is long enough to host a believable marquee.
		if f == 0:
			_awnings(b, off, w, d, fh, tag, spec, door_edge)
		b.pop_layer()

	# Phase O: construction scaffolding on plaza-adjacent historic facades.
	# A steel pole cage + plank decks (standable) runs the full facade height,
	# tagged "scaffold", deterministic, gated to plaza adjacency. Plank decks
	# double as AC traversal ledges at each storey.
	_scaffolds(b, off, w, d, fh, n, tag, spec)

	# Phase P: facade cornices + pilasters — horizontal stone cornice bands
	# + vertical pilaster strips forming an AC ledge/pillar parkour network
	# on historic multi-storey facades. Stone, deterministic, gated to
	# historic + multi-storey + long facade. Cornices are grabbable ledges at
	# each storey junction; pilasters are segmented vertical strips per storey
	# giving continuous pillar geometry. Tagged "cornice"/"pilaster".
	_cornices_and_pilasters(b, off, w, d, fh, n, tag, spec)

	# Phase Q: post-apoc facade decay — graffiti / rust / moss visual decals
	# pressed to the historic facade face (visual-only, deterministic, gated
	# to historic + long facade). Brings the white-dummy core into the
	# directive's eerie decayed aesthetic without touching collision.
	_facade_decay(b, off, w, d, fh, n, tag, spec)

	# Phase R: broken windows + street litter — missing glass on historic
	# facades (visual darkness cue inside the aperture, deterministic per
	# building+side+floor+window) + tiny sidewalk litter decals (paper/
	# bottles) as visual-only scatter on the pavement outside long historic
	# facades. Gated to historic district so the city outside stays tidy.
	_street_litter(b, off, w, d, fh, n, tag, spec)

	# Phase X: Prague facade signage — faded shop signs + house-number plaques
	# (visual-only, deterministic per side/building, gated to historic +
	# long facade). Shop signs hang on non-entrance ground-floor walls,
	# house numbers sit beside the doorway — the Prague old-town read.
	_facade_signage(b, off, w, d, fh, n, tag, spec)

	# Phase Y: Prague facade drainpipes + eave gutters — vertical zinc/copper
	# downpipes + horizontal gutters at the eave, visual-only thin boxes pressed
	# just outside historic long facades, deterministic per (side, building),
	# completing the Prague roofline plumbing read without touching collision.
	_facade_drainpipes(b, off, w, d, fh, n, tag, spec)

	# Phase Z: Prague window shutters — hinged wooden shutters flanking
	# historic windows, visual-only thin planes pressed just outside the wall
	# beside each window opening, deterministic per (building, side, floor,
	# window) via WorldSeed shutter, gated to historic + long facade. Gives
	# the Prague core its shuttered-window rhythm without touching collision.
	_facade_shutters(b, off, w, d, fh, n, tag, spec)

	# Phase AA: Prague window flower boxes — trailing greenery under historic
	# sills, visual-only trough + bloom mass pressed just outside the wall
	# under each window, deterministic per (building, side, floor, window)
	# via WorldSeed flowerbox, gated to historic + long facade. Gives the
	# Prague core its lived-in sill gardens without touching collision.
	_facade_flower_boxes(b, off, w, d, fh, n, tag, spec)

	# Phase AB: Prague window stone lintels — header trim above historic windows,
	# visual-only thin stone slabs pressed just outside the wall above each
	# window, deterministic per (building, side, floor, window) via WorldSeed
	# window_trim, gated to historic + long facade. Gives the Prague core its
	# classic stone window headers without touching collision.
	_facade_window_trim(b, off, w, d, fh, n, tag, spec)

	# Phase AC: Prague window stone sills — stone sill ledge below historic windows,
	# visual-only thin stone slabs (SILL_T 0.06 x SILL_H 0.09, width WIN_W+0.24=1.39)
	# pressed just outside the wall at the sill line, deterministic per (building,
	# side, floor, window) via WorldSeed sill_stone, gated to historic + long
	# facade. Gives every qualifying window a crisp stone sill without touching
	# collision or the window glass itself.
	_facade_sill_ledges(b, off, w, d, fh, n, tag, spec)

	# Phase AD: Prague window stone jambs — vertical stone reveals flanking
	# historic windows, visual-only thin stone strips (JAMB_W 0.11 x WIN_H 1.35 x
	# JAMB_T 0.04) pressed just outside the wall beside each window opening,
	# left+right pair per window. Deterministic per (building, side, floor,
	# window) via WorldSeed window_jamb, gated to historic + long facade.
	# Together with Phase AB lintels + AC sills they complete the classical
	# stone window surround without touching collision.
	_facade_window_jambs(b, off, w, d, fh, n, tag, spec)

	# Phase AE: Prague window stone keystones -- central header stone above
	# historic windows, visual-only thin stone block (KEYSTONE_W 0.28 x
	# KEYSTONE_H 0.18 x KEYSTONE_T 0.055) centered above each window opening
	# at y = y0+WIN_SILL+WIN_H+0.24 (just above the AB lintel's top, slightly
	# embedded). Deterministic per (building, side, floor, window) via
	# WorldSeed window_keystone, gated to historic + long facade. Gives the
	# Prague core its classic keystoned window headers without touching
	# collision or glass; together with sills/jambs/lintels the stone
	# window surround is now 5-sided (4 surrounds + keystone crown).
	_facade_window_keystones(b, off, w, d, fh, n, tag, spec)

	# Phase AF: Prague window sill corbels -- stone support brackets under
	# historic sills, visual-only small stone blocks (CORBEL_W 0.13 x
	# CORBEL_H 0.16 x CORBEL_D 0.09) pressed just outside the wall below
	# each sill (pair per window at t_center ±0.35), deterministic per
	# (building, side, floor, window) via WorldSeed sill_corbel, gated
	# to historic + long facade. Gives every qualifying sill a classic
	# Prague console without touching collision or glass; together with
	# the AB/AC/AD/AE surround the window now has 7-piece stone dressing.
	_facade_sill_corbels(b, off, w, d, fh, n, tag, spec)

	# Phase AG: Prague doorway stone portal — framed historic entrance with
	# jambs + lintel header, visual-only thin stone boxes pressed just outside
	# the entrance wall around the doorway opening, deterministic per building
	# via WorldSeed door_portal, gated to historic + long entrance facade.
	# Gives every qualifying entrance a classic Prague portal without touching
	# collision or the door leaf itself.
	_facade_door_portals(b, off, w, d, fh, n, tag, spec)

	# Phase AH: Prague facade quoins — rusticated corner stones on historic
	# buildings, visual-only thin stone blocks pressed just outside the four
	# corners at each storey, deterministic per building via WorldSeed quoin,
	# gated to historic + long facades (>=5.0). Gives the Prague core its
	# classic rusticated corners without touching collision.
	_facade_quoins(b, off, w, d, fh, n, tag, spec)

	# --- staircase --------------------------------------------------------------
	var guard_on_east := true
	if has_stairs:
		guard_on_east = zone.position.x + zone.size.x \
				< w * 0.5 + 0.01   # open side faces the room center
		_staircase(b, off, zone, fh, n, tag, guard_on_east)

	# --- roof -------------------------------------------------------------------
	b.push_layer(tag + ":roof")
	_roof(b, off, fp, style, roof_c, wall_c, total_h, zone, has_stairs,
			guard_on_east)
	b.pop_layer()


# --- Walls -------------------------------------------------------------------

## All four walls of one storey as REAL APERTURE COMPOSITION (P0-E):
## every opening - the entrance door and each window - is carved by the
## SAME generator. Piers stand between openings, a sill band closes each
## window below, a structural lintel closes each opening above, and window
## panes are centered INSIDE their empty gaps. Nothing solid is ever left
## behind glass; after shattering, the aperture is genuinely open.
##
## DESTRUCTION GRANULARITY (P0-F): piers are emitted as stacked ~1 m tall
## modules (CELL_H), so blasts carve out a few courses instead of deleting a
## whole multi-metre wall segment. Every module is its own integrity record.
##
## LAYER OWNERSHIP (P0-3): each facade pushes its EXPLICIT reveal key
## "<building tag>:f<storey>:<N/E/S/W>" directly (no nesting tricks), so
## ChunkManager.apply_floor_gate() can fade exactly one building's
## camera-facing wall per storey.
static func _storey_walls(b: MeshBatcher, off: Vector3, w: float, d: float,
		y0: float, fh: float, col: Color, floor_i: int, door_edge: int,
		tag: String, is_historic: bool = false) -> void:
	var facades := ["N", "E", "S", "W"]   # order matches side encoding 0..3
	for side in 4:
		b.push_layer("%s:f%d:%s" % [tag, floor_i, facades[side]])
		_facade_with_openings(b, off, side, w, d, y0, fh, col, floor_i,
				door_edge == side, is_historic, tag)
		b.pop_layer()


## Phase K: AC-style facade balconies. A cantilevered concrete deck juts out
## from one upper-storey facade per (floor, side), capped by a steel railing
## whose top edge is a grabbable parkour lip. The deck is STANDABLE (collides)
## so the player can mantle onto it from the street or from a lower balcony;
## the railing is a thin tall steel lip that the Phase-E parkour grab can
## catch. Placement is deterministic (one choice RNG per floor/side/building),
## gated to floors above ground and to facades long enough to host a believable
## balcony, and never on the entrance (door) wall so shopfronts stay clear.
static func _balconies(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, f: int, tag: String, spec: Dictionary) -> void:
	var door_edge: int = int(spec.get("door_edge", 0))
	var facades := ["N", "E", "S", "W"]   # order matches side encoding 0..3
	for side in 4:
		# Phase N: the old hard skip blocked the street wall so an
		# awning (ground floor, door_edge) could never chain to a
		# first-floor balcony on the SAME facade - the iconic AC
		# ground->first-floor vertical. Shopfront dressing lives on
		# f==0 only, so balconies at f>=1 no longer need to keep that
		# wall clear. The street wall now rolls the same BAL_PROB as
		# any other facade so stacked awning->balcony can actually
		# generate in the city (seeded, still gated by BAL_MIN_SIDE).
		if side == door_edge and f == 0:
			continue   # vestigial: balconies never at f==0 anyway
		var length := w if (side == 0 or side == 2) else d
		if length < BAL_MIN_SIDE:
			continue   # balcony needs a believable run of facade
		var rng := WorldSeed.rng_for("balcony",
			[WorldSeed.str_hash(tag), f * 7, side])
		if rng.randf() >= BAL_PROB:
			continue   # ~30% of eligible facades get one - avoids total coverage
		var slot: Vector3 = _balcony_slot(w, d, side, f, fh)
		var cx := off.x + slot.x
		var cy := off.y + slot.y
		var cz := off.z + slot.z
		_add_balcony(b, cx, cy, cz, side)


## World-local center (no building offset) of a balcony deck for `side`.
static func _balcony_slot(w: float, d: float, side: int, f: int,
		fh: float) -> Vector3:
	var y := f * fh + 0.25          # deck top just above the storey floor
	var t := (w if (side == 0 or side == 2) else d) * 0.5  # centered on facade
	match side:
		0: return Vector3(t, y, WALL_T * 0.5 - BAL_PROJ * 0.5)      # N (-Z)
		1: return Vector3(w - WALL_T * 0.5 + BAL_PROJ * 0.5, y, t)  # E (+X)
		2: return Vector3(t, y, d - WALL_T * 0.5 + BAL_PROJ * 0.5)  # S (+Z)
		_: return Vector3(WALL_T * 0.5 - BAL_PROJ * 0.5, y, t)      # W (-X)


## One balcony: concrete deck (standable) + 3-segment steel railing lip.
static func _add_balcony(b: MeshBatcher, cx: float, cy: float, cz: float,
		side: int) -> void:
	var horizontal := side == 0 or side == 2
	var aw := BAL_W if horizontal else BAL_PROJ
	var ad := BAL_PROJ if horizontal else BAL_W
	# Deck slab - concrete, standable (collides). Thin cantilever.
	b.add_destructible_box(Vector3(cx, cy - BAL_DECK_T * 0.5, cz),
			Vector3(aw, BAL_DECK_T, ad), Color("8a8074").darkened(0.1),
			&"concrete", true, "balcony", -1)
	# Steel railing lip: front rail (the grabbable parkour edge) + two returns.
	# Top of the front rail sits BAL_RAIL_H above the deck -> catchable ledge.
	var ry := cy + BAL_RAIL_H * 0.5
	var rail_c := Color("6b6f73")
	# Front rail runs along the facade edge, facing out into the city.
	var fr_w := BAL_W if horizontal else BAL_RAIL_T
	var fr_d := BAL_RAIL_T if horizontal else BAL_W
	var fr_x: float = cx
	var fr_z: float = cz
	if horizontal:
		fr_z += (BAL_PROJ - BAL_RAIL_T) * 0.5 * (1.0 if side == 2 else -1.0)
	else:
		fr_x += (BAL_PROJ - BAL_RAIL_T) * 0.5 * (1.0 if side == 1 else -1.0)
	b.add_destructible_box(Vector3(fr_x, ry, fr_z),
			Vector3(fr_w, BAL_RAIL_H, fr_d), rail_c,
			&"steel", true, "balcony", -1)
	# Two side returns (short steel posts along the deck edges).
	var ret_len := BAL_PROJ - 2.0 * BAL_RAIL_T
	if horizontal:
		for sx: float in [cx - BAL_W * 0.5 + BAL_RAIL_T * 0.5,
				cx + BAL_W * 0.5 - BAL_RAIL_T * 0.5]:
			b.add_destructible_box(Vector3(sx, ry, fr_z),
					Vector3(BAL_RAIL_T, BAL_RAIL_H, ret_len), rail_c,
					&"steel", true, "balcony", -1)
	else:
		for sz: float in [cz - BAL_W * 0.5 + BAL_RAIL_T * 0.5,
				cz + BAL_W * 0.5 - BAL_RAIL_T * 0.5]:
			b.add_destructible_box(Vector3(fr_x, ry, sz),
					Vector3(ret_len, BAL_RAIL_H, BAL_RAIL_T), rail_c,
					&"steel", true, "balcony", -1)


## Phase L: AC-style street awnings. A sloped canopy deck projects from ONE
## ground-floor (shopfront) facade per building, capped by a steel front lip
## whose top edge is a grabbable parkour ledge and whose sloped top is
## STANDABLE (collides) so the player can mantle from the street or from a
## nearby balcony/deck. Deterministic per (side, building), gated to the
## entrance/retail street wall and to facades long enough to host a marquee,
## and shares the door-wall discipline so shopfronts stay readable.
static func _awnings(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, tag: String, spec: Dictionary,
		door_edge: int) -> void:
	var facade_side: int = door_edge
	var length := w if (facade_side == 0 or facade_side == 2) else d
	if length < AWN_MIN_SIDE:
		return   # facade too short to host a believable marquee
	var rng := WorldSeed.rng_for("awning",
		[WorldSeed.str_hash(tag), facade_side])
	if rng.randf() >= AWN_PROB:
		return   # ~45% of eligible street walls get one - avoids total cover
	var slot: Vector3 = _awning_slot(w, d, facade_side)
	var cx := off.x + slot.x
	var cy := off.y + slot.y
	var cz := off.z + slot.z
	_add_awning(b, cx, cy, cz, facade_side)


## World-local center (no building offset) of an awning canopy for `side`.
static func _awning_slot(w: float, d: float, side: int) -> Vector3:
	var y := AWN_DECK_Y - AWN_DECK_T * 0.5     # canopy slab center height
	var t := (w if (side == 0 or side == 2) else d) * 0.5  # centered on facade
	match side:
		0: return Vector3(t, y, WALL_T * 0.5 - AWN_PROJ * 0.5)      # N (-Z)
		1: return Vector3(w - WALL_T * 0.5 + AWN_PROJ * 0.5, y, t)  # E (+X)
		2: return Vector3(t, y, d - WALL_T * 0.5 + AWN_PROJ * 0.5)  # S (+Z)
		_: return Vector3(WALL_T * 0.5 - AWN_PROJ * 0.5, y, t)      # W (-X)


## One awning: sloped standable canopy deck (collides) + steel front lip.
## The canopy SLOPES down-and-out (tilt about the horizontal facade axis) so
## it reads like a real marquee and its top stays a flat standable surface;
## the front lip top sits AWN_RAIL_H above the canopy deck (grabbable ledge).
static func _add_awning(b: MeshBatcher, cx: float, cy: float, cz: float,
		side: int) -> void:
	var horizontal := side == 0 or side == 2   # N/S facades run along X
	var cw := AWN_W if horizontal else AWN_PROJ
	var cd := AWN_PROJ if horizontal else AWN_W
	# Slope: +0.10 per metre of outward run (tilt about the facade axis).
	var slope := 0.10
	var axis: Vector3 = Vector3(1, 0, 0) if horizontal else Vector3(0, 0, 1)
	var basis := Basis(axis, atan(slope))
	var deck_c := Color("6b4f3a").darkened(0.05)   # canvas/wood awning tone
	b.add_box_rotated(Vector3(cx, cy, cz),
		Vector3(cw, AWN_DECK_T, cd), basis, deck_c, true,
		false, &"wood", "awning", 0)
	# Steel front lip: runs along the facade edge, facing out into the city.
	# Top of the lip sits AWN_RAIL_H above the canopy deck -> catchable ledge.
	var ry := cy + AWN_DECK_T * 0.5 + AWN_RAIL_H * 0.5
	var lip_c := Color("6b6f73")
	var fr_w := AWN_W if horizontal else AWN_RAIL_T
	var fr_d := AWN_RAIL_T if horizontal else AWN_W
	var fr_x: float = cx
	var fr_z: float = cz
	if horizontal:
		fr_z += (AWN_PROJ - AWN_RAIL_T) * 0.5 * (1.0 if side == 2 else -1.0)
	else:
		fr_x += (AWN_PROJ - AWN_RAIL_T) * 0.5 * (1.0 if side == 1 else -1.0)
	b.add_destructible_box(Vector3(fr_x, ry, fr_z),
		Vector3(fr_w, AWN_RAIL_H, fr_d), lip_c,
		&"steel", true, "awning", 0)
	# Two side returns (short steel posts along the canopy edges).
	var ret_len := AWN_PROJ - 2.0 * AWN_RAIL_T
	if horizontal:
		for sx: float in [cx - AWN_W * 0.5 + AWN_RAIL_T * 0.5,
				cx + AWN_W * 0.5 - AWN_RAIL_T * 0.5]:
			b.add_destructible_box(Vector3(sx, ry, fr_z),
				Vector3(AWN_RAIL_T, AWN_RAIL_H, ret_len), lip_c,
				&"steel", true, "awning", 0)
	else:
		for sz: float in [cz - AWN_W * 0.5 + AWN_RAIL_T * 0.5,
				cz + AWN_W * 0.5 - AWN_RAIL_T * 0.5]:
			b.add_destructible_box(Vector3(fr_x, ry, sz),
				Vector3(ret_len, AWN_RAIL_H, AWN_RAIL_T), lip_c,
				&"steel", true, "awning", 0)

## Phase O: construction scaffolding on plaza-adjacent historic facades.
## A steel pole cage + plank decks (standable) runs the FULL height of ONE
## facade per building, giving AC-style mid-height traversal. Planks at each
## storey are wood, poles/ledgers are steel, all tagged "scaffold". Gated to
## historic district + plaza adjacency + multi-storey + long facade, seeded
## per building so the same facade is chosen deterministically.
static func _scaffolds(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	if not bool(spec.get("plaza_adjacent", false)):
		return
	if n < 2:
		return
	var rng := WorldSeed.rng_for("scaffold", [WorldSeed.str_hash(tag)])
	if rng.randf() >= SCAFF_PROB:
		return
	# Shuffle side order deterministically, then pick first eligible long facade.
	var sides: Array[int] = [0, 1, 2, 3]
	for i in range(3, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := sides[i]
		sides[i] = sides[j]
		sides[j] = tmp
	var chosen_side := -1
	var chosen_len := 0.0
	for side in sides:
		var length := w if (side == 0 or side == 2) else d
		if length < SCAFF_MIN_SIDE:
			continue
		chosen_side = side
		chosen_len = length
		break
	if chosen_side == -1:
		return
	var scaffold_w := minf(SCAFF_W, chosen_len - 1.0)
	var horizontal := chosen_side == 0 or chosen_side == 2
	var t := chosen_len * 0.5
	var cx: float = 0.0
	var cz: float = 0.0
	match chosen_side:
		0: cx = t; cz = WALL_T * 0.5 - SCAFF_PROJ * 0.5
		1: cx = w - WALL_T * 0.5 + SCAFF_PROJ * 0.5; cz = t
		2: cx = t; cz = d - WALL_T * 0.5 + SCAFF_PROJ * 0.5
		_: cx = WALL_T * 0.5 - SCAFF_PROJ * 0.5; cz = t
	var aw := scaffold_w if horizontal else SCAFF_PROJ
	var ad := SCAFF_PROJ if horizontal else scaffold_w
	var plank_c := Color("8b7355")
	var pole_c := Color("6b6f73")
	for f in n:
		var plank_top := f * fh + 0.25
		var plank_cy := plank_top - SCAFF_PLANK_T * 0.5
		b.push_layer(tag + ":f%d" % f)
		# Plank deck (wood, standable, tagged scaffold)
		b.add_destructible_box(off + Vector3(cx, plank_cy, cz),
				Vector3(aw, SCAFF_PLANK_T, ad), plank_c,
				&"wood", true, "scaffold", f)
		# Two vertical pole segments for this storey (steel)
		var pole_y := f * fh + fh * 0.5
		var pole_h := fh
		var p1x: float
		var p1z: float
		var p2x: float
		var p2z: float
		if horizontal:
			p1x = cx - scaffold_w * 0.5 + SCAFF_POLE_S * 0.5
			p1z = cz
			p2x = cx + scaffold_w * 0.5 - SCAFF_POLE_S * 0.5
			p2z = cz
		else:
			p1x = cx
			p1z = cz - scaffold_w * 0.5 + SCAFF_POLE_S * 0.5
			p2x = cx
			p2z = cz + scaffold_w * 0.5 - SCAFF_POLE_S * 0.5
		b.add_destructible_box(off + Vector3(p1x, pole_y, p1z),
				Vector3(SCAFF_POLE_S, pole_h, SCAFF_POLE_S), pole_c,
				&"steel", true, "scaffold", f)
		b.add_destructible_box(off + Vector3(p2x, pole_y, p2z),
				Vector3(SCAFF_POLE_S, pole_h, SCAFF_POLE_S), pole_c,
				&"steel", true, "scaffold", f)
		b.pop_layer()


## Phase P: facade cornices + pilasters on historic multi-storey facades.
## A horizontal stone cornice band runs each storey junction (grabbable
## ledge), and vertical pilaster strips punctuate long facades (pillar
## network). Both are stone/concrete, colliding, tagged "cornice"/
## "pilaster", deterministic per (side, building), gated to historic +
## multi-storey + long facade. Together they complete the AC
## "ledges/pillars" traversal vocabulary on the historic core.
static func _cornices_and_pilasters(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	if n < 2:
		return
	var corn_c := Color("9e968a")
	var pil_c := Color("a8a098").lightened(0.04)
	for side in 4:
		var length := w if (side == 0 or side == 2) else d
		if length < CORN_MIN_SIDE:
			continue
		var rng := WorldSeed.rng_for("cornice", [WorldSeed.str_hash(tag), side])
		if rng.randf() >= CORN_PROB:
			continue
		var horizontal := side == 0 or side == 2
		var t := length * 0.5
		var cx: float = 0.0
		var cz: float = 0.0
		match side:
			0: cx = t; cz = WALL_T * 0.5 - CORN_PROJ * 0.5
			1: cx = w - WALL_T * 0.5 + CORN_PROJ * 0.5; cz = t
			2: cx = t; cz = d - WALL_T * 0.5 + CORN_PROJ * 0.5
			_: cx = WALL_T * 0.5 - CORN_PROJ * 0.5; cz = t
		var span := length - 0.4
		var aw := span if horizontal else CORN_PROJ
		var ad := CORN_PROJ if horizontal else span
		for f in range(1, n + 1):
			var cy := f * fh - CORN_H * 0.5
			if f == n:
				cy = n * fh - CORN_H * 0.5 - 0.06
			var layer_f := mini(f, n - 1)
			b.push_layer(tag + ":f%d" % layer_f)
			b.add_destructible_box(off + Vector3(cx, cy, cz),
					Vector3(aw, CORN_H, ad), corn_c,
					&"concrete", true, "cornice", layer_f)
			b.pop_layer()
	for side in 4:
		var length2 := w if (side == 0 or side == 2) else d
		if length2 < PIL_MIN_SIDE:
			continue
		var rng2 := WorldSeed.rng_for("pilaster", [WorldSeed.str_hash(tag), side])
		if rng2.randf() >= PIL_PROB:
			continue
		var count := maxi(1, floori((length2 - 0.8) / PIL_SPACING))
		var jitter := rng2.randf_range(-0.18, 0.18)
		for i in count:
			var frac := float(i + 1) / float(count + 1)
			var t2 := length2 * frac + jitter
			t2 = clampf(t2, PIL_W * 0.5 + 0.25, length2 - PIL_W * 0.5 - 0.25)
			var px: float = 0.0
			var pz: float = 0.0
			match side:
				0: px = t2; pz = WALL_T * 0.5 - PIL_PROJ * 0.5
				1: px = w - WALL_T * 0.5 + PIL_PROJ * 0.5; pz = t2
				2: px = t2; pz = d - WALL_T * 0.5 + PIL_PROJ * 0.5
				_: px = WALL_T * 0.5 - PIL_PROJ * 0.5; pz = t2
			var horizontal2 := side == 0 or side == 2
			for f in n:
				var cy2 := f * fh + fh * 0.5
				var pw := PIL_W if horizontal2 else PIL_PROJ
				var pd := PIL_PROJ if horizontal2 else PIL_W
				b.push_layer(tag + ":f%d" % f)
				b.add_destructible_box(off + Vector3(px, cy2, pz),
						Vector3(pw, fh - 0.02, pd), pil_c,
						&"concrete", true, "pilaster", f)
				b.pop_layer()


const CELL_H := 2.5      # floor slab panel target edge (BOTH dimensions)
const WALL_CELL := 1.25  # wall pier horizontal module target width


## Phase Q: post-apoc facade decay — visual-only graffiti / rust / moss
## pressed to the historic facade face (thin planes just outside the wall).
## Deterministic per (side, building) via WorldSeed, gated to historic +
## long facade (>= DECAY_MIN_SIDE). Visual-only (collide=false, material
## empty) so it never affects physics or parkour — pure aesthetic decay.
static func _facade_decay(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var graff_colors: Array[Color] = [
		Color("c73a2e"), Color("2c5f8a"), Color("e8c24a"),
		Color("4a7a3a"), Color("6e3a8a"), Color("e8a040"),
	]
	var rust_c := Color("7a3b1f")
	var moss_c := Color("4a5a2e")
	for side in 4:
		var length := w if (side == 0 or side == 2) else d
		if length < DECAY_MIN_SIDE:
			continue
		var rng_g := WorldSeed.rng_for("decay_graff", [WorldSeed.str_hash(tag), side])
		if rng_g.randf() < DECAY_GRAFF_PROB:
			var gw := rng_g.randf_range(DECAY_GRAFF_W_MIN, DECAY_GRAFF_W_MAX)
			var gh := rng_g.randf_range(DECAY_GRAFF_H_MIN, DECAY_GRAFF_H_MAX)
			gw = minf(gw, length - 0.8)
			var t := rng_g.randf_range(gw * 0.5 + 0.4, length - gw * 0.5 - 0.4)
			var cy := rng_g.randf_range(0.9, n * fh - 0.7)
			var c: Color = graff_colors[rng_g.randi_range(0, graff_colors.size() - 1)]
			c = c.lightened(rng_g.randf_range(-0.06, 0.06))
			var cx: float = 0.0
			var cz: float = 0.0
			var aw: float = 0.0
			var ad: float = 0.0
			var eps := 0.04
			match side:
				0: cx = t; cz = -DECAY_T * 0.5 - eps; aw = gw; ad = DECAY_T
				1: cx = w + DECAY_T * 0.5 + eps; cz = t; aw = DECAY_T; ad = gw
				2: cx = t; cz = d + DECAY_T * 0.5 + eps; aw = gw; ad = DECAY_T
				_: cx = -DECAY_T * 0.5 - eps; cz = t; aw = DECAY_T; ad = gw
			var layer_f := clampi(int(cy / fh), 0, maxi(n - 1, 0))
			b.push_layer(tag + ":f%d" % layer_f)
			b.add_box_rotated(off + Vector3(cx, cy, cz), Vector3(aw, gh, ad),
					Basis.IDENTITY, c, false, false, &"", "decay", layer_f)
			b.pop_layer()
		var rng_r := WorldSeed.rng_for("decay_rust", [WorldSeed.str_hash(tag), side])
		if rng_r.randf() < DECAY_RUST_PROB:
			var rw := DECAY_RUST_W
			var rh := rng_r.randf_range(DECAY_RUST_H_MIN, DECAY_RUST_H_MAX)
			rh = minf(rh, n * fh - 0.6)
			var t2 := rng_r.randf_range(rw * 0.5 + 0.35, length - rw * 0.5 - 0.35)
			var cy2 := rng_r.randf_range(rh * 0.5 + 0.3, n * fh - rh * 0.5 - 0.2)
			var rc := rust_c.lightened(rng_r.randf_range(-0.07, 0.08))
			var cx2: float = 0.0
			var cz2: float = 0.0
			var aw2: float = 0.0
			var ad2: float = 0.0
			var eps2 := 0.04
			match side:
				0: cx2 = t2; cz2 = -DECAY_T * 0.5 - eps2; aw2 = rw; ad2 = DECAY_T
				1: cx2 = w + DECAY_T * 0.5 + eps2; cz2 = t2; aw2 = DECAY_T; ad2 = rw
				2: cx2 = t2; cz2 = d + DECAY_T * 0.5 + eps2; aw2 = rw; ad2 = DECAY_T
				_: cx2 = -DECAY_T * 0.5 - eps2; cz2 = t2; aw2 = DECAY_T; ad2 = rw
			var layer_f2 := clampi(int(cy2 / fh), 0, maxi(n - 1, 0))
			b.push_layer(tag + ":f%d" % layer_f2)
			b.add_box_rotated(off + Vector3(cx2, cy2, cz2), Vector3(aw2, rh, ad2),
					Basis.IDENTITY, rc, false, false, &"", "decay", layer_f2)
			b.pop_layer()
		var rng_m := WorldSeed.rng_for("decay_moss", [WorldSeed.str_hash(tag), side])
		if rng_m.randf() < DECAY_MOSS_PROB:
			var mw := length - 0.7
			var mh := DECAY_MOSS_H
			var t3 := length * 0.5
			var cy3 := mh * 0.5 + 0.08 + rng_m.randf_range(-0.04, 0.05)
			var mc := moss_c.lightened(rng_m.randf_range(-0.08, 0.08)).darkened(0.05)
			var cx3: float = 0.0
			var cz3: float = 0.0
			var aw3: float = 0.0
			var ad3: float = 0.0
			var eps3 := 0.04
			match side:
				0: cx3 = t3; cz3 = -DECAY_T * 0.5 - eps3; aw3 = mw; ad3 = DECAY_T
				1: cx3 = w + DECAY_T * 0.5 + eps3; cz3 = t3; aw3 = DECAY_T; ad3 = mw
				2: cx3 = t3; cz3 = d + DECAY_T * 0.5 + eps3; aw3 = mw; ad3 = DECAY_T
				_: cx3 = -DECAY_T * 0.5 - eps3; cz3 = t3; aw3 = DECAY_T; ad3 = mw
			b.push_layer(tag + ":f0")
			b.add_box_rotated(off + Vector3(cx3, cy3, cz3), Vector3(aw3, mh, ad3),
					Basis.IDENTITY, mc, false, false, &"", "decay", 0)
			b.pop_layer()

## Phase R: street-level sidewalk litter outside historic facades ----------
## Tiny visual-only debris (paper / bottles) scattered on the pavement
## just outside long historic facades. Deterministic per (side, building)
## via WorldSeed, gated to historic + long facade, never collides. Pure
## aesthetic grit for the directive's post-apoc sidewalks.
static func _street_litter(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var litter_colors: Array[Color] = [
		Color("c7bca8"), Color("8a7460"), Color("6e6a5f"),
		Color("b3a48a"), Color("9c9583"), Color("7a5a3a"),
	]
	for side in 4:
		var length := w if (side == 0 or side == 2) else d
		if length < LITTER_MIN_SIDE:
			continue
		var rng := WorldSeed.rng_for("litter", [WorldSeed.str_hash(tag), side])
		if rng.randf() >= LITTER_PROB:
			continue
		var count := rng.randi_range(2, 4)
		var horizontal := side == 0 or side == 2
		for k in count:
			var t := rng.randf_range(0.55, length - 0.55)
			var sx := rng.randf_range(0.18, 0.42)
			var sz := rng.randf_range(0.16, 0.35)
			var sy := 0.02
			if rng.randf() < 0.35:
				# bottle / can upright
				sx = rng.randf_range(0.10, 0.14)
				sz = rng.randf_range(0.10, 0.14)
				sy = rng.randf_range(0.14, 0.28)
			var cx: float = 0.0
			var cz: float = 0.0
			var outward := rng.randf_range(0.55, 1.15)
			match side:
				0: cx = t; cz = -outward
				1: cx = w + outward; cz = t
				2: cx = t; cz = d + outward
				_: cx = -outward; cz = t
			var yaw := rng.randf_range(-0.6, 0.6)
			var basis := Basis(Vector3.UP, yaw)
			var col: Color = litter_colors[rng.randi_range(0, litter_colors.size() - 1)]
			col = col.lightened(rng.randf_range(-0.07, 0.07))
			var litter_sz := Vector3(sx, sy, sz)
			b.push_layer(tag + ":f0")
			b.add_box_rotated(off + Vector3(cx, LITTER_Y + sy * 0.5, cz),
					litter_sz, basis, col, false, false, &"", "litter", 0)
			b.pop_layer()

## Phase X: Prague facade signage — faded shop signs + house-number plaques.
## Visual-only thin planes pressed just outside the wall (SIGNAGE_T), gated
## to historic + long facade (>= SIGNAGE_MIN_SIDE), deterministic per
## (side, building) via WorldSeed. House plaques sit beside the entrance
## door on the door wall; shop signs hang on the other three walls as a
## single faded board on the ground floor. Pure Prague historic dressing,
## no collision or parkour change.
static func _facade_signage(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	# Faded palette — desaturated Prague shop tones + enamel house-number cream/blue.
	var shop_colors: Array[Color] = [
		Color("4a5a6e"), Color("6e4a3a"), Color("5a6e4a"),
		Color("6e5a4a"), Color("4a6e6a"), Color("5a4a6e"),
	]
	var plaque_colors: Array[Color] = [
		Color("c8c4a8"), Color("d8cfb0"), Color("a8c4d8"), Color("d8b8a0"),
	]
	for side in 4:
		var length := w if (side == 0 or side == 2) else d
		if length < SIGNAGE_MIN_SIDE:
			continue
		if side == door_edge:
			var rng_h := WorldSeed.rng_for("house_num", [WorldSeed.str_hash(tag), side])
			if rng_h.randf() >= SIGNAGE_HOUSE_PROB:
				continue
			var s := SIGNAGE_HOUSE_S
			var h_y := 1.35
			# Left or right of the doorway centre, never overlapping the door leaf.
			var side_offset := (DOOR_W * 0.5 + 0.72) * (1.0 if rng_h.randf() < 0.5 else -1.0)
			var t_h := length * 0.5 + side_offset
			t_h = clampf(t_h, s * 0.5 + 0.35, length - s * 0.5 - 0.35)
			var c_plaque: Color = plaque_colors[rng_h.randi_range(0, plaque_colors.size() - 1)]
			c_plaque = c_plaque.lightened(rng_h.randf_range(-0.05, 0.05)).darkened(0.02)
			var cx_h: float = 0.0
			var cz_h: float = 0.0
			var aw_h: float = 0.0
			var ad_h: float = 0.0
			var eps := 0.04
			match side:
				0: cx_h = t_h; cz_h = -SIGNAGE_T * 0.5 - eps; aw_h = s; ad_h = SIGNAGE_T
				1: cx_h = w + SIGNAGE_T * 0.5 + eps; cz_h = t_h; aw_h = SIGNAGE_T; ad_h = s
				2: cx_h = t_h; cz_h = d + SIGNAGE_T * 0.5 + eps; aw_h = s; ad_h = SIGNAGE_T
				_: cx_h = -SIGNAGE_T * 0.5 - eps; cz_h = t_h; aw_h = SIGNAGE_T; ad_h = s
			b.push_layer(tag + ":f0")
			b.add_box_rotated(off + Vector3(cx_h, h_y, cz_h),
					Vector3(aw_h, s, ad_h), Basis.IDENTITY, c_plaque, false, false, &"", "signage", 0)
			b.pop_layer()
		else:
			var rng_s := WorldSeed.rng_for("shop_sign", [WorldSeed.str_hash(tag), side])
			if rng_s.randf() >= SIGNAGE_SHOP_PROB:
				continue
			var sw := rng_s.randf_range(SIGNAGE_SHOP_W_MIN, SIGNAGE_SHOP_W_MAX)
			sw = minf(sw, length - 0.8)
			var sh := SIGNAGE_SHOP_H
			var t_s := rng_s.randf_range(sw * 0.5 + 0.40, length - sw * 0.5 - 0.40)
			var cy := 2.02 + rng_s.randf_range(-0.08, 0.08)
			cy = clampf(cy, 1.6, fh - 0.25)
			var c_shop: Color = shop_colors[rng_s.randi_range(0, shop_colors.size() - 1)]
			c_shop = c_shop.lightened(rng_s.randf_range(-0.06, 0.08))
			# Slightly desaturate to read as faded sun-bleached board.
			c_shop = c_shop.lerp(Color(0.68, 0.65, 0.60), 0.22)
			var cx_s: float = 0.0
			var cz_s: float = 0.0
			var aw_s: float = 0.0
			var ad_s: float = 0.0
			var eps2 := 0.04
			match side:
				0: cx_s = t_s; cz_s = -SIGNAGE_T * 0.5 - eps2; aw_s = sw; ad_s = SIGNAGE_T
				1: cx_s = w + SIGNAGE_T * 0.5 + eps2; cz_s = t_s; aw_s = SIGNAGE_T; ad_s = sw
				2: cx_s = t_s; cz_s = d + SIGNAGE_T * 0.5 + eps2; aw_s = sw; ad_s = SIGNAGE_T
				_: cx_s = -SIGNAGE_T * 0.5 - eps2; cz_s = t_s; aw_s = SIGNAGE_T; ad_s = sw
			b.push_layer(tag + ":f0")
			b.add_box_rotated(off + Vector3(cx_s, cy, cz_s),
					Vector3(aw_s, sh, ad_s), Basis.IDENTITY, c_shop, false, false, &"", "signage", 0)
			b.pop_layer()

## Phase Y: Prague facade drainpipes + eave gutters (historic patina).
## Visual-only thin boxes pressed just outside historic long facades
## (DRAIN_T 0.06 square pipe section), deterministic per (side, building)
## via WorldSeed. Each qualifying facade rolls once: on success it grows
## one vertical downpipe running the full facade height + one horizontal
## eave gutter at the roofline. Zinc/copper patina palette, visual-only,
## no collision or parkour change.
static func _facade_drainpipes(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var total_h := n * fh
	var door_edge: int = int(spec.get("door_edge", 0))
	for side in 4:
		var length := w if (side == 0 or side == 2) else d
		if length < DRAIN_MIN_SIDE:
			continue
		var rng := WorldSeed.rng_for("drainpipe", [WorldSeed.str_hash(tag), side])
		if rng.randf() >= DRAIN_PIPE_PROB:
			continue
		# Lateral position: 32% or 68% along facade, jittered, clamped away from door.
		var t := (0.32 if rng.randf() < 0.5 else 0.68) * length
		t += rng.randf_range(-0.12, 0.12)
		if side == door_edge:
			var door_center := length * 0.5
			if absf(t - door_center) < 1.6:
				t = door_center + 1.75 * (1.0 if t > door_center else -1.0)
		t = clampf(t, DRAIN_T * 0.5 + 0.35, length - DRAIN_T * 0.5 - 0.35)
		var eps := 0.05
		var cx: float = 0.0
		var cz: float = 0.0
		match side:
			0: cx = t; cz = -DRAIN_T * 0.5 - eps
			1: cx = w + DRAIN_T * 0.5 + eps; cz = t
			2: cx = t; cz = d + DRAIN_T * 0.5 + eps
			_: cx = -DRAIN_T * 0.5 - eps; cz = t
		var cy := total_h * 0.5
		var h := total_h - 0.14
		var pipe_col: Color = Color("5a6d6e") if rng.randf() < 0.62 else Color("6a7a5e")
		pipe_col = pipe_col.darkened(0.04).lightened(rng.randf_range(-0.04, 0.04))
		b.push_layer(tag + ":f0")
		b.add_box_rotated(off + Vector3(cx, cy, cz),
				Vector3(DRAIN_T, h, DRAIN_T), Basis.IDENTITY, pipe_col, false, false, &"", "drainpipe", 0)
		# Horizontal eave gutter: runs along the top edge just below the roof plane.
		var gutter_y := total_h - DRAIN_GUTTER_H * 0.5 - 0.04
		var gutter_len := length - 0.55
		if gutter_len < 1.0:
			b.pop_layer()
			continue
		var g_cx: float = 0.0
		var g_cz: float = 0.0
		var g_w: float = 0.0
		var g_d: float = 0.0
		match side:
			0: g_cx = length * 0.5; g_cz = -DRAIN_GUTTER_T * 0.5 - eps; g_w = gutter_len; g_d = DRAIN_GUTTER_T
			1: g_cx = w + DRAIN_GUTTER_T * 0.5 + eps; g_cz = length * 0.5; g_w = DRAIN_GUTTER_T; g_d = gutter_len
			2: g_cx = length * 0.5; g_cz = d + DRAIN_GUTTER_T * 0.5 + eps; g_w = gutter_len; g_d = DRAIN_GUTTER_T
			_: g_cx = -DRAIN_GUTTER_T * 0.5 - eps; g_cz = length * 0.5; g_w = DRAIN_GUTTER_T; g_d = gutter_len
		var gutter_col := pipe_col.lightened(0.06)
		b.add_box_rotated(off + Vector3(g_cx, gutter_y, g_cz),
				Vector3(g_w, DRAIN_GUTTER_H, g_d), Basis.IDENTITY, gutter_col, false, false, &"", "drainpipe", 0)
		b.pop_layer()

## Phase Z: Prague window shutters — hinged wooden shutters beside historic windows.
## Visual-only thin planes (SHUTTER_T 0.025) pressed just outside the wall
## flanking each window opening. Deterministic per (building, side, floor,
## window) via WorldSeed "shutter", gated to historic + long facade (>=5.0).
## Each qualifying window rolls SHUTTER_PROB 0.52 independently; on success
## it grows a LEFT + RIGHT shutter leaf (SHUTTER_W 0.30 x SHUTTER_H 1.22)
## with a SHUTTER_GAP 0.04 from the window edge, centered at the window's
## sill mid-height. Faint Prague wood palette (desaturated browns/greens),
## visual-only, no collision or parkour change. Mirrors the window layout
## computed by _facade_with_openings so shutters sit exactly beside glass.
static func _facade_shutters(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var shutter_colors: Array[Color] = [
		Color("5a3a2a"), Color("4a5a3a"), Color("3a4a5a"),
		Color("6e5a3a"), Color("6e4a3a"), Color("4a5a6e"),
	]
	var door_edge: int = int(spec.get("door_edge", 0))
	for f_idx in n:
		var y0 := f_idx * fh
		var cy := y0 + WIN_SILL + WIN_H * 0.5
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < SHUTTER_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(t)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("shutter", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= SHUTTER_PROB:
					continue
				var col: Color = shutter_colors[rng.randi_range(0, shutter_colors.size() - 1)]
				col = col.lightened(rng.randf_range(-0.06, 0.06)).darkened(0.03)
				col = col.lerp(Color(0.60, 0.58, 0.55), 0.12)
				var left_t := t_center - (WIN_W * 0.5 + SHUTTER_W * 0.5 + SHUTTER_GAP)
				var right_t := t_center + (WIN_W * 0.5 + SHUTTER_W * 0.5 + SHUTTER_GAP)
				left_t = clampf(left_t, SHUTTER_W * 0.5 + 0.18, length - SHUTTER_W * 0.5 - 0.18)
				right_t = clampf(right_t, SHUTTER_W * 0.5 + 0.18, length - SHUTTER_W * 0.5 - 0.18)
				var eps := 0.045
				for shutter_t in [left_t, right_t]:
					var cx: float = 0.0
					var cz: float = 0.0
					var aw: float = 0.0
					var ad: float = 0.0
					match side:
						0: cx = shutter_t; cz = -SHUTTER_T * 0.5 - eps; aw = SHUTTER_W; ad = SHUTTER_T
						1: cx = w + SHUTTER_T * 0.5 + eps; cz = shutter_t; aw = SHUTTER_T; ad = SHUTTER_W
						2: cx = shutter_t; cz = d + SHUTTER_T * 0.5 + eps; aw = SHUTTER_W; ad = SHUTTER_T
						_: cx = -SHUTTER_T * 0.5 - eps; cz = shutter_t; aw = SHUTTER_T; ad = SHUTTER_W
					b.push_layer(tag + ":f%d" % f_idx)
					b.add_box_rotated(off + Vector3(cx, cy, cz),
							Vector3(aw, SHUTTER_H, ad), Basis.IDENTITY, col, false, false, &"", "shutter", f_idx)
					b.pop_layer()


## Phase AA: Prague window flower boxes — terracotta trough + trailing bloom under historic sills.
## Visual-only boxes pressed just outside the wall under each window sill,
## deterministic per (building, side, floor, window) via WorldSeed "flowerbox",
## gated to historic + long facade (>= FLOWER_MIN_SIDE 5.0). Each qualifying
## window rolls FLOWER_PROB 0.42 independently; on success it grows a
## terracotta trough (FLOWER_W 1.38 x FLOWER_H 0.18 x FLOWER_D 0.22, protruding
## beyond the wall face) plus a foliage bloom mass (slightly inset,
## FLOWER_W*0.92 x FLOWER_BLOOM_H 0.12 x FLOWER_D*0.88) sitting atop the trough.
## Both are visual-only, no collision, tagged "flowerbox" per floor. Mirrors
## the window layout computed by _facade_with_openings so boxes sit exactly
## under glass, at sill height.
static func _facade_flower_boxes(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var trough_base := Color("b06238").darkened(0.04)
	var bloom_palette: Array[Color] = [
		Color("4a7a3a"), Color("6e4a3a"), Color("c73a2e"),
		Color("e8a040"), Color("5a6e4a"), Color("8a7a30"),
	]
	var door_edge: int = int(spec.get("door_edge", 0))
	for f_idx in n:
		var y0 := f_idx * fh
		var trough_cy := y0 + WIN_SILL - FLOWER_H * 0.5
		var bloom_cy := y0 + WIN_SILL + FLOWER_BLOOM_H * 0.5
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < FLOWER_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(t)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("flowerbox", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= FLOWER_PROB:
					continue
				var trough_c: Color = trough_base.lightened(rng.randf_range(-0.06, 0.06))
				var bloom_c: Color = bloom_palette[rng.randi_range(0, bloom_palette.size() - 1)]
				bloom_c = bloom_c.lightened(rng.randf_range(-0.07, 0.07)).darkened(0.02)
				bloom_c = bloom_c.lerp(Color(0.62, 0.64, 0.58), 0.18)
				var eps := 0.045
				var trough_w := FLOWER_W
				var trough_d := FLOWER_D
				var bloom_w := FLOWER_W * 0.92
				var bloom_d := FLOWER_D * 0.88
				var cx_t: float = 0.0
				var cz_t: float = 0.0
				var aw_t: float = 0.0
				var ad_t: float = 0.0
				match side:
					0: cx_t = t_center; cz_t = -trough_d * 0.5 - eps; aw_t = trough_w; ad_t = trough_d
					1: cx_t = w + trough_d * 0.5 + eps; cz_t = t_center; aw_t = trough_d; ad_t = trough_w
					2: cx_t = t_center; cz_t = d + trough_d * 0.5 + eps; aw_t = trough_w; ad_t = trough_d
					_: cx_t = -trough_d * 0.5 - eps; cz_t = t_center; aw_t = trough_d; ad_t = trough_w
				b.push_layer(tag + ":f%d" % f_idx)
				b.add_box_rotated(off + Vector3(cx_t, trough_cy, cz_t),
						Vector3(aw_t, FLOWER_H, ad_t), Basis.IDENTITY, trough_c, false, false, &"", "flowerbox", f_idx)
				var cx_b: float = 0.0
				var cz_b: float = 0.0
				var aw_b: float = 0.0
				var ad_b: float = 0.0
				match side:
					0: cx_b = t_center; cz_b = -bloom_d * 0.5 - eps; aw_b = bloom_w; ad_b = bloom_d
					1: cx_b = w + bloom_d * 0.5 + eps; cz_b = t_center; aw_b = bloom_d; ad_b = bloom_w
					2: cx_b = t_center; cz_b = d + bloom_d * 0.5 + eps; aw_b = bloom_w; ad_b = bloom_d
					_: cx_b = -bloom_d * 0.5 - eps; cz_b = t_center; aw_b = bloom_d; ad_b = bloom_w
				b.add_box_rotated(off + Vector3(cx_b, bloom_cy, cz_b),
						Vector3(aw_b, FLOWER_BLOOM_H, ad_b), Basis.IDENTITY, bloom_c, false, false, &"", "flowerbox", f_idx)
				b.pop_layer()

## Phase AB: Prague window stone lintels — header trim above historic windows.
## Visual-only thin stone slabs (WINDOW_TRIM_H 0.14 x WINDOW_TRIM_T 0.05,
## width WIN_W 1.15 + 0.26 = 1.41) pressed just outside the wall above each
## window opening. Deterministic per (building, side, floor, window) via
## WorldSeed "window_trim", gated to historic + long facade (>=5.0).
## Each qualifying window rolls WINDOW_TRIM_PROB 0.58 independently; on success
## it grows a lintel stone header above the window (gap 0.02 above the glass
## top), visual-only, no collision. Mirrors the window layout computed by
## _facade_with_openings so headers sit exactly above glass.
static func _facade_window_trim(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	var lintel_w := WIN_W + WINDOW_TRIM_W_EXTRA
	for f_idx in n:
		var y0 := f_idx * fh
		# lintel sits just above the window header with a 0.02 gap
		var cy := y0 + WIN_SILL + WIN_H + WINDOW_TRIM_H * 0.5 + 0.02
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < WINDOW_TRIM_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(t)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("window_trim", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= WINDOW_TRIM_PROB:
					continue
				var stone_c := Color("9e968a").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.02)
				stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.10)
				var eps := 0.045
				var cx: float = 0.0
				var cz: float = 0.0
				var aw: float = 0.0
				var ad: float = 0.0
				match side:
					0: cx = t_center; cz = -WINDOW_TRIM_T * 0.5 - eps; aw = lintel_w; ad = WINDOW_TRIM_T
					1: cx = w + WINDOW_TRIM_T * 0.5 + eps; cz = t_center; aw = WINDOW_TRIM_T; ad = lintel_w
					2: cx = t_center; cz = d + WINDOW_TRIM_T * 0.5 + eps; aw = lintel_w; ad = WINDOW_TRIM_T
					_: cx = -WINDOW_TRIM_T * 0.5 - eps; cz = t_center; aw = WINDOW_TRIM_T; ad = lintel_w
				b.push_layer(tag + ":f%d" % f_idx)
				b.add_box_rotated(off + Vector3(cx, cy, cz),
						Vector3(aw, WINDOW_TRIM_H, ad), Basis.IDENTITY, stone_c, false, false, &"", "trim", f_idx)
				b.pop_layer()

## Phase AC: Prague window stone sills — sill ledge below historic windows.
## Visual-only thin stone slabs (SILL_H 0.09 x SILL_T 0.06,
## width WIN_W 1.15 + 0.24 = 1.39) pressed just outside the wall at the sill
## line, directly under each window opening. Deterministic per (building, side,
## floor, window) via WorldSeed "sill_stone", gated to historic + long facade
## (>=5.0). Each qualifying window rolls SILL_PROB 0.60 independently; on success
## it grows a stone sill ledge whose TOP sits flush with the window sill
## (WIN_SILL), visual-only, no collision. Mirrors the window layout computed by
## _facade_with_openings so sills sit exactly under glass.
static func _facade_sill_ledges(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	var sill_w := WIN_W + SILL_W_EXTRA
	for f_idx in n:
		var y0 := f_idx * fh
		# sill top flush with window sill: center = y0 + WIN_SILL - SILL_H/2
		var cy := y0 + WIN_SILL - SILL_H * 0.5 + 0.015
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < SILL_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(t)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("sill_stone", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= SILL_PROB:
					continue
				var stone_c := Color("a8a098").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.03)
				stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.10)
				var eps := 0.045
				var cx: float = 0.0
				var cz: float = 0.0
				var aw: float = 0.0
				var ad: float = 0.0
				match side:
					0: cx = t_center; cz = -SILL_T * 0.5 - eps; aw = sill_w; ad = SILL_T
					1: cx = w + SILL_T * 0.5 + eps; cz = t_center; aw = SILL_T; ad = sill_w
					2: cx = t_center; cz = d + SILL_T * 0.5 + eps; aw = sill_w; ad = SILL_T
					_: cx = -SILL_T * 0.5 - eps; cz = t_center; aw = SILL_T; ad = sill_w
				b.push_layer(tag + ":f%d" % f_idx)
				b.add_box_rotated(off + Vector3(cx, cy, cz),
						Vector3(aw, SILL_H, ad), Basis.IDENTITY, stone_c, false, false, &"", "sill", f_idx)
				b.pop_layer()

## Phase AD: Prague window stone jambs — vertical stone reveals flanking historic windows.
## Visual-only thin stone strips (JAMB_W 0.11 x WIN_H 1.35 x JAMB_T 0.04,
## height WIN_H, width 0.11) pressed just outside the wall beside each
## window opening, left+right pair per window at WINDOW sill mid-height.
## Deterministic per (building, side, floor, window) via WorldSeed "window_jamb",
## gated to historic + long facade (>=5.0). Each qualifying window rolls
## JAMB_PROB 0.56 independently; on success it grows a left+right jamb pair
## whose inner faces sit flush with the window edges (center = t_center ±
## (WIN_W/2 + JAMB_W/2)), visual-only, no collision. Completes the classical
## stone window surround when combined with Phase AB lintels + AC sills. Mirrors
## the window layout computed by _facade_with_openings so jambs sit exactly
## beside glass.
static func _facade_window_jambs(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	for f_idx in n:
		var y0 := f_idx * fh
		var cy := y0 + WIN_SILL + WIN_H * 0.5
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < JAMB_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(t)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("window_jamb", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= JAMB_PROB:
					continue
				var stone_c := Color("b0a898").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.03)
				stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.11)
				var eps := 0.045
				var left_t := t_center - (WIN_W * 0.5 + JAMB_W * 0.5)
				var right_t := t_center + (WIN_W * 0.5 + JAMB_W * 0.5)
				for jamb_t in [left_t, right_t]:
					var cx: float = 0.0
					var cz: float = 0.0
					var aw: float = 0.0
					var ad: float = 0.0
					match side:
						0: cx = jamb_t; cz = -JAMB_T * 0.5 - eps; aw = JAMB_W; ad = JAMB_T
						1: cx = w + JAMB_T * 0.5 + eps; cz = jamb_t; aw = JAMB_T; ad = JAMB_W
						2: cx = jamb_t; cz = d + JAMB_T * 0.5 + eps; aw = JAMB_W; ad = JAMB_T
						_: cx = -JAMB_T * 0.5 - eps; cz = jamb_t; aw = JAMB_T; ad = JAMB_W
					b.push_layer(tag + ":f%d" % f_idx)
					b.add_box_rotated(off + Vector3(cx, cy, cz),
							Vector3(aw, WIN_H, ad), Basis.IDENTITY, stone_c, false, false, &"", "jamb", f_idx)
					b.pop_layer()

## Phase AE: Prague window stone keystones -- central header stone above historic windows.
## Visual-only thin stone block (KEYSTONE_W 0.28 x KEYSTONE_H 0.18 x KEYSTONE_T 0.055)
## centered above each window at y = y0+WIN_SILL+WIN_H+0.24 (just crowning the AB
## lintel, slightly embedded so the header reads as one stone assembly).
## Deterministic per (building, side, floor, window) via WorldSeed "window_keystone",
## gated to historic + long facade (>=5.0). Each qualifying window rolls
## KEYSTONE_PROB 0.52 independently; on success it grows a single central
## keystone (wider than the jamb, narrower than the lintel) whose bottom is
## ~1cm below the lintel top so the two stones read as a continuous header.
## Mirrors the window layout computed by _facade_with_openings so keystones
## sit exactly above glass.
static func _facade_window_keystones(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	for f_idx in n:
		var y0 := f_idx * fh
		var cy := y0 + WIN_SILL + WIN_H + 0.24
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < KEYSTONE_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var tr := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(tr - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(tr)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("window_keystone", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= KEYSTONE_PROB:
					continue
				var stone_c := Color("c4b8a0").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.02)
				stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.11)
				var eps := 0.050
				var cx: float = 0.0
				var cz: float = 0.0
				var aw: float = 0.0
				var ad: float = 0.0
				match side:
					0: cx = t_center; cz = -KEYSTONE_T * 0.5 - eps; aw = KEYSTONE_W; ad = KEYSTONE_T
					1: cx = w + KEYSTONE_T * 0.5 + eps; cz = t_center; aw = KEYSTONE_T; ad = KEYSTONE_W
					2: cx = t_center; cz = d + KEYSTONE_T * 0.5 + eps; aw = KEYSTONE_W; ad = KEYSTONE_T
					_: cx = -KEYSTONE_T * 0.5 - eps; cz = t_center; aw = KEYSTONE_T; ad = KEYSTONE_W
				b.push_layer(tag + ":f%d" % f_idx)
				b.add_box_rotated(off + Vector3(cx, cy, cz),
						Vector3(aw, KEYSTONE_H, ad), Basis.IDENTITY, stone_c, false, false, &"", "keystone", f_idx)
				b.pop_layer()

## Phase AF: Prague window sill corbels -- stone support brackets under historic sills.
## Visual-only small stone blocks (CORBEL_W 0.13 x CORBEL_H 0.16 x CORBEL_D 0.09)
## pressed just outside the wall UNDER the AC sill ledge, pair per window at
## t_center +/-0.35 (inset ~0.15 from window edge, comfortably inside the
## 1.39 sill span). y = y0+WIN_SILL - SILL_H +0.015 - CORBEL_H/2 (top flush
## with sill bottom). Deterministic per (building, side, floor, window) via
## WorldSeed "sill_corbel", gated to historic + long facade (>=5.0).
## Mirrors the window layout so corbels sit exactly under glass.
static func _facade_sill_corbels(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	for f_idx in n:
		var y0 := f_idx * fh
		var cy := y0 + WIN_SILL - SILL_H + 0.015 - CORBEL_H * 0.5
		for side in 4:
			var length := w if (side == 0 or side == 2) else d
			if length < CORBEL_MIN_SIDE:
				continue
			var is_entrance_side := (side == door_edge) and f_idx == 0
			var count := int(floor((length - 1.6) / WIN_SPACING))
			var win_centers: Array[float] = []
			for i in count:
				var tr := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
				if is_entrance_side and absf(tr - length * 0.5) < DOOR_W * 0.5 + 0.9:
					continue
				win_centers.append(tr)
			for win_idx in win_centers.size():
				var t_center: float = win_centers[win_idx]
				var rng := WorldSeed.rng_for("sill_corbel", [WorldSeed.str_hash(tag), side * 1000 + f_idx * 100 + win_idx])
				if rng.randf() >= CORBEL_PROB:
					continue
				var stone_c := Color("b8a898").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.03)
				stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.11)
				var eps := 0.045
				var left_t := t_center - 0.35
				var right_t := t_center + 0.35
				left_t = clampf(left_t, CORBEL_W * 0.5 + 0.18, length - CORBEL_W * 0.5 - 0.18)
				right_t = clampf(right_t, CORBEL_W * 0.5 + 0.18, length - CORBEL_W * 0.5 - 0.18)
				for corbel_t in [left_t, right_t]:
					var cx: float = 0.0
					var cz: float = 0.0
					var aw: float = 0.0
					var ad: float = 0.0
					match side:
						0: cx = corbel_t; cz = -CORBEL_D * 0.5 - eps; aw = CORBEL_W; ad = CORBEL_D
						1: cx = w + CORBEL_D * 0.5 + eps; cz = corbel_t; aw = CORBEL_D; ad = CORBEL_W
						2: cx = corbel_t; cz = d + CORBEL_D * 0.5 + eps; aw = CORBEL_W; ad = CORBEL_D
						_: cx = -CORBEL_D * 0.5 - eps; cz = corbel_t; aw = CORBEL_D; ad = CORBEL_W
					b.push_layer(tag + ":f%d" % f_idx)
					b.add_box_rotated(off + Vector3(cx, cy, cz),
							Vector3(aw, CORBEL_H, ad), Basis.IDENTITY, stone_c, false, false, &"", "corbel", f_idx)
					b.pop_layer()

## Phase AG: Prague doorway stone portal — framed historic entrance.
## Visual-only thin stone boxes (PORTAL_JAMB_W 0.16 x PORTAL_JAMB_H 2.25 x PORTAL_JAMB_T 0.05 jamb pair + lintel ~2.22 x 0.18 x 0.055)
## pressed just outside the entrance wall around the doorway opening (jambs at DOOR_H/2, lintel at DOOR_H+0.02+0.09).
## Deterministic per building via WorldSeed "door_portal", gated to historic + long entrance facade (>=5.0).
## One roll per building (PORTAL_PROB 0.65); on success grows exactly 3 boxes — left jamb, right jamb, header lintel —
## centered on the doorway (length*0.5) with jamb inner faces at mid ± (DOOR_W/2+JAMB_W/2) and lintel width DOOR_W+2*JAMB_W+EXTRA.
## Visual-only, no collision, layer f0 tagged portal, stone b9aa90 desaturated 0.11.
static func _facade_door_portals(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	var door_edge: int = int(spec.get("door_edge", 0))
	var length := w if (door_edge == 0 or door_edge == 2) else d
	if length < PORTAL_MIN_SIDE:
		return
	var rng := WorldSeed.rng_for("door_portal", [WorldSeed.str_hash(tag)])
	if rng.randf() >= PORTAL_PROB:
		return
	var stone_c := Color("b9aa90").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.03)
	stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.11)
	var eps := 0.045
	var mid := length * 0.5
	var lintel_w := DOOR_W + 2.0 * PORTAL_JAMB_W + PORTAL_LINTEL_EXTRA
	var left_t := mid - (DOOR_W * 0.5 + PORTAL_JAMB_W * 0.5)
	var right_t := mid + (DOOR_W * 0.5 + PORTAL_JAMB_W * 0.5)
	var jamb_cy := PORTAL_JAMB_H * 0.5
	var lintel_cy := DOOR_H + 0.02 + PORTAL_LINTEL_H * 0.5
	# Left + right jambs
	for jamb_t in [left_t, right_t]:
		var cx: float = 0.0
		var cz: float = 0.0
		var aw: float = 0.0
		var ad: float = 0.0
		match door_edge:
			0: cx = jamb_t; cz = -PORTAL_JAMB_T * 0.5 - eps; aw = PORTAL_JAMB_W; ad = PORTAL_JAMB_T
			1: cx = w + PORTAL_JAMB_T * 0.5 + eps; cz = jamb_t; aw = PORTAL_JAMB_T; ad = PORTAL_JAMB_W
			2: cx = jamb_t; cz = d + PORTAL_JAMB_T * 0.5 + eps; aw = PORTAL_JAMB_W; ad = PORTAL_JAMB_T
			_: cx = -PORTAL_JAMB_T * 0.5 - eps; cz = jamb_t; aw = PORTAL_JAMB_T; ad = PORTAL_JAMB_W
		b.push_layer(tag + ":f0")
		b.add_box_rotated(off + Vector3(cx, jamb_cy, cz),
				Vector3(aw, PORTAL_JAMB_H, ad), Basis.IDENTITY, stone_c, false, false, &"", "portal", 0)
		b.pop_layer()
	# Header lintel centered above doorway
	var lcx: float = 0.0
	var lcz: float = 0.0
	var law: float = 0.0
	var lad: float = 0.0
	match door_edge:
		0: lcx = mid; lcz = -PORTAL_LINTEL_T * 0.5 - eps; law = lintel_w; lad = PORTAL_LINTEL_T
		1: lcx = w + PORTAL_LINTEL_T * 0.5 + eps; lcz = mid; law = PORTAL_LINTEL_T; lad = lintel_w
		2: lcx = mid; lcz = d + PORTAL_LINTEL_T * 0.5 + eps; law = lintel_w; lad = PORTAL_LINTEL_T
		_: lcx = -PORTAL_LINTEL_T * 0.5 - eps; lcz = mid; law = PORTAL_LINTEL_T; lad = lintel_w
	b.push_layer(tag + ":f0")
	b.add_box_rotated(off + Vector3(lcx, lintel_cy, lcz),
			Vector3(law, PORTAL_LINTEL_H, lad), Basis.IDENTITY, stone_c, false, false, &"", "portal", 0)
	b.pop_layer()

## Phase AH: Prague facade quoins — rusticated corner stones.
## Visual-only thin stone blocks (QUOIN_W 0.44 x fh-0.02 x QUOIN_T 0.06)
## pressed just outside the four building corners at each storey, giving the
## historic core its classic rusticated-corner read. Deterministic per building
## via WorldSeed "quoin" (one roll per building, QUOIN_PROB 0.60), gated to
## historic + both footprint axes >= QUOIN_MIN_SIDE 5.0. Each qualifying
## building grows exactly 8 * n visual-only boxes (2 per side per floor: west+east
## on N/S walls, north+south on E/W walls) at y = f*fh + fh*0.5, thin 0.06
## protruding beyond the wall face (eps 0.05), stone aba090 desaturated 0.11,
## layered f* tagged quoin. No collision or parkour change.
static func _facade_quoins(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, n: int, tag: String, spec: Dictionary) -> void:
	if str(spec.get("district", "")) != "historic":
		return
	if w < QUOIN_MIN_SIDE or d < QUOIN_MIN_SIDE:
		return
	var rng := WorldSeed.rng_for("quoin", [WorldSeed.str_hash(tag)])
	if rng.randf() >= QUOIN_PROB:
		return
	var stone_c := Color("aba090").lightened(rng.randf_range(-0.05, 0.06)).darkened(0.03)
	stone_c = stone_c.lerp(Color(0.64, 0.63, 0.60), 0.11)
	var eps := 0.05
	for f_idx in n:
		var cy := f_idx * fh + fh * 0.5
		var h := fh - 0.02
		# N wall (side 0) — west + east corners
		for corner_x: float in [QUOIN_W * 0.5, w - QUOIN_W * 0.5]:
			var cx: float = corner_x
			var cz := -QUOIN_T * 0.5 - eps
			b.push_layer(tag + ":f%d" % f_idx)
			b.add_box_rotated(off + Vector3(cx, cy, cz),
					Vector3(QUOIN_W, h, QUOIN_T), Basis.IDENTITY, stone_c, false, false, &"", "quoin", f_idx)
			b.pop_layer()
		# S wall (side 2)
		for corner_x2: float in [QUOIN_W * 0.5, w - QUOIN_W * 0.5]:
			var cx2: float = corner_x2
			var cz2 := d + QUOIN_T * 0.5 + eps
			b.push_layer(tag + ":f%d" % f_idx)
			b.add_box_rotated(off + Vector3(cx2, cy, cz2),
					Vector3(QUOIN_W, h, QUOIN_T), Basis.IDENTITY, stone_c, false, false, &"", "quoin", f_idx)
			b.pop_layer()
		# E wall (side 1)
		for corner_z: float in [QUOIN_W * 0.5, d - QUOIN_W * 0.5]:
			var cx3 := w + QUOIN_T * 0.5 + eps
			var cz3: float = corner_z
			b.push_layer(tag + ":f%d" % f_idx)
			b.add_box_rotated(off + Vector3(cx3, cy, cz3),
					Vector3(QUOIN_T, h, QUOIN_W), Basis.IDENTITY, stone_c, false, false, &"", "quoin", f_idx)
			b.pop_layer()
		# W wall (side 3)
		for corner_z2: float in [QUOIN_W * 0.5, d - QUOIN_W * 0.5]:
			var cx4 := -QUOIN_T * 0.5 - eps
			var cz4: float = corner_z2
			b.push_layer(tag + ":f%d" % f_idx)
			b.add_box_rotated(off + Vector3(cx4, cy, cz4),
					Vector3(QUOIN_T, h, QUOIN_W), Basis.IDENTITY, stone_c, false, false, &"", "quoin", f_idx)
			b.pop_layer()

## One facade:
## `is_entrance` turns the mid-facade door into a real aperture; the Door
## ENTITY from the CityPlan manifest fills it at runtime.
static func _facade_with_openings(b: MeshBatcher, off: Vector3, side: int,
		w: float, d: float, y0: float, fh: float, col: Color, floor_i: int,
		is_entrance: bool, is_historic: bool = false, tag: String = "") -> void:
	var horizontal := side == 0 or side == 2     # N/S walls run along X
	var length := w if horizontal else d
	var lo := -WALL_T * 0.5                      # extend past corners like the
	var hi := length + WALL_T * 0.5              # old monolithic walls did

	# --- openings: {c: center_t, wd: width, bot: sill height, h: height,
	#                glass: bool}
	var openings: Array[Dictionary] = []
	# Doorway aperture gets a small jamb clearance (real door frames have
	# one) so the leaf never rubs the piers and no collider face lies
	# exactly on the leaf's swing plane.
	if is_entrance and floor_i == 0:
		openings.append({"c": length * 0.5, "wd": DOOR_W + DOOR_FRAME,
				"bot": 0.0, "h": DOOR_H, "glass": false})
	var count := int(floor((length - 1.6) / WIN_SPACING))
	for i in count:
		var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
		if is_entrance and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
			continue   # keep the entrance clear; shopfront dresses this wall
		openings.append({"c": t, "wd": WIN_W, "bot": WIN_SILL, "h": WIN_H,
				"glass": true})
	if openings.is_empty():
		# Solid wall: one full-length piece.
		_emit_wall_seg(b, off, side, horizontal, lo, hi, y0, fh, col, w, d)
		return
	openings.sort_custom(_opening_cmp)

	# --- piers between openings (full height) ---------------------------------
	var cursor := lo
	for o in openings:
		var a: float = float(o["c"]) - float(o["wd"]) * 0.5
		if a - cursor >= 0.05:
			_emit_wall_seg(b, off, side, horizontal, cursor, a, y0, fh,
					col, w, d)
		cursor = maxf(cursor, float(o["c"]) + float(o["wd"]) * 0.5)
	if hi - cursor >= 0.05:
		_emit_wall_seg(b, off, side, horizontal, cursor, hi, y0, fh, col,
				w, d)

	# --- vertical closure + glass per opening ----------------------------------
	var win_idx := 0
	for o in openings:
		var oc: float = float(o["c"])
		var obot: float = float(o["bot"])
		var oh: float = float(o["h"])
		var owd: float = float(o["wd"])
		# Sill band below window openings.
		if obot > 0.05:
			_emit_band(b, off, side, horizontal, w, d, oc, owd, y0,
					obot, col)
		# Structural lintel/header above every opening.
		var lh := fh - obot - oh
		if lh > 0.05:
			_emit_band(b, off, side, horizontal, w, d, oc, owd,
					y0 + obot + oh, lh, col)
		# Glass pane centered INSIDE the aperture (windows only).
		if bool(o["glass"]):
			var cur_idx := win_idx
			var is_broken := false
			if is_historic and tag != "":
				var length_b := w if horizontal else d
				if length_b >= BROKEN_MIN_SIDE:
					var rng_br := WorldSeed.rng_for("broken_win",
							[WorldSeed.str_hash(tag), side * 1000 + floor_i * 100 + cur_idx])
					if rng_br.randf() < BROKEN_WIN_PROB:
						is_broken = true
			win_idx += 1
			if is_broken:
				# Missing pane — leave the aperture open but add a dark
				# interior plane so the hole reads as interior darkness,
				# not a transparent peek into empty volume. Visual-only.
				var p_dark := _side_point(side, w, d, oc)
				var inside := 0.55
				match side:
					0: p_dark = Vector2(oc, WALL_T + inside)
					1: p_dark = Vector2(w - WALL_T - inside, oc)
					2: p_dark = Vector2(oc, d - WALL_T - inside)
					_: p_dark = Vector2(WALL_T + inside, oc)
				var dark_sz := Vector3(owd - 0.12, oh - 0.12, BROKEN_DARK_T) \
						if horizontal else Vector3(BROKEN_DARK_T, oh - 0.12, owd - 0.12)
				var dark_c := Color("0f1216")
				b.push_layer("%s:f%d" % [tag, floor_i])
				b.add_box_rotated(off + Vector3(p_dark.x, y0 + obot + oh * 0.5, p_dark.y),
						dark_sz, Basis.IDENTITY, dark_c, false, false, &"", "broken", floor_i)
				b.pop_layer()
			else:
				var p := _side_point(side, w, d, oc)
				var gsize := Vector3(owd - 0.06, oh - 0.04, GLASS_T) \
						if horizontal else Vector3(GLASS_T, oh - 0.04, owd - 0.06)
				b.add_destructible_box(
						off + Vector3(p.x, y0 + obot + oh * 0.5, p.y), gsize,
						WINDOW_COLOR, &"glass", true, "", -1)
				# Phase U: faint warm interior glow behind intact historic glass.
				# Night-only OmniLight via MeshBatcher.window_glows() -> ChunkBuilder.
				# Deterministic per (building, side, floor, window) via WorldSeed,
				# gated to historic + long facade, intact pane only, sparse.
				if is_historic and tag != "":
					var length_g := w if horizontal else d
					if length_g >= WINDOW_GLOW_MIN_SIDE:
						var rng_glow := WorldSeed.rng_for("window_glow",
								[WorldSeed.str_hash(tag), side * 1000 + floor_i * 100 + cur_idx])
						if rng_glow.randf() < WINDOW_GLOW_PROB:
							var glow_inside := WINDOW_GLOW_INSET
							var glow_p := Vector2.ZERO
							match side:
								0: glow_p = Vector2(oc, WALL_T + glow_inside)
								1: glow_p = Vector2(w - WALL_T - glow_inside, oc)
								2: glow_p = Vector2(oc, d - WALL_T - glow_inside)
								_: glow_p = Vector2(WALL_T + glow_inside, oc)
							var glow_y := y0 + obot + oh * 0.5
							b.add_window_glow(off + Vector3(glow_p.x, glow_y, glow_p.y))
		else:
			# Door opening: no window index to advance, but keep ordering stable.
			pass


static func _emit_wall_seg(b: MeshBatcher, off: Vector3, side: int,
		horizontal: bool, a: float, b2: float, y0: float, fh: float,
		col: Color, w: float, d: float) -> void:
	# Horizontal wall modules (P1-9): piers longer than ~WALL_CELL split
	# into even ~1.25 m destructible cells so blasts punch LOCAL holes.
	# Vertical courses stay full-storey (documented compromise - keeps the
	# collider count linear and small; asserted by --citytest).
	var length := b2 - a
	var cells := maxi(1, ceili(length / WALL_CELL))
	var cw := length / float(cells)
	for i in cells:
		var mid_t := a + (float(i) + 0.5) * cw
		var p := _side_point(side, w, d, mid_t)
		var size := Vector3(cw, fh, WALL_T) if horizontal \
				else Vector3(WALL_T, fh, cw)
		b.add_destructible_box(off + Vector3(p.x, y0 + fh * 0.5, p.y),
				size, col, &"concrete")


## Sill/lintel band of `bw` meters centered at opening center `oc`.
static func _emit_band(b: MeshBatcher, off: Vector3, side: int,
		horizontal: bool, w: float, d: float, oc: float, bw: float,
		y_base: float, bh: float, col: Color) -> void:
	var p := _side_point(side, w, d, oc)
	var size := Vector3(bw, bh, WALL_T) if horizontal \
			else Vector3(WALL_T, bh, bw)
	b.add_destructible_box(off + Vector3(p.x, y_base + bh * 0.5, p.y),
			size, col, &"concrete")


static func _opening_cmp(a: Dictionary, b2: Dictionary) -> bool:
	return float(a["c"]) < float(b2["c"])


## Point along a facade at distance t from its first corner.
static func _side_point(side: int, w: float, d: float, t: float) -> Vector2:
	match side:
		0: return Vector2(t, WALL_T * 0.5)          # N: along +X at north face
		1: return Vector2(w - WALL_T * 0.5, t)      # E: along +Z at east face
		2: return Vector2(t, d - WALL_T * 0.5)      # S
		_: return Vector2(WALL_T * 0.5, t)          # W


# --- Windows -----------------------------------------------------------------
# Window apertures are composed by _facade_with_openings() together with the
# entrance door: one generator, one set of physical aperture rules (piers,
# sill, lintel, glass centered inside the gap). Ground-floor shopfront glazing
# follows the same rules when it becomes structural (see _shopfront dressing).

## Signboard band + tall display panels flanking the door on historic lots.
static func _shopfront(b: MeshBatcher, off: Vector3, w: float, d: float,
		spec: Dictionary) -> void:
	var side := int(spec["door_edge"])
	var style: Dictionary = spec["style"]
	var horizontal := side == 0 or side == 2
	var length := w if horizontal else d
	if length < 7.0 or not style.get("attic", false):
		return
	var sign_c: Color = SIGN_COLORS[(style["wall"] + style["roof"]) % SIGN_COLORS.size()]
	var mid := length * 0.5
	var pc := _side_point(side, w, d, mid)
	var bsize := Vector3(length - 0.9, 0.55, 0.55) if horizontal \
			else Vector3(0.55, 0.55, length - 0.9)
	b.add_visual_box(off + Vector3(pc.x, 2.62, pc.y), bsize, sign_c)
	for i in 2:
		var t := mid + (DOOR_W * 0.5 + 1.15) * (1.0 if i == 0 else -1.0)
		var p := _side_point(side, w, d, t)
		var psize := Vector3(1.7, 2.15, 0.5) if horizontal \
				else Vector3(0.5, 2.15, 1.7)
		b.add_visual_box(off + Vector3(p.x, 1.22, p.y), psize, WINDOW_COLOR)


# --- Slabs -------------------------------------------------------------------

## Floor slab split around the stairwell aperture. DELEGATES to slab_pieces()
## so tests can validate coverage numerically without a scene tree.
##
## COVERAGE CONTRACT (enforced by --citytest): union(pieces) equals the usable
## interior footprint minus EXACTLY the shaft hole - no accidental gaps, no
## overlaps, exactly one intended opening.
static func slab_pieces(w: float, d: float, hole: Rect2) -> Array[Rect2]:
	var inner := Rect2(WALL_T, WALL_T,
			maxf(w - 2.0 * WALL_T, 0.0), maxf(d - 2.0 * WALL_T, 0.0))
	return SlabMath.subtract_rect(inner, hole)


static func _slab_with_hole(b: MeshBatcher, off: Vector3, w: float, d: float,
		hole: Rect2, y: float) -> void:
	var cy := y - SLAB_T * 0.5
	for r: Rect2 in slab_pieces(w, d, hole):
		_emit_slab_panels(b, off, r, cy)


## Bounded 2D paneling of ONE slab strip (P1-9): ~CELL_H modules in BOTH
## dimensions so a blast carves a LOCAL hole instead of a full-depth strip
## across the floor. Panel counts derive from the strip size (deterministic,
## no slivers - remainders fold into even cell widths); the count stays
## LINEAR in floor area and far under the RID budget.
static func _emit_slab_panels(b: MeshBatcher, off: Vector3, r: Rect2,
		cy: float) -> void:
	var cols := maxi(1, ceili(r.size.x / CELL_H))
	var rows := maxi(1, ceili(r.size.y / CELL_H))
	var cw := r.size.x / float(cols)
	var ch := r.size.y / float(rows)
	for cx in cols:
		for cz in rows:
			var c := Vector2(r.position.x + (float(cx) + 0.5) * cw,
					r.position.y + (float(cz) + 0.5) * ch)
			b.add_destructible_box(off + Vector3(c.x, cy, c.y),
					Vector3(cw, SLAB_T, ch), DECK_COLOR,
					&"concrete")


# --- Stairs ------------------------------------------------------------------

## Switchback staircase. GEOMETRY CONTRACT (P0-B):
##   - The flight's horizontal run is FIXED by the shaft layout; the ramp
##     angle is DERIVED from it (atan2(fh, run)) - never assumed.
##   - The walkable top surface starts EXACTLY flush with the lower landing
##     top (z0 at height lvl*fh) and ends EXACTLY flush with the upper
##     landing top (z1 at height (lvl+1)*fh). No lip, no invisible step,
##     no overshoot into a landing.
##   - Visual treads are placed ON the same inclined plane as the collider,
##     so what you see is what you stand on.
##   - Slope stays below Survivor.floor_max_angle (46 deg) for every
##     generated floor height (asserted by --citytest).
## Treads are visual only. Landings at both shaft ends on every level are
## structural and tagged f<lvl-1> (the storey you board from).
static func _staircase(b: MeshBatcher, off: Vector3, zone: Rect2,
		fh: float, n: int, tag: String, guard_on_east := true) -> void:
	var z_n := zone.position.y                  # north end
	var z_s := zone.end.y                       # south end
	var zx := zone.position.x
	var cx_west := zx + LANE_W * 0.5
	var cx_east := zx + LANE_W * 1.5

	const LAND_TUCK := 0.08   # landings tuck under flight ends: no seam notch
	# Structural landings at every level 1..n, top FLUSH with that level's
	# floor surface (top face exactly at y = lvl*fh). Level 0 needs none:
	# the ground slab already provides it. Each landing extends a few cm
	# UNDER its adjacent flight ends so the ramp underside meets the landing
	# plate above floor level - a capsule crossing the seam can no longer
	# wedge in the right-angle notch.
	for lvl in range(1, n + 1):
		b.push_layer(tag + ":f%d" % (lvl - 1))
		var ly := lvl * fh - SLAB_T * 0.5
		b.add_destructible_box(
				off + Vector3(zx + LANE_W, ly,
						z_n + (LAND - LAND_TUCK) * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND + LAND_TUCK),
				DECK_COLOR, &"concrete")
		b.add_destructible_box(
				off + Vector3(zx + LANE_W, ly,
						z_s - (LAND - LAND_TUCK) * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND + LAND_TUCK),
				DECK_COLOR, &"concrete")
		b.pop_layer()

	# Flight span between landing INNER edges. No RAMP_OVERLAP fudge: flush
	# start/end come from exact endpoint placement instead.
	var z0 := z_n + LAND
	var z1 := z_s - LAND
	var run := z1 - z0
	var ang := atan2(fh, run)          # DERIVED - the actual slope
	var cos_a := cos(ang)

	for k in n:
		var ascending_south := k % 2 == 0
		var lane_c := cx_west if ascending_south else cx_east
		var y0 := k * fh
		# Single walkable ramp collider. P1-8 GEOMETRY CONTRACT:
		#   - The walkable TOP face lies EXACTLY on the flight plane
		#     through (z0, y0) -> (z1, y0 + fh): the center is the plane
		#     midpoint pushed down half a thickness along the plane NORMAL
		#     (a pure-Y drop skews the box so only ONE endpoint meets its
		#     landing). Both endpoints are therefore FLUSH with their
		#     landing surfaces - no lip a capsule could not climb.
		#   - The seam is kept notch-free WITHOUT trimming the walkable
		#     surface: the landing plates extend LAND_TUCK under each
		#     flight end, so the ramp's end faces and underside corners
		#     are buried inside solid landing geometry (static overlaps
		#     are harmless) and no right-angle pocket remains above any
		#     walkable surface. Verified against the REAL collider bounds
		#     by --citytest.
		b.push_layer(tag + ":f%d" % k)
		var hyp := sqrt(run * run + fh * fh)
		var basis := Basis(Vector3.RIGHT, -ang if ascending_south else ang)
		var n_up := (basis * Vector3(0, 1, 0)).normalized()
		var mid := off + Vector3(lane_c, y0 + fh * 0.5, (z0 + z1) * 0.5)
		b.add_box_rotated(mid - n_up * (RAMP_T * 0.5),
				Vector3(LANE_W - 0.04, RAMP_T, hyp), basis, DECK_COLOR,
				true, false, &"concrete", tag, k)
		# Handrails: only on the OUTER edge of each lane (west lane -> the
		# shaft's west edge against the building interior; east lane -> the
		# shaft's east edge, already long-guarded). The INNER sides face the
		# adjacent lane's solid landing/flight at every z, so no rail is
		# needed there - and a rail would block the switchback crossing
		# (the lane gap between inner rail tips is < the capsule width).
		# Rails stop RAIL_SETBACK short of each flight end so the landing
		# funnel stays clear.
		var rail_len := maxf(hyp - 2.0 * RAIL_SETBACK, hyp * 0.55)
		var rail_sides := [-1.0] if ascending_south else [1.0]
		for rail_side in rail_sides:
			var rail_lat := basis * Vector3(
					rail_side * (LANE_W * 0.5 - 0.04), 0.0, 0.0)
			b.add_box_rotated(
					mid + n_up * 0.85 + rail_lat,
					Vector3(0.07, 0.07, rail_len), basis,
					RAIL_COLOR, true, false, &"steel")
		# Decorative treads (collision comes from the ramps) lying ON the
		# ramp plane: each tread's center follows the same straight line as
		# the collider's top surface, offset by half its thickness along
		# the plane normal. Visual and physical describe ONE plane.
		var steps := maxi(8, int(round(run / 0.28)))
		var step_len := hyp / float(steps)
		for i in steps:
			var raw := (float(i) + 0.5) / float(steps)
			var t := raw if ascending_south else 1.0 - raw
			var z := lerpf(z0, z1, t)
			var sy := y0 + raw * fh + 0.03 / cos_a
			b.add_visual_box(off + Vector3(lane_c, sy, z),
					Vector3(LANE_W - 0.06, 0.06, step_len + 0.02),
					FLOOR_COLOR)
		b.pop_layer()

	# --- fall protection around the shaft --------------------------------------
	# Switchback parity decides which landing halves expose a void:
	#   north landing: both halves connected on EVEN levels (flight L departs
	#     west, flight L-1 arrives east); ISOLATED on odd levels.
	#   south landing: both halves connected on ODD levels; ISOLATED on even
	#     levels (lvl 0 is ground-flush, no fall).
	#   deck (lvl == n): the top flight arrives on exactly ONE half - the
	#     OTHER half is void and gets the rail, the arrival half stays open
	#     or the final flight is unreachable (this boxed-in the descent).
	for lvl in n + 1:
		var ry := lvl * fh + 0.55
		var rail_tag := tag + ":f%d" % maxi(lvl - 1, 0)
		var half_w := LANE_W - 0.06
		var north_void_west := false
		var north_void_east := false
		var south_void_west := false
		var south_void_east := false
		if lvl == n:
			if lvl % 2 == 0:
				# Flight n-1 (odd) arrives north deck EAST half.
				north_void_west = true
				south_void_west = true   # south deck isolated
				south_void_east = true
			else:
				# Flight n-1 (even) arrives south deck WEST half.
				north_void_west = true   # north deck isolated
				north_void_east = true
				south_void_east = true
		elif lvl % 2 == 1 and lvl >= 1:
			north_void_west = true       # north landing isolated
			north_void_east = true
		elif lvl % 2 == 0 and lvl >= 2:
			south_void_west = true       # south landing isolated
			south_void_east = true
		if north_void_west or north_void_east \
				or south_void_west or south_void_east:
			b.push_layer(rail_tag)
			if north_void_west:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 0.5, ry,
								z_n + LAND - 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			if north_void_east:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 1.5, ry,
								z_n + LAND - 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			if south_void_west:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 0.5, ry,
								z_s - LAND + 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			if south_void_east:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 1.5, ry,
								z_s - LAND + 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			b.pop_layer()
	# Long-edge guard between the landings, every storey. NOT at deck level:
	# the bulkhead walls already enclose the shaft up there, and a rail at
	# that height intersects them (wedging actors in the seam).
	for lvl in n:
		b.push_layer(tag + ":f%d" % lvl)
		var ry2 := lvl * fh + 0.55
		var guard_x := zx + LANE_W * 2.0 + 0.06 if guard_on_east \
				else zx - 0.06
		b.add_destructible_box(off + Vector3(guard_x, ry2,
						(z_n + z_s) * 0.5),
				Vector3(0.09, 1.05, zone.size.y - 2.0 * LAND), RAIL_COLOR,
				&"steel")
		b.pop_layer()


# --- Furniture -----------------------------------------------------------------

const FURN_WOOD := Color("a9743e")        # oak tabletops, chair seats
const FURN_WOOD_DARK := Color("5d452c")   # chair backs, table aprons
const FURN_WALNUT := Color("6b4a2f")      # shelf carcasses
const FURN_DESK := Color("7a5230")        # computer desks
const FURN_METAL := Color("3a3f44")       # monitor stands
const FURN_SCREEN := Color("16202b")      # dark monitor panels
const FURN_KEYBOARD := Color("2e3338")
const FURN_POT := Color("b06238")         # terracotta plant pots
const FURN_LEAF := Color("3f7d32")
const FURN_LEAF_DARK := Color("356b2a")
const FURN_BOOKS := [
	Color("7a3030"), Color("31527a"), Color("3f6b34"),
	Color("8a7a30"), Color("5a3a6b"),
]
# Phase D slice 2 - semantic room layouts. Beds and counters are the big
# wall-snapped pieces that make a room READ as residential or retail.
const BED_ALONG := 1.45      # bed width, running ALONG its wall
const BED_DEPTH := 2.05      # headboard (wall side) to footboard
const COUNTER_ALONG := 2.2   # shop counter run along its wall
const COUNTER_DEPTH := 0.62

## Scatter deterministic furniture through one storey's open floor.
## Everything inherits the CURRENT storey layer (the cutaway hides it with
## the room) AND sits on THAT storey's floor: every item's origin Y is
## floor_i * fh (P0-C) - upper-storey furniture can never stack onto the
## ground-floor colliders again.
##
## Placement (P0-D) validates each item's ORIENTED footprint (OBB) against:
## exterior-wall inset, stair shaft + circulation margin, entrance swing +
## walk-in corridor, and previously placed solid items. Visual and collider
## transforms are identical everywhere (the desk body shares its accessories'
## rotated basis; bookshelves are genuinely snapped against their wall).
##
## Phase D slice 2: the room_type label picks the furniture PROGRAM -
## "residential" rooms sleep (wall-snapped beds first, then the home mix),
## "retail" floors sell (wall-run counters, dense shelf rows, display
## tables, never a bed).
static func _furnish(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, floor_i: int, tag: String, zone: Rect2,
		door_edge: int, room_type := "residential") -> void:
	var rng := WorldSeed.rng_for("furnish",
			[WorldSeed.str_hash(tag), floor_i])
	var floor_y := float(floor_i) * fh   # THE floor this furniture lives on
	var usable := Rect2(WALL_T + 0.45, WALL_T + 0.45,
			w - 2.0 * (WALL_T + 0.45), d - 2.0 * (WALL_T + 0.45))
	if usable.size.x < 1.4 or usable.size.y < 1.4:
		return

	# --- keep-out OBBs: stair shaft, entrance swing, walk-in corridor ------
	# The shaft keep-out is the EXACT zone rect: it already contains the
	# builder's structural margins, so nothing overlaps the stairs them-
	# selves. Growing it used to reach the perimeter walls on the zone's
	# anchored side and reject EVERY wall-snapped bookcase there (P1-12).
	var blocked: Array[Dictionary] = []
	blocked.append(_rect_obb(zone))
	if door_edge >= 0:
		var mid_len := (w if door_edge == 0 or door_edge == 2 else d) * 0.5
		var dp := _side_point(door_edge, w, d, mid_len)
		match door_edge:
			0: dp += Vector2(0, 1.1)
			1: dp += Vector2(-1.1, 0)
			2: dp += Vector2(0, -1.1)
			_: dp += Vector2(1.1, 0)
		# Facade-aligned strip covering the leaf swing (~1.5 m radius) plus
		# a 2.4 m walk-in lane behind it - the entrance route stays open.
		var corridor_len := DOOR_W + 2.4
		var corridor_depth := DOOR_W + 0.4
		var cc := dp
		match door_edge:
			0: cc += Vector2(0, corridor_depth * 0.5 - 0.55)
			1: cc += Vector2(-corridor_depth * 0.5 + 0.55, 0)
			2: cc += Vector2(0, -corridor_depth * 0.5 + 0.55)
			_: cc += Vector2(corridor_depth * 0.5 - 0.55, 0)
		var along_x := door_edge == 0 or door_edge == 2
		blocked.append({
			"c": cc,
			"e": Vector2(corridor_len * 0.5, corridor_depth * 0.5)
					if along_x else Vector2(corridor_depth * 0.5,
					corridor_len * 0.5),
			"r": 0.0,
		})

	var placed: Array[Dictionary] = []    # solid furniture OBBs so far
	var spot_free := func(p: Vector2, half: Vector2, yaw: float) -> bool:
		var obb := {"c": p, "e": half, "r": yaw}
		if not _obb_in_rect(obb, usable):
			return false
		for bl in blocked:
			if _obb_overlap(obb, bl):
				return false
		for q in placed:
			if _obb_overlap(obb, q):
				return false
		return true
	var take_spot := func(half: Vector2, yaw: float) -> Variant:
		for attempt in 40:
			var cand := Vector2(
					rng.randf_range(usable.position.x + half.x,
							usable.end.x - half.x),
					rng.randf_range(usable.position.y + half.y,
							usable.end.y - half.y))
			if spot_free.call(cand, half, yaw):
				placed.append({"c": cand, "e": half, "r": yaw})
				return cand
		return null

	# --- room_type picks the furniture PROGRAM (Phase D slice 2) --------------
	if room_type == "retail":
		# SHOP floor: counters run ALONG a wall, dense shelf rows, small
		# display tables - retail never sleeps.
		for i in rng.randi_range(1, 2):
			var cs := {}
			for attempt in 5:
				cs = _wall_snap_spot(rng, usable, w, d, blocked, placed,
						COUNTER_ALONG * 0.5, COUNTER_DEPTH)
				if not cs.is_empty():
					break
			if cs.is_empty():
				continue
			placed.append(cs["obb"])
			_f_counter(b, off + Vector3(cs["pos"].x, floor_y,
					cs["pos"].y), float(cs["yaw"]), tag, floor_i)
		for i in rng.randi_range(2, 3):
			var s := _shelf_spot(rng, usable, w, d, blocked, placed)
			if s.is_empty():
				break
			placed.append(s["obb"])
			_f_shelf(b, off + Vector3(s["pos"].x, floor_y, s["pos"].y),
					float(s["yaw"]), rng, tag, floor_i)
		for i in rng.randi_range(1, 2):
			var t: Variant = take_spot.call(Vector2(0.63, 0.44), 0.0)
			if t == null:
				break
			var tp: Vector2 = t
			_f_table(b, off + Vector3(tp.x, floor_y, tp.y), tag, floor_i)
		for i in rng.randi_range(1, 2):
			var pv: Variant = take_spot.call(Vector2(0.26, 0.26), 0.0)
			if pv == null:
				break
			var pp: Vector2 = pv
			_f_plant(b, off + Vector3(pp.x, floor_y, pp.y))
	else:
		# RESIDENTIAL floor: beds claim wall space FIRST (largest foot-
		# print wins), then the familiar home mix.
		for i in rng.randi_range(1, 2):
			var bs := {}
			for attempt in 5:
				bs = _wall_snap_spot(rng, usable, w, d, blocked, placed,
						BED_ALONG * 0.5, BED_DEPTH)
				if not bs.is_empty():
					break
			if bs.is_empty():
				continue
			placed.append(bs["obb"])
			_f_bed(b, off + Vector3(bs["pos"].x, floor_y,
					bs["pos"].y), float(bs["yaw"]), tag, floor_i)
		# Tables with chairs pulled up around them.
		for i in rng.randi_range(1, 3):
			var t: Variant = take_spot.call(Vector2(0.63, 0.44), 0.0)
			if t == null:
				break
			var tp: Vector2 = t
			_f_table(b, off + Vector3(tp.x, floor_y, tp.y), tag, floor_i)
			for c in rng.randi_range(1, 2):
				var ca := TAU * rng.randf()
				var cp := tp + Vector2(cos(ca), sin(ca)) * 0.95
				if usable.grow(-0.3).has_point(cp) \
						and spot_free.call(cp, Vector2(0.24, 0.24), ca) \
						or (_obb_in_rect({"c": cp, "e": Vector2(0.24, 0.24),
						"r": ca}, usable.grow(-0.1))
						and not _point_in_any(cp, blocked)):
					_f_chair(b, off + Vector3(cp.x, floor_y, cp.y),
							atan2(tp.x - cp.x, tp.y - cp.y))
		# Bookshelves/wardrobes: snapped against a wall (P1-12 contract).
		for i in rng.randi_range(1, 2):
			var s := _shelf_spot(rng, usable, w, d, blocked, placed)
			if s.is_empty():
				break
			placed.append(s["obb"])
			_f_shelf(b, off + Vector3(s["pos"].x, floor_y, s["pos"].y),
					float(s["yaw"]), rng, tag, floor_i)
		# Computer desks: accessories AND body share one rotated basis.
		for i in rng.randi_range(0, 2):
			var yaw := rng.randf_range(0.0, TAU)
			var dv: Variant = take_spot.call(Vector2(0.68, 0.36), yaw)
			if dv == null:
				break
			var dp2: Vector2 = dv
			_f_desk_pc(b, off + Vector3(dp2.x, floor_y, dp2.y), yaw, tag,
					floor_i)
		# Plant vases tucked into leftovers (soft clutter - no collision).
		for i in rng.randi_range(1, 3):
			var pv: Variant = take_spot.call(Vector2(0.26, 0.26), 0.0)
			if pv == null:
				break
			var pp: Vector2 = pv
			_f_plant(b, off + Vector3(pp.x, floor_y, pp.y))


## Nearest-wall shelf placement (P1-12). The shelf is a 1.6 x 0.34 slab:
## its local X axis is WIDTH, local Z axis is DEPTH. Wall-snapped against
## the interior wall face (+ GAP), yaw turns the width to run ALONG the
## chosen wall. Validation uses the shelf's REAL oriented footprint against
## the interior bounds and keep-out zones - never a furniture-center
## rectangle that excludes wall-adjacent placement.
const SHELF_WIDTH := 1.6
const SHELF_DEPTH := 0.34
const SHELF_GAP := 0.02


static func _shelf_spot(rng: RandomNumberGenerator, usable: Rect2,
		w: float, d: float, blocked: Array[Dictionary],
		placed: Array[Dictionary]) -> Dictionary:
	return _wall_snap_spot(rng, usable, w, d, blocked, placed,
			SHELF_WIDTH * 0.5, SHELF_DEPTH)


## Generic wall-SNAPPED placement for any rectangular piece whose back face
## must touch an interior wall (Phase D slice 2): shelves, counters, beds.
## `half_along` is HALF the along-wall width, `depth` the FULL wall-to-room
## extent; yaw aligns the width axis WITH the chosen wall exactly like the
## furniture builders' basis convention (local X = along-wall, local -Z =
## the wall side). Validation mirrors P1-12: TRUE interior bounds + keep-out
## zones + already-placed OBBs - never a furniture-center rectangle that
## excludes wall-adjacent placement. Returns {} when no side fits.
static func _wall_snap_spot(rng: RandomNumberGenerator, usable: Rect2,
		w: float, d: float, blocked: Array[Dictionary],
		placed: Array[Dictionary], half_along: float,
		depth: float, gap := SHELF_GAP) -> Dictionary:
	var side := rng.randi_range(0, 3)          # 0=W 1=E 2=N 3=S
	var yaw := 0.0
	var pos := Vector2.ZERO
	match side:
		0:   # west wall: width runs along Z, depth extends +X inward
			yaw = PI * 0.5
			pos = Vector2(WALL_T + depth * 0.5 + gap,
					rng.randf_range(usable.position.y + half_along,
							usable.end.y - half_along))
		1:   # east wall
			yaw = PI * 0.5
			pos = Vector2(w - WALL_T - depth * 0.5 - gap,
					rng.randf_range(usable.position.y + half_along,
							usable.end.y - half_along))
		2:   # north wall: width runs along X, depth extends +Y inward
			yaw = 0.0
			pos = Vector2(rng.randf_range(usable.position.x + half_along,
					usable.end.x - half_along),
					WALL_T + depth * 0.5 + gap)
		_:   # south wall
			yaw = 0.0
			pos = Vector2(rng.randf_range(usable.position.x + half_along,
					usable.end.x - half_along),
					d - WALL_T - depth * 0.5 - gap)
	# OBB half-extents MATCH the drawn/colliding box after the wall-aligned
	# yaw: E/W snaps carry (depth/2 along X, half_along along Y) in world
	# terms; N/S snaps the transpose.
	var half := Vector2(depth * 0.5, half_along) if side <= 1 \
			else Vector2(half_along, depth * 0.5)
	var obb := {"c": pos, "e": half, "r": yaw}
	var interior := Rect2(WALL_T, WALL_T,
			maxf(w - 2.0 * WALL_T, 0.0), maxf(d - 2.0 * WALL_T, 0.0))
	if not _obb_in_rect(obb, interior):
		return {}
	for bl in blocked:
		if _obb_overlap(obb, bl):
			return {}
	for q in placed:
		if _obb_overlap(obb, q):
			return {}
	return {"pos": pos, "yaw": yaw, "obb": obb}


static func _point_in_any(p: Vector2, obbs: Array[Dictionary]) -> bool:
	for o in obbs:
		if _obb_contains_point(o, p):
			return true
	return false


## Oriented-bounding-box containment/intersection helpers (2D SAT).
## An OBB is {c: Vector2 center, e: Vector2 half-extents, r: float yaw}.
static func _obb_axes(r: float) -> Vector2:
	return Vector2(cos(r), sin(r))


static func _obb_contains_point(o: Dictionary, p: Vector2) -> bool:
	var u := _obb_axes(float(o["r"]))
	var v := Vector2(-u.y, u.x)
	var l := p - (o["c"] as Vector2)
	var e: Vector2 = o["e"]
	return absf(l.dot(u)) <= e.x + SlabMath.EPS \
			and absf(l.dot(v)) <= e.y + SlabMath.EPS


static func _obb_in_rect(o: Dictionary, r: Rect2) -> bool:
	var u := _obb_axes(float(o["r"]))
	var v := Vector2(-u.y, u.x)
	var e: Vector2 = o["e"]
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner: Vector2 = (o["c"] as Vector2) + u * e.x * sx \
					+ v * e.y * sy
			if not r.grow(SlabMath.EPS).has_point(corner):
				return false
	return true


static func _obb_overlap(a: Dictionary, b2: Dictionary) -> bool:
	var axes: Array[Vector2] = []
	var ua := _obb_axes(float(a["r"]))
	var ub := _obb_axes(float(b2["r"]))
	axes.append(ua)
	axes.append(Vector2(-ua.y, ua.x))
	axes.append(ub)
	axes.append(Vector2(-ub.y, ub.x))
	var ea: Vector2 = a["e"]
	var eb: Vector2 = b2["e"]
	var d: Vector2 = (b2["c"] as Vector2) - (a["c"] as Vector2)
	for ax in axes:
		var ra := ea.x * absf(ax.dot(ua)) + ea.y * absf(ax.dot(Vector2(-ua.y, ua.x)))
		var rb := eb.x * absf(ax.dot(ub)) + eb.y * absf(ax.dot(Vector2(-ub.y, ub.x)))
		if absf(d.dot(ax)) > ra + rb:
			return false
	return true


static func _rect_obb(r: Rect2, pad := 0.0) -> Dictionary:
	var grown := r.grow(pad)
	return {"c": grown.get_center(), "e": grown.size * 0.5, "r": 0.0}


## Dining/work table: oak top on a dark apron base. Collides (walk around).
static func _f_table(b: MeshBatcher, pos: Vector3, owner_tag := "",
		floor_i := -1) -> void:
	b.add_destructible_box(pos + Vector3(0, 0.37, 0),
			Vector3(1.15, 0.74, 0.78), FURN_WOOD_DARK, &"wood", true,
			owner_tag, floor_i)
	b.add_visual_box(pos + Vector3(0, 0.755, 0),
			Vector3(1.25, 0.07, 0.88), FURN_WOOD)


static func _f_chair(b: MeshBatcher, pos: Vector3, yaw: float) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.23, 0),
			Vector3(0.44, 0.06, 0.42), basis, FURN_WOOD, false)
	b.add_box_rotated(pos - basis.z * 0.19 + Vector3(0, 0.51, 0),
			Vector3(0.44, 0.52, 0.05), basis, FURN_WOOD_DARK, false)


## Bookcase: walnut carcass (collides) with colored book rows on shelves.
static func _f_shelf(b: MeshBatcher, pos: Vector3, yaw: float,
		rng: RandomNumberGenerator, owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 1.0, 0),
			Vector3(SHELF_WIDTH, 2.0, SHELF_DEPTH), basis, FURN_WALNUT, true,
			false, &"wood", owner_tag, floor_i)
	for shelf_y in [0.55, 1.05, 1.55]:
		b.add_box_rotated(pos + Vector3(0, shelf_y, 0.02),
				Vector3(1.5, 0.04, 0.28), basis, FURN_WOOD, false)
		var cursor := -0.62
		while cursor < 0.58:
			var bw := rng.randf_range(0.07, 0.15)
			cursor += bw + 0.03
			if cursor > 0.62:
				break
			var bc: Color = FURN_BOOKS[rng.randi_range(
					0, FURN_BOOKS.size() - 1)]
			b.add_box_rotated(pos + basis.x * cursor + Vector3(0,
					shelf_y + 0.14, 0.02),
					Vector3(bw, 0.26, 0.22), basis, bc, false)


## Desk with keyboard, monitor stand and dark screen. VISUAL/COLLIDER
## AGREEMENT (P0-D): the destructible desk BODY shares its accessories'
## rotated basis - collider and visuals describe the same oriented footprint.
static func _f_desk_pc(b: MeshBatcher, pos: Vector3, yaw: float,
		owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.36, 0),
			Vector3(1.35, 0.72, 0.68), basis, FURN_DESK, true,
			false, &"wood", owner_tag, floor_i)
	b.add_box_rotated(pos + basis.z * 0.18 + Vector3(0, 0.79, 0),
			Vector3(0.42, 0.05, 0.16), basis, FURN_KEYBOARD, false)
	b.add_box_rotated(pos - basis.z * 0.16 + Vector3(0, 0.82, 0),
			Vector3(0.10, 0.16, 0.10), basis, FURN_METAL, false)
	b.add_box_rotated(pos - basis.z * 0.20 + Vector3(0, 1.06, 0),
			Vector3(0.58, 0.36, 0.04), basis, FURN_SCREEN, false)


## Bed: walnut frame (collides) with headboard AGAINST the wall - local
## X runs ALONG the wall, local -Z faces it (the _wall_snap_spot basis
## convention). Pale mattress, pillow at the head, blanket band across the
## foot half; all dressing shares the rotated basis.
static func _f_bed(b: MeshBatcher, pos: Vector3, yaw: float,
		owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.21, 0),
			Vector3(BED_ALONG, 0.42, BED_DEPTH), basis, FURN_WOOD_DARK,
			true, false, &"wood", owner_tag, floor_i)
	b.add_box_rotated(pos + Vector3(0, 0.50, 0),
			Vector3(BED_ALONG - 0.12, 0.16, BED_DEPTH - 0.18), basis,
			Color("cfc4b0"), false)
	b.add_box_rotated(pos - basis.z * (BED_DEPTH * 0.5 - 0.04)
			+ Vector3(0, 0.62, 0),
			Vector3(BED_ALONG, 0.82, 0.07), basis, FURN_WALNUT, false)
	b.add_box_rotated(pos - basis.z * (BED_DEPTH * 0.5 - 0.34)
			+ Vector3(0, 0.62, 0),
			Vector3(BED_ALONG - 0.34, 0.13, 0.52), basis,
			Color("ded8ca"), false)
	b.add_box_rotated(pos + basis.z * (BED_DEPTH * 0.5 - 0.62)
			+ Vector3(0, 0.60, 0),
			Vector3(BED_ALONG - 0.10, 0.10, 1.02), basis, FURN_LEAF_DARK,
			false)


## Shop counter: walnut carcass against the wall (collides), oak countertop
## with a slight overhang, dark register block toward one end. Same basis
## convention as _f_bed / _f_shelf.
static func _f_counter(b: MeshBatcher, pos: Vector3, yaw: float,
		owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.475, 0),
			Vector3(COUNTER_ALONG, 0.95, COUNTER_DEPTH), basis,
			FURN_WALNUT, true, false, &"wood", owner_tag, floor_i)
	b.add_box_rotated(pos + Vector3(0, 0.99, 0.03),
			Vector3(COUNTER_ALONG + 0.14, 0.06, COUNTER_DEPTH + 0.12),
			basis, FURN_WOOD, false)
	b.add_box_rotated(pos + basis.x * (COUNTER_ALONG * 0.5 - 0.38)
			+ Vector3(0, 1.17, 0.02),
			Vector3(0.38, 0.30, 0.30), basis, FURN_SCREEN, false)


## Terracotta pot with two-tone green foliage. Soft clutter (no collision).
static func _f_plant(b: MeshBatcher, pos: Vector3) -> void:
	b.add_visual_box(pos + Vector3(0, 0.17, 0),
			Vector3(0.30, 0.34, 0.30), FURN_POT)
	b.add_visual_box(pos + Vector3(0, 0.52, 0),
			Vector3(0.46, 0.30, 0.46), FURN_LEAF)
	b.add_visual_box(pos + Vector3(0, 0.76, 0),
			Vector3(0.30, 0.24, 0.30), FURN_LEAF_DARK)


# --- Roof --------------------------------------------------------------------

static func _roof(b: MeshBatcher, off: Vector3, fp: Rect2, style: Dictionary,
		roof_c: Color, wall_c: Color, total_h: float, zone: Rect2,
		has_stairs: bool, guard_on_east := true) -> void:
	var w := fp.size.x
	var d := fp.size.y
	# Parapet ring on top of the perimeter walls (standable edge, blocking).
	var ring := [
		[Vector3(w * 0.5, total_h + PARAPET_H * 0.5, WALL_T * 0.5),
				Vector3(w + 0.3, PARAPET_H, 0.28)],
		[Vector3(w * 0.5, total_h + PARAPET_H * 0.5, d - WALL_T * 0.5),
				Vector3(w + 0.3, PARAPET_H, 0.28)],
		[Vector3(WALL_T * 0.5, total_h + PARAPET_H * 0.5, d * 0.5),
				Vector3(0.28, PARAPET_H, d + 0.3)],
		[Vector3(w - WALL_T * 0.5, total_h + PARAPET_H * 0.5, d * 0.5),
				Vector3(0.28, PARAPET_H, d + 0.3)],
	]
	for r: Array in ring:
		b.add_destructible_box(off + r[0], r[1], wall_c.darkened(0.25),
				&"concrete")

	# Bulkhead around the stair shaft exit (roof access hut).
	if has_stairs:
		var bz := zone.grow(0.14)
		# Opening must clear the 1.7 m player capsule AND sit over the top
		# LANDING, not over the open shaft. The doorway faces the OPEN ROOM
		# side of the shaft (east or west - it follows the zone anchor), so
		# exiting always steps onto real deck, never off the building.
		var bh_h := 2.4
		var opening_h := 1.95
		var wy := total_h + bh_h * 0.5
		var gap_wall_x := bz.end.x if guard_on_east else bz.position.x
		var side_walls := [
			[Vector3(bz.get_center().x, wy, bz.position.y),
					Vector3(bz.size.x, bh_h, 0.22)],
			[Vector3(bz.get_center().x, wy, bz.end.y),
					Vector3(bz.size.x, bh_h, 0.22)],
			[Vector3(bz.position.x if guard_on_east else bz.end.x,
					wy, bz.get_center().y),
					Vector3(0.22, bh_h, bz.size.y)],
		]
		for wl: Array in side_walls:
			b.add_destructible_box(off + wl[0], wl[1], wall_c.darkened(0.15),
					&"concrete")
		# Doorway wall with gap + header, centered on the north landing.
		var gz := bz.position.y + 0.14 + LAND * 0.5   # landing center z
		var gap := 1.0
		var seg_lo := clampf(gz - gap * 0.5 - bz.position.y, 0.0, bz.size.y)
		var seg_hi := clampf(bz.end.y - (gz + gap * 0.5), 0.0, bz.size.y)
		if seg_lo > 0.05:
			b.add_destructible_box(
					off + Vector3(gap_wall_x, wy, bz.position.y + seg_lo * 0.5),
					Vector3(0.22, bh_h, seg_lo), wall_c.darkened(0.15),
					&"concrete")
		if seg_hi > 0.05:
			b.add_destructible_box(
					off + Vector3(gap_wall_x, wy, bz.end.y - seg_hi * 0.5),
					Vector3(0.22, bh_h, seg_hi), wall_c.darkened(0.15),
					&"concrete")
		b.add_destructible_box(
				off + Vector3(gap_wall_x, total_h + opening_h + 0.225, gz),
				Vector3(0.22, bh_h - opening_h, gap), wall_c.darkened(0.15),
				&"concrete")
		b.add_destructible_box(
				off + Vector3(bz.get_center().x, total_h + bh_h + 0.09,
						bz.get_center().y),
				Vector3(bz.size.x + BH_CAP_OVERHANG, 0.18,
						bz.size.y + BH_CAP_OVERHANG), ROOF_COLORS[0],
				&"wood")
		# Phase H: steel rim railing around the bulkhead cap. Reads as a
		# deliberate roof-exit landmark and hands the hut roof a grabbable lip
		# (one more parkour mantle to a fresh vantage). Every member sits ABOVE
		# the bulkhead wall top (total_h + bh_h), so the walk-through doorway
		# lane below stays geometrically untouched. Tagged "bhexit" for tests.
		var cap_top := total_h + bh_h + 0.18
		var ry := cap_top + BH_RAIL_H * 0.5
		var cx := bz.get_center().x
		var cz := bz.get_center().y
		var hw := bz.size.x * 0.5 + BH_CAP_OVERHANG * 0.5
		var hd := bz.size.y * 0.5 + BH_CAP_OVERHANG * 0.5
		var rim := [
			[Vector3(cx, ry, cz - hd + BH_RAIL_T * 0.5),
					Vector3(hw * 2.0, BH_RAIL_H, BH_RAIL_T)],
			[Vector3(cx, ry, cz + hd - BH_RAIL_T * 0.5),
					Vector3(hw * 2.0, BH_RAIL_H, BH_RAIL_T)],
			[Vector3(cx - hw + BH_RAIL_T * 0.5, ry, cz),
					Vector3(BH_RAIL_T, BH_RAIL_H,
							hd * 2.0 - 2.0 * BH_RAIL_T)],
			[Vector3(cx + hw - BH_RAIL_T * 0.5, ry, cz),
					Vector3(BH_RAIL_T, BH_RAIL_H,
							hd * 2.0 - 2.0 * BH_RAIL_T)],
		]
		for rl: Array in rim:
			b.add_destructible_box(off + rl[0], rl[1], RAIL_COLOR,
					&"steel", true, "bhexit", -1)
		# Phase I: serviced plant-room details on the bulkhead cap. A steel
		# access hatch lid + two galvanized vent louvers sit ON the cap
		# surface (cap_top), inside the Phase H railed enclosure, so the hut
		# roof reads as a real mechanical room rather than a bare lid. All
		# destructible steel (extra carveable cover + standable lips),
		# tagged "bhplant" for tests, deterministic, and gated to stair
		# buildings only (no plant details on plain flat decks).
		var plant_c := Color("9aa0a6")
		var hatch := [Vector3(cx + bz.size.x * 0.12,
				cap_top + 0.06, cz),
				Vector3(0.95, 0.12, 0.95)]
		b.add_destructible_box(off + hatch[0], hatch[1], plant_c,
				&"steel", true, "bhplant", -1)
		for vz: float in [cz - bz.size.y * 0.18, cz + bz.size.y * 0.18]:
			var vent := [Vector3(cx - bz.size.x * 0.25,
					cap_top + 0.125, vz),
					Vector3(0.5, 0.25, 0.16)]
			b.add_destructible_box(off + vent[0], vent[1], plant_c,
					&"steel", true, "bhplant", -1)
		# Phase J: rooftop access ladder from the deck up to the bulkhead
		# cap rim, so the serviced plant-room roof (Phase H rim + Phase I
		# hatch) is actually CLIMBABLE, not just a mantle target. A vertical
		# run of steel rungs on the hut's +Z face: bottom rung clears the
		# deck, top rung reaches the rim top so the player steps over onto
		# the cap. Destructible steel (grabbable parkour lip), deterministic,
		# gated to stair buildings, tagged "bhladder" for tests.
		var ladder_color := Color("6b6f73")
		var ladder_z := cz + hd - 0.05          # just inside the +Z rim face
		var ladder_y0 := total_h + 0.3          # first rung clears the deck
		var ladder_y1 := cap_top + BH_RAIL_H    # top rung at the rim top
		var n_rungs := maxi(int(round((ladder_y1 - ladder_y0) / 0.4)), 1)
		for ri: int in n_rungs:
			var lr := ladder_y0 + float(ri) * 0.4
			b.add_destructible_box(
				off + Vector3(cx, lr, ladder_z),
				Vector3(0.4, 0.06, 0.09), ladder_color,
				&"steel", true, "bhladder", -1)

	if style.get("attic", false):
		_pitched_shell(b, off, w, d, total_h, roof_c, style)
	else:
		# Flat roof variant: VISUAL membrane only. The walkable deck is the
		# top storey slab (already structural, with the shaft hole); a solid
		# cap here used to seal the stairwell shut below a 12 cm ceiling.
		if has_stairs:
			_membrane_with_hole(b, off, w, d, zone, total_h + 0.02, roof_c)
		else:
			b.add_roof_visual_box(off + Vector3(w * 0.5, total_h + 0.02, d * 0.5),
					Vector3(w - WALL_T, 0.04, d - WALL_T), roof_c)
		_roof_props(b, off, fp, style, total_h, zone, has_stairs)
		# Phase G: landmark rooftop water tower on the largest RETAIL flat
		# decks only - a tall standable steel tank on four legs, giving a
		# fresh elevated vantage and a tall ledge-grab lip. Skipped on
		# pitched (attic) roofs and on small/non-retail decks, and never
		# placed where it would block the stair bulkhead roof exit.
		if not style.get("attic", false) and is_retail_deck(style) \
				and (w * d) >= TOWER_MIN_AREA:
			_tower_landmark(b, off, usable_roof_rect(fp), total_h,
					keepout_roof(zone, has_stairs))


## Flat-roof dressing: thin VISUAL membrane around the shaft hole (no
## collision - the structural top slab below is the real deck). Lives on the
## RoofLayer so interiors can be revealed while the player is inside. Shares
## slab_pieces() with the structural slabs: same aperture, same four strips.
static func _membrane_with_hole(b: MeshBatcher, off: Vector3, w: float,
		d: float, hole: Rect2, y: float, color: Color) -> void:
	for r: Rect2 in slab_pieces(w, d, hole):
		b.add_roof_visual_box(
			off + Vector3(r.get_center().x, y, r.get_center().y),
			Vector3(r.size.x, 0.04, r.size.y), color)


## Phase G helpers: the landmark rooftop water tower is gated to the
## LARGEST RETAIL FLAT decks (no stairs, no pitched attic shell) so it reads
## as a district landmark rather than random clutter. These keep the gate
## readable and shared between `_roof` and the tests.
static func is_retail_deck(style: Dictionary) -> bool:
	return str(style.get("room_type", "residential")) == "retail"


## Parapet-inset walkable deck rect (matches `_roof_props` inset).
static func usable_roof_rect(fp: Rect2) -> Rect2:
	var inset := WALL_T + 0.55
	return Rect2(inset, inset,
			maxf(fp.size.x - 2.0 * inset, 0.0),
			maxf(fp.size.y - 2.0 * inset, 0.0))


## Bulkhead keep-out ring carried by the roof builder (empty when the
## building has no stair bulkhead). Towers never appear on stair buildings,
## but the rect is computed for completeness/testing.
static func keepout_roof(zone: Rect2, has_stairs: bool) -> Rect2:
	return zone.grow(BULKHEAD_RING + PROP_CLEARANCE) if has_stairs else Rect2()


## Phase G: landmark rooftop water tower. A tall standable steel tank on
## four legs placed on a large retail flat deck (NO stair bulkhead there),
## giving a fresh elevated vantage and a tall ledge-grab lip for the parkour
## system. Deterministic placement (seeded by the deck rect); legs + tank +
## cap are destructible steel (collide), ladder rungs up one leg double as a
## grabbable lip. All tower boxes carry owner_tag "tower" so tests can
## isolate them from the rest of the roof dressing.
static func _tower_landmark(b: MeshBatcher, off: Vector3, usable: Rect2,
		total_h: float, keepout: Rect2) -> void:
	if usable.size.x < TOWER_FOOTPRINT.x + 0.6 \
			or usable.size.y < TOWER_FOOTPRINT.y + 0.6:
		return
	var rng := WorldSeed.rng_for("tower",
		[int(usable.position.x * 13.0), int(usable.position.y * 13.0),
		 int(usable.size.x * 7.0)])
	var half := TOWER_FOOTPRINT * 0.5
	var cx := rng.randf_range(usable.position.x + half.x,
			maxf(usable.end.x - half.x, usable.position.x + half.x))
	var cz := rng.randf_range(usable.position.y + half.y,
			maxf(usable.end.y - half.y, usable.position.y + half.y))
	var foot := Rect2(cx - half.x, cz - half.y,
			TOWER_FOOTPRINT.x, TOWER_FOOTPRINT.y)
	if keepout.size.x > 0.0 and keepout.size.y > 0.0 \
			and foot.intersects(keepout):
		return
	var y := total_h + 0.04
	var leg_h := 2.6
	var tank_h := 1.8
	var tank_r := 0.85
	# Four legs at the footprint corners (steel, collides/standable base).
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var lx: float = cx + sx * (TOWER_FOOTPRINT.x * 0.5 - 0.18)
			var lz: float = cz + sz * (TOWER_FOOTPRINT.y * 0.5 - 0.18)
			b.add_destructible_box(off + Vector3(lx, y + leg_h * 0.5, lz),
					Vector3(0.16, leg_h, 0.16), Color("7c8288"),
					&"steel", true, "tower", -1)
	# Cylindrical tank faked as a steel box + a slightly wider rim cap.
	var tank_base := y + leg_h
	b.add_destructible_box(off + Vector3(cx, tank_base + tank_h * 0.5, cz),
			Vector3(tank_r * 2.0, tank_h, tank_r * 2.0),
			Color("3e5a6e"), &"steel", true, "tower", -1)
	b.add_destructible_box(off + Vector3(cx, tank_base + tank_h + 0.06, cz),
			Vector3(tank_r * 2.0 + 0.1, 0.12, tank_r * 2.0 + 0.1),
			Color("2f4250"), &"steel", true, "tower", -1)
	# Ladder rungs climbing one leg - a fresh ledge-grab lip to the top.
	for i in 5:
		var ry := y + 0.4 + float(i) * 0.5
		b.add_destructible_box(
				off + Vector3(cx + TOWER_FOOTPRINT.x * 0.5 - 0.18,
						ry, cz + TOWER_FOOTPRINT.y * 0.5 - 0.18),
				Vector3(0.06, 0.06, 0.4), Color("565d63"),
				&"steel", true, "tower", -1)



## Flat-roof prop dressing (Phase D slice 4/5/6): AC condensers, a water
## tank, vent pipes and an antenna mast scattered over the walkable roof
## deck. Phase D slice 5 adds ROOF-TYPE VARIETY: retail roofs get BILLBOARDS
## (tall vertical ad panels), residential roofs get LAUNDRY LINES (horizontal
## cables with struts) and PIGEON COOPS (small wooden hutches). Phase D
## slice 6 adds CLUTTER: one linear HVAC duct run lining a parapet-side edge,
## SOLAR THERMAL PANELS (tilted dark glass, residential) and SATELLITE DISHES
## (retail). Props are
## DESTRUCTIBLE boxes - standable cover that doubles as fresh ledge-grab
## lips for the Phase E parkour system. Placement is deterministic
## (WorldSeed.rng_for, same pattern as the chimney), confined to the deck
## area inset from the parapet line, and keeps a clear approach ring around
## the stair bulkhead so the roof exit never gets blocked - the ring itself
## carries PROP_CLEARANCE so no prop footprint ever sits flush against the
## roof-exit lane boundary (Phase F). Pitched roofs
## carry no walkable deck and skip dressing entirely.
static func _roof_props(b: MeshBatcher, off: Vector3, fp: Rect2,
		style: Dictionary, total_h: float, zone: Rect2, has_stairs: bool) -> void:
	var w := fp.size.x
	var d := fp.size.y
	var inset := WALL_T + 0.55   # clear of the parapet inner face
	var usable := Rect2(inset, inset,
			maxf(w - 2.0 * inset, 0.0), maxf(d - 2.0 * inset, 0.0))
	if usable.size.x < 1.4 or usable.size.y < 1.4:
		return   # deck too small to dress safely
	# Phase F: the bulkhead approach ring carries PROP_CLEARANCE on top of
	# BULKHEAD_RING, so prop footprints (scatter AND the HVAC duct run) keep
	# a 0.35 m gap from the ring boundary instead of stopping flush against
	# the roof-exit lane.
	var keepout := zone.grow(BULKHEAD_RING + PROP_CLEARANCE) \
			if has_stairs else Rect2()
	var rng := WorldSeed.rng_for("roofprops",
			[int(style["wall"]), int(style["roof"]), int(round(d * 10))])
	var budget := mini(int(usable.get_area() / 18.0), 4)
	var target := 1 + rng.randi_range(0, maxi(budget - 1, 0))
	var placed: Array[Dictionary] = []
	# Phase D slice 6: one linear HVAC duct run lining a parapet-side edge
	# (a ready-made perimeter parkour lip), placed before the scatter so it
	# claims deck space ahead of the freestanding props.
	var duct_r := _hvac_rect(usable, keepout, rng)
	if duct_r.size.x > 0.0 and duct_r.size.y > 0.0:
		placed.append(_rect_obb(duct_r, PROP_CLEARANCE))
		_rp_hvac_duct(b, off, duct_r, total_h + 0.04)
	var attempts := 0
	var room_type := str(style.get("room_type", "residential"))
	var is_retail := room_type == "retail"
	while placed.size() < target and attempts < 40:
		attempts += 1
		# kind pool filtered by room_type (Phase D slices 5/6):
		#   shared 0-4 | retail-only 7 (satellite dish) |
		#   residential-only 5 (pigeon coop) + 6 (solar panel);
		#   kind 4 morphs: billboard (retail) / laundry line (residential)
		var kinds: Array[int] = []
		for k in 8:
			if k == 7:
				if is_retail:
					kinds.append(k)
			elif k == 5 or k == 6:
				if not is_retail:
					kinds.append(k)
			else:
				kinds.append(k)
		var kind: int = kinds[rng.randi_range(0, kinds.size() - 1)]
		var footprint := Vector2(0.95, 0.75)      # AC condenser
		if kind == 1:
			footprint = Vector2(1.25, 1.25)       # water tank
		elif kind == 2:
			footprint = Vector2(0.55, 0.55)       # vent cluster
		elif kind == 3:
			footprint = Vector2(0.35, 0.35)       # antenna base
		elif kind == 4:
			footprint = Vector2(2.0, 0.3)         # billboard (retail) / laundry line (residential)
		elif kind == 5:
			footprint = Vector2(1.1, 1.1)         # pigeon coop (residential only)
		elif kind == 6:
			footprint = Vector2(1.9, 1.05)        # solar thermal panel (residential only)
		elif kind == 7:
			footprint = Vector2(0.75, 0.75)       # satellite dish (retail only)
		var px := rng.randf_range(usable.position.x,
				maxf(usable.end.x - footprint.x, usable.position.x))
		var pz := rng.randf_range(usable.position.y,
				maxf(usable.end.y - footprint.y, usable.position.y))
		var r := Rect2(px, pz, footprint.x, footprint.y)
		if keepout.size.x > 0.0 and keepout.size.y > 0.0 \
				and r.intersects(keepout):
			continue
		var obb := _rect_obb(r, PROP_CLEARANCE)
		var clash := false
		for o in placed:
			if _obb_overlap(obb, o):
				clash = true
				break
		if clash:
			continue
		placed.append(obb)
		var y := total_h + 0.04   # on top of the membrane
		match kind:
			0: _rp_ac_unit(b, off, r, y)
			1: _rp_water_tank(b, off, r, y)
			2: _rp_vents(b, off, r, y)
			3: _rp_antenna(b, off, r, y)
			4: _rp_billboard_or_laundry(b, off, r, y, is_retail)
			5: _rp_pigeon_coop(b, off, r, y)
			6: _rp_solar_panel(b, off, r, y)
			7: _rp_satellite_dish(b, off, r, y)


static func _rp_ac_unit(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 0.42, c.y),
			Vector3(r.size.x, 0.84, r.size.y), Color("b8bcc2"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 0.90, c.y),
			Vector3(r.size.x * 0.7, 0.12, r.size.y * 0.7),
			Color("6f767c"), &"steel")


static func _rp_water_tank(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 0.14, c.y),
			Vector3(r.size.x * 0.8, 0.28, r.size.y * 0.8), PLINTH_COLOR,
			&"concrete")
	b.add_destructible_box(off + Vector3(c.x, y + 0.98, c.y),
			Vector3(r.size.x, 1.4, r.size.y), Color("3e5a6e"), &"steel")


static func _rp_vents(b: MeshBatcher, off: Vector3, r: Rect2, y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x - 0.12, y + 0.45, c.y - 0.10),
			Vector3(0.24, 0.9, 0.24), PLINTH_COLOR.darkened(0.15), &"concrete")
	b.add_destructible_box(off + Vector3(c.x + 0.13, y + 0.32, c.y + 0.12),
			Vector3(0.20, 0.64, 0.20), PLINTH_COLOR.darkened(0.15), &"concrete")


static func _rp_antenna(b: MeshBatcher, off: Vector3, r: Rect2, y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 1.15, c.y),
			Vector3(0.12, 2.3, 0.12), Color("565d63"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 1.95, c.y),
			Vector3(0.90, 0.07, 0.07), Color("565d63"), &"steel")


## Retail billboard OR residential laundry line (Phase D slice 5).
## Single function avoids duplication: both are vertical posts with a
## cross member. Retail = tall ad panel (steel frame + dark face).
## Residential = laundry line (two posts + horizontal cables + struts).
static func _rp_billboard_or_laundry(b: MeshBatcher, off: Vector3,
		r: Rect2, y: float, is_retail: bool) -> void:
	var c := r.get_center()
	var w := r.size.x
	var d := r.size.y
	if is_retail:
		# BILLBOARD: steel I-beam posts + large dark ad panel.
		# Posts at the long edges, panel spans between them.
		b.add_destructible_box(off + Vector3(c.x - w * 0.5 + 0.15, y + 4.5, c.y),
				Vector3(0.3, 9.0, d), Color("3a3f44"), &"steel")
		b.add_destructible_box(off + Vector3(c.x + w * 0.5 - 0.15, y + 4.5, c.y),
				Vector3(0.3, 9.0, d), Color("3a3f44"), &"steel")
		b.add_destructible_box(off + Vector3(c.x, y + 4.5, c.y),
				Vector3(w - 0.6, 8.5, 0.15), Color("1a1a20"), &"wood")
		# Small ladder rung on one post (visual ledge-grab lip).
		b.add_destructible_box(off + Vector3(c.x - w * 0.5 + 0.15, y + 0.5, c.y + d * 0.5 + 0.1),
				Vector3(0.08, 0.08, 0.3), Color("3a3f44"), &"steel")
	else:
		# LAUNDRY LINE: two wooden posts with horizontal cables.
		var post_h := 2.2
		b.add_destructible_box(off + Vector3(c.x - w * 0.5 + 0.1, y + post_h * 0.5, c.y),
				Vector3(0.12, post_h, 0.12), FURN_WOOD_DARK, &"wood")
		b.add_destructible_box(off + Vector3(c.x + w * 0.5 - 0.1, y + post_h * 0.5, c.y),
				Vector3(0.12, post_h, 0.12), FURN_WOOD_DARK, &"wood")
		# 3 cable strands (visual only, no collision needed - posts are the cover).
		for i in 3:
			var ch := y + 0.5 + float(i) * 0.55
			b.add_visual_box(off + Vector3(c.x, ch, c.y),
					Vector3(w - 0.3, 0.02, d), Color("cfc4b0"))


## Pigeon coop (residential only, Phase D slice 5).
## Small wooden hutch with slatted front and a perching ledge.
## Destructible - standable cover + ledge-grab lip.
static func _rp_pigeon_coop(b: MeshBatcher, off: Vector3, r: Rect2, y: float) -> void:
	var c := r.get_center()
	var w := r.size.x
	var d := r.size.y
	var h := 1.3
	# Main box (hutch body).
	b.add_destructible_box(off + Vector3(c.x, y + h * 0.5, c.y),
			Vector3(w * 0.9, h, d * 0.9), FURN_WOOD_DARK, &"wood")
	# Slatted front face (visual).
	b.add_visual_box(off + Vector3(c.x, y + h * 0.5, c.y + d * 0.5),
			Vector3(w * 0.85, h * 0.8, 0.06), FURN_WOOD)
	# Perching ledge on top (standable + ledge-grab).
	b.add_destructible_box(off + Vector3(c.x, y + h + 0.08, c.y),
			Vector3(w, 0.16, d), FURN_WOOD, &"wood")
	# Entry hole (visual only).
	b.add_visual_box(off + Vector3(c.x, y + h * 0.6, c.y + d * 0.5),
			Vector3(0.3, 0.3, 0.06), Color("1a1a20"))


## Phase D slice 6: pick the rect for an HVAC duct run hugging one side of
## the usable deck (the parapet walkway line). Tries the four edges in a
## seeded shuffled order; returns Rect2() when no edge clears the bulkhead
## keep-out ring.
static func _hvac_rect(usable: Rect2, keepout: Rect2,
		rng: RandomNumberGenerator) -> Rect2:
	var th := 0.42
	var margin := 0.5
	var order: Array[int] = [0, 1, 2, 3]
	for i in range(3, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	for e: int in order:
		var r := Rect2()
		if e == 0 or e == 1:
			var avail_x := usable.size.x - 2.0 * margin
			if avail_x < 1.8:
				continue
			var len_x := minf(avail_x, rng.randf_range(2.4, 4.2))
			var x0 := usable.position.x + margin \
					+ rng.randf_range(0.0, maxf(avail_x - len_x, 0.0))
			if e == 0:
				r = Rect2(x0, usable.position.y, len_x, th)
			else:
				r = Rect2(x0, usable.end.y - th, len_x, th)
		else:
			var avail_z := usable.size.y - 2.0 * margin
			if avail_z < 1.8:
				continue
			var len_z := minf(avail_z, rng.randf_range(2.4, 4.2))
			var z0 := usable.position.y + margin \
					+ rng.randf_range(0.0, maxf(avail_z - len_z, 0.0))
			if e == 2:
				r = Rect2(usable.position.x, z0, th, len_z)
			else:
				r = Rect2(usable.end.x - th, z0, th, len_z)
		if keepout.size.x > 0.0 and keepout.size.y > 0.0 \
				and r.intersects(keepout):
			continue
		return r
	return Rect2()


## HVAC duct run (Phase D slice 6): linear galvanized chase on low steel
## stands lining the parapet walkway. Destructible - standable cover and a
## perimeter ledge-grab lip for Phase E parkour routes.
## HVAC duct run (Phase D slice 6): linear galvanized chase on low steel
## stands lining the parapet walkway. Destructible - standable cover and a
## perimeter ledge-grab lip for Phase E parkour routes.
static func _rp_hvac_duct(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	var horizontal: bool = r.size.x >= r.size.y
	var stand_h := 0.32
	for i in 3:
		var t := (float(i) + 0.5) / 3.0
		var px := lerpf(r.position.x + 0.25, r.end.x - 0.25, t)
		var pz := lerpf(r.position.y + 0.25, r.end.y - 0.25, t)
		if horizontal:
			pz = c.y
		else:
			px = c.x
		b.add_destructible_box(off + Vector3(px, y + stand_h * 0.5, pz),
			Vector3(0.14, stand_h, 0.14), Color("7c8288"), &"steel")
	var duct_y := y + stand_h + 0.19
	b.add_destructible_box(off + Vector3(c.x, duct_y, c.y),
		Vector3(r.size.x, 0.38, r.size.y), Color("aab0b6"), &"steel")
	for i in 2:
		var t := (float(i) + 1.0) / 3.0
		var rx := lerpf(r.position.x, r.end.x, t)
		var rz := lerpf(r.position.y, r.end.y, t)
		if horizontal:
			rz = c.y
		else:
			rx = c.x
		var rs := Vector3(0.07, 0.05, 0.52)
		if not horizontal:
			rs = Vector3(0.52, 0.05, 0.07)
		b.add_visual_box(off + Vector3(rx, duct_y + 0.21, rz), rs,
			Color("8f959b"))


## Solar thermal panel (residential, Phase D slice 6): dark glass absorber
## on two steel legs - a tall rear rail and short front rail fake the tilt.
## The absorber slab is DESTRUCTIBLE and standable (low ledge-grab lip).
## Phase E: rear leg lip height raised to ≥0.9m for parkour compatibility.
static func _rp_solar_panel(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	var w := r.size.x
	var d := r.size.y
	b.add_destructible_box(
			off + Vector3(c.x, y + 0.30, c.y - d * 0.5 + 0.15),
		Vector3(w * 0.9, 0.60, 0.12), Color("565d63"), &"steel")
	b.add_destructible_box(
			off + Vector3(c.x, y + 0.14, c.y + d * 0.5 - 0.15),
		Vector3(w * 0.9, 0.26, 0.12), Color("565d63"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 0.48, c.y),
		Vector3(w, 0.08, d), Color("101820"), &"glass")


## Satellite dish (retail corners, Phase D slice 6): concrete footplate +
## steel pedestal + two stacked plates faking a concave bowl + feed arm.
## All DESTRUCTIBLE; the pedestal top is a fresh ledge-grab lip.
static func _rp_satellite_dish(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 0.07, c.y),
			Vector3(r.size.x * 0.85, 0.14, r.size.y * 0.85),
			PLINTH_COLOR, &"concrete")
	b.add_destructible_box(off + Vector3(c.x, y + 0.55, c.y),
			Vector3(0.12, 0.96, 0.12), Color("565d63"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 1.02, c.y - 0.10),
			Vector3(0.66, 0.34, 0.10), Color("c8ccd0"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 1.24, c.y + 0.06),
			Vector3(0.46, 0.24, 0.10), Color("b4b9be"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 1.18, c.y - 0.26),
			Vector3(0.05, 0.05, 0.34), Color("565d63"), &"steel")


static func _pitched_shell(b: MeshBatcher, off: Vector3, w: float, d: float,
		total_h: float, roof_c: Color, style: Dictionary) -> void:
	var eave := 0.28
	var half_run := d * 0.5 + eave
	var rise := minf(2.4, d * 0.42)
	var ang := atan2(rise, half_run)
	var slope_len := sqrt(half_run * half_run + rise * rise)
	var cy := total_h + rise * 0.5
	# Roof shells are VISUAL RoofLayer geometry: players walk the structural
	# deck beneath them, and the whole shell hides away indoors.
	b.add_roof_visual_box(
			off + Vector3(w * 0.5, cy, d * 0.25 - eave * 0.5 + 0.0),
			Vector3(w + 0.55, 0.18, slope_len), roof_c)
	b.add_roof_visual_box(
			off + Vector3(w * 0.5, cy, d * 0.75 + eave * 0.5),
			Vector3(w + 0.55, 0.18, slope_len), roof_c)

	# Dormer(s) punching through the south slope.
	if style.get("balcony", false):
		return   # stylistic variety: some roofs stay plain
	var dz := d * 0.78
	var dx := w * 0.32
	b.add_roof_visual_box(off + Vector3(dx, total_h + rise * 0.45, dz),
			Vector3(1.1, 1.1, 1.0), PLINTH_COLOR)
	b.add_roof_visual_box(off + Vector3(dx, total_h + rise * 0.45 + 0.61, dz + 0.1),
			Vector3(1.3, 0.12, 1.2), roof_c)
	b.add_roof_visual_box(off + Vector3(dx, total_h + rise * 0.45, dz + 0.48),
			Vector3(0.7, 0.8, 0.12), WINDOW_COLOR)
	# Chimney on the ridge (seeded by style for stable placement).
	var rng_pos := WorldSeed.rng_for("chimney",
			[int(style["wall"]), int(style["roof"]), int(round(d * 10))])
	var ch_x := lerpf(w * 0.25, w * 0.75, rng_pos.randf())
	b.add_roof_visual_box(off + Vector3(ch_x, total_h + rise * 0.55 + 0.75,
					d * 0.5),
			Vector3(0.65, 1.5, 0.65), PLINTH_COLOR.darkened(0.2))
