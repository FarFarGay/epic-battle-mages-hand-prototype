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
## Радиус визуального кольца волны вызова от башни.
@export var recall_radius: float = 30.0
## Скорость расширения кольца (м/с) — задаёт длительность визуала.
@export var recall_wave_speed: float = 45.0

## Счётчик уникальных id отрядов (для squad-карточек HUD'а). Со смещением 1000,
## чтобы не пересекаться с лагерными id (на случай гибридных сцен).
var _next_squad_id: int = 1000
## Один отряд НА ТИП (soldier_type → Squad). Найм доливает в существующий отряд
## своего типа, а не плодит дубликаты. На disband — чистим.
var _squads_by_type: Dictionary = {}


const GROUP := &"squad_spawner"


func _ready() -> void:
	add_to_group(GROUP)  # чтобы постройки (казарма) могли заказать отряд
	# Deferred: TradeUI мог ещё не войти в группу к нашему _ready (порядок детей).
	call_deferred(&"_connect_trade")
	# Стартовая артель рабочих (7) живёт в башне с самого начала.
	_spawn_starting_workers()


## Публичный заказ отряда из постройки (казармы): добавить count юнитов типа у позиции
## pos в отряд-этого-типа (тот же путь, что покупка). Возвращает созданных (последние N
## членов отряда) — постройка раздаёт им посты гарнизона.
func request_squad(soldier_type: StringName, count: int, pos: Vector3) -> Array:
	if SoldierSystem == null or not SoldierSystem.has_soldier(soldier_type):
		return []
	# Кламп по капу типа ЗДЕСЬ (единый путь для всех нанимателей — казарма/замок):
	# спавнер держит ОДИН отряд на тип, добор лишь доливает павших до cap.
	var add: int = _clamp_to_cap(soldier_type, maxi(count, 1))
	if add <= 0:
		return []
	_spawn_squad(soldier_type, add, pos)
	var sq: Squad = _squads_by_type.get(soldier_type)
	if sq == null:
		return []
	var m: Array = sq.members
	var out: Array = []
	for i in range(maxi(m.size() - add, 0), m.size()):
		if i >= 0 and i < m.size() and is_instance_valid(m[i]):
			out.append(m[i])
	return out


func _connect_trade() -> void:
	var trade := get_tree().get_first_node_in_group(&"trade_ui")
	if trade != null and not trade.purchased.is_connected(_on_purchased):
		trade.purchased.connect(_on_purchased)


## Клавиша вызова (F): волна от башни + toggle всех room-отрядов escort⇄hold —
## комнатный аналог кампового recall (Camp._handle_halt_input), но без Camp.
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
	# Живые отряды собираем из солдат (уникальные Squad-ссылки).
	var squads: Array = []
	var seen: Dictionary = {}
	for s in get_tree().get_nodes_in_group(&"soldier"):
		if is_instance_valid(s) and s._squad != null and not seen.has(s._squad):
			seen[s._squad] = true
			squads.append(s._squad)
	if squads.is_empty():
		return
	# Toggle: хоть один в эскорте → все встают (HOLD-soft); иначе → все к башне.
	var any_escort: bool = false
	for sq in squads:
		if sq.state == Squad.State.ESCORTING_TOWER:
			any_escort = true
			break
	for sq in squads:
		if any_escort:
			sq.command_hold(_squad_center(sq, origin), false)
		else:
			sq.command_escort()


## Средняя позиция живых членов отряда (fallback — точка башни).
func _squad_center(sq: Squad, fallback: Vector3) -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in sq.members:
		if is_instance_valid(m):
			sum += m.global_position
			n += 1
	return sum / float(n) if n > 0 else fallback


func _on_purchased(unit_type: StringName, squad_size: int) -> void:
	if SoldierSystem == null:
		return
	var soldier_type: StringName = unit_type if SoldierSystem.has_soldier(unit_type) else SOLDIER_TYPE
	# Кап артели (рабочие — 7): докупка доливает только до потолка. Уже полно → ничего.
	var add: int = _clamp_to_cap(soldier_type, maxi(squad_size, 1))
	if add <= 0:
		return
	var front: Vector3 = _purchase_front()
	if front == Vector3.INF:
		return
	_spawn_squad(soldier_type, add, front)


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
	_spawn_squad(soldier_type, count, Vector3(t.x, ground_y, t.z))


## Сколько добавить с учётом потолка типа: cap<=0 → без потолка (вернёт want).
func _clamp_to_cap(soldier_type: StringName, want: int) -> int:
	var cap: int = SoldierSystem.get_squad_cap(soldier_type)
	if cap <= 0:
		return want
	return clampi(want, 0, maxi(cap - _count_of_type(soldier_type), 0))


## Живых членов отряда этого типа (для капа). Реестр _squads_by_type — один на тип.
func _count_of_type(soldier_type: StringName) -> int:
	var sq: Squad = _squads_by_type.get(soldier_type)
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
func _spawn_squad(soldier_type: StringName, count: int, front: Vector3) -> void:
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
	# Один отряд на тип: доливаем в существующий или создаём новый.
	var squad: Squad = _squads_by_type.get(soldier_type)
	var is_new: bool = squad == null
	if is_new:
		squad = Squad.new()
		_next_squad_id += 1
		squad.id = _next_squad_id
		squad.soldier_type = soldier_type
		squad.icon_color = data.get("icon_color", Color.WHITE)
		_squads_by_type[soldier_type] = squad
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
			_squads_by_type.erase(soldier_type)
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
	if _squads_by_type.get(squad.soldier_type) == squad:
		_squads_by_type.erase(squad.soldier_type)
