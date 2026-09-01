# AUTOPILOT TASK — The ONLY current implementation assignment

**Task:** Rural structural construction parity — port city wall/opening grammar to rural houses/barns/stables (M-RURAL-STRUCT-1)
**Grand Plan:** Generation 8/10 — Rural Port M1 bounded slice (user-directed, supersedes G10-M1 cave chamber for this cycle; cave/industrial remain additive)
**Player-facing goal:** The hamlet and village you walk through now reads as real buildings: thick walls with door/window openings (piers + lintels), floor slabs, gabled roofs with chimneys, per-floor windows on two-storey houses, and collision that matches what you see. Fences, yards, cart/foot paths and trees form coherent deterministic settlements, all grounded on WorldPlan surface, budgeted, and streamed — replacing the old house-shaped batched mesh without breaking city/cave/streaming.

## Context

City pipeline (Ox Alpha) builds multistory buildings from real wall sections: every door/window is carved by same aperture generator (piers + sill + lintel, glass inside void), destructible ~1m modules, ground slab below grade so doorways walkable, slabs with stairwell holes, batched via MeshBatcher to one mesh + one StaticBody per chunk, ACTIVE-only physics 54 peak, deterministic via WorldSeed domains. Rural fabric currently on recovery worktree (6f704b8 base) still uses batched-mesh shells (box + roof) with façade quads, not wall sections around openings; budgets 480/360 old, hamlet house+barn guarantee flaky, per-floor windows missing, floor slab missing. Canonical master already proves port at b256287 (e399bde..b256287): RuralArt wall grammar 564 lines, WorldConstants 720/420, RuralBuildingPlan 604 delta, RuralBuildingChunkBuilder 259 delta — all 0-fail but recovery trails by 4 commits (diff shows 541 vs 564 rural_art, 480 vs 720 budgets, 499 vs 604 rural_plan). This task brings recovery to parity as smallest reliable structural milestone, reusing city principles via rural-owned helpers, preserving surface-authority/streaming/budgets.

## Scope

**Implement:**

1. `world/generation/world_constants.gd` — raise rural budgets to proven values (no duplicate inline): `MAX_RURAL_VERTS_PER_CHUNK 480→720`, `MAX_RURAL_VERTS_TYPICAL 280→360`, `MAX_RURAL_TRIS_PER_CHUNK 360→420`, `MAX_RURAL_TRIS_TYPICAL 210→280` (village dense 6 buildings+2 wells+4 forage+2 stoves+2 beds+1 workbench+1 granary+ fences/paths/trees still within 720/420; hamlet within 360/280). Verify dressing constants `RURAL_PATH_*`, `RURAL_YARD_*`, `RURAL_FENCE_*`, `RURAL_CLUTTER_*`, `RURAL_SETTLEMENT_TREES_*`, `RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK 64`, `COL_RURAL_*`, `COL_RURAL_TREE_*` present (from e399bde) — add if missing, do not duplicate elsewhere.

2. `art/rural_art.gd` — port city grammar to rural geometry-only helpers (reuses city wall-section math but rural-owned, no city generator import). Implement/verify: `append_building` emits structural wall segments with door opening split (two piers + lintel at door_width/height), plinth 0-0.38, gabled roof ridge+fascia+ridge cap, roof tile bands visual-only, windows+trim on 4 sides (house) or loft vent (barn/stable), per-floor windows for two-storey (upper windows at ground+floor_h+WIN_SILL), gable timber detail, chimney visual-only; all grounded via `WorldPlan.surface_height_at` + lift 0.04, cardinal yaw. `append_building_collision` emits 4-wall collision segments with door opening + lintel at 0.18 thickness. `append_tree/path/yard/fence` handle dressing deterministic, no terrain carve. Match canonical 564 lines behavior (5c388b8 floor slab + per-floor windows inclusive).

3. `world/generation/rural_building_plan.gd` — deterministic pure plan extensions already partially on recovery (499 lines). Bring to canonical 604: ensure hamlet fallback `tile/strata/gate_id` preserved plus road setback gate (4m) with `48` attempts spacing, deterministic house+barn guarantee for every hamlet (fallback cottage if needed, relax road setback leniently but still gate, all hamlets 100% house+barn), second barn/stable for villages 5-6 buildings, layout slots via `_layout_slot_center` + jitter 2.2/2.0 clamped to radius*0.90 road-aware via `_dressing_basis`, interior partition 0.15 inset 0.5 gap 0.95 + robust furniture pass (2-3 house else 1-2 barn guaranteed inhabited), fences 7 hamlet/10 village, trees 8/12 with spacing 4.5/road5.0/path3.5/building5.0 via settlement_front/slot_jitter domains, paths/yards fences/clutter/trees deterministic via `_generate_settlement_dressing` 64/chunk cap. Cache extended to include settlement_dressing arrays + stale detection for hamlet barn/second barn. Must handle negative coords floori, byte-identical shuffled, different seed differs.

4. `world/streaming/rural_building_chunk_builder.gd` — pure manifest `build_manifest(world_plan, coord)` clips owned buildings/wells/forage/hearth/workbench/granary/dressing by center, caps buildings6 doors6 wells2 forage4 stoves2 beds2 hearth4 workbench2 granary2 dressing64, batches vertex-colored ArrayMesh via RuralArt wall grammar + dressing appends, single `RuralBody` Concave (1 collider/chunk ACTIVE-only, dressing visual only), grounding at surface+0.04 buildings / +0.035 paths / +0.01 yards, budgets 720/420 enforced, freed-Zombie guard + MAX_MATERIALIZATIONS_PER_FRAME 1 preserved, center ownership no duplication at ±Z.

