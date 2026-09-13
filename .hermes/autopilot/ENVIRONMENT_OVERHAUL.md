# Ring Bell — Environment Simulation Overhaul (continuation document)

Authoritative notes for the environment subsystem: architecture, models, integration
points, verification commands, measured results and known limitations. Written so a
later model can continue without chat history.

Subsystem owner: `world/environment/` (`EnvironmentManager`).
Status: implemented, contract-tested, visual-matrix tested, performance-measured,
committed and pushed (see "Commits" at the end).

---

## 0. Constraints this work obeyed

- **Isolation from the concurrent interior overhaul.** Nothing in
  `world/generation/interior_plan.gd`, `world/generation/historic_interior_plan.gd`,
  room topology/partitions/door placement/floor-plan archetypes was touched.
  `building_builder.gd` and `chunk_builder.gd` were not modified.
  The environment reaches the world through three small, read-only interfaces:
  the camera-focus group (`player`), `World3D` raycasts (shelter), and global
  shader uniforms (materials). No building-generation logic was rewritten.
- **No graphics rewrite.** One `WorldEnvironment`, one sun, one moon, one sky
  shader, one camera-local particle box, one global-parameter publisher. No
  post-process stack was introduced; `Environment` tone-map/exposure settings are
  used, not abused (no bloom-heavy, vignette-heavy or saturated grading).
- Art direction guardrails encoded in constant *floors*: `MIN_AMBIENT_ENERGY`,
  `MIN_ZENITH_LUMA`, `MIN_HORIZON_LUMA`, `MIN_AMBIENT_LUMA` keep night and storm
  navigable; haze is capped by `MAX_VOLUMETRIC_DENSITY` ("haze, not a fog wall").

---

## 1. File map

| File | Role |
| --- | --- |
| `world/environment/environment_manager.gd` | **Authoritative singleton** (`class_name EnvironmentManager`, group `environment_manager`). Owns time, weather, atmosphere, precipitation, ambience, exposure; publishes global shader params; `save_state()`/`load_state()`; `state()` snapshot. |
| `world/environment/environment_config.gd` | Every tunable in one place: day length, solar constants, lat/long, wetness rates, gust model, lightning/thunder timing, episode lengths, per-quality budgets, rain geometry/colours, fog limits. No magic numbers in the controllers. |
| `world/environment/time_of_day.gd` | Pure time/solar math: hour/minute from minutes, solar elevation/azimuth for Prague latitude, phase names, moon visibility. No nodes. |
| `world/environment/weather_model.gd` | Deterministic weather state machine: `State` enum, per-state parameter targets, `TRANSITIONS`, `state_from_name()`. Pure data + math. |
| `world/environment/weather_controller.gd` | Runs the episode machine: picks the next state deterministically, blends parameters over `TRANSITION_MINUTES`, emits `lightning_struck`, exposes `force_lightning()`, `save_state()`/`load_state()`. |
| `world/environment/atmosphere_controller.gd` | Builds/owns `WorldEnvironment`, sky, `EnvironmentSun`, `EnvironmentMoon`, the lightning bolt node; drives sky shader uniforms, ambient/directional energy, fog + volumetric fog, night floors, lightning flash envelope. |
| `world/environment/precipitation_controller.gd` | Camera-local rain (one `CPUParticles3D` box); intensity → `amount`, `emitting`, wind-driven `gravity`, streak colour; parks the emitter when dry (engine rejects `amount = 0`). |
| `world/environment/environment_ambience.gd` | Procedural exterior ambience (wind bed, rain bed, thunder) synthesised in-engine — no external/proprietary audio assets required; per-state mixing, shelter attenuation, deterministic noise seeds. |
| `world/environment/exposure_probe.gd` | Indoor/outdoor shelter probe: throttled `World3D` raycasts (up for roofs, plus a short forward/lateral set), returns a 0..1 shelter value, `force()` override. |
| `world/environment/environment_debug.gd` | Runtime debug: F-keys, cycle helpers, `overlay_lines()` for the on-screen readout. |
| `world/environment/shaders/environment_sky.gdshader` | Analytic stylised sky (time, cloud, rain, storm, fog uniforms). Cheaper than a physical atmosphere; no textures. |
| `world/environment/shaders/wetness_overlay.gdshader` | **Reference consumer** of the global environment uniforms — the on-record contract for material integration. |
| `debug/environment_test.gd` | `--envtest`: headless contract harness (standalone minimal world; does not need the streamed city). |
| `debug/environment_capture.gd` | `--envcapture`: windowed visual matrix (13 frames) + readability metrics + assertions. |
| `debug/environment_perf.gd` | `--envperf`: frame-cost comparison on the **real streamed city** (clear / cloudy / heavy rain / storm). |
| `world/main.gd` | Bootstrap only: creates the manager, wires `--envtest` / `--envcapture` / `--envperf`, keeps the CLI flag list. The old `DayNightController` member is gone. |
| `project.godot` | `[shader_globals]` declarations for the six environment globals. |

---

## 2. Time architecture

- `GameClock` (autoload) holds `total_minutes`, `time_scale` (speed only), `paused`.
  `EnvironmentManager` reads it and never keeps a second clock.
- `EnvironmentConfig.DAY_LENGTH_SECONDS := 1440.0` — **one in-game day = 24 real
  minutes** (configurable, clamped to `MIN_DAY_LENGTH_SECONDS` 120 s … `MAX_DAY_LENGTH_SECONDS` 14400 s).
