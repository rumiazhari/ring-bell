# Ring Bell — Universal Site Envelope Contract (G10-P2C)

The building contract (`BUILDING-CONTRACT.md`) owns the shell of a structure.
This contract owns the ground around it: the **yard surface, the fence loop with
its gates, and the trees standing in the yard** — the outdoor envelope of a real
plot. It is the same doctrine one layer out: the plan decides WHAT a plot has,
the validator proves it, and the emitters are the only construction path.

Scope today: **fences, yards, trees.** Roads and blocks join the same envelope
(plot frontage, setbacks, street continuity) as the next milestone.

## 1. Core architecture — separate the WHAT from the HOW

```
SitePlan (pure math, deterministic)  ->  site spec (Dictionary)
                                             |
                    SiteContractValidator.validate_spec(spec, surface_fn)
                                             |
              world/streaming/* emitters (prisms, colliders, batched props)
                                             |
                    SiteContractValidator.validate_build(spec, evidence)
```

Nothing constructs a fence post, a gate leaf or a tree trunk except an emitter,
and no emitter may emit a site the validator rejects.

## 2. Quality levels (same three as the building contract)

| Level | Meaning |
| --- | --- |
| `FULL_SITE` | complete envelope: yard surface, fence with gates, standing trees |
| `DISTANT_LOD` | simplified envelope beyond the playable ring; requires `lod_of` |
| `DECOR_ONLY` | yard dressing with no gameplay role; requires `decor_of`, may not plant trees |

## 3. Vocabulary (`world/generation/site_spec.gd`)

- **Yard kinds:** `courtyard`, `garden`, `backyard`, `farmyard`, `street_garden`, `industrial_yard`
- **Fence styles:** `none`, `picket`, `palisade`, `hedge`, `stone_wall`, `wire`, `rail`
- **Surfaces:** `paving`, `gravel`, `grass`, `earth`, `cobble`, `concrete`
- **Trees:** species come from `TreeBuilder.SPECIES`, so a yard tree is the same
  species table the tree system audits — one vocabulary, not two.
- A fence loop is a **ring**: the planner emits it implicitly closed and
  `normalize()` drops a duplicated final vertex, so no consumer has to guess.

## 4. Mandatory site invariants (`FULL_SITE`)

1. A site belongs to a plot with a building (`building_id`), and the plot has a
   real area (`>= SITE_MIN_PLOT_AREA_M2`).
2. The yard keeps a usable **outdoor share** of the plot (`>= SITE_MIN_YARD_FRACTION`).
3. A fenced yard is big enough to be a yard (`>= SITE_MIN_YARD_AREA_M2`).
4. The fence loop encloses ground, does not repeat points, and **never passes
   through the building** it protects (grazing a party wall is allowed).
5. Fence height sits in human scale (`SITE_MIN_FENCE_H .. SITE_MAX_FENCE_H`) and
   posts are close enough that no rail spans unsupported (`SITE_MAX_POST_SPACING`).
6. Every gate sits **on the fence line**, is walkable
   (`SITE_MIN_GATE_W .. SITE_MAX_GATE_W`), and every enclosed entrance has a gate
   within `SITE_GATE_ALIGN_M`.
7. Fence lines and tree roots are grounded within `SITE_GROUND_TOL_M` — the same
   authority the building contract uses for walls and doors.
8. A tree stands inside the plot, outside the building
   (`SITE_TREE_BUILDING_CLEAR_M`), apart from its neighbours
   (`SITE_TREE_TREE_CLEAR_M`), and a yard plants at most
   `SITE_MAX_TREES_PER_SITE` of them.
9. A fence that exists is **real**: it carries collision. No decorative-only
   fence in a playable plot, and no invisible fence on a style-less yard.

## 5. Build evidence (`validate_build(spec, evidence)`)

The second half of the contract is the proof that what was planned reached the
emitter. Every site build must report:

| Key | Meaning |
| --- | --- |
| `fence_posts` / `fence_segments` | posts on the loop and rails between them |
| `gate_leaves` | gate leaves, one per planned gate |
| `fence_colliders` | collision modules the fence produced (must be `> 0`) |
| `tree_trunks` | trunks emitted for the planned trees |
| `ground_y` | the height the envelope was built at |

## 6. Planner (`world/generation/site_plan.gd`)

Pure and deterministic — same seed, same sites, byte for byte.

- **City plots:** `CityPlan.garden_regions_in_rect()` courtyards and street
  gardens become sites; the fence follows the region ring, the gate is placed on
  the loop point nearest the plot's door, and the trees are scattered by area
  (`SITE_TREE_AREA_PER_TREE_M2`) with the building and tree clearances applied.
- **Fringe plots:** `FringePlan` residential and inn yards become sites, and the
  site adopts the **existing fringe trees inside the yard rect** — the same trees
  the tree system already generates and audits.
- **Ceilings:** `SITE_MAX_PER_RECT`, `SITE_MAX_TREES_PER_RECT` per chunk rect, so
  the outdoor layer cannot blow the chunk budget.

## 7. Migration status (fidelity to the real game)

| Site source | Status |
| --- | --- |
| City courtyards and street gardens (`CityPlan` regions) | Planned + validated ✅ |
| Fringe residential/inn yards + their trees (`FringePlan`) | Planned + validated ✅ |
| Fence/yard/tree **geometry** in the chunk builders (prisms + colliders) | Pending — next slice |
| Roads and blocks (frontage, setbacks, street continuity) | Pending |

## 8. Test gates

`--sitecontracttest` (`debug/site_contract_test.gd`):

- spec vocabulary — normalize defaults and accessors agree
- malformed-spec matrix — one deliberately broken site per rule, each must be
  rejected, and the untouched baseline must pass so a mutation is proven
  meaningful rather than vacuous
- city conformance — real `CityPlan` courtyards/gardens, every derived site
  validates against the real terrain
- fringe conformance — real `FringePlan` yards validate
- determinism — same seed identical, different seed differs
- build evidence — a fence or tree that never reached the emitter, a missing
  collider, an invisible fence, or grounding drift is caught
- ceilings — per-rect site/tree caps hold

Judge by the `[SiteContractTest] finished with 0 failure(s)` marker.

## 9. Work log

- Contract + planner + gate landed for city and fringe sites; fence/yard/tree
  geometry in the chunk builders is the next slice.
