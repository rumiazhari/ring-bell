# Ring Bell — Rural Port M1 Spec — City Grammar → Rural Structural Parity
**Date:** 2026-09-01
**Worktree:** C:/Vibe Code project/Godot Project/ring-bell-front-end-recovery (front-end-recovery-20260831)
**Base HEAD:** 6f704b8 (feat G9-M3 society worker) — recovery worktree behind origin/master (rural port commits e399bde..b256287 exist on canonical/master already, proven 0-fail with 720/420 budgets)
**City reference commit:** b256287 on canonical — BuildingBuilder 3386 lines, art/rural_art.gd 564 lines, rural_building_plan 1688 delta
**Protect:** C:/Vibe Code project/Godot Project/ring-bell (canonical) is read-only reference; never edit, reset, or force-update
**Author:** Architect (GPT-5.6 Luna frontier reasoning, ultra) — inspected actual repo, not assumed

## 1. City Pipeline — Actual Reference (source of truth, Ox Alpha / GLM 5.3-Flash)

### 1.1 Manifest & Footprint (city_plan.gd)
- Hierarchical macro plan: districts (128m) → street grid (GRID_BASE_SPACING 88 ±18, avenues) → urban blocks → plazas → perimeter parcels with EXPLICIT CORNER OWNERSHIP (four corner lots first, edge rows subdivide frontage between them). No overlaps, validated by validate_buildings().
- BuildingSpec dict: `id: "b_<cell>_<edge><k>"`, `rect: Rect2 XZ` (world coords), `floors: int` storeys, `floor_h: float`, `door_edge: 0=N/1=E/2=S/3=W` street-facing, `style: {wall, roof, balcony, attic}`, `doors: Array` door manifests, `district`, `use` (residential/retail). Footprint realistic for several rooms per floor.
- Queries: `buildings_in_rect(rect)`, `buildings_in(rect)`, `building_by_id(id)`, `cells_in_rect`, `cell_block(cell)`. Thread-unsafe Dictionary caches per instance → workers use private CityPlan copy; plan_mutex guards in ChunkManager. Pure functions of seed+coords, order-independent.

### 1.2 Floor & Vertical Datums (BuildingBuilder)
- Local frame: origin = spec.rect.position, X east, Rect2.y = Z south, heights Y. Ground top surface y=0.
- Constants: `WALL_T 0.35`, `SLAB_T 0.22`, `LANE_W 1.25`, `LAND 1.25`, `PITCH_DEG 34.0`, `RAMP_T 0.22`, `RAMP_OVERLAP 0.2`, `DOOR_W 1.5`, `DOOR_H 2.25`, `WIN_W 1.15`, `WIN_H 1.35`, `WIN_SILL 0.85`, `PARAPET_H 0.9`.
- Ground slab: STRUCTURAL `add_structural_box` at `Vector3(w*0.5, -SLAB_T*0.5 -0.02, d*0.5)` size `Vector3(w, SLAB_T, d)` below grade so doorway has no 22cm lip. Visual floor finish thin box `0.02` at `y=0.01` inset `WALL_T`.
- Storey slabs lvl 1..n at `lvl*fh`: tagged `f<lvl>` is CEILING of storey lvl-1; `_slab_with_hole` cuts stairwell shaft through EVERY intermediate slab including collision. Layers `push_layer(tag+":f<lvl>")` let ChunkManager.hide storeys above player.
- Roofs: pitched shell, parapet, bulkhead, chimneys, balconies, awnings — all deterministic via `WorldSeed.rng_for("balcony", [hash(tag), f, side])` etc.

