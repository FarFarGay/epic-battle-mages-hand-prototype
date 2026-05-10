class_name SoldierGnome
extends Gnome
## Гном-солдат — мобилизованный из gatherer'а через `Camp.recruit_soldier`.
## Параметры (hp, attack_radius, damage, cooldown, speed) приходят из
## `SoldierSystem.SOLDIER_CATALOG[type].stats` через `setup_soldier`.
##
## Phase 1 (MVP): стоит на той точке, где призван, и стреляет в скелетов в
## attack_radius'е. Squad-команды (defend / escort / attack-move) — Phase 2/3.
##
## Не привязан к палатке (в отличие от DefenderGnome): `_home_tent=null`.
## `_active_tick` переопределён под combat-логику без AI собирателя/защитника.
## Пока что солдат не двигается сам — стоит и атакует. Когда появится
## squad-system, движение пойдёт по командам squad'а (target_pos / state).
##
## Группа SOLDIER_GROUP — для squad-сканов и общего учёта.

const SOLDIER_GROUP := &"soldier"

@export_group("Soldier combat (override через setup_soldier)")
@export var attack_radius: float = 18.0
@export var attack_damage_min: float = 18.0
@export var attack_damage_max: float = 28.0
@export var attack_cooldown_min: float = 1.0
@export var attack_cooldown_max: float = 1.8
@export var arrow_scene: PackedScene
@export var arrow_speed: float = 22.0
@export var arrow_spawn_offset: Vector3 = Vector3(0, 0.6, 0)
@export var soldier_color: Color = Color(0.4, 0.65, 1.0, 1.0)
@export_group("")

## Тип солдата из SOLDIER_CATALOG. Ставится в setup_soldier.
var soldier_type: StringName = &""
## Ссылка на squad. Назначается Squad.add_member(self). RefCounted —
## пока хотя бы один член держит ссылку или Camp хранит, объект жив.
var _squad: Squad = null
var _attack_cd: float = 0.0
## Расстояние «прибытия» к squad-target'у. Меньше — стоим (squad-positioning
## не jitter'ит на под-метровых отклонениях).
const SQUAD_TARGET_ARRIVAL: float = 0.4


func _ready() -> void:
	# gnome_color для _apply_visual'а — выставляем ДО super._ready чтобы
	# базовый ready взял правильный цвет, если он туда смотрит. Сейчас в
	# Gnome._ready визуал не применяется (только в setup), но на будущее.
	gnome_color = soldier_color
	super._ready()
	add_to_group(SOLDIER_GROUP)


## Конфиг приходит от Camp.recruit_soldier на основе SoldierSystem.SOLDIER_CATALOG.
## Stats — Dictionary с ключами hp / attack_radius / damage_min / damage_max /
## cooldown_min / cooldown_max / move_speed. Отсутствующие ключи — оставляют
## @export-дефолты.
func setup_soldier(p_type: StringName, stats: Dictionary, p_camp: Camp, position: Vector3) -> void:
	soldier_type = p_type
	hp = float(stats.get("hp", hp))
	attack_radius = float(stats.get("attack_radius", attack_radius))
	attack_damage_min = float(stats.get("attack_damage_min", attack_damage_min))
	attack_damage_max = float(stats.get("attack_damage_max", attack_damage_max))
	attack_cooldown_min = float(stats.get("attack_cooldown_min", attack_cooldown_min))
	attack_cooldown_max = float(stats.get("attack_cooldown_max", attack_cooldown_max))
	if stats.has("move_speed"):
		move_speed = float(stats.move_speed)
	global_position = position
	# Базовая Gnome-инициализация. home_tent=null — солдат не привязан.
	# setup() вызывает _enter_in_tent внутри, поэтому ниже принудительно
	# выходим в outside-режим (visible, в группе skeleton_target, _state свой).
	setup(p_camp, null)
	_state = State.SEARCHING  # любой outdoor-state, AI в _active_tick переопределён
	visible = true
	add_to_group(SKELETON_TARGET_GROUP)
	_attack_cd = randf_range(0.0, attack_cooldown_max)  # рандомный стартовый cd — чтобы не залп


## Squad назначает себя на add_member. Двусторонняя ссылка нужна юниту
## чтобы запросить target_for_member и читать squad.state. На смерть юнита
## squad сам отлавливает destroyed-сигнал и убирает из members'а.
func set_squad(squad: Squad) -> void:
	_squad = squad


## Override базового AI. Логика «attack-and-move»:
##   1. Cooldown стрельбы тикает всегда.
##   2. Если враг в attack_radius'е — останавливаемся, поворачиваемся, стреляем.
##   3. Иначе двигаемся к squad-target'у (если есть squad) или стоим.
func _active_tick(delta: float) -> void:
	if _attack_cd > 0.0:
		_attack_cd -= delta

	var target: Node3D = _find_target()
	if target != null:
		# Враг в radius'е — стоим и стреляем. Squad-движение приостанавливается:
		# огневой контакт приоритетнее перемещения.
		velocity = Vector3.ZERO
		if _attack_cd <= 0.0 and arrow_scene != null:
			_fire_at(target)
			_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
		return

	# Нет огневого контакта — двигаемся к squad-target'у (если есть squad).
	if _squad == null or _camp == null:
		velocity = Vector3.ZERO
		return
	var tower_pos: Vector3 = _camp.get_tower_position() if _camp.has_method(&"get_tower_position") else global_position
	var goal: Vector3 = _squad.target_for_member(self, tower_pos)
	var to_goal_xz := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var dist: float = to_goal_xz.length()
	if dist <= SQUAD_TARGET_ARRIVAL:
		velocity = Vector3.ZERO
		return
	var dir: Vector3 = to_goal_xz / dist
	# Поворачиваем юнита по направлению движения.
	look_at(global_position + dir, Vector3.UP)
	velocity = dir * move_speed


## Ближайший Skeleton в attack_radius'е. Идёт через SKELETON_GROUP — и NEAR,
## и FAR-LOD скелеты в группе (в отличие от broad-phase, которая FAR пропускает).
func _find_target() -> Node3D:
	var nearest: Skeleton = null
	var nearest_d_sq: float = attack_radius * attack_radius
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if not is_instance_valid(skel):
			continue
		var d_sq: float = (skel.global_position - global_position).length_squared()
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = skel
	return nearest


func _fire_at(target: Node3D) -> void:
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return
	get_tree().current_scene.add_child(arrow)
	arrow.damage = randf_range(attack_damage_min, attack_damage_max)
	arrow.speed = arrow_speed
	var spawn: Vector3 = global_position + arrow_spawn_offset
	arrow.setup(spawn, target.global_position)
	# Поворачиваем гнома лицом к цели — facing-indicator (если есть в .tscn)
	# показывает на цель. look_at безопасен для Node3D без shape-issues.
	var to_target_xz := Vector3(target.global_position.x - global_position.x, 0.0, target.global_position.z - global_position.z)
	if to_target_xz.length_squared() > 0.001:
		look_at(global_position + to_target_xz, Vector3.UP)
