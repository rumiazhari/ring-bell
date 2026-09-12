# Q2 — Parkour overhaul: verified features, honest movement, real routes

Owner of record: Ring Bell queue item **Q2** (`.hermes/plans/QUEUE.md`). Status: IN PROGRESS.
Branch: `copilot/worldgen-fix` (push ONLY this branch; never merge/ff `master`).
Project root: `C:/Vibe Code project/Godot Project/ring-bell`.

## 1. Measured baseline (2026-09-13, before any edit)

### 1.1 The controller
`actors/traversal/parkour_controller.gd` (617 lines).

| Item | Value |
| --- | --- |
| chest probe height / reach | `LEDGE_PROBE_HEIGHT 1.2`, `LEDGE_PROBE_REACH 0.62`, lateral `±0.18` |
| lip probe | `_probe_ledge()`: from the wall hit, step `dir * 0.45` outward, cast DOWN from `feet+2.2` to `feet+0.85` |
| accept window | `rise ∈ [0.9, 2.1]`, `normal.y ≥ 0.6`, descending ≥ −0.5 m/s, air time ≥ 0.30 s, cooldown 0.9 s |
| grab effect | `_commit_grab()`: stamina, `velocity.y = sqrt(2g(rise+0.35))` clamped [4.5, 9.5], xz × 1.35, then a 0.6 s assisted drive |
| classification | from the *ray-hit* shape meta: `vox_material == concrete` → building/rooftop mantle; `vox_tag` → feature class (awning today) |
| seek | 8 evenly spaced rays around the body (`LEDGE_SEEK_RAYS`), plus separate vault/mantle/wallrun probes |
| hang | animation-only. `CharacterLocomotion` HANG/SHIMMY/DROP2HANG/CLIMB_UP states exist; the controller never anchors the body, the locomotion writes no position |

### 1.2 Defect A — the lip probe misses every shallow facade feature
The down-probe is pushed **0.45 m outward** before descending. A hold is therefore grabbable only when it protrudes ≥ ~0.45 m. Per the generator constants in `world/generation/building_builder.gd`:

| feature | tag (collider) | protrusion | grabbable today? |
| --- | --- | --- | --- |
| balcony deck | `balcony` | `BAL_PROJ 0.7` | yes |
| scaffold plank | `scaffold` | `SCAFF_PROJ 1.0` | yes |
| awning deck | `awning` | ~1.2 | yes |
| cornice band | `cornice` | `CORN_PROJ 0.26` | **no — probe steps past it** |
| pilaster | `pilaster` | `PIL_PROJ 0.24` | **no** |
| roof parapet | *(untagged)* | 0.28 thick, `PARAPET_H 0.9`, centred on `WALL_T 0.35` | **no** |
| balcony rail | `balcony` | `BAL_RAIL_T 0.07` | **no** |
| bulkhead rim | `bhexit` | `BH_RAIL_T 0.08`, `BH_RAIL_H 0.45` | **no** |
| drainpipe | `drainpipe` | 0.06 square | **no** |
| window sill | *(none)* | `SILL_T 0.06 × SILL_H 0.09`, visual-only, no collider | **no — not physical** |

So the worldgen already emits an AC-style ledge vocabulary (its own comment calls it "AC ledge/pillar parkour network"), but the climb rule can only reach the four deepest members. Facade→roof chains are broken at exactly the features generated for parkour.

### 1.3 Defect B — acceptance is geometric luck, not verified features
`_probe_ledge()` returns on the first down-ray hit. Nothing verifies: which shape the lip belongs to (a doorway/window hole lets the probe land on unrelated geometry), the lip's usable width/depth, capsule clearance at the hang point or the landing, or whether a "top surface" is an exposed top at all (a storey seam inside a facade is a down-ray hit too). Semantic tags are consulted only *after* the grab, for HUD counters.

### 1.4 Defect C — no anchored hang
`_commit_grab()` launches the body ballistically. `CharacterLocomotion` HANG/`shimmy`/DROP2HANG animate, but the body keeps whatever velocity the match had: during HANG xz is frozen by `survivor.gd` while gravity still pulls, so the climber sinks down the face while the hang animation loops. No wall anchor, no shimmy travel limit, no corner traversal, no release-to-drop, no clip protection.

### 1.5 Stamped tags (`MeshBatcher.flush_into`, lines 1138-1145)
Whitelist: `awning, balcony, tower, bhplant, bhladder, bhexit, scaffold, cornice, pilaster`. `vox_material` is stamped on every batched structural/destructible cell. Building-id owner tags are deliberately not stamped. Parapets and all visual dressings are emitted with no owner tag, so they are unreachable by any tag rule.

