class_name OilTank
extends StaticBody3D
## Цистерна — хранит добытую нефть (= счётчик к победе матча). Строится как
## здание ([RoomBuildings.OIL_TANK]); на достройке регистрируется на ближайший
## [OilRig] (пока — авто по радиусу; позже связь пойдёт через ТРУБОПРОВОД), и бур
## гонит добычу сюда через add_oil. Накопила oil_goal → [signal filled] (подключим
## к WinOverlay следующим шагом). Уровень нефти растёт визуально (fill-меш).

const GROUP := &"oil_tank"

signal oil_changed(oil: float, goal: float)
signal filled

@export var oil_goal: float = 100.0
## Меш «уровень нефти» внутри бака — масштабируется по Y от 0 до полного.
@export var fill_path: NodePath = NodePath("Fill")

var _oil: float = 0.0
var _full: bool = false
var _fill: Node3D = null


func _ready() -> void:
	add_to_group(GROUP)
	_fill = get_node_or_null(fill_path) as Node3D
	_update_fill()
	# Связь с буром НЕ автоматическая — её прокладывает ТРУБА ([HandPipeAim] зовёт
	# rig.set_cistern). Без трубы цистерна стоит пустая, добыча не идёт.


## Залить нефть (зовёт OilRig в режиме PUMPING). На oil_goal — filled.
func add_oil(amount: float) -> void:
	if _full or amount <= 0.0:
		return
	_oil = minf(_oil + amount, oil_goal)
	_update_fill()
	oil_changed.emit(_oil, oil_goal)
	if _oil >= oil_goal:
		_full = true
		filled.emit()
		if LogConfig.master_enabled:
			print("[OilTank] ★ ЦИСТЕРНА ПОЛНА (%.0f) — цель добычи достигнута" % oil_goal)


func get_oil() -> float:
	return _oil


func get_goal() -> float:
	return oil_goal


## Уровень нефти в баке: fill-меш растёт по Y от 0 (пусто) до 1 (полно).
func _update_fill() -> void:
	if _fill == null:
		return
	var frac: float = clampf(_oil / maxf(oil_goal, 0.001), 0.0, 1.0)
	_fill.scale.y = maxf(frac, 0.001)
