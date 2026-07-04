extends Node
## Слушает TradeUI.purchased(unit_type, squad_size) и спавнит купленный отряд (копейщики
## или рабочие — по типу) БЕЗ лагеря, следующий за башней. Зеркало Camp._build_and_register_squad, но без
## Camp/экономики/палаток: SoldierGnome.setup_free(escort=башня) + command_escort().
## Отряд (Squad, RefCounted) жив, пока солдаты держат ссылку _squad.

## Тип по умолчанию (fallback, если торг не передал тип).
const SOLDIER_TYPE := &"pikeman"
## Инпут-действие «волна вызова» (как камповый recall). Из project.godot — клавиша F.
const RECALL_ACTION := &"caravan_halt_toggle"

## Радиус кучки спавна вокруг точки появления.
@export var spawn_radius: float = 1.4
## Отступ точки появления ПЕРЕД домами (в сторону открытого пола / башни), чтобы
## копейщики возникали на земле перед поселением, а не внутри здания.
@export var spawn_front_distance: float = 6.0
## Наземный Y для fallback-спавна у башни (её origin приподнят ≈5 — спавнить там
## нельзя, копейщики повисли бы). У домика берётся его собственный наземный Y.
@export var ground_y: float = 0.5
## Боевой радиус купленного отряда от центра строя (башни). Меньше дефолтных 12 —
## копейщики бьют только у башни, под её защитой, не убегают вглубь толпы.
@export var squad_leash_radius: float = 7.0
## Рабочий радиус для артели: больше боевого — чтобы охватить и дерево, и стройку,
## когда отряд припаркован между ними (рабочие сами курсируют руб↔стройка).
@export var work_leash_radius: float = 16.0
## Радиус кольца призыва от башни (и визуал, и гейт «кто откликается на F»). Узкий —
## чтобы F цеплял только ближайшую группу солдат, а не всех на карте.
@export var recall_radius: float = 7.0
## Скорость расширения кольца (м/с) — задаёт длительность визуала.
@export var recall_wave_speed: float = 45.0

## Счётчик уникальных id отрядов (для squad-карточек HUD'а). Со смещением 1000,
## чтобы не пересекаться с лагерными id (на случай гибридных сцен).
var _next_squad_id: int = 1000
## Реестр отрядов по КЛЮЧУ → Squad. Ключ = soldier_type (рабочие/покупка в домике —
## один отряд на тип) ИЛИ instance_id казармы (КАЖДАЯ казарма держит СВОЙ отряд, своя
## тройка, добор только своих павших). Найм доливает в отряд этого ключа. На disband — чистим.
var _squads: Dictionary = {}


const GROUP := &"squad_spawner"


func _ready() -> void:
	add_to_group(GROUP)  # чтобы постройки (казарма) могли заказать отряд
	# Deferred: TradeUI мог ещё не войти в группу к нашему _ready (порядок детей).
	call_deferred(&"_connect_trade")
	# Стартовая артель рабочих (7) живёт в башне с самого начала.
	_spawn_starting_workers()


## Публичный заказ отряда ОТ КОНКРЕТНОЙ КАЗАРМЫ: добавить count юнитов типа у позиции pos
## в отряд ЭТОЙ казармы (ключ = её instance_id → своя тройка независимо от других казарм).
## Добор клампится к cap типа по живым ЭТОЙ казармы. Возвращает новых членов (для постов).
func request_squad_for(owner: Node, soldier_type: StringName, count: int, pos: Vector3) -> Array:
	if owner == null or SoldierSystem == null or not SoldierSystem.has_soldier(soldier_type):
		return []
	var key: int = owner.get_instance_id()
	# ДВА предела: ось ГАРНИЗОНА этой казармы (база типа + бараки рядом, hire_cap_bonus) И глобальное
	# НАСЕЛЕНИЕ (Population) — общий пул армия+добыча. Нанять можно лишь в пределах обоих.
	var cap_bonus: int = int(owner.call(&"hire_cap_bonus")) if owner.has_method(&"hire_cap_bonus") else 0
	var add: int = _clamp_to_cap(key, soldier_type, maxi(count, 1), cap_bonus)
	add = _clamp_to_population(soldier_type, add)
	if add <= 0:
		return []
	var pre: Squad = _squads.get(key)
	var before: int = pre.members.size() if pre != null else 0
	_spawn_squad(key, soldier_type, add, pos)
	var sq: Squad = _squads.get(key)
	if sq == null:
		return []
	# Срез строго от прежнего размера: _spawn_squad мог заспавнить МЕНЬШЕ add
	# (instantiate == null → continue), и срез «последние add» захватил бы
	# старых бойцов — их бы переназначили на посты как «новых».
	var m: Array = sq.members
	var out: Array = []
	for i in range(before, m.size()):
		if is_instance_valid(m[i]):
			out.append(m[i])
	return out


