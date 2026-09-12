# Q3 -- Procedural building interiors overhaul (recon + plan)

Branch: copilot/worldgen-fix. Base: ebc3aedf22309737900fd2418af1bed5047066be (Q1 done, pushed).
Status: recon COMPLETE, baseline MEASURED, implementation IN PROGRESS.

## 1. What already exists (do not rebuild)

The interior system is far more complete than the task brief assumes. It is NOT empty.

- world/generation/interior_plan.gd -- build_for_building(spec); dispatches to the historic grammar
  or to a generic _floor_manifest; owns validate(manifest) (the interior contract), furniture
  tables, interior_station exploration hooks, planned_clearance.
- world/generation/historic_interior_plan.gd -- the real Prague grammar: courtyard/wing/triangle
  houses, circulation spine, stair column, a "mazhaus" front room, depth tables, a privet (WC) on
  every floor, multi-floor plans, and a door graph with degree caps.
- debug/prague_interior_logic_test.gd -- a dedicated 12-check audit, runs as --interiorlogictest,
  three seeds (19041207/08/09), ~890-946 wings, ~4,100-4,300 floors.
- debug/prague_gameplay_test.gd -- prints the room metrics line (occupied_rooms,
  room_count_p10/50/90, principal_p50, tiny_share, invalid_interiors, floor_rooms_p50, hall_p50).
- Attic/cellar/mezzanine depth plans, STAIR_DEPTH_TAKE, LOBBY_PROGRAMS, area tiers
  PRINCIPAL_MIN/NORMAL_MIN/SERVICE_MIN/SERVICE_MAX, COMBAT_MIN combat room, _chained_bedrooms,
  kitchen_rear, prevet_ok, mazhaus_* already exist.

Q3 is NOT "invent interiors". It is: fix the specific systemic rules that still produce
unbelievable interiors, measured by the audits that already exist.

## 2. Baseline (measured, --interiorlogictest, 3 seeds)

python tools/run_suite.py --interiorlogictest 420  ->  12 FAILURES (4 checks x 3 seeds).

Per-seed line lives in the engine log tools/out_interiorlogictest.txt, NOT the runner temp log:
  seed=19041207 wings=917 floors=4123 dups=0 blind=97 blind_area=1745m2 door_missing=0
  door_private=0 stair_uncovered=0/3791 chained_private=2891 chained_bedrooms=0 kitchens=2966
  kitchen_rear=0.773 prvets=4053 prevet_ok=0.980 mazhaus_front=0.968/917 mazhaus_all=0.872/1274
  hall_p50=2.00
  seed=19041208 blind=95  chained_private=2955 mazhaus_all=0.853/1357
  seed=19041209 blind=134 blind_area=2315m2 chained_private=2942 mazhaus_all=0.863/1254

PASSING (9 of 12): dups=0, no_compound=0, dup_rooms=0, door_missing=0, door_private=0,
stair_uncovered=0, chained_bedrooms=0, kitchen_rear=0.773, prevet_ok=0.98, mazhaus_front=0.968.

FAILING (4):
  1. blind_rooms == 0                                        -> 97 / 95 / 134 blind rooms
  2. chained_private * 20 <= lit_contact.size()  (5% budget) -> chained_private=2891
  3. chained_private * 4  <= lit_contact.size() (25% budget) -> chained_private=2891 (~29%)
  4. mazhaus_ok / mazhaus_floors >= 0.9                      -> 0.872 / 0.853 / 0.863

## 3. Root causes (read from source, each with the rule that is wrong)

### 3.1 Blind rooms: a habitable kind is planned against a party wall
_Light contact_ (prague_interior_logic_test.gd:330) defines lit as: the room's wall lies on the
plot's inner boundary AND that face is an _open_edges face, where _open_edges (:310) means "no
other lot sits within 0.8 m on the far side" (party wall => no light, no air).
Blind samples all show a habitable kind on the BACK band:
  blind: historic_block_11_step_1_22_front f1 kitchen 3.3x7.4 area=24.3 doors=1
  blind: historic_block_1_plot_10_0_front  f1 kitchen 2.9x5.0 area=14.5 doors=2
  blind: historic_block_0_plot_3_1_front   f0 sales   2.6x7.4 area=19.0 doors=1
historic_interior_plan.gd:_depth_back(fi, 0, use, narrow) returns DEPTH_UPPER_BACK = "kitchen"
whenever narrow is false. narrow is a SIZE HEURISTIC (inner.size.x < 6.5 and inner.size.y > 10.5),
but the real cause of a dark back room is ADJACENCY -- another lot on the far side. A plot 6.5 m+
wide with a neighbour abutting its back therefore still gets a kitchen there. _depth_front already
carries the correct reasoning for the mirror case (street side, narrow => kitchen); the two
functions disagree about where light is.

Two more rules in the same file are wrong the same way:
  - (:379-383) the "uninhabited floor" rescue promotes the largest store to a room if it touches
    plate.position.y or plate.end.y -- "touches the outer face" without asking whether that face is
    a party wall. Manufactures a blind room on every such floor.
  - (:405-408) the landing-hand-back pass uses lit_end := absf(lr.end.y - plate.end.y) < 0.05 with
    the comment "only a landing that already reaches the courtyard wall has light to give".
    Reaching the wall is not light. Same defect, same fix.

