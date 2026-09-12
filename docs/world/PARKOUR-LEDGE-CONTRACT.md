# Ring Bell — Parkour Ledge Contract (Q2)

**Version:** 1.0.0 · **Status:** LIVE (verified-feature query + anchored hang; worldgen tags parapets and bands)

Player-facing vertical traversal in Ring Bell is one deterministic, feature-verified
ledge query plus an anchored hang. This document is the contract: any future agent
changing parkour, or the generated facade vocabulary it stands on, must keep these
rules true and keep both proof harnesses green.

Project root: `C:/Vibe Code project/Godot Project/ring-bell`.
Code: `actors/traversal/parkour_controller.gd`, `world/generation/building_builder.gd`,
`world/streaming/mesh_batcher.gd`.
Harnesses: `debug/parkour_contract_test.gd` (`--parkourtest`),
`debug/parkour_ledge_test.gd` (`--parkourledgetest`).

## 1. One query

`ParkourController._probe_ledge(dir) -> Dictionary` is the single source of truth for
every ledge decision: the grab, the shimmy, the corner hand-off, the climb-up
pre-check and the HUD cue all ask it. There is no second climbing path.

It returns `{}` or a full record:

```
{kind, tag, shape_node, lip (Vector3), outer_face, wall_normal, tangent,
 rise, box_depth, usable_depth, usable_width, usable_half_width,
 class ("slab" | "bar"), hang_clear, stand_clear, stand_offset}
```

`kind` is the shape's generator tag when it has one, else `structure`
(`vox_material` stamped = batched building masonry) or `prop` (bare fixture crate).
`tag` is the raw tag.

## 2. Rules (each individually testable)

| Rule | Statement |
| --- | --- |
| **A. Face** | Chest ray (1.2 m above feet, ±0.18 m lateral, reach 0.62 m) hits a `BoxShape3D` whose normal opposes the probe (`normal·dir ≤ −0.5`). Glancing and backside hits are rejected. |
| **B. Rise** | Lip top within `[LEDGE_TOP_MIN 0.9, LEDGE_REACH_ABOVE 2.1]` m above the feet. |
| **C. Attribution** | The lip must belong to the ray-hit shape. When that shape has no reachable top, a bounded scan (`HOLD_SCAN_OFFSETS`, one down-ray each) may find a protruding shape instead — that is how a cornice above a window band is found without opening an "any wall" door. Scanned lips must sit on the face we hit (`HOLD_SCAN_MAX_PLANE 0.45`). |
| **D. Profile** | Measured from the actual `BoxShape3D.size` + world basis, never guessed. Minimum usable depth: `0.05` for a tagged generator feature, `0.14` for an untagged shape (a prop must be substantial before it counts). Thickness: vertical face ≥ `HOLD_HEIGHT_MIN 0.15`, **or** a top face wide enough to hook (`usable ≥ HOLD_DEPTH_WIDE 0.25`) — a 0.08 m moulding offers neither. Usable width ≥ `HOLD_WIDTH_MIN 0.45`. Class is `slab` exactly when `usable ≥ HOLD_DEPTH_MIN_SLAB 0.14` **and** a landing exists, else `bar` (hang + shimmy only). |
| **E. Exposed top** | The blank-wall rule. The point 0.2 m inboard of the lip's outer edge at `lip_y + 0.10` must be free of colliders and a 0.6 m upward ray from it must be clear. Blank facade cells (wall above), storey seams and lintel bands fail; cornices, parapets, roof edges, planks, decks, crates and sills-on-top pass. |
| **F. Hang clearance** | A capsule (r 0.30, h 1.7) at the hang pose (`face_plane + normal·0.45`, feet at `lip_y − 1.45`) is clear of everything but the hold. |
| **G. Destination** | A stand capsule (r 0.30) must fit at the mantle landing; bounded offset search (`HOLD_STAND_OFFSETS 0.24…0.85`, up to `HOLD_STAND_DROP_MAX 1.00` below the lip) records `stand_clear`. A blocked landing downgrades to hang-only — never a phantom mantle. |
| **H. Budget/determinism** | ≤ 24 rays + ≤ 8 shape queries per attempt, no `randf`, no wall-clock, cached while hanging/shimmying. |

| **I. Preference** | When several holds verify inside the same reach window, the one with a landing wins while it costs no more than `LEDGE_STAND_PREFER_DROP 0.9` of height; otherwise the higher lip wins, then the nearer scan offset. Generated facades stack thin lip bands 0.1–0.7 m above every mountable cornice, so "highest wins" alone leaves the body hanging on a lip it can never stand on. |

A hold with neither hang nor landing clearance is rejected (`no_clearance`).
`class` is `slab` exactly when usable depth ≥ 0.14 **and** a landing exists.

## 3. Feature-tag contract (worldgen side)

A tag classifies a hold; the shape's own box geometry verifies it. Tags never
confer climbing, and no tag can promote a dressing that fails rule D/E.

