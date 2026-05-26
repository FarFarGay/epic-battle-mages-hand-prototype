class_name Harvester
extends Node3D
## Звено каравана между башней и палатками. Едет за башней, на развёртке
## ставится ровно на POI и качает золото в [CampEconomy] пока стоит. Движением
## управляет [Camp] (caravan-follow + ring-anchor) — сам Harvester только
## переключает состояние и тикает добычу.
##
## Состояния:
## - IN_CARAVAN — едет в строю (между Tower и tents[0]). Не добывает.
## - DEPLOYED — стоит на _deploy_anchor (= центр POI). Добывает gold-per-second.
##
## Привязка экономики: Camp устанавливает _economy через bind_economy() в _ready.
## Через сигнал gold_produced(amount, at_position) Camp может слушать для UI/FX.

signal deployed
signal packed
signal gold_produced(amount: int, at_position: Vector3)

enum State { IN_CARAVAN, DEPLOYED }

@export_group("Gold harvest")
## Скорость добычи золота, единиц в секунду. Тикает только в DEPLOYED.
## 0.5 = 1 gold каждые 2с.
@export var gold_per_second: float = 0.5

@export_group("Visual")
## Узел, который вращается вокруг Y при добыче (drill / шестерня). Опциональный.
@export_node_path("Node3D") var drill_node_path: NodePath
## Скорость вращения drill'а (оборотов в секунду).
@export var drill_rps: float = 0.6
## GPUParticles, эмитирующие частицы добычи. Включаются в DEPLOYED, выключаются
## в IN_CARAVAN. Опционально.
@export_node_path("GPUParticles3D") var harvest_particles_path: NodePath

const HARVESTER_GROUP := &"harvester"

var _state: State = State.IN_CARAVAN
var _gold_accumulator: float = 0.0
var _economy: CampEconomy
var _drill: Node3D
var _harvest_particles: GPUParticles3D


func _ready() -> void:
	add_to_group(HARVESTER_GROUP)
	if not drill_node_path.is_empty():
		_drill = get_node_or_null(drill_node_path) as Node3D
	if not harvest_particles_path.is_empty():
		_harvest_particles = get_node_or_null(harvest_particles_path) as GPUParticles3D
	_apply_visual_state()


## Camp передаёт ссылку на свою экономику. Без неё gold-tick — no-op
## (Harvester не падает, просто не зачисляет).
func bind_economy(economy: CampEconomy) -> void:
	_economy = economy


func is_deployed() -> bool:
	return _state == State.DEPLOYED


## Camp зовёт при развёртке. Anchor — позиция POI (= центр кольца палаток).
## Harvester телепортируется на anchor (внутри ring'а палаток он визуально
## по центру). Идемпотентно.
func deploy_on(anchor: Vector3) -> void:
	global_position = anchor
	if _state == State.DEPLOYED:
		return
	_state = State.DEPLOYED
	_apply_visual_state()
	deployed.emit()


## Camp зовёт при свёртке. Harvester возвращается в IN_CARAVAN — двигаться
## дальше будет уже логика caravan-follow в Camp'е. Идемпотентно.
func pack_to_caravan() -> void:
	if _state == State.IN_CARAVAN:
		return
	_state = State.IN_CARAVAN
	_gold_accumulator = 0.0
	_apply_visual_state()
	packed.emit()


func _process(delta: float) -> void:
	if _state != State.DEPLOYED:
		return
	if _drill != null:
		_drill.rotate_y(delta * TAU * drill_rps)
	if gold_per_second <= 0.0:
		return
	_gold_accumulator += gold_per_second * delta
	if _gold_accumulator < 1.0:
		return
	var whole: int = int(_gold_accumulator)
	_gold_accumulator -= float(whole)
	if _economy != null:
		_economy.add_resource(ResourcePile.ResourceType.GOLD, whole)
	gold_produced.emit(whole, global_position)


func _apply_visual_state() -> void:
	if _harvest_particles != null:
		_harvest_particles.emitting = (_state == State.DEPLOYED)
