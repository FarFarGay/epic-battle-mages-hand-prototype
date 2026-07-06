# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Epic Battle Mages — Hand Prototype** (`config/name="Hand Gameplay Prototype"`). A **Godot 4.6.2 / GDScript** hand-physical game. **The current `run/main_scene` is the ROOMS gameloop** (`scenes/level_rooms.tscn`, see `SPEC.md §5.22`): the player drives a mobile tower through an enfilade of rooms shaped as a tutorial arc "one room = one verb" (`SPEC.md §5.26`): cave start (move/dash/mana/super-dash), hand lessons (grab a plank-bridge across a chasm, seat a relay diode into a broken spark-chain), a giant boss duel (roar → dodge → stun window → exactly 3 super-dashes), and "work under threat" (order the worker artel to chop a grove while chop-noise waves attack; felled grove frees the bridge plank). Door-puzzles by hand/magic (spark→diode→lever), mana from skeleton XP-orbs, tutorial hints via `tutorial_hint.gd` → HUD. The older **camp-defense / fortress** game (`scenes/main.tscn`: polar build grid, gnome population, vein economy, day/night warband siege) still exists and most of this file's "big picture" describes it — but it is NOT the booting scene.

- **117 `.gd` scripts** in `scripts/`, **66 scenes** in `scenes/`. Booting scene: `scenes/level_rooms.tscn` (rooms gameloop). Camp game: `scenes/main.tscn`.
- **`SPEC.md` is the detailed source of truth** — a large, sectioned, dated spec (`### 5.X` headers). This file is the quick orientation; read the relevant `SPEC.md` section for depth before changing a system. Memories named `project_ebm_*` / `feedback_*` capture design intent and gotchas not obvious from code.
- **No test framework** — this is a **playtest-driven prototype**. The designer verifies behavior visually in-game. "Verify" here means a headless boot that catches parse/load errors (see below), not automated tests.

## Running & verifying

There is no build step (Godot loads scripts directly). The only programmatic check is a **headless boot** of a scene — it parses all `class_name` scripts and surfaces `SCRIPT ERROR` / parse errors. Run after **every** edit (boot the scene whose systems you touched — rooms gameloop by default, `scenes/main.tscn` for camp systems):

```
& "D:\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --headless --path "D:\epic-battle-mages-hand-prototype" scenes/level_rooms.tscn --quit-after 90
```

(The console exe lives *inside* the equally-named folder; the non-console exe has no stdout. `--quit-after N` is in frames. Exit 0 + no `SCRIPT ERROR`/`Parse Error` lines = clean.)

- **New `class_name`?** Run `--headless --editor --quit-after 1` FIRST to rebuild the class cache, else `--check-only` reports "Could not find type X".
- To unit-test a pure helper, a throwaway `extends SceneTree` script with the logic in `_init()` (or load a `.tscn` and inspect it) works; `_process`/`_initialize` overrides on a `SceneTree` subclass do **not** fire via `--script`.

## Architecture (big picture)

Cross-system communication is centralized through **`EventBus`** (autoload, `scripts/event_bus.gd`) — a global signal hub (`resources_changed`, `camp_buildings_changed`, `day_phase_changed`, `skeleton_attacked_camp`, …). Listeners connect in `_ready` and disconnect on `tree_exiting` (EventBus is an autoload, so subscriptions would otherwise leak across scene reloads). Prefer wiring new cross-system events here over direct node references.

**Autoloads:** `EventBus`, `LogConfig` (gate debug prints with `LogConfig.master_enabled`), `MatchConfig`/`QuestProgress` (match state), `JournalPanel` (the in-game menu UI), `SpellSystem`, `SoldierSystem`, plus FX autoloads (`SquadXpFx`, `XpOrbSpawner`, `ResourceFx`).