- Progression is `total_minutes += delta * 1440 / day_length * scale`, i.e.
  simulation-time based, frame-rate independent. Freezing is supported
  (`GameClock.paused` / the F8 key / debug API) and does not disturb weather.
- Solar geometry: `LATITUDE_DEG := 50.08` (Prague), `SOLAR_DECLINATION_DEG := 12.2`,
  `SOLAR_ZENITH_HOUR := 13.0` (true solar noon in CET, not literal 12:00),
  `MOON_CYCLE_DAYS := 29.53`. Phases: `dawn, morning, noon, afternoon, sunset, evening, midnight, pre_dawn`
  (`time_phase_changed` signal).
- All lighting quantities are continuous functions of solar elevation; there are no
  hard sunrise/sunset switches and no per-frame discontinuities.

## 3. Weather architecture

- States (`WeatherModel.State`): **clear, partly_cloudy, cloudy, fog, light_rain,
  heavy_rain, storm** — plus thunder behaviour inside `storm`.
- Each state is a parameter target set: `cloud`, `precipitation`, `fog`, `storm`,
  `wind_speed`, `wind_direction`.
- Transitions blend every parameter over `TRANSITION_MINUTES := 75` game minutes
  (≈ 1.25 real minutes at the default day length), so `CLEAR → STORM` can never pop;
  only debug force takes the short path.
- Episodes last `EPISODE_MIN_MINUTES` 60 … `EPISODE_MAX_MINUTES` 240 game minutes;
  the next state is chosen from `WeatherModel.TRANSITIONS`.
- **Determinism**: every random draw goes through `WorldSeed.rng_for(purpose, [ints])`
  keyed by the world seed + world day + state (`WorldSeed.combine` mixes integers
  only, so all tunables are fixed-point ints). Given the same world seed and time,
  the weather sequence, gust phases, lightning timing and ambience noise are
  reproducible. No `randf()`/`Math.random` anywhere in the subsystem.
- Wind: base speed per state, direction drifting deterministically, gust modulation
  (`GUST_FREQUENCY` 0.09 cycles/game-minute, `GUST_AMPLITUDE` ±22 %). Exposed as
  `wind_vector()`, `state()["wind_speed"]`, `state()["wind_dir_deg"]` (wrapped to
  0..360), global `environment_wind_vector`.

## 4. Atmosphere, sky, sun and moon

- One `WorldEnvironment` + one `Environment` resource, one `DirectionalLight3D` sun,
  one moon light, realtime `Sky` with `environment_sky.gdshader`
  (`radiance_size = 256`, the value the renderer enforces for realtime skies).
- Sky colour is a two-axis gradient (zenith/horizon) blended by daylight, dusk and
  storm factors; cloud cover drives stylised cloud masks in the shader.
- Sun: colour/intensity from elevation (`SUN_NOON` → `SUN_DUSK` → `SUN_NIGHT`),
  low-angle at dawn/dusk for long shadows, solar contribution fades to zero
  scientifically at night (`daylight → 0`).
- Moon: separate light with `MOON_CYCLE_DAYS` phase, `MOON_MIN_VISIBILITY := 0.45`
  floor so night is never pitch black; night ambient floors
  (`MIN_AMBIENT_ENERGY` 0.028, `MIN_ZENITH_LUMA` 0.010, `MIN_HORIZON_LUMA` 0.018,
  `MIN_AMBIENT_LUMA` 0.10) keep shapes readable — street lamps can still add on top.
- Fog: `Environment.fog_*` always on (cheap), plus volumetric fog used only when
  fog/rain/storm call for it, capped by `MAX_VOLUMETRIC_DENSITY`.
  Night haze is **lit, not self-luminous**: `VOL_FOG_ALBEDO_DAY` is day-only and the
  night albedo follows the sun; `VOL_FOG_EMISSION_NIGHT := 0.04` (below the day
  value of 0.10). This is the fix for "midnight rendered as grey overcast".

## 5. Rain

- One `CPUParticles3D` box parented to the manager, **follows the camera focus** —
  never city-wide, never per building.
- Density scales with precipitation and quality:
  `QUALITY_RAIN_AMOUNT` LOW 1800 / MEDIUM 4200 / HIGH 6800 streaks;
  `RAIN_BOX_METERS := 11.0`, `RAIN_BOX_HEIGHT := 12.0`, `RAIN_BOX_LIFT := 5.5` —
  deliberately small so the budget reads as *density* near the player.
- Streaks: `RAIN_STREAK_LENGTH := 0.95` m × `RAIN_STREAK_WIDTH := 0.065`,
  `RAIN_FALL_SPEED := 19.0` m/s; colour `RAIN_COLOR` (α 0.50) → `RAIN_COLOR_STORM`
  (α 0.62) so rain reads against dark facades.
- Wind influence: the slant lives in the streak **velocity** —
  `direction = normalize(wind.x * RAIN_WIND_FACTOR, -fall_speed, wind.z * RAIN_WIND_FACTOR)`
  with `initial_velocity_min/max` around its magnitude (`RAIN_WIND_FACTOR := 1.1`,
  `RAIN_GRAVITY_FACTOR := 0.35` for a residual fall arc, `RAIN_SPREAD_DEG := 4.0`).  The
  material uses `BILLBOARD_PARTICLES` with `particle_flag_align_y = true`, so a streak is
  oriented along its own velocity.  The slant *must* be in the velocity: bending gravity
  alone left streaks born at rest (no velocity to align to), and at the old
  `RAIN_WIND_FACTOR 3.0` the lateral acceleration walked most of the budget out of the
  camera-local box before a streak had fallen.
