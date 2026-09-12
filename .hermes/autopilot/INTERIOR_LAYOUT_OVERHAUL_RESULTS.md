# Interior Layout Overhaul — Results (branch `copilot/worldgen-fix`)

Companion to `INTERIOR_LAYOUT_OVERHAUL.md`. The long-form design document describes the
grammar and the decisions; this file records what the generator actually does now, measured
over the floorplan probe, and what is still open.

## How to reproduce

```
python tools/run_suite.py --floorplanprobe 420 --fp-seeds 6 > .hermes/probe_runNN.log 2>&1
python .hermes/tools/reject_stats.py  .hermes/probe_runNN.log   # reject totals by kind
python .hermes/tools/reject_heads.py  .hermes/probe_runNN.log   # metrics + reject heads
python .hermes/tools/render_floorplans.py                       # top-down PNG sheets
```

The probe generates 108 buildings / 312 floors of residential, commercial, civic and work
buildings across 6 seeds, then reports plan validity, coverage, circulation share, facade
quality and the per-archetype reject set.

## Headline numbers (probe run 21, 312 floors)

| Metric | Value |
| --- | --- |
| Floors planned by the new archetype planner | 290 / 312 (93%) |
| Floors still falling back to the pre-overhaul planner | 22 (7%) |
| Rooms / doors / sealed walls | 2000 / 1708 / 1348 |
| Overlapping rooms | 0 |
| Sliver rooms | 0 |
| Bedroom used as a corridor | 0 / 290 |
| Major rooms with the principal facade | 70.6% (507 of 718) |
| Circulation share (archetype floors) | 0.39 |
| Planner rejects | 22 (12 pre-archetype, 10 shallow-plate reachability) |

Trajectory across the session, for context on how the numbers moved:

* `legacy_floors` 262 → 149 → 98 → **22**
* `facade_principal` 0.133 → **0.706**
* slivers / overlaps: **0** throughout the final passes

## Architecture as built

`world/generation/floorplan/` — the planner package:

* **`floor_plan_frame.gd`** — turns the caller's parameters (rect, open faces, door edge,
  core rect, floor index, use) into the local, mirrored, normalised plate the planner works
  in. Owns `face_open`, `has_core`, `core`, `entry` and the frame→world transform, so the
  planner never has to reason about world orientation.
* **`floor_program.gd`** — building use + floor index → **floor role**
  (residential / commercial / civic / work), and the room programme that role wants.
* **`floor_plan_planner.gd`** — 11 archetypes, the skeleton (circulation first), the room
  bands, the programme assignment, the boundary/door pass and the validator.

The grammar the archetypes share, in the order it runs:

1. **Circulation core first.** The party-wall corridor (a spine down one side, or a corridor
   down the middle on wide plates) is laid out before any room exists, then the stair.
2. **Stair band.** A full-width stair band crosses the plate at the stair; the shaft's own
   footprint is not floor anyone walks on, so it is excluded from both numerator and
   denominator of the circulation metric, while the rest of the band counts as genuine
   circulation (landing + cross-hall).
3. **Room bands.** Full-depth room slabs in front of and behind the stair band, each with
   street and courtyard windows. Kitchen/service go to the courtyard side, living to the
   street, bedrooms between.
4. **Entrance.** Every floor has exactly one street entry: the corridor cell that touches the
   open street face is the entry, or a small entrance hall is created for it
   (`_ensure_entry`).
5. **Validation before geometry.** Overlap, containment, sliver, coverage, circulation share,
   facade quality and reachability are all checked on the cell graph; only a valid plan is
   handed to the wall/door builder.

Archetypes (order = preference): `prague_narrow_townhouse`, `prague_side_spine_flat`,
`prague_deep_tenement`, `prague_compact_flat`, `courtyard_double_front`,
`shopfront_rear_service`, `tavern_taproom_ground`, `office_corridor_suite`,
`civic_reception_hall`, `workshop_hall_ground`, `warehouse_loading_ground`.

Applicability is gated by role, footprint width/depth, area and open-face count; candidates
are then scored, so a building picks the archetype that fits its plate rather than being
forced through one shape.

## Decisions worth carrying forward

* **The band's full width must stay circulation.** Carving rooms out of the stair band
  severs the room slabs directly behind them from circulation — those slabs then have no
  edge to a circulation cell, and the reachability gate rejects the plan. A pocket beside
  the stair (a WC on the landing) is only safe in the column that a full-depth corridor
  already serves.
* **Circulation cap depends on what the floor carries.** A stair floor owns its landing and
  the cross-hall that serves both room bands (cap 0.40); a floor without a stair is held to
  0.34. Fighting the geometry to satisfy 0.34 on a 115 m2 tenement floor only produced
  rejects of plans that were architecturally correct.
* **A bay must not become pure circulation.** When the tail behind the stair is too thin to
  be a room, the stair hall takes it — but capped at the stair's own depth plus a landing;
  an entire full-depth bay of hall is the "giant lobby" failure this overhaul exists to kill.
* **A shallow street strip is not a corridor.** On shallow plates a street-edge strip around
  1.2 m deep cannot hold a door and the circulation component splits (the 10 remaining
  rejects). The fix is a minimum depth for a circulation strip (or letting the full-width
  entrance hall absorb it), not a looser reachability test.

## Known limitations

1. **22 floors (7%) still fall back to the pre-overhaul planner.** 12 of them never reach
   archetype selection and the old builder reports no reason for declining (the pre-overhaul
   path has no diagnostics); 10 are shallow residential plates with the 1.2 m street strip
   described above.
2. **Circulation share (0.39) sits at the cap.** It is the honest cost of a party-wall
   corridor plus a full-width stair band with a landing that every room slab opens onto.
   Landing-side WCs and store cupboards are the obvious next reduction.
3. **The probe covers 6 seeds / 312 floors.** Larger sweeps would tighten the reject
   statistics; the harness takes `--fp-seeds`.
4. **Door placement in the boundary pass still uses a minimum shared-edge length.** That is
   what produces limitation 1's shallow-strip failure; a circ-to-circ passage rule would
   remove it.
