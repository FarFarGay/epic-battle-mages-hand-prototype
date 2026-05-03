class_name Camp
extends Node3D
## Лагерь — модуль каравана+развёртки. Цепочка палаток-RigidBody3D
## (frozen=true в норме — Camp двигает их через global_position) следует за
## башней (CARAVAN_FOLLOWING) и по hold-инпуту разворачивается в кольцо
## вокруг точки остановки башни (DEPLOYED). На физический удар (Slam, Flick,
## магия) палатка снимается с freeze, эмиттит CampPart.is_torn_off=true,
## Camp пропускает её в follow-логике — она физически летает и кувыркается.
##
## Состояния:
## - CARAVAN_FOLLOWING — палатки тянутся «змейкой» за башней. Hold R с условием
##   «башня стоит» ≥ deploy_duration разворачивает лагерь.
## - DEPLOYED — палатки lerp'ом смещаются на точки кольца радиуса deploy_radius
##   вокруг _deploy_anchor. Hold R ≥ pack_duration сворачивает (без
##   stationary-проверки).
##
## Коллизии: палатки всегда на слое CampObstacle (6, бит 5). Tower.mask=31
## не включает этот бит → башня проходит сквозь палатки в любом состоянии.
## Skeleton.mask=55 включает его → скелеты упираются в палатки и в каравне,
## и в развёрнутом лагере. Никакого рантайм-toggle коллизии нет.
##
## Зависит только от Tower через target_path. Локальные сигналы deployed/packed
## ре-эмитятся в EventBus для UI / звука / статистики.
##
signal deployed(anchor: Vector3)
signal packed

## CARAVAN_FOLLOWING — палатки тянутся за башней, гномы IN_TENT.
## DEPLOYED — палатки в кольце вокруг anchor'а, гномы бродят и собирают ресурсы.
## PACKING_RETURNING — пользователь начал свёртку, гномы возвращаются в палатки;
##                     сами палатки пока не двигаются — ждут гномов. Когда все
##                     гномы IN_TENT — переход в CARAVAN_FOLLOWING.
enum State { CARAVAN_FOLLOWING, DEPLOYED, PACKING_RETURNING }

@export_node_path("Node3D") var target_path: NodePath

@export_group("Caravan composition")
## Сцена палатки — будет инстанцироваться по tent_count раз в _ready.
## Каждая палатка самостоятельная сущность (Tent.tscn + camp_part.gd):
## Damageable, может быть уничтожена, имеет свой shatter-эффект на смерть.
@export var tent_scene: PackedScene
## Сколько палаток в караване. Меняется в инспекторе — спавнится при старте.
## Можно ставить любое разумное количество; layout цепочки автоматически
## распределится через part_gap. На развёртку угол кольца считается как
## TAU / tent_count, так что любое число работает.
@export var tent_count: int = 4
## «Уже развёрнутый» лагерь: на _ready стартуем сразу в DEPLOYED-состоянии,
## anchor = собственная global_position (не нужна башня). Палатки сразу
## едут в кольцо вокруг лагеря, гномы выходят бродить и собирать.
## R-toggle отключён — такой лагерь не сворачивается. Используется для
## статических поселений на POI (карта-локация без следования за башней).
@export var start_deployed: bool = false
@export_group("")

## Группа целей для скелетов (см. Skeleton.TARGET_GROUP). Camp ставит/убирает
## tower в эту группу в зависимости от состояния: в каравне tower уязвим
## для агро, в развёрнутом лагере — нет (скелеты переключаются на палатки
## и гномов вокруг костра).
const SKELETON_TARGET_GROUP := &"skeleton_target"


@export_group("POI deploy gate")
## Если true — деплой возможен ТОЛЬКО когда башня в радиусе safe_radius
## хотя бы одной POI-зоны (см. [QuestActor.safe_radius] и группу `poi_zone`).
## Hold R вне POI игнорируется (счётчик _deploy_hold не накапливается).
## Anchor лагеря защёлкивается на позицию POI, а не на текущую позицию
## башни — палатки кольцом строятся симметрично вокруг костра.
##
## Геймдизайнерская идея: POI = костёр = единственное место «осесть».
## Между POI караван едет, защитники в палатках, никаких атак волной —
## фоновые скелеты могут увидеть и накинуться, но это редкие стычки.
##
## false — старое поведение (deploy где угодно, anchor=tower.position).
## Полезно для отладки и потенциально для «лагерь без POI» режимов.
@export var require_poi: bool = true
@export_group("")

