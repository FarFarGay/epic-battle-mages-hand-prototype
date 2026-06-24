class_name PadArcher
extends Node3D
## Лучник казармы ([PadBuilding] роль barracks, corner_tower). Ходит по БОЕВОМУ ХОДУ —
## проходимым клеткам сети (стена/ворота/казарма) на высоте верха стены. Башенный
## (branch_dir == ZERO) стоит на башне; патрульные идут по «рукаву» (стене/воротам от
## казармы) пинг-понгом. Маршрут пересчитывается периодически — стены меняются на ходу.
## Стрельба по врагам — следующий шаг. Спавнится казармой как top_level-ребёнок.

const SPEED := 1.5
const REPATH := 0.6
const ARROW := preload("res://scenes/arrow.tscn")
const ARROW_SPEED := 22.0

var home_cell: Vector2i = Vector2i.ZERO       # мировая клетка угла казармы
var branch_dir: Vector2i = Vector2i.ZERO      # направление рукава (ZERO = башенный)
var tower_pos: Vector3 = Vector3.ZERO         # пост на башне (для башенного)

var _route: Array = []   # Array[Vector3] точки боевого хода
var _i: int = 0
var _dir: int = 1
var _t: float = 0.0
# Боевые статы — из каталога наёмного лучника (та же логика/баланс).
var _range: float = 18.0
var _dmg_min: float = 8.0
var _dmg_max: float = 12.0
var _cd_min: float = 0.8
var _cd_max: float = 1.4
var _cd: float = 0.0


func setup(hc: Vector2i, bd: Vector2i, tp: Vector3) -> void:
	home_cell = hc
	branch_dir = bd
	tower_pos = tp


func _ready() -> void:
	_build_visual()
	_t = randf() * REPATH  # фазовый разброс пересчёта
	# Боевые статы наёмного лучника (дальность/урон/кулдаун) — единый баланс.
	var st: Dictionary = SoldierSystem.get_soldier_data(&"archer_squad").get("stats", {})
	_range = float(st.get("attack_range", _range))
	_dmg_min = float(st.get("attack_damage_min", _dmg_min))
	_dmg_max = float(st.get("attack_damage_max", _dmg_max))
	_cd_min = float(st.get("attack_cooldown_min", _cd_min))
	_cd_max = float(st.get("attack_cooldown_max", _cd_max))
	_recompute()
	if not _route.is_empty():
		global_position = _route[0]


func _build_visual() -> void:
	var cloth := _mat(Color(0.28, 0.46, 0.7))   # синий — лучники
	var skin := _mat(Color(0.85, 0.7, 0.55))
	var wood := _mat(Color(0.3, 0.2, 0.12))
	_b(Vector3(0.34, 0.5, 0.26), Vector3(0, 0.45, 0), cloth)   # тело
	_b(Vector3(0.26, 0.26, 0.24), Vector3(0, 0.82, 0), skin)   # голова
	_b(Vector3(0.06, 0.62, 0.06), Vector3(0.22, 0.55, 0), wood)  # лук


func _process(delta: float) -> void:
	_cd -= delta
	# Бой: есть враг в радиусе → стоим на месте и стреляем (как стационарный лучник).
	var enemy := _nearest_enemy()
	if enemy != null:
		_face(enemy.global_position)
		if _cd <= 0.0:
			_fire(enemy)
			_cd = randf_range(_cd_min, _cd_max)
		return
	# Иначе — патруль боевого хода.
	_t -= delta
	if _t <= 0.0:
		_t = REPATH
		_recompute()
	if _route.is_empty():
		return
	_i = clampi(_i, 0, _route.size() - 1)
	var target: Vector3 = _route[_i]
	var flat: Vector3 = target - global_position
	flat.y = 0.0
	if flat.length() <= 0.12:
		if _route.size() > 1:
			_i += _dir
			if _i >= _route.size():
				_i = _route.size() - 2
				_dir = -1
			elif _i < 0:
				_i = 1
				_dir = 1
			_i = clampi(_i, 0, _route.size() - 1)
	else:
		global_position += flat.normalized() * SPEED * delta
	# Плавно подстраиваем высоту под боевой ход (всходы/спуски).
	global_position.y = lerp(global_position.y, target.y, 1.0 - exp(-8.0 * delta))


func _recompute() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if branch_dir == Vector2i.ZERO:
		_route = [tower_pos]
		return
	var r: Array = PadBuilding.wall_route(tree, home_cell + branch_dir, branch_dir)
	if r.is_empty():
		r = [PadBuilding.cell_top(home_cell, tree)]  # стен ещё нет — топчемся у казармы
	_route = r


## Ближайший враг в радиусе стрельбы (XZ). Группа врагов — общая (скелеты и пр.).
func _nearest_enemy() -> Node3D:
	var best: Node3D = null
	var bd: float = _range * _range
	for e in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(e) or not (e is Node3D):
			continue
		var n := e as Node3D
		var dx: float = n.global_position.x - global_position.x
		var dz: float = n.global_position.z - global_position.z
		var d: float = dx * dx + dz * dz
		if d < bd:
			bd = d
			best = n
	return best


## Выстрел стрелой (тот же снаряд, что у наёмных лучников) во врага.
func _fire(target: Node3D) -> void:
	var root := get_tree().current_scene
	if root == null or not is_instance_valid(target):
		return
	var a := ARROW.instantiate() as Arrow
	if a == null:
		return
	root.add_child(a)
	a.damage = randf_range(_dmg_min, _dmg_max)
	a.speed = ARROW_SPEED
	a.setup(global_position + Vector3(0, 0.6, 0), target.global_position + Vector3(0, 0.5, 0))


func _face(world_pos: Vector3) -> void:
	var flat := Vector3(world_pos.x, global_position.y, world_pos.z)
	if flat.distance_to(global_position) > 0.05:
		look_at(flat, Vector3.UP)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


func _b(size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
