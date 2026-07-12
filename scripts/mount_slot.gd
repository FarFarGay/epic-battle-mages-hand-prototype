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
##
## ГРУЗ (2026-07-08, «верх башни = инвентарь»): слот дополнительно паркует
## любой grabbable-RigidBody из группы tower_cargo (артефакты вылазок:
## свиток/клад, минный заряд с верфи) — предмет едет на верхушке, руки
## свободны для боя. Снять — схватить рукой (слой MOUNTED_MODULE в grab-маске).
## Груз, вышедший из группы (ArtifactElement всосался в приёмник прямо
## с борта, MineCharge потрачен залпом), слот отпускает сам. Один груз за раз.

## Где сидит модуль относительно слота. Y > 0 — стоит «над» слотом, чтобы
## база не просвечивалась мешем модуля.
@export var module_offset: Vector3 = Vector3(0, 0.0, 0)
## Максимальное горизонтальное расстояние от модуля до слота, при котором
## релиз засчитывается как монтаж. Чем больше — тем «прилипчивее» слот,
## но риск перехвата чужих модулей.
@export var snap_radius: float = 1.5
## Выравнивать поворот модуля по слоту (модуль наследует global_rotation слота).
## Октагон-кольцо включает это, чтобы блоки-сегменты вставали гранью наружу и
## смыкались в кольцо построек. По умолчанию выкл — центральный слот не вращает
## модуль (турель радиально-симметрична, поворот ей не нужен).
@export var align_rotation: bool = false
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
## Радиус посадки ГРУЗА (XZ до слота): предмет отпущен рукой у подножия башни.
@export var cargo_snap_radius: float = 2.5

const CARGO_GROUP := &"tower_cargo"

var _mounted: CampModule = null
var _cargo: RigidBody3D = null


func _ready() -> void:
	add_to_group(&"tower_top_slot")
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


## Крыша занята грузом? (эксклюзив с турелью — HarpoonModule спрашивает).
func has_cargo() -> bool:
	return _cargo != null


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
	# Груз сняли с верхушки — рука владеет (слой/freeze предмет чинит сам).
	# Маркер «на борту» снимаем СРАЗУ: по нему живут гейты (минный залп —
	# MineCharge.mounted_on_tower), схваченный груз бортом не считается.
	if _cargo != null and item == _cargo:
		_cargo.remove_from_group(CARGO_GROUP)
		_cargo = null


func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if not enabled or _mounted != null:
		return
	if not (item is CampModule):
		_try_park_cargo(item)
		return
	var module := item as CampModule
	if module.is_mounted():
		# Уже сел в чей-то другой слот в этом же тике — пропускаем.
		return
	var dist := _horizontal_distance(module.global_position)
	if dist > snap_radius:
		return
	_mount(module)


# --- Груз («верх башни = инвентарь») ---

## Попытка парковки груза: ЛЮБОЙ свободный grabbable-RigidBody (юзер
## 2026-07-08: «на крышу можно всё, что берёт рука») кроме исключений:
## мост-доска (haul, волочится), модули со своим монтажом. frozen = уже
## где-то сидит (сокет/гном/чужой слот) — не трогаем.
func _try_park_cargo(item: Node3D) -> void:
	var rb := item as RigidBody3D
	if rb == null or rb.freeze or not Grabbable.is_grabbable(rb):
		return
	if rb.is_in_group(Layers.HAND_HAUL_GROUP) or rb is CampModule or rb is HarpoonModule:
		return
	if _horizontal_distance(rb.global_position) > cargo_snap_radius:
		return
	if _cargo != null or get_tree().get_first_node_in_group(HarpoonModule.MOUNTED_GROUP) != null:
		EventBus.tutorial_hint.emit("⚠ Крыша башни занята — сними старый груз рукой", 4.0)
		return
	_cargo = rb
	rb.add_to_group(CARGO_GROUP)  # маркер «на борту»; артефакт снимает его при доставке
	rb.freeze = true
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	rb.collision_layer = Layers.MOUNTED_MODULE
	rb.global_position = global_position + module_offset
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, rb.global_position, 0.9, 8.0)
	EventBus.tutorial_hint.emit("📦 Груз на верхушке башни — поехали. Снять: схвати рукой", 4.0)
	if debug_log and LogConfig.master_enabled:
		print("[MountSlot:%s] груз на борту: %s" % [name, rb.name])