## Decay-коэффициент (log-rate) экспоненциального следования палаток.
## Чем выше — тем быстрее палатка догоняет точку-цель. Не зависит от dt.
@export var follow_speed: float = 4.0
## Расстояние между палатками в цепочке и между башней и parts[0].
@export var part_gap: float = 2.5
## За этим порогом ведущая палатка перестаёт двигаться (башня «ушла далеко»).
@export var follow_max_distance: float = 30.0
## Радиус «зоны каравана» — куда игрок может рукой вернуть палатку в строй.
## В CARAVAN_FOLLOWING зона измеряется от башни, в DEPLOYED — от _deploy_anchor.
## Если игрок аккуратно (тихий release) поставил палатку В этой зоне →
## Camp пересортирует _parts по позиции и втянет её в строй. Если ВНЕ зоны →
## palatка просто стоит на месте, Camp её не таскает (но и гномы IN_TENT
## остаются в ней — никого не убивает). Чтобы вернуть палатку в строй,
## её надо подобрать ещё раз и поставить ближе чем placement_zone_radius.
@export var placement_zone_radius: float = 15.0
## Секунды зажатой R + неподвижности башни для развёртки.
@export var deploy_duration: float = 3.0
## Секунды зажатой R для свёртки (stationary не требуется).
@export var pack_duration: float = 4.0
## Таймаут после _start_pack: если за это время не все гномы дошли домой
## (застряли вне reach'а, ушли далеко, рука держит их с RETURNING_TO_TENT
## пропуская _tick_returning, и т.п.) — форсированно завершаем свёртку.
## Без таймаута Camp залипал в PACKING_RETURNING вечно: один зависший гном
## (например, упавший с обрыва или застрявший в коллизии скелета)
## блокировал весь караван от движения.
@export var pack_timeout: float = 12.0
## Радиус кольца, на которое расставляются палатки вокруг anchor.
@export var deploy_radius: float = 8.0
## Порог смещения цели за кадр, ниже которого считаем её неподвижной.
@export var stationary_threshold: float = 0.01

@export_group("Gnomes")
## Сцена обычного гнома-собирателя. Спавнится на каждую палатку
## (gnomes_per_tent − defenders_per_tent) раз — это «жители-собиратели»,
## ищут ResourcePile и носят к anchor лагеря.
@export var gnome_scene: PackedScene
## Сцена защитника-лучника (DefenderGnome). Спавнится на каждую палатку
## defenders_per_tent раз — стоят у лагеря и стреляют в скелетов.
## Если null — защитники не спавнятся, на их слоты подставятся обычные гномы.
@export var defender_scene: PackedScene

@export_group("")
@export var debug_log: bool = true

var _tower: Node3D
var _state: State = State.CARAVAN_FOLLOWING
## Палатки каравана. Тип Node3D (а не RigidBody3D), потому что после tear-off
## (apply_push на CampPart) палатка остаётся в массиве несколько кадров до
## фактического `_remove_torn_part` — но сама follow-логика её уже пропускает
## через `(part as CampPart).is_torn_off()`. Также удобнее, если когда-то
## появятся не-RB палатки.
var _parts: Array[Node3D] = []
## Таймер удержания R в CARAVAN_FOLLOWING (для развёртки).
var _deploy_hold: float = 0.0
## Таймер удержания R в DEPLOYED (для свёртки).
var _pack_hold: float = 0.0
var _deploy_anchor: Vector3 = Vector3.ZERO
var _deployed_targets: Array[Vector3] = []
## Часы PACKING_RETURNING: тикают с момента _start_pack. По достижении
## pack_timeout — _finalize_pack принудительно, даже если кто-то не дома.
var _pack_elapsed: float = 0.0
## Позиция башни на прошлом кадре — для эпсилон-чека неподвижности.
var _last_target_pos: Vector3 = Vector3.INF
## Гномы лагеря — gnomes_per_tent × количество палаток. Создаются в _ready.
var _gnomes: Array[Gnome] = []
## Центральный mount-slot для модулей (turret и т. д.). В фазе CARAVAN он
## выключен и невидим — «центра лагеря» не существует. На развёртке слот
## переезжает в anchor и активируется; на свёртке — выключается, что
## размонтирует всё что на нём стояло (модуль остаётся лежать на земле).
@onready var _center_slot: MountSlot = $CenterMountSlot if has_node("CenterMountSlot") else null

## Публичный геттер anchor'а — гномы читают, чтобы знать, куда нести ресурс.
var deploy_anchor: Vector3:
	get:
		return _deploy_anchor

# Логирование (фронт-триггеры, чтобы не спамить каждый кадр).
var _was_holding_stationary: bool = false
var _was_out_of_range: bool = false


