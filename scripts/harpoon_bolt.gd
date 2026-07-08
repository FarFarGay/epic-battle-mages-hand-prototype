class_name HarpoonBolt
extends Node3D
## Гарпун — стрела с верёвкой из башни (заклинание `harpoon`).
##
## ЕДИНАЯ МОДЕЛЬ: летит ПРЯМО от башни; мелких врагов пробивает НАСКВОЗЬ
## (урон → их собственный shatter, полёт продолжается), в ТЯЖЁЛОГО
## (super_dash_only / мех) или grabbable-ПРЕДМЕТ вцепляется и ПОДТЯГИВАЕТ
## к башне. Предмет и враг — один код-путь (PULL), никаких частных веток.
## Стена (544) или конец дистанции — пшик, верёвка исчезает.
##
## Верёвка ФИЗИЧЕСКАЯ: верлет-цепочка точек (гравитация + итерации
## расстояний, оба конца пришпилены к башне и стреле), рендер — сегменты-
## цилиндры. Провисает в полёте, натягивается при протяжке, не липнет в пол.

enum State { FLY, PULL, SPENT }

## Скорость полёта стрелы (м/с).
var bolt_speed: float = 40.0
## Урон мелочи при пробое (скелет hp 30, лучник ~50 — one-shot обоих).
var damage: float = 60.0
## Максимальная дистанция полёта от точки старта (XZ).
var max_range: float = 20.0
## Скорость подтягивания добычи к башне (м/с).
var pull_speed: float = 14.0
## Радиус захвата целей вокруг стрелы в полёте (XZ).
var hit_radius: float = 1.4
## На каком расстоянии от башни добыча отпускается (доставлена).
var release_distance: float = 3.5
## Safety-cap фазы PULL (жертва застряла за геометрией и т.п.).
var max_pull_time: float = 3.0

const HEAVY_GROUP := &"super_dash_only"
const WALL_MASK: int = Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE

## --- Верёвка (верлет) ---
## Точек в цепочке (сегментов на 1 меньше). 12 хватает на плавную дугу.
const ROPE_POINTS := 12
## Итераций удовлетворения расстояний за кадр: больше = жёстче натяжение.
const ROPE_ITERATIONS := 4
## Запас длины (провис): 1.0 = струна, 1.06 = слегка провисшая верёвка.
const ROPE_SLACK := 1.06
## Гравитация точек верёвки (своя, не physics — верёвка чисто визуальная).
const ROPE_GRAVITY := 18.0
## Затухание скорости точек (0..1) — гасит болтанку.
const ROPE_DAMPING := 0.92
## Ниже пола верёвку не пускаем (пол комнат y=0).
const ROPE_FLOOR_Y := 0.08
const ROPE_RADIUS := 0.07

## --- Отработанный гарпун (SPENT: воткнулся в стену / упал на промахе) ---
## Сам не исчезает — ОТМЕНА повторным ПКМ при выбранном гарпуне (cancel()).
## Safety-cap на совсем забытый гарпун.
const SPENT_SAFETY := 30.0
## Длительность fade-растворения.
const FADE_TIME := 0.8
## Быстрый fade после доставки добычи (верёвка своё отработала).
const FADE_TIME_DELIVERED := 0.35
## Резкий fade при РАЗРЫВЕ верёвки (вес/супер-дэш).
const FADE_TIME_SNAP := 0.4
## Гравитация падения стрелы на промахе.
const DROP_GRAVITY := 25.0
## Порог веса: RigidBody тяжелее — верёвка РВЁТСЯ при зацепе (предметы 3-4,
## порог с запасом; мех рвёт всегда — apex непротягиваем, см. _hook).
const ROPE_BREAK_MASS := 12.0

## Боевая высота полёта: стрела, выпущенная с крыши (дуло турели), плавно
## снижается к ней в FLY (NAN = лететь на высоте старта, как раньше).
var descend_to_y: float = NAN

var _tower: Node3D = null
var _effects_root: Node = null
var _dir: Vector3 = Vector3.FORWARD
var _start_pos: Vector3 = Vector3.ZERO
var _state: int = State.FLY
var _victim: Node3D = null
var _pull_t: float = 0.0
## Кого уже пробили этим выстрелом (не бить дважды).
var _pierced: Array = []