## Живых членов отряда ЭТОЙ казармы (гейт «Артель полна» в торге — per-barracks, не глобально).
func owner_squad_count(owner: Node) -> int:
	if owner == null:
		return 0
	return _count_in(owner.get_instance_id())


## Отряд ЭТОЙ казармы (ключ = instance_id) или null, если ещё не нанимали.
## Панель казармы (HUD) управляет им: призвать за башню / вернуть на стену.
func owner_squad(owner: Node) -> Squad:
	if owner == null:
		return null
	return _squads.get(owner.get_instance_id())


## Заказ отряда ПО ТИПУ (ключ = soldier_type) — ОДИН общий отряд на тип. Для рабочих-артели
## из замка (oil_collector): та же артель, что стартовые рабочие, общий cap. НЕ для казарм
## (у них per-barracks через request_squad_for). Возвращает новых членов.
func request_squad(soldier_type: StringName, count: int, pos: Vector3) -> Array:
	if SoldierSystem == null or not SoldierSystem.has_soldier(soldier_type):
		return []
	var add: int = _clamp_to_cap(soldier_type, soldier_type, maxi(count, 1))
	if add <= 0:
		return []
	var pre: Squad = _squads.get(soldier_type)
	var before: int = pre.members.size() if pre != null else 0
	_spawn_squad(soldier_type, soldier_type, add, pos)
	var sq: Squad = _squads.get(soldier_type)
	if sq == null:
		return []
	# Срез от прежнего размера — та же защита от недоспавна, что в request_squad_for.
	var m: Array = sq.members
	var out: Array = []
	for i in range(before, m.size()):
		if is_instance_valid(m[i]):
			out.append(m[i])
	return out


func _connect_trade() -> void:
	var trade := get_tree().get_first_node_in_group(&"trade_ui")
	if trade != null and not trade.purchased.is_connected(_on_purchased):
		trade.purchased.connect(_on_purchased)


## Клавиша вызова (F): ПРИЗЫВ боевых отрядов за башню. Снимает лучников со стен и ведёт
## за башней. НЕ вытаскивает спрятанных в башне; рабочих не трогает; зовёт только тех, у
## кого есть живой боец в кольце призыва. Возврат на стену — кнопкой в карточке (не F).
func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(RECALL_ACTION):
		_recall_squads()


func _recall_squads() -> void:
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		return
	var origin: Vector3 = (tower as Node3D).global_position
	# Кольцо-волну пульсим всегда (даже без отрядов — видно границу/обратную связь).
	EventBus.recall_zone_pulsed.emit(origin, recall_radius, recall_radius / maxf(recall_wave_speed, 0.001))
	# Уникальные живые отряды из солдат.
	var seen: Dictionary = {}
	for s in get_tree().get_nodes_in_group(&"soldier"):
		if not is_instance_valid(s) or s._squad == null or seen.has(s._squad):
			continue
		seen[s._squad] = true
		var sq: Squad = s._squad
		# Рабочих F не трогает (контроль — через карточку артели).
		if sq.soldier_type == SoldierSystem.ROLE_WORKER:
			continue
		# Спрятанных в башне НЕ вытаскиваем (F не вынимает из башни).
		if sq.state == Squad.State.ESCORTING_TOWER and sq.hide_in_tower:
			continue
		# Зовём, только если есть живой боец в кольце призыва (на стенах/в поле).
		if _squad_has_member_in_ring(sq, origin, recall_radius):
			sq.command_escort()  # снимает лучников со стен → за башней