`MeshBatcher.flush_into` stamps `vox_tag` on **colliding** batched features only,
for tags in its whitelist:

```
awning, balcony, tower, bhplant, bhladder, bhexit, scaffold, cornice,
pilaster, parapet, band
```

`parkour_controller.CLIMBABLE_TAGS` mirrors that list exactly, so a
generated feature is classified by kind and measured by profile:

| Generator feature | Tag stamped | Protrusion / size | Class |
| --- | --- | --- | --- |
| Balcony deck | `balcony` | `BAL_PROJ 0.7` | slab |
| Scaffold plank | `scaffold` | `SCAFF_PROJ 1.0` | slab |
| Awning deck | `awning` | ~1.2 m | slab |
| Roof parapet | `parapet` | `PARAPET_H 0.9`, 0.28 m ring on `WALL_T 0.35` | slab (roof edge) |
| Cornice band | `cornice` | `CORN_PROJ 0.26` | slab or bar by measured depth |
| Sill/lintel band | `band` | `WALL_T` deep string course | bar (glass/wall above) |
| Balcony rail | `balcony` | `BAL_RAIL_T 0.07` | bar |
| Bulkhead rim | `bhexit` | `BH_RAIL_T 0.08`, `BH_RAIL_H 0.45` | bar |
| Pilaster | `pilaster` | `PIL_PROJ 0.24` | bar or slab by measurement |
| Crate / bare prop | *(none)* | any box | slab by measurement |

**Deliberately not climbable:**

- **Window sills** (`SILL_T 0.06 × SILL_H 0.09`) stay visual-only — no collider, so
  no stamp. Promoting them would add ~4 colliders per window for a 9 cm shelf no
  human mantles; cornices, bands, parapets, decks, planks and bulkhead rims already
  cover the "substantial surround" role. This is a recorded deviation, not an oversight.
- **Drainpipes** are emitted with collision off (visual only). A `pipe` class
  (vertical hold, square ≥ 0.05, run ≥ 2.5 m) is specified in the Q2 design but not
  implemented: with no colliding pipe in the world it would be dead code.
- Thin decorative trim (0.06 m mouldings, shutters, gutters) has no collider; even if
  it had one, rule D thickness and rule E exposed-top would reject it.

## 4. Anchored movement (no teleport, no sinking)

- **Grab → HANG**: the controller anchors the body (`{lip, wall_normal, face_plane,
  tangent, half_width}`), zeroes velocity, and corrects to the hang pose each frame,
  clamped at `HANG_SNAP_MAX 0.12 m/frame` — a few centimetres onto the face, never a
  jump between distant holds.
- **Shimmy**: A/D travel along the tangent at `SHIMMY_DRIVE_SPEED 0.60`, clamped by the
  *measured* half width; a ledge end stops the body instead of floating it. One
  perpendicular query at a ledge end hands off around a corner when a compatible hold
  is in reach, otherwise the body releases.
- **Climb-up**: jump while hanging → verified mantle (`stand_clear` from rule G),
  driven like the classic climb; a hold below may be re-grabbed while falling
  (drop-to-hang) with hysteresis (`LEDGE_CLIMB_HYSTERESIS 0.15`) so the lip just left
  cannot be re-caught.
- **Anti-stuck**: a grab only arms after `LEDGE_MIN_AIR_TIME 0.30 s` genuinely
  airborne (stair lips must not latch the player), a climb-up re-arms the grab with
  `LEDGE_CLIMB_HYSTERESIS 0.15` so the lip just left cannot be re-caught, and HANG is
  never a trap: drop/release always ends it, and a ledge end stops the shimmy in place.
- **Counters kept** so `--smoke` keeps its meaning: `ledge_grabs`, `rooftop_mantles`,
  `awning_grabs`, `last_grab_was_building`, `last_grab_was_awning`, plus Q2 additions
  (`hang_ticks`, `shimmy_driven_ticks`, `shimmy_ends`, `corner_handoffs`,
  `ledge_climbs`, `last_shimmy_travel`, `last_hold_kind/width/depth/hang_clear/stand_clear`)
  and the census ledger (`hold_accepts`, `hold_rejects`, `last_reject_reason`,
  `reject_reasons`).

## 5. Proof

Two headless harnesses, both deterministic and both required:

```
python tools/run_suite.py --parkourtest 400        # rules A-H on fixtures
python tools/run_suite.py --parkourledgetest 2400  # the real city (4 sections)
```

`--parkourtest` (`debug/parkour_contract_test.gd`) proves the rules on purpose-built
fixtures: blank facade, storey seam, 0.06 m dressings, through-wall hole, out-of-reach
wall, deep crate, cornice, parapet, balcony rail, bulkhead rim, plus a driven
jump→hold→climb-up case.

`--parkourledgetest` (`debug/parkour_ledge_test.gd`) asks the same question of the
generated world, through the real pipeline (`MeshBatcher.new()` →
`BuildingBuilder.build` → `flush_into`):

