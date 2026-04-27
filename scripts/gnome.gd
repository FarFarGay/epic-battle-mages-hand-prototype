class_name Gnome
extends CharacterBody3D
## Гном — обитатель лагеря. По 2 на палатку. Сам ищет ресурсы патрулём,
## находит глазами и сам носит ресурс челноком. По сигналу кампа →
## возвращается в свою палатку.
##
## Двухфазная FSM сбора:
##   ФАЗА 1 (поиск): SEARCHING — каждый кадр гном:
##     1) Глазами сканирует кучи в vision_radius от себя. Учитывает только
##        кучи, которые ещё никем не нацелены (Camp.is_pile_claimed) — каждый
##        ищет «своё», нашедший один не созывает остальных.
##     2) Если в мире вообще нет куч (анти-livelock-чек на пустой group) —
##        переход в IDLE_NEAR_BASE.
##     3) Иначе патрулируем: случайные точки в search_radius от anchor'а.
##        Глаза ловят кучи, мимо которых проходим.
##   ФАЗА 2 (челнок): COMMUTING_TO_PILE → COMMUTING_TO_BASE → ... пока
##     закреплённая куча валидна. На опустошении → SEARCHING (ищет дальше).
##
## Прочие состояния:
##   IN_TENT — приклеен к палатке, скрыт. Состояние по умолчанию (караван).
##   RETURNING_TO_TENT — лагерь сворачивается, гном идёт к своей палатке.
##                       Несомый ресурс роняется по дороге (queue_free).
##   IDLE_NEAR_BASE — куч на карте нет вообще, гном ошивается возле anchor'а.
##
## Связь с лагерем: setup(camp, home_tent). Гном не сканирует tower/спавнер —
## всё через camp. Кучи между гномами не делятся через broadcast: гном видит
## только свою vision-зону и сам решает, куда бежать.
##
## Цель скелетов: пока гном НЕ IN_TENT, он зарегистрирован в группе
## skeleton_target — скелеты находят его глазами в их vision_radius.
## При переходе в IN_TENT/RETURNING_TO_TENT он из группы выходит. На смерти —
## destroyed signal, Camp вычищает себя из массива _gnomes по сигналу.

signal damaged(amount: float)
signal destroyed

const SKELETON_TARGET_GROUP := &"skeleton_target"

enum State {
	IN_TENT,
	SEARCHING,
	COMMUTING_TO_PILE,
	COMMUTING_TO_BASE,
	IDLE_NEAR_BASE,
	RETURNING_TO_TENT,
}

@export_group("Stats")
@export var hp: float = 20.0
## Замедление knockback-скорости в секунду — пока knockback_timer > 0,
## AI не управляет скоростью, она затухает к нулю.
@export var knockback_friction: float = 6.0

@export_group("Movement")
@export var move_speed: float = 1.6
@export var gravity: float = 20.0

@export_group("Behaviour")
## Радиус патруля — где гном выбирает случайные точки во время SEARCHING.
## Покрывает всю карту от любой точки развёртки. Карта 200×200, диагональ ~283.
@export var search_radius: float = 300.0
## Дальность зрения гнома: куча в этом радиусе считается «увиденной».
## Маленький радиус → дольше искать; большой → почти всезнайство.
@export var vision_radius: float = 10.0
## Радиус «ошивания» возле anchor'а, когда на карте не осталось куч.
@export var idle_radius: float = 4.0
## Дистанция до кучи, на которой считаем «дошёл — можно брать».
@export var pickup_distance: float = 0.8
## Дистанция до anchor'а лагеря для сдачи ресурса.
@export var deposit_distance: float = 1.2
## Дистанция до палатки, на которой гном «дома».
@export var home_distance: float = 0.8
## Дистанция до wander-точки, чтобы выбрать новую (или после прибытия).
@export var wander_arrival: float = 0.6
## Половина стороны квадратной карты от центра (0,0). Wander-точки клампятся
## в этих пределах, чтобы при search_radius=300 на карте 200×200 гном не
## уходил за пол. Должно совпадать со Skeleton.wander_map_half_extent.
@export var wander_map_half_extent: float = 95.0