### 1.6 Proof harnesses already in tree
`--smoke` (fixture grabs: crate, cornice-crate, awning deck + lip, awning→balcony chain), `--animclimb`, `--animationtest` (hand snap), `--walkthrough`, `--havoctest`, `--citytest`, `--cityruntime`, `--terraintest`. Fixtures are plain `StaticBody3D`+`CollisionShape3D` (no meta = untagged prop) or with `vox_material`/`vox_tag` metas. Real generated buildings are built in tests as `MeshBatcher.new()` → `BuildingBuilder.build(batcher, spec)` → `batcher.flush_into(holder)` (see `debug/city_building_repair_test.gd:99-103`).

## 2. Design

### 2.1 One ledge-query, feature-verified (replaces `_probe_ledge` internals)
`query(dir) -> Dictionary` returns `{}` or a full record: `{kind, tag, shape_node, lip (Vector3), lip_normal, wall_normal, face_plane, rise, width, depth, thickness, stand_off, hang_clear, stand_clear, wall_hit}`.

Rules, each individually testable:
- **A. Face**: chest ray (`1.2` above feet, `±0.18` lateral, reach `0.62`) hits a `BoxShape3D` face whose normal opposes the probe (`normal·dir ≤ −0.5`) — rejects glancing/backside hits.
- **B. Rise**: lip top within `[LEDGE_TOP_MIN 0.9, LEDGE_REACH_ABOVE 2.1]` above the feet.
- **C. Attribution**: the lip belongs to the ray-hit shape; when that shape has no reachable top, a bounded scan (4 outward offsets `0.10…0.40`, each one down-ray) may find a *protruding* shape instead. This is how a cornice above a window band is found without opening the "any wall" door.
- **D. Profile** (verified from the actual `BoxShape3D.size` + world basis, not from a guess):
  - depth = horizontal extent along the face normal; width = extent along the ledge tangent; thickness = extent on Y.
  - `slab` class (cornice, parapet, balcony deck, scaffold plank, awning deck, roof edge, prop): `depth ≥ 0.14`, `width ≥ 0.45`, `thickness ≥ 0.05`.
  - `bar` class (balcony rail, bulkhead rim): `depth ≥ 0.05`, `width ≥ 0.45` (thin members are legal holds, tiny dressings are not).
  - `pipe` class (drainpipe): vertical hold, square section `≥ 0.05`, run `≥ 2.5 m`; climbed, not mantle-able as a ledge.
- **E. Exposed top** (this is the blank-wall rule): the point 0.2 m inboard of the lip's outer edge at `lip_y + 0.10` must be empty of colliders, and a `0.6 m` upward ray from it must be clear. A blank facade cell fails (the point is inside the wall / wall continues above); a storey seam fails (wall above); a cornice, parapet, roof edge, plank, crate or balcony all pass. Untagged `slab` shapes bigger than 2.0 m horizontally are additionally required to carry `vox_material` (i.e. be real building structure) before they count as a roof-edge hold.
- **F. Hang clearance**: capsule (`r 0.30`, `h 1.7`) at the hang pose (`face_plane + normal·0.45`, feet at `lip_y − 1.45`) clear of everything but the lip shape.
- **G. Destination**: stand capsule (`r 0.30`) at the mantle landing; bounded 3-offset search (outward `0.30 / 0.38 / 0.46`); records `stand_clear`. Blocked landings downgrade to hang-only, never a phantom mantle.
- **H. Budget/determinism**: ≤ 24 rays + ≤ 8 shape queries per grab attempt; no `randf`, no wall-clock; cache while hanging/shimmying.

### 2.2 Anchored movement (no teleport, no sinking)
- Grab → **HANG**: state + anchor `{lip, wall_normal, face_plane, tangent, half_width}`; velocity zeroed; per-frame skin correction to the hang pose clamped at `HANG_SNAP_MAX 0.10 m/frame` (a few centimetres against a nearby surface, never a jump between distant holds).
- **Shimmy**: A/D travel along the tangent at `SHIMMY_SPEED`, anchored to the face, clamped by the *measured* `half_width`; ledge end stops instead of floating.
- **Corner traversal**: at a ledge end, one perpendicular query (`±90°`); a compatible hold within reach re-anchors and continues, otherwise release.
- **Climb-up**: jump while hanging → verified mantle (clearance from G, `stand_clear` required), driven like today's climb; **drop**: S/down or a grab release → release-to-fall, then a lower hold may be re-grabbed while falling (drop-to-hang).
- Keep every existing counter (`ledge_grabs`, `rooftop_mantles`, `awning_grabs`, `last_grab_was_*`) so `--smoke` keeps its meaning.