### 1.3 Wall Segments Around Openings
- `_storey_walls(b, off, w,d, y0, fh, col, floor_i, door_edge, tag, is_historic)` loops 4 facades, pushes layer `"<tag>:f<storey>:<N/E/S/W>"` then calls `_facade_with_openings`.
- `_facade_with_openings` is aperture composition: every opening (entrance door on ground floor door_edge side + windows on all sides) is carved by SAME generator: piers stand between openings, sill band closes window below, structural lintel closes opening above, panes centered INSIDE empty gaps. Nothing solid behind glass; after shattering aperture genuinely open.
- Destruction granularity: piers stacked ~1m tall modules (CELL_H) via `add_destructible_box(..., "wall"/"concrete"/"steel", true, "balcony"/"wall", -1)` each its own integrity record, so blasts carve courses not whole segment.
- Historic dressing phases (K,L,O,P,Q,R,U,W,X,Y,Z,AA,AB,AC,AD,AE,AF,AG,AH,AI) are visual-only boxes pressed 0.02 outside wall face, gated to historic+long facade, never touching collision.

### 1.4 Openings — Doors/Windows/Frames/Thresholds
- Doors: builder emits WALL OPENING only (segments + lintel). Movable leaf is dynamic `Door` entity spawned by `ChunkBuilder.build()` from `spec.doors` manifests produced by CityPlan — never baked into static mesh. Door leaf closed blocks without RID exclusion, open clears swung leaf collidable; ChunkManager respects `dead_doors`.
- Windows: `WIN_W/WIN_H/WIN_SILL/WIN_SPACING/GLASS_T 0.2` pane inside `WALL_T` aperture, centered. Historic stone trim: lintel `AB`, sill `AC`, jambs, keystone `AE`, corbels `AF`, plus shutters `Z`, flower boxes `AA`, drainpipes `Y`. All visual-only, structural wall remains piers/lintels.
- Threshold: ground slab below grade; door wall pieces + lintel frame opening; no floating walls. Door state changes never delete structural collision (wall segments remain, leaf toggles).

### 1.5 Floors/Ceilings/Roofs/Stairs/Rooms
- Rooms: interior partitions via `InteriorPlan.build_for_building(spec)` — 3-4 rooms (entry/kitchen/sleeping/toilet) per residential ground floor, partitions `0.18` + opening `0.95`, furniture anchors bed/shelf/table + stations bed/counter via `_furnish` batched vertex-colored, ACTIVE-only.
- Stairs: switchback staircase with walkable ramp colliders + decorative treads, target 30-35deg, ramps overlap landings by `RAMP_OVERLAP` so no step at seam, shaft holes through slabs, guard rails `RAIL_SETBACK 0.6`.

### 1.6 Furniture Anchors & Interior Placement
- Furniture via `_furnish` from deterministic zone rect; placement wall-relative, clear of doorway 1.0, gap 0.9, cardinal. Varies by `style.room_type`. Budgets: city interior `320/240 per chunk additive to 1500/2480 typ`.

### 1.7 Visual Mesh Batching
- `MeshBatcher` collects `(box,color,collide,material,integrity,layer)` tuples during `BuildingBuilder.build`, then `flush_into(chunk, 1, include_collision)` merges to ONE vertex-colored ArrayMesh + one StaticBody3D per chunk (ACTIVE-only). Layers enable floor-gate fading per building/storey/side.

### 1.8 Structural Collision
- Policy in BuildingBuilder header: STRUCTURAL = every wall segment incl door-wall pieces + lintels, ground slab, all storey slabs, stair ramps+landings, guard rails, parapets, bulkhead, chimneys, flat-roof caps. VISUAL ONLY = windows, signboards, shopfront panels, treads, pitched shells, dressing.
- `add_structural_box` vs `add_visual_box` vs `add_destructible_box(..., collide=true/false)`. Door openings: piers+lintel are structural, glass is visual, leaf is dynamic. Visual/collision openings correspond.

### 1.9 Streaming/Materialization Ownership
- `ChunkBuilder.fill_batcher(b, plan, coord)` pure data (worker thread, private CityPlan copy). `ChunkBuilder.build(parent, plan, coord, batcher, dead_doors)` main thread only, creates `Chunk_<x>_<z>` Node3D, flushes mesh, spawns Door/DestructibleProp/OmniLight nodes once.
- Building owned by chunk containing its footprint CENTER (Rect2.get_center()) so streaming never duplicates/tears; whole subtree under owner.
- Cross-chunk decoration anchored to GLOBAL grid steps (DASH_STEP 7.0, LAMP_STEP 22.0) not chunk-local.

