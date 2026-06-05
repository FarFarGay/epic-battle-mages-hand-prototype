class_name HandSpellSpark
extends Node
## Подмодуль «Искра» — дешёвое single-target заклинание зачистки.
##
## Каст по образцу Frost/Fireball: на ПКМ telegraph-ring под курсором +
## снаряд из башни в target_pos. Отличие — SparkBolt НЕ AOE: в радиусе
## [impact_radius] он находит ОДНОГО врага (ближайший к точке падения) и
## наносит урон. Промах или каст в землю — просто визуальная искра.
##
## Параметры читаются из [SpellSystem.get_current_level_data] (single source
## of truth), @export'ы — fallback для дев-сцен без autoload'а.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Balance")
@export var damage: float = 35.0
@export var cooldown: float = 0.15
@export var mana_cost: float = 3.0
## Радиус sphere-scan вокруг точки попадания. SparkBolt ищет здесь одного
## ближайшего Enemy. Маленький (1.5м) — игрок должен метко наводить.
@export var impact_radius: float = 1.5

@export_group("Visual")
@export var spark_scene: PackedScene
@export var launch_offset_y: float = 3.0

@export_group("Telegraph")
## Длительность кольца под точкой удара. Короткое — искра долетает за ~1с,
## ring не должен висеть.
@export var warning_duration: float = 0.6
## Жёлтый — отличается от голубого frost и оранжевого fireball.
@export var warning_color: Color = Color(1.0, 0.95, 0.3, 0.85)

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


# --- Публичный API ---

func can_trigger() -> bool:
	return _cooldown_remaining <= 0.0


func on_press() -> void:
	_perform_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


# --- Каст ---

func _perform_cast() -> void:
	if spark_scene == null:
		push_error("[Hand:Spell:Spark] spark_scene не задан")
		return
	if SpellSystem != null and not SpellSystem.is_unlocked(&"spark"):
		return
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"spark") if SpellSystem != null else {}
	var p_damage: float = float(lvl.get("damage", damage))
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var p_mana_cost: float = float(lvl.get("mana_cost", mana_cost))
	var p_impact_radius: float = float(lvl.get("impact_radius", impact_radius))

	if not _coord.try_consume_tower_mana(p_mana_cost):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Spark] не хватает маны (нужно %.0f)" % p_mana_cost)
		return
	_cooldown_remaining = p_cooldown
	var launch_pos: Vector3 = _coord.tower_launch_position(launch_offset_y, _hand)
	var target_pos: Vector3 = _hand.cursor_world_position()
	target_pos.y -= _hand.hand_height

	# Telegraph: маленькое жёлтое кольцо в точке удара.
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, p_impact_radius, warning_duration, warning_color)

	var bolt := spark_scene.instantiate() as SparkBolt
	if bolt == null:
		push_error("[Hand:Spell:Spark] spark_scene не инстанцируется как SparkBolt")
		return
	bolt.impact_radius = p_impact_radius
	_effects_root.add_child(bolt)
	bolt.add_to_group(&"player_projectile")  # EnemyMech уклоняется от снарядов игрока
	bolt.setup(launch_pos, target_pos, p_damage, _effects_root)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Spark] искра @ (%.1f, %.1f) damage=%.0f" % [target_pos.x, target_pos.z, p_damage])
	spell_cast.emit(&"spark", target_pos)