- When dry, the emitter is parked (`amount = _amount_step`, `emitting = false`,
  `visible = false`) because the engine rejects `amount = 0`; `active_particles()`
  reports 0 while parked and `rain_particles()` exposes the live budget.
- Indoor reduction: the precipitation controller takes the shelter value and
  suppresses streaks that fall between the camera and the roof (see §7): proportional
  first (`SHELTER_RAIN_REDUCTION := 0.92`), then a **hard cutoff** above
  `SHELTER_RAIN_CUTOFF := 0.95`, because a proportional cut alone still left 8% of a
  storm falling inside a room.  A budget that quantises to zero parks the emitter, so a
  drizzle thinner than one `_amount_step` draws nothing instead of one whole step.

## 6. Wetness

- Global parameter: `wetness` 0..1, `WETNESS_GAIN_PER_GAME_MINUTE := 0.055` while
  `precipitation > WETNESS_PRECIP_THRESHOLD` (0.02 — the same value as
  `RAIN_MIN_PRECIPITATION`, so the road starts to darken on the frame the first streaks
  appear), drying at `WETNESS_DRY_PER_GAME_MINUTE := 0.0042` (≈ 13× slower than wetting).
- Integration is in **fixed game-minute substeps**: `WETNESS_MAX_JUMP_MINUTES := 5.0` is
  the substep size, one frame integrates at most
  `WETNESS_MAX_SUBSTEPS (12) × 5.0 = 60` game minutes, and each substep samples the model
  at its own minute.  A long frame therefore lands the same as many short ones (the old
  single clamp truncated a 12-minute frame to 5, making the road depend on frame history),
  while a debug time skip still cannot soak or dry the whole city in one frame.
- **Material contract**: six global shader uniforms published by the manager —
  `environment_wetness`, `environment_rain_intensity`, `environment_wind_vector`,
  `environment_night_factor`, `environment_hour`, `environment_storm` — declared in
  `project.godot [shader_globals]` and verified at runtime by
  `_check_global_params()` (publishing an undeclared global spams an engine error
  every frame). A material opts in with `global uniform float environment_wetness;`
  and nothing else — no per-material bookkeeping, no per-frame material loops.
  **Real consumers since the fix pass**: `world/streaming/urban_paving.gdshader` (streets)
  and `world/streaming/surface_atlas.gdshader` (surfaces and building faces) — both darken
  albedo and drop roughness with wetness.  Before that, the only consumer was the
  unreferenced reference shader, so wet roads existed in the capture fixture and nowhere in
  the game.  `shaders/wetness_overlay.gdshader` stays as the reference consumer.
- Demonstrated effect: wet surfaces darken in albedo (diffuse) and gain a
  sky-reflecting gloss (highlight percentile up) — both verified in `--envcapture`.
- Puddles: intentionally not implemented (optional per the brief). The wet-road
  gloss carries the read; no decals, no extra draw calls.

## 7. Shelter / indoor-outdoor hook

- `exposure_probe.gd` returns a 0..1 shelter value: roof rays up plus a short
  throttled** (not every frame, no per-entity raycasts).
  The value is `hits / RAY_COUNT`: **one** ray is partial cover (an awning, a bridge, a
  doorway) and only two or more overlapping rays pass `SHELTER_INDOOR_THRESHOLD` (0.60).
  Dividing by 1.5 made a single ray read 0.67 — i.e. "indoors" — which muted the ambience
  and cut the rain under any narrow overhang.  `force(value)` overrides it for tests (F12).
- **The building world owns "inside".** `CityInteriorState` decides it (the camera rig
  carries the answer); the environment consumes that via `set_interior_claim()`, fed from
  the rig's read-only `is_interior_active()`, and takes the union with its own rays.  The
  probe cannot re-derive it: the interior ceiling caps are presentation-only geometry, so a
  ray sees open sky from inside a room.
- The probe follows the **player**, not the camera: `tick()` retries
  `resolve_default_focus()` for the first `FOCUS_RESOLVE_FRAMES` (180) frames, and that
  resolver falls back to the camera rig's public `target` because nothing in this project
  claims the `player` group.  The camera sits on a boom metres away and can be the only
  thing under a roof.
- Consumers: precipitation (rain visible only outside, plus an indoor acoustic-ish
  reduction), ambience (rain/wind beds attenuate indoors), `is_indoors()`,
  `state()["exposure"]`, `state()["indoors"]`.
- No interior was redesigned; the probe only *queries* `World3D`.
- Future hooks (deliberately left for later): wetness accumulation indoors,
  footstep acoustics, interior light leak when the door is open.

## 8. Lightning and thunder