@export_group("Visual")
@export var gnome_color: Color = Color(0.7, 0.45, 0.25)
@export var carry_color: Color = Color(0.4, 0.75, 0.3)
@export var carry_visual_size: Vector3 = Vector3(0.3, 0.3, 0.3)

@export_group("Shatter (рассыпание на смерти)")
@export var shatter_fragment_count: int = 6
@export var shatter_lifetime: float = 1.5
## Куда складывать фрагменты. Пусто → fallback на current_scene. Лагерь как
## parent НЕ подходит: при свёртке/смерти кампа дети-фрагменты были бы
## уничтожены вместе с ним; current_scene их переживает.
@export_node_path("Node") var effects_root_path: NodePath

@export_group("")
@export var debug_log: bool = false

var _camp: Camp
var _home_tent: Node3D
var _state: State = State.IN_TENT
var _assigned_pile: ResourcePile = null
var _wander_target: Vector3 = Vector3.INF
var _carry_visual: MeshInstance3D = null
var _knockback := KnockbackState.new()
var _dying: bool = false
var _effects_root: Node = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D


## Камп вызывает после спавна гнома. До этого момента — без активной логики.
func setup(camp: Camp, home_tent: Node3D) -> void:
	_camp = camp
	_home_tent = home_tent
	_apply_visual()
	_enter_in_tent()


func _ready() -> void:
	# До setup просто стоим. Без камп-ссылки FSM не имеет смысла.
	visible = false
	Damageable.register(self)
	Pushable.register(self)
	_knockback.friction = knockback_friction
	# _effects_root: явный path → ноду; пустой/неразрешённый → fallback на
	# current_scene. Камп родитель нам НЕ подходит — он мог бы освободиться
	# до окончания shatter-таймера, и фрагменты испарились бы.
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	damaged.connect(func(amount: float) -> void: EventBus.gnome_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.gnome_destroyed.emit(self))


func _apply_visual() -> void:
	if not _mesh:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = gnome_color
	_mesh.material_override = mat


# --- API для Camp ---

## Лагерь развернулся — выходим в фазу поиска.
func enter_deployed() -> void:
	visible = true
	_assigned_pile = null
	_wander_target = Vector3.INF
	_state = State.SEARCHING
	# Снаружи и виден → цель скелетов.
	add_to_group(SKELETON_TARGET_GROUP)
	if debug_log and LogConfig.master_enabled:
		print("[Gnome:%s] вышел из палатки" % name)


## Лагерь свёртывается — возвращаемся в палатку. Roняем то, что несли.
func request_return() -> void:
	if _state == State.IN_TENT:
		return
	_drop_carry()
	_assigned_pile = null
	_state = State.RETURNING_TO_TENT
	# Идёт домой — больше не цель скелетов (логически отступает).
	remove_from_group(SKELETON_TARGET_GROUP)
	if debug_log and LogConfig.master_enabled:
		print("[Gnome:%s] возвращается в палатку" % name)


func is_home() -> bool:
	return _state == State.IN_TENT


## Камп использует, чтобы понять «занята ли куча» — другие гномы её пропустят.
## Возвращает null, если гном не «привязан» к куче сейчас.
func get_assigned_pile() -> ResourcePile:
	if _state != State.COMMUTING_TO_PILE and _state != State.COMMUTING_TO_BASE:
		return null
	if not is_instance_valid(_assigned_pile):
		return null
	return _assigned_pile