### 3.2 chained_private ~= 29% (5% budget)
_chained (:385): a private room counts as chained when none of its neighbours is reachable from a
circulation room without crossing a private room. The back band is DEPTH_GROUND_BACK[use] /
DEPTH_UPPER_BACK (kitchen) and DEPTH_TAIL (storage) -- all PRIVATE kinds. When a back bay is entered
through a street-band room instead of the mid passage/landing (rear_open == false layouts, and any
floor where the crossing is consumed by the stair, privet and store), every back room becomes
private-behind-private. chained_bedrooms == 0 proves the sleeping case is already handled; the
residue is kitchen/service behind a room.

### 3.3 mazhaus_all 0.85-0.87 against a 0.90 bar
The check is "the street door opens into a public room"; per-seed the misses print as
door_room=taproom area=6.8 and door_room=warehouse area=3.9 -- the entrance room is public IN KIND
but tiny, so the entrance lands in a service-scale cell. _bays' principal-first rule cannot make a
wide front room when the stair column, privet and crossing have eaten the band; the bays.is_empty()
fallback (:333-337) then emits nothing but landing, and the door opens into that. The front public
room needs an AREA floor (COMBAT_MIN-scale), not just a public kind, and the fallback must keep a
real entrance cell.

## 4. Implementation plan -- rules only, no per-building special cases

  F1. Feed real adjacency to the planner. The planner only receives spec; grep the call site of
      InteriorPlan.build_for_building(spec). Where lot/city context is in scope, attach the
      open/closed state of the plot's outer faces to the spec (e.g. spec["open_faces"], Array[bool]
      in raw lot-edge order 0=N,1=E,2=S,3=W, exactly as the audit computes it via
      CityPlan._lot_corners + a 0.8 m outward probe). If generation order makes that impossible,
      use a conservative planner-side rule instead: a habitable kind may only occupy a cell whose
      outer face is provably open, else it is service.
  F2. Enforce "no habitable kind without light" as ONE rescue pass in floor_plan, immediately
      before cells become rooms (:413-417): for every cell whose kind is not in
      SERVICE_KINDS/CIRC_KINDS, if its rect reaches an outer face that is not open, re-kind it to
      storage (keep the geometry -- a windowless store is a real room type, a windowless bedroom is
      not). This removes every blind room whichever band placed it, and is the rule the file's own
      comments state but never enforce.
  F3. Make _depth_back use the same light test as _depth_front: on a plot whose back face is a party
      wall the back band takes DEPTH_TAIL (storage), not DEPTH_UPPER_BACK (kitchen). Keep narrow
      working as before when adjacency is unavailable.
  F4. Fix the two passes that promote walls into rooms without a light test (:379-383, :405-408):
      promotion and lit_end must use the open-face test from F1/F2, not "touches the outer bound".
  F5. Back-band connectivity: link every back cell to the crossing/landing whenever such a wall
      exists, BEFORE private-through-private links are considered, so chains drop. If the link is
      geometrically impossible, the cell must be a kind that is legitimately reached through the
      room in front of it.
  F6. Entrance room: the ground-floor front public room must clear a real area floor
      (COMBAT_MIN-scale), and where the band is too eaten to make one, the door must still open into
      the largest public cell rather than a 3.9-6.8 m2 service cell.

Constraints (binding, from the user):
  - Fix generation rules, NOT one showcase building. No hardcoding a building id.
  - Do not regress doorway clearance, camera cutaway, roof transitions, parkour, destruction,
    streaming/performance, interior lighting.
  - Deterministic: no Math.random/randf, seeded only. Same seed => same output.
  - Do not weaken or edit any assertion in debug/prague_interior_logic_test.gd.
  - .gd files here are CRLF: re-normalise to CRLF after any patch-tool edit.
  - Do not run git add/commit/push.

## 5. Test matrix

  python tools/run_suite.py --interiorlogictest 420     -> blind=0 on all 3 seeds,
                                                          mazhaus_all >= 0.90, chained_private
                                                          under the 25% budget; report the 5%
                                                          budget honestly if a rule change cannot
                                                          reach it (NEVER edit the test to pass).
  python tools/run_suite.py --walkthrough 300           -> must stay 0 failures (Q1 gate).
  python tools/run_suite.py --cityruntime 300           -> must stay 0 failures.
  python tools/run_suite.py --buildingcontracttest 420  -> must stay 302 failures / 116 of 373.
  python tools/run_suite.py --praguegameplaytest 180    -> record room metrics before/after.
  Determinism: run the interior logic test twice, diff the per-seed summary lines.

Log routing gotcha: in-game print() from a test lands in tools/out_<suite>.txt, NOT the runner's
temp log. The runner echoes only FAIL/PASS/ERROR lines plus the tail.

## 6. Environment

  Godot: C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe ; project root
  C:/Vibe Code project/Godot Project/ring-bell ; shell is git-bash, not PowerShell.
  Pre-flight: --headless --path . --import. Long runs: background + poll.
  --interiorlogictest is dispatched in world/main.gd (:154) and needs no world build.