func _ready() -> void:
	if not target_path.is_empty():
		_tower = get_node_or_null(target_path) as Node3D
	if not _tower and not start_deployed:
		push_warning("Camp: target_path не разрешился, башня не задана")

	_spawn_tents()
	_spawn_gnomes()

	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	deployed.connect(func(anchor: Vector3) -> void: EventBus.camp_deployed.emit(anchor))
	packed.connect(func() -> void: EventBus.camp_packed.emit())

	# Башня может погибнуть — обнуляем ссылку, чтобы караван не follow'ил мёртвый
	# (но всё ещё существующий статикой) Tower-меш. _update_caravan_follow и
	# stationary-чек уже null-safe, ничего больше делать не нужно.
	EventBus.tower_destroyed.connect(_on_tower_destroyed)

	# Static-режим: сразу стартуем в DEPLOYED. Anchor = собственная позиция
	# Camp (не башни, которой нет). Палатки переедут с линии (где их поставил
	# _spawn_tents) в кольцо вокруг anchor через _exp_decay в _update_deployed.
	if start_deployed:
		_start_deploy()
	else:
		# В каравне tower сам по себе является целью для скелетов: фоновые
		# wander-скелеты, увидев караван глазами, идут к башне и атакуют её.
		# Когда лагерь развернётся — _start_deploy уберёт tower из группы
		# (агро переключится на палатки), а на _finalize_pack — вернёт.
		_set_tower_aggro(true)
		# Палатки тоже атакуемы в каравне — скелеты, увидев караван глазами,
		# идут на ближайшую цель (tower или палатку). Раньше было «уязвимы
		# только в DEPLOYED», но геймдизайнер просил, чтобы караван был
		# полноценной целью: tower + палатки. Бронируются только в
		# PACKING_RETURNING (см. _start_pack).
		_set_parts_vulnerable(true)


## Спавнит палатки по tent_scene × tent_count. Линейная цепочка позади башни:
## первая в локальном (0,0,0), каждая следующая на part_gap метров левее по X.
## Y берётся из самой сцены палатки (Tent.tscn ставит её на пол через свой
## меш-размер; camp_part.set_vulnerable управляет уязвимостью).
##
## Каждая палатка — самостоятельный инстанс с собственным CampPart-скриптом.
## Подписываемся на destroyed, чтобы синхронно вычищать обе структуры
## (_parts и _deployed_targets) при гибели — иначе индексы сдвинутся
## и оставшиеся палатки в DEPLOYED поедут к чужим точкам кольца.
func _spawn_tents() -> void:
	if tent_scene == null:
		push_warning("Camp: tent_scene не задан — палатки не спавнятся")
		return
	if tent_count <= 0:
		return
	# Стартовая привязка цепочки: за башней (если есть), иначе у самого Camp.
	# Раньше tent[0] ставился в локальном (0,0,0) и подтягивался к башне через
	# exp_decay — на разнесённых Camp/Tower палатки на первом кадре сидели в
	# центре и потом «уезжали» к башне. Сразу строим конечную цепочку.
	var leader_xz: Vector3 = _tower.global_position if _tower != null else global_position
	for i in range(tent_count):
		# Tent — RigidBody3D с freeze=true (после смены StaticBody → RB на 2026-05-03):
		# на freeze палатка ведёт себя как кинематическое тело, Camp двигает её
		# через global_position. На apply_push freeze снимается, палатка летит.
		var tent := tent_scene.instantiate() as Node3D
		if tent == null:
			push_warning("Camp: tent_scene не инстанцируется как Node3D")
			continue
		tent.name = "Tent%d" % (i + 1)
		add_child(tent)
		# Цепочка позади башни вдоль -X: tent[0] на part_gap позади башни,
		# каждая следующая ещё на part_gap дальше. Y оставляем тот, что задал
		# tent.tscn (там transform.y=0.75 — половина высоты, чтобы стояла на полу).
		tent.global_position = Vector3(
			leader_xz.x - float(i + 1) * part_gap,
			tent.global_position.y,
			leader_xz.z,
		)
		_parts.append(tent)
		if tent is CampPart:
			(tent as CampPart).destroyed.connect(_on_part_destroyed.bind(tent))


func _spawn_gnomes() -> void:
	if gnome_scene == null and defender_scene == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp] ни gnome_scene, ни defender_scene не заданы — никого не спавним")
		return
	for tent in _parts:
		if not (tent is CampPart):
			continue
		var part := tent as CampPart
		var total: int = part.gnomes_per_tent
		# defenders_per_tent клампим до total — защитников не больше жителей.
		var defender_count: int = clampi(part.defenders_per_tent, 0, total)
		var gatherer_count: int = total - defender_count
		# Сначала защитники (если их сцена задана), потом собиратели.
		# Каждый получает позицию палатки + setup(camp, tent) — гном привязан
		# именно к этой палатке (RETURNING_TO_TENT идёт сюда же).
		for i in range(defender_count):
			_spawn_one_gnome(defender_scene, tent, "defender")
		for i in range(gatherer_count):
			_spawn_one_gnome(gnome_scene, tent, "gatherer")


## Инстанцирует одну сцену гнома, привязывает к палатке. Используется
## и для защитников (defender_scene), и для собирателей (gnome_scene).
## Если сцена null или не инстанцируется как Gnome — push_warning и пропуск.
func _spawn_one_gnome(scene: PackedScene, tent: Node3D, role: String) -> void:
	if scene == null:
		push_warning("Camp: сцена для роли '%s' не задана — пропуск" % role)
		return
	var gnome := scene.instantiate() as Gnome
	if gnome == null:
		push_warning("Camp: сцена для роли '%s' не инстанцируется как Gnome" % role)
		return
	add_child(gnome)
	gnome.global_position = tent.global_position
	gnome.setup(self, tent)
	# Скелет может убить гнома — выкидываем из _gnomes, иначе claim-чек
	# и _all_gnomes_home будут спотыкаться об invalid-инстансы.
	gnome.destroyed.connect(_on_gnome_destroyed.bind(gnome))
	_gnomes.append(gnome)