**`Camp` (`scripts/camp.gd`, very large) is the player-base orchestrator.** It owns and ticks:
- **`CampEconomy`** (`camp_economy.gd`) — resource pool (wood/stone/iron + gold) with a per-material cap; `add_resource`/`try_spend`/`cap_for`. Gold is the uncapped win currency.
- **`BuildGrid`** (`build_grid.gd`) — a **polar build grid** of concentric rings of wedge cells around the harvester. Buildings are placed from the Journal into the hand and stamped into cells. Placement rules combine **`ring_tier`** (generator → ring 0; others → rings 1+) and **veins** (random cells in rings 1+; only the warehouse-extractor `requires_vein` may sit on a vein, nothing else may). Emits `buildings_changed` on place/built/destroy → `Camp._on_grid_buildings_changed`.
- **`BuildBlock`** (`build_block.gd`) — a building: a procedural **curved-sector mesh** sized to its cell (normals set explicitly outward). The catalog `model_decor` flag keeps the sector visible as the body (perfect fit) with a graybox model layered on top; a plain `model` (generator) replaces the sector. Construction is non-instant (blueprint silhouette grows → built).
- **`CampBuildings.CATALOG`** (`camp_buildings.gd`) — pure data (cost/hp/ring_tier/footprint/flags/model) for every building. Subclasses for special blocks: `GateBlock`, `BunkerBlock`.
- **Gnomes** (`gnome.gd`) — the camp **population**. An FSM with a `CollectionMode` (FREE = idle camp-life / ALARM = recall to tower). Gnomes are spent as **workers** (walk into a warehouse-extractor on a vein and produce its material), recruited into **Squads** (`SoldierGnome`/`SoldierSystem`), or man defenses. Population is the economy throttle.

**Tower** (`tower.gd`) = the core (mana, "super" charge, spell origin). **Hand** (`hand.gd`) = the player's hand: `HandPhysical` (grab/slam/flick) + `HandSpell` (spells via `SpellSystem` + per-spell `hand_spell_*.gd`). Hand and magic are unified as **friendly-fire-by-default with per-target immunity** (see `SPEC.md §4.2`).

**Enemies & waves:** `Enemy` (base) → `Skeleton` (LOD-throttled at scale, boids-style avoidance) and variants (`SkeletonArcher`/`Giant`/`Thrower`/`EnemyMech`). `EnemySpawner` + **`WaveDirector`** drive a **day/night warband siege** (day = roaming bands, night = a one-front assault marching on the camp with a ground-arc telegraph). Skeletons break walls and target structures in the `skeleton_target` group; the camp core is in group `&"camp"`.

## Current economy model (recently reworked — read `SPEC.md §5.20`)

Materials (wood/stone/iron) come from **central veins** (typed ore/grove deposits in the build grid) via the **warehouse = extractor** building, in which a **gnome physically works** (enters and hides inside; production only while staffed). The **generator** (ring 0 only) powers the harvester for **gold**. **Field gathering was removed** (resource zones disabled, the WORK collection mode dropped); food and the PAGE resource were cut from the economy bar. Population (gnomes) is split between economy, defense, and troops.

## Conventions & recurring gotchas

- **Freed-node safety:** the spatial grids and group lists can hold freed instances. Read dictionary/array entries into an **untyped Variant and `is_instance_valid()` it BEFORE any typed cast** — `var n: Node3D = entry[1]` on a freed instance crashes.
- **`queue_free` is deferred** to end-of-frame; in destroyed-signal handlers with AoE/cascade chains, remove from groups immediately in `_die()` before `emit`.
- Lambda captures of a `Node` in timer/tween callbacks throw "Lambda capture … was freed"; capture a `WeakRef` and `get_ref()` inside.
- Runtime visuals are often built procedurally with `SurfaceTool`; `tools/mesh_lib.gd` is for **offline-baked** assets only (`extends RefCounted`, not runtime).
- Grayboxes are primitive `.tscn` under `models/` (BoxMesh/CylinderMesh/PrismMesh + StandardMaterial3D `material_override`, which `BuildBlock` duplicates per-instance for hit-flash).
- **Git:** work on `main`; end commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. CRLF warnings on commit are benign. The repo is on Windows; use the headless verify above, not automated tests.

## Layout

`scripts/` game logic · `scenes/` Godot scenes · `models/` graybox/decor `.tscn` · `resources/` `.tres` · `shaders/` · `tools/` offline mesh-bake scripts · `docs/` · `SPEC.md` detailed spec · `Agent Task.md` working notes.
