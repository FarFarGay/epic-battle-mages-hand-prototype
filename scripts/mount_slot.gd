class_name MountSlot
extends Node3D
## Точка монтажа модуля (`CampModule`). Кладётся как ребёнок Tower'а или
## управляется Camp'ом (позиция = deploy_anchor). Пока слот `enabled`, при
## релизе модуля рукой в радиусе `snap_radius` он защёлкивается в слот:
## модуль становится freeze=true, позиция следует за слотом каждый физкадр,
## и модуль начинает работу через `_on_mounted`.
##
## Слот сам слушает EventBus:
##   - `hand_released(item, velocity)` — попытка монтажа.
##   - `hand_grabbed(item)` — если игрок схватил наш модуль, отпускаем его
##     (модуль становится свободным, Hand его уже держит).
##
## Можно положить несколько слотов в проекте. Каждый — независим, конфликтов
## за один и тот же модуль нет (на release модуль монтируется в первый слот,
## который успел его засчитать).

signal module_attached(module: Node)
signal module_detached(module: Node)

## Где сидит модуль относительно слота. Y > 0 — стоит «над» слотом, чтобы
## база не просвечивалась мешем модуля.
@export var module_offset: Vector3 = Vector3(0, 0.0, 0)
## Максимальное горизонтальное расстояние от модуля до слота, при котором
## релиз засчитывается как монтаж. Чем больше — тем «прилипчивее» слот,
## но риск перехвата чужих модулей.
@export var snap_radius: float = 1.5
## Слот активен. Camp'у нужно отключать слот в фазе CARAVAN_FOLLOWING — там
## нет «центра» лагеря. Если слот выключают с занятым модулем — модуль
## принудительно сбрасывается на землю (freeze=false, гравитация).
@export var enabled: bool = true:
	set(value):
		if enabled == value:
			return
		enabled = value
		if not enabled and _mounted:
			_drop_mounted()
@export var debug_log: bool = true

var _mounted: CampModule = null


func _ready() -> void:
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)
	# Re-emit на глобальный EventBus — слушатели UI/звука/логики апгрейдов
	# подписываются один раз, не зная о конкретных слотах.
	module_attached.connect(func(m: Node) -> void: EventBus.module_mounted.emit(m, self))
	module_detached.connect(func(m: Node) -> void: EventBus.module_unmounted.emit(m, self))


func is_occupied() -> bool:
	return _mounted != null


func get_mounted() -> CampModule:
	return _mounted


# --- EventBus listeners ---

func _on_hand_grabbed(item: Node3D) -> void:
	# Игрок забрал наш модуль из слота — освобождаем место. freeze не трогаем:
	# Hand уже выставил freeze=true в _attach и владеет модулем до релиза.
	if _mounted != null and item == _mounted:
		_release_to_hand()


func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if not enabled or _mounted != null:
		return
	if not (item is CampModule):
		return
	var module := item as CampModule
	if module.is_mounted():
		# Уже сел в чей-то другой слот в этом же тике — пропускаем.
		return
	var dist := _horizontal_distance(module.global_position)
	if dist > snap_radius:
		return
	_mount(module)


# --- Mount/unmount ---

func _mount(module: CampModule) -> void:
	_mounted = module
	module.attach_to_slot(self)
	module.global_position = global_position + module_offset
	module_attached.emit(module)
	if debug_log and LogConfig.master_enabled:
		print("[MountSlot:%s] монтаж: %s" % [name, module.name])


## Размонтаж по факту захвата рукой. Hand уже владеет freeze (выставил true
## в _attach), мы только освобождаем ссылку.
func _release_to_hand() -> void:
	if _mounted == null:
		return
	var old := _mounted
	_mounted = null
	old.detach_from_slot()
	module_detached.emit(old)
	if debug_log and LogConfig.master_enabled:
		print("[MountSlot:%s] размонтаж (хват): %s" % [name, old.name])


## Принудительное размонтирование (слот выключен). Модуль становится
## свободным RigidBody с freeze=false и падает по гравитации.
func _drop_mounted() -> void:
	if _mounted == null:
		return
	var old := _mounted
	_mounted = null
	old.detach_from_slot()
	old.freeze = false
	module_detached.emit(old)
	if debug_log and LogConfig.master_enabled:
		print("[MountSlot:%s] размонтаж (drop): %s" % [name, old.name])


# --- Цикл ---

func _physics_process(_delta: float) -> void:
	if _mounted == null:
		return
	# Жёстко прибиваем модуль к слоту. Слот может двигаться (Tower едет, Camp
	# обновляет deploy_anchor) — модуль следует синхронно. RigidBody с freeze=true
	# позволяет писать в global_position без интегратора.
	_mounted.global_position = global_position + module_offset


func _horizontal_distance(pos: Vector3) -> float:
	var d := pos - global_position
	d.y = 0.0
	return d.length()
