extends Node
## Слушает TradeUI.purchased(unit_type, squad_size) и спавнит купленный отряд (копейщики
## или рабочие — по типу) БЕЗ лагеря, следующий за башней. Зеркало Camp._build_and_register_squad, но без
## Camp/экономики/палаток: SoldierGnome.setup_free(escort=башня) + command_escort().
## Отряд (Squad, RefCounted) жив, пока солдаты держат ссылку _squad.

## Тип по умолчанию (fallback, если торг не передал тип).
const SOLDIER_TYPE := &"pikeman"
## Радиус кучки спавна вокруг точки появления.
const SPAWN_RADIUS := 1.4
## Отступ точки появления ПЕРЕД домами (в сторону открытого пола / башни), чтобы
## копейщики возникали на земле перед поселением, а не внутри здания.
const SPAWN_FRONT_DISTANCE := 6.0
## Наземный Y для fallback-спавна у башни (её origin приподнят ≈5 — спавнить там
## нельзя, копейщики повисли бы). У домика берётся его собственный наземный Y.
const GROUND_Y := 0.5
## Боевой радиус купленного отряда от центра строя (башни). Меньше дефолтных 12 —
## копейщики бьют только у башни, под её защитой, не убегают вглубь толпы.
const SQUAD_LEASH_RADIUS := 7.0
## Рабочий радиус для артели: больше боевого — чтобы охватить и дерево, и стройку,
## когда отряд припаркован между ними (рабочие сами курсируют руб↔стройка).
const WORK_LEASH_RADIUS := 16.0

## Инпут-действие «волна вызова» (как камповый recall). Из project.godot — клавиша F.
const RECALL_ACTION := &"caravan_halt_toggle"
## Радиус визуального кольца волны от башни.
const RECALL_RADIUS := 30.0
## Скорость расширения кольца (м/с) — задаёт длительность визуала.
const RECALL_WAVE_SPEED := 45.0

## Счётчик уникальных id отрядов (для squad-карточек HUD'а). Со смещением 1000,
## чтобы не пересекаться с лагерными id (на случай гибридных сцен).
var _next_squad_id: int = 1000
## Один отряд НА ТИП (soldier_type → Squad). Найм доливает в существующий отряд
## своего типа, а не плодит дубликаты. На disband — чистим.
var _squads_by_type: Dictionary = {}


func _ready() -> void:
	# Deferred: TradeUI мог ещё не войти в группу к нашему _ready (порядок детей).
	call_deferred(&"_connect_trade")


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
	EventBus.recall_zone_pulsed.emit(origin, RECALL_RADIUS, RECALL_RADIUS / maxf(RECALL_WAVE_SPEED, 0.001))
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
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		return
	if SoldierSystem == null:
		return
	var soldier_type: StringName = unit_type if SoldierSystem.has_soldier(unit_type) else SOLDIER_TYPE
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
	# «Дом» — говорящий гномий домик (откуда выходят), иначе fallback на башню.
	var house := get_tree().get_first_node_in_group(&"gnome_settlement")
	var anchor: Node3D = (house if house != null else tower) as Node3D
	# Наземный Y якоря. У домика origin на полу; у башни origin приподнят (≈5) —
	# тогда садим на GROUND_Y, чтобы не спавнить в воздухе.
	var ground_y: float = anchor.global_position.y
	if house == null:
		ground_y = GROUND_Y
	var base: Vector3 = Vector3(anchor.global_position.x, ground_y, anchor.global_position.z)
	# Направление «в комнату» — от дома к башне (в открытое пространство, не в стену).
	var to_tower: Vector3 = (tower as Node3D).global_position - base
	to_tower.y = 0.0
	var dir: Vector3 = to_tower.normalized() if to_tower.length() > 0.1 else Vector3.FORWARD
	# Точка появления — ПЕРЕД домами, на открытой земле (не внутри здания).
	var front: Vector3 = base + dir * SPAWN_FRONT_DISTANCE

	# Один отряд на тип: доливаем в существующий отряд этого типа или создаём новый.
	var squad: Squad = _squads_by_type.get(soldier_type)
	var is_new: bool = squad == null
	if is_new:
		squad = Squad.new()
		_next_squad_id += 1
		squad.id = _next_squad_id
		squad.soldier_type = soldier_type
		squad.icon_color = data.get("icon_color", Color.WHITE)
		_squads_by_type[soldier_type] = squad
	# Рабочим — большой work-радиус (охват дерево↔стройка); воинам — боевой leash.
	var leash: float = WORK_LEASH_RADIUS if soldier_type == &"worker" else SQUAD_LEASH_RADIUS
	var n: int = maxi(squad_size, 1)
	var spawned: int = 0
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		# Кучка вокруг точки появления перед домами, на наземном Y.
		var pos: Vector3 = front + Vector3(cos(ang) * SPAWN_RADIUS, 0.0, sin(ang) * SPAWN_RADIUS)
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			continue
		scene_root.add_child(soldier)
		soldier.setup_free(soldier_type, stats, pos, tower)
		soldier.combat_leash_radius = leash
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
		squad.members_changed.connect(func() -> void: EventBus.squad_changed.emit(squad))
		squad.state_changed.connect(func() -> void: EventBus.squad_changed.emit(squad))
		squad.disbanded.connect(_on_squad_disbanded.bind(squad), CONNECT_ONE_SHOT)
		squad.command_escort()


## Отряд-тип погиб целиком — убираем карточку и чистим реестр (следующий найм
## этого типа создаст новый отряд).
func _on_squad_disbanded(squad: Squad) -> void:
	EventBus.squad_disbanded.emit(squad)
	if _squads_by_type.get(squad.soldier_type) == squad:
		_squads_by_type.erase(squad.soldier_type)
