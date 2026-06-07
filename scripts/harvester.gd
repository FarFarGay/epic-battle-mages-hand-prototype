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

## Motion-feedback для caravan (snake-trail bobbing + tilt + squash-stretch).
## VisualRoot — Node3D-обёртка над всеми мешами (Base/Struts/Housing/Orb/
## DrillAssembly), позволяет применять fx-transform к одной ноде, не трогая
## каждый mesh-child. См. harvester.tscn.
var _motion_fx: SegmentMotionFx = null
var _visual_root: Node3D = null
var _visual_base_y: float = 0.0
var _visual_base_basis: Basis = Basis()


func _ready() -> void:
	add_to_group(HARVESTER_GROUP)
	if not drill_node_path.is_empty():
		_drill = get_node_or_null(drill_node_path) as Node3D
	if not harvest_particles_path.is_empty():
		_harvest_particles = get_node_or_null(harvest_particles_path) as GPUParticles3D
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_base_y = _visual_root.position.y
		_visual_base_basis = _visual_root.basis
		_motion_fx = SegmentMotionFx.new()
		# Harvester крупнее палаток — bob чуть мощнее, частота ниже (как
		# тяжёлая машина шагает реже).
		_motion_fx.bob_amplitude = 0.09
		_motion_fx.bob_frequency = 2.0
		_motion_fx.stretch_factor = 0.06
		_motion_fx.reset(global_position)
	_apply_visual_state()


## Camp передаёт ссылку на свою экономику. Без неё gold-tick — no-op
## (Harvester не падает, просто не зачисляет).
func bind_economy(economy: CampEconomy) -> void:
	_economy = economy


func is_deployed() -> bool:
	return _state == State.DEPLOYED


## Camp включает/выключает добычу по числу установленных генераторов (нужно 4).
## Пока выключен — харвестер развёрнут, но не качает золото и не крутит бур.
var _running: bool = false

func set_running(value: bool) -> void:
	if _running == value:
		return
	_running = value
	if _harvest_particles != null:
		_harvest_particles.emitting = _running and _state == State.DEPLOYED


## Camp зовёт при развёртке. Anchor — позиция POI (= центр кольца палаток).
## Harvester телепортируется на anchor (внутри ring'а палаток он визуально
## по центру). Идемпотентно.
func deploy_on(anchor: Vector3) -> void:
	global_position = anchor
	if _state == State.DEPLOYED:
		return
	_state = State.DEPLOYED
	_reset_motion_visuals()
	_apply_visual_state()
	deployed.emit()


## Camp зовёт при свёртке. Harvester возвращается в IN_CARAVAN — двигаться
## дальше будет уже логика caravan-follow в Camp'е. Идемпотентно.
func pack_to_caravan() -> void:
	if _state == State.IN_CARAVAN:
		return
	_state = State.IN_CARAVAN
	_gold_accumulator = 0.0
	_reset_motion_visuals()
	_apply_visual_state()
	packed.emit()


## Сбрасывает motion-fx state и нейтрализует VisualRoot — нужно после
## телепорта (deploy/pack), иначе first tick посчитает огромную скорость
## и Harvester «лягнётся».
func _reset_motion_visuals() -> void:
	if _motion_fx != null:
		_motion_fx.reset(global_position)
	if _visual_root != null:
		_visual_root.position.y = _visual_base_y
		_visual_root.basis = _visual_base_basis


func _process(delta: float) -> void:
	# Motion-fx работает в IN_CARAVAN (двигается за tower'ом). В DEPLOYED
	# Harvester стоит — fx гасится естественно (low speed → speed_norm ≈ 0).
	if _motion_fx != null and _visual_root != null and _state == State.IN_CARAVAN:
		var fx: Dictionary = _motion_fx.tick(global_position, delta)
		_visual_root.position.y = _visual_base_y + (fx["bob_y"] as float)
		_visual_root.basis = _visual_base_basis * (fx["basis"] as Basis)
	if _state != State.DEPLOYED:
		return
	# Харвестер запускается только когда установлены все генераторы (Camp дёргает
	# set_running по числу генераторов в гриде). Без них — стоит, золото не качает.
	if not _running:
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
		_harvest_particles.emitting = (_state == State.DEPLOYED) and _running
