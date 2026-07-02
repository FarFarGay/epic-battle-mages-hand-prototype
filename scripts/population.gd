extends Node
## Население — единый supply-пул (slots). СНАБЖЕНИЕ дают ЗАМОК и ДОМА; армия и производство ЗАНИМАЮТ
## слоты. Общий пул (солдаты И работающие шахты тянут из него) → трейд-офф «армия ИЛИ добыча»: каждый
## нанятый солдат = минус одна укомплектованная шахта. ОТДЕЛЬНО от пула живёт ВМЕСТИМОСТЬ казармы
## (бараки рядом, PadBuilding.hire_cap_bonus) — сколько солдат держит казарма; заселить их всё равно
## надо из этого пула (ёмкость ≠ снабжение).
##
## Автолоад-источник правды (как SoldierSystem). Значения — аггрегаты по группам, пересчёт на своём
## таймере; потребители ОПРАШИВАЮТ cap()/free()/military_room()/is_staffed() (как HUD опрашивает
## монеты — без сигналов, throttled).
##
## ПРИОРИТЕТ ВОЕННЫЙ: живые солдаты держат слоты всегда (их нельзя «разжаловать»); шахты комплектуются
## ОСТАТКОМ (cap − солдаты), лишние ПРОСТАИВАЮТ (_tick_mine выходит без добычи). Рабочие-артель башни
## НЕ считаются — это базовая бригада, существовала до экономики населения.

const PAD_GROUP := &"pad_building"
const SOLDIER_GROUP := &"soldier"
const CASTLE_GROUP := &"castle"

## ЗАМОК — соц-ядро: население существует ТОЛЬКО с замком (он заселяет поселение). До замка cap=0 и
## HUD не показывает параметр. Замок даёт стартовые слоты, соц-постройки (дом/барак) добавляют сверх.
const CASTLE_POP := 6
## Частота пересчёта снапшота (сек): значения меняются медленно (стройка/найм/гибель) — редкий ок.
const RECOMPUTE_INTERVAL := 0.25

var _cap: int = 0
var _used_military: int = 0
var _used_production: int = 0
## instance_id шахты → true: продюсеры, получившие слот в этом пересчёте (см. is_staffed).
var _staffed: Dictionary = {}
var _timer: float = 0.0

## ТРЕВОГА (клавиша V / дизайн 2026-07-02): население попряталось — пересчёт никого
## не комплектует (вся добыча/мана простаивает), рабочие-артель бегут в убежище
## (SoldierGnome._active_tick). Военных НЕ трогает — солдаты воюют.
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


## Полный кап населения = замок (CASTLE_POP) + Σ соц-зданий (pop_provided). 0, пока замка нет.
func cap() -> int:
	return _cap


## Активна ли система населения = стоит ли замок (соц-ядро). HUD прячет параметр, пока false.
func has_castle() -> bool:
	var tree := get_tree()
	return tree != null and tree.get_first_node_in_group(CASTLE_GROUP) != null


## Занято = солдаты + укомплектованные шахты (по построению всегда ≤ cap).
func used() -> int:
	return _used_military + _used_production


## Свободные слоты (есть, только если соц-зданий больше, чем солдат+работающих шахт).
## Имя НЕ free() — оно занято встроенным Object.free() (снос узла), переопределение ломает движок.
func free_slots() -> int:
	return maxi(_cap - used(), 0)


## Слоты под НАЙМ солдат (военный приоритет: армия может занять весь cap, выдавив шахты в простой).
## = cap − живые солдаты. Гейт «Артель полна» в торге берёт это (PadBuilding._my_hire_cap).
func military_room() -> int:
	return maxi(_cap - _used_military, 0)


## Укомплектована ли шахта населением (получила слот). Не укомплектованная — простаивает.
func is_staffed(producer: Node) -> bool:
	return producer != null and is_instance_valid(producer) and _staffed.has(producer.get_instance_id())


## Пересчёт снапшота: cap по соц-зданиям, военный расход по солдатам, комплектование шахт остатком.
func _recompute() -> void:
	var tree := get_tree()
	if tree == null:
		return
	# КАП: замок (соц-ядро) + вклад каждого соц-здания. Без замка cap=0 (система не активна).
	var cap_total: int = CASTLE_POP if tree.get_first_node_in_group(CASTLE_GROUP) != null else 0
	var producers: Array = []  # PRODUCTION-здания, претендующие на гнома (шахта/плавильня/двор)
	for b in tree.get_nodes_in_group(PAD_GROUP):
		if not is_instance_valid(b):
			continue
		if b.has_method(&"pop_provided"):
			cap_total += int(b.call(&"pop_provided"))
		if b.has_method(&"pop_demand") and int(b.call(&"pop_demand")) > 0:
			producers.append(b)
	_cap = cap_total
	# ВОЕННЫЙ расход: живые солдаты (рабочие-артель НЕ в счёт — базовая бригада башни).
	var mil: int = 0
	for s in tree.get_nodes_in_group(SOLDIER_GROUP):
		if not is_instance_valid(s):
			continue
		if s.has_method(&"is_worker") and bool(s.call(&"is_worker")):
			continue
		mil += 1
	_used_military = mil
	# ПРОИЗВОДСТВО: комплектуем гномами ОСТАТКОМ (cap − солдаты). Порядок: pop_priority (шахта раньше
	# плавильни/двора — базовое производство держим, усиления гаснут первыми), затем instance_id (стабильно).
	producers.sort_custom(_compare_producers)
	var room: int = maxi(_cap - _used_military, 0)
	var staffed: Dictionary = {}
	var prod: int = 0
	# ТРЕВОГА: население в укрытии — производственные слоты не комплектуются вовсе.
	if not alarm_active:
		for p in producers:
			var need: int = int(p.call(&"pop_demand"))
			if prod + need <= room:
				staffed[p.get_instance_id()] = true
				prod += need
	_staffed = staffed
	_used_production = prod


## Порядок комплектования: меньший pop_priority раньше (шахта=0 до сапортов=1), при равенстве — по id.
func _compare_producers(a: Node, c: Node) -> bool:
	var pa: int = int(a.call(&"pop_priority")) if a.has_method(&"pop_priority") else 1
	var pc: int = int(c.call(&"pop_priority")) if c.has_method(&"pop_priority") else 1
	if pa != pc:
		return pa < pc
	return a.get_instance_id() < c.get_instance_id()