## Есть ли у отряда живой боец в кольце призыва (XZ-радиус от башни).
func _squad_has_member_in_ring(sq: Squad, origin: Vector3, radius: float) -> bool:
	var r2: float = radius * radius
	for m in sq.members:
		if is_instance_valid(m):
			var d: Vector3 = m.global_position - origin
			d.y = 0.0
			if d.length_squared() <= r2:
				return true
	return false


func _on_purchased(unit_type: StringName, squad_size: int) -> void:
	if SoldierSystem == null:
		return
	var soldier_type: StringName = unit_type if SoldierSystem.has_soldier(unit_type) else SOLDIER_TYPE
	# Кап артели (рабочие — 7): докупка доливает только до потолка. Уже полно → ничего.
	# Покупка в домике гномов — отряд НА ТИП (ключ = тип), не per-barracks.
	var add: int = _clamp_to_cap(soldier_type, soldier_type, maxi(squad_size, 1))
	add = _clamp_to_population(soldier_type, add)  # поверх типа — глобальное население (рабочих не трогает)
	if add <= 0:
		return
	var front: Vector3 = _purchase_front()
	if front == Vector3.INF:
		return
	_spawn_squad(soldier_type, soldier_type, add, front)


## Стартовая артель рабочих — появляется У БАШНИ и сразу прячется внутрь (они в ней
## «живут»). Численность = кап типа (7). Зовётся deferred из _ready (ждёт дерево сцены).
func _spawn_starting_workers() -> void:
	await get_tree().physics_frame
	if not is_inside_tree() or SoldierSystem == null:
		return
	var soldier_type: StringName = SoldierSystem.ROLE_WORKER
	var count: int = SoldierSystem.get_squad_cap(soldier_type)
	if count <= 0:
		count = SoldierSystem.get_squad_size(soldier_type)
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		return
	var t: Vector3 = (tower as Node3D).global_position
	_spawn_squad(soldier_type, soldier_type, count, Vector3(t.x, ground_y, t.z))


## Сколько добавить с учётом потолка ТИПА по отряду ЭТОГО КЛЮЧА: cap<=0 → без потолка. cap_bonus —
## ось гарнизона (бараки в зоне казармы поднимают кап ИМЕННО этой казармы, PadBuilding.hire_cap_bonus).
func _clamp_to_cap(key, soldier_type: StringName, want: int, cap_bonus: int = 0) -> int:
	var cap: int = SoldierSystem.get_squad_cap(soldier_type)
	if cap <= 0:
		return want  # тип без потолка — бараки ни при чём
	return clampi(want, 0, maxi(cap + cap_bonus - _count_in(key), 0))


## Поверх типа — глобальное НАСЕЛЕНИЕ (Population): нанять не больше свободных военных слотов общего
## пула. Рабочие-артель НЕ тратят население (базовая бригада башни) → их не клампим. Нет Population → как было.
func _clamp_to_population(soldier_type: StringName, want: int) -> int:
	if want <= 0:
		return want
	if SoldierSystem != null and soldier_type == SoldierSystem.ROLE_WORKER:
		return want
	if Population == null:
		return want
	return clampi(want, 0, maxi(int(Population.military_room()), 0))


## Живых членов отряда по ключу (тип ИЛИ казарма) — для капа/гейта.
func _count_in(key) -> int:
	var sq: Squad = _squads.get(key)
	if sq == null:
		return 0
	var c: int = 0
	for m in sq.members:
		if is_instance_valid(m):
			c += 1
	return c