5. `world/generation/world_plan.gd` — facade owns enriched RuralBuildingPlan and forwards 10 settlement dressing pure queries `settlement_paths/yards/fences/clutter/trees` (+ existing rural_buildings/wells/forage/workbenches/granaries) via private per-worker instances, plan_mutex guards CityPlan caches exactly as before. `GENERATOR_VERSION` stays 2 additive.

6. `world/streaming/chunk_manager.gd` — ensure rural telemetry includes dressing: counters `rural_vertices_total` etc already, but verify `t_rural_gen/mat` includes dressing derivation, `debug_lines()` shows `rural verts|tris|colliders|doors|buildings` with dressing counts within same line, pacing 1-per-frame + freed-Zombie guard extended to dressing Area3D, unified 54 peak not 63, save_state excludes generated geometry (deltas only).

7. `debug/rural_test.gd` — update harness to proven budgets/watchdog: watchdog 90→400, expects 720/420 verts/tris per chunk, hamlet lenient house+barn-or-stable 100% pass (strict house+barn for settlement_1_5_0 relax documented), wall-segment structural checks, per-floor window checks, floor slab checks, 9 resident rural chunks with dressing, 64 instances, unified 54 peak, determinism shuffled incl negative, different-seed differs, grounding surface_authority diff <1.0.

8. Update `ARCHITECTURE.md`/`DEVELOPMENT.md` module map + telemetry + gate docs for rural port M1 (wall grammar, floor slab, per-floor windows, dressing, budgets 720/420).

**Do NOT implement (out of scope):** new biomes, society/economy/lore/quest, whole world generator redesign, WorldPlan surface authority replacement, collision mask weakening, teleportation to hide grounding, streaming/budget bypass, city generator rewrite, unrelated character/combat/UI/menu/camera/cave/bridge/industrial changes, debug overlays/labels, weakening existing tests, bundling broader settlement beyond minimal M1 scope.

## Acceptance Criteria (prove independently, not one aggregate fallback)

1. **Wall sections & openings:** Sample 3 hamlet houses +2 village houses +1 barn: walls are real sections around openings (piers+lintel) not façade quads; verts ≤720 tris ≤420 1 collider; door lintel height = door_h+0.15 thickness 0.18; upper windows at floor_h offset for two-storey; visual vs collision piers/lintel positions agree ±0.02.

2. **Floors & datums grounded:** All wall bases at surface_height_at+0.04 ±0.06, floor slab at datum, roof ridge at total_h+1.2 ±0.1, no floating (raycast ground 0.01-0.08); upper floors stacked correctly.

3. **Doors/windows/furniture structurally placed:** Doors separate Door nodes rural_door_* at door_pos width1.0/1.2 height2.1/2.2 hinge deterministic swing ±1; windows+trim dark interior inside wall thickness; furniture anchors deterministic inset 0.75 clear door 1.45 partition 0.65 spacing ≥0.9 count 2-3 house.

4. **Visual/collision agree & variants:** Single Concave per chunk merges walls, no per-fragment colliders; door leaf toggle doesn't delete wall; kinds produce variants (village 8-10×10-12 1-2 floors, cottage 7-9×8-11, barn 8-10×10-14 loft vent 1.2×2.2).

5. **Fences/gates/paths/trees deterministic & surface-authoritative:** Same-seed identical shuffled incl negative, different seed differs ≥30%; grounded +0.01-0.035; fences posts 2.2 spacing rails continuous gates 1.35 at path crossing aligned with doors; trees 8 hamlet 12 village spacing 4.5/5.0/3.5/5.0 avoids buildings/roads/paths, 64 cap, no duplication.

6. **City unchanged & budgets/tests green:** `--citytest`, `--terrainmaterialtest`, `--hydrotest`, `--biometest`, `--roadtest`, `--cavetest`, `--cityruntime`, `--walkthrough`, `--smoke` still 0 failures; rural 720/420 within FRAME_BUDGET_MS 12; active rural ≤9 unified 54 peak; surface_authority preserved; determinism byte-identical shuffled incl negative coords.

## Execution Notes

- Preserve uncommitted work in recovery (499+ lines already) — integrate not reset; never delete to junk unless temp.
- Use headless import first if class_name changed: `python tools/run_suite.py --import 120` → boot OK.
- Judge suites by `finished with 0 failure(s)` marker (3221225477 with marker = pass); inspect logs for SCRIPT ERROR / Parse Error / missing classes / Element limit reached / null collision shapes / duplicate chunk subtrees / budget regressions.
- Work only under C:/Vibe Code project/Godot Project/ring-bell-front-end-recovery; do not edit canonical checkout.

## Tests

- `python tools/run_suite.py --import 120`
- `python tools/run_suite.py --ruraltest 400` (primary)
- `python tools/run_suite.py --citytest 400`
- `python tools/run_suite.py --terrainmaterialtest 300`
- `python tools/run_suite.py --hydrotest 300`
- `python tools/run_suite.py --biometest 420`
- `python tools/run_suite.py --roadtest 400`
- `python tools/run_suite.py --cavetest 400`
- `python tools/run_suite.py --cityruntime 400`
- `python tools/run_suite.py --walkthrough 360`
- `python tools/run_suite.py --smoke 180`
- Plus quick headless `godot --headless --path <proj> -- --ruraltest` logs inspected.

## Budget & Rollback

- Rural 720/420 dense 360/280 typ 1 collider 9 active 54 peak; do not raise again without arch.
- Max 2 principal revisions; after cap fresh spec.
- On blocker, BUILD_RESULT with fingerprint, HEADs, files, tests, verification, blocker.