- Lightning only exists inside storm conversations and is fully optional if a
  project decides to mute it; scheduling: `LIGHTNING_STRIKE_MIN_GAP` 2.6 … 
  `LIGHTNING_STRIKE_MAX_GAP` 11.0 game minutes, `LIGHTNING_MAX_STRIKES_PER_EPISODE` 64,
  storm build-up `LIGHTNING_STORM_BUILD_MINUTES` 10, and an anti-strobe valve
  `LIGHTNING_MIN_REAL_GAP := 2.0` **real seconds** — applied as the game-minute gap
  `max(LIGHTNING_STRIKE_MIN_GAP, 2.0 × GameClock.time_scale)`, so it still stops a
  fast-forwarded storm from flickering while the strike schedule remains a function of game
  time rather than of the frame clock.
- A strike is **multi-stage**: 1..N stages per quality
  (`QUALITY_LIGHTNING_STAGES`), a visible bolt mesh (9 segments, `BOLT_VISIBLE_SECONDS`
  0.14, spawned 220 m+ away at 260 m altitude) plus a flash envelope on sky/ambient
  directional energy (`FLASH_COLOR`).
- The flash lights the **street**, not only the sky: the ambient light takes
  `FLASH_AMBIENT_GAIN` and leans `FLASH_AMBIENT_TINT` towards `FLASH_COLOR` while a flash
  is up.  The sky shader already took `flash`, so before this a night strike brightened the
  sky over an unchanged dark street.
- The bolt is **depth-tested** (a building hides a bolt behind it) and its drawn distance is
  clamped inside the camera's far plane (`BOLT_MAX_DRAWN_DISTANCE` and the per-frame
  `_frame["camera_far"]`), so lowering the view-distance setting cannot clip it away.  It
  used to draw straight through walls because it had `no_depth_test = true`.
- Thunder: distance from the bolt, propagation at `THUNDER_SPEED_MPS := 343.0`,
  delay clamped to `THUNDER_DELAY_MIN` 0.35 … `THUNDER_DELAY_MAX` 18.2 s (the old 11 s cap
  clipped the ~16 s delay of a 5.5 km strike), delivered on
  the `lightning_event(intensity, distance_m, delay)` signal and drained by the
  ambience layer. Audio is **synthesised in-engine** (`_make_thunder()`,
  filtered noise + envelope), so thunder works with zero external assets; drop
  `res://audio/environment/thunder_*.ogg` in place and `_load_or_make()` prefers it.

## 9. Ambience

- Beds: wind (LP-filtered noise, gust-modulated), rain (light/heavy), storm, thunder.
  All generated procedurally at 22050 Hz into `AudioStreamWAV` loops — no
  copyrighted downloads, no missing-asset breakage.
- Synthesis is **spread over frames**: the beds are queued (rain → wind → thunder) and one
  is built per frame, instead of all three in a single deferred call — which was one
  main-thread stall inside world construction (~250k filtered samples plus an s16 encode per
  loop).  `state()["synth_steps"]` and `state()["synth_ms"]` report the measured cost.
- Mixing is driven by the same parameters as the visuals: `update_frame(precipitation,
  storm, wind_speed, shelter)`; `state()` exposes levels; `last_thunder_db()` and
  `stream_bytes()` exist for tests/assertions.
- Expected external asset slots (documented, not required):
  `res://audio/environment/wind_loop.ogg`, `rain_loop.ogg`, `heavy_rain_loop.ogg`,
  `thunder_near.ogg`, `thunder_far.ogg`.

## 10. Save / load and chunk streaming

- `save_state()` is **self-sufficient**: `version`, `quality`, `time_scale`,
  `time_paused`, `clock_minutes`, plus weather/transition/wetness/wind continuation
  from the weather controller. `load_state()` restores `GameClock.total_minutes`
  (`maxf(0.0, ...)`), quality, scale, pause, and the weather episode — so a reload
  resumes the *same* sky, not a new random one.
- The subsystem is world state, not chunk state: it is not parented to chunks, holds
  no chunk references, and chunk streaming therefore cannot reset time, weather,
  wetness or duplicate rain/lights. Verified by `--envtest`
  (`world_state_not_chunk_state`, singleton/no-duplicate tests) and by `--envperf`
  counting environment-owned nodes across streaming (`world_envs > 1` = failure).

## 11. Quality scaling

`Quality` LOW / MEDIUM / HIGH (`QUALITY_NAMES`, F11 cycles): rain amount, rain
`fixed_fps`, cloud steps, volumetric-fog availability and lightning stages all scale;
LOW stays coherent (cheap sky, fewer streaks, no volumetric fog) rather than broken.

## 12. Debug controls

CLI (bypass the main menu):
- `--envtest` — headless contract harness, exits with a failure count.
- `--envcapture` — windowed visual matrix into `captures/environment/` + `summary.md`.
- `--envperf` — windowed frame-cost comparison on the streamed city.
- `--envtime=H`, `--envweather=state`, `--envquality=low|medium|high`,
  `--envwetness=F`, `--envwind=F`, `--envdump` — force values and print state.

Runtime (debug builds; the flag line is printed once at startup):
- **F6** cycle time anchors (06:00 / 12:00 / 18:00 / 00:00)
- **F7** cycle weather (clear → cloudy → fog → light rain → heavy rain → storm)
- **F8** freeze/unfreeze time
- **F10** force a lightning strike
- **F11** cycle quality
- **F12** cycle shelter override (auto → indoors → outdoors)
- **P** print the environment state dictionary.

Overlay (`overlay_lines()`): clock, phase, weather + target, transition progress,
rain intensity, cloud, fog, wind speed/direction, wetness, indoors, quality.

