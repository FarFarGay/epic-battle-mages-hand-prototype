class_name HandSpellFrost
extends Node
## Мороз — баллистический снаряд по образцу Fireball, но frost-эффект вместо
## damage'а:
##  - **Hit-target** (попавшие в AOE взрыва) — полная заморозка `hit_freeze_duration`с
##  - **Зона на земле** (FrostPatch) — замедление 60% на `patch_duration`с
##
## Логика баллистики переиспользует [Fireball] (boost + homing); сцена
## frost_bolt.tscn инстанцируется как [FrostBolt] (наследник Fireball)
## который добавляет post-impact freeze + patch.
##
## Параметры override'ятся из `SpellSystem.get_current_level_data(&"frost")`.

signal spell_cast(spell_name: StringName, position: Vector3)

## Параметры траектории — общие для Fireball/Firestorm/Frost. По умолчанию
## ссылается на [code]resources/ballistic_default.tres[/code]. Frost летит
## идентично fireball'у — если нужен «отличный полёт» (медленнее / выше),
## создай дубль .tres и подсунь сюда.
@export var ballistics: BallisticConfig = preload("res://resources/ballistic_default.tres")

@export_group("Balance")
## Frost — control, не damage. По умолчанию 0 — снаряд только замораживает.
## Если дизайнер захочет minor damage — можно положить >0 в SpellSystem level-data
## (override @export). Дизайнерское правило: «один эффект = один смысл»
## (см. memory project_ebm_charge_abilities).
@export var damage: float = 0.0
## Радиус AOE взрыва (hit-target freeze). 3.5м — компактнее frost-patch'а,
## точное прямое попадание награждается hard-CC.
@export var radius: float = 3.5
@export var cooldown: float = 0.6
@export var mana_cost: float = 18.0
@export_flags_3d_physics var explode_mask: int = Layers.MASK_HAND_SLAM
## Knockback подавлен — frost не толкает, он замораживает. Force=0 даёт
## "тихий взрыв", визуально подчёркивает разницу с fireball.
@export var knockback_duration: float = 0.0
@export var knockback_force: float = 0.0
@export var knockback_lift: float = 0.0

@export_group("Frost")
@export var hit_freeze_duration: float = 2.0
## Сцена FrostPatch — синяя зона на земле.
@export var frost_patch_scene: PackedScene
## Радиус зоны (БОЛЬШЕ AOE-радиуса самой ракеты — «пятно льда» вокруг
## точки удара). 5.0м даёт ~80м² зоны замедления.
@export var patch_radius: float = 5.0
@export var patch_duration: float = 4.0
@export var patch_slow_factor: float = 0.4
## Время раскрытия зоны льда от 0 до полного `patch_radius`, секунд.
## Игрок видит как лёд «расползается» от точки удара. 1.0с — заметное,
## но не затягивающее раскрытие; через эту секунду зона уже полная.
@export var patch_grow_duration: float = 1.0

@export_group("Visual")
@export var frost_bolt_scene: PackedScene
@export var launch_offset_y: float = 3.0

@export_group("Telegraph")
@export var warning_duration: float = 1.0
## Ледяной cyan — отличается от огненного оранжевого fireball'а.
@export var warning_color: Color = Color(0.45, 0.8, 1.0, 0.85)

@export_group("")
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _cooldown_remaining: float = 0.0
var _effects_root: Node = null


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


func is_active() -> bool:
	return false


# --- Публичный API (вызывается координатором HandSpell) ---

func can_trigger() -> bool:
	return _cooldown_remaining <= 0.0


func on_press() -> void:
	_perform_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


# --- Каст ---

func _perform_cast() -> void:
	if frost_bolt_scene == null:
		push_error("[Hand:Spell:Frost] frost_bolt_scene не задан")
		return
	if SpellSystem != null and not SpellSystem.is_unlocked(&"frost"):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Frost] заклинание не разблокировано")
		return
	# SpellSystem.levels — single source of truth, @export — fallback.
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"frost") if SpellSystem != null else {}
	var p_damage: float = float(lvl.get("damage", damage))
	var p_radius: float = float(lvl.get("radius", radius))
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var p_mana_cost: float = float(lvl.get("mana_cost", mana_cost))
	var p_hit_freeze: float = float(lvl.get("hit_freeze_duration", hit_freeze_duration))
	var p_patch_radius: float = float(lvl.get("patch_radius", patch_radius))
	var p_patch_duration: float = float(lvl.get("patch_duration", patch_duration))
	var p_patch_slow: float = float(lvl.get("patch_slow_factor", patch_slow_factor))
	var p_patch_grow: float = float(lvl.get("patch_grow_duration", patch_grow_duration))

	var bolt := frost_bolt_scene.instantiate() as FrostBolt
	if bolt == null:
		push_error("[Hand:Spell:Frost] frost_bolt_scene не инстанцируется как FrostBolt")
		return

	if not _coord.try_consume_tower_mana(p_mana_cost):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Frost] не хватает маны (нужно %.0f)" % p_mana_cost)
		bolt.queue_free()
		return
	var launch_pos: Vector3 = _coord.tower_launch_position(launch_offset_y, _hand)
	var target_pos: Vector3 = _hand.cursor_world_position()
	target_pos.y -= _hand.hand_height
	_cooldown_remaining = p_cooldown

	# Telegraph: ground-ring под точкой удара, размер AOE-радиуса.
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, p_radius, warning_duration, warning_color)

	_effects_root.add_child(bolt)
	bolt.setup(
		launch_pos,
		target_pos,
		ballistics.boost_duration,
		ballistics.boost_velocity_up,
		ballistics.boost_velocity_forward,
		ballistics.boost_gravity,
		ballistics.boost_drift_velocity,
		ballistics.homing_initial_speed,
		ballistics.homing_acceleration,
		ballistics.homing_max_speed,
		ballistics.homing_drift_angle_deg,
		ballistics.homing_turn_rate,
		p_damage,
		p_radius,
		explode_mask,
		knockback_force,
		knockback_lift,
		knockback_duration,
	)
	bolt.setup_frost(frost_patch_scene, p_hit_freeze, p_patch_radius, p_patch_duration, p_patch_slow, p_patch_grow)
	# Frost-bolt НЕ зовёт setup_burn — burn-patch не нужен, frost-patch
	# спавнится в _on_post_explode подкласса.
	# Fog pulse: чуть скромнее fireball'а — frost не «вспышка», а «выдох холода».
	bolt.setup_fog_pulse(10.0)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Frost] каст @ target=(%.1f, %.1f, %.1f)" % [target_pos.x, target_pos.y, target_pos.z])
	spell_cast.emit(&"frost", target_pos)
