class_name ConstructionSite
extends StaticBody3D
## Стройплощадка — временный объект на месте будущего здания. Стоит [build_time]
## секунд, показывая прогресс (растущий полупрозрачный каркас), и по завершении
## вызывает колбэк [_on_complete], который спавнит настоящее здание (Camp зовёт
## тот же _apply_building / _spawn_one_palisade_segment). Затем queue_free.
##
## АТАКУЕМА: Damageable + SKELETON_TARGET_GROUP (как ArcherPost) — скелеты бьют
## стройку, и если разрушат до завершения, здание НЕ появляется (ресурсы уже
## потрачены при старте — теряются). Это сознательный риск-дизайн.
##
## Generic: не знает тип здания. Camp передаёт позицию, время, колбэк завершения
## и (для волны палисада) start_delay. Один пакет покрывает все постройки.

signal damaged(amount: float)
signal destroyed

const GROUP := &"construction_site"
const SKELETON_TARGET_GROUP := Enemy.TARGET_GROUP  # канон — Enemy.TARGET_GROUP, локальное имя для совместимости

## Прочность стройплощадки. Хрупкая — стройку реально сорвать парой ударов.
@export var hp_max: float = 35.0
## Цвет каркаса (полупрозрачный «чертёж»). Растёт по Y с прогрессом.
@export var scaffold_color: Color = Color(0.5, 0.8, 1.0, 0.45)
## Цвет кольца-футпринта вокруг площадки.
@export var footprint_color: Color = Color(0.5, 0.8, 1.0, 0.7)
## Радиус кольца-футпринта.
@export var footprint_radius: float = 1.3

var _hp: float
var _destroyed: bool = false
var _build_time: float = 2.5
var _elapsed: float = 0.0
## Задержка до начала прогресса (для «волны» палисада — сегменты стартуют
## по очереди). Площадка уже видна, но прогресс не идёт пока не истечёт.
var _start_delay: float = 0.0
var _on_complete: Callable = Callable()
var _log_label: String = "build"
var _finished: bool = false
## Лёгкий режим FX: без кольца-футпринта и без dust-пуфа на завершении. Нужен
## для массовой стройки (палисад волной — десятки площадок), иначе десятки
## GPUParticles + overdraw полупрозрачных колец дают просадку FPS. Растущий
## каркас остаётся как индикатор прогресса.
var _light_fx: bool = false

@onready var _scaffold: Node3D = get_node_or_null("Scaffold")
var _footprint_ring: MeshInstance3D = null


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(SKELETON_TARGET_GROUP)
	Damageable.register(self)
	_hp = hp_max
	# Каркас стартует «из земли» (почти нулевая высота).
	if _scaffold != null:
		_scaffold.scale.y = 0.02
		_apply_scaffold_color()


## Camp вызывает после add_child. on_complete спавнит настоящее здание.
## Кольцо-футпринт спавним здесь (а не в _ready) — global_position валиден
## только после этой установки.
func setup(world_pos: Vector3, build_time: float, on_complete: Callable, start_delay: float = 0.0, log_label: String = "build", light_fx: bool = false) -> void:
	global_position = world_pos
	_build_time = maxf(build_time, 0.01)
	_on_complete = on_complete
	_start_delay = maxf(start_delay, 0.0)
	_log_label = log_label
	_light_fx = light_fx
	# Кольцо-футпринт пропускаем в light-режиме (палисад) — десятки overlap'ающих
	# полупрозрачных колец дают overdraw.
	if not _light_fx:
		var root: Node = get_tree().current_scene
		if root != null:
			_footprint_ring = AoeVisual.spawn_ground_ring(
				root, global_position, footprint_radius, 0.0, footprint_color,
			)


func take_damage(amount: float) -> void:
	if _destroyed or _finished or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash_damage()
	if _hp <= 0.0:
		_fail()


## Стройку сорвали (разрушена скелетами/магией). Здание НЕ появляется, ресурсы
## потеряны. Из групп выходим СРАЗУ до emit (queue_free отложен — см. контракт
## [[reference_godot_queue_free_deferred]]), чтобы AoE-цепочки не били труп.
func _fail() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(GROUP)
	remove_from_group(SKELETON_TARGET_GROUP)
	if LogConfig.master_enabled:
		print("[ConstructionSite] %s сорвана (hp<=0) — здание не построено" % _log_label)
	if is_instance_valid(_footprint_ring):
		_footprint_ring.queue_free()
	destroyed.emit()
	queue_free()


func _process(delta: float) -> void:
	if _destroyed or _finished:
		return
	if _start_delay > 0.0:
		_start_delay -= delta
		return
	_elapsed += delta
	var progress: float = clampf(_elapsed / _build_time, 0.0, 1.0)
	if _scaffold != null:
		_scaffold.scale.y = maxf(progress, 0.02)
	if progress >= 1.0:
		_complete()


## Стройка завершена — спавним настоящее здание через колбэк, dust-пуф, уходим.
func _complete() -> void:
	if _finished or _destroyed:
		return
	_finished = true
	remove_from_group(GROUP)
	remove_from_group(SKELETON_TARGET_GROUP)
	# Dust-пуф пропускаем в light-режиме (палисад волной — десятки GPUParticles
	# подряд = просадка FPS).
	if not _light_fx:
		var root: Node = get_tree().current_scene
		if root != null:
			AoeVisual.spawn_dust(root, global_position)
	if _on_complete.is_valid():
		_on_complete.call()
	if LogConfig.master_enabled:
		print("[ConstructionSite] %s завершена" % _log_label)
	if is_instance_valid(_footprint_ring):
		_footprint_ring.queue_free()
	queue_free()


## Чистка кольца если площадку убрали извне (свёртка лагеря — queue_free без
## _complete/_fail).
func _exit_tree() -> void:
	if is_instance_valid(_footprint_ring):
		_footprint_ring.queue_free()
		_footprint_ring = null


func _apply_scaffold_color() -> void:
	var mesh := _scaffold.get_node_or_null("ScaffoldMesh") as MeshInstance3D
	if mesh == null:
		return
	var mat := mesh.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = scaffold_color


## Красный flash при ударе — по образцу ArcherPost._flash_damage.
func _flash_damage() -> void:
	if _scaffold == null:
		return
	var mesh := _scaffold.get_node_or_null("ScaffoldMesh") as MeshInstance3D
	if mesh == null:
		return
	var mat := mesh.material_override as StandardMaterial3D
	if mat == null:
		return
	if not mat.emission_enabled:
		mat.emission_enabled = true
	var orig_emission: Color = mat.emission
	var orig_mult: float = mat.emission_energy_multiplier
	mat.emission = Color(1.0, 0.2, 0.2, 1.0)
	mat.emission_energy_multiplier = 2.5
	var tween := create_tween()
	tween.tween_property(mat, "emission", orig_emission, 0.18)
	tween.parallel().tween_property(mat, "emission_energy_multiplier", orig_mult, 0.18)