### 1.10 Determinism & Budgets
- Seed: `WorldSeed.GENERATOR_VERSION 2`, `sample_coherent(p, domain, cell_size, seed)` via splitmix, domain-separated (`district`, `gap0/1`, `width0/1`, `avenue0/1`, `blockkind`, `interior`, `balcony`, `awning` ... handles negative coords via floori). Every scatter via `rng_for`.
- Budgets: city 1 mesh+1 body per chunk, terrain 289/512 1 collider, water 81/128 1, biome 81/128 1 + MultiMesh 48, road 96/64 typ 160/96 jun 1, rural 720/420 dense 360/280 typ 1 shell+well collider (verified: unified 54 peak = 9 city+9 terrain+9 water+9 biome+9 road+9 rural; warm visuals retained but collision disabled). FRAME_BUDGET_MS 12, MAX_MATERIALIZATIONS_PER_FRAME 1 + early _collect_finished_jobs(pc) + freed-Zombie guard (`is_instance_valid` + `!is_queued_for_deletion()` + `is_inside_tree()` before global_transform).

## 2. Existing Rural — Batched-Mesh Baseline (food for port)

- `RuralBuildingPlan` (P4.2/P4.3/P5.1): deterministic 1-6 per settlement (village 4-6, hamlet 2-3, farmstead 1-2, isolated 1), spaced ≥8m, road setback 4m, cardinal yaw via `nearest_road_tangent` quantized to 90°, footprints 6-10×8-14 (village 8-10×10-12, barn 8-10×10-14), height 4.2+2.9*floors, plaster/brick/timber colors, roof 8a3a2a/5a5a5a, door facing road/settlement, no building in floodplain/water/cliff/urban 350 except gate barn, slope <14 village_house else <22, distance_to_water >BANK_W+2. Interior partition 0-1 wall 0.15 thick inset 0.5 gap 0.95 + 1-3 furniture proxies + FoodCrate + Well + Forage + Hearth + Workbench + Granary — all batched vertex-colored, 1 shell+well Concave/chunk, Area3D ACTIVE-only.
- Baseline rural materialization was house-shaped batched mesh (box shell + roof box) not walls-around-openings. No per-window wall sections, no lintel/sill grammar, no floor slab per storey; door opening not split into piers+lintel with collidable lintel; windows façade quads only; roofs as single boxes; furniture anchors exterior-clutter risk if not datum-grounded.

## 3. Rural Port — Bounded Milestone M1: Structural Parity

**Goal:** Replace rural “house-shaped batched mesh” with structurally composed rural buildings wherever appropriate, reusing city principles via safe helpers, retaining rural ownership of planning/composition.

### 3.1 Building Manifest (rural_building_plan.gd)
- Extend manifest fields per building dict: `id`, `center: Vector2`, `footprint: Vector2`, `yaw: float cardinal`, `ground_y: float = WorldPlan.surface_height_at(center)+RURAL_OVERLAY_LIFT_M (0.04)`, `height: float = 4.2 + (floors-1)*2.9`, `floors: int` (1 default, villages 1-2 where plan calls via deterministic roll 0.5 threshold), `floor_h: float = 2.9` for two-storey else 4.2/ single, `building_datum: float = ground_y`, `wall_sections: Array` descriptors (not persisted as geometry, but manifest must support wall composition), `door_opening: Dictionary {pos, yaw, width 1.0 (1.2 barn/stable), height 2.1 (2.2 barn/stable), hinge, edge}`, `window_openings: Array` per floor/side (village_house/cottage/farmhouse: windows on 4 sides, per-floor for 2-storey; barn/stable: loft vent or limited), `floor_descs: Array` per floor datum `ground_y + f*floor_h`, `roof_desc: Dictionary {kind: gable/flat, ridge_y, color}`, `furniture_anchors: Array` deterministic interior anchors with room awareness, `building_kind` deterministic variation (village_house/cottage/barn/farmhouse/stable/shed via existing _choose_building_kind), `palettes` deterministic via seed.
- Retain rural ownership: planning stays in RuralBuildingPlan, no CityPlan import. Low-level helpers from BuildingBuilder may be reused if safe (wall segment math, lintel calc) but via duplication/adaptation in RuralArt, not by importing city generator whole.

