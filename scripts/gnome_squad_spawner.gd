extends Node
## Слушает TradeUI.purchased(squad_size) и спавнит купленный отряд копейщиков —
## БЕЗ лагеря, следующих за башней. Зеркало Camp._build_and_register_squad, но без
## Camp/экономики/палаток: SoldierGnome.setup_free(escort=башня) + command_escort().
## Отряд (Squad, RefCounted) жив, пока солдаты держат ссылку _squad.

const SOLDIER_TYPE := &"pikeman"
## Радиус кольца спавна вокруг башни (чтобы не появляться внутри корпуса).
const SPAWN_RADIUS := 3.5


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
	var squad := Squad.new()
	squad.soldier_type = SOLDIER_TYPE
	squad.icon_color = data.get("icon_color", Color.WHITE)
	squad.charge_max = float(data.get("charge_max", squad.charge_max))
	var center: Vector3 = (tower as Node3D).global_position
	var n: int = maxi(squad_size, 1)
	var spawned: int = 0
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		var pos: Vector3 = center + Vector3(cos(ang) * SPAWN_RADIUS, 0.0, sin(ang) * SPAWN_RADIUS)
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			continue
		scene_root.add_child(soldier)
		soldier.setup_free(SOLDIER_TYPE, stats, pos, tower)
		squad.add_member(soldier)
		spawned += 1
	if spawned == 0:
		return
	# Эскорт башни — отряд следует за ней и бьёт врагов по пути.
	squad.command_escort()
	# Маркер заряда squad-абилки над отрядом (ловит hand-slam при готовности).
	var marker := SquadChargeMarker.new()
	scene_root.add_child(marker)
	marker.setup(squad)
