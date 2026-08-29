# Development Guide

## Requirements
- Godot 4.7.x (tested with 4.7.2 stable, Windows)
  - This workspace uses: `C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe`
  - Canonical project path: `C:/Vibe Code project/Godot Project/ring-bell` (never a OneDrive copy)

## Opening / running

- Open the project folder in Godot (it contains `project.godot`), press F5.
- Or from a terminal:

```powershell
& "C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe" --path "C:/Vibe Code project/Godot Project/ring-bell"
```

## Controls

| Input | Action |
|---|---|
| WASD | Move (camera-relative) |
| Shift | Sprint (drains stamina) |
| LMB / Space | Melee attack |
| E | Interact / talk |
| F | Eat food item |
| G | Use medical item |
| Q / R | Rotate camera (also RMB-drag) |
| Mouse wheel | Zoom |

## Debug hotkeys

| Key | Effect |
|---|---|
| F3 | Toggle debug overlay (stats, quest states, world-event log) |
| F5 | Quicksave |
| F9 | Quickload |
| T | Cycle game time scale x1 / x8 / x30 |

Save file: `%APPDATA%\Godot\app_userdata\Ring Bell\saves\save_01.json`

## Headless validation (no window needed)

Run after any script change. All must finish with `finished with 0 failure(s)` per `tools/run_suite.py`.
A Windows child exit `3221225477` (0xC0000005) with that marker is not a failure — judge only by the marker, not the exit code. Small headless shutdown `ObjectDB !is_inside_tree()` noise is guarded where feasible (see `world/main.gd`).

```powershell
$G = "C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe"
$P = "C:/Vibe Code project/Godot Project/ring-bell"

# 1) Reimport + parse check (12 s)
python tools/run_suite.py --import 120

# 2) Hydrology determinism + water manifest budgets (hydrology owns river+tributaries)
python tools/run_suite.py --hydrotest 300
# alias also accepted (same harness):
python tools/run_suite.py --hydromaterialtest 300

# 3) Procedural city determinism suite
python tools/run_suite.py --citytest 300

# 4) Terrain manifest + streaming budgets (17x17, 289 verts / 512 tris, 1 collider/chunk)
python tools/run_suite.py --terrainmaterialtest 300

# 5) Streamed-city integration (physics rays, doors, stairs, camera, persistence)
python tools/run_suite.py --cityruntime 300

# 6) Honest player traversal (no teleport: door -> stairs 5 storeys -> roof -> exit)
python tools/run_suite.py --walkthrough 360

# 7) Havoc physics + firearms integration (doors, explosion, SMG, rocket, glass ladder)
python tools/run_suite.py --havoctest 240

# 8) Functional regression suite (exits 0 on success; runs on the legacy block)
python tools/run_suite.py --smoke 180

# 9) Day/night + sleep AI + zombie wandering soak (legacy block)
& $G --headless --path $P -- --soak
```

The project wrappers `tools/run_suite.py` invoke `godot --headless --path <proj> -- --<flag>` and judge by the `finished with 0 failure(s)` marker printed by each harness (Windows `3221225477` with marker is a pass). Long Godot runs can hang past the shell timeout and lose partial output — `run_suite.py` redirects to a file so timeouts still yield diagnostics. Do not launch a second Godot instance while one may still be alive (`tasklist /FI IMAGENAME eq Godot*`).

Note when launching via `Start-Process`: quote the `--path` argument; prefer plain `&` invocation so output streams live.

## World modes

| Mode | When | Content |
|---|---|---|
| CITY (default) | normal launch | streamed procedural city + terrain + water: ChunkManager loads 64 m chunks (ACTIVE ring <= 1 with physics, WARM <= 2 visuals only, hysteresis UNLOAD=3) from deterministic CityPlan/TerrainPlan/HydrologyPlan via WorldPlan facade; player spawns at the plaza anchor on the `URBAN_INNER_M=350` flat, ambient zombies scatter on streets; river corridor `CX 530-710 m` east with `9x9` water meshes (81 verts / <=128 tris, at most 1 water collider per wet chunk, 9 active water max) streams with the same pipeline and F3 stats `t_water_gen`/`t_water_mat` |
| LEGACY | `--smoke`, `--soak`, `--legacy-block` | hand-built Prototype 0 test block with the full narrative cast |

