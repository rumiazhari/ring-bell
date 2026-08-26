# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 42
UPDATED: 2026-08-27 (JST, cron run) — iter 42

## Current goal
Iter 42: Phase AB Prague window stone lintels — stone header (WIN_W 1.15 + 0.26 = 1.41 x WINDOW_TRIM_H 0.14 x WINDOW_TRIM_T 0.05) above historic windows, pressed 0.045 outside historic long facades (>=5.0) at y WIN_SILL+WIN_H+0.02+0.07, deterministic per WorldSeed window_trim per window, visual-only, stone 9e968a lerp 0.10, layer f* tagged trim; BuildingBuilder._facade_window_trim via WorldSeed, visual-only, no collision; citytest + smoke green (1 new assertion).

## This iteration
[autopilot] iter 42: Phase AB Prague window stone lintels crown historic windows with classic header trim: BuildingBuilder adds WINDOW_TRIM_W 1.41 (WIN_W+0.26) x WINDOW_TRIM_H 0.14 x WINDOW_TRIM_T 0.05 stone lintel with _facade_window_trim (historic-gated >=5.0, deterministic per WorldSeed window_trim per window, visual-only thin slab pressed 0.045 outside wall — header at WIN_SILL+WIN_H+0.02+0.07 above each window, stone 9e968a desaturated 0.10, layer f* tagged trim); citytest + smoke green (0 failures); 1 new assertion passes ("facade window trim: Prague stone lintels above historic windows (deterministic)" - thin 0.05 + 1.41 x 0.14 at header height + outside-footprint + visual-only + deterministic rebuild + non-historic/tiny gating + historic ring hit).
[autopilot] iter 41: Phase AA Prague window flower boxes dress historic sills with lived-in gardens: BuildingBuilder adds FLOWER_W 1.38 / FLOWER_H 0.18 x FLOWER_D 0.22 trough + FLOWER_BLOOM_H 0.12 bloom (FLOWER_W*0.92 x FLOWER_D*0.88) with _facade_flower_boxes (historic-gated >=5.0, deterministic per WorldSeed flowerbox per window, visual-only trough+bloom pressed 0.045 outside wall — trough at WIN_SILL-FLOWER_H/2 + bloom at WIN_SILL+FLOWER_BLOOM_H/2 under each window, terracotta + bloom palette desaturated 0.18, layer f* tagged flowerbox, trough+bloom even pairs); citytest + smoke green (0 failures); 1 new assertion passes ("facade flower boxes: Prague terracotta trough + bloom under historic sills (deterministic)" - trough 1.38 x 0.18 x 0.22 + bloom 1.27 x 0.12 x 0.19 at sill height + outside-footprint + visual-only + deterministic rebuild + even pairs + non-historic/tiny gating + historic ring hit).
[autopilot] iter 40: Phase Z Prague window shutters flank historic windows: BuildingBuilder adds SHUTTER_T 0.025 / SHUTTER_W 0.30 x SHUTTER_H 1.22 / SHUTTER_GAP 0.04 / SHUTTER_PROB 0.52 with _facade_shutters (historic-gated >=5.0, deterministic per WorldSeed shutter per window, visual-only thin planes pressed 0.045 outside wall at window sill-mid (WIN_SILL+WIN_H/2) — left+right leaf pair per qualifying window, shutters at y window-center, thin 0.025 + planar 0.30 + height 1.22, wood palette desaturated via lerp 0.12, even leaf-pair count, outside-footprint + deterministic rebuild + pair count + non-historic/tiny gating + historic ring hit); citytest + smoke green (0 failures); 1 new assertion passes ("facade shutters: Prague wooden shutters flanking historic windows (deterministic)" - thin 0.025 + planar 0.30 + height 1.22 at window height + outside-footprint + visual-only + deterministic rebuild + even pairs + gating).
[autopilot] iter 39: Phase Y Prague drainpipes + eave gutters dress the historic roofline: BuildingBuilder adds DRAIN_T 0.06 / DRAIN_PIPE_PROB 0.62 / DRAIN_GUTTER_H 0.07 / DRAIN_GUTTER_T 0.08 with _facade_drainpipes (historic-gated >=5.0, deterministic per WorldSeed drainpipe, visual-only thin boxes pressed 0.05 outside wall — vertical pipe full-height total_h-0.14 + horizontal gutter at total_h-0.075 along eave, zinc 5a6d6e / copper 6a7a5e patina, layer f0 tagged drainpipe, even count pipe+gutter pairs); citytest + smoke green (0 failures); 1 new assertion passes ("facade drainpipes: Prague zinc/copper downpipes + eave gutters on historic facades (deterministic)" - pipe 0.06 square full-height + gutter 0.07×0.08 at eave + outside-footprint + visual-only + deterministic rebuild + pair count + non-historic/tiny gating + historic ring hit).
[autopilot] iter 38: Phase X Prague facade signage — faded shop signs + house numbers dress the historic core: BuildingBuilder adds SIGNAGE_T 0.02 / SHOP_PROB 0.48 / HOUSE_PROB 0.60 / SHOP_W 0.85-1.45×0.42 / HOUSE_S 0.32 with _facade_signage (historic-gated >=5.0, deterministic per WorldSeed house_num/shop_sign, visual-only thin planes pressed 0.04 outside wall at y 1.35 plaque beside door / y ~2.02 board, desaturated shop palette 4a5a6e/6e4a3a etc lerp 0.22 + plaque c8c4a8/d8cfb0/a8c4d8/d8b8a0, layer f0 tagged signage); citytest + smoke green (0 failures); 1 new assertion passes ("facade signage: Prague shop signs + house numbers on historic facades (deterministic)" - thin 0.02 + ground-band 1.0-3.0 + outside-footprint + visual-only + deterministic rebuild + non-historic/tiny gating + historic ring hit).
[autopilot] iter 37: Phase W flicker/dead-lamp variant — historic avenue lamps now sputter or stay dead for post-apoc horror: MeshBatcher adds STREET_DEAD_PROB 0.035 / FLICKER_PROB 0.18 / AMPL 0.18 / FREQ 3.0 with _street_lamp_dead/flicker/phase parallel arrays (historic-gated via _lamp_is_historic replicating CityPlan district_at_point), manifest carries street_lamp_dead/flicker/phase and _manifest_equal checks determinism; ChunkBuilder spawns OmniLights with dead_lamp meta (visible false always, still counted in stats) or lamp_flicker+flicker_phase meta (range 13, energy 2.8 warm 1.0/0.88/0.62, group streetlamp); DayNightController keeps dead dark even at night and modulates flicker energy via dual-sine noise (0.6*sin(FREQ*TAU*t+phase)+0.4*sin(1.73*FREQ*TAU*t+phase*2.11), clamped 0.55-1.40x base, breathing with _flicker_time, reset to base for non-flicker), is_inside_tree guard + _sun guard for headless; citytest + smoke green (0 failures); 1 new assertion passes ("flicker/dead lamps: historic subset sputters or stays dark (deterministic)" - dead 3.5% + flicker 18% in 169-chunk ring, historic gating, outer chunk ~0, deterministic rebuild, manifest keys, node dead/flicker meta + phase, DNC night/day flicker modulation and dead stays dark).
[autopilot] iter 36: Phase V volumetric street ambience — faint night haze + bloom halo around streetlamps/window glows: DayNightController Environment now has glow_enabled (intensity night 0.62→day 0.28, strength 1.0, bloom 0.12, hdr 0.88/1.6 softlight) + volumetric_fog_enabled (density night 0.022→day 0.005, emission night 0.52→day 0.08, albedo 0.60/0.63/0.70, warm emission 0.86/0.68/0.42, length 64, detail 6.0) that breathes with day_factor (night thicker/brighter, day thin), plus fog_density 0.008→0.0025; is_inside_tree() guard prevents headless tree errors; citytest + smoke green (0 failures); 1 new assertion passes ("volumetric ambience: ground fog + bloom halo around streetlamps/window glows at night").
[autopilot] iter 35: Phase U interior window glow — intact historic long facades now leak warm light: each intact window has a 0.32-deterministic chance (WorldSeed "window_glow") to sprout an interior OmniLight 0.65m behind the glass at window centre (range 5.5, energy 1.15, warm 1.0/0.88/0.62, shadow off, group window_glow), night-only via DayNightController live group query; broken panes never glow; gated to historic + long facade, deterministic via MeshBatcher.window_glows() and manifest equality; ChunkBuilder spawns per-chunk lights counted in stats["window_glows"]; citytest + smoke green (0 failures); 1 new assertion passes ("window interior glow: faint warm lights behind intact historic glass at night (deterministic)").
[autopilot] iter 34: Phase T handheld lantern — Survivor now spawns a warm handheld OmniLight (LANTERN_RANGE 10.0, LANTERN_ENERGY 2.2, LANTERN_COLOR 1.0/0.85/0.58, offset 0.35/1.10/0.25, shadow off, group player_lantern, bob AMPL 0.045 FREQ 4.2) as a child of the player only (NPCs get none); _update_lantern tracks GameClock.is_night() each physics frame and adds sinusoidal bob (idle + walk) so the pool reads as carried; refresh_lantern() helper for headless tests; citytest + smoke green (0 failures); 1 new assertion passes ("player lantern: warm handheld light at night with bob").
[autopilot] iter 33: Phase S genuine night darkness + streamed streetlamp warm pools — DayNightController makes night truly dark (NIGHT_SUN 0.015 vs day 1.35, NIGHT_AMBIENT 0.03 vs 0.60, NIGHT_BG dark navy 0.015/0.022/0.045 + fog 0.008 night → 0.0025 day) and re-queries streetlamp group live each frame (fixes stale-cache bug that left CITY dark); ChunkBuilder._lamp_post now emits a real OmniLight3D per avenue lamp (range 13, energy 2.8, warm color) via MeshBatcher.street_lights() counted in manifest; citytest + smoke green (0 failures); 1 new assertion passes ("streetlamp night lights: genuine darkness + avenue-aligned warm pools").
[autopilot] iter 32: Phase R broken windows + street litter — historic long facades lose ~30% of window panes (BROKEN_WIN_PROB 0.30, BROKEN_DARK_T 0.03 dark interior plane tagged broken) + sidewalk litter (LITTER_PROB 0.58, 2-4 per side at LITTER_Y 0.035 tagged litter); both visual-only, deterministic per (building,side,floor,window) via WorldSeed, gated to historic + long facade (>=5.0); leaves eerie dark interiors and gritty sidewalks without touching collision. citytest + smoke green (0 failures); 1 new assertion passes ("broken windows + street litter: missing panes / dark interiors + sidewalk debris on historic facades").
[autopilot] iter 31: Phase Q facade decay — BuildingBuilder grows graffiti / rust-streak / moss visual decals (DECAY_T 0.02 thin planes, GRAFF 0.55 / RUST 0.48 / MOSS 0.40) pressed just outside each historic long facade (>=5.0), deterministic per (side, building) via WorldSeed, visual-only (collide=false, material empty, tagged "decay"); three RNG channels give independent coverage (graffiti mid-wall, rust drip, moss base strip). Brings the Prague core out of white-dummy into the directive's eerie decayed aesthetic without touching collision. citytest + smoke green (0 failures); 1 new assertion passes ("facade decay: graffiti / rust / moss visual decals on historic facades").
[autopilot] iter 30: Phase P facade cornices + pilasters — BuildingBuilder grows horizontal stone cornice bands at each storey junction (CORN_H 0.18, CORN_PROJ 0.26, concrete, tagged "cornice") + segmented vertical pilaster pillar strips per storey (PIL_W 0.32, PIL_PROJ 0.24, concrete, tagged "pilaster") on historic multi-storey long facades; deterministic per (side, building), gated to historic + multi-storey + long facade. MeshBatcher now carries vox_tag cornice/pilaster. citytest + smoke green (0 failures); 1 new assertion passes ("facade cornices + pilasters: stone ledge bands + pillar strips on historic multi-storey facades").
[autopilot] iter 29: Phase O construction scaffold — CityPlan emits district + plaza_adjacent (historic + plaza-ring check), BuildingBuilder grows a full-height steel cage + wood plank decks (tagged "scaffold", SCAFF_PROJ 1.0, SCAFF_W 3.4) on one shuffled long facade of plaza-adjacent historic buildings; planks at each storey provide mid-height AC traversal. MeshBatcher now carries vox_tag scaffold. citytest + smoke green (0 failures); 1 new assertion passes ("construction scaffolding: steel cage + plank decks on plaza-adjacent historic facades").
[autopilot] iter 28: Phase N awning->balcony chain — BuildingBuilder now
hosts balconies on the street wall at f>=1 (same BAL_PROB, enabling
stacked awning->balcony generation); smoke fixture proves the balcony lip
(steel, vox_tag balcony, top 3.75) is grabbable from a fall alongside the
stack and that the 2.3->3.75 rise (1.45) sits comfortably inside the
LEDGE_TOP_MIN/REACH window, confirming ground->first-floor chaining needs
no height tuning. citytest + smoke green (0 failures); 5 new assertions
pass ("balcony grab triggered during fall", "chain height delta within
grab window", etc.).
[autopilot] iter 27: Phase M awning-grab classification in the parkour
controller (vox_tag meta from MeshBatcher, awning_grabs counter, gentler
AWNING_DRIVE_SPEED follow-through); smoke fixture mimics real iter-26
awning geometry. citytest + smoke green (0 failures); 5 new/extended
assertions pass ("awning grab classified as awning", "survivor mounted
awning deck", etc.).
[autopilot] iter 26: Phase L street awnings — sloped canopy deck from the
ground-floor street facade + steel front lip (grabbable parkour ledge);
deterministic, gated to street wall + AWN_MIN_SIDE, tagged "awning".
citytest + smoke green (0 failures); new `_test_awnings` assertion passes.

[autopilot] iter 24: Phase J bulkhead roof-access ladder — a vertical run of destructible
steel rungs on the hut's +Z face climbing from just above the deck up to the
Phase H rim top, so the serviced plant-room roof (Phase H rim + Phase I hatch)
is actually CLIMBABLE rather than a mantle-only target. Rungs tagged "bhladder",
deterministic, gated to stair buildings. Added `--citytest` assertion
`_test_bulkhead_ladder` (>=4 ascending steel "bhladder" rungs, footprints
inside the cap zone, bottom near deck + top at cap, deterministic, non-stair
buildings grow none).

[autopilot] iter 23: Phase I bulkhead plant-room details — steel hatch lid
+ 2 vent louvers on the cap surface (above doorway lane, inside the Phase
H rim), tagged "bhplant", gated to stairs. citytest + smoke green
(0 failures); new `_test_bulkhead_plant` assertion passes.

[autopilot] iter 22: Phase H bulkhead roof-exit rim railing — 4-segment
steel rail (0.45 m) around the hut cap, fully above the doorway lane
(exit path untouched), hut roof becomes a grabbable parkour lip; rim
tagged "bhexit", gated to stair buildings. citytest + smoke green (0
failures); new `_test_bulkhead_rails` assertion passes.

[autopilot] iter 21: Phase G rooftop water tower on large retail flat decks
(area >= 90 m^2, no attic) — four legs + tank + rim cap + ladder rungs,
seeded, clear of the bulkhead keep-out ring; tower boxes tagged "tower",
destructible steel. citytest + smoke green (0 failures); new tower
assertion passes.

[autopilot] iter 20: Phase F bulkhead keep-out clearance — ring grown by
PROP_CLEARANCE via new BULKHEAD_RING const; props/HVAC never clip the
roof-exit lane. citytest + smoke green (0 failures); strengthened citytest
assertion passes.

[autopilot] iter 19: Phase F inter-roof prop spacing optimization —
PROP_CLEARANCE 0.35 m buffer between adjacent roof props (HVAC duct +
scatter) via padded `_rect_obb`; prevents overlapping destructible boxes
at dense roof packing. citytest + smoke green (0 failures).

## Backlog
1. Phase D slice 5 COMPLETE: rooftop variety pass - retail roofs get
   billboards, residential gets laundry lines/pigeon coops (reuse
   _roof_props seeding). [COMPLETE in iter 17]
2. [Done] Phase E idea: parkour ledge-grab lip validation — all new
   destructible boxes' ledge-grab geometry satisfies the Phase E parkour
   test suite. Gate: --smoke. [COMPLETE in iter 18/19]
3. [Done] Phase F idea: inter-roof prop spacing optimization — prevent
   overlapping destructible boxes at dense roof packing. Gate: --citytest.
   [COMPLETE in iter 19]
4. [Done] Phase F idea: extend PROP_CLEARANCE to the stair bulkhead
   keep-out ring so roof props never clip the roof-exit lane. Gate:
   --citytest. [COMPLETE in iter 20]
5. [Done] Phase G idea: rooftop water tower landmark on the largest retail
   flat decks (tall standable tank on legs = fresh vantage + ledge lips).
   Gate: --citytest. [COMPLETE in iter 21]
6. [Done] Phase H idea: rooftop access railings on the stair bulkhead
   roof exit — steel rim around the hut cap (reads as landmark + grabbable
   parkour lip, sits above the doorway lane). Gate: --citytest.
   [COMPLETE in iter 22]
7. [Done] Phase I idea: roof-exit hatch lid / vents on the bulkhead cap so
   the hut roof reads as a serviced plant room (small destructible steel
   details on the cap, gated to the bulkhead cap zone). Gate: --citytest.
   [COMPLETE in iter 23]
8. [Done] Phase J idea: rooftop access ladder from the deck to the bulkhead
   cap rim — a steel rung ladder (destructible "bhladder") so the
   plant-room roof is actually climbable, not just a mantle target.
   Gate: --citytest. [COMPLETE in iter 24]
9. [Done] Phase K idea: facade balconies — AC-style cantilevered concrete
   decks + steel railing lip (grabbable parkour ledge) on upper storeys,
   deterministic, gated to multi-storey, tagged "balcony". Directly serves
   the Prague directive's named "balconies" parkour feature. Gate: --citytest.
   [COMPLETE in iter 25]
10. [Done] Phase M idea: awning-led low-mantle traversal — the street canopy
   deck (AWN_DECK_Y) becomes a grabbable entry perch feeding ledge/awning
   chaining on the ground floor; the Phase-E parkour controller now treats
   "awning" boxes as their own soft-structure grab class (vox_tag meta,
   awning_grabs counter, AWNING_DRIVE_SPEED follow-through). Gate: --smoke.
   [COMPLETE in iter 27]
11. [Done] Phase N idea: awning->balcony chain reach audit - verify (smoke
    fixture) that from a standable awning deck (2.3 m) a jump-grab can
    catch the first balcony deck of a 2-storey facade, making ground->
    first-floor traversal a real AC-style chain; tune AWN_DECK_Y/BAL
    heights only if the gap is unreachable. Gate: --smoke.
    [COMPLETE in iter 28] rise 1.45 inside 0.9-2.1, no tuning needed.
12. [Done] Phase O idea: construction scaffold on plaza-adjacent historic facades
    — steel pole cage + plank decks (standable) tagged "scaffold",
    deterministic, gated to plaza adjacency; adds mid-height AC
    scaffolding traversal. Gate: --citytest. [COMPLETE in iter 29]
13. [Done] Phase P idea: facade cornices + pilasters — horizontal stone cornice
    bands + vertical pilaster strips (grabbable ledge network) on historic
    multi-storey facades, tagged "cornice"/"pilaster", deterministic,
    gated to historic multi-storey + long facade; completes the AC
    "ledges/pillars" parkour vocabulary. Gate: --citytest.
    [COMPLETE in iter 30]
14. [Done] Phase Q idea: post-apoc facade decay pass — graffiti/decal layers, rust
    streaks, overgrowth/moss on historic facades, visual-only, deterministic,
    gated to historic district; brings the Prague core out of white-dummy into
    the directive's eerie decayed aesthetic. Gate: --citytest (determinism + gating).
    [COMPLETE in iter 31] graffiti (1.0-1.9x0.6-1.0) + rust (0.28x1.2-2.0) + moss
    (base strip 0.32h) as DECAY_T 0.02 thin visual planes just outside the wall,
    3 RNG channels, thin-plane + wall-face + determinism + 2 negative gates.
15. [Done] Phase R idea: broken-window variant — historic facades get random shattered/
    missing panes (glass removal / cracked visual) + interior darkness cue; plus
    street-level litter/debris pass (paper, bottles) as visual decals on the
    sidewalk; visual-only, deterministic, gated to historic. Gate: --citytest.
    [COMPLETE in iter 32] ~30% panes missing per historic facade as BROKEN_DARK_T
    0.03 dark planes tagged broken + 2-4 litter decals per side at LITTER_Y 0.035
    tagged litter, visual-only, thin-plane + outside-footprint + determinism +
    glass-reduction + 2 negative gates.
16. [Done] Phase S idea: interior darkness / night-lighting pass — night is genuinely
    dark in the historic core (NIGHT_SUN 0.015, NIGHT_AMBIENT 0.03, NIGHT_BG dark
    navy), windows with broken panes leak darkness vs intact panes catch
    streetlamp spill; DayNightController now re-queries streetlamp group live
    so streamed lamps work + ChunkBuilder emits real warm OmniLights (range 13,
    energy 2.8) per avenue (deterministic via MeshBatcher.street_lights()).
    Gate: --citytest.
    [COMPLETE in iter 33] genuine darkness + warm avenue pools, luminance/energy
    thresholds + avenue alignment + y=4.1 + determinism + node creation passing.
17. [Done] Phase T idea: lantern/torch handheld light as player-carried gameplay light —
   a bobbing point light following the player at night that makes darkness
   survivable and ties into the directive's "light as gameplay" survival
   mechanic. Gate: --smoke or --citytest.
   [COMPLETE in iter 34] Survivor LANTERN_RANGE 10 / ENERGY 2.2 / warm 1.0,0.85,0.58 shoulder offset 0.35,1.10,0.25 group player_lantern, night-only via GameClock.is_night() + sinusoidal bob (AMPL 0.045, FREQ 4.2 + walk sway); citytest + smoke green (0 failures); 1 new assertion ("player lantern: warm handheld light at night with bob").
18. [Done] Phase U idea: interior window glow — intact windows leak a faint warm interior point/spot at night (vs broken panes stay dark), reinforcing the lantern vs streetlamp reading and giving the Prague core a lived-in night silhouette from the street. Gate: --citytest or --smoke.
   [COMPLETE in iter 35] faint warm interior OmniLights 0.65m behind intact historic glass (WINDOW_GLOW_RANGE 5.5 ENERGY 1.15 warm 1.0/0.88/0.62 PROB 0.32 MIN_SIDE 5.0 group window_glow) night-only via DayNightController live re-query, vs broken panes stay dark; MeshBatcher.window_glows() deterministic via WorldSeed "window_glow" and manifest equality; ChunkBuilder spawns per-chunk lights counted in stats["window_glows"]; citytest + smoke green (0 failures); 1 new assertion ("window interior glow: faint warm lights behind intact historic glass at night").
19. [Done] Phase V idea: volumetric street ambience — faint ground fog / bloom halo around streetlamps + window glows via WorldEnvironment fog + volumetric emissive tweak, reinforcing light-as-gameplay without new geometry. Gate: --smoke or --citytest (fog params / luminance).
   [COMPLETE in iter 36] glow_enabled (intensity 0.62→0.28, strength 1.0, bloom 0.12, hdr 0.88/1.6 softlight) + volumetric_fog_enabled (density 0.022→0.005, emission 0.52→0.08, albedo 0.60/0.63/0.70 warm 0.86/0.68/0.42, length 64) breathing with day_factor, fog 0.008→0.0025, is_inside_tree() guard; citytest + smoke green (0 failures); 1 new assertion ("volumetric ambience: ground fog + bloom halo").
20. [Done] Phase W idea: flicker/dead-lamp variant — a deterministic subset of avenue streetlamps sputters (flicker ~0.18 amplitude, ~3 Hz noise) or stays dead (2-4% dark) for post-apoc horror, gated to avenue + historic; DayNightController flicker modulates energy without touching determinism; visual-only, no collision change. Gate: --citytest (flicker range / gating).
   [COMPLETE in iter 37]
21. [Done] Phase X idea: Prague facade signage — faded shop signs + house-number plaques as thin visual planes (SIGNAGE_T 0.02) on historic long facades (>=5.0), deterministic per (side,building) via WorldSeed house_num/shop_sign, house plaques 0.32 at y 1.35 beside door (HOUSE_PROB 0.60) + shop boards 0.85-1.45×0.42 at y ~2.02 (SHOP_PROB 0.48) on non-entrance walls, visual-only, layer f0 tagged signage, desaturated palette; city-test verifies thin-plane + ground-band + outside-footprint + deterministic + gating.
   [COMPLETE in iter 38] SIGNAGE_T 0.02 thin plane pressed 0.04 outside wall, plaque 0.32 at y 1.35 / board 0.85-1.45×0.42 at y ~2.02, desaturated Prague palette 4a5a6e/6e4a3a etc lerp 0.22 + plaque c8c4a8/d8cfb0/a8c4d8/d8b8a0, visual-only, layer f0 tagged signage; citytest + smoke green (0 failures); 1 new assertion ("facade signage: Prague shop signs + house numbers on historic facades (deterministic)" - thin 0.02 + ground-band 1.0-3.0 + outside-footprint + deterministic rebuild + non-historic/tiny gating + historic ring hit).
22. [Done] Phase Y idea: Prague facade drainpipes + eave gutters — vertical zinc/copper downpipes + horizontal gutters at the eave (DRAIN_T 0.06, DRAIN_GUTTER 0.07×0.08, 62% pipe+gutter pair per historic long facade >=5.0), deterministic per (side,building) via WorldSeed drainpipe, visual-only thin boxes pressed 0.05 outside wall (pipe full-height total_h-0.14 + gutter at eave total_h-0.075), zinc 5a6d6e / copper 6a7a5e patina, layer f0 tagged drainpipe; city-test verifies pipe square + gutter eave + thin + outside-footprint + visual-only + deterministic rebuild + pair count + gating.
   [COMPLETE in iter 39] DRAIN_T 0.06 / DRAIN_PIPE_PROB 0.62 / DRAIN_GUTTER_H 0.07 / DRAIN_GUTTER_T 0.08 with _facade_drainpipes (historic-gated >=5.0, deterministic per WorldSeed drainpipe, visual-only thin boxes pressed 0.05 outside wall — vertical pipe full-height total_h-0.14 + horizontal gutter at total_h-0.075 along eave, zinc 5a6d6e / copper 6a7a5e patina, layer f0 tagged drainpipe, even count pipe+gutter pairs); citytest + smoke green (0 failures); 1 new assertion ("facade drainpipes: Prague zinc/copper downpipes + eave gutters on historic facades (deterministic)" - pipe 0.06 square full-height + gutter 0.07×0.08 at eave + outside-footprint + visual-only + deterministic rebuild + pair count + non-historic/tiny gating + historic ring hit).
23. [Done] Phase Z idea: Prague window shutters — hinged wooden shutters flanking historic windows (SHUTTER_T 0.025, SHUTTER_W 0.30 x SHUTTER_H 1.22, SHUTTER_GAP 0.04, SHUTTER_PROB 0.52) pressed just outside historic long facades (>=5.0) beside each window at sill-mid height, deterministic per (building,side,floor,window) via WorldSeed shutter, visual-only thin planes 0.045 outside wall (left+right leaf pair per window), wood palette desaturated 0.12, layer f* tagged shutter; city-test verifies thin 0.025 + planar 0.30 + height 1.22 at window height + outside-footprint + visual-only + deterministic rebuild + even pairs + gating.
   [COMPLETE in iter 40] SHUTTER_T 0.025 / SHUTTER_W 0.30 / SHUTTER_H 1.22 / SHUTTER_GAP 0.04 / SHUTTER_PROB 0.52 with _facade_shutters (historic-gated >=5.0, deterministic per WorldSeed shutter per window, visual-only thin leaves 0.045 outside wall at window center y = WIN_SILL+WIN_H/2, left+right pair per qualifying window, wood palette lerp 0.12, layer f* tagged shutter, even leaf-pair count); citytest + smoke green (0 failures); 1 new assertion ("facade shutters: Prague wooden shutters flanking historic windows (deterministic)" - thin 0.025 + planar 0.30 + height 1.22 at window height + outside-footprint + visual-only + deterministic rebuild + even pairs + non-historic/tiny gating + historic ring hit).
24. [Done] Phase AA idea: Prague window flower boxes — terracotta trough + trailing bloom under historic sills (FLOWER_W 1.38 x FLOWER_H 0.18 x FLOWER_D 0.22 + BLOOM 1.27 x 0.12 x 0.19, 42% trough+bloom pair per historic window >=5.0), deterministic per (building,side,floor,window) via WorldSeed flowerbox, visual-only boxes pressed 0.045 outside wall (trough at WIN_SILL-FLOWER_H/2 + bloom at WIN_SILL+BLOOM_H/2 under window center), terracotta + bloom palette desaturated 0.18, layer f* tagged flowerbox, even trough+bloom pairs; city-test verifies trough 1.38 x 0.18 x 0.22 + bloom 1.27 x 0.12 x 0.19 at sill height + outside-footprint + visual-only + deterministic rebuild + even pairs + gating.
   [COMPLETE in iter 41] FLOWER_W 1.38 / FLOWER_H 0.18 / FLOWER_D 0.22 / FLOWER_BLOOM_H 0.12 / FLOWER_PROB 0.42 with _facade_flower_boxes (historic-gated >=5.0, deterministic per WorldSeed flowerbox per window, visual-only trough+bloom pressed 0.045 outside wall at sill height — trough WIN_SILL-FLOWER_H/2 + bloom WIN_SILL+BLOOM_H/2 under window center, terracotta + bloom palette lerp 0.18, layer f* tagged flowerbox, trough+bloom even pairs); citytest + smoke green (0 failures); 1 new assertion ("facade flower boxes: Prague terracotta trough + bloom under historic sills (deterministic)" - trough 1.38 x 0.18 x 0.22 + bloom 1.27 x 0.12 x 0.19 at sill height + outside-footprint + visual-only + deterministic rebuild + even pairs + non-historic/tiny gating + historic ring hit).
25. [Done] Phase AB idea: Prague window stone lintels — stone header (WIN_W 1.15 + 0.26 = 1.41 x WINDOW_TRIM_H 0.14 x WINDOW_TRIM_T 0.05, 58% per historic window >=5.0), deterministic per (building,side,floor,window) via WorldSeed window_trim, visual-only thin slab pressed 0.045 outside wall above window (header at WIN_SILL+WIN_H+0.02+0.07), stone 9e968a desaturated 0.10, layer f* tagged trim; city-test verifies thin 0.05 + 1.41 x 0.14 at header height + outside-footprint + visual-only + deterministic rebuild + gating.
   [COMPLETE in iter 42] WINDOW_TRIM_T 0.05 / WINDOW_TRIM_W 1.41 / WINDOW_TRIM_H 0.14 / WINDOW_TRIM_PROB 0.58 with _facade_window_trim (historic-gated >=5.0, deterministic per WorldSeed window_trim per window, visual-only thin slab pressed 0.045 outside wall at header height — header WIN_SILL+WIN_H+0.02+0.07 above window, stone 9e968a lerp 0.10, layer f* tagged trim); citytest + smoke green (0 failures); 1 new assertion ("facade window trim: Prague stone lintels above historic windows (deterministic)" - thin 0.05 + 1.41 x 0.14 at header height + outside-footprint + visual-only + deterministic rebuild + non-historic/tiny gating + historic ring hit).

## ⭐ USER DIRECTIVE (2026-08-26 evening) — PRAGUE ASSASSIN-CITY PIVOT
Supersedes current goal priorities after the in-flight Phase E slice lands:

1. ONE handcrafted great map (no multi-seed requirement): a Prague-style
   European historic core done to Assassin's-Creed standard.
2. REALISTIC ARCHITECTURE & SCALE: apartments with bedrooms/dining/kitchens/
   toilets; offices with office interiors; shops, grocery stores, malls,
   workshops, schools, universities — each building type with logical interior
   layout, and TOILETS/logical service rooms in every building. Human-scale
   floor heights (~3 m), believable room dimensions.
3. SPATIAL PARKOUR MECHANICS like AC: ledges, fences, gates, pillars, awnings,
   balconies, scaffolding, rooftops — the city is climbable as a traversal
   space, integrated with the Phase-E parkour controller.
4. POST-APOC EUROPEAN AESTHETIC — NO MORE WHITE-DUMMY LOOK: proper textures,
   shading/shadow/light systems, bloom, reflections, water rendering. Eerie
   horror zombie-apocalypse mood: decayed facades, graffiti, rust, overgrowth.
5. LIGHT AS GAMEPLAY: night is genuinely dark; lanterns/flashlights/fire/torch
   matter for visibility — light/darkness becomes a survival mechanic.
Keep gates green (citytest/smoke/cityruntime/havoctest/walkthrough).