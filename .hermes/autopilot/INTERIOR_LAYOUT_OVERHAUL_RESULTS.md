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

**Status update (run 22): limitations 1 and 4 are fixed; the list below is kept
as the record of what was wrong and how it was closed.**

1. ~~22 floors (7%) still fall back to the pre-overhaul planner.~~ **Closed.**
   12 of them never reached archetype selection and the old builder reports no
   reason for declining -- that was a *probe* defect, not a planner one: the
   probe read the planner's static `last_reject` after the fact, so for a floor
   the planner was never consulted about it printed whatever the previous floor
   left behind (usually the empty string). The probe now states that case
   explicitly. The remaining 10 were shallow residential plates hitting
   limitation 4, now gone. The floor count on the pre-overhaul path is down to
   **12 / 312 (3.8%)**, and every one of them is the probe's deliberate
   `small_below_threshold` footprint.
4. ~~Door placement in the boundary pass still uses a minimum shared-edge
   length.~~ **Closed (run 22).** Every boundary went through `DOOR_EDGE_MIN`
   (1.25 m, sized for a door leaf plus jambs), so a 1.19 m edge between a
   landing and a corridor was **sealed** -- and because the reachability gate
   requires circulation to be one connected component, the whole plan was
   discarded. Fix: `PASSAGE_EDGE_MIN = 1.15` (0.95 aperture plus slim jambs),
   applied only where **both** cells are circulation. A landing and its
   corridor are one space, not two rooms with a door between them.

### Run 22 metrics (supersedes the table above)

| Metric | Value |
| --- | --- |
| Archetype-planned floors | **300 / 312 (96.2%)** |
| Pre-overhaul fallback | **12 (3.8%)** -- all `small_below_threshold` |
| Rooms / doors / sealed walls | 2020 / 1718 / 1388 |
| Overlaps / slivers / bedroom-as-corridor | **0 / 0 / 0** (of 291 bedrooms) |
| Circulation share | 0.385 (archetype floors 0.389) |
| Principal room on best facade | 69.8% |
| Distinct reject reasons | **1** -- the below-minimum fallback, stated as such |

**The remaining 12 are not failures.** They are the probe's
`small_below_threshold` footprint, deliberately smaller than
`FloorPlanPlanner.MIN_INNER`; such a plate cannot hold circulation *plus* a
programme, so `_plan_applies()` declines it and the single-room path is the
correct answer. The boundary is intentional and now reports its own reason.

**Still unshipped, stated plainly:** the PNG visualiser does not outline the
entry cell (the entry is present in the plan data, it simply is not drawn) --
the one §14 checklist item outstanding. And the 12 below-minimum floors route
through the pre-overhaul path rather than a dedicated minimal-plate archetype;
adding one is the obvious next quality step, not a defect.

