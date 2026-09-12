# Ring Bell — Procedural Interior Layout Overhaul

Development document for the interior room-placement rewrite.
Branch: `copilot/worldgen-fix` · Repo: `rumiazhari/ring-bell` · Project: `C:/Vibe Code project/Godot Project/ring-bell`
Godot: `Godot_v4.7.2-stable_win64.exe` (headless CLI used for every test below).

---

## 1. The old problem

The generator planned interiors *backwards*:

1. reserve stairs / hall / toilet,
2. compute the leftover rectangular regions,
3. subdivide those leftovers with area thresholds,
4. label the resulting rectangles with room kinds afterwards,
5. repair the result with fallback passes when it was invalid.

Symptoms the player sees: rooms that are obviously "whatever rectangle was left over",
toilets the size of a band because a leftover needed a name, oversized landings,
rooms behind other rooms with no way to reach them, ground floors that collapse into
one giant lobby plus one WC, and two buildings of the same shape planning completely
differently because different rescue passes happened to fire.

Three planners coexisted (`HistoricInteriorPlan`, `_corridor_floor`, `_floor_manifest`),
each with its own spatial logic, each with its own repair passes.

## 2. The new architecture

New package `world/generation/floorplan/`, three pure files, no scene-tree access,
no `WorldConstants` dependency (the two constants it needs are declared locally):

| File | Role |
|---|---|
| `floor_plan_frame.gd` | Canonical local frame of a floor: origin at the entrance, local `+y` inward, facade edges, stair core rect, mirroring. |
| `floor_program.gd` | The room *programme*: kind table (min/max area, min side, facade need, privacy, tier), `slots(use, floor_i, cell_count)`, `is_service`, substitute chains. |
| `floor_plan_planner.gd` | The planner: archetypes → skeleton → assignment → boundaries → validation → reachability → emit. |

Pipeline, in order (this order is the whole point — **rooms first, geometry second**):

```
footprint + floor role + entrance + stair
        ↓  pick archetype (deterministic, seeded by building id + floor)
_skeleton()      place corridor, entrance cluster, room slabs, stair core
        ↓
_assign()        programme slots → cells (facade, area, aspect, privacy, tier)
        ↓
_boundaries()    adjacency → doors (circ-circulation, then every room onto
                 circulation, then one relay hop, then seal the rest)
        ↓
_validate()      overlaps, outside, slivers, coverage, circulation share,
                 toilet cap, landing cap, facade fraction
        ↓
_reach_ok()      circulation connected; every room on circulation in ≤1 relay
        ↓
emit             plan schema InteriorPlan already consumes:
                 rooms[] / partitions[] / doors[] / boundaries[]
```

If no candidate passes, the planner reports *why* (`last_reject`) and the caller falls
back — but the fallback is now the exception, not the mechanism.

## 3. The plan grammar: the Bohemian side-corridor module

The decisive change (why the first rows-and-slabs version was thrown away):
in a party-wall town house the plate is only reachable from the street and the
courtyard. If rooms are stacked along the depth, only the front room can have a
window and the rest of the floor is windowless (`facade_principal` came out at
0.06 — 36 of 574 rooms). Real Bohemian/Prague houses solve it the other way:

```
   street facade
  ┌───────┬───────────────────┬──────────────────┐
  │ HALL  │  LIVING  (slab)   │  room  (slab)    │   ← every slab spans the
  ├───────┤                   │                  │     full depth: street
  │ SVC   │                   │                  │     window AND courtyard
  ├───────┤                   │                  │     window, full-length
  │  WC   │                   │                  │     door onto circulation
  ├───────┴───────────────────┴──────────────────┤
  │ CORRIDOR (full depth, along the party wall)  │
  └──────────────────────────────────────────────┘
   courtyard facade
```

* The corridor runs the **full depth of the plate along a party wall** — never
  through the middle of the plate, never truncated at the stair.
* Rooms are **slabs across the width**, sharing their long edge with the corridor.
  Each slab touches both facades, so no room is windowless; and each slab is one
  door away from circulation, so no room is stranded.