## 13. Verification (commands + measured results)

All run from the project root; Godot 4.7.2 stable, Forward+/Vulkan.

| Command | Result |
| --- | --- |
| `Godot --headless --path . -- --envtest` | **103 checks, 0 failures** (pre-fix pass); the fix pass re-ran it in an isolated worktree — see §15.5 |
| `Godot --headless --path . --script debug/weather_model_check.gd` | **16 checks, 0 failures** — model maths with no world: cross-midnight continuity, wetness frame-independence, tuning invariants (~5 s) |
| `Godot --headless --path . --script debug/environment_shader_check.gd` | **10 checks, 0 failures** — shader compile, published-vs-declared global parameters, wetness consumers (~5 s) |
| `Godot --path . -- --envcapture` | **13 frames, 0 metric failures** + PNGs |
| `Godot --path . -- --envperf` | see §14 |
| `Godot --headless --path . -- --cityruntime` | **streamed city: 0 failures** (chunk ring build, unload/reload, collision, stairs, door-id determinism, camera sectors) — the environment system sits in this boot path, so this is the regression gate for criterion 13 |
| `Godot --headless --path . --check-only --script <env script>` | clean |

Contract checks include: deterministic time progression, deterministic weather
progression (same seed+day ⇒ same state sequence), valid transitions only, no
`CLEAR → STORM` shortcut, save/load restoration, wetness rise/fall, parameter range
validity, no duplicate manager, forced debug weather, wind vector coherence.

Readability metrics (`--envcapture`, mean luminance of the frame):

| Frame | mean | p01 | p99 | crushed | blown |
| --- | --- | --- | --- | --- | --- |
| 01-clear-morning 08:00 | 0.225 | 0.156 | 0.453 | 0.00 % | 0.00 % |
| 02-clear-noon 12:00 | 0.280 | 0.172 | 0.531 | 0.00 % | 0.00 % |
| 03-sunset 18:30 | 0.173 | 0.125 | 0.313 | 0.00 % | 0.00 % |
| 04-clear-midnight 00:00 | 0.065 | 0.031 | 0.109 | 0.00 % | 0.00 % |
| 05-fog-morning 07:00 | 0.152 | 0.094 | 0.359 | 0.00 % | 0.00 % |
| 07-light-rain-day 11:00 | 1750 streaks live | — | — | 0.00 % | 0.00 % |
| 08-heavy-rain-night 22:00 | 3150 streaks live | — | — | 0.00 % | 0.00 % |
| 09/10-storm day+night | 4200 streaks live | — | — | 0.00 % | 0.00 % |
| 11-lightning-flash (storm 14:00) | 0.326 → **0.417** (+0.091) | — | — | — | — |
| 12/13-road dry → wet | mean 0.284 → 0.324, p99 0.516 → 0.563 | — | — | — | — |

Interpretation: midnight is genuinely night (0.065) while noon is 0.280, and **no
frame crushes shadows or blows highlights** — the "night must stay playable, no
muddy grey" requirement is measured, not asserted by eye.

## 14. Performance

`--envperf` on the real streamed city (same camera path, same focus, forced states,
city generation excluded from the sample window; medium quality, 170 157 world nodes,
3 937 lights, ~13 850 draw calls — the city's own baseline, not the environment's):

| State | avg | fps | p99 | worst | live rain | Δ vs clear |
| --- | --- | --- | --- | --- | --- | --- |
| clear | 25.98 ms | 38.5 | 86.90 ms | 143.10 ms | 0 | — |
| cloudy | 35.45 ms | 28.2 | 77.53 ms | 79.66 ms | 0 | +9.47 ms |
| heavy_rain | 30.63 ms | 32.7 | 73.43 ms | 74.46 ms | 1400 | +4.64 ms (+17.9 %) |
| storm | 28.54 ms | 35.0 | 50.00 ms | 60.94 ms | 1750 | +2.56 ms (+9.9 %) |

- Environment-owned nodes stay **constant** across three weather transitions while
  chunks stream: `nodes +0`, `world_envs 1`, `{suns: 1, moons: 1, managers: 1, rain: 1}`
  before and after — no duplicate sun/moon/rain, no runaway node count.
- Rain costs ~1 particle box (1 400–1 750 live streaks at medium, ramping up);
  draw calls move by <1 % (13 850 → 13 913).
- The spread between states (cloudy slower than storm) is **run-to-run noise**, not a
  storm cost: each state is a single short sample on a laptop GPU, with a stray
  second Godot process (a deleted copy running from the Recycle Bin) resident. The
  honest reading is "no environment state costs more than measurement noise on top of
  the city", which is what the node/draw/particle invariants independently confirm.
- Design reasons it stays cheap: one manager, one `WorldEnvironment`, two lights, one
  sky shader, one camera-local particle box, global uniforms instead of per-material
  loops, throttled shelter raycasts, event-driven lightning, interpolated parameters,
  no per-frame allocations in steady state.

### 14.1 Reading the logs (pitfall)

Background runs are launched as `... > "$OUT" 2>&1; echo "exit=$?" >> "$OUT"`, so the shell
wrapper itself always exits 0 -- a run that dies during city generation still reports "completed
normally". **The real status is the `exit=` line inside the log, and the only proof a suite ran
is its own summary line.** `envperf4.txt` is the cautionary example: six lines, zero `EnvPerf`
rows, `exit=127` (the process died during streamed-city generation, before the settlement wait
that precedes measurement). It is a dead run, not a baseline -- `envperf5.txt` is the run that
carries data. Timing runs by file mtime rather than by completion notification is what makes
this distinguishable.