## Публичный геттер списка гномов лагеря. CampPart использует, чтобы найти
## своих жильцов IN_TENT при tear-off (eject + damage). Возвращает internal
## ссылку — caller'ы должны не мутировать массив, только итерировать.
func get_gnomes() -> Array[Gnome]:
	return _gnomes


## Публичный геттер ссылки на башню. Бездомные гномы (FOLLOWING_CARAVAN) идут
## за ней. Может быть null если target_path не разрешился или Tower уничтожена.
func get_tower() -> Node3D:
	return _tower


## Уведомление от CampPart, что её только что аккуратно поставили рукой
## (тихий release без impulse). Camp проверяет distance до leader'а:
## - В зоне → reorder _parts по позиции, палатка встаёт в новый слот строя.
##   Зону проверяем ОДНОКРАТНО здесь, не каждый кадр в follow — иначе
##   палатка, попавшая по краю зоны, могла бы выпасть из строя через секунду
##   когда строй растянется (баг 2026-05-04: «выбивает четвёртую»).
## - Вне зоны → mark_outside_caravan на палатке. Camp.follow её пропускает
##   до следующего pickup (тогда _outside_caravan сбрасывается).
func notify_part_settled(part: CampPart) -> void:
	var leader_pos := _leader_pos_for_zone()
	var zone_sq := placement_zone_radius * placement_zone_radius
	if (part.global_position - leader_pos).length_squared() > zone_sq:
		part.mark_outside_caravan()
		if debug_log and LogConfig.master_enabled:
			print("[Camp] %s оставлена вне зоны (dist > %.1f), стоит вне строя" % [part.name, placement_zone_radius])
		return
	_reorder_parts_by_position()


## Leader-позиция для зоны установки и follow-фильтра. CARAVAN — башня,
## DEPLOYED/PACKING — anchor.
func _leader_pos_for_zone() -> Vector3:
	if _state == State.CARAVAN_FOLLOWING and _tower != null:
		return _tower.global_position
	return _deploy_anchor


## Сортирует _parts по distance до leader'а. Палатки в строю (is_in_caravan)
## впереди, torn_off / outside_caravan — в конце (Camp их всё равно skip'ает
## в follow). _deployed_targets перестраиваются под новое количество
## активных палаток в DEPLOYED-режимах.
func _reorder_parts_by_position() -> void:
	var leader_pos: Vector3 = _leader_pos_for_zone()
	_parts.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var a_active := not (a is CampPart) or (a as CampPart).is_in_caravan()
		var b_active := not (b is CampPart) or (b as CampPart).is_in_caravan()
		if a_active != b_active:
			# Активные впереди (true перед false в sort_custom).
			return a_active
		return a.global_position.distance_squared_to(leader_pos) < b.global_position.distance_squared_to(leader_pos)
	)
	if _state == State.DEPLOYED or _state == State.PACKING_RETURNING:
		_rebuild_deployed_targets()


## Пересчитывает _deployed_targets[i] под текущий порядок _parts. Считаем
## количество активных (не torn_off) палаток как N, делим круг на N
## секторов и расставляем targets по углам. Torn_off палатки не получают
## target — они всё равно skip'аются в _update_deployed.
func _rebuild_deployed_targets() -> void:
	_deployed_targets.clear()
	var active_count := 0
	for part in _parts:
		if part is CampPart and not (part as CampPart).is_in_caravan():
			continue
		active_count += 1
	if active_count == 0:
		return
	var idx := 0
	for part in _parts:
		if part is CampPart and not (part as CampPart).is_in_caravan():
			# Placeholder — _update_deployed skip'ает по индексу, i должен
			# совпадать с _parts. Используем текущую позицию палатки.
			_deployed_targets.append(part.global_position)
			continue
		var angle := float(idx) * TAU / float(active_count)
		var part_y: float = part.global_position.y
		_deployed_targets.append(Vector3(
			_deploy_anchor.x + cos(angle) * deploy_radius,
			part_y,
			_deploy_anchor.z + sin(angle) * deploy_radius,
		))
		idx += 1


## Считает живых гномов-собирателей (исключая защитников). Используется HUD'ом.
func gatherer_count() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g is DefenderGnome:
			continue
		n += 1
	return n


## Считает живых гномов-защитников (DefenderGnome).
func defender_count() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g is DefenderGnome:
			n += 1
	return n


## Считает живые палатки. «Уровень лагеря» в HUD = это число.
func tent_count_alive() -> int:
	var n := 0
	for p in _parts:
		if is_instance_valid(p):
			n += 1
	return n


