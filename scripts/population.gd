extends Node
## НАСЕЛЕНИЕ = АРТЕЛЬ РАБОЧИХ (пивот 2026-07-12). Абстрактного supply-пула больше нет:
## население — это ЖИВЫЕ гномы-рабочие артели (кап найма — SoldierSystem, 7).
## Производственное здание (pop_demand > 0) забирает РЕАЛЬНОГО свободного гнома:
## Population назначает ближайшего, тот идёт к зданию и прячется внутри («смена») —
## здание работает, только пока гном ВНУТРИ (is_staffed). Найм солдата расходует
## свободного гнома артели (consume_free_workers — лучник/копейщик = бывший рабочий).
## Пополнение артели: найм рабочих у замка + домик гномов — как раньше, кап 7.
##
## API сохранён (cap/used/free_slots/military_room/is_staffed/alarm) — потребители
## (HUD, гейты торга, тики зданий) те же. Семантика: cap = живых рабочих ВСЕГО,
## used = на сменах, free_slots = military_room = свободные (в здание ИЛИ в солдаты).
## Замок/дома кап больше НЕ поднимают (CASTLE_POP/pop_provided умерли с пулом).
##
## Источник правды назначений — сам рабочий (SoldierGnome._staff_building): Population
## каждый пересчёт собирает картину по юнитам и закрывает дефициты. Назначения ЛИПКИЕ —
## гномов не перетасовываем между зданиями; продюсеры (pop_priority 0: шахта/институт)
## комплектуются раньше сапортов. Перетекание гнома из сапорта в осиротевший продюсер —
## PENDING (v1 без воровства).

const PAD_GROUP := &"pad_building"
const SOLDIER_GROUP := SoldierGnome.SOLDIER_GROUP  # канон — SoldierGnome.SOLDIER_GROUP

## Частота пересчёта снапшота (сек): значения меняются медленно (стройка/найм/гибель) — редкий ок.
const RECOMPUTE_INTERVAL := 0.25

var _alive: int = 0            # живых рабочих всего (свободные + на сменах)
var _on_shift: int = 0         # назначены на здания (в пути или внутри)
## producer instance_id → сколько его гномов уже ВНУТРИ (для is_staffed).
var _inside_by_building: Dictionary = {}
var _timer: float = 0.0
## Прошлые значения снапшота: карточка артели рисует наши цифры, но обновляется
## по squad-событиям — на смену чисел БЕЗ события (спавн/смерть/смена) пинаем её сами.
var _prev_alive: int = -1
var _prev_free: int = -1

## ТРЕВОГА (клавиша V / дизайн 2026-07-02): свободные рабочие бегут в убежище
## (SoldierGnome._active_tick), здания ПРОСТАИВАЮТ (is_staffed = false), но гномов
## со смен НЕ выгоняем — внутри здания так же безопасно, как в убежище.
## Военных не трогает — солдаты воюют.
var alarm_active: bool = false


func set_alarm(active: bool) -> void:
	if alarm_active == active:
		return
	alarm_active = active
	_timer = 0.0  # мгновенный пересчёт: простой/возврат без ожидания интервала
	EventBus.alarm_changed.emit(active)


## V — тумблер тревоги. В main.tscn клавишей владеет Camp (режим ALARM
## сборщиков) — там не перехватываем, чтобы не раздваивать смысл клавиши.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"gnome_alarm"):
		return
	if get_tree().get_first_node_in_group(&"camp") != null:
		return
	set_alarm(not alarm_active)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_recompute()
		_timer = RECOMPUTE_INTERVAL


## Вся артель: живых рабочих всего (свободные + на сменах). Потолок найма держит
## SoldierSystem (кап типа 7) — тут только факт.
func cap() -> int:
	return _alive


## Занято = рабочие на сменах в зданиях (в пути к зданию тоже считаются занятыми).
func used() -> int:
	return _on_shift


## Свободные рабочие: можно назначить в здание или потратить на найм солдата.
## Имя НЕ free() — оно занято встроенным Object.free() (снос узла), переопределение ломает движок.
func free_slots() -> int:
	return maxi(_alive - _on_shift, 0)


## Слоты под НАЙМ солдат = свободные рабочие (солдат расходует гнома артели).
## Гейт найма в торге (PadBuilding._my_hire_cap) и клампы спавнера берут это.
func military_room() -> int:
	return free_slots()


## Работает ли здание: НЕ тревога И все нужные гномы смены уже ВНУТРИ (дошли).
## Гном в пути = здание ещё простаивает (органика: добыча стартует с приходом).
func is_staffed(producer: Node) -> bool:
	if alarm_active or producer == null or not is_instance_valid(producer):
		return false
	var need: int = int(producer.call(&"pop_demand")) if producer.has_method(&"pop_demand") else 0
	if need <= 0:
		return false
	return int(_inside_by_building.get(producer.get_instance_id(), 0)) >= need