## 15. Audit remediation (the HIGH / MEDIUM / LOW fix pass)

A read-only adversarial audit of the shipped subsystem produced 18 findings; this pass
fixed all of them.  Evidence keys: **WM** = `debug/weather_model_check.gd` (16 checks,
~5 s, no world), **SC** = `debug/environment_shader_check.gd` (10 checks, ~5 s), **ET** =
`--envtest`, **EC** = `--envcapture`.

### 15.0 HIGH

| # | Finding | Fix | Evidence |
| --- | --- | --- | --- |
| 1 | Weather popped at 00:00 — a day's first episode had no `prev` to blend from, so a day that ended in a storm snapped `precipitation 1.00 → 0.00` in one frame. | `WeatherModel.sample()` carries in the previous day's last episode as the blend source (`_carry_in`). | WM: worst step across 40 midnights **0.0000**; "a midnight after a storm still reads as a storm (3 of 3)" |
| 2 | It still rained indoors: the shelter cut was proportional (`× 0.92`) and `maxi(budget, _amount_step)` re-inflated a near-zero budget to a full step (~350 streaks). | `SHELTER_RAIN_CUTOFF := 0.95` stops it outright under a real ceiling; the `maxi` floor is gone and a budget that quantises to zero parks the emitter. | ET: "rain stops outright under a real ceiling (0 particles)" |
| 3 | Wetness was invisible in the shipped game: the six published globals had no real consumer (only an unreferenced reference shader). | `world/streaming/urban_paving.gdshader` + `surface_atlas.gdshader` (the city's actual street/surface materials) declare and use `global uniform float environment_wetness` — albedo darkening + roughness drop. | SC: both "consumes environment_wetness" checks and the compile checks |
| 4 | The shelter probe never ran on the player: nothing called `set_focus()`/`resolve_default_focus()` and no node joins group `player`, so the probe used the camera boom. | `tick()` retries `resolve_default_focus()` for `FOCUS_RESOLVE_FRAMES` frames; the resolver falls back to the camera rig's public `target`. | ET probes after adopting the rig target; WM/SC cover the contract |
| 5 | One roof ray read as "indoors" (`hits / 1.5` → 0.67 ≥ 0.60): any awning muted the ambience and cut the rain. | `hits / RAY_COUNT` — one ray is partial cover (0.33), two is a ceiling (0.67). | WM: "one of three roof rays stays under the indoor threshold"; ET: "one roof ray is partial cover, not indoors" |
| 6 | A second, disagreeing interior authority: the environment derived inside/outside from rays while `CityInteriorState` (via the camera rig) owns it — and the ceiling caps are presentation-only, so a ray sees open sky from inside a room. | The probe consumes the building world's answer (`set_interior_claim()`, fed from the rig's new read-only `is_interior_active()`) and takes the union with its rays. | ET: "an interior claim alone makes the probe report indoors" + "and it stops the rain the way a real ceiling does" |

### 15.1 MEDIUM

| # | Finding | Fix | Evidence |
| --- | --- | --- | --- |
| 7 | Saved glow/distance-fog settings were clobbered on cold start (built with `= true`; `GameSettings` only re-applies on pause-menu open). | The atmosphere reads the same `GameSettings.graphics(...)` keys the applier writes (`distance_fog`, `glow`, `volumetric_fog` — the last also AND-ed with quality). | code; the applier is now a no-op path at build |
| 8 | Lightning lit only the sky, and bolts drew through buildings. | The flash adds bounded ambient energy (`FLASH_AMBIENT_GAIN`) and tints the ambient colour (`FLASH_AMBIENT_TINT`); the bolt is depth-tested with its drawn distance clamped inside the camera far plane (`BOLT_MAX_DRAWN_DISTANCE`, `_frame["camera_far"]`). | EC readability frame (see §13) |
| 9 | Storm rain spent most of its budget off-box: the wind bend was *acceleration* (up to ~86 m/s² lateral) and streaks were born at rest with `particle_flag_align_y` on an undefined direction. | The slant moved into `direction` + `initial_velocity_*` (streaks are born moving along the wind), gravity keeps a small residual fall (`RAIN_GRAVITY_FACTOR`), and `RAIN_WIND_FACTOR` 3.0 → 1.1. | WM: "storm rain is slanted, not horizontal (1.62)" + "the wind factor stays at the retuned value (1.10)" |
| 10 | Rain's minimum was a whole quantisation step: any drizzle above the threshold drew ~350 streaks. | Covered by #2 — a zero budget parks the emitter. | ET: `rain_particles() == 0` below one step |
| 11 | Thunder distance fidelity: everything past 1.4 km sounded identical, and the 11 s delay cap clipped a 5.5 km strike (~16 s). | Distance curve `THUNDER_FULL_M 1400 → THUNDER_SILENT_M 6200` with `THUNDER_DB_FALLOFF 30`, pitch `0.90 → 0.60`, delay cap 18.2 s (covers 6243 m). | WM: "the thunder delay band covers THUNDER_SILENT_M (6243 m at the 18.2 s cap)" |
| 12 | Ambience synthesis was one main-thread stall at world build (~250k filtered samples + s16 encode). | Generation is queued rain → wind → thunder, one stream per frame; the measured cost is exposed as `state()["synth_ms"]`/`["synth_steps"]`. | ET: "ambience synthesis is spread over frames, not one stall" + the reported ms |

