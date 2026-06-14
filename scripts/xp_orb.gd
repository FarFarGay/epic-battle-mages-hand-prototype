class_name XpOrb
extends Node3D
## Орб со смерти скелета. Лежит на земле, на касании союзника (Tower / CampPart /
## гном-собиратель) активируется магнит — летит к `Camp.deploy_anchor`, на arrival
## пополняет МАНУ башни (`Tower.restore_mana`, топливо для кастов) и исчезает.
## XP отряда орб БОЛЬШЕ НЕ даёт — оно начисляется напрямую за убийство в
## `Camp._on_enemy_killed`, независимо от сбора орбов. (Имя класса/группы — легаси.)
##
## Архитектура «один путь»:
##   - Все скелеты дропают орб через `XpOrbSpawner` (autoload, слушает
##     `EventBus.enemy_destroyed`).
##   - Орб stateless по отношению к стрелку — кредит идёт лагерю целиком,
##     не отдельному защитнику. Тот, кто коснулся, определяет КУДА орб летит.
##   - Защитник может кoснуться орба своим патрулём, гном-собиратель — через
##     активный поиск (`Gnome._scan_orbs` → `COMMUTING_TO_ORB`), Tower и
##     палатка — пассивно проезжая мимо.
##
## Lifetime fallback: если за 60с никто не коснулся (далеко от каравана,
## гномы не дошли) — queue_free без кредита. Иначе уцелевшие дальние орбы
## накапливались бы пачками после стресс-волн.

signal collected(amount: int, world_position: Vector3)

const GROUP := &"xp_orb"

@export_group("Stats")
## Сколько XP добавится в `Camp._squad_xp` на arrival. Дефолт 10 совпадает с
## прежним `Camp.squad_xp_per_kill`.
@export var amount: int = 10
## Сколько маны вернётся башне на arrival (сбор орба = топливо для кастов). При
## дорогой мане (медленный реген) убийство скелетов «кормит» выстрелы. 0 = выкл.
@export var mana_amount: float = 5.0
## Сколько секунд орб лежит, прежде чем самоуничтожиться. Без таймаута дальние
## неподобранные орбы накапливались бы — на 200 скелетов / волну = 200 нодов.
@export var lifetime: float = 60.0

@export_group("Magnet")
## Скорость движения к anchor'у в MAGNETIZED-фазе. Выше Tower=8 — орб догоняет
## караван, даже если тот уже отъехал от точки касания.
@export var magnet_speed: float = 12.0
## Дистанция до anchor'а, на которой орб «прибыл» и зачисляется. Меньше
## arrival_distance = риск проскочить за один тик при magnet_speed=12.
@export var arrival_distance: float = 0.5
## Радиус «области сбора» вокруг каждого солдата отряда. Симметрично
## tower-зоне ([Camp.gather_radius]): орб в этом радиусе от живого
## солдата авто-магнитится. Запитан в том же polling-цикле, что и
## tower-зона ([_try_auto_magnetize_in_gather_zone]). Дефолт 3м —
## ширина типичной формации копейщиков ~5-7м с буфером.
@export var soldier_pickup_radius: float = 3.0
## Радиус «вакуума» вокруг башни, когда в сцене НЕТ развёрнутого лагеря (room-режим:
## башня сама собирает орбы — топливо для кастов). С лагерем орбы маршрутизирует он,
## этот фоллбэк молчит. 0 = выкл.
@export var tower_gather_radius: float = 6.0

@export_group("Idle visual")
## Амплитуда вертикального покачивания в IDLE — даёт орбу «жизнь», глаз
## цепляется за движение в траве.
@export var bobbing_amplitude: float = 0.15
@export var bobbing_speed: float = 2.0

@export_group("")
@export var debug_log: bool = true

enum State { IDLE, MAGNETIZED }

## Шейр'нутый материал — все орбы рисуются одним и тем же золотым emissive'ом,
## GPU батчит draw calls. Не дублируем .duplicate() per-instance.
static var _shared_material: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _magnet_area: Area3D = $MagnetArea