### 2.3 Worldgen: make the generated vocabulary reachable
- `building_builder.gd`: tag the roof **parapets** (`&"parapet"`), the **facade bands/string courses** where they are structural, and the bulkhead rim (`bhexit` already tagged) via the emitter's `owner_tag` argument.
- `mesh_batcher.gd`: extend the stamp whitelist to `parapet, sill, band, ledge, bulkhead, drainpipe` and (only when the geometry profile passes at runtime) keep dressings out.
- **Sills stay visual-only** (`SILL_T 0.06 × SILL_H 0.09`, no collider). Promoting them would add ~4 colliders per window for a 9 cm shelf that no human mantles; the "substantial surround" role is already filled by cornices, bands, parapets, balcony decks, planks and bulkhead rims. Recorded as a deliberate deviation, not an oversight.
- Any newly tagged feature must still be reachable *by geometry* — tags classify, they do not confer climbing.

### 2.4 Tests
New headless suite `--parkourledgetest` (`debug/parkour_ledge_test.gd`), deterministic, 4 sections:
1. **Rejection matrix on fixtures**: blank facade cell (top in reach, wall above) → no grab; storey seam → no grab; 0.06 dressings (sill/trim/shutter/gutter) → no grab; through-wall (hole + far lip) → no grab; tall wall (top out of reach) → no grab; deep crate / cornice / parapet / balcony rail / bulkhead rim → grab, with `kind` matching.
2. **Real buildings**: `BuildingBuilder.build` over real specs (inner-city + historic, ≥ 3 seeds, ≥ 8 buildings) — probe a lattice of points on every facade at every storey; report accepted holds per kind with measured width/depth; assert no accepted hold fails its profile, every accepted hold has `hang_clear`, and route diversity is non-uniform.
3. **Real climb**: drive the real `Survivor` + `ParkourController` up ≥ 2 buildings (jump, hold toward the face, climb-up): reach the roof deck (≥ `floors × floor_h`) with ≥ 2 chained holds, and assert no per-frame displacement exceeds the honest-traversal budget (no teleports).
4. **Determinism**: the whole section-1 matrix re-runs to an identical record, twice.
Plus: `--smoke` stays green (fixtures keep their meaning), `--animclimb` and `--animationtest` stay green.

## 3. Stages / commits (push after each)
1. Plan document (this file).
2. `mesh_batcher` + `building_builder`: parapet/band/bulkhead tags on collidable cells; whitelist stamping.
3. `parkour_controller`: rules A–H replacing `_probe_ledge`, record + counters.
4. `parkour_controller`: anchored HANG / shimmy / corner / release / verified climb-up.
5. `debug/parkour_ledge_test.gd` + `world/main.gd` flag + `tools/run_suite.py` registration.
6. Docs (`docs/`, `DEVELOPMENT.md` note) + final report.

## 4. Verification commands
```
tools/run_suite.py --parkourledgetest      # new
tools/run_suite.py --smoke --animclimb --animationtest
tools/run_suite.py --citytest --cityruntime
```
Windowed evidence (the 3-iteration visual limit applies): `--parkourledgetest --visual` capture of a real cornice→parapet chain, PNG sent to the user.

## 5. Limits / open items
- Sills visual-only (§2.3).
- `drainpipe` climb is a vertical hold; if no suitable pipe exists on a facade, that route simply does not exist — pipes are never promoted to ledges.
- No new animation was authored: HANG/SHIMMY/CLIMB_UP clips already exist in `CharacterLocomotion`; this work makes the *body* obey them.
- Resume pointer: start at stage 2 unless the tags already exist in `git log`.


## 6. Result — session 2 (2026-09-13), `--parkourtest`

Continuation harness of record: `debug/parkour_contract_test.gd` + flag `--parkourtest`
(`world/main.gd`, registered in `_should_show_main_menu`'s `test_flags` so the main menu never
eats the run). 43 checks, **43 PASS / 0 FAIL**, `exit=0`:

```
python tools/run_suite.py --parkourtest 300      # -> --parkourtest exit=0 elapsed=14s
```

### 6.1 Rules A–H verified against real collision geometry (not unit stubs)
Every case builds real `StaticBody3D`+`BoxShape3D` fixtures and asks the real controller; the
survivor is a real `Survivor` with its own locomotion. Survivor stands `z=0.55` from the face —
inside `LEDGE_PROBE_REACH 0.62`, which is the whole point of the probe.