### 3.2 Structural Walls
- Walls made from real sections around openings: split walls on door side into two piers (left/right of opening) plus lintel box spanning above opening; window sides similarly pier + sill band + lintel. Thick recessed openings (wall thickness 0.18-0.35 depending on rural scale) not decorative façade quads.
- Grounding: all wall bases at `ground_y` (surface_authority), no floating. Upper-floor walls stacked at `ground_y + floor_h*level`, gable walls triangularly capped. No floating roofs/furniture/thresholds; plinth base 0-0.38 if historic variant, else flush.
- Roof relationships: gabled roof ridge at `total_h + 1.2`, fascia, ridge cap, tile bands visual-only but roof col `8a3a2a`/`5a5a5a`, correctly sitting on top plate.

### 3.3 Doors & Windows
- Doors remain separate interactive `Door` nodes (rural_door_manifest) spawned by RuralBuildingChunkBuilder — visual wall opening (piers+lintel) is in static mesh, leaf is dynamic. Closed leaf blocks without RID exclusion (raycast), open leaf clears swung position collidable. Window openings: aperture with frame/shutter/trim dark interior plane aligned structurally; glass visual-only inside aperture.
- Visual openings must correspond to collision openings: collision mesh includes wall piers+lintel but not glass; opening void is empty. Door state changes toggle leaf collider only, never delete wall structural collision.

### 3.4 Floors & Furniture
- Floors: explicit slab at `ground_y` (structural 0.22 below grade + visual finish 0.02) and per intermediate floor slab at `ground_y + lvl*floor_h` with same below-grade trick. Furniture placed from deterministic anchors using wall-relative candidates (e.g., 5 candidates: corners + center) filtered by door clearance 1.45, partition clearance 0.65, spacing 0.9, staying within `footprint inset 0.75`. Must remain within geometry/budget.
- Furniture varies: cottage/house 2-3 (bed/shelf/table/stove), barn/stable 1-2 (shelf/table) but never uninhabited house; fallback guarantees at least 1 table.

### 3.5 Rural Variants
- Cottages/houses: footprint 7-9×8-11, height 4.2 single, timber/plaster walls, roof red clay, windows on 4 sides per floor.
- Larger village houses: 8-10×10-12, 1-2 floors (two-storey extra 2.9), floor slab + per-floor windows (upper floor windows at `ground_y + floor_h + WIN_SILL`), interior partition 0.15 with gap 0.95.
- Barns: 8-10×10-14, height 4.2+extra, timber/brick, roof grey or red, loft vent window or single large opening, large door 1.2×2.2.
- Stables: similar barns but stable door, loft vent.
- Farmstead outbuildings: sheds 6-8×8-10 small, 1 floor.

### 3.6 Settlement Dressing (M1 minimal but present)
- Yards: coherent property discs radius 7 hamlet /10 village at settlement center, color 71814d, grounded 0.01, 8-sided approx.
- Paths: connect buildings, doors, gates, wells, shared spaces — main cart path 2.8/2.4 width between settlement center and nearest road projection, foot paths 1.55/1.35 between buildings/door→path and building→building, segmented quads at terrain+0.035, colors 8b7656/a08a68, clipped to settlement rect via _clip_segment_to_rect, no duplication across chunks (center ownership of buildings ensures path ownership via settlement).
- Fences: deterministic boundary polylines or planned segments along yard edges, posts 0.18×1.2 + caps 0.22×0.05 at 2.2 spacing, rails 0.08×0.08 between posts, height 1.05-1.30 jitter, colors 6b4b32/89633f, continuous readable boundaries, gate gap 1.35 where path crosses fence line (deterministic via gate polylines, align with paths/door approaches).
- Posts/rails form continuous boundaries; gates align with paths.
- Trees: deterministic, surface-authoritative, placed with building/path/door avoidance (min spacing 4.5, road 5.0, path 3.5, building 5.0), distinct patterns orchard/yard-edge/forest-edge/farmstead without new biome: hamlet 8, village 12 per settlement, via _settlement_trees using sample_coherent with domains settlement_front/settlement_slot_jitter, caps 64 instances/chunk.