var _state: State = State.IDLE
var _life_elapsed: float = 0.0
## Фаза bobbing'а: рандом per-инстанс — пачка орбов от одной волны не качается
## синхронно, выглядит естественно.
var _bob_phase: float = 0.0
## Базовая Y-координата (точка спавна) — bobbing колеблется относительно неё.
## Также используется как Y магнитного полёта: target_y = _base_y, чтобы орб
## летел строго горизонтально и не нырял в anchor-точку (которая на полу).
var _base_y: float = 0.0
## Camp-получатель кредита XP на arrival. None = ещё в IDLE или орб собирается
## напрямую башней (room-режим без лагеря).
var _camp_target: Camp = null
## Башня-получатель маны на arrival. Резолвится из Camp (camp.get_tower()) или
## напрямую (tower-фоллбэк). Mana всегда идёт сюда. None = ещё в IDLE.
var _tower: Node = null
## Что физически преследовать в MAGNETIZED-фазе. Harvester внутри build_radius
## лагеря, Tower вне (она движется, орб догоняет). Решается в _activate_magnet
## по позиции орба и не пересчитывается каждый тик — иначе при пересечении
## границы build_radius орб резко менял бы цель в полёте.
var _magnet_target_node: Node3D = null

## Период авто-проверки попадания в зону добычи лагеря. Если орб в IDLE и
## расстояние до развёрнутого Camp.deploy_anchor ≤ Camp.gather_radius —
## автомагнит, без необходимости касания союзника. 0.2с (5Hz) дёшево даже
## на 100+ орбах после стресс-волны (200×5 = 1000 distance²/с на N лагерей).
const GATHER_SCAN_INTERVAL: float = 0.2
var _gather_scan_timer: float = 0.0


## Орб ещё лежит и ждёт касания. `Gnome._scan_orb` использует это, чтобы
## не выбирать целью орб, который уже улетает к Camp'у (тогда побежал бы
## впустую — другой союзник его подобрал первым).
func is_idle() -> bool:
	return _state == State.IDLE


func _ready() -> void:
	add_to_group(GROUP)
	_ensure_shared_material()
	if _mesh != null and _shared_material != null:
		_mesh.material_override = _shared_material
	_base_y = global_position.y
	_bob_phase = randf() * TAU
	_magnet_area.body_entered.connect(_on_body_entered)
	if debug_log and LogConfig.master_enabled:
		print("[XpOrb:%s] ready: pos=(%.2f, %.2f, %.2f), base_y=%.2f, amount=%d" % [
			name, global_position.x, global_position.y, global_position.z, _base_y, amount,
		])


static func _ensure_shared_material() -> void:
	if _shared_material != null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.2)
	mat.emission_energy_multiplier = 1.5
	_shared_material = mat


func _physics_process(delta: float) -> void:
	_life_elapsed += delta
	if _life_elapsed >= lifetime:
		if debug_log and LogConfig.master_enabled:
			print("[XpOrb:%s] expired (lifetime=%.0fс) at pos=(%.2f, %.2f, %.2f), state=%s" % [
				name, lifetime, global_position.x, global_position.y, global_position.z,
				"IDLE" if _state == State.IDLE else "MAGNETIZED",
			])
		queue_free()
		return
	match _state:
		State.IDLE:
			# Bobbing вокруг _base_y. Не трогаем X/Z — лежит на месте.
			global_position.y = _base_y + sin(_life_elapsed * bobbing_speed + _bob_phase) * bobbing_amplitude
			# Авто-магнит: если орб лежит в зоне добычи развёрнутого лагеря —
			# летит к нему сам, без касания союзника. Throttled.
			_gather_scan_timer -= delta
			if _gather_scan_timer <= 0.0:
				_gather_scan_timer = GATHER_SCAN_INTERVAL
				_try_auto_magnetize_in_gather_zone()
		State.MAGNETIZED:
			_tick_magnetized(delta)