* The **entrance column** sits between the corridor and the first slab, at the
  street end: hall (with the entrance), service cell when the house is deep enough,
  WC at the courtyard end. Everything in the column opens onto the corridor, so the
  WC never depends on a room and never eats a room.
* A **stair core** intersects the slab zone as a column: the rooms to the left and
  right of the shaft keep their frontage, and the landing itself is a circulation
  cell, so the rooms beside it are one door from circulation.
* Wide plates get the **central spine** variant: corridor down the middle, a band on
  each side, the hall in the band the entrance opens into (the other band is rooms
  straight off the corridor — two full-width halls per floor ate half of these plates).
* Narrow plates (no room for an entrance column) keep the slabs and put the WC
  across the courtyard end of the band.

Key geometric rules the module enforces (all in `_band`, `_corner_cluster`,
`_rear_wc`, `_slice_rooms`, `_slice_x`):

* room slabs are equalised — no 2.7 m room next to a 5.1 m one (that is leftover, not design);
* the entrance column is only built when the band can still keep a real room beside it;
* the stair shaft outranks the entrance column (if the shaft stands where the column
  would go, the column is dropped and the rooms keep the street facade);
* a landing is circulation, never a room (this was a real bug: `_locked_cell` marked
  the `stair_hall` as a non-circulation cell, so every room beside the shaft came out
  doorless and the whole plan was rejected as unreachable);
* any cell thinner than 1.0 m in either direction kills the candidate (no slivers).

## 4. Archetypes (11 implemented)

Selection is deterministic and condition-based (`min_w` / `max_w` / `min_d` /
`max_area` / `min_open_sides` / `roles`), scored when several apply; the same
building id + floor + footprint always yields the same archetype.

| # | id | role | shape it is for |
|---|---|---|---|
| 1 | `prague_narrow_townhouse` | residential | one-room-wide, deep, rooms front→back |
| 2 | `prague_side_spine_flat` | residential | classic side-spine flat |
| 3 | `prague_deep_tenement` | residential | wide + deep tenement |
| 4 | `prague_compact_flat` | residential | tiny flat (≤62 m²) |
| 5 | `courtyard_double_front` | residential | open on two sides; principal room takes the best facade |
| 6 | `shopfront_rear_service` | commercial | shopfront + rear service |
| 7 | `tavern_taproom_ground` | commercial | big taproom front, kitchen/store behind |
| 8 | `office_corridor_suite` | civic | offices off a corridor |
| 9 | `civic_reception_hall` | civic | reception hall front, offices behind |
| 10 | `workshop_hall_ground` | work | workshop hall |
| 11 | `warehouse_loading_ground` | work | warehouse with a loading bay |

## 5. Programme and quality rules (`floor_program.gd`)

Per-kind spec: `min_area`, `max_area`, `min_side`, `facade` (0..2, how much daylight the
kind wants), `private` (must not be a through-room), `tier`, `service`.
`slots(use, floor_i, cell_count)` decides *what* the floor must contain (ground floors
get entrance/commercial/service slots; upper floors get residential/office slots).
Cells are scored (`_fit`) on facade access, area fit, aspect ratio, privacy (private
rooms away from the entrance), and service placement (service rooms toward the rear).
A kind is only placed in a cell that `_can_host`s it (both ways round: too small is a
sliver, too large is the "toilet the size of the band" defect); otherwise the slot is
*downgraded* along an explicit chain (living → sleeping → storage, toilet → storage, …)
instead of forcing an impossible room.

## 6. Validation gates (`_validate`, `_reach_ok`)