var _rope_root: Node3D = null
var _rope_segs: Array[MeshInstance3D] = []
var _pts: PackedVector3Array = PackedVector3Array()
var _prev_pts: PackedVector3Array = PackedVector3Array()

## Фиксированная длина верёвки: ставится В МОМЕНТ ЗАЦЕПА (стена/добыча) =
## текущая дистанция, не больше max_range. INF до зацепа (полёт не ограничивает).
## Дальше верёвка НЕ растягивается: воткнутый в стену гарпун держит башню
## привязью, рендер не резинится. Масштаб — через range в каталоге уровней.
var _rope_length: float = INF
## SPENT: true = воткнут в стену (висит), false = падает/лежит на земле.
var _stuck: bool = false
var _spent_t: float = 0.0
var _fall_vel: float = 0.0
var _fading: bool = false
## Материалы для fade-растворения (сталь стрелы + верёвка).
var _steel_mat: StandardMaterial3D = null
var _rope_mat: StandardMaterial3D = null


## Caller (HandSpellHarpoon) собирает и настраивает. dir — плоское направление.
## ⚠ Зовётся ПОСЛЕ add_child (значит после _ready) — всё, что зависит от
## _effects_root (верёвка), строим ЗДЕСЬ, не в _ready.
func setup(tower: Node3D, start_pos: Vector3, dir: Vector3, effects_root: Node) -> void:
	_tower = tower
	_effects_root = effects_root
	_start_pos = start_pos
	global_position = start_pos
	_dir = VecUtil.horizontal(dir).normalized()
	look_at(start_pos + _dir, Vector3.UP)
	_build_rope()


func _ready() -> void:
	_build_visual()


## Стрела: стальное древко + наконечник-конус.
func _build_visual() -> void:
	var shaft := MeshInstance3D.new()
	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(0.12, 0.12, 0.9)
	shaft.mesh = shaft_mesh
	_steel_mat = StandardMaterial3D.new()
	_steel_mat.albedo_color = Color(0.7, 0.78, 0.85)
	_steel_mat.metallic = 0.8
	_steel_mat.roughness = 0.35
	shaft.material_override = _steel_mat
	add_child(shaft)
	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.16
	tip_mesh.height = 0.4
	tip.mesh = tip_mesh
	tip.material_override = _steel_mat
	tip.position = Vector3(0.0, 0.0, -0.6)
	tip.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(tip)


## Верёвка: цепочка точек (верлет) + сегменты-цилиндры под ними. Живёт в
## _effects_root (мировые координаты, не крутится со стрелой).
func _build_rope() -> void:
	if _rope_root != null or _effects_root == null:
		return
	_rope_root = Node3D.new()
	_effects_root.add_child(_rope_root)
	_rope_mat = StandardMaterial3D.new()
	_rope_mat.albedo_color = Color(0.72, 0.55, 0.3)
	_rope_mat.roughness = 0.9
	_rope_mat.emission_enabled = true
	_rope_mat.emission = Color(0.72, 0.55, 0.3)
	_rope_mat.emission_energy_multiplier = 0.35
	var mat := _rope_mat
	var seg_mesh := CylinderMesh.new()
	seg_mesh.top_radius = ROPE_RADIUS
	seg_mesh.bottom_radius = ROPE_RADIUS
	seg_mesh.height = 1.0
	for i in range(ROPE_POINTS - 1):
		var seg := MeshInstance3D.new()
		seg.mesh = seg_mesh
		seg.material_override = mat
		_rope_root.add_child(seg)
		_rope_segs.append(seg)
	# Стартовая линия: башня → стрела, без скорости (prev = current).
	var anchor: Vector3 = _rope_anchor()
	_pts.resize(ROPE_POINTS)
	_prev_pts.resize(ROPE_POINTS)
	for i in range(ROPE_POINTS):
		var p: Vector3 = anchor.lerp(global_position, float(i) / float(ROPE_POINTS - 1))
		_pts[i] = p
		_prev_pts[i] = p


func _rope_anchor() -> Vector3:
	return _tower.global_position + Vector3.UP * 0.5