**Streaming telemetry (F3 overlay and headless logs):** `ChunkManager.debug_lines()` exposes `chunk | active | warm | queued | loads/unloads`, `boxes | colliders | doors | buildings | records`, `gen | materialize | resident`, plus terrain `verts | tris | colliders | t_gen | t_mat_total | active terrain (warm)` and water `verts | tris | colliders | t_water_gen | t_water_mat | active water (warm)`. Per-chunk `terrain_gen_ms`/`terrain_mat_ms` and `water_gen_ms`/`water_mat_ms` are measured inside the worker (private WorldPlan) and on the main thread respectively and budgeted within `FRAME_BUDGET_MS 12.0`.

**Collision budget (ACTIVE-only, intentional optimization — corrects the previous warm+active assumption):** warm chunks retain their merged `MeshInstance3D` visuals (city, terrain, water) but their `StaticBody3D`/`WaterBody` collision is disabled (`collision_layer=0` or `MeshBatcher.disable_collision()`). Only ACTIVE chunks contribute to `colliders`/`terrain_colliders`/`water_colliders` and to `active terrain`/`active water` counts. This keeps physics at `9 city + 9 terrain + at most 9 water` colliders (3x3) while warm visuals stay resident for seamless streaming. Previous docs that stated warm+active physics are corrected here.

Extra dev flag: `--shot` captures screenshots (gameplay + top-down overview + street level + far teleport) to `%TEMP%\opencode\rb_*.png` and prints F3-style streaming stats, then quits. Note: headless `--shot` uses the dummy renderer and its textures are null — for the archived windowed proof (see below) use a normal **windowed** CITY run, not `--shot`.

### What `--hydrotest` / `--hydromaterialtest` verifies (P2.2-HYDRO-ANCHORS)

Same-seed hydrology queries and water manifests identical regardless of query/build order (including negative coords), different seed materially differs, primary centerline continuous across every chunk seam, both tributaries approach monotonically and meet within 600 m of the seeded confluence; geographic validity for canonical +4 alternate seeds: deterministic `CX 530-710 m` + meander `+-72 m`, width `38-50 m`, bank `9 m` / floodplain `26 m` monotonic, no water on cliff slopes/ridge hilltops except lake placeholder, flow unit length with northward `>0.35` primary and `>0.45` tributary convergence dot using real `WorldConstants` thresholds; water materialization budgets and seams: chunk water manifests byte-identical across shuffled builds, shared-edge heights/centerline within `0.02 m` at `+` and `-` boundaries, `<=1` water collider per chunk (`0` if dry), `<=9` active water in `3x3`, bounded `81/128` verts/tris per wet chunk (9x9) and per-chunk `water_mat_ms`; ChunkManager streams water with terrain+city without duplication: `3x3` ACTIVE ring around a hill near the river claims `active water <=9`, walking `480 m` beyond `UNLOAD_RADIUS` unloads river chunks and returning regenerates identical manifests, debug stats contain `t_water_gen`/`t_water_mat`, generated water excluded from `save_state()`.

### What `--citytest` verifies

Same world seed -> identical plan data and chunk geometry manifests regardless of query/build order; a different seed produces a materially different city; spawn anchors exist; multi-storey buildings generate near the center; chunk discovery records survive a save/load round-trip; building overlap, door manifest, stair/landing geometry, facade/balcony/scaffolding, and destruction delta persistence.

### What `--terrainmaterialtest` verifies

Terrain is a 17x17 heightfield per 64 m chunk (4 m spacing, 289 verts / 512 tris, 1 Concave per chunk, 9 active max); shared-edge heights identical within `0.02 m` at `+/-` boundaries; manifest equality across shuffled builds; material vocab, cliff-to-rock, normals, and mesh/collision extents; ACTIVE-only terrain colliders, `t_gen`/`t_mat` timings; ground ownership (`URBAN_INNER_M=350` flat, `URBAN_OUTER_M=600` transition) and no duplicate flat/terrain surfaces.

### What `--cityruntime` verifies

ChunkManager exists, `3x3` ACTIVE ring, player spawned, exterior wall blocks physics ray, zombies and door entities exist, closed leaf blocks doorway center, open doorway clear without RID exclusion and swung leaf remains collidable, far ring activates after teleport and origin chunks unload/return deterministically, stair probe reaches upper floor, camera rig exposes real lens offset and sector/facade math, interior presentation distance `<=9 m` while preserving user zoom, and streamed destruction survives unload/reload.

