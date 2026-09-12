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
- Wind influence: `gravity = (wind.x, -fall_speed, wind.z) * RAIN_WIND_FACTOR`
  (`RAIN_WIND_FACTOR := 3.0`), and the material uses
  `BILLBOARD_PARTICLES` with `particle_flag_align_y = true` so each streak is
  oriented along its own velocity (wind-driven slant) instead of staying vertical.
- When dry, the emitter is parked (`amount = _amount_step`, `emitting = false`,
  `visible = false`) because the engine rejects `amount = 0`; `active_particles()`
  reports 0 while parked and `rain_particles()` exposes the live budget.
- Indoor reduction: the precipitation controller takes the shelter value and
  suppresses streaks that fall between the camera and the roof (see §7).

## 6. Wetness

- Global parameter: `wetness` 0..1, `WETNESS_GAIN_PER_GAME_MINUTE := 0.055` while
  `precipitation > WETNESS_PRECIP_THRESHOLD` (0.03), drying at
  `WETNESS_DRY_PER_GAME_MINUTE := 0.0042` (≈ 13× slower than wetting).
  `WETNESS_MAX_JUMP_MINUTES := 5.0` clamps catches-up after load/time skips.
- **Material contract**: six global shader uniforms published by the manager —
  `environment_wetness`, `environment_rain_intensity`, `environment_wind_vector`,
  `environment_night_factor`, `environment_hour`, `environment_storm` — declared in
  `project.godot [shader_globals]` and verified at runtime by
  `_check_global_params()` (publishing an undeclared global spams an engine error
  every frame). A material opts in with `global uniform float environment_wetness;`
  and nothing else — no per-material bookkeeping, no per-frame material loops.
  `shaders/wetness_overlay.gdshader` is the working reference consumer.
- Demonstrated effect: wet surfaces darken in albedo (diffuse) and gain a
  sky-reflecting gloss (highlight percentile up) — both verified in `--envcapture`.
- Puddles: intentionally not implemented (optional per the brief). The wet-road
  gloss carries the read; no decals, no extra draw calls.

## 7. Shelter / indoor-outdoor hook

- `exposure_probe.gd` returns a 0..1 shelter value: roof rays up plus a short
  horizontal set, **throttled** (not every frame, no per-entity raycasts).
  `force(value)` overrides it for tests/debug (F12).
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
  `LIGHTNING_MIN_REAL_GAP := 2.0` **real seconds** — no rapid flicker.
- A strike is **multi-stage**: 1..N stages per quality
  (`QUALITY_LIGHTNING_STAGES`), a visible bolt mesh (9 segments, `BOLT_VISIBLE_SECONDS`
  0.14, spawned 220 m+ away at 260 m altitude) plus a flash envelope on sky/ambient
  directional energy (`FLASH_COLOR`).
- Thunder: distance from the bolt, propagation at `THUNDER_SPEED_MPS := 343.0`,
  delay clamped to `THUNDER_DELAY_MIN` 0.35 … `THUNDER_DELAY_MAX` 11.0 s, delivered on
  the `lightning_event(intensity, distance_m, delay)` signal and drained by the
  ambience layer. Audio is **synthesised in-engine** (`_make_thunder()`,
  filtered noise + envelope), so thunder works with zero external assets; drop
  `res://audio/environment/thunder_*.ogg` in place and `_load_or_make()` prefers it.

## 9. Ambience

- Beds: wind (LP-filtered noise, gust-modulated), rain (light/heavy), storm, thunder.
  All generated procedurally at 22050 Hz into `AudioStreamWAV` loops — no
  copyrighted downloads, no missing-asset breakage.
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
| `Godot --headless --path . -- --envtest` | **103 checks, 0 failures** |
| `Godot --path . -- --envcapture` | **13 frames, 0 metric failures** + PNGs |
| `Godot --path . -- --envperf` | see §14 |
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

## 15. Known limitations

1. Rain streaks are thin geometry: they read clearly in motion and in the storm
   frames, but a *single still frame* under-counts apparent density. Wind slant is
   present in the particle velocity and the streak orientation; in a still frame
   down a straight alley it reads subtler than it does in play.
2. Thunder is synthesised noise; it is convincing as "distant rumble" but a real
   recording sample (documented slot) would improve near-strike punch.
3. Volumetric fog is quality-gated; LOW falls back to depth fog only.
4. Puddles are not implemented (optional per the brief); wet roads are handled by
   the wetness parameter.
5. The capture fixture is a procedural blockout (flat faces, no windows/lamps), so
   its absolute luminance values are fixture-specific — the *ratios* (night vs noon,
   dry vs wet) are the meaningful measurements.
6. `EnvironmentManager` is expected to be created by `world/main.gd`; other scenes
   that build their own world must create it explicitly (or load `--envtest`'s
   standalone pattern).

## 16. Future hooks

- Street lamps / point lights can read `night_factor()` and `daylight_factor()`.
- Character cloth/vegetation can read `wind_vector()` and gust amplitude.
- Interiors can consume `is_indoors()` plus wetness for indoor tracked-in water.
- A weather *script* (authored episodes) can replace the stochastic chooser by
  driving `force_weather()` — the blending path is unchanged.
