# QUEUED TASKS (Ring Bell) — do these in order; the topmost unfinished entry wins

Recorded so any model can resume. Each entry: user directive (verbatim where it constrains
behaviour), required pre-work, and the definition of done. **Do not start a lower entry while
an upper entry is unfinished.**

---

## Q1 (ACTIVE) — Performance: make the game "flawless and lagless"

User (verbatim): "please optimize the game performance without sacrificing front end what
player perceive. current FPS is like 4-5 in my RTX 5060 16gb ram SSD drive AMD Ryzen 7 350.
It should be flawless and lagless. Optimize the performance to ensure the game is extremely
smooth but with good front end graphics."

State so far (measured, not assumed): `--perftest` on the real streamed ring shows a FLAT
5.0 FPS in every configuration — volumetric fog / glow / depth fog / sun shadows / MSAA /
all 3,836 lights / ALL mesh instances (66 draw calls) / render scale 0.6 — identical 5.0.
So the frame is NOT raster-bound and no visual setting needs to be sacrificed.
Live-ring inventory: nodes=165,517, render_objs=11,272, StaticBody3D=8,254, lights=3,836,
draws=7,222, prims=3.74M, memory_static=2.7 GB, video_mem=685 MB.
ms_process≈11.6 ms, ms_physics≈24.3 ms per STEP; focus=true, vsync=1, max_fps=0.
Per-chunk flush: mesh≈47 ms for 20–25 k boxes; collision=0; assets=0 (`queue_asset_wall`
is test-only, the live city never calls it).
Next: physics-axis isolation (physics hz 30 / all script ticks off / static bodies out of
broadphase) — whichever stage moves FPS names the true bottleneck. Fix that systemically.

---

## Q2 (QUEUED, after Q1) — BUILDING PARKOUR / CLIMBING OVERHAUL

User (verbatim): "After all earlier queued tasks finish, continue from latest pushed
copilot/worldgen-fix HEAD. Overhaul BUILDING PARKOUR/CLIMBING into systemic
Assassin's-Creed-style traversal based on LOGICAL physical ledges. FIRST inspect current
code/generated architecture and write a detailed continuation plan in .hermes/plans/ so
another model can resume. Then implement, test, COMMIT AND ALWAYS PUSH."

### GOAL
"climbing must be visually predictable. Do NOT make every wall climbable. Traversal must use
real believable holds from generated architecture."

### Inspect at minimum (before proposing anything)
- `actors/traversal/parkour_controller.gd`
- `actors/survivor/player_controller.gd`
- `components/animation/*`
- `world/generation/building_builder.gd`
- `world/generation/building_archetype.gd`
- `world/generation/historic_facade_plan.gd`
- `world/generation/roof_plan.gd`
- `world/streaming/mesh_batcher.gd`
- `camera/follow_camera.gd`
- relevant `debug/` tests

### CLIMBABLE FEATURES (the only legal holds)
window sills / substantial surrounds, cornices, balcony edges & rails when reasonable,
awnings, scaffolding, suitable drainpipes/pipes, masonry projections/bands, parapets,
bulkhead edges, ladders and explicitly generated ledges.
"Blank plaster/brick walls are NOT climbable merely because a ray hits them."
"Tiny decorative trim must not become a hold unless dimensions physically support it."

### ONE robust local ledge-query system
- detect ledge front/top, usable width/depth, surface normal
- validate vertical/lateral reach, clearance above hands/head, player capsule at
  destination, and unobstructed path
- reject backside/underside grabs, through-wall grabs, tiny ledges, impossible jumps
- use semantic feature tags to identify candidates, then VERIFY ACTUAL GEOMETRY
- deterministic and FPS-independent
- "bounded local probes only; no expensive whole-building search every frame"

### MOVEMENT
ground -> jump/grab -> hang -> climb/mantle; hang -> horizontal shimmy; hang -> reachable
higher/lower ledge; continuous corner traversal when geometry supports it; facade features ->
balcony/scaffold -> roof; roof/ledge -> drop-to-hang where valid.
"NO teleporting between distant holds." Keep body/hands aligned to real surfaces, maintain
sensible wall offset, prevent clipping. "Failed reaches must cleanly fail/fall instead of
snapping."

### PROCEDURAL ROUTES
Buildings must "naturally provide non-uniform climb routes rather than artificial ladders
everywhere." Routes may emerge as sill -> cornice -> balcony/awning/scaffold -> upper ledge ->
parapet. Multi-storey archetypes must generate plausible routes "without making every facade
trivially climbable."

