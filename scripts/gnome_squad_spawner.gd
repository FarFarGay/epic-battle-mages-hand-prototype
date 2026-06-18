extends Node
## Слушает TradeUI.purchased(squad_size) и спавнит купленный отряд копейщиков —
## БЕЗ лагеря, следующих за башней. Зеркало Camp._build_and_register_squad, но без
## Camp/экономики/палаток: SoldierGnome.setup_free(escort=башня) + command_escort().
## Отряд (Squad, RefCounted) жив, пока солдаты держат ссылку _squad.

const SOLDIER_TYPE := &"pikeman"
## Радиус кучки спавна вокруг точки появления.
const SPAWN_RADIUS := 1.4
## Отступ точки появления ПЕРЕД домами (в сторону открытого пола / башни), чтобы
## копейщики возникали на земле перед поселением, а не внутри здания.
const SPAWN_FRONT_DISTANCE := 6.0
## Наземный Y для fallback-спавна у башни (её origin приподнят ≈5 — спавнить там
## нельзя, копейщики повисли бы). У домика берётся его собственный наземный Y.
const GROUND_Y := 0.5

## Счётчик уникальных id отрядов (для squad-карточек HUD'а). Со смещением 1000,
## чтобы не пересекаться с лагерными id (на случай гибридных сцен).
var _next_squad_id: int = 1000


func _ready() -> void:
	# Deferred: TradeUI мог ещё не войти в группу к нашему _ready (порядок детей).
	call_deferred(&"_connect_trade")


func _connect_trade() -> void:
	var trade := get_tree().get_first_node_in_group(&"trade_ui")
	if trade != null and not trade.purchased.is_connected(_on_purchased):
		trade.purchased.connect(_on_purchased)


func _on_purchased(squad_size: int) -> void:
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		return
	if SoldierSystem == null:
		return
	var data: Dictionary = SoldierSystem.get_soldier_data(SOLDIER_TYPE)
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

	var squad := Squad.new()
	_next_squad_id += 1
	squad.id = _next_squad_id
	squad.soldier_type = SOLDIER_TYPE
	squad.icon_color = data.get("icon_color", Color.WHITE)
	squad.charge_max = float(data.get("charge_max", squad.charge_max))
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
		soldier.setup_free(SOLDIER_TYPE, stats, pos, tower)
		squad.add_member(soldier)
		spawned += 1
	if spawned == 0:
		return
	# Карточка управления в HUD: эмитим как Camp — squad_created + проброс
	# members_changed/state_changed → squad_changed, disbanded → squad_disbanded.
	EventBus.squad_created.emit(squad)
	squad.members_changed.connect(func() -> void: EventBus.squad_changed.emit(squad))
	squad.state_changed.connect(func() -> void: EventBus.squad_changed.emit(squad))
	squad.disbanded.connect(func() -> void: EventBus.squad_disbanded.emit(squad), CONNECT_ONE_SHOT)
	# Появились перед домами на земле → сразу за башней (управление — карточкой в HUD).
	squad.command_escort()
	# Маркер заряда squad-абилки над отрядом (ловит hand-slam при готовности).
	var marker := SquadChargeMarker.new()
	scene_root.add_child(marker)
	marker.setup(squad)