### 15.2 LOW

- **Determinism.** Wetness integrates in fixed game-minute substeps bounded to
  `WETNESS_MAX_SUBSTEPS × WETNESS_MAX_JUMP_MINUTES` per frame, so a frame hitch lands the
  same as many short frames; the lightning anti-strobe valve is now a game-minute predicate
  scaled by `GameClock.time_scale`.  Evidence: WM "wetness does not depend on frame length
  (0.2244 vs 0.2244)", "a time skip cannot dry the world out in one frame (0.2480)".
- **Debug overrides in saves.** `load_state()` warns when a restored save carries a forced
  weather state instead of silently forcing the weather for the rest of the run.
- **Doc drift.** The `precipitation_controller.gd` header box (44×30×44 → 11×12×11), the
  shelter comment and the wind comment now match the shipped values.
- **Threshold split.** `WETNESS_PRECIP_THRESHOLD` 0.03 → 0.02 = `RAIN_MIN_PRECIPITATION`.
- **Magic numbers.** `1440.0` → `EnvironmentConfig.MINUTES_PER_DAY` in `weather_model.gd`.
- **Per-frame material write.** `_material.albedo_color` is change-gated.
- **Debug hotkeys.** `--envkeys=off` drops the F-key bindings while keeping the state
  publishing (`--envdebug` still gates the panel itself).

### 15.3 Audit corrections (findings that were wrong)

- "Dead config constants `VOL_FOG_ALBEDO_NIGHT` / `VOL_FOG_EMISSION_TINT_NIGHT`" — **wrong**:
  both are live in the night volumetric-fog branch.  Nothing was removed.
- "Unused `dust` constant" — **wrong**: a grep artefact (`industrial_corridor` matched
  "dust").  No such constant exists in the subsystem.
- The published globals are `environment_rain_intensity`, `environment_storm`,
  `environment_night_factor`, `environment_hour` — not `environment_rain`,
  `environment_cloud_cover`, `environment_night`.  The first draft of the new shader gate
  used the wrong names and the renderer rejected the writes, which is how the mistake
  surfaced; the gate now compares the manager's `GLOBAL_PARAMS` against `project.godot`.

### 15.4 New fast gates (run these before the slow suites)

| Command | Result | Scope |
| --- | --- | --- |
| `Godot --headless --path . --script debug/weather_model_check.gd` | **16 checks, 0 failures** | model maths, no world: cross-midnight continuity, wetness frame-independence/bounds, tuning invariants |
| `Godot --headless --path . --script debug/environment_shader_check.gd` | **10 checks, 0 failures** | shader compile + published-vs-declared global parameters (names *and* types) + wetness consumers |

Both gates were verified with negative controls: injecting a shader syntax error makes the
shader gate fail (`SHADER ERROR: Invalid assignment of 'void' to 'float'`), and the model
gate caught a real bug in this very pass (a substep clamp that bounded the *count* but left
the integrated *duration* unbounded) before the slow suite ever ran.

### 15.5 Verifying while another track is mid-overhaul

The shared tree could not run any harness for part of this pass, for two reasons that are
**not** the environment subsystem:

1. **Stale global class cache (fixed).** `world/main.gd` failed to compile —
   `Identifier "MeleeCombos" not declared` — because `.godot/global_script_class_cache.cfg`
   (01:45) predated the merge that brought in `actors/weapons/melee_combos.gd`.  That makes
   *every* harness die before it starts (the engine cannot load `main.gd`).  Fixed with
   `Godot --headless --path . --import` (build cache only — no source file was touched).
   Symptom to remember: a run whose log contains no harness banner at all.
2. **Interior planner error loop (reported, not touched).** Chunk materialization then hits
   `ERROR: Internal bug ... CowData was modified during destruction` from
   `world/generation/floorplan/floor_plan_planner.gd:1080` (`_validate` ← `_candidate` ←
   `plan_best` ← `interior_plan.gd:111`), so `--envtest` / `--cityruntime` never reach their
   assertions in this tree.  That code belongs to the interior/room-placement track.

Because of (2), the fix pass was verified in an **isolated git worktree** at the last green
environment commit with only the changed environment files copied in:

```
git worktree add --detach "C:/Vibe Code project/junk/rb-envverify" eda4eb1
# copy world/environment/*, the two city shaders, camera/follow_camera.gd, the debug tools
Godot --headless --path . --envtest        # run from the worktree
```

The worktree is kept (not deleted) so the environment subsystem can be re-verified while the
interior track is mid-overhaul; the two fast gates in §15.4 need no world at all and run in
the shared tree.

## 16. Known limitations

1. Rain streaks are thin geometry: they read clearly in motion and in the storm
   frames, but a *single still frame* under-counts apparent density. Wind slant is
   present in the particle velocity and the streak orientation; in a still frame
   down a straight alley it reads subtler than it does in play.
2. Thunder is synthesised noise; the fix pass made distance read as volume *and*
   duration (30 dB falloff over 1.4–6.2 km, pitch 0.90 → 0.60), but a real recording
   sample (documented slot) would still improve near-strike punch.