### ANIMATION
Integrate with the existing locomotion/climb system: jump-to-grab, hang idle, shimmy, corner
transition, climb-up/mantle, drop. Prevent detached limbs, sinking, snapping, foot sliding,
or animation fighting CharacterBody transforms. "Do not regress hijab/gamis cloth."

### CAMERA / BUILDINGS
"Stay compatible with the fixed cutaway/interior/roof system. Exterior climbing must never
trigger incorrect interior cutaway or make roofs disappear." Camera follows vertical
traversal smoothly.

### TEST ACROSS MANY BUILDINGS / SEEDS
valid ledges accepted; blank walls rejected; blocked/unreachable ledges rejected; capsule
destination clearance; no through-wall grabs; no large teleport; chained ground-to-roof
routes; corners; roof mantle / drop-to-hang; no regressions to doors/interiors/streaming/
destruction. Manually window-test several historic/retail/residential buildings street -> roof.

### CLOSE OUT
"Fix SYSTEMIC rules, not one showcase building. Update docs/tests/build result, then COMMIT
AND PUSH. Report exact commit hash, tested routes/buildings and genuine remaining
limitations."

---

# Q3 — PROCEDURAL BUILDING INTERIORS overhaul (user, queued after Q1 + Q2)

Continue from the then-current `copilot/worldgen-fix` HEAD. FIRST inspect current code and
write a detailed continuation plan in `.hermes/plans/` so another model can resume. Then
implement, test, COMMIT AND ALWAYS PUSH. **Fix generation rules, NOT one showcase building.**

GOAL: replace empty/shell-like interiors with systemic multi-floor layouts matching each
building's footprint, entrances, windows, stairs and archetype.

INSPECT AT MINIMUM: `world/generation/building_builder.gd`, `interior_plan.gd`,
`historic_interior_plan.gd`, `building_archetype.gd`, `building_spec.gd`, `city_plan.gd`,
`roof_plan.gd`, `world/streaming/chunk_builder.gd`, `world/interior_probe.gd`, relevant
debug/tests.

MULTI-FLOOR: meaningful interiors on ALL appropriate floors, not only ground-floor
residential. Every floor connects logically to stairs/landings and roof access where
applicable. No sealed rooms, impossible corridors, floating partitions, or stairs opening
into walls.

ROOM LOGIC BY ARCHETYPE:
- residential: entry/common space, kitchen, bedrooms, storage, washroom; attic/cellar where suitable
- retail: storefront, counter/service zone, backroom/storage, staff/access; upper residence/office when plausible
- workshop/industrial: work floor, storage, service space, office
- civic/large historic: halls, offices/rooms and wider circulation
Do not make every floor identical.

ARCHITECTURAL RULES: respect exterior windows/doors; partitions must not cut through windows,
entrances or stairs; realistic corridors, doors, player-capsule clearance, useful circulation.
Avoid both giant empty boxes and tiny random mazes.

VERTICAL SPACES: deterministic basements/cellars and attics where geometry permits, with real
stairs/hatches/doors. Attics must respect roof/headroom; basements must not conflict with
terrain/underground systems.

FURNITURE: placed by room purpose, not random scatter. Sensible placement and clearance.
Preserve critical paths entrance -> circulation -> stairs -> rooms.

EXPLORATION: generate semantic candidate points for future loot/interactables (cupboards,
desks, shelves, wardrobes, shop backrooms, workshop storage, attic/cellar storage). Do NOT
build a full loot economy unless already supported — provide clean metadata/hooks.

VARIETY: deterministic seed-based variation; same archetype yields varied but valid layouts.
Prefer strong layout grammars/templates with constrained variation over pure randomness.

COMPATIBILITY: do not regress doorway clearance, camera cutaway, roof transitions,
parkour/climbing, destruction, streaming/performance, or interior lighting.

TEST MANY seeds/sizes/archetypes: all intended floors generated; entrance->interior access;
stair continuity; no sealed required rooms; no partition/window/stair conflicts; capsule
clearance; furniture not blocking critical paths; valid attic/basement access; deterministic
same-seed output; acceptable performance. Manually window-test several residential, retail,
workshop and historic buildings street -> rooms -> upper floors -> attic/roof/basement where
applicable. Fix SYSTEMIC causes. Update docs/tests/build result, COMMIT AND PUSH. Report
commit hash, supported interior archetypes, tests run and genuine remaining limitations.

Note: Q3 shares subject matter with Q1 (buildings/interior/camera) and Q2 (parkour). Q1's
locked decisions (kind-based door widths, HARD-CUT camera-side-only cutaway, `floor_i == n`
= roof/exterior) and Q2's climbable-feature rules remain binding on Q3.