### 3.7 Collision & Streaming
- Visible structural pieces (wall piers, lintels, slabs, rails) and collision pieces (same but merged into one Concave per chunk) remain aligned; collision uses 0.18 thickness boxes (rural smaller than city 0.35) at same positions as visual wall segments.
- Use existing collision representation: single `RuralBody` (StaticBody3D) with ConcavePolygonShape per chunk (ACTIVE-only, 1 collider/chunk, 0 if no building), dressing visual-only. Do NOT create one collider per tiny fragment.
- Measure collider/budget: rural 720 verts /420 tris dense (village 6+ dressing), 360/280 typical (hamlet), 1 collider, 6 doors max, 6 furniture max, 2 wells, 4 forage, 4 hearth, 2 workbench, 2 granary, 64 dressing instances, within FRAME_BUDGET_MS 12. Existing city budgets unchanged.
- Preserve chunk lifecycle ACTIVE ≤1/WARM ≤2/COLD>2 with hysteresis UNLOAD=3, MAX_MATERIALIZATIONS_PER_FRAME 1, freed-Zombie guard, duplicate-chunk protections (center ownership via footprints, path clipping, tree spacing). Preserve WorldPlan.surface_height_at as only outdoor surface authority (terrain_y + urban_weight + river bank + quarry). Preserve city exclusion (no building inside URBAN_INNER 350 except gate barn) and rural/city composition rules.

## 4. Files & Symbols — Exact