func _exit_tree() -> void:
	if _rope_root != null and is_instance_valid(_rope_root):
		_rope_root.queue_free()


func _physics_process(delta: float) -> void:
	if _tower == null or not is_instance_valid(_tower):
		queue_free()
		return
	match _state:
		State.FLY:
			_tick_fly(delta)
		State.PULL:
			_tick_pull(delta)
		State.SPENT:
			_tick_spent(delta)
	_tick_rope(delta)


func _tick_fly(delta: float) -> void:
	var prev: Vector3 = global_position
	global_position += _dir * bolt_speed * delta
	# Снижение с дула турели к боевой высоте (полого, ~2 горизонтали на 1 вниз).
	if not is_nan(descend_to_y):
		global_position.y = move_toward(global_position.y, descend_to_y, bolt_speed * 0.5 * delta)
	# Стена по пути → пшик, гарпун ломается об камень. Невидимые барьеры
	# ПРОПАСТЕЙ (chasm_barrier, тот же слой 544) — не стена: пропасть фейковая,
	# стрела летит НАД ней (пазл храма: стащить плиту-мост с того берега).
	var space := get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(prev, global_position, WALL_MASK)
		for _attempt in 4:
			var wall: Dictionary = space.intersect_ray(q)
			if wall.is_empty():
				break
			var collider := wall.get("collider") as Node3D
			if collider != null and collider.is_in_group(&"chasm_barrier"):
				q.exclude = q.exclude + [wall.get("rid")]
				continue
			_stick_to_wall(wall.get("position", global_position))
			return
	# Утварь (горшки) — разбиваем на пролёте, летим дальше.
	_smash_scenery()
	# Цели по пути: враг → тяжёлого цепляем / мелочь пробиваем; предмет → цепляем.
	var enemy: Node3D = _scan_enemy_hit()
	if enemy != null:
		if _is_heavy(enemy):
			_hook(enemy)
			return
		_pierce(enemy)
	var item: Node3D = _scan_item_hit()
	if item != null:
		_hook(item)
		return
	if VecUtil.horizontal(global_position - _start_pos).length() >= max_range:
		_drop()


## Ближайший враг в hit_radius (XZ, по origin'у — юниты компактные).
func _scan_enemy_hit() -> Node3D:
	var best: Node3D = null
	var best_d: float = hit_radius * hit_radius
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n) or n in _pierced or n == _victim:
			continue
		var t := n as Node3D
		if t == null or Layers.is_hand_immune(t):
			continue
		var d: Vector3 = t.global_position - global_position
		var d_sq: float = d.x * d.x + d.z * d.z
		if d_sq < best_d:
			best_d = d_sq
			best = t
	return best


## Свободный grabbable-предмет под стрелой: sphere-query по слою ITEMS — бьём
## по КОЛЛАЙДЕРУ, не по origin'у (мост длинный: выстрел в край плашки от её
## центра дальше hit_radius, group-скан промахивался).
func _scan_item_hit() -> Node3D:
	var space := get_world_3d().direct_space_state
	if space == null:
		return null
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = hit_radius
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, global_position)
	params.collision_mask = Layers.ITEMS
	for hit in space.intersect_shape(params, 6):
		var t := hit.get("collider") as Node3D
		if t == null or not Grabbable.is_grabbable(t) or Layers.is_hand_immune(t):
			continue
		if t in _pierced or t == _victim:
			continue
		# Замороженный RigidBody = в руке / смонтирован в гнездо — не трогаем.
		if t is RigidBody3D and (t as RigidBody3D).freeze:
			continue
		return t
	return null


## Горшки и прочая бьющаяся утварь (shield_breakable) на пролёте: тот же
## контракт on_spark, что у щита башни и Искры. Гарпун их пробивает не
## останавливаясь; _pierced — от двойного вызова до queue_free горшка.
func _smash_scenery() -> void:
	for n in get_tree().get_nodes_in_group(Layers.SHIELD_BREAKABLE_GROUP):
		if not is_instance_valid(n) or n in _pierced:
			continue
		var node := n as Node3D
		if node == null or not node.has_method(&"on_spark"):
			continue
		var d: Vector3 = node.global_position - global_position
		if d.x * d.x + d.z * d.z <= hit_radius * hit_radius:
			_pierced.append(node)
			node.call(&"on_spark")