Hard rejects: rooms outside the plate, room overlap, cells < 1 m, coverage holes
(≥ the allowed uncovered fraction, reported with the first hole's coordinates),
circulation share over the cap (`0.34` for plates ≥ 34 m², else `0.52`), toilets over
their cap, oversized landings, facade fraction. Reachability then requires that the
circulation cells form one connected network and every non-circulation room either
touches circulation directly or relays through **one** public room — never through a
bedroom or a toilet (no bedroom-as-corridor).

Every rejection is self-describing: `_boundaries`/`_reach_ok` failures dump the
failing room's rect, its full adjacency with door markers, the circulation rects, and
the **entire skeleton** (`_cell_dump`, index:kind(x,y,w,h,circ,lock)). A reject that
cannot be localised is a reject that gets patched blind.

## 7. Integration with the live generator

* `world/generation/interior_plan.gd` — `_archetype_floor(bid, fi, use_val, spec, fh)`
  runs the planner and converts its output into the existing plan schema
  (`partitions` / `doors` / `rooms` / `kind`), so nothing downstream has to know the
  planner exists. `uses_archetype_plan(spec, floor_i)` is the compatibility gate;
  `_open_by_plan_edge()` feeds the opening set.
* `world/generation/building_builder.gd` — `circulation_keepouts(spec, floor_i)` branches
  on the gate so the wall emitter does not clip the new layouts.
* `world/main.gd` — `--floorplanprobe` CLI flag for the statistical harness.
* Walls and doors are still generated *from* the finished plan, never independently
  (`partition_id` + `open_faces` per edge). The planner emits an `opening` rect covering
  the plan's wall slab so the existing door pivot work stays valid.
* Determinism: all choice is index/seed driven from `str(building_id).hash()` + floor;
  no `randf`, no time, no iteration over unordered dictionaries in a decision path.

## 8. Debug tooling

* `debug/floorplan_probe.gd` — synthetic footprint zoo (narrow/deep, wide/shallow,
  square, historic compound, corner two-facade, party-wall one-facade, ground
  commercial, upper residential, awkward-but-valid), planned over many seeds.
  Writes `out_floorplans/plans.json` (room rects, kinds, doors, facade edges) — a
  top-down viewer can be built straight off that JSON.
* Run: `python tools/run_suite.py --floorplanprobe 420 --fp-seeds 6 > .hermes/probe_run.log 2>&1`
* Statistics printed by the probe: plans built / rejected, rooms, kinds histogram,
  `facade_principal` (rooms with street facade / rooms), `circ_share`, coverage,
  overlap, sliver counts, and the full `planner_rejections` histogram.

## 9. Results

_Appended after each verified probe run; see section 12 for the run log._

## 10. Decisions worth knowing (and why)

* **Rewrite the module rather than tune the rows.** Tuning rows could not fix
  windowless rooms: the geometry itself made them unavoidable. Prefer the layout rule
  that gives every habitable room a facade.
* **The planner owns the WC and the landing (`locked` cells); the programme never
  renames them.** Where the WC goes is an architectural decision; leaving it to the
  slot assigner is what produced toilets in leftover corners.
* **One helper per architectural element** (`_corner_cluster`, `_rear_wc`,
  `_slice_rooms`, `_slice_x`) instead of one long function: the module is the unit of
  design, and each element can be validated on its own.
* **Reject loudly, never silently.** The first version of this package was integrated
  behind a gate that fell back on every failure; the whole "floor plans are bad"
  symptom was invisible for that reason.
* **`stair_hall`, not `stair`** — the canonical vocabulary in `FloorProgram`; a wrong
  kind drops the cell out of the circulation set and produces a doorless room beside
  the shaft.
* **Local constants** (`WALL_T := 0.18`, `OPEN_W := 0.95`) rather than reaching into
  `WorldConstants`: the planner stays a pure function of its inputs.

## 11. Known limitations / next steps

* Some archetypes still reject on the smallest footprints in the probe; the reject
  histogram in section 12 says which and why.
* Furniture placement has only been adapted minimally (it consumes the same room
  kinds as before).
* The probe writes JSON, not pictures; a top-down SVG/PNG export of
  `out_floorplans/plans.json` is the next piece of tooling.
* Legacy `HistoricInteriorPlan` still handles historic compounds; the archetype planner
  now covers ordinary buildings. Removing the legacy rescue passes entirely is a
  follow-up once the compound path is ported.

## 12. Run log

_Appended as runs complete._
