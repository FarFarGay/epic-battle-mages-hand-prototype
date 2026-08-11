class_name MageVolley
extends Node3D
## ⭐ ЗАЛП ОГНЕВИКОВ — ОДИН НА ОБА ЭПИЗОДА (2026-08-11, следом за StoneWave).
##
## Каждый живой маг пускает мини-фаербол — ТУ ЖЕ `fireball.tscn`, что у Ладьи,
## меха и шквала («уменьшенная копия выстрела башни», новой сущности не заводим).
## Раньше залп жил внутри dungeon_sandbox и тянул за собой лёд ледника, поэтому
## в большом мире огневик был телом без глагола. Теперь общий узел: полёт, взрыв
## и прямое попадание тут, а лёд и прочая местная химия — по сигналу `exploded`.
##
## Урон ТРЕМЯ СЛОЯМИ, чтобы точность решала, а огонь добивал:
##   1. прямое попадание — бонус ближайшему у точки взрыва;
##   2. AOE взрыва слабый, с затуханием к краю;
##   3. горящая земля штатным BurnPatch.
##
## Как подключить:
##   var v := MageVolley.new()
##   add_child(v)
##   v.exploded.connect(...)      # что ещё делает огонь в этом эпизоде
##   ... каждый физкадр: v.tick(delta)
##   ... по кнопке: v.fire(mages, target_point)

const FIREBALL_SCENE: PackedScene = preload("res://scenes/fireball.tscn")
const BURN_PATCH_SCENE: PackedScene = preload("res://scenes/burn_patch.tscn")

## Взрыв мини-фаербола в точке. Эпизод добавляет своё: в подземелье огонь топит
## лёд (сегменты стен, колонны, глыбы завала) и прожигает талое пятно на катке.
signal exploded(origin: Vector3, radius: float)

## Числа — данжевые, финальные. Хозяин может переопределить.
var cooldown: float = 5.0
## Прямое попадание: бонус ближайшему врагу в этом радиусе от взрыва.
var direct_damage: float = 30.0
var direct_radius: float = 1.0
## AOE взрыва (слабый, затухает к краю) и его радиус.
var aoe_damage: float = 10.0
var aoe_radius: float = 2.6
## Горящая земля: пятак чуть уже AOE, тикает по врагам.
var burn_damage_per_tick: float = 4.0
var burn_tick_interval: float = 0.5
var burn_duration: float = 3.0
## Разброс точек прицеливания, когда магов больше одного (залп, а не одна точка).
var spread: float = 1.2

var _cd: float = 0.0


func cooldown_left() -> float:
	return _cd


func is_ready() -> bool:
	return _cd <= 0.0


func tick(delta: float) -> void:
	if _cd > 0.0:
		_cd = maxf(_cd - delta, 0.0)


## ПКМ: залп по точке курсора. Целиться можно куда угодно — в том числе в лёд
## или в стену: фаербол детонирует о преграду по пути и работает там, куда
## реально попал. true = ушёл (хозяин трясёт камеру и обновляет карточки).
func fire(mages: Array, target: Vector3) -> bool:
	if _cd > 0.0 or mages.is_empty() or target == Vector3.INF:
		return false
	_cd = cooldown
	var at := Vector3(target.x, 0.0, target.z)
	for i in range(mages.size()):
		var m = mages[i]
		if not is_instance_valid(m):
			continue
		var jitter := Vector3.ZERO
		if mages.size() > 1:
			jitter = Vector3(randf_range(-spread, spread), 0.0, randf_range(-spread, spread))
		_launch((m as Node3D).global_position, at + jitter)
	return true


## Один мини-фаербол: короткая пологая дуга из рук мага, взрыв малым AOE.
func _launch(from: Vector3, target: Vector3) -> void:
	var fb := FIREBALL_SCENE.instantiate() as Fireball
	if fb == null:
		return
	add_child(fb)
	fb.add_to_group(&"player_projectile")
	fb.setup(
		from + Vector3(0.0, 1.1, 0.0),
		target,
		0.22,   # boost: короткий подскок из рук
		5.5,    # вверх
		5.0,    # вперёд
		16.0,   # gravity дуги
		1.0,    # sway
		9.0,    # homing initial
		26.0,   # accel
		20.0,   # max speed
		6.0,    # drift angle
		9.0,    # turn rate
		aoe_damage,
		aoe_radius,
		Layers.MASK_HAND_SLAM,
		8.0,    # knockback
		0.35,   # lift
		0.25,   # duration
	)
	fb.set_collide_in_flight(true, Layers.TERRAIN)
	fb.shake_amount = 0.12
	fb.setup_burn(BURN_PATCH_SCENE, aoe_radius * 0.85,
			burn_damage_per_tick, burn_tick_interval, burn_duration)
	fb.hit.connect(_on_hit)


## Взрыв: «в кого прилетел, тому больно» — ближайший враг у точки взрыва берёт
## бонус-урон поверх слабого AOE. Дальше слово за эпизодом (лёд и прочее).
func _on_hit(origin: Vector3, radius: float) -> void:
	var direct: Node3D = null
	var direct_d: float = direct_radius
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or (sk as Node).is_queued_for_deletion():
			continue
		var sd: float = Vector2((sk as Node3D).global_position.x - origin.x,
				(sk as Node3D).global_position.z - origin.z).length()
		if sd < direct_d:
			direct_d = sd
			direct = sk as Node3D
	if direct != null:
		var dir: Vector3 = direct.global_position - origin
		dir.y = 0.0
		Damageable.try_damage(direct, direct_damage, HitStop.LIGHT,
				dir if dir.length_squared() > 0.01 else Vector3.FORWARD)
	exploded.emit(origin, radius)