func _is_heavy(target: Node3D) -> bool:
	return target.is_in_group(HEAVY_GROUP) or target.is_in_group(EnemyMech.MECH_GROUP)


## Мелочь: урон (умирает своим shatter'ом) и летим дальше.
func _pierce(target: Node3D) -> void:
	_pierced.append(target)
	if target.has_method(&"take_damage"):
		target.call(&"take_damage", damage)
		HitStop.fire_for(target, HitStop.LIGHT)
	if _effects_root != null:
		AoeVisual.spawn_pulse_sparks(_effects_root, target.global_position, 0.8, 8.0)


## Тяжёлый враг или предмет: вцепились — тянем к башне. Сверхтяжёлое
## (масса > ROPE_BREAK_MASS, мех) верёвка НЕ держит — рвётся.
func _hook(target: Node3D) -> void:
	_victim = target
	_state = State.PULL
	_pull_t = 0.0
	global_position = target.global_position + Vector3.UP * 0.6
	_fix_rope_length()
	HitStop.fire_for(target, HitStop.LIGHT)
	EventBus.camera_shake.emit(0.3, target.global_position)
	if _effects_root != null:
		AoeVisual.spawn_pulse_sparks(_effects_root, target.global_position, 1.2, 10.0)
	# Тяжёлому — небольшой чип-урон за попадание (гарпун всё-таки железо).
	if _is_heavy(target) and target.has_method(&"take_damage"):
		target.call(&"take_damage", damage * 0.35)
	# РАЗРЫВ ПО ВЕСУ: слишком тяжёлая добыча (или мех — apex непротягиваем).
	var too_heavy: bool = target.is_in_group(EnemyMech.MECH_GROUP) \
		or (target is RigidBody3D and (target as RigidBody3D).mass > ROPE_BREAK_MASS)
	if too_heavy:
		_snap_rope()


## Верёвка НЕ ВЫДЕРЖАЛА (вес добычи / супер-дэш на привязи): разрыв — искры
## в середине, короткий резкий fade.
func _snap_rope() -> void:
	if _fading:
		return
	if _effects_root != null and _pts.size() == ROPE_POINTS:
		var mid: Vector3 = _pts[ROPE_POINTS / 2]
		AoeVisual.spawn_pulse_sparks(_effects_root, mid, 1.0, 12.0)
	EventBus.camera_shake.emit(0.2, global_position)
	_release(FADE_TIME_SNAP)


## Можно ли отменить повторным ПКМ: в полёте НЕЛЬЗЯ (спам ПКМ не должен
## убивать собственный выстрел), зацепленный/воткнутый/лежащий — можно.
func can_cancel() -> bool:
	return _state != State.FLY and not _fading


## Ручная отмена (повторный ПКМ при выбранном гарпуне): нативный fade.
func cancel() -> void:
	_release(FADE_TIME)


func _tick_pull(delta: float) -> void:
	_pull_t += delta
	if _victim == null or not is_instance_valid(_victim) or _pull_t >= max_pull_time:
		_release(FADE_TIME_DELIVERED)
		return
	# Жертву заморозили в полёте (рука перехватила / плита-мост защёлкнулась
	# авто-снапом) — добыча «встала на место», верёвка отпускает.
	if _victim is RigidBody3D and (_victim as RigidBody3D).freeze:
		_release(FADE_TIME_DELIVERED)
		return
	var to_tower: Vector3 = VecUtil.horizontal(_tower.global_position - _victim.global_position)
	if to_tower.length() <= release_distance:
		_release(FADE_TIME_DELIVERED)  # доставлено — добыча у башни
		return
	var step: Vector3 = to_tower.normalized() * pull_speed
	if _victim is RigidBody3D:
		# Предмет тянем физикой: скорость к башне (Y не трогаем — гравитация
		# своя). sleeping=false ОБЯЗАТЕЛЕН: лежащий предмет спит, и присвоение
		# linear_velocity спящее тело НЕ будит — гарпун цеплялся, но не тянул.
		var rb := _victim as RigidBody3D
		rb.sleeping = false
		rb.linear_velocity.x = step.x
		rb.linear_velocity.z = step.z
	else:
		# CharacterBody-враг: позиционное волочение по XZ (AI-скорость перебивается
		# каждый физкадр — верёвка сильнее ног).
		_victim.global_position += step * delta
	# Стрела сидит в жертве.
	global_position = _victim.global_position + Vector3.UP * 0.6