- `world/generation/world_constants.gd` — authoritative numerics: `MAX_RURAL_VERTS_PER_CHUNK 720`, `MAX_RURAL_VERTS_TYPICAL 360`, `MAX_RURAL_TRIS_PER_CHUNK 420`, `MAX_RURAL_TRIS_TYPICAL 280`, `RURAL_OVERLAY_LIFT_M 0.04`, `RURAL_PATH_*`, `RURAL_YARD_*`, `RURAL_FENCE_*`, `RURAL_CLUTTER_*`, `RURAL_SETTLEMENT_TREES_*`, `COL_RURAL_*`, `COL_RURAL_TREE_*`, `RURAL_BUILDING_*` footprints/heights/spacing already present; do NOT duplicate inline numbers elsewhere.
- `world/generation/world_seed.gd` — verify domains `INDUSTRIAL_CORRIDOR_DOMAINS`, `CAVE_CHAMBER_DOMAINS` etc remain; rural domains `rural_building`, `rural_building_yaw`, `rural_building_fp_x/y`, `rural_interior_wall`, `rural_furniture`, `settlement_front`, `settlement_slot_jitter` already seed-separated via `_unit_float_with_seed`, handling negative coords floori, no RNG sharing — reuse, do not add new if not needed.
- `world/generation/rural_building_plan.gd` — pure: `_generate()`, `_choose_building_kind`, `_footprint_for_kind`, `_yaw_for`, `_door_for_building`, `_generate_partition_wall`, `_generate_furniture`, `_generate_settlement_dressing` (paths/yards/fences/clutter/trees), caches `_cache` per seed including settlement_dressing arrays, helpers `_local_to_world`, `_world_to_local`, `_aabb_gap`, `_effective_footprint`, `_layout_slot_center`, `_dressing_basis`. Must remain pure, no Node access.
- `art/rural_art.gd` — geometry-only: `append_building(verts,normals,colors,indices, center, footprint, yaw, ground, height, door_pos, door_width, door_height, kind, wall_col, roof_col, timber_col, window_col)` emits plinth, wall quads with door split+lintel, gabled roof (ridge, fascia, cap), roof tile bands visual, windows+trim on 4 sides or loft vent, gable timber, chimney; `append_building_collision(collision_verts, ...)` emits 4-wall collision segments with door opening + lintel at 0.18 thickness; `append_tree`, `append_path`, `append_yard`, `append_fence` for dressing. All grounded via `WorldPlan.surface_height_at`, cardinal yaw, deterministic, no terrain carve.
- `world/streaming/rural_building_chunk_builder.gd` — `build_manifest(world_plan, coord)` clips owned buildings/wells/forage/hearth/workbench/granary/dressing by center, caps enforced (buildings6, doors6, wells2, forage4, stoves2, beds2, hearth4, workbench2, granary2, dressing64), batches via RuralArt, single RuralBody Concave ACTIVE-only; `materialize(parent, world_plan, coord, manifest)` creates N3D + Door/FoodCrate/Well/Forage/Stove/Bed/Workbench/Granary leaves; budgets enforced, freed-Zombie guard, 1-per-frame.
- `world/generation/world_plan.gd` — facade forwards: `rural_buildings_in(rect)`, `rural_wells_in(rect)`, `rural_forage_patches_in(rect)`, `rural_workbenches_in`, `rural_granaries_in`, `settlement_paths/yards/fences/clutter/trees_in(rect)` — private per-worker instances, plan_mutex guards CityPlan.
- `world/streaming/chunk_manager.gd` — stream rural with ACTIVE/WARM/COLD, `MAX_MATERIALIZATIONS_PER_FRAME 1`, early `_collect_finished_jobs(pc)`, freed-Zombie guard extended to rural dressing, counters `rural_vertices_total/triangles_total/colliders_total/doora_total/buildings_total/.../dressing`, unified 54 peak (9+9+9+9+9+9), telemetry `t_rural_gen/mat`, debug_lines, save_state deltas-only.
- `debug/rural_test.gd` — harness for determinism (same-seed byte-identical shuffled incl negative, different-seed differs), geographic gates via real WorldConstants, budgets/seams (verts≤720 tris≤420 1 collider, shared-edge agreement ≥7/9), streaming ACTIVE/WARM dedup + unload/reload identical, 9 resident rural chunks around transect with barns/stables, unified 54 peak, dressing 64 instances, surface-authority grounding.

## 5. Implementation Phases (builder order)

1. WorldConstants dressing constants + raised rural budgets 720/420 (if not already 720 on this worktree — verify diff shows 480→720 needed).
2. RuralBuildingPlan robust manifest: floor count/height/datum, wall opening descriptors, per-floor windows for two-storey, furniture anchors, kind variation, dressing generation with road-aware basis and slot jitter.
3. RuralArt wall grammar: wall segments around door/window (pier + lintel + sill/trim), plinth, per-floor windows, gable roof, chimney, grounded at surface, collision counterpart at 0.18.
4. RuralBuildingChunkBuilder manifest+materialize: center ownership, batching, caps, single Concave, budgets, ACTIVE-only.
5. WorldPlan facade + ChunkManager wiring: 10 settlement dressing forwards, rural counters, debug_lines, save_state exclusion.
6. Tests/docs: update rural_test watchdog 90→400, budget expectations 720/420, verify city/terrain/hydro/biome/road/cave/streaming unchanged, run suites via run_suite.py, archive windowed proof log.

## 6. Acceptance Criteria (prove independently, not one aggregate fallback)