func _tick_magnetized(delta: float) -> void:
	if _magnet_target_node == null or not is_instance_valid(_magnet_target_node):
		# Цель полёта (Harvester или Tower) исчезла — орб теряет ориентир.
		# Кредит без полёта не выдаём, чтобы XP визуально совпадал с прибытием.
		queue_free()
		return
	# Целимся в X/Z позиции магнит-цели (Harvester в DEPLOYED-зоне или Tower
	# снаружи), но Y держим равной `_base_y` — высоте рождения орба. Это даёт
	# горизонтальный полёт без ныряний. Tower движется → target_pos считается
	# каждый тик (орб её преследует).
	var attract: Vector3 = _magnet_target_node.global_position
	var target_pos := Vector3(attract.x, _base_y, attract.z)
	var to_target: Vector3 = target_pos - global_position
	var dist: float = to_target.length()
	if dist <= arrival_distance:
		if debug_log and LogConfig.master_enabled:
			print("[XpOrb:%s] arrival: pos=(%.2f, %.2f, %.2f), target=%s @(%.2f, %.2f, %.2f), +%d xp" % [
				name, global_position.x, global_position.y, global_position.z,
				_magnet_target_node.name, attract.x, attract.y, attract.z, amount,
			])
		# XP отряда теперь начисляется напрямую за убийство (Camp._on_enemy_killed),
		# НЕ через сбор орба. Орб даёт только ману — топливо для кастов.
		_grant_mana()
		collected.emit(amount, global_position)
		queue_free()
		return
	var step: float = magnet_speed * delta
	if step >= dist:
		# Этот шаг доедет до цели — телепортируемся, чтобы не проскочить.
		global_position = target_pos
		return
	global_position += to_target / dist * step


## Пополняет ману башни на сбор орба (топливо для кастов при дорогой мане).
## Башню берём через Camp-получателя; орб мог лететь к Harvester'у, но мана —
## всегда игроку (башне). Наличие метода проверяем (duck-typing, без связки).
func _grant_mana() -> void:
	if mana_amount <= 0.0:
		return
	if _tower != null and is_instance_valid(_tower) and _tower.has_method("restore_mana"):
		_tower.restore_mana(mana_amount)


## Polling-сканер автомагнита: проверяет, попадает ли орб в чью-то «область
## сбора». Два источника, проверяются в порядке убывающей дальности:
##  1. **Tower-зона**: орб в радиусе [Camp.gather_radius] от deploy_anchor
##     развёрнутого лагеря. Дизайн 2026-05-16 — своя территория = свой XP.
##  2. **Soldier-зона**: орб в радиусе [soldier_pickup_radius] от любого живого
##     солдата. Симметрично tower-зоне — отряд «всасывает» XP по ходу боя,
##     не нужно вести юнита прямо по орбу.
##
## Дополнение к body_entered (магнит на физическое касание). Раз нашли —
## return, орб уже в MAGNETIZED.
func _try_auto_magnetize_in_gather_zone() -> void:
	for c in get_tree().get_nodes_in_group(Camp.CAMP_GROUP):
		if not is_instance_valid(c):
			continue
		var camp := c as Camp
		if camp == null:
			continue
		# Только развёрнутый лагерь имеет осмысленный anchor. В каравне
		# _deploy_anchor = ZERO (или старое значение от прошлого деплоя),
		# зона добычи неактивна.
		if not camp.is_deployed():
			continue
		var anchor: Vector3 = camp.deploy_anchor
		var dx: float = global_position.x - anchor.x
		var dz: float = global_position.z - anchor.z
		var r: float = camp.gather_radius
		if dx * dx + dz * dz <= r * r:
			_activate_magnet(camp)
			return
	var sr_sq: float = soldier_pickup_radius * soldier_pickup_radius
	for s in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		if not is_instance_valid(s):
			continue
		var soldier := s as SoldierGnome
		if soldier == null:
			continue
		var dx: float = global_position.x - soldier.global_position.x
		var dz: float = global_position.z - soldier.global_position.z
		if dx * dx + dz * dz > sr_sq:
			continue
		var camp := soldier.get_camp()
		if camp == null:
			continue
		_activate_magnet(camp)
		return
	# Фоллбэк без развёрнутого лагеря: башня сама «вакуумит» орбы в своём радиусе.
	# С лагерем не срабатывает — он владеет маршрутизацией (см. ранние ветки).
	if tower_gather_radius > 0.0 and not _any_deployed_camp():
		var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
		if tower != null:
			var dxt: float = global_position.x - tower.global_position.x
			var dzt: float = global_position.z - tower.global_position.z
			if dxt * dxt + dzt * dzt <= tower_gather_radius * tower_gather_radius:
				_activate_magnet_to_tower(tower)