## Реальный центр лагеря для расчётов на стороне (например WaveDirector
## смотрит безопасную зону вокруг лагеря). global_position самого узла Camp
## **не двигается** когда игрок ведёт Tower — двигаются только дочерние
## палатки. Поэтому центр считаем как среднее живых палаток. Если палаток
## не осталось — fallback на tower.global_position (caravan следует за
## башней) или собственную позицию узла.
func current_center() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for part in _parts:
		if not is_instance_valid(part):
			continue
		sum += part.global_position
		n += 1
	if n > 0:
		return sum / float(n)
	if _tower != null:
		return _tower.global_position
	return global_position


## Ближайшая живая палатка к точке. WaveDirector использует для назначения
## aggro-цели волне: 10 скелетов получают forced_target = эту палатку.
## Возвращает null если все палатки разрушены — лагерь больше не валидная
## цель, и вся волна идёт мимо. Оторванные (torn_off) палатки не считаются
## легитимной целью каравана — волна идёт на стационарные палатки лагеря.
func nearest_part_to(pos: Vector3) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart and (part as CampPart).is_torn_off():
			continue
		var d_sq: float = (part.global_position - pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = part
	return nearest


## True если у лагеря есть хотя бы одна живая палатка — иначе он больше не
## валидная цель (все палатки разрушены).
func has_alive_parts() -> bool:
	for part in _parts:
		if is_instance_valid(part):
			return true
	return false


## Воскрешает гномов лагеря: вычищает оставшихся, заспавнивает новых на
## уцелевших палатках. Палатки не восстанавливаются — пользователь явно
## просил «воскресить гномов» (rebalance после волн); если палатка уже
## уничтожена, её жители безвозвратно потеряны вместе с ней. Используется
## WaveDirector'ом при рестарте кампании (P).
func reset_population() -> void:
	# Копия — _gnomes мутируется через _on_gnome_destroyed на queue_free.
	for gnome in _gnomes.duplicate():
		if is_instance_valid(gnome):
			gnome.queue_free()
	_gnomes.clear()
	_spawn_gnomes()
	# Если лагерь уже DEPLOYED — новые гномы должны выйти бродить, иначе
	# останутся IN_TENT и не будут собирать ресурсы / отстреливать скелетов.
	if _state == State.DEPLOYED:
		for g in _gnomes:
			if is_instance_valid(g):
				g.enter_deployed()
	if debug_log and LogConfig.master_enabled:
		print("[Camp] популяция сброшена (гномов: %d)" % _gnomes.size())


func _on_part_destroyed(part: Node3D) -> void:
	# Удаляем по индексу, чтобы синхронно обрезать _deployed_targets — иначе
	# после смерти палатки [i] оставшиеся палатки поедут к чужим точкам кольца
	# (каждая палатка читает _deployed_targets[i] по своему индексу в _parts).
	var idx := _parts.find(part)
	if idx == -1:
		return
	_parts.remove_at(idx)
	if idx < _deployed_targets.size():
		_deployed_targets.remove_at(idx)
	# Переназначаем сиротских гномов на ближайшую живую палатку. Без этого
	# гном с _home_tent → freed-инстансом застревает: при request_return
	# _tick_returning видит null tent и сразу _enter_in_tent на текущей
	# позиции (становится невидим где-то в поле), а в CARAVAN_FOLLOWING
	# IN_TENT-приклейка к null'у не работает — он не двигается с караваном.
	# Если живых палаток вообще не осталось — просто оставляем _home_tent=null,
	# гномы продолжают жить на местах (Camp всё равно невалиден для волн).
	_reassign_orphan_gnomes(part)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] палатка %s уничтожена (осталось: %d)" % [part.name, _parts.size()])


## Гномы, чей home_tent был только что разрушен, получают новую ближайшую
## живую палатку как home. Если живых палаток нет — гном переходит в
## FOLLOWING_CARAVAN (идёт за башней без дома). До этого orphan мог сидеть
## IN_TENT с freed-ссылкой и телепортироваться по последней позиции мёртвой
## палатки — теперь он явно «бездомный» с активным state.
func _reassign_orphan_gnomes(dead_tent: Node3D) -> void:
	var reassigned := 0
	var stranded := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.get_home_tent() != dead_tent:
			continue
		var new_home := _nearest_alive_tent_to(g.global_position)
		if new_home != null:
			g.set_home_tent(new_home)
			reassigned += 1
		else:
			# Живых палаток нет — становится бездомным, идёт за башней.
			# IN_TENT гномы тоже нужно «выпустить» — просто set state.
			g.enter_following_caravan()
			stranded += 1
	if (reassigned > 0 or stranded > 0) and debug_log and LogConfig.master_enabled:
		print("[Camp] осиротели после смерти %s: на новые палатки %d, бездомных %d" % [dead_tent.name, reassigned, stranded])