1. **Wall sections & openings:** For each sampled rural building (at least 3 hamlet houses + 2 village houses + 1 barn/stable), manifest shows wall segments are built around door/window openings (piers+lintel) not façade quads; visual verts ≤720, collision Concave has opening void (no solid wall across doorway); lintel height = door_height + 0.15, thickness 0.18; upper floor windows at ground+floors*floor_h correct.
2. **Floors & datums grounded:** All wall bases at surface_height_at(center)+0.04 within 0.06, floor slabs at datum, roof ridge at total_h+1.2 within 0.1, no floating (raycast ground distance 0.01-0.08). Sample at (0,0) vs (1200,800) etc, all buildings grounded, upper floors correctly stacked, gables closed.
3. **Doors/windows/furniture structurally placed:** Doors are separate Door nodes (rural_door_*) at door_pos with correct yaw/width/height, hinge deterministic, swing ±1, kind rural_house; windows+trim dark interior planes structurally aligned inside wall thickness; furniture anchors deterministic, within building inset 0.75, clear of door 1.45 and partition 0.65, spacing ≥0.9, count 2-3 house else 1-2 barn, within budget.
4. **Visual/collision agree:** For same building, visual wall pier/lintel positions == collision boxes positions (±0.02) except collision thickness 0.18 vs visual may have outer quads; no collider per tiny fragment — one Concave per chunk merges all walls; door leaf collider toggles but wall remains.
5. **Rural variants:** Kinds produce meaningful structural variants: cottage 7-9×8-11, village_house 8-10×10-12 with 1-2 floors, barn/stable 8-10×10-14 with larger door 1.2×2.2 and loft vent vs windows, farmhouse similar, shed small 6-8×8-10 grey roof; deterministic via seed.
6. **Fences/gates/paths/trees deterministic & surface-authoritative:** Same-seed `settlement_paths/yards/fences/trees` byte-identical shuffled incl negative, different seed differs ≥30% placements; all grounded at surface_height_at+0.01-0.035; fences follow boundary polylines, posts 2.2 spacing, rails continuous, gates at path crossing 1.35 gap aligned with door approach; trees placed with building/path/door avoidance 4.5/5.0/3.5/5.0, hamlet 8 village 12 distinct patterns, never inside building aabb+5.0, road 5.0, path 3.5, within settlement radius*0.90, 64 instances/chunk cap, no duplicate at ±X/Z (center ownership).
7. **City behavior unchanged:** `--citytest` determinism still 0 failures, city building wall grammar unchanged, city interior still 3-room ground floor, city exclusion still URBAN_INNER 350, rural buildings still suppressed inside 350 except gate barn; city exclusion and rural/city composition rules preserved.
8. **Streaming/budgets/tests green:** ChunkManager streams rural with city+terrain+water+biome+road+cave+vertical: ACTIVE 9, WARM 14, unified active 54 not 63 (rural 1 collider), 64 dressing instances, t_rural_gen/mat ≤12ms per chunk, MAX_MATERIALIZATIONS_PER_FRAME 1 + freed-Zombie guard 0 failures, no duplicate chunks (center ownership), WorldPlan surface_authority preserved, save_state stores deltas only (no generated geometry), determinism shuffled incl negative coords byte-identical.

## 7. Required Tests (real Godot workflow)

- Run engine import first when class_name scripts or renamed scripts changed: `python tools/run_suite.py --import 120` → `boot OK`
- Then relevant suites (judge by `finished with 0 failure(s)` marker, 3221225477 with marker = pass, timeout extended):
  `python tools/run_suite.py --ruraltest 400` (primary, now 720/420 budgets, 9 resident rural chunks, wall segments, fences/paths/trees)
  `python tools/run_suite.py --citytest 400`
  `python tools/run_suite.py --terrainmaterialtest 300`
  `python tools/run_suite.py --hydrotest 300`
  `python tools/run_suite.py --biometest 420` (industrial still additive, 550 may be needed on slow HW)
  `python tools/run_suite.py --roadtest 400`
  `python tools/run_suite.py --cavetest 400`
  `python tools/run_suite.py --cityruntime 400`
  `python tools/run_suite.py --walkthrough 360`
  `python tools/run_suite.py --smoke 180`
- Inspect fresh logs for SCRIPT ERROR, Parse Error, missing classes, Element limit reached, null collision shapes, duplicate chunk subtrees, budget regressions; grep logs.
- Add focused test `debug/quick_rural_dressing_test.gd` for structural evidence not just labels: wall segments around openings, floor datums grounded, collision alignment, kind variants, deterministic dressing.

