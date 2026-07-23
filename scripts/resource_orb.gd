class_name ResourceOrb
extends Node3D
## Маленькая кучка ресурса, которую рабочий роняет У ИСТОЧНИКА, когда склад башни
## полон по этому типу (сдать некуда). Лежит и покачивается; КАК ТОЛЬКО у склада
## появляется место по её типу И башня в своей зоне (gather_radius) — кучка летит к
## башне (магнит, как XpOrb) и сдаётся. Не влезло всё (склад добился по пути) —
## возвращается в IDLE с остатком. Лёгкая (Node3D), строится в коде.
##
## Дроп/слияние делает рабочий ([SoldierGnome._drop_carried_as_orb]): соседние кучки
## того же типа в MERGE_RADIUS не плодятся — растёт `amount` существующей.

const GROUP := &"resource_orb"
## Радиус слияния при дропе: новая единица вливается в idle-кучку того же типа рядом.
const MERGE_RADIUS: float = 1.4

## Тип ресурса (ResourcePile.ResourceType). Задаётся при дропе ДО add_child.
var resource_type: int = ResourcePile.ResourceType.WOOD
## Сколько единиц в кучке. Растёт при слиянии, тратится при сдаче на склад.
var amount: int = 1

@export var magnet_speed: float = 12.0
@export var arrival_distance: float = 0.7
@export var bob_amplitude: float = 0.12
@export var bob_speed: float = 2.2
## Период проверки «есть ли место на складе + башня в зоне» (с). Дёшево.
const SCAN_INTERVAL: float = 0.25

enum State { IDLE, MAGNETIZED, POPPING }

var _state: State = State.IDLE
## POPPING (шматок из лопнувшей жилы): баллистический подлёт до _pop_land_y,
## дальше обычный IDLE (качается, ждёт магнита башни). См. launch().
var _pop_velocity: Vector3 = Vector3.ZERO
var _pop_land_y: float = 0.35
const POP_GRAVITY: float = 14.0
## Визуал «осколка жилы»: задан (alpha > 0) → меш не тип-цветной бокс, а
## кристалл-призма этого цвета (как кристаллы залежи в VeinVisuals) с
## кувырком в полёте. Один язык — один смысл (юзер 2026-07-21): осколок,
## вылетающий из жилы, и ЕСТЬ шматок ресурса; отдельного FX-шаттера при
## выбивании нет, кристальный цвет = «это можно собрать».
var shard_color: Color = Color(0, 0, 0, 0)
## Кувырок осколка в полёте (POPPING/MAGNETIZED). Ось и скорость — случайные.
var _spin_axis: Vector3 = Vector3.UP
var _spin_speed: float = 0.0
var _elapsed: float = 0.0
var _bob_phase: float = 0.0
## Высота, вокруг которой качается и на которой летит (горизонтальный полёт).
var _base_y: float = 0.0
var _scan_timer: float = 0.0
var _mesh: MeshInstance3D = null
var _tower: Node3D = null


func _ready() -> void:
	add_to_group(GROUP)
	_base_y = global_position.y
	_bob_phase = randf() * TAU
	_build_mesh()


func is_idle() -> bool:
	return _state == State.IDLE


## Выстрелить кучку дугой (шматок, выбитый рукой из жилы — VeinBoulder). Звать
## ПОСЛЕ add_child + установки global_position. Летит баллистикой (POP_GRAVITY)
## до высоты land_y, там переходит в IDLE — качается и ждёт магнита башни.
## В полёте не сливается и не магнитится (is_idle() == false).
func launch(velocity: Vector3, land_y: float = 0.35) -> void:
	_pop_velocity = velocity
	_pop_land_y = land_y
	# Кувырок на время полёта — осколок, а не парящий куб.
	_spin_axis = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	if _spin_axis.length_squared() < 0.5:
		_spin_axis = Vector3.UP
	_spin_speed = randf_range(3.0, 7.0)
	_state = State.POPPING


## Влить ещё единиц (слияние при дропе рядом). Растит визуал.
func add_units(n: int) -> void:
	amount += maxi(n, 0)
	_refresh_scale()


