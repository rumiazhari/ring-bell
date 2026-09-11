# Historic core morphology (Prague grammar)

Reference for the historic-core overhaul: the plan-layer grammar, its IDs and ownership
rules, the RNG domains, the measured distributions, and the known limitations.

Baseline: the overhaul started from `7b92460`. All of it is PLAN work in
`world/generation/` — pure, deterministic, no scene tree, no global RNG.

## Reference constraints

IPR Praha's [Historic Centre critical catalogue](https://iprpraha.cz/assets/files/files/577271ac73f60a8670dbfc7577b13497.pdf?v=1740488409), section Public Spaces, p. 92, treats the connected street/square system, continuous building fronts and the medieval structure's later compositional changes as heritage values. This supports deriving land faces from streets and keeping entrances connected to public space. It does not supply a universal street-width distribution.

IPR's [Prague Public Space Design Manual](https://iprpraha.cz/assets/files/files/baa0012499e8264b1a66a7854e6c289c.pdf), D.1.1, p. 129, supports stone paving in the historic city and recovering historic paving covered with asphalt. Existing setts/paving atlas materials and batched paving are reusable; a new texture system is unnecessary.

Michael Rykl and Ladislav Bartoš, [Too many portals and staircases: houses 506 and 507 at Havel's Market](https://www.staletapraha.cz/incpdfs/pha-201802-0001_10_001.pdf), Staletá Praha 34(2), 2018, pp. 2–49, English annotation and German summary: the documented original plot is 13 m wide. Its passage house was subdivided, gained rear wings and changed stair positions, then was reunited. The study describes longitudinal room sequences, courtyard access, commercial frontage competing with stair space, and distinct basement circulation. This supports persistent plots containing changing wings and circulation. One documented 13 m plot is evidence for a plausible example, not a citywide mean.

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
- `HistoricInteriorPlan` — stair hall + three longitudinal zones (≥6.6 m wide wings), or a
  shaft column with flanking rooms for narrower wings; `GROUND_PROGRAMS` gives each use real
  room kinds.
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
- `WorldSeed.GENERATOR_VERSION` is **4** (was 2): the historic street topology, persistent
  plots and compound ownership all change generated worlds, so a ≤3 world must not be
  silently regenerated as this one. `SaveManager` stores `generator_version` in save
  metadata and reports a mismatch instead of reinterpreting an old save.

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

Interiors — a normal floor is a small number of real rooms, not a door maze:

- substantial rooms per front-wing floor: p10/50/90 = 2–3/4/8 (large corner plates only
  reach 8); service spaces (toilet, stores) are separate and never counted.
- occupied room area p10/50/90 = 15.5 / 19.8 / 27.2 m² against the 12–22 m² normal band;
  principal-room median 24.7 m² inside the 22–40 m² principal band.
- rooms under 8 m²: 0.5%; rooms with more than two connections: **0**; interiors failing
  the geometry/connectivity contract: **0**.
- entry hall is a real 1.5–2.0 m passage beside the stairwell column (median 2.00 m);
  partition openings are clamped to 1.3–1.6 m; a floor is cut by repeated halving, so a
  90 m² flank becomes four ~22 m² rooms and no partition may leave a piece below 12 m².
- 92–93% of normal floors contain an ≥18 m² room with at most two doors (a manoeuvre
  room), and the door graph is a tree: bedrooms are never mandatory through-routes.

Street wall and density:

- historic block footprint coverage **0.591–0.627** (bar 0.55–0.75) — PASS.
- unclassified residual void **0.000** of block perimeter (bar < 5%) — PASS; party walls
  are 1.1–1.2%, i.e. ~90% of every block perimeter is genuinely buildable street frontage.
- buildable street-frontage continuity **0.663–0.695** (bar 0.85) — NOT MET.
- blank frontage runs longer than 15 m: **127–148 per city** (bar 0) — NOT MET.
- where the missing frontage lives, measured: 2.9–3.5 km of it is internal street wall
  (historic fabric stands across the street) and 2.0–2.2 km is the core boundary, where
  this grammar hands over to the generic fringe and no historic plot is expected.

Façades — openings derived from the actual rooms and the ground-floor use:

- 100% of historic street wings carry a room-derived façade plan (929/929 and 877/877),
  and every one of them differs from the legacy evenly-spaced rule (the materializer
  consumes `spec.facade_plan` through `city_window_openings`).
- ground-floor shopfronts appear on 60% of street wings (562 and 530); service rooms get
  small high openings, chambers get 1.25–1.55 m windows on the spacing of their own room
  width.

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