# --- Damageable / Pushable ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	HitFlash.flash(_mesh)
	if hp <= 0.0:
		_dying = true
		# Снимаем флаг цели заранее: queue_free отрабатывает только в конце кадра,
		# и без этого скелет ещё успел бы взять умирающего гнома в целеуказание
		# в текущем тике (get_nodes_in_group видит queued-инстансы до фактической смерти).
		remove_from_group(SKELETON_TARGET_GROUP)
		# Прячем тело и спавним фрагменты — те живут в _effects_root, переживают
		# queue_free самого гнома (queue_free ниже прибьёт его в конце кадра).
		if _mesh:
			_mesh.visible = false
		if _effects_root:
			ShatterEffect.spawn(_effects_root, global_position, gnome_color,
				shatter_fragment_count, shatter_lifetime)
		destroyed.emit()
		queue_free()


## Pushable-контракт: knockback, на длительность которого AI отключён,
## и горизонтальная скорость затухает к нулю по knockback_friction.
func apply_push(velocity_change: Vector3, duration: float) -> void:
	if _state == State.IN_TENT:
		# В палатке — позиция приклеена, импульс не имеет смысла.
		return
	velocity = KnockbackState.compose(velocity, velocity_change)
	_knockback.start(duration)


# --- Цикл ---

func _physics_process(delta: float) -> void:
	if _camp == null:
		return

	if _state == State.IN_TENT:
		# Приклеены к палатке — позиция ведомая, физикой не трогаем.
		if is_instance_valid(_home_tent):
			global_position = _home_tent.global_position
		return

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	_knockback.tick(delta)
	if _knockback.is_active():
		# Под knockback'ом — AI заглушен, скорость затухает по trение-coeff.
		velocity = _knockback.apply_friction(velocity, delta)
	else:
		match _state:
			State.SEARCHING:
				_tick_searching()
			State.COMMUTING_TO_PILE:
				_tick_commuting_to_pile()
			State.COMMUTING_TO_BASE:
				_tick_commuting_to_base()
			State.IDLE_NEAR_BASE:
				_tick_idle_near_base()
			State.RETURNING_TO_TENT:
				_tick_returning()

	move_and_slide()


func _tick_searching() -> void:
	# Шаг 1: глаза — ближайшая НЕ занятая другим гномом куча в vision_radius.
	var spotted := _scan_vision()
	if spotted:
		_assigned_pile = spotted
		_wander_target = Vector3.INF
		_state = State.COMMUTING_TO_PILE
		return

	# Шаг 2: в мире куч нет → ошиваемся возле базы.
	if not _world_has_any_pile():
		_wander_target = Vector3.INF
		_state = State.IDLE_NEAR_BASE
		return

	# Шаг 3: патруль — случайная точка в search_radius от anchor'а.
	var anchor := _camp.deploy_anchor
	if _wander_target == Vector3.INF or _horizontal_distance(_wander_target) < wander_arrival:
		_wander_target = _random_point_around(anchor, search_radius)
	_move_toward_xz(_wander_target)


func _tick_commuting_to_pile() -> void:
	# freeze=true → кучу схватила рука, take_one провалится; не топчем зря.
	if not is_instance_valid(_assigned_pile) or _assigned_pile.units <= 0 or _assigned_pile.freeze:
		_on_pile_lost()
		return
	var pile_pos := _assigned_pile.global_position
	_move_toward_xz(pile_pos)
	if _horizontal_distance(pile_pos) <= pickup_distance:
		if _assigned_pile.take_one():
			_pickup_carry()
			_state = State.COMMUTING_TO_BASE
		else:
			# take_one() провалился — кучу выбили в этом же кадре.
			_on_pile_lost()


func _tick_commuting_to_base() -> void:
	var anchor := _camp.deploy_anchor
	_move_toward_xz(anchor)
	if _horizontal_distance(anchor) <= deposit_distance:
		_drop_carry()
		# Челнок: если pile ещё валиден — снова к нему. Иначе — решаем по миру.
		if is_instance_valid(_assigned_pile) and _assigned_pile.units > 0:
			_state = State.COMMUTING_TO_PILE
		else:
			_on_pile_lost()