## Точка появления при ПОКУПКЕ — перед говорящим домиком (откуда выходят), иначе у
## башни на наземном Y. INF = нет башни (спавн невозможен).
func _purchase_front() -> Vector3:
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		return Vector3.INF
	var house := get_tree().get_first_node_in_group(&"gnome_settlement")
	var anchor: Node3D = (house if house != null else tower) as Node3D
	# ВСЕГДА садим на наземный Y (ground_y), не доверяя origin якоря: и у башни (≈5), и у
	# приподнятого домика-поселения спавн по их Y повесил бы отряд в воздух.
	var base: Vector3 = Vector3(anchor.global_position.x, ground_y, anchor.global_position.z)
	# Направление «в комнату» — от дома к башне (в открытое пространство, не в стену).
	var to_tower: Vector3 = (tower as Node3D).global_position - base
	to_tower.y = 0.0
	var dir: Vector3 = to_tower.normalized() if to_tower.length() > 0.1 else Vector3.FORWARD
	return base + dir * spawn_front_distance


## Спавнит count юнитов типа кучкой у front, доливая в отряд-этого-типа (один на тип)
## или создавая новый (тогда — карточка HUD + эскорт). Общий путь покупки и старта.
func _spawn_squad(key, soldier_type: StringName, count: int, front: Vector3) -> void:
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		return
	var data: Dictionary = SoldierSystem.get_soldier_data(soldier_type)
	if data.is_empty():
		return
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var stats: Dictionary = data.get("stats", {})
	# Один отряд на КЛЮЧ (тип или казарма): доливаем в существующий или создаём новый.
	var squad: Squad = _squads.get(key)
	var is_new: bool = squad == null
	if is_new:
		squad = Squad.new()
		_next_squad_id += 1
		squad.id = _next_squad_id
		squad.soldier_type = soldier_type
		squad.icon_color = data.get("icon_color", Color.WHITE)
		_squads[key] = squad
	var n: int = maxi(count, 1)
	var spawned: int = 0
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		var pos: Vector3 = front + Vector3(cos(ang) * spawn_radius, 0.0, sin(ang) * spawn_radius)
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			continue
		scene_root.add_child(soldier)
		soldier.setup_free(soldier_type, stats, pos, tower)
		# Рабочим — большой work-радиус (охват дерево↔стройка); воинам — боевой leash.
		# Решение по контракту is_worker(), не по сырому soldier_type.
		soldier.combat_leash_radius = work_leash_radius if soldier.is_worker() else squad_leash_radius
		squad.add_member(soldier)  # эмитит members_changed → карточка обновит счётчик
		spawned += 1
	if spawned == 0:
		if is_new:
			_squads.erase(key)
		return
	# Новый отряд-тип → карточка в HUD (squad_created + проброс сигналов) + эскорт.
	# Донайм в существующий — карточка уже есть, обновится через members_changed.
	if is_new:
		EventBus.squad_created.emit(squad)
		# СЛАБАЯ ссылка: связи висят на сигналах САМОГО отряда; сильный захват squad
		# (RefCounted) замкнул бы его на себя → не освобождается (утечка при выходе/
		# disband). WeakRef рвёт цикл — отряд живёт, пока его держат реестр и члены.
		var wr: WeakRef = weakref(squad)
		squad.members_changed.connect(func() -> void: _emit_squad_changed(wr))
		squad.state_changed.connect(func() -> void: _emit_squad_changed(wr))
		squad.disbanded.connect(func() -> void: _emit_squad_disbanded(wr), CONNECT_ONE_SHOT)
		squad.command_escort()


## Проброс squad_changed по WeakRef (см. _spawn_squad — рвём self-цикл RefCounted).
func _emit_squad_changed(wr: WeakRef) -> void:
	var s: Squad = wr.get_ref()
	if s != null:
		EventBus.squad_changed.emit(s)


func _emit_squad_disbanded(wr: WeakRef) -> void:
	var s: Squad = wr.get_ref()
	if s != null:
		_on_squad_disbanded(s)


## Отряд-тип погиб целиком — убираем карточку и чистим реестр (следующий найм
## этого типа создаст новый отряд).
func _on_squad_disbanded(squad: Squad) -> void:
	EventBus.squad_disbanded.emit(squad)
	# Чистим по значению — ключ может быть типом ИЛИ казармой.
	for k in _squads.keys():
		if _squads[k] == squad:
			_squads.erase(k)
			break
