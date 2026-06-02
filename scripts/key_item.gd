class_name KeyItem
extends Node3D
## Ключ — золотой куб для второй цели матча (вместе со 1000 золота).
## Дизайнер ставит инстанс KeyItem в подземелье на main.tscn; геймплей
## дальше управляется самим ключом — self-monitoring state machine, без
## специальных команд игрока.
##
## ## Поток:
## 1. **IDLE** — лежит в подземелье. Спин вокруг Y, лёгкий bobbing.
##    Каждые [SCAN_INTERVAL]с проверяет SoldierGnome.SOLDIER_GROUP: если
##    есть живой солдат в [pickup_radius] — берёт его как carrier и
##    переходит в CARRIED. Солдат привёл туда через команду «иди сюда»
##    (HandSquadAim ЛКМ-клик в подземелье рядом с ключом) — никакой
##    спец-команды «подобрать» не нужно, ключ сам цепляется.
## 2. **CARRIED** — следует за carrier (member squad'а). Визуально парит
##    над его головой. Каждый кадр проверяет дистанцию до Tower: если
##    ≤ [tower_pickup_radius] — переходит в AT_TOWER. Эмитит
##    [signal EventBus.key_picked_up_by_squad].
## 3. **AT_TOWER** — парит над башней. Сигнал
##    [signal EventBus.key_delivered_to_tower]. Gate теперь слушает
##    Tower-positions для перехода в OPENED.
## 4. **CONSUMED** — после прохождения через Gate. Невидим, ничего не делает.
##
## **Carrier-смерть:** если carrier-член squad'а умер — ключ падает на
## землю в его последней позиции, возвращается в IDLE (другие солдаты могут
## подобрать).

## Состояния. Linear progression: IDLE → CARRIED → AT_TOWER → CONSUMED.
## Откат CARRIED → IDLE возможен при смерти carrier'а (ключ падает).
enum State { IDLE, CARRIED, AT_TOWER, CONSUMED }

const GROUP := &"key_item"

## Радиус подбора ключом солдата. Соответствует ~двум шагам солдата —
## squad дошёл до точки рядом, ключ цепляется.
@export var pickup_radius: float = 2.5
## Радиус доставки в башню. Tower-pickup zone = ~центр башни + размер.
## 5м — squad подходит к башне, ключ перепрыгивает на неё.
@export var tower_pickup_radius: float = 5.0
## Высота парения над carrier'ом (CARRIED / AT_TOWER).
@export var carry_offset_y: float = 1.6
## Период sphere-scan'а в IDLE. 0.2с — реакция почти мгновенная, нагрузка
## мизерная (group-iter на ~10-15 солдатах).
@export var scan_interval: float = 0.2

@onready var _mesh: MeshInstance3D = $Mesh

var _state: int = State.IDLE
var _carrier: Node3D = null  ## SoldierGnome — конкретный член squad'а
var _tower: Node3D = null
var _scan_timer: float = 0.0
var _spin_angle: float = 0.0
var _bob_phase: float = 0.0
## Y из .tscn — точка падения «обратно на пол» при смерти carrier'а или
## стартовая высота в IDLE.
var _ground_y: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	_ground_y = global_position.y
	_scan_timer = randf() * scan_interval


func get_state() -> int:
	return _state


func is_carried() -> bool:
	return _state == State.CARRIED


func is_at_tower() -> bool:
	return _state == State.AT_TOWER


## Gate вызывает после прохода башни — переводим в CONSUMED. Визуально
## ключ исчезает (это «отдан воротам»).
func consume() -> void:
	if _state == State.CONSUMED:
		return
	_state = State.CONSUMED
	visible = false
	if LogConfig.master_enabled:
		print("[KeyItem] потрачен на ворота")


func _process(delta: float) -> void:
	_spin_angle += delta * TAU * 0.35
	_bob_phase += delta * 2.0
	match _state:
		State.IDLE:
			_tick_idle(delta)
		State.CARRIED:
			_tick_carried(delta)
		State.AT_TOWER:
			_tick_at_tower(delta)
		State.CONSUMED:
			pass
	# Визуал спина — на всех живых state'ах. Bob — мягкое колебание Y вокруг
	# текущей global_position.y (плюс carry_offset_y для CARRIED/AT_TOWER —
	# применяется внутри tick'ов).
	if _mesh != null:
		_mesh.rotation.y = _spin_angle
		_mesh.position.y = sin(_bob_phase) * 0.08


## IDLE: throttled scan ближайшего солдата в pickup_radius. Чем меньше
## solid'ов на сцене — тем дешевле, но даже на 30+ — копейки.
func _tick_idle(delta: float) -> void:
	global_position.y = _ground_y
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return
	_scan_timer = scan_interval
	var soldier: Node3D = _find_soldier_nearby()
	if soldier == null:
		return
	_carrier = soldier
	_state = State.CARRIED
	if LogConfig.master_enabled:
		print("[KeyItem] подобран солдатом %s" % soldier.name)
	EventBus.key_picked_up_by_squad.emit()


## CARRIED: парим над carrier'ом, проверяем дистанцию до Tower'а. Если
## carrier умер — ключ падает на землю в его последней позиции.
func _tick_carried(_delta: float) -> void:
	if not is_instance_valid(_carrier):
		# Carrier мёртв — ключ остаётся в последней позиции, возвращается
		# в IDLE. Другой солдат может подобрать.
		_state = State.IDLE
		_carrier = null
		_ground_y = global_position.y
		if LogConfig.master_enabled:
			print("[KeyItem] carrier мёртв — ключ упал на пол")
		return
	# Парим над carrier'ом. Y = carrier.y + carry_offset_y.
	global_position = Vector3(
		_carrier.global_position.x,
		_carrier.global_position.y + carry_offset_y,
		_carrier.global_position.z,
	)
	# Проверка близости к Tower'у — lazy-резолв ссылки.
	if not is_instance_valid(_tower):
		_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if _tower == null:
		return
	var dx: float = _tower.global_position.x - _carrier.global_position.x
	var dz: float = _tower.global_position.z - _carrier.global_position.z
	if dx * dx + dz * dz <= tower_pickup_radius * tower_pickup_radius:
		_state = State.AT_TOWER
		if LogConfig.master_enabled:
			print("[KeyItem] доставлен в башню")
		EventBus.key_delivered_to_tower.emit()


## AT_TOWER: парим над Tower'ом. Tower проходит через Gate — Gate сама
## позовёт consume() на ключе.
func _tick_at_tower(_delta: float) -> void:
	if not is_instance_valid(_tower):
		_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if _tower == null:
		return
	global_position = Vector3(
		_tower.global_position.x,
		_tower.global_position.y + carry_offset_y + 2.5,  # выше — над верхушкой башни
		_tower.global_position.z,
	)


## Ищет ближайшего живого солдата в pickup_radius. Y игнорируется —
## ключ на полу, солдат на полу. Группа SOLDIER_GROUP включает pikeman'ов
## и archer'ов.
func _find_soldier_nearby() -> Node3D:
	var best: Node3D = null
	var best_dist_sq: float = pickup_radius * pickup_radius
	for n in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		if not is_instance_valid(n):
			continue
		var s := n as Node3D
		if s == null:
			continue
		var dx: float = s.global_position.x - global_position.x
		var dz: float = s.global_position.z - global_position.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = s
	return best