func _tick_idle_near_base() -> void:
	# Пока в idle — не сканируем кучи. Камп вернёт нас в SEARCHING при следующей
	# развёртке, либо появление куч нас не разбудит до этого момента — это ок,
	# на текущей итерации куч на карте больше не появляется.
	var anchor := _camp.deploy_anchor
	if _wander_target == Vector3.INF or _horizontal_distance(_wander_target) < wander_arrival:
		_wander_target = _random_point_around(anchor, idle_radius)
	_move_toward_xz(_wander_target)


func _tick_returning() -> void:
	if not is_instance_valid(_home_tent):
		# Палатка пропала — фиксируем дома там, где стоим, чистим состояние.
		_enter_in_tent()
		return
	var tent_pos := _home_tent.global_position
	_move_toward_xz(tent_pos)
	if _horizontal_distance(tent_pos) <= home_distance:
		_enter_in_tent()


# --- Helpers ---

func _enter_in_tent() -> void:
	_state = State.IN_TENT
	_assigned_pile = null
	_wander_target = Vector3.INF
	_drop_carry()
	visible = false
	velocity = Vector3.ZERO
	# Скрыт в палатке — снимаем «целеустойчивость» для скелетов.
	remove_from_group(SKELETON_TARGET_GROUP)


## Куча, которую мы вели, исчезла или опустела. Просто перевод в SEARCHING —
## следующий кадр сам решит (память / глаза / патруль / idle).
func _on_pile_lost() -> void:
	_assigned_pile = null
	_wander_target = Vector3.INF
	_state = State.SEARCHING


func _move_toward_xz(target: Vector3) -> void:
	var to_target := target - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir := to_target.normalized()
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed


func _horizontal_distance(target: Vector3) -> float:
	var d := target - global_position
	d.y = 0.0
	return d.length()


## «Глаза» гнома — ближайшая куча в vision_radius от текущей позиции.
## Пропускает: пустые кучи, кучи в чужой клейм, замороженные (рука держит).
func _scan_vision() -> ResourcePile:
	var nearest: ResourcePile = null
	var nearest_dist := INF
	for pile in get_tree().get_nodes_in_group(ResourcePile.GROUP):
		if not is_instance_valid(pile):
			continue
		var rp := pile as ResourcePile
		if rp == null or rp.units <= 0 or rp.freeze:
			continue
		if _camp.is_pile_claimed(rp, self):
			continue
		var d := global_position.distance_to(rp.global_position)
		if d > vision_radius:
			continue
		if d < nearest_dist:
			nearest_dist = d
			nearest = rp
	return nearest


## Анти-livelock: есть ли в мире хоть одна куча с units > 0. Используется
## только чтобы перевести гнома в IDLE, когда патрулировать бесполезно.
func _world_has_any_pile() -> bool:
	for pile in get_tree().get_nodes_in_group(ResourcePile.GROUP):
		if not is_instance_valid(pile):
			continue
		var rp := pile as ResourcePile
		if rp and rp.units > 0:
			return true
	return false


func _random_point_around(center: Vector3, radius: float) -> Vector3:
	var angle := randf() * TAU
	var dist := radius * sqrt(randf())  # uniform в круге, не в кольце
	var p := Vector3(
		center.x + cos(angle) * dist,
		center.y,
		center.z + sin(angle) * dist
	)
	# При search_radius=300 и карте ±95 точка часто уходит за пол. Клампим, чтобы
	# гном не патрулировал в пустоте (и не проваливался при будущих обрывах).
	p.x = clampf(p.x, -wander_map_half_extent, wander_map_half_extent)
	p.z = clampf(p.z, -wander_map_half_extent, wander_map_half_extent)
	return p


func _pickup_carry() -> void:
	if _carry_visual:
		return
	_carry_visual = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = carry_visual_size
	_carry_visual.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = carry_color
	_carry_visual.material_override = mat
	_carry_visual.position = Vector3(0, 1.0, 0)  # над головой гнома
	add_child(_carry_visual)


func _drop_carry() -> void:
	if _carry_visual:
		_carry_visual.queue_free()
		_carry_visual = null