## РАСХОД гномов на найм солдат: забрать до count СВОБОДНЫХ рабочих, ближайших к
## near (у казармы). Каждый исчезает с кольцом-визуалом («ушёл в казарму»).
## Возвращает, сколько реально забрали — спавнер нанимает ровно столько солдат.
func consume_free_workers(count: int, near: Vector3) -> int:
	if count <= 0:
		return 0
	var tree := get_tree()
	if tree == null:
		return 0
	var free_workers: Array = []
	for s in tree.get_nodes_in_group(SOLDIER_GROUP):
		if not is_instance_valid(s):
			continue
		if not (s.has_method(&"is_worker") and bool(s.call(&"is_worker"))):
			continue
		if s.staff_building() != null:
			continue  # на смене — не трогаем (снял бы добычу без ведома игрока)
		free_workers.append(s)
	var taken: int = 0
	while taken < count and not free_workers.is_empty():
		var w: Node3D = _pop_nearest(free_workers, near)
		var pos: Vector3 = w.global_position
		AoeVisual.spawn_expanding_ring(tree.current_scene,
			Vector3(pos.x, 0.05, pos.z), 1.6, 0.3, Color(0.55, 0.75, 1.0, 0.9))
		# Штатно выписать из отряда (queue_free БЕЗ смерти destroyed-сигнал не
		# эмитит — Squad.remove_member чистит members и толкает members_changed →
		# EventBus.squad_changed → карточка артели обновляет счётчик).
		var sq: Squad = w._squad
		if sq != null:
			sq.remove_member(w)
		# Из группы СРАЗУ (queue_free отложен до конца кадра — иначе повторный
		# пересчёт в этом кадре посчитал бы «мёртвую душу»), потом сносим.
		w.remove_from_group(SOLDIER_GROUP)
		w.visible = false
		w.queue_free()
		taken += 1
	if taken > 0:
		# Снапшот правим сразу (не ждём пересчёта): синхронный refresh карточки
		# из remove_member выше должен прочитать уже новые цифры.
		_alive = maxi(_alive - taken, 0)
		_timer = 0.0  # мгновенный полный пересчёт следом
	return taken


## Пересчёт снапшота: собрать картину по рабочим (их _staff_building — источник
## правды), отпустить назначения на здания без спроса, закрыть дефициты продюсеров
## ближайшими свободными гномами.
func _recompute() -> void:
	var tree := get_tree()
	if tree == null:
		return
	# 1. Живые рабочие: свободные / по зданиям / кто уже внутри.
	var free_workers: Array = []
	var by_building: Dictionary = {}   # producer_id → Array[worker]
	var inside: Dictionary = {}        # producer_id → int (уже внутри)
	var alive: int = 0
	var any_worker: Node = null  # для пинка карточки артели (нужен её squad)
	for s in tree.get_nodes_in_group(SOLDIER_GROUP):
		if not is_instance_valid(s):
			continue
		if not (s.has_method(&"is_worker") and bool(s.call(&"is_worker"))):
			continue
		alive += 1
		any_worker = s
		var b: Node3D = s.staff_building()
		if b == null:
			free_workers.append(s)
			continue
		var bid: int = b.get_instance_id()
		if not by_building.has(bid):
			by_building[bid] = []
		(by_building[bid] as Array).append(s)
		if bool(s.call(&"is_on_shift")):
			inside[bid] = int(inside.get(bid, 0)) + 1
	_alive = alive
	# 2. Продюсеры со спросом, по приоритету комплектования.
	var producers: Array = []
	var demand_ids: Dictionary = {}
	for b in tree.get_nodes_in_group(PAD_GROUP):
		if is_instance_valid(b) and b.has_method(&"pop_demand") and int(b.call(&"pop_demand")) > 0:
			producers.append(b)
			demand_ids[b.get_instance_id()] = true
	# 3. Назначения на здания БЕЗ спроса (жила иссякла, demand упал) — отпустить в артель.
	for bid in by_building.keys():
		if demand_ids.has(bid):
			continue
		for w in by_building[bid]:
			w.clear_staffing()
			free_workers.append(w)
		by_building.erase(bid)
		inside.erase(bid)
	# 4. Дефициты по приоритету: ближайший свободный гном получает назначение.
	producers.sort_custom(_compare_producers)
	var on_shift: int = 0
	for p in producers:
		var bid: int = p.get_instance_id()
		var have: Array = by_building.get(bid, [])
		var need: int = int(p.call(&"pop_demand"))
		while have.size() > need:  # спрос снизился — лишних отпускаем
			var extra: Node3D = have.pop_back()
			extra.clear_staffing()
			free_workers.append(extra)
		while have.size() < need and not free_workers.is_empty():
			var w: Node3D = _pop_nearest(free_workers, (p as Node3D).global_position)
			w.assign_staffing(p)
			have.append(w)
		on_shift += have.size()
	_on_shift = on_shift
	_inside_by_building = inside
	# Цифры сменились (спавн/смерть/расход/смена) → пнуть карточку артели: она
	# рисует free/cap отсюда, а squad-события на часть этих изменений не фронтят.
	var free_now: int = free_slots()
	if (_alive != _prev_alive or free_now != _prev_free) and any_worker != null:
		_prev_alive = _alive
		_prev_free = free_now
		var sq = any_worker.get(&"_squad")
		if sq != null:
			EventBus.squad_changed.emit(sq)


## Вынуть из массива юнита, ближайшего к point (XZ). Массив непуст — caller следит.
func _pop_nearest(units: Array, point: Vector3) -> Node3D:
	var best_i: int = 0
	var best_d: float = INF
	for i in range(units.size()):
		var u: Node3D = units[i]
		var dx: float = u.global_position.x - point.x
		var dz: float = u.global_position.z - point.z
		var d: float = dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best_i = i
	var out: Node3D = units[best_i]
	units.remove_at(best_i)
	return out


## Порядок комплектования: меньший pop_priority раньше (шахта=0 до сапортов=1), при равенстве — по id.
func _compare_producers(a: Node, c: Node) -> bool:
	var pa: int = int(a.call(&"pop_priority")) if a.has_method(&"pop_priority") else 1
	var pc: int = int(c.call(&"pop_priority")) if c.has_method(&"pop_priority") else 1
	if pa != pc:
		return pa < pc
	return a.get_instance_id() < c.get_instance_id()
