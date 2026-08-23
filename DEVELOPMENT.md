# Development Guide

## Requirements

- Godot 4.7.x (tested with 4.7.1 stable, Windows)
  - This workspace uses: `C:\Godot Enginer\Godot_v4.7.1-stable_win64.exe`

## Opening / running

- Open the project folder in Godot (it contains `project.godot`), press F5.
- Or from a terminal:

```powershell
& "C:\Godot Enginer\Godot_v4.7.1-stable_win64.exe" --path "C:\Godot Enginer\Project\ring-bell"
```

## Controls

| Input | Action |
|---|---|
| WASD | Move (camera-relative) |
| Shift | Sprint (drains stamina) |
| LMB / Space | Melee attack |
| E | Interact / talk |
| F | Eat food item |
| G | Use medical item |
| Q / R | Rotate camera (also RMB-drag) |
| Mouse wheel | Zoom |

## Debug hotkeys

| Key | Effect |
|---|---|
| F3 | Toggle debug overlay (stats, quest states, world-event log) |
| F5 | Quicksave |
| F9 | Quickload |
| T | Cycle game time scale x1 / x8 / x30 |

Save file: `%APPDATA%\Godot\app_userdata\Ring Bell\saves\save_01.json`

## Headless validation (no window needed)

Run after any script change. All must pass with zero errors.

```powershell
$G = "C:\Godot Enginer\Godot_v4.7.1-stable_win64.exe"
$P = "C:\Godot Enginer\Project\ring-bell"

# 1) Reimport + parse check
& $G --headless --path $P --import

# 2) Short stability run (~10 s of simulation)
& $G --headless --path $P --quit-after 600

# 3) Functional regression suite (exits 0 on success; runs on the legacy block)
& $G --headless --path $P -- --smoke

# 4) Day/night + sleep AI + zombie wandering soak (legacy block)
& $G --headless --path $P -- --soak

# 5) Procedural city determinism suite
& $G --headless --path $P -- --citytest
```

Note when launching via `Start-Process`: quote the `--path` argument; prefer
plain `&` invocation so output streams live.

## World modes

| Mode | When | Content |
|---|---|---|
| CITY (default) | normal launch | streamed procedural city: ChunkManager loads 64 m chunks (ACTIVE ring <= 1, WARM <= 2) from the deterministic CityPlan; player spawns at the plaza anchor, ambient zombies scatter on streets |
| LEGACY | `--smoke`, `--soak`, `--legacy-block` | hand-built Prototype 0 test block with the full narrative cast |

Extra dev flag: `--shot` captures screenshots (gameplay + top-down overview +
street level + far teleport) to `%TEMP%\opencode\rb_*.png` and prints F3-style
streaming stats, then quits.

### What `--citytest` verifies

Same world seed -> identical plan data and chunk geometry manifests regardless
of query/build order; a different seed produces a materially different city;
spawn anchors exist; multi-storey buildings generate near the center; chunk
discovery records survive a save/load round-trip.

### What `--smoke` verifies

Population spawns; hungry NPC eats carried food; crates feed NPCs; melee
damages/kills zombies; quest objective advances if Hana was met BEFORE the
quest starts; Hana's independent death fails the quest and is recorded;
Kenji's dialogue switches to a grief branch; save/load keeps her dead,
respawns everyone else, restores the clock.

## Manual test walkthrough (the narrative proof)

1. Run the game. Talk to **Kenji Tanaka** inside the apartment building
   (east door). Accept his task.
2. Cross the east road; find **Hana Tanaka** near the wrecked cars in the
   southeast corner. Talk to her - objective flips to "Return to Kenji".
3. Return to Kenji -> quest completes, he gives canned food.
4. Variation A: talk to Hana FIRST, then Kenji - he skips the "find" objective.
5. Variation B: while the quest is active, let a zombie kill Hana (or use
   timescale T and patience) - the quest FAILS by itself and Kenji now only
   speaks the grief branch.
6. Kill Hana, F5, quit, relaunch, F9 -> she stays dead after load.

## Conventions for AI-assisted changes

- Read ARCHITECTURE.md before refactoring anything.
- One responsibility per file; keep files small and explicitly named.
- Update the signal contract list in `event_bus.gd` when adding signals.
- Never hard-code actor ids outside `population.gd`, `dialogue_data.gd`,
  and quest definitions.
- After changes: run all four validation commands above; do not leave
  known errors behind.
