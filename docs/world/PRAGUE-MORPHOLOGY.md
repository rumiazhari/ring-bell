# Historic core morphology (Prague grammar)

Reference for the historic-core overhaul: the plan-layer grammar, its IDs and ownership
rules, the RNG domains, the measured distributions, and the known limitations.

Baseline: the overhaul started from `7b92460`. All of it is PLAN work in
`world/generation/` — pure, deterministic, no scene tree, no global RNG.

## Reference constraints

IPR Praha's [Historic Centre critical catalogue](https://iprpraha.cz/assets/files/files/577271ac73f60a8670dbfc7577b13497.pdf?v=1740488409), section Public Spaces, p. 92, treats the connected street/square system, continuous building fronts and the medieval structure's later compositional changes as heritage values. This supports deriving land faces from streets and keeping entrances connected to public space. It does not supply a universal street-width distribution.

IPR's [Prague Public Space Design Manual](https://iprpraha.cz/assets/files/files/baa0012499e8264b1a66a7854e6c289c.pdf), D.1.1, p. 129, supports stone paving in the historic city and recovering historic paving covered with asphalt. Existing setts/paving atlas materials and batched paving are reusable; a new texture system is unnecessary.

Michael Rykl and Ladislav Bartoš, [Too many portals and staircases: houses 506 and 507 at Havel's Market](https://www.staletapraha.cz/incpdfs/pha-201802-0001_10_001.pdf), Staletá Praha 34(2), 2018, pp. 2–49, English annotation and German summary: the documented original plot is 13 m wide. Its passage house was subdivided, gained rear wings and changed stair positions, then was reunited. The study describes longitudinal room sequences, courtyard access, commercial frontage competing with stair space, and distinct basement circulation. This supports persistent plots containing changing wings and circulation. One documented 13 m plot is evidence for a plausible example, not a citywide mean.

[Mázhaus](https://cs.wikipedia.org/wiki/M%C3%A1zhaus) with the National Heritage Institute catalogue's documented disposition of a Prague burgher house (e.g. *V Jirchářích* 12: a front two-tract building with a courtyard wing set perpendicular, the *průjezd* on the central axis, Gothic barrel-vaulted cellars, *pavlače* on the courtyard wing). The mázhaus is the vaulted, unheated front room of the ground floor — the house's communication node, from which the stair to the first floor and the cellar, and the passage to the courtyard, are reached. This is the disposition `HistoricInteriorPlan` implements.

The requested 6–15 m frontage, 25–45 m depth, 3–6 typical storeys, 4–12 m courtyard span and street-width proportions are **Ring Bell design targets supplied by the user**, not statistics measured from these publications. Tests distinguish these calibration targets from geometric invariants. The city remains fictional; no source map is copied.

## The grammar

`WorldPlan → historic street graph → public spaces/landmarks → urban blocks → plots →
compounds (wings/courtyards/passages) → floor plans → rooms/stairs/cellars/roofs →
materialization`, implemented as:

- `HistoricStreetPlan` — accretion sites, anisotropic spacing, shared cell boundaries by
  half-plane clipping inside a 16-gon transition boundary; street class → width
  (alley 3.5–5.5 / local 5.5–8 / secondary 8–11 / primary 12–16 m) with roll shares
  30/45/20/5%; shared surface, cobble or stone setts; blind lanes; preserved outer routes
  cut at the exact transition polygon.
- `UrbanBlockPlan` — planarizes the real road polylines, traces bounded faces, cleans
  duplicate/collinear ring vertices (`clean_polygon`), exposes junction statistics
  (`graph_manifest`).
- `ParcelPlan` — persistent plots allocated before buildings: weighted span split for
  frontage, aspect-clamped depth, plot envelope reserving court and access, one stable
  `owner_chunk` per compound, manifest-only cellars, `historical_layer`.
- `CityPlan._historic_buildings_for_block` — plots → wing specs (`plot_id`, `compound_id`,
  `owner_chunk`, `wing_role`, `frontage_role`, `historical_layer`, `floor_uses`,
  `circulation`) with 3–6 storey street wings and one-storey-lower annexes.
- `HistoricInteriorPlan` — the Prague depth plan. Plans in a canonical frame (street facade
  on -y, stair column on the west), so all four entrance orientations get the same
  disposition: an entry passage (the *síň*) from the street to the stair, the stair column
  wrapped by a landing that reaches the courtyard wall, a street band of bays cut *across*
  the frontage, a courtyard band of bays cut across the back, and a windowless middle that
  is only ever circulation or a store (the *komora*). `DEPTH_GROUND`/`DEPTH_UPPER` give each
  use real room kinds, ordered by depth: the public front room (the *mázhaus* of a shop or
  tavern, the *přední pokoj* of a flat) carries the street door, and the working room (the
  tavern or shop kitchen, the store) sits at the courtyard end.
- `RoofPlan` — gable/hip/mansard faces per wing, ridge axis by wing role, chimney, dormer,
  attic metadata; materialized only through `MeshBatcher.add_visual_face`.

## IDs, ownership, RNG

- Plot IDs `"<block_id>_plot_<edge>_<i>"`; wing IDs `"<plot_id>_<role>"`; block IDs
  `historic_block_<n>`; roof IDs `"<spec_id>_roof"`. All deterministic and stable for a
  given seed.
- `owner_chunk = WorldSeed.chunk_coord(lot centre)` — a compound keeps ONE owner while its
  geometry may span 64 m chunks. `--praguetest` asserts zero owner-chunk conflicts.
- Domains (seed-separated, never shared across purposes): `historic_extent`, `historic_grain`,
  `historic_site_angle`, `historic_site_radius`, `historic_site_spacing`,
  `historic_street_bend`, `historic_street_class`, `historic_blind_lane`,
  `historic_plot_width`, `historic_plot_depth`, `historic_compound_form`, `historic_court`,
  `historic_roof`, `historic_ground_use`, `historic_annex_use`, `historic_upper_use`,
  `historic_height_neighborhood`, `historic_height_variation`.
- `WorldSeed.GENERATOR_VERSION` is **5** (was 4, and 2 before that): the historic street
  topology, persistent plots and compound ownership changed worlds at 4; **5** lifts it again
  because the Prague *interiors* were rebuilt to the depth plan (mázhaus/hall spine, kitchens
  against the flue, privet on every floor) and interior dressing was moved onto the walls
  it hangs on. A ≤4 world must not be silently regenerated as this one. `SaveManager`
  stores `generator_version` in save metadata and reports a mismatch instead of
  reinterpreting an old save.

## Measured distributions

Reproduce with:

```
python tools/run_suite.py --praguetest 540           # one real seed + determinism (~170 s)
python tools/run_suite.py --praguetest 600 --dist     # seeds 19041207/08/09 (~270 s)
python tools/run_suite.py --praguetest 360 --fast     # one seed, no determinism (~45 s)
python tools/run_suite.py --praguetest 300 --full     # block/plot/wing counts only
```

Seed 19041207 (407 city blocks, 58 historic-core blocks, 326 plots, 577 wings):

- streets: 197 in the core, lanes .32 / ordinary .44 / important .21 / wide .03 / oversize
  .00 against targets .30/.45/.20/.05; 100% shared surface; segments p10 4.5 m, median
  26.8 m, p90 48.4 m.
- junctions: 360 nodes, dead ends 21.4%, T/Y 38.1%, four-ways 20.6%.
- blocks: median 4776 m², aspect 1.34, rect fill 0.58, corner-right-angle share 0.31,
  **world-axis alignment 0.10** (the fabric is not an X/Z grid), 100% with ≥5 edges,
  0 slivers; perimeter edges p10 0.4 / median 18.2 / p90 41.4 m.
- plots: frontage p0 6.1 / p25 8.9 / median 10.5 / p90 13.6 / max 15.0 m, **26% in the
  narrow 6–9 m band**, 100% inside 6–15 m; depth median 26.7 m (61% inside 25–45 m);
  courtyards on 80% of plots (courtyard area fraction median 0.40); 20% of plots have no
  passage, 21% have two or more, three passage kinds present; 7% of blocks impermeable;
  historical layers medieval_core 194 / rebuilt_front 132.
- wings: front storeys 3–6 only, annexes never taller than their street wing; roofs
  gable/hip/mansard all present; ground programmes retail/workshop/tavern/storage/caretaker;
  street houses mixed-use 1.00; one compound per plot with **0 owner-chunk conflicts**.
- interiors: 24 sampled wings (narrowest first, narrowest 6.1 m, 18 below 9 m) — 0 invalid
  plans, 0 floors without stair access.
- determinism: same seed → identical block/plot/wing id hash; different seed → different city.
- cost: city generation ~41 s per seed (pre-existing generator cost, unchanged); the
  morphology analysis itself adds < 150 ms per seed.

## Gameplay and density overhaul (interiors, street wall, façades)

Reproduce with:

```
python tools/run_suite.py --praguegameplaytest 2300     # 3 real seeds, ~8 min
```

Interiors — a Prague house is a depth plan, not a door maze. The street front carries the
*mázhaus*: the unheated vaulted front room that is the house's communication node, holding
the stair, the cellar entry and the passage through to the courtyard. Chambers sit behind it
and the kitchen sits at the courtyard end, by the flue. Both flanking walls are party walls,
so light reaches a room only from the two ends of the plot. Two rules follow, and
`debug/prague_interior_logic_test.gd` (an independent audit that rebuilds openness by
probing the neighbouring lots, never the generator's own predicate) measures both.

```
python tools/run_suite.py --interiorlogictest 2400     # 3 seeds, ~2 min
```

- every habitable room reaches a facade: **97 of 19,600 rooms** (1,745 m²) fail, all of them
  in clipped "step" infill wings whose courtyard face is the neighbour's wall. Before this
  pass it was 9,419 rooms / 195,065 m²; the old plan halved zones across the light and left
  half the rooms of a deep plate with no window at all.
- the street door opens into the public front room (the mázhaus) or the entry passage: **0**
  openings into a chamber or store, **0** doors that land in no room (was 73). 98.9% of
  street wings open into a public front room ≥12 m²; across all four wing roles, 89.1%.
- **0** bedrooms are mandatory through-routes (a chamber is never crossed to reach another
  chamber). Stores and privies behind a room are the historical norm and are counted
  separately: they stay under the reported ceiling rather than being hidden.
- the kitchens sit behind the parlour: 77.3% in the rear half of the plot, and none on the
  street front. The remainder are deep narrow plots where the courtyard face is the
  neighbour's wall, so the back bay is a windowless store (the *zadní komora*) and the
  kitchen takes the second bay of the street band, the only window it can have.
- the stair column is free floor inside circulation on **every** floor (3,791/3,791), and
  every floor has its privet: 4,053 of 4,123 floors, 98.0% of them standing off the
  circulation or an outside wall.
- a floor is a small number of real rooms: substantial rooms per front-wing floor
  p10/50/90 = 1/3/4; occupied room area p10/50/90 = 12.5 / 18.4 / 25.0 m²; principal-room
  median **25.0 m²** inside the 22–40 m² band; rooms under 8 m² 1.1%; rooms with more than
  two connections **0**.
- the first bay of a floor is the big one (the *přední pokoj*), so 85.7% of normal floors
  hold an ≥18 m² manoeuvre room with at most two doors — **still short of the 90% bar**;
  the shortfall is small plates where the stair leaves under ~4.5 m of street depth.
- interiors failing the geometry/connectivity contract: **22** (from 490 mid-pass; the
  remaining cases are plate layouts where no privet host exists). Not yet zero.

Street wall and density:

- historic block footprint coverage **0.591–0.627** (bar 0.55–0.75) — PASS.
- unclassified residual void **0.000** of block perimeter (bar < 5%) — PASS; party walls
  are 1.1–1.2%, i.e. ~90% of every block perimeter is genuinely buildable street frontage.
- buildable street-frontage continuity: **0.667–0.700 building wall** plus
  **2,998–3,400 m of planted street garden** = **86.7–88.1% wall-or-garden** — the 0.85
  bar is met only by counting intentional gardens, which the brief explicitly allows
  ("blank plates must become buildings, or intentional courtyards/squares/gardens/
  service areas"); the building-only figure is NOT met.
- blank frontage runs longer than 15 m: **50–54 per city** (bar 0) — NOT MET, down from
  127–148 before the wedge/garden pass; 1.97–2.22 km of bare frontage remains (11.9–13.3%)
  against 4.9–5.7 km before it.
- the remaining bare frontage is concentrated on the core boundary, where this grammar
  hands over to the generic fringe, and in internal street wall breaks where a house that
  fits the gap also has to clear its neighbours' rear wings. Wedge tips too small for a
  stair-capable house (4.7 m wide × 9.5 m deep) are planted rather than built on, which is
  why the garden frontage is a fifth of the total.

Façades — openings derived from the actual rooms and the ground-floor use:

- 100% of historic street wings carry a room-derived façade plan (929/929 and 877/877),
  and every one of them differs from the legacy evenly-spaced rule (the materializer
  consumes `spec.facade_plan` through `city_window_openings`).
- ground-floor shopfronts appear on 60% of street wings (562 and 530); service rooms get
  small high openings, chambers get 1.25–1.55 m windows on the spacing of their own room
  width.

## Irregular infill: wedge houses, gardens and cafés

The engine publishes a rotated rectangle, so a triangular or trapezoidal ground plan
is expressed the way a real terraced row does it: as a short run of houses whose depth
follows whatever the block face actually allows. `ParcelPlan.seal_street_frontage()`
walks each uncovered run of boundary with a cursor and, at every position on it, takes
the largest lot from a width/depth ladder that fits wholly inside the block polygon and
clears every plot already placed; the cursor then advances by the lot just laid, so the
wall stays continuous and the outline steps round the corner instead of leaving the
wedge empty. Wedge houses run 4.2–21 m wide and 4–15 m deep, i.e. one to three steps
per side.

Small street-facing wedge houses carry a venue rather than a service use: a
deterministic roll gives them `tavern` (taproom/kitchen/toilet interiors, i.e. the café
and restaurant the street needs) or `retail`.

Whatever the fitter still cannot build on is not left as dirt. `_frontage_garden_polygon()`
measures the strip the block really allows, station by station, with depth probes of
3.2/2.2/1.5/1.0 m that must be strictly inside the polygon and clear of every real
footprint, and publishes the resulting world-space polygon as a `garden` region with
`access_kind: street_garden`. Those are emitted *before* the enclosed-courtyard rules,
because a wedge between two houses has no passage and encloses nothing — it would be
dropped by the courtyard test even though it is exactly the blank the city must not
have. The chunk builder draws street gardens from 3 m² upward in the planted tone, and
`_plant_garden_trees()` puts one tree per 16 m² (max three) into them, kept 1.1 m clear
of the walls they sit between.

Measured over three seeds (19041207 / 19041208 / 19041209):

- **231 / 230 / 246 street gardens** covering 8,394 / 7,651 / 8,720 m², fronting
  **3,323 / 2,998 / 3,400 m** of block boundary — i.e. 18.1–20.8% of the buildable
  street frontage is now planted ground.
- **13 / 16 / 13 stepped wedge houses**, every one of them mixed-use (café/restaurant
  or shop) and stair-capable.
- buildable street frontage: **0.668 / 0.700 / 0.667 is building wall**, plus the
  garden frontage above, giving **86.7 / 88.1 / 87.5% wall-or-garden** (the bar is
  0.85 and it is met only when intentional gardens are counted — the building-only
  figure is reported beside it and is not met).
- blank runs longer than 15 m fell from 127–148 to **54 / 50 / 50**; bare frontage
  fell from 4.9–5.7 km to **2.22 / 1.97 / 2.06 km** (11.9–13.3% of the frontage).
- the interior contract is **not clean** since the depth-plan rewrite (below):
  `invalid_interiors` 23 / 36 / 21 and 86.1–86.8% of floors hold a manoeuvre room
  (3,180/3,682, 3,265/3,761, 3,255/3,779), against `invalid_interiors 0` and
  90–92% before it. The rewrite bought the mázhaus depth plan and cut blind rooms
  from 9,419 to 97; it cost some contract headroom on the smallest plates, and
  both numbers are reported rather than traded in silence.
- cafés and restaurants: 185–193 street wings carry the `tavern` ground-floor use
  (taproom/kitchen interiors) plus 4–10 of them laid by the wedge fill itself.

## Interior plans and interior dressing

`--interiorlogictest` (`debug/prague_interior_logic_test.gd`) audits the floor
plans against the historical rules, and `--propslogictest`
(`debug/prague_props_test.gd`) audits what the generator hangs on the house:
props, doors and window dressings. Neither reuses the generator's own placement
predicate — the props audit rebuilds each building's mesh, puts every emitted box
back into footprint-local coordinates, and asks whether it stands in its own
room, collides with another prop, a door aperture, a partition or the stair
column, whether a wall-hung prop touches a wall, and whether every box is
*attached* to something (a floor, a wall, the roof or another box).

What the props audit found, and what changed:

- the broken-pane plate was emitted at `WALL_T + 0.55` from the facade — a 3 cm
  panel hanging 0.55 m out into the room with nothing under it. It now sits in
  the wall cavity just behind the glass plane.
- wall-hung dressing (wall clock, framed print, gauge) was placed on room corner
  and lattice candidates, which sit 0.22 m inside the room: a clock hanging
  0.17 m off the plaster. `InteriorPlan._hang_on_wall()` now snaps it onto the
  nearest wall, 0.11 m clear of the partition board.
- prop sub-boxes that floated free of their own prop: the fern crown sat 0.055 m
  above its fronds, cabinet/table/ceramic top slabs sat a scaled gap above their
  carcasses, the third drawer pull and the workbench vice hung off the top, and
  the gauge's pipe riser began 0.6 m above the floor — a gauge floating in
  mid-room. All now meet their own geometry.
- the staircase is exempted as an assembly: its treads and handrail are separate
  boxes that do not overlap by design.
- the legacy shutter / flowerbox / lintel families never fire in the Prague core:
  every one of the 1,274 buildings carries a `facade_plan`, and the planned path
  emits its lintel-and-sill bands aligned to `city_window_openings()` instead.
  A zero there is not a pass, so the audit samples the rest of the historic
  radius as well and reports the scope it measured.

Measured on seed 19041207 (1,274 buildings, 4,123 floors, 33,699 props, 27,207
doors, 1,632,222 boxes): `out_of_room 0`, `overlap 0`, `in_wall 0`, `on_door 0`,
`on_stair 0`, `wall_hung_floating 0`, `over_ceiling 0`; doors `to_nowhere 0`,
`sweep_solid 0`, `sweep_furniture 0`, `no_partition 0`, `outside 0`,
`wrong_rooms 5` (0.018%). Attachment: **118 boxes of 1,632,222** (0.007%) are not
connected to the shell — 62 of them 0.2 × 0.2 × 0.04 m and 47 of them
0.4 × 0.1 × 0.4 m, plus nine shop signs and plaster patches hanging on brackets
the generator does not model. No prop, door, stair, pane or sill band is among
them. Attachment is tested against wall boards and slabs within 0.45 m, because a
sill or lintel band sits inside an aperture that has no wall box of its own.

Floor-plan rules added with the interior pass:

- a landing that has swallowed the floor (a 21 m² approach beside a 9 m² parlour)
  keeps the approach to the stair and hands the surplus back as a room — but only
  where that landing already reaches the courtyard wall, since the surplus has to
  have a window.
- a floor that came out as nothing but stores and landings promotes its largest
  *facade-reaching* store to the room the floor is for. The windowless middle
  store is never promoted: that is how blind rooms would be manufactured.
- a floor too small to hold two real rooms keeps its band whole instead of
  splitting it into two rooms that are both under the manoeuvre floor.
- a floor with no privet anywhere else takes one off the landing by the stair
  (the prevét of the house that had no yard to sit over).

## Known limitations (not hidden — the harness asserts what holds and reports the rest)

- Dead-end share runs 21–27% of junctions: the blind-lane roll is deliberate but high.
- Courts are derived residual space; they are not yet materialized as courtyard paving
  patches with their own surface, and court-to-court links are plan-level only.
- Plot depth lands in 25–45 m for 61–74% of plots; the rest use the fallback ladder, and a
  fallback below the 14 m accepted-lot depth floor (`CITY_LOT_MIN_DEPTH_M`) is rejected.
- The parcel fitter (`_fit_frontage_lot`) may yield depth to 10 m, but the accepted-lot gate
  is the district standard — so a block shallower than 14 m still yields no generic lot.
- Rear-lane passages are planned but not yet rendered as a distinct surface.
- Cellars are manifest-only by design (`materialized: false`) — pending the underground
  systems.
- Façade grammar (openings from room boundaries and ground-floor use, item 13) is
  implemented: `HistoricFacadePlan.for_wing()` publishes a per-floor, per-side opening
  list on every historic wing and `city_window_openings()` returns it unchanged.
- The manoeuvre-room bar — 90% of floors holding an 18 m² room — is at 86.1–86.8%
  in the gameplay harness and 82.2% in the stricter interior audit. The shortfall
  splits cleanly: **135 floors** belong to outbuildings whose entire interior is
  smaller than the room being asked for (3.0 × 4.5 m side wings, 13–14 m²), and
  **~590 floors** sit on plates big enough to hold it, where the stair column, the
  privet and the landing leave no band 18 m² deep. Closing the first needs the
  infill layer to stop emitting 13 m² houses as buildings; closing the second
  needs the stair position to stop crowding the street band.
- Street-frontage continuity is 0.663–0.695 against the 0.85 bar. The gap is structural, not
  a metric artefact: ~300 street-wall gaps remain per city and most of them resist every
  filler. A candidate house must place its *rotated* footprint inside the irregular block
  polygon to within 0.03 m², and the space behind a gap is usually already occupied by a
  neighbour's depth; widening the neighbouring house along the same street line closes only
  a few dozen of them. Measured, ~2.0–2.2 km of the shortfall is the core boundary (no
  historic fabric across the street) and ~2.9–3.5 km is genuine internal street wall.
  Closing the internal remainder needs clipped (non-rectangular) lots, which this generator
  cannot express — lots, interiors, façades and the validator all assume a rotated rectangle.
- The legacy `actual street elevations / block perimeter` ratio prints as a diagnostic
  only (0.61–0.65). It divides covered street wall by the whole block perimeter including
  party walls and non-buildable boundary, so it cannot reach the bar even on a perfect
  street wall; the graded bar is the buildable-frontage ratio above.