### What `--walkthrough` verifies

Honest player traversal (no position writes/teleport): closed door blocks, E opens it, walk door->stairwell, climb all 5 storeys to roof deck, camera tracks vertical climb, descend to ground, walk out, close door and verify it blocks again. No waypoint skips.

### What `--havoctest` verifies

Door structural destruction leaves doors group and spawns wood debris, explosion damages/kills zombie and emits noise and ragdoll, player survives blast, weapon system wired, destructible prop placed with clear shot, SMG damages prop, rocket in flight detonates into debris, explosion respects material integrity, glass damage ladder matches `ItemDB` weapons, camera follows vertical movement.

### What `--smoke` verifies

Population spawns; hungry NPC eats carried food; crates feed NPCs; melee damages/kills zombies; quest objective advances if Hana was met BEFORE the quest starts; Hana's independent death fails the quest and is recorded; Kenji's dialogue switches to a grief branch; parkour ledge/cornice/awning grabs, stamina scaling, and HUD flashes; semantic room layouts and zombie flanking; save/load keeps her dead, respawns everyone else, restores the clock.

## Manual test walkthrough (the narrative + hydro proof)

1. Run the game windowed (1200x720 windowed, CITY default). Spawn at plaza, toggle F3.
2. With WASD approach a qualifying building (`int(floors)>=2`, `BuildingBuilder.has_stairs_for` true); closed entrance must stop the capsule. Press E — door visibly swings and remains solid at the swung position, walk through the aperture, cross the entry corridor, climb the visible stairwell to every floor and the roof deck, reverse and leave, close the door from outside and verify it blocks again. F3 overlay must show `active water` and `t_water_gen`/`t_water_mat` (even if zero near spawn) and `active terrain`.
3. Then walk east (or toward the deterministic river `CX` at `~620 m`) `600-900 m` over rolling hills — the valley should appear as a long teal water surface with darker banks and lighter floodplain meadow contrast (vertex-colored, no authored texture). Stand on a bank hill and observe water continuity across streamed chunks (no cracks at 64 m seams, no flicker as chunks warm-stream). If a failure occurs, retain PNG/log with exact player `global_position`, `WorldSeed` value, and river centerline X at that Z.
4. Quest proof: Talk to **Kenji Tanaka** inside the apartment building (east door). Accept his task. Cross the east road; find **Hana Tanaka** near the wrecked cars in the southeast corner. Talk to her - objective flips to "Return to Kenji". Return to Kenji -> quest completes. Variation A: talk to Hana FIRST, then Kenji - he skips the "find" objective. Variation B: while the quest is active, let a zombie kill Hana (or use timescale T) - the quest FAILS by itself and Kenji now only speaks the grief branch. Kill Hana, F5, quit, relaunch, F9 -> she stays dead after load.

Do not compensate with teleport or disabled collision. A screenshot built with `--shot` in headless is not sufficient for this proof due to dummy renderer; the archived PNG must be from a real windowed run and stored under `.hermes/autopilot/reports/` or `junk/` with its run log.

## Conventions for AI-assisted changes

- Read ARCHITECTURE.md before refactoring anything.
- One responsibility per file; keep files small and explicitly named.
- Update the signal contract list in `event_bus.gd` when adding signals.
- Never hard-code actor ids outside `population.gd`, `dialogue_data.gd`,
  and quest definitions.
- After changes: run every gate named by the active spec through `tools/run_suite.py` and judge by the `finished with 0 failure(s)` marker (Windows `3221225477` with marker is a pass). Do not weaken assertions, hide errors, accept pending/inflight work as completed behavior, or replace ordinary movement with teleportation when the spec requires player traversal.
- Preserve all unrelated dirty files and user work. Never reset or clean the checkout. Never delete files; move unwanted artifacts into project `junk/`.
- Headless shutdown noise: where `world/main.gd` or smoke/walkthrough probes fetch `global_transform` after `queue_free` during shutdown, guard with `is_instance_valid` + `is_inside_tree()` before reading transforms; ensure `ObjectDB` script warnings are quelled without masking real failures.