## Ближайшая живая палатка к точке. Используется при переназначении
## гномов-сирот после гибели их home_tent. Оторванные (torn_off) палатки
## пропускаются — переназначать сироту на летающую палатку бессмысленно.
func _nearest_alive_tent_to(pos: Vector3) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart and (part as CampPart).is_torn_off():
			continue
		var d_sq: float = (part.global_position - pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = part
	return nearest


func _on_gnome_destroyed(gnome: Gnome) -> void:
	_gnomes.erase(gnome)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] гном %s убит (осталось: %d)" % [gnome.name, _gnomes.size()])


func _on_tower_destroyed() -> void:
	if debug_log and LogConfig.master_enabled:
		print("[Camp] башня уничтожена — караван останавливается")
	# Башня умирает → больше не цель ни для кого. group-membership чистить
	# не обязательно (нода freed → вышла из всех групп автоматически), но
	# делаем явно на случай если EventBus.tower_destroyed эмитится перед
	# фактическим queue_free.
	_set_tower_aggro(false)
	_tower = null


## Управление tower-aggro для скелетов: tower уязвим (в группе skeleton_target)
## только в каравне. В DEPLOYED осада идёт на палатки/гномов вокруг костра,
## tower сам по себе не цель. После _finalize_pack возвращаем — караван снова
## в движении, фоновые скелеты могут аггриться через vision.
##
## Tower может быть null (target_path не задан, или _on_tower_destroyed уже
## обнулил) — тогда no-op. is_inside_tree-чек защищает от попытки добавить
## в группу ноду, которую только что freed (group API падает на freed-инстансе).
func _set_tower_aggro(active: bool) -> void:
	if _tower == null or not is_instance_valid(_tower):
		return
	if not _tower.is_inside_tree():
		return
	if active:
		if not _tower.is_in_group(SKELETON_TARGET_GROUP):
			_tower.add_to_group(SKELETON_TARGET_GROUP)
	else:
		if _tower.is_in_group(SKELETON_TARGET_GROUP):
			_tower.remove_from_group(SKELETON_TARGET_GROUP)


func _process(delta: float) -> void:
	_handle_input(delta)
	match _state:
		State.CARAVAN_FOLLOWING:
			_update_caravan_follow(delta)
		State.DEPLOYED:
			_update_deployed(delta)
		State.PACKING_RETURNING:
			# Палатки стоят на местах развёртки, гномы возвращаются.
			# Когда все дома — финализируем pack. Если кто-то завис (схвачен
			# рукой, застрял в коллизии, упал с обрыва) — таймаут спасает
			# караван от вечного простоя.
			_update_deployed(delta)
			_pack_elapsed += delta
			if _all_gnomes_home():
				_finalize_pack()
			elif _pack_elapsed >= pack_timeout:
				if debug_log and LogConfig.master_enabled:
					var stuck := _count_gnomes_not_home()
					print("[Camp] свёртка форсированно завершена (таймаут %.1fс, %d гномов не дома)" % [pack_timeout, stuck])
				_finalize_pack()
	if _tower != null:
		_last_target_pos = _tower.global_position


func _all_gnomes_home() -> bool:
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if not g.is_home():
			return false
	return true


## Считает живых гномов, которые ещё не дома. Используется в логе таймаута
## свёртки — без этого «застрял на N гномов» в логе не покажется.
func _count_gnomes_not_home() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if not g.is_home():
			n += 1
	return n


# --- Дележ куч между гномами ---

## True, если кучу уже нацелил какой-то гном (≠ exclude_gnome). Гном-сканер
## пропускает claimed-кучи, чтобы каждый нашёл «своё».
func is_pile_claimed(pile: ResourcePile, exclude_gnome: Gnome = null) -> bool:
	if not is_instance_valid(pile):
		return false
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g == exclude_gnome:
			continue
		if g.get_assigned_pile() == pile:
			return true
	return false


# --- Ввод / переходы состояний ---

func _handle_input(delta: float) -> void:
	# Static-camp (start_deployed=true) не реагирует на R — он не сворачивается.
	# Поселения на POI остаются развёрнутыми всю игру.
	if start_deployed:
		return
	if not Input.is_action_pressed("camp_toggle"):
		if _deploy_hold > 0.0 and debug_log and LogConfig.master_enabled and _was_holding_stationary:
			print("[Camp] отсчёт прерван (отпущена R)")
		_deploy_hold = 0.0
		_pack_hold = 0.0
		_was_holding_stationary = false
		return

	match _state:
		State.CARAVAN_FOLLOWING:
			# Стационарность башни — необходимое условие. POI-gate (если
			# require_poi=true) — второе. Оба должны быть true, чтобы
			# счётчик отсчёта развёртки тикал.
			var poi := _find_poi_for_deploy()
			var poi_ok: bool = (not require_poi) or (poi != null)
			if _is_tower_stationary() and poi_ok:
				if not _was_holding_stationary:
					if debug_log and LogConfig.master_enabled:
						if poi != null:
							print("[Camp] начат отсчёт развёртки (POI: %s)" % poi.name)
						else:
							print("[Camp] начат отсчёт развёртки")
					_was_holding_stationary = true
				_deploy_hold += delta
				if _deploy_hold >= deploy_duration:
					_start_deploy()
			else:
				if _was_holding_stationary and debug_log and LogConfig.master_enabled:
					if not _is_tower_stationary():
						print("[Camp] отсчёт прерван (башня поехала)")
					else:
						print("[Camp] отсчёт прерван (вышли из POI)")
				_deploy_hold = 0.0
				_was_holding_stationary = false
		State.DEPLOYED:
			_pack_hold += delta
			if _pack_hold >= pack_duration:
				_start_pack()
		State.PACKING_RETURNING:
			# Во время сбора отсчёт не накапливается — гномам нужно дойти.
			pass