## Стена: гарпун ВТЫКАЕТСЯ и висит — верёвка натянута к башне, живёт физикой
## (башня едет — тянется). Через SPENT_LINGER растворяется.
func _stick_to_wall(hit_pos: Vector3) -> void:
	_state = State.SPENT
	_stuck = true
	_spent_t = 0.0
	global_position = hit_pos - _dir * 0.15  # чуть утоплен в стену наконечником
	_fix_rope_length()
	if _effects_root != null:
		AoeVisual.spawn_pulse_sparks(_effects_root, hit_pos, 0.7, 8.0)


## Зафиксировать длину верёвки на текущей дистанции (кап max_range).
func _fix_rope_length() -> void:
	_rope_length = clampf(_rope_anchor().distance_to(global_position), 2.0, max_range)


## Промах по дальности: стрела теряет ход и ПАДАЕТ, верёвка провисает и
## болтается по земле. Длина фиксируется ЗДЕСЬ ЖЕ — уезжающая башня не
## растягивает верёвку, а ВОЛОЧЁТ упавший гарпун за собой (_enforce_bolt_drag).
func _drop() -> void:
	_state = State.SPENT
	_stuck = false
	_spent_t = 0.0
	_fall_vel = 0.0
	_fix_rope_length()


## Отработанный гарпун: висит в стене / падает и лежит, затем нативное
## растворение (fade), не мгновенный «пшик».
func _tick_spent(delta: float) -> void:
	if not _stuck and global_position.y > ROPE_FLOOR_Y + 0.1:
		_fall_vel += DROP_GRAVITY * delta
		global_position.y = maxf(global_position.y - _fall_vel * delta, ROPE_FLOOR_Y + 0.1)
		# Нос опускается по мере падения — стрела «клюёт».
		rotate_object_local(Vector3.RIGHT, -1.8 * delta)
	if not _fading:
		if _stuck:
			_enforce_tower_tether()
		else:
			_enforce_bolt_drag()
	_spent_t += delta
	if _spent_t >= SPENT_SAFETY:
		_release(FADE_TIME)  # забытый гарпун — safety, обычный путь = cancel()


## ПРИВЯЗЬ: воткнутый в стену гарпун держит башню на длине верёвки — уехать
## дальше нельзя, башню осаживает обратно по XZ (Y не трогаем — origin башни
## приподнят). Верёвка сильнее хода: работает и против рывка, и против
## отбросов — «зафиксировался у стены».
func _enforce_tower_tether() -> void:
	if _tower == null or not is_instance_valid(_tower):
		return
	var to_tower: Vector3 = VecUtil.horizontal(_tower.global_position - global_position)
	var dist: float = to_tower.length()
	if dist <= _rope_length or dist < 0.01:
		return
	# РАЗРЫВ ПО СИЛЕ: супер-дэш на натянутой привязи рвёт верёвку — осознанный
	# способ сорваться с фиксации (обычный ход/рывок верёвка держит).
	if bool(_tower.get(&"_dash_is_super")) and float(_tower.get(&"_dash_timer")) > 0.0:
		_snap_rope()
		return
	var clamped: Vector3 = global_position + to_tower / dist * _rope_length
	_tower.global_position.x = clamped.x
	_tower.global_position.z = clamped.z


## Обратная сторона привязи: УПАВШИЙ гарпун (промах) волочится ЗА башней по
## земле, когда верёвка натянулась — лёгкий конец тащится за тяжёлым, длина
## не растягивается.
func _enforce_bolt_drag() -> void:
	var anchor: Vector3 = _rope_anchor()
	var to_bolt: Vector3 = VecUtil.horizontal(global_position - anchor)
	var dist: float = to_bolt.length()
	if dist <= _rope_length or dist < 0.01:
		return
	var clamped: Vector3 = anchor + to_bolt / dist * _rope_length
	global_position.x = clamped.x
	global_position.z = clamped.z