## Пин груза + авто-отпуск: предмет вышел из группы (всосался в здание) или умер.
func _tick_cargo() -> void:
	if _cargo == null:
		return
	if not is_instance_valid(_cargo) or not _cargo.is_in_group(CARGO_GROUP):
		_cargo = null
		return
	_cargo.global_position = global_position + module_offset


# --- Mount/unmount ---

func _mount(module: CampModule) -> void:
	# Защёлка ДО attach_to_slot: re-entrance-защита если внутри attach
	# случится переэмит сигналов (mounted/unmounted) и слушатели
	# вернутся в _on_hand_released текущего слота — _mounted уже занят,
	# повторный _mount вернётся через гард в начале _on_hand_released.
	_mounted = module
	# Подписка на module.unmounted: если модуль перехватит другой слот
	# (вызовет attach_to_slot со своим self → unmounted старого слота),
	# наш _mounted станет зомби-ссылкой. Однократная подписка с oneshot —
	# сама отвалится на любом detach (включая release_to_hand).
	if not module.unmounted.is_connected(_on_module_force_detached):
		module.unmounted.connect(_on_module_force_detached, CONNECT_ONE_SHOT)
	module.attach_to_slot(self)
	module.global_position = global_position + module_offset + Vector3(0.0, module.mount_lift, 0.0)
	if align_rotation:
		module.global_rotation = global_rotation
	if debug_log and LogConfig.master_enabled:
		print("[MountSlot:%s] монтаж: %s" % [name, module.name])


## Защита от стейл-ссылки _mounted: если модуль был перехвачен другим слотом
## (через attach_to_slot, который в CampModule безусловно сменит _slot и
## эмитит unmounted старого слота), мы получаем сигнал и чистим _mounted.
## Без этого слот думал бы что владеет модулем, а module.get_slot() указывает
## на чужой — следующий _drop_mounted/_release_to_hand работал бы с фантомом.
func _on_module_force_detached(_old_slot: Node) -> void:
	# Сигнал может прилететь на нашу же _release_to_hand/_drop_mounted —
	# в этом случае _mounted уже null, ничего не делаем. Если же это
	# чужой слот — сбрасываем зомби-ссылку.
	if _mounted == null:
		return
	# get_slot() вернёт нового владельца (или null) — если не мы, обнуляем.
	if _mounted.get_slot() != self:
		var old := _mounted
		_mounted = null
		if debug_log and LogConfig.master_enabled:
			print("[MountSlot:%s] зомби-detach: модуль перехвачен другим слотом" % name)


## Размонтаж по факту захвата рукой. Hand уже владеет freeze (выставил true
## в _attach), мы только освобождаем ссылку.
func _release_to_hand() -> void:
	if _mounted == null:
		return
	var old := _mounted
	_mounted = null
	old.detach_from_slot()
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
	if debug_log and LogConfig.master_enabled:
		print("[MountSlot:%s] размонтаж (drop): %s" % [name, old.name])


# --- Цикл ---

func _physics_process(_delta: float) -> void:
	_tick_cargo()
	if _mounted == null:
		return
	# Жёстко прибиваем модуль к слоту. Слот может двигаться (Tower едет, Camp
	# обновляет deploy_anchor) — модуль следует синхронно. RigidBody с freeze=true
	# позволяет писать в global_position без интегратора.
	_mounted.global_position = global_position + module_offset + Vector3(0.0, _mounted.mount_lift, 0.0)
	if align_rotation:
		_mounted.global_rotation = global_rotation


func _horizontal_distance(pos: Vector3) -> float:
	var d := pos - global_position
	d.y = 0.0
	return d.length()