func _is_tower_stationary() -> bool:
	if _tower == null:
		return false
	if _last_target_pos == Vector3.INF:
		return false
	var d := _tower.global_position - _last_target_pos
	d.y = 0.0
	return d.length() < stationary_threshold


## Возвращает ближайший POI, в радиус которого попадает башня. Если башни нет
## или POI не найдено — null. Используется и в _handle_input как gate-чек,
## и в _start_deploy как источник якоря.
##
## "Ближайший" — на случай перекрытия safe_radius'ов соседних POI: лагерь
## защёлкивается на тот, к которому башня ближе. Без этого первый POI в
## группе бы выигрывал, и игрок не смог бы выбрать более далёкий.
func _find_poi_for_deploy() -> Node3D:
	if _tower == null:
		return null
	var tower_pos := _tower.global_position
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for poi in get_tree().get_nodes_in_group(QuestActor.POI_GROUP):
		if not is_instance_valid(poi):
			continue
		if not poi.has_method("is_within_safe_radius"):
			continue
		if not poi.is_within_safe_radius(tower_pos):
			continue
		var poi_node := poi as Node3D
		if poi_node == null:
			continue
		var d_sq: float = (poi_node.global_position - tower_pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = poi_node
	return nearest


func _start_deploy() -> void:
	_state = State.DEPLOYED
	# Anchor: позиция POI (если рядом с костром) > позиция башни > собственная.
	# POI-snap даёт визуально центрированный лагерь на костре, не «рядом с ним
	# со смещением, где башня случайно остановилась».
	var poi := _find_poi_for_deploy()
	if poi != null:
		_deploy_anchor = poi.global_position
	elif _tower != null:
		_deploy_anchor = _tower.global_position
	else:
		_deploy_anchor = global_position
	_deployed_targets.clear()
	var count := _parts.size()
	for i in range(count):
		var angle := float(i) * TAU / float(maxi(count, 1))
		var part_y: float = _parts[i].global_position.y
		var target := Vector3(
			_deploy_anchor.x + cos(angle) * deploy_radius,
			part_y,
			_deploy_anchor.z + sin(angle) * deploy_radius,
		)
		_deployed_targets.append(target)
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_was_holding_stationary = false
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь развёрнут @ (%.1f, %.1f, %.1f)" % [_deploy_anchor.x, _deploy_anchor.y, _deploy_anchor.z])
	deployed.emit(_deploy_anchor)
	# Палатки уязвимы (как и в каравне сейчас — см. _ready/_finalize_pack).
	# В DEPLOYED это идентично, в каравне они тоже atакуемы скелетами,
	# единственное исключение — PACKING_RETURNING (бронь см. _start_pack).
	_set_parts_vulnerable(true)
	# Tower уходит из аггро-цели — скелеты переключаются на палатки/гномов.
	# Если игрок свернёт лагерь, _finalize_pack вернёт tower в группу.
	_set_tower_aggro(false)
	# Гномы выходят бродить.
	for g in _gnomes:
		if is_instance_valid(g):
			g.enter_deployed()
	# Центральный слот для модулей переезжает в anchor и активируется.
	# Y берём с пола, а не с anchor'а: anchor — позиция башни (y≈3, центр меша),
	# а модуль должен стоять на земле, а не висеть в воздухе.
	if _center_slot:
		var ground_y: float = 0.0
		if not _parts.is_empty():
			ground_y = _ground_y_at(_parts[0], _deploy_anchor)
		_center_slot.global_position = Vector3(_deploy_anchor.x, ground_y, _deploy_anchor.z)
		_center_slot.enabled = true


func _start_pack() -> void:
	# Сначала зовём гномов домой; финальный переход в CARAVAN — после прихода всех.
	_state = State.PACKING_RETURNING
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_pack_elapsed = 0.0
	_was_holding_stationary = false
	# Палатки сразу неуязвимы — игрок начал свёртку, тент бронируется.
	# Гномы остаются целью, пока не дойдут до своих палаток (они сами выходят
	# из skeleton_target в _enter_in_tent). На _finalize_pack бронь снимается.
	_set_parts_vulnerable(false)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] свёртка инициирована — ждём гномов")
	for g in _gnomes:
		if is_instance_valid(g):
			g.request_return()


