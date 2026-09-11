# Ring Bell — Procedural urban buildings / interior / camera: continuation plan

**Written:** 2026-09-12 · **Status:** plan only, no implementation yet · **Owner of next step:** any model

## 0. How to use this document

Sections 1–3 are the state of the world **as verified by direct inspection**, with
`file:line` anchors. Section 4 lists what I did **not** read, so nobody mistakes
an assumption for a fact. Sections 5–8 are the four workstreams with the rules,
the files to change, and the evidence each must produce. Section 9 is the exact
order of operations for a resuming model. Section 10 is decisions that are the
user's, not the implementer's.

House rules that apply throughout (from the project's own doctrine):

- Fix **systemic procedural rules**, never one example building.
- **Measure, don't eyeball**: a claim is only real when a headless audit prints a
  number that would change if the code regressed.
- Do not weaken global collision to make a local problem disappear.
- Keep performance, parkour, destruction and streaming intact.
- Nothing counts as done until it is **committed and pushed**, with the SHA read
  back from the remote.

## 1. Repository / branch state (read this before your first commit)

- Remote: `https://github.com/rumiazhari/ring-bell.git`. Remote default branch
  read-back during this session: `b256287` (master).
- Work done immediately before this plan landed on **`copilot/worldgen-fix`**,
  which at the time of writing is **28 commits ahead of master** and contains the
  procedural **tree system** (`dccd8eb`) and the **site envelope contract**
  (`49ec12d`) plus everything that was already on that branch.
- The user's instruction for this workstream is “continue latest pushed
  master”. Those two goals conflict: starting from master loses the tree and
  site work; starting from `copilot/worldgen-fix` is not master.
  **Recommendation:** branch from `copilot/worldgen-fix` (so the world work is
  continuous) unless the user explicitly wants master fast-forwarded first.
  This is decision D1 in section 10 — do not silently pick one.

## 2. Current architecture (verified)

### 2.1 Interior cutaway — the real one already exists

```
world/main.gd:_update_city_interior()
  -> InteriorProbe (interior boundary, valid storey, hysteresis)
  -> InteriorProbe.faded_facades(player_xz, camera_xz_rotated_into_building_space)
  -> chunk_manager.apply_floor_gate(coord, tag, max_floor, faded)
  -> MeshBatcher.reveal_layer_hidden(layer_key, tag, max_floor, faded)
     MeshBatcher.reveal_asset_hidden(asset_def, tag, max_floor, faded)
```

- `world/streaming/chunk_manager.gd:1646` `apply_floor_gate(coord, tag, max_floor, faded)`
  records the request even for non-resident chunks and replays it on
  `_materialize()` — good, keep this contract.
- `chunk_manager.gd:1682` builds `asset_def` including `"roof": bool(asset.get_meta("asset_roof", false))`.
- `world/main.gd:869` (approx, inside `_update_city_interior`) computes
  `new_faded = InteriorProbe.faded_facades(p, local_camera) if floor_i < n else []`
  — **the facade fade is camera-sector driven already** (the camera position is
  rotated into the building's local space, so rotating the camera swaps which wall
  fades). This is exactly the Project-Zomboid/Sims-4 behaviour the brief asks for;
  it needs hardening and verification, not a rewrite.
- Visibility is applied with `(node as MeshInstance3D).visible = not hide` and
  `asset.visible = asset_visible`. **Collision is not involved** (colliders and
  destructibles are separate nodes), which is why hiding visuals satisfies “hidden
  visuals must retain collision” — but this must be *proved* by a test, see 8.3.

### 2.2 Legacy whole-roof hide — violates the brief, must be retired

`world/main.gd:759 _update_roof_visibility()` iterates `_buildings`, tests
`rect.grow(0.4).has_point(p)` and sets `roof_nodes[].visible = false` for the whole
building the moment the player is inside its footprint. That is precisely the
“inside building = remove whole roof/upper building” behaviour the brief forbids,
and it runs **in parallel** with the sector cutaway, so both fight over `.visible`.
Plan: delete this function and its call site once the cutaway covers the same
cases (section 7), rather than layering a third mechanism on top.

### 2.3 The roof bug (`floor_i == floors`)

- `world/interior_probe.gd:42` `var n := mini(int(spec["floors"]), 8)` — the storey
  count the rest of the system uses.
- `main.gd` gate call: `chunk_manager.apply_floor_gate(owner_coord, tag, floor_i, new_faded)`
  with `max_floor = floor_i`, i.e. **every layer tagged above the player's storey
  is hidden — including the roof layer** when the player stands on the top storey
  or parkours onto the deck. The roof deck is not an interior.
- Consequence user reported: final stairs/parkour roofs disappear. Fix belongs in
  the gate semantics (roof is exterior for visibility purposes), not in a
  one-off `if`.

### 2.4 Doors and entrances

- `world/generation/building_builder.gd:37` `const DOOR_W := 1.5` — the single
  global door width. The brief wants believable single doors ~1.0–1.1 m, with
  wider only when intentional (double/shop/portal/cart doors).
- `building_builder.gd:39` `DOOR_FRAME := 0.06`, `:220` `PORTAL_LINTEL_EXTRA`,
  `:329` `door_w = spec.get("door_w", DOOR_W)`, `:403`/`:407` aperture + interior
  casing emission, `:750` `_add_door(..., door_w, door_h, extra_edges, spec)`.
- `building_builder.gd:1084` already has a pilaster/doorway clash test
  (`< DOOR_W * 0.5 + PIL_W * 0.5 + 0.18`) — evidence that facade dressing can
  legitimately collide with the aperture; the brief's “suspect pilasters/cornices”
  is a real risk and this is the first place to verify, not to assume.
- `world/buildings/door.gd` — `class_name Door`, manifest-driven, frame +
  RigidBody3D leaf + HingeJoint3D, `LAYER_ENVIRONMENT`, stall/stall-tick logic.
  Doors are physical; an oversized `door_w` therefore also widens aperture,
  lintel, casing and collision together (the brief's “keep aperture/leaf/frame/
  collision consistent”).
- `CityPlan` assigns `DOOR_W = 2.6`-class widths for city houses (the building
  contract audit rejects them as “entrance width 2.60 outside human scale”, 130
  occurrences) — i.e. the city door width is a *second* source of truth that
  disagrees with `building_builder.DOOR_W = 1.5`, and neither matches the brief.

### 2.5 Camera presentation

`camera/follow_camera.gd`: `PITCH_DEG -52`, `INTERIOR_PITCH_DEG -66`,
`MIN/MAX/DEFAULT_DISTANCE 6/26/16`, `INTERIOR_DISTANCE 9`, `FOLLOW_SPEED 7`,
`VERTICAL_SPEED 9`, `KEY_ROTATE_SPEED 2.4`, `DRAG_SENSITIVITY 0.0055`,
`PRESENT_SPEED 5.0` (“interior/exterior blend rate (pitch AND distance)”),
`_interior` flag driven by `camera_rig.set_interior(any_inside)` from
`main.gd:_update_roof_visibility()` (section 2.2 — note the interior/zoom blend is
currently driven by the *footprint* test that 2.2 retires; the cutaway must take
over that signal or the smooth interior pitch/zoom breaks).

### 2.6 Test flags that already exist

`--citytest`, `--cityruntime`, `--walkthrough` (`debug/walkthrough_probe.gd`),
`--doortest`, `--g10p2b-revealtest` (cutaway/reveal), `--import` pre-flight, plus
the building-contract gate `--buildingcontracttest` (currently **302 failures**:
entrance width band, terrain grounding, migration bypass/registration — the
entrance-width class is 130 of them and is in scope for workstream A).
Headless runs: `"<godot>" --headless --path . --import` first (compiles every
script), then the flag; long runs in the background with `timeout`, because Godot
hangs on exit after printing its summary (observed repeatedly: exit 124 with a
complete summary in the log). Windowed runs are required for anything that
renders (headless renders nothing).

## 3. What the brief asks for, mapped to the code

| Brief | Where it lives now |
| --- | --- |
| Doors blocked by geometry / oversized doors | `building_builder.gd` aperture+decor passes, `Door`, `CityPlan` door widths |
| Camera cutaway (Zomboid/Sims dollhouse) | `main.gd:_update_city_interior`, `InteriorProbe.faded_facades`, `chunk_manager.apply_floor_gate`, `MeshBatcher.reveal_*` |
| Hidden visuals keep collision | visual nodes vs colliders are separate — must be proved |
| Roof must not vanish at `floor_i == floors` | `apply_floor_gate(..., max_floor = floor_i)` semantics + `asset_roof` |
| Interior must stay shadowed when the roof is visually cut | `.visible = false` also stops shadow casting — needs a shadow-only path |
| Smooth follow-camera interior pitch/zoom, no popping | `follow_camera.gd` `_interior` blend, currently signalled by the retiring function |

## 4. NOT verified yet (do not treat as fact)

I read the files above only where anchored. These were **not** opened in this
session and must be read before editing: `world/generation/interior_plan.gd`
(stair/room/partition authoring), `world/day_night_controller.gd` (sun/shadow
config), `world/streaming/mesh_batcher.gd` `reveal_layer_hidden` /
`reveal_asset_hidden` **bodies** (the exact rule that decides “above max_floor”),
`world/streaming/chunk_builder.gd` (layer/asset tagging, `asset_roof`), the
furniture/prop authoring inside `building_builder.gd`, `debug/world_test.gd`,
`debug/city_runtime_test.gd`, `debug/walkthrough_probe.gd` bodies.

## 5. Workstream A — entrances and doors

**Rules to enforce (systemic, in the generator):**

- One authority for door widths. Introduce a door *kind* (`person`, `double`,
  `shop`, `portal`/`cart`, `service`) with a width band each; `person` is
  ~1.0–1.1 m. `spec["door_w"]` may only be set from a kind, never ad hoc.
- Aperture = `door_w` + jamb/frame allowance; lintel, casing, threshold,
  collider and leaf are all derived from the *same* value so they cannot drift.
- Clearance: for **every** generated entrance, the player capsule must have an
  unobstructed route from the street, through the doorway, to ≥3 m inside, on
  the ground storey. Anything decorative (pilaster, cornice, signboard, awning,
  step, furniture, prop) that intrudes into that volume must be *moved or
  clipped by the generator*, not tolerated.
- Keep the collision that already exists for the building; do not disable
  collision globally, and do not punch holes in walls to satisfy the test.

**Implementation order:** (1) read the aperture/décor passes in
`building_builder.gd` (`:1084` clash test, `:1278` offset, `:1423` entrance-side
exclusion) and the furniture pass; (2) add a single `DOOR_KIND_W` table in
`WorldConstants`; (3) route `CityPlan` door widths through it (this alone should
retire most of the 130 “entrance width 2.60” contract failures); (4) add the
clearance volume reservation *before* décor/furniture placement, so décor is
placed around it.

**Evidence:** new gate `--entrancetest` (or an extension of `--doortest`) that,
over ≥5 seeds and a sample of ≥200 generated buildings, walks a capsule from the
street through each entrance to 3 m inside and reports `entrances_total`,
`entrances_blocked`, `worst_intrusion_m`, `min_clear_width`, plus a per-door-width
histogram proving only intentional kinds are wide.

## 6. Workstream B — cutaway camera

**Target behaviour:** the building is physically complete at all times. Only
geometry between the camera and the player's current room is visually cut/faded;
opposite and non-obstructing walls stay. Camera rotation updates the cut. Upper
ceilings/floors may become visually absent for readability but must keep physics
and shadows.

**Mechanism, preferred order (all keep collision):**

1. **Render layer + camera cull mask** — put cutaway-able geometry on a dedicated
   layer and clear that bit in the *gameplay camera's* `cull_mask` while the
   shadow-casting settings stay untouched. Rendering and shadow casting are
   separate settings in Godot, so this hides geometry from our camera without
   removing it from the light's shadow pass. Preferred because it is a camera
   property, not a per-node state change, so nothing pops in the world data.
2. **`cast_shadow = SHADOW_CASTING_SETTING_SHADOWS_ONLY`** on the cut meshes —
   invisible to every camera, still occludes sunlight. Use when a mesh must stop
   being drawn entirely.
3. Fade via material alpha for the camera-facing facade only (the brief allows
   "cut/fade"), applied to the wall(s) in the camera's sector — `faded_facades`
   already computes exactly this set.

Avoid a global `visible = false` for whole storeys/roofs: that is the mechanism
that causes both the roof bug and the “interior becomes outdoor-bright” bug, and
it is also what makes shadow behaviour wrong.

**Anti-pop:** drive transitions through the existing `PRESENT_SPEED` blend;
hysteresis already exists in `InteriorProbe` (`ENTER_EPS`, `EXIT_EPS`); add a test
that sweeps the camera 360° around a player standing just inside a room and
asserts the cut set changes monotonically (no flicker) and never contains a wall
in the opposite sector.

**Evidence:** extend `--g10p2b-revealtest` (or add `--cutawaytest`) to report, per
sample: camera sector, cut set, whether the opposite wall stayed drawn, whether
geometry outside the room was affected, and monotonicity across the sweep.

## 7. Workstream C — the roof bug

- Make the roof **exterior** for visibility purposes: the gate must never hide
  the roof layer for a player standing on/above the top storey — instead, when the
  player is at or above the roof deck (`floor_i >= n`, or standing on the deck /
  parapet / bulkhead), switch to rooftop/exterior presentation for that building.
- Keep `apply_floor_gate`'s record-and-replay contract (non-resident chunks).
- Final stairs must reach a **complete, usable roof deck**; the deck, parapets,
  bulkhead and their props stay visible.
- Retire `main.gd:_update_roof_visibility()` and hand its `set_interior()` signal
  to the InteriorProbe-driven path (so the follow camera's interior pitch/zoom
  keeps working).

**Evidence:** gate `--rooftest`: ground → every storey → roof, then down again,
then a direct parkour route onto the roof; assert for each step that
`roof_visible == true` and `interior == false` once on the deck, that stairs are
traversable both ways, and that no storey is left permanently hidden after the
walk (state must not leak across buildings).

## 8. Workstream D — interior lighting

- Camera cutaway is **visual only**. A visually-cut roof/ceiling must still block
  sunlight: never rely on `.visible = false` for that (it also removes the mesh
  from shadow casting). Use the render-layer/cull-mask route (6.1) or
  `SHADOWS_ONLY` (6.2).
- Interiors must not become noon-bright when the roof is visually cut. Daylight
  enters through real windows/doors/openings; add restrained interior lights only
  where a room would otherwise be unreadable, and avoid many dynamic shadowed
  lights (cost).
- Preserve the day/night cycle's shadow configuration in `world/day_night_controller.gd`.

**Evidence:** `--lighttest` sampling N interior points across ≥3 seeds and
reporting mean luminance outside vs inside, plus per-room darkest point, so the
“interior is as bright as the street” regression is numerically detectable.

## 9. Order of operations for the resuming model

1. Decide D1 (branch base) and D2 (door width policy) — see section 10.
2. Read everything in section 4.
3. Pre-flight: `"<godot>" --headless --path . --import` (exit 0 = every script
   compiles). `--check-only --script` gives false errors on autoloads; do not
   trust only it.
4. Baseline the existing gates and record the numbers: `--citytest`,
   `--cityruntime`, `--walkthrough`, `--doortest`, `--g10p2b-revealtest`,
   `--import`. Save raw logs; they are the "before" column.
5. Workstream C first (smallest, unblocks visibility semantics), then B, then A,
   then D — or A first if the user prioritises playability. Say which you chose.
6. After each change: import pre-flight, relevant gate, and **windowed manual
   verification** (headless renders nothing; capture PNGs and send them to the
   user — the user expects the images, good or bad).
7. Update `docs/` (a contract/behaviour doc for cutaway + doors) and this plan's
   status line; add the new gates to `docs/world/BUILDING-CONTRACT.md`'s or a
   sibling doc's gate list.
8. `git add` **only** your files (this checkout carries other work), commit,
   push, then read the SHA back from the remote and report it.

## 10. Decisions that are not the implementer's

- **D1 — branch base:** master (user's literal words, loses the 28 commits of
  worldgen/tree/site work) vs `copilot/worldgen-fix` (continuous, not master).
- **D2 — door width policy:** strict 1.0–1.1 m for all person doors (may look
  narrow on historic shopfronts) vs a kind-based table where wide is legal but
  must be *justified by kind* (recommended; use kind-based).
- **D3 — fade vs hard cut** for the camera-facing facade (brief allows both;
  fade is prettier, hard cut is cheaper and never shows transparency artefacts).
- **D4 — who owns roof/eye-level exposure:** whether the roof is hidden while
  the player is *inside* the top storey (current behaviour) or always shown once
  the player is on the top storey and above.

## 11. Known debt discovered while writing this plan (in scope, but not asked for)

- `--buildingcontracttest` is **red: 302 failures** (was 418). Registered the six
  city archetypes (`narrow_townhouse`, `merged_house`, `courtyard_tenement`,
  `merchant_house`, `artisan_house`, `tavern_inn`) which took city specs from
  **0/373 to 116/373** passing; remaining classes: entrance width (130, workstream
  A), terrain grounding (~80: city `ground_y` does not follow the surface), and
  migration bypass/registration (~35). Grounding needs a plot-pad decision
  (flatten under plots vs follow terrain) and is a prerequisite for fences/yards.
- `--sitecontracttest` (new, G10-P2C site envelope contract): **42/44 checks pass**.
  Fringe yards validate 9/9. The city side derived **0 sites**, and the pinned root
  cause is now measured, not guessed: after generation `wp.city_plan._blocks` is
  **empty** (`blocks=0`, `courtyard_regions=0`, extent `(0,0,0,0)`), while
  `city_plan.gd:1179` fills `_block_by_cell[block["cell"]] = block` — so the
  populated store is `_block_by_cell`, and both `SitePlan.raw_region_count()` and
  the *existing* `CityPlan.garden_regions_in_rect()` (which iterates `_blocks`)
  therefore see nothing. Fix: read `_block_by_cell.values()` (or look up by cell
  for a rect) in both; then re-run `--sitecontracttest`. If street gardens were
  never actually planted in-game either, that is a second, larger find.