## 8. Forbidden Scope (STRICT)

- Do NOT add new biomes beyond existing `industrial_corridor` additive overlay
- Do NOT add society/economy/lore/quest or unrelated gameplay systems
- Do NOT redesign whole world generator or replace WorldPlan surface authority
- Do NOT weaken collision masks or spawn validation
- Do NOT use teleportation to hide grounding problems
- Do NOT bypass streaming or budget contracts (54 peak, 720/420)
- Do NOT rewrite city generator unnecessarily — reuse principles/helpers only
- Do NOT make unrelated character/combat/UI/menu/camera/cave/bridge/industrial changes
- Do NOT solve visual requirements with debug overlays/labels
- Do NOT weaken or remove existing tests
- Do NOT bundle every rural improvement into oversized task — M1 bounded as above; broader settlement dressing beyond minimal goes to next milestone

## 9. Budget Limits (authoritative WorldConstants)

- Terrain 17×17 289/512 1 collider/active 9
- Water 9×9 81/128 1/active 9
- Biome 9×9 81/128 1/active 9, MultiMesh ≤48, field tilled 96/64 orchard 12 quarry 6 industrial slag 6
- Road ≤96/64 typ 160/96 jun 1/active 9
- Rural 720/420 dense (village+ dressing) 360/280 typ hamlet 1 shell+well collider/active 9, doors ≤6, furniture ≤6, wells ≤2, forage ≤4, hearth ≤4, workbench ≤2, granary ≤2, dressing ≤64 instances
- Cave 24/12 0 collider/active 3 (chamber future 48/24)
- Vertical 24/12 0/active 3
- Unified active peak 54 not 63 (warm visuals retained but collision 0)
- FRAME_BUDGET_MS 12.0, MAX_MATERIALIZATIONS_PER_FRAME 1, early _collect_finished_jobs, freed-Zombie guard, GENERATOR_VERSION 2 additive

## 10. Rollback / Escalation

- Builder must not weaken tests to get green; if budgets exceeded, optimize geometry or cap instances, not raise again without arch approval.
- Max 2 bounded principal revisions; after cap, fresh architect design (new spec) not third patch. Minor findings deferred.
- If core API redesign needed (e.g., WorldPlan surface authority change, city generator rewrite, or streaming contract break), escalate to architect for fresh design — do not silently refactor.
- On failure, preserve evidence: BUILD_RESULT with fingerprint, HEAD before/after, changed files, tests pass/fail with marker, player-facing verification, limitations, blocker.
- Preserve uncommitted work: never delete files; move unwanted temps to junk/.

## 11. References (actual files)

- City reference: `world/generation/building_builder.gd:1-3386`, `world/streaming/chunk_builder.gd:1-598`, `world/streaming/mesh_batcher.gd`, `world/generation/world_constants.gd:1-567`, `world/generation/city_plan.gd:1-604`, `world/generation/world_seed.gd`, `world/streaming/chunk_manager.gd:1-2456`
- Rural target: `art/rural_art.gd` (existing 541 lines on recovery — needs per-floor windows + floor slab parity with canonical 564), `world/generation/rural_building_plan.gd` (499 diff on recovery — needs hamlet fallback + 48 attempts + road gate tuning to reach 604), `world/streaming/rural_building_chunk_builder.gd` (259 diff — needs 720/420 budgets), `world/generation/world_constants.gd` (60 diff — needs 720/420), `world/generation/world_plan.gd` (40 diff — needs dressing forwards), `debug/rural_test.gd` (17 diff — needs watchdog 400 + hamlet relax)

## 12. Next Milestones (deferred)

- M2: Full settlement dressing gates/paths/trees density tuning + village worker schedule expansion
- M3: Industrial warehouse fabric + slag volume
- M4: City retail upper floors circulation
- Selection after M1 review.

Architect heartbeats via `python tools/ring_bell_runtime.py heartbeat --role architect --action inspecting` etc; fingerprint via `python tools/ring_bell_runtime.py fingerprint`.