func _finalize_pack() -> void:
	_state = State.CARAVAN_FOLLOWING
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь свёрнут (все гномы дома)")
	# Слот выключается → модуль с него отпадает (остаётся стоять на земле,
	# где был лагерь — игрок может подобрать рукой и поставить заново).
	if _center_slot:
		_center_slot.enabled = false
	# Tower снова цель скелетов в каравне — фоновые wander'ы могут увидеть
	# караван и накинуться. Симметрично _start_deploy, который убирает.
	_set_tower_aggro(true)
	# Палатки также возвращаются в категорию целей — в каравне атакуемы.
	# Бронь снимается, _set_parts_vulnerable(false) был выставлен в _start_pack.
	_set_parts_vulnerable(true)
	packed.emit()


## Хелпер: разом ставит/убирает _vulnerable у всех живых палаток.
## set_vulnerable у CampPart сам управляет членством в SKELETON_TARGET_GROUP
## и приёмом урона. Используется в _ready (caravan-стартом), _start_deploy,
## _start_pack, _finalize_pack — вместо четырёхкратного дублирования цикла.
func _set_parts_vulnerable(value: bool) -> void:
	for p in _parts:
		if p is CampPart:
			(p as CampPart).set_vulnerable(value)


# --- Движение палаток ---

func _update_caravan_follow(delta: float) -> void:
	if _tower == null or _parts.is_empty():
		return

	# Виртуальная цепочка: только палатки, которыми Camp реально может управлять.
	# Skip'аются: torn_off (живут по физике), in_hand (Hand двигает), вне строя
	# (флаг _outside_caravan, ставится в notify_part_settled при release вне
	# placement-зоны и сбрасывается при следующем pickup). distance-фильтра
	# здесь НЕТ — он каждый кадр выкидывал бы из строя «отстающие» палатки
	# когда tower уезжает быстрее цепочки.
	var active_parts: Array[Node3D] = []
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart:
			var cp := part as CampPart
			if not cp.is_in_caravan() or cp.is_in_hand():
				continue
		active_parts.append(part)
	if active_parts.is_empty():
		return

	var lead_dist: float = active_parts[0].global_position.distance_to(_tower.global_position)
	var leader_too_far := lead_dist > follow_max_distance

	if debug_log and LogConfig.master_enabled and leader_too_far != _was_out_of_range:
		if leader_too_far:
			print("[Camp] башня вне зоны видимости (dist=%.1f)" % lead_dist)
		else:
			print("[Camp] башня вернулась в зону видимости (dist=%.1f)" % lead_dist)
		_was_out_of_range = leader_too_far

	for i in range(active_parts.size()):
		var part := active_parts[i]
		var leader_pos: Vector3 = _tower.global_position if i == 0 else active_parts[i - 1].global_position

		# Ведущая палатка стоит, если башня ушла за порог. Остальные всё равно
		# подтягиваются к своему (стоящему) лидеру — цепочка собирается.
		if i == 0 and leader_too_far:
			continue

		var to_leader := leader_pos - part.global_position
		to_leader.y = 0.0
		if to_leader.length_squared() < VecUtil.EPSILON_SQ:
			continue
		var dir := to_leader.normalized()
		var target_pos := leader_pos - dir * part_gap
		# Y: ground + half-height — палатка стоит ровно на полу, не утопает.
		# Без offset palatka.center на ground_y → её нижняя сторона уходит
		# под пол на половину высоты (визуально незаметно из-за толщины
		# Ground'а, но математически некорректно).
		var part_offset_y: float = (part as CampPart).floor_offset_y() if part is CampPart else 0.0
		target_pos.y = _ground_y_at(part, target_pos) + part_offset_y
		part.global_position = _exp_decay(part.global_position, target_pos, follow_speed, delta)


func _update_deployed(delta: float) -> void:
	for i in range(_parts.size()):
		if i >= _deployed_targets.size():
			break
		var part := _parts[i]
		# Skip правило симметрично caravan-follow: torn_off, in_hand,
		# _outside_caravan. Distance-фильтра нет — однократная проверка
		# происходит в notify_part_settled при release.
		if part is CampPart:
			var cp := part as CampPart
			if not cp.is_in_caravan() or cp.is_in_hand():
				continue
		part.global_position = _exp_decay(part.global_position, _deployed_targets[i], follow_speed, delta)


# --- Helpers ---

## Покадрово стабильное смягчение к target. decay — log-rate (чем больше, тем быстрее).
static func _exp_decay(current: Vector3, target: Vector3, decay: float, delta: float) -> Vector3:
	return target + (current - target) * exp(-decay * delta)


## Y под точкой target_pos через raycast по слою TERRAIN. Если raycast пуст —
## возвращаем текущую Y палатки (не дёргаем по высоте).
func _ground_y_at(part: Node3D, target_pos: Vector3) -> float:
	var space := part.get_world_3d().direct_space_state
	if space == null:
		return part.global_position.y
	var from := target_pos + Vector3.UP * 5.0
	var to := target_pos + Vector3.DOWN * 50.0
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.TERRAIN)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return part.global_position.y
	return (hit.position as Vector3).y