## Касание союзника — активируем магнит. Идемпотентно: повторное касание в
## MAGNETIZED-фазе игнорируется (мы уже летим).
func _on_body_entered(body: Node) -> void:
	if _state != State.IDLE:
		return
	var camp := _resolve_camp_from(body)
	if camp != null:
		_activate_magnet(camp)
		return
	# Нет лагеря, но коснулась башня — магнитимся прямо к ней (room-режим).
	if body.is_in_group(Tower.GROUP):
		_activate_magnet_to_tower(body)


## Найти Camp-владельца коснувшегося тела. Tower/CampPart/Gnome — три
## случая. Tower не хранит ссылку на Camp напрямую — итерируем группу
## `camp` (1-2 инстанса на карте, дёшево).
func _resolve_camp_from(body: Node) -> Camp:
	if body.is_in_group(Gnome.GNOME_GROUP):
		return (body as Gnome).get_camp()
	if body is CampPart:
		return body.get_parent() as Camp
	# Tower-ветка: единственный кейс, когда нужно искать Camp по ссылке.
	for c in get_tree().get_nodes_in_group(Camp.CAMP_GROUP):
		if not is_instance_valid(c):
			continue
		var camp := c as Camp
		if camp == null:
			continue
		if camp.get_tower() == body:
			return camp
	return null


## Магнит прямо к башне (без лагеря, room-режим): летим к башне, на arrival — мана.
func _activate_magnet_to_tower(tower: Node) -> void:
	var t := tower as Node3D
	if t == null:
		return
	_camp_target = null
	_tower = tower
	_magnet_target_node = t
	_state = State.MAGNETIZED
	_magnet_area.set_deferred("monitoring", false)


## True если в сцене есть хоть один развёрнутый лагерь — тогда он владеет орбами,
## а tower-фоллбэк молчит (чтобы не дублировать маршрутизацию).
func _any_deployed_camp() -> bool:
	for c in get_tree().get_nodes_in_group(Camp.CAMP_GROUP):
		var camp := c as Camp
		if camp != null and is_instance_valid(camp) and camp.is_deployed():
			return true
	return false


func _activate_magnet(camp: Camp) -> void:
	_camp_target = camp
	_tower = camp.get_tower()
	_magnet_target_node = camp.get_xp_magnet_target(global_position)
	if _magnet_target_node == null:
		# Ни Harvester, ни Tower не доступны как цель — орб некуда лететь.
		# Лучше queue_free, чем висеть в MAGNETIZED с null-target и сразу
		# само-удаляться в _tick_magnetized.
		queue_free()
		return
	_state = State.MAGNETIZED
	# Снимаем Area3D.monitoring — больше не интересны новые касания.
	# Лишнее body_entered в полёте к anchor'у только зря тратит physics-call'ы.
	# `set_deferred`, не прямое присваивание: мы внутри обработчика body_entered
	# (Godot вызвал нас из in/out signal'а), и менять `monitoring` напрямую
	# во время этой фазы запрещено — спамит ошибкой каждый кадр магнита.
	_magnet_area.set_deferred("monitoring", false)
	if debug_log and LogConfig.master_enabled:
		var t_pos: Vector3 = _magnet_target_node.global_position
		print("[XpOrb:%s] magnet activated: pos=(%.2f, %.2f, %.2f), target=%s xz=(%.2f, %.2f), target_y=%.2f (=base_y)" % [
			name, global_position.x, global_position.y, global_position.z,
			_magnet_target_node.name, t_pos.x, t_pos.z, _base_y,
		])