Accepted (12 accepts / 13 rejects in the run's own ledger):

- `0.24 m` cornice band (`vox_tag: cornice`) → hold, `kind=cornice`, rise `1.5`, width `6.0`,
  **`stand_clear=false` → handhold, not a floor** (rule G; the wall behind leaves no landing).
- Awning deck `2.4 m` deep (`vox_tag: awning`) → `kind=awning`, usable depth measured `1.55`
  (capped by `HOLD_USABLE_MAX`, wall found inboard), **`stand_clear=true` → mantle target**.
- The route chain: street → awning deck (rise `2.0`) → balcony (`2.1`) → roof edge (`1.6`) =
  `5.7 m` climbed in three verified hops, each inside one arm reach (`≤ 2.1`).

Rejected (each with the reason recorded on the record):

- blank 6 m facade, storey seam (two stacked cells), `0.08 × 0.10 m` decorative trim,
  `0.3 m`-wide block (no usable width), a box buried inside the wall, a `3.3 m` lip (out of
  reach — and the *same* lip verifies once the body is lifted to `2.2 m`, so it is the reach
  rule that rejects, not a missing hold), a band whose top is covered (the covering slab is
  what surfaces instead).

### 6.2 Defect found and fixed this session — the shimmy had no honest drive
`character_locomotion.gd` derives its shimmy velocity from `strafe_val` (`survivor.gd:549`,
`dir2` at `:654`), and `survivor.gd:677` re-aims `facing` at the move direction. So a player
holding a lateral direction turns to face it, the strafe reads `0` on the next frame, and the
shimmy dies after one frame: **195 frames in `SHIMMY` state, 0.010 m of travel** (measured
before the fix). The verified width of the hold was never consulted.

Fix, kept inside `parkour_controller.gd` (no cross-track edit): the anchored hang drives the
travel itself along the ledge axis the survivor actually moves on
(`(-wall_normal).cross(UP)`), at `SHIMMY_DRIVE_SPEED 0.60`, from the player's tangential
intent (`_move_dir` projected on that axis), clamped to the **measured** `usable_half_width`.
Measured after the fix: **travel `1.200 m` = the measured half-width `1.200 m`**, `shimmy_ends
= 1` (the ledge-end event fires where the geometry ends), `shimmy_ticks = 176`.

### 6.3 Anchored hang verified (no teleport, no sinking)
Driven case: real survivor walks in, jumps (`try_jump`), grab latches a verified hold
(`grabs 1→2`), 201 frames of hang: worst per-frame step `0.125 m` (< 0.35), worst per-frame
`Δy 0.106 m` on the first frames then settled (< 0.02 settled), total drift `< 0.20`,
worst lip gap `0.114 m`, `hang_ticks 388`, recorded hold `kind=cornice`, `anchored=true`.

### 6.4 Harness lessons (kept in the test so the next session does not repeat them)
- The chest rays only reach `0.62 m`: a probe from `1.6 m` off the face returns `{}` and the
  case silently "proves" nothing. Probe distance is part of the contract.
- The scan casts down from `feet + 2.25`, so it finds the **highest** hold inside the window,
  and a lip whose top sits inside `[feet+1.2, feet+2.25]` is not detected from that stance —
  it is detected from the airborne pose that actually asks the question.
- Scenario isolation: tearing a fixture down does not tell the state machine the hill is gone,
  and `_climb_floor_y` (anti-recatch) survives cases; both are reset per case, the grab path is
  muted (`_ledge_cooldown`) while the fixture question is asked, so the counted grab comes only
  from the jump.

### 6.5 Still open in Q2 (honest)
1. **Stage 2 — tags in the generator** (§2.3): `mesh_batcher` already stamps the whitelist
   (`cornice, awning, balcony, scaffold, ...`), but `building_builder.gd` does not yet emit
   `parapet`/`band`/`bulkhead` owner tags, so real generated roofs/bands classify by geometry
   (`structure`/`prop`) rather than by kind. Tags only classify — geometry still decides.
2. **§2.4 section 2 — real buildings**: the lattice census over `BuildingBuilder.build` output
   (≥ 8 buildings, ≥ 3 seeds) with per-kind accept counts and non-uniform route diversity is
   not written yet; today's evidence is fixture-based.
3. **§2.4 section 3 — real climb**: the full street→roof drive on a *generated* building.
4. **§2.4 section 4 — determinism**: the matrix re-run to an identical record.
5. Docs (`docs/`, `DEVELOPMENT.md` note) for the feature-tag contract.
6. Windowed confirmation of the cornice→parapet chain (3-iteration visual limit; PNG to user).