1. **Rejection matrix** — the fixture rules again, recorded for section 4.
2. **Census** — ≥ 3 seeds, ≥ 8 materialized buildings (`city_materialized` chunks
   only): a lattice of standpoints along every facade, from the street to the roof and
   upward through every storey in `VER_STEP 0.6` steps, plus the standpoints a real
   jump passes through (`JUMP_STEPS`, apex 1.14 m — `JUMP_SPEED 6.4`, `GRAVITY 18`), so
   a hold that is only reachable mid-arc is measured as such. Per-kind accepted holds
   with measured width/depth, class × kind counts, and the heights above base at which
   each mountable kind occurs; asserts no accepted hold fails its profile, every
   accepted hold is anchored (hang **or** landing clearance, rule F/G) with stand-only
   holds reported as a small minority, and route diversity is non-uniform.
3. **Real climb** — sweeps the facades of the census buildings, column by column in a
   fixed order, and drives the real `Survivor` + controller from the street: walk at
   the face (real input), jump, hold toward it, and while it hangs use the controller's
   own climb-up input. No pre-planned chain and no teleport — a column that gains a
   level is kept for the next hop, a column that misses is retried while the body is up
   on a ledge and otherwise the sweep steps along the facade. Asserts ≥ 2 chained holds,
   the roof deck (≥ `floors × floor_h`), and no per-frame displacement over the honest
   budget (0.50 m: 30 m/s at 60 Hz, faster than free fall from the tallest facade —
   only a teleport exceeds it).
4. **Determinism** — section 1's matrix and one census building re-run to identical
   records.

Cost note: `CityPlan` generation is ~100 s per seed, so the harness builds the plan
once and caches the specs; the census and the climb reuse them.

## 6. Limits of this contract

- Roof-reaching mantle chains need features spaced within `LEDGE_REACH_ABOVE 2.1 m`
  (3.2 m out of a standing jump, ~3.0 m out of a hang jump). A facade whose only
  climbable features sit one storey apart (`floor_h` ~3.1 m) with nothing between them
  is not chainable: the body grabs, hangs, climbs up onto the hold, and finds no next
  hold inside its reach. The harness reports the hops it actually made, the attempts it
  spent and the best footing it reached instead of inventing a route, and the census
  prints the heights above base at which each mountable kind occurs so a gap like that
  is visible in the numbers. Intermediate climb features (AC brackets, service
  landings) are a worldgen follow-up, not a query bug.
- The climb only reports what the body achieves: ladders, stairs and doors are
  separate systems.
- `HOLD_WIDTH_MIN 0.45` and the depth floors are the current tuned numbers. Change
  them only with both harnesses green and the census re-run.

## 7. Measured ceiling of the generated city (2026-09-13)

The census of section 5 was run over three seeds and nine materialized fronts, and the
driven climb at four of them. What it measured, as arithmetic the design has to live with:

- **The lowest climbable hold on every front sits at 3.10 m** above the base (a
  `bar:cornice` whose `stand_clear` is nevertheless true) or 3.85 m (a balcony rail).
  Nothing generated is climbable below that.
- **A hang chain gains at most `JUMP_SPEED * 0.9` apex (0.92 m) + `LEDGE_REACH_ABOVE`
  (2.1 m) = 3.02 m per leap** — *less* than one storey (`floor_h` 3.10 m), so bar-class
  bands cannot be chained across a storey boundary.
- **A standing jump gains 1.14 + 2.1 = 3.24 m** — more than a storey. The ladder closes
  exactly when the body takes a hold it can stand on at the storey head.
- **The driven body does not.** It chains holds inside the first storey (logged 1.74 ->
  2.38 -> 2.78 -> 3.74 -> 4.20 m of feet), stalls at the storey boundary (`rise_high`
  dominates its reject ledger) and never stands above the entrance stoop: `stood` is
  1.08 m against an 18.60 m roof on every front.
- **The open question is the hang -> climb-up transition, not the city.** The driven
  climb's own grab records show holds with `stand_clear` true at a 3.95 m lip - holds the
  body could have climbed onto - yet the hop is logged as a leap and the body never ends
  standing on one. The contract test never drives a mantle (its hold report from the same
  run reads `climbs 0`), so the transition that the whole storey (3.24 m standing-jump
  gain) depends on is unverified by `--parkourtest` and does not complete in the driven
  climb.
- Two candidate fixes aimed at the *grab* were implemented and measured - preferring a
  mountable hold inside the same reach window, and a second down-cast that looks below
  the highest lip - and **neither changed the outcome**. Both were reverted rather than
  left in as unproven behaviour, so the rules of section 2 are unchanged.

So: "climbable hold" is verified across the city; **"climbable facade" is not**, and the
next item is a contract-test case for the hang -> climb-up transition plus a fix for the
climb follow, not a change to the city or the reach numbers.