func _build_mesh() -> void:
	_mesh = MeshInstance3D.new()
	var c: Color
	if shard_color.a > 0.0:
		# Осколок жилы: кристалл-призма (та же форма, что кристаллы залежи
		# в VeinVisuals) цвета кристаллов жилы, светится ярче бокса.
		var prism := CylinderMesh.new()
		prism.top_radius = 0.0
		prism.bottom_radius = 0.19
		prism.height = 0.72
		prism.radial_segments = 5
		prism.rings = 1
		_mesh.mesh = prism
		c = shard_color
	else:
		var box := BoxMesh.new()
		box.size = Vector3(0.4, 0.3, 0.4)
		_mesh.mesh = box
		c = ResourcePile.color_for_type(resource_type)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 1.2 if shard_color.a > 0.0 else 0.5
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	_refresh_scale()


## Кучка чуть растёт с запасом (маленькая, чтобы не загромождать). Высота низкая —
## «насыпь у пенька».
func _refresh_scale() -> void:
	if not is_instance_valid(_mesh):
		return
	var s: float = clampf(0.6 + 0.06 * float(amount), 0.6, 1.6)
	_mesh.scale = Vector3(s, s, s)


func _physics_process(delta: float) -> void:
	match _state:
		State.IDLE:
			_elapsed += delta
			global_position.y = _base_y + sin(_elapsed * bob_speed + _bob_phase) * bob_amplitude
			_scan_timer -= delta
			if _scan_timer <= 0.0:
				_scan_timer = SCAN_INTERVAL
				_try_magnetize()
		State.MAGNETIZED:
			_tick_magnet(delta)
		State.POPPING:
			_tick_pop(delta)


## Баллистика подлёта: гравитация + перенос. Коллизий нет (Node3D) — просто
## дуга до land_y на нисходящей ветке. Приземлился → фиксируем _base_y и в IDLE.
func _tick_pop(delta: float) -> void:
	if _spin_speed > 0.0:
		rotate(_spin_axis, _spin_speed * delta)
	_pop_velocity.y -= POP_GRAVITY * delta
	global_position += _pop_velocity * delta
	if _pop_velocity.y < 0.0 and global_position.y <= _pop_land_y:
		global_position.y = _pop_land_y
		_base_y = _pop_land_y
		_elapsed = 0.0
		_state = State.IDLE
		# Скан сразу на приземлении (не ждать 0.25с): если башня уже в зоне —
		# шматок подхватывается без паузы. Вне зоны — обычное ожидание.
		_scan_timer = 0.0
		_try_magnetize()


## Магнит включается, когда: башня есть, кучка в её зоне добычи (gather_radius —
## та же зона, что у рабочих; 0 → без ограничения), И на складе есть МЕСТО по типу.
func _try_magnetize() -> void:
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if tower == null:
		return
	var gr: Variant = tower.get(&"gather_radius")
	var r: float = float(gr) if (typeof(gr) == TYPE_FLOAT or typeof(gr) == TYPE_INT) else 0.0
	if r > 0.0:
		var dx: float = global_position.x - tower.global_position.x
		var dz: float = global_position.z - tower.global_position.z
		if dx * dx + dz * dz > r * r:
			return  # башня далеко — ждём, пока подойдёт/освободит зону
	var store := get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
	if store == null or store.is_full(resource_type):
		return  # места нет — лежим дальше
	_tower = tower
	_state = State.MAGNETIZED


## Летит к башне по XZ на высоте _base_y; прибыл — сдаёт на склад. Влезло не всё
## (склад добился) — назад в IDLE с остатком, ждём следующего окна.
func _tick_magnet(delta: float) -> void:
	if _tower == null or not is_instance_valid(_tower):
		_state = State.IDLE  # башня исчезла — не теряем кучку, ждём заново
		return
	if _spin_speed > 0.0:
		rotate(_spin_axis, _spin_speed * delta)
	var target := Vector3(_tower.global_position.x, _base_y, _tower.global_position.z)
	var to_target := target - global_position
	var dist: float = to_target.length()
	if dist <= arrival_distance:
		_arrive()
		return
	var step: float = magnet_speed * delta
	if step >= dist:
		global_position = target
	else:
		global_position += to_target / dist * step


func _arrive() -> void:
	var store := get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
	if store != null:
		var accepted: int = int(store.call(&"deposit", resource_type, amount))
		amount -= accepted
	if amount <= 0:
		queue_free()
		return
	# Склад добился по пути — остаток роняем здесь, ждём следующего окна.
	_base_y = global_position.y
	_refresh_scale()
	_state = State.IDLE