3. Volumetric fog is quality-gated; LOW falls back to depth fog only.
4. Puddles are not implemented (optional per the brief); wet roads are handled by
   the wetness parameter.
5. The capture fixture is a procedural blockout (flat faces, no windows/lamps), so
   its absolute luminance values are fixture-specific — the *ratios* (night vs noon,
   dry vs wet) are the meaningful measurements.
6. `EnvironmentManager` is expected to be created by `world/main.gd`; other scenes
   that build their own world must create it explicitly (or load `--envtest`'s
   standalone pattern).
7. **`--envperf` deltas are single-sample.** One 30 s sample per state on the real
   streamed city, so the per-state millisecond deltas are only reliable to roughly
   +-10 ms and should not be quoted as precise costs. In `envperf5.txt` (the current,
   post-retune run) clear measured 25.98 ms avg / 86.90 ms p99 while cloudy measured
   35.45 ms avg / 77.53 ms p99 -- i.e. the partially-cloudy sky both averaged worse
   *and* spiked less than clear, which is sampling noise plus realtime-sky shader
   work varying with cloud coverage, not a weather cost ordering. The results that
   *are* structural and trustworthy are the invariants printed alongside the timings:
   node count flat (170157 -> 170157 across all four states), one world environment,
   one sun / one moon / one manager / one rain node, and no duplicate environment
   nodes after three transitions.
8. **Live rain amounts differ by context, by design.** The emitter count is
   `round(rain_amount(quality) * precipitation^0.75)` quantised down to
   `rain_amount(quality) / 12`, so it scales with both quality and intensity: at
   medium quality a ramped storm shows 1750 live streaks in `--envperf` while the
   capture fixture, which forces states on its own quality, reports its own larger
   figures (light 1330 / heavy 2394 / storm 3192). Both are the same code path at
   different quality/intensity inputs; neither is a world-wide particle count, since
   the emitter follows the camera in an 11 m box.
   9. **Residual storm-rain drift (reduced, not fixed).** The slant is now in the streak
    velocity and `RAIN_WIND_FACTOR` came down 3.0 → 1.1, but at storm wind the lateral speed
    is still ~1.62× the fall speed: a streak needs ~0.63 s to fall the 12 m box height and
    travels ~19 m sideways in that time, so it leaves the 11 m camera-local emission box
    before it finishes falling.  The visible effect is a slight thinning on the upwind side
    in a storm; the gross part (born-at-rest streaks and 86 m/s² lateral acceleration) is
    gone.
   10. **A drizzle thinner than one budget step draws no rain at all** — the quantised budget
    parks the emitter.  Deliberate (it replaces "one whole step of streaks for almost-dry
    air"), but the lowest few percent of precipitation are now visually dry.
   11. **Wetness on the real streets is verified by declaration, compilation and publication,
    not yet by a street-level frame.** Both city shaders declare and consume the global, it
    is declared in `project.godot`, published every frame, and both shaders compile; the
    visual confirmation on real city pavement still needs a windowed run of the streamed
    city (see §15.5).
   12. **The interior claim depends on the camera rig** (`is_interior_active()`).  If a later
    refactor renames or drops it, the probe silently falls back to its rays (no error, no
    warning) and a room whose ceiling caps have no collision reads as outdoors again.
   13. **A long thunder delay can outlive its storm**: the delay band now runs to 18.2 s, so a
    strike late in an episode can still rumble after the weather has cleared.

## 17. Future hooks

- Street lamps / point lights can read `night_factor()` and `daylight_factor()`.
- Character cloth/vegetation can read `wind_vector()` and gust amplitude.
- Interiors can consume `is_indoors()` plus wetness for indoor tracked-in water.
- A weather *script* (authored episodes) can replace the stochastic chooser by
  driving `force_weather()` — the blending path is unchanged.

---

## 18. Commit history (environment subsystem)

- **`9f572cf`** (2026-09-13) — the subsystem's first landing: every
  `world/environment/*` file, both shaders, and the three debug tools. Its subject line
  is about melee because the Ring Bell worktree and git index are **shared** with the
  combat and interior tracks, so the staged environment files rode along in that
  commit. Nothing was lost; the content is all there.
- **`05abb34`** (2026-09-13) — readability retune + diagnostics + this document:
  volumetric-fog day/night albedo split (night emission 0.52 → 0.04), rain box/budget/
  streak/wind retune, velocity-aligned streaks, `wind_dir_deg` wrapped to 0..360°,
  multi-frame lightning peak sampling in `--envcapture`, CPU+GPU particle counting and
  type-based node counts in `--envperf`, `.hermes/autopilot/ENVIRONMENT_OVERHAUL.md`.

- **`bfdd562`** (2026-09-13) — the audit-remediation pass (§15): the six HIGH, six MEDIUM
  and LOW fixes above, plus the new fast gates `debug/weather_model_check.gd` and
  `debug/environment_shader_check.gd`, and the city shaders' wetness consumption.

Branch: **`copilot/worldgen-fix`**, pushed to `origin` (never merged or fast-forwarded
into master).

Operating rule for this repo: stage **only your own paths**. Other tracks' hunks sit
unstaged in the same index, so `git add -A` / `git commit -a` will sweep their work
into your commit; and check `git status` before committing in case they already staged
files of their own.