## Нативное исчезновение: fade прозрачностью стрелы и верёвки → queue_free.
## Идемпотентно (повторные вызовы не перезапускают tween).
func _release(fade_time: float) -> void:
	if _fading:
		return
	_fading = true
	_state = State.SPENT  # геймплей закончен, остался только визуал
	var tw := create_tween().set_parallel(true)
	for m in [_steel_mat, _rope_mat]:
		var mat := m as StandardMaterial3D
		if mat == null:
			continue
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		tw.tween_property(mat, "albedo_color:a", 0.0, fade_time)
		if mat.emission_enabled:
			tw.tween_property(mat, "emission_energy_multiplier", 0.0, fade_time)
	tw.chain().tween_callback(queue_free)


## --- Верёвка: верлет-симуляция + рендер сегментов ---

func _tick_rope(delta: float) -> void:
	if _rope_root == null or _pts.size() != ROPE_POINTS:
		return
	var anchor: Vector3 = _rope_anchor()
	# Интеграция: внутренние точки летят по инерции + гравитация вниз.
	for i in range(1, ROPE_POINTS - 1):
		var cur: Vector3 = _pts[i]
		var vel: Vector3 = (cur - _prev_pts[i]) * ROPE_DAMPING
		_prev_pts[i] = cur
		_pts[i] = cur + vel + Vector3.DOWN * ROPE_GRAVITY * delta * delta
	# Длина сегмента: расстояние между концами с запасом провиса, но НЕ длиннее
	# зафиксированной длины верёвки (после зацепа верёвка не резинится:
	# концы дальше — она струной, ближе — провисает сильнее).
	var rest: float = minf(anchor.distance_to(global_position), _rope_length) \
		* ROPE_SLACK / float(ROPE_POINTS - 1)
	for _it in range(ROPE_ITERATIONS):
		_pts[0] = anchor
		_pts[ROPE_POINTS - 1] = global_position
		for i in range(ROPE_POINTS - 1):
			var a: Vector3 = _pts[i]
			var b: Vector3 = _pts[i + 1]
			var seg: Vector3 = b - a
			var l: float = seg.length()
			if l < 0.0001:
				continue
			var corr: Vector3 = seg * ((l - rest) / l)
			if i == 0:
				_pts[i + 1] = b - corr  # конец у башни пришпилен
			elif i == ROPE_POINTS - 2:
				_pts[i] = a + corr  # конец у стрелы пришпилен
			else:
				_pts[i] = a + corr * 0.5
				_pts[i + 1] = b - corr * 0.5
	# Пол: верёвка не проваливается.
	for i in range(1, ROPE_POINTS - 1):
		if _pts[i].y < ROPE_FLOOR_Y:
			_pts[i] = Vector3(_pts[i].x, ROPE_FLOOR_Y, _pts[i].z)
	_render_rope()


## Сегменты-цилиндры по точкам. Растяжение — ЛОКАЛЬНОЙ оси Y базиса (колонка
## вдоль сегмента). Не .scaled(): тот умножает слева = мировые оси, и верёвка
## вставала вертикальной лентой.
func _render_rope() -> void:
	for i in range(_rope_segs.size()):
		var seg_node: MeshInstance3D = _rope_segs[i]
		if not is_instance_valid(seg_node):
			continue
		var a: Vector3 = _pts[i]
		var b: Vector3 = _pts[i + 1]
		var seg: Vector3 = b - a
		var seg_len: float = seg.length()
		if seg_len < 0.01:
			seg_node.visible = false
			continue
		seg_node.visible = true
		var dir_n: Vector3 = seg / seg_len
		var seg_basis: Basis
		if dir_n.dot(Vector3.UP) < -0.999:
			# Сегмент строго вниз: кватернион UP→(-UP) вырожден (NaN) — явный переворот.
			seg_basis = Basis(Vector3.RIGHT, PI)
		else:
			seg_basis = Basis(Quaternion(Vector3.UP, dir_n))
		seg_basis.y *= seg_len
		seg_node.global_transform = Transform3D(seg_basis, a + seg * 0.5)
