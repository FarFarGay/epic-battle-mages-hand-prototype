class_name Hand
extends Node3D
## Гигантская рука — координатор. Курсор мыши = позиция руки в мире.
## Действия делятся на две категории, каждая в собственном подузле:
##   - PhysicalActions (Node, hand_physical.gd) — физика: захват, бросок, магнит, подсветка.
##   - SpellActions (Node, hand_spell.gd) — заклинания (Fireball и др).
##
## **Активная категория** (`active_category`) определяет, кто из подмодулей
## реагирует на ввод. Переключается через equip-биндинги: клавиши 1/2
## ставят PHYSICAL (Slam/Flick), 3 — MAGIC (Fireball). Сами equip-биндинги
## слушают оба подмодуля — переключаются всегда. Остальной ввод (LMB grab,
## RMB ability) обрабатывает только активная категория.
##
## Сама Hand отвечает только за:
##   - позиционирование под курсором с учётом высоты поверхности (raycast по физике),
##   - сглаженный трекинг скорости,
##   - хранение active_category и нотификацию при смене,
##   - проксирование сигналов категорий наружу для совместимости.

## SUPER — режим «великой силы». Активен пока HandSuper координатор ведёт
## QTE-паттерн или AIMING. Hand_physical и hand_spell ввод в этом режиме
## игнорируют (их раннее `if active_category != X: return` срабатывает).
##
## SQUAD_AIM — режим прицеливания команды «Идти сюда» для отряда. HandSquadAim
## координатор перехватывает ПКМ для подтверждения цели. Все остальные
## категории также гасятся.
enum Category { PHYSICAL, MAGIC, SUPER, SQUAD_AIM, BUILD_AIM, DASH_AIM }

const HAND_GROUP := &"hand"
## Группа Node3D-объектов с публичным `set_highlighted(bool)`, которые
## подсвечиваются при наведении курсора руки (hover). Используется для
## non-Grabbable pickup-объектов: колокол (relocate), будущие постройки и
## интерактивные предметы. Grabbable RigidBody3D имеют свою подсветку
## через [HandPhysicalActions._update_candidate_highlight] (overlap-based, не
## дистанция-от-курсора) — там сохраняется текущая семантика «рука рядом
## с предметом». Здесь — «курсор рядом с объектом».
const PICKUP_HIGHLIGHT_GROUP := &"pickup_highlight"
## Радиус hover-highlight'а для PICKUP_HIGHLIGHT_GROUP. Игроку комфортно —
## не нужно попадать пиксель-в-пиксель.
const PICKUP_HIGHLIGHT_RADIUS: float = 1.5

signal grabbed(item: Node3D)
signal released(item: Node3D, velocity: Vector3)
## Категория сменилась. Слушают подмодули, чтобы корректно реагировать —
## например, PhysicalActions роняет удержанный предмет на смене на MAGIC.
signal category_changed(new_category: Category)

const VELOCITY_HISTORY_FRAMES := 6
const RAY_DISTANCE := 1000.0

@export var hand_height: float = 2.5
## По каким слоям raycast поднимает руку. По умолчанию — Layers.MASK_HAND_CURSOR
## (Terrain + Items + MountedModule = 67). Actors/Enemies/Projectiles исключены —
## иначе рука прыгала бы на врагов и снаряды.
##
## Динамика: пока в руке держится CampModule (несём турель ставить на башню),
## в маску добавляется ACTORS на лету — иначе курсор не «ловит» верх башни,
## hand остаётся на полу, и поставить модуль на слот нечем.
@export_flags_3d_physics var cursor_raycast_mask: int = Layers.MASK_HAND_CURSOR  # 67
@export var debug_log: bool = true

@onready var _grab_area: Area3D = $GrabArea
@onready var _magnet_area: Area3D = $MagnetArea
@onready var physical_actions: HandPhysicalActions = $PhysicalActions
@onready var spell_actions: HandSpell = $SpellActions
@onready var super_actions: HandSuper = $SuperActions
@onready var squad_aim: HandSquadAim = $SquadAim
@onready var build_aim: HandBuildAim = $BuildAim

var _velocity_history: Array[Vector3] = []
var _previous_pos: Vector3
var _initialized: bool = false
var _last_surface_label: String = ""
## Активная категория ввода. MAGIC по умолчанию (старт с фаербола): Хлоп/Щелб
## убраны из арсенала, PHYSICAL как режим больше не выбирается. Захват предметов
## работает в любой категории (ЛКМ), поэтому отдельная PHYSICAL-категория не нужна.
var active_category: Category = Category.MAGIC
## Стек предыдущих категорий для [push_category]/[pop_category]. Координаторы
## (Super/SquadAim/BuildAim) запоминают, в какой категории была рука перед их
## активацией, и возвращают её на завершении. Раньше каждый координатор хранил
## свою `_pre_*_category` — три параллельных хранилища, на вложенных aim'ах
## (теоретически: build → super) одно могло перетереть другое.
var _category_stack: Array[Category] = []
## Флаг активного UI-drag'а из action-bar'а. GameplayHud выставляет true на
## start_drag и false на finish. Hand учитывает в `is_pointer_over_ui` —
## пока тащим карту, ВСЕ мирные действия (grab, magnet, slam, cast) заблокированы.
var ui_drag_active: bool = false
# Если true — Hand не перетаскивает позицию под курсор. Используется
# подмодулями, когда им нужно временно держать руку в собственном месте
# (например, PhysicalActions при щелбане крутит руку вокруг цели).
# Cursor world-position продолжает обновляться независимо от lock'а,
# чтобы подмодуль мог им рулить (например, читать угол через cursor_world_position()).
var _position_locked: bool = false
var _last_cursor_world: Vector3 = Vector3.ZERO
# Подмодули регистрируют здесь Callable, которые возвращают Array[RID] —
# объекты, исключаемые из террейн-raycast'а. Так Hand не лезет в кишки
# подмодулей через has_method/duck-typing.
var _raycast_excluders: Array[Callable] = []


func _ready() -> void:
	add_to_group(HAND_GROUP)
	_last_cursor_world = global_position
	# Прокидываем сигналы физического подмодуля наверх — внешние слушатели
	# могут подключаться к hand.grabbed / hand.released как раньше.
	physical_actions.grabbed.connect(grabbed.emit)
	physical_actions.released.connect(released.emit)
	# Заглушка spells: разрешаем ей работать через явный setup, не через get_parent.
	spell_actions.setup(self)
	# SUPER — третья ось ввода. setup нужен только чтобы подмодуль получил
	# ссылку на руку (cursor_world_position, is_holding, set_active_category).
	super_actions.setup(self)
	# SQUAD_AIM — четвёртая ось (команда отряду «Идти сюда»).
	squad_aim.setup(self)
	# BUILD_AIM — пятая ось (интерактивное размещение построек: колокол и т.д.).
	build_aim.setup(self)
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	grabbed.connect(func(item: Node3D) -> void: EventBus.hand_grabbed.emit(item))
	released.connect(func(item: Node3D, velocity: Vector3) -> void: EventBus.hand_released.emit(item, velocity))


func _process(delta: float) -> void:
	_update_cursor_world()
	if not _position_locked:
		global_position = _last_cursor_world
	_track_velocity(delta)
	_update_pickup_highlight()


## Сканер hover-подсветки для всех Node3D в [PICKUP_HIGHLIGHT_GROUP]. Один
## ближайший к курсору (в радиусе [PICKUP_HIGHLIGHT_RADIUS]) зажигается через
## `set_highlighted(true)`, остальные гасятся. Активен только в PHYSICAL при
## свободной руке и без активного aim'а (build/squad/super). Любой новый
## pickup-объект (рычаг, ящик-с-action, и т.д.) автоматически работает —
## достаточно `add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)` и метода
## `set_highlighted(bool)`.
func _update_pickup_highlight() -> void:
	# Захват — в любой боевой категории (ЛКМ), кроме aim-takeover (super/squad/build)
	# и пока что-то держим. Раньше гейтилось по PHYSICAL — теперь PHYSICAL не
	# выбирается, а pickup'ы (рычаг/ящик/колокол) должны подсвечиваться и в MAGIC.
	var allow: bool = not is_in_aim_mode() and not is_holding()
	if allow and build_aim != null and build_aim.is_aiming_any():
		allow = false
	if not allow:
		for n in get_tree().get_nodes_in_group(PICKUP_HIGHLIGHT_GROUP):
			if is_instance_valid(n) and n.has_method(&"set_highlighted"):
				n.set_highlighted(false)
		return
	var cursor: Vector3 = _last_cursor_world
	cursor.y -= hand_height
	var r_sq: float = PICKUP_HIGHLIGHT_RADIUS * PICKUP_HIGHLIGHT_RADIUS
	var hovered: Node3D = null
	var best_sq: float = r_sq
	for n in get_tree().get_nodes_in_group(PICKUP_HIGHLIGHT_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var dx: float = node.global_position.x - cursor.x
		var dz: float = node.global_position.z - cursor.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq <= best_sq:
			best_sq = d_sq
			hovered = node
	for n in get_tree().get_nodes_in_group(PICKUP_HIGHLIGHT_GROUP):
		if is_instance_valid(n) and n.has_method(&"set_highlighted"):
			n.set_highlighted(n == hovered)


# --- Публичный API для подмодулей ---

func lock_position(locked: bool) -> void:
	_position_locked = locked


## True если в руке сейчас есть удерживаемый предмет (grab активен).
## Используется HandPhysicalActions и HandSpell как guard на ПКМ —
## пока что-то держим, никакие активные действия (Slam/Flick/Fireball)
## не триггерятся.
func is_holding() -> bool:
	return physical_actions != null and physical_actions.is_holding()


## Программно вложить тело в руку (меню постройки спавнит здание прямо в руку).
func hold_item(body: RigidBody3D) -> void:
	if physical_actions != null:
		physical_actions.hold(body)


## Снять держимое из руки БЕЗ установки (выход из стройки по j) — без impulse и
## без `released`-сигнала. См. HandPhysicalActions.clear_held.
func clear_held() -> void:
	if physical_actions != null:
		physical_actions.clear_held()


## True если рука сейчас в одной из «aim-takeover» категорий, где
## input принадлежит специальному координатору (Super QTE, SquadAim,
## BuildAim). Используется hand_physical/hand_spell для гейта своего
## _handle_input — equip и cast не должны срываться в эти моменты.
## HandSuper'у этот helper не подходит (когда сам Super активен,
## hand_super._handle_input должен работать) — там inline-проверка
## {SQUAD_AIM, BUILD_AIM} без SUPER.
func is_in_aim_mode() -> bool:
	return active_category == Category.SUPER \
			or active_category == Category.SQUAD_AIM \
			or active_category == Category.BUILD_AIM \
			or active_category == Category.DASH_AIM


## Переключает активную категорию ввода. Идемпотентно. Эмитит category_changed,
## на который PhysicalActions подписан (роняет удержанный предмет при уходе
## из PHYSICAL — иначе игрок переключился на магию, а в руке торчит ящик).
func set_active_category(category: Category) -> void:
	if active_category == category:
		return
	active_category = category
	if debug_log and LogConfig.master_enabled:
		print("[Hand] категория: %s" % Category.keys()[category])
	category_changed.emit(category)


## Push current category onto stack and switch to `category`. Если рука уже
## в `category` — стек не растёт (no-op). Используется временными координаторами
## (Super, SquadAim, BuildAim) — на завершении они зовут [pop_category],
## который вернёт ту категорию, что была до них.
##
## Защита от вложенных push'ей одного и того же cat'а делает pop сбалансированным
## даже если координатор «случайно» дёрнул push дважды.
func push_category(category: Category) -> void:
	if active_category == category:
		return
	_category_stack.push_back(active_category)
	set_active_category(category)


## Возвращает категорию, сохранённую [push_category]. Если стек пуст —
## fallback на PHYSICAL (на старте/после рестарта мы туда же и возвращаемся).
func pop_category() -> void:
	var prev: Category = Category.PHYSICAL
	if not _category_stack.is_empty():
		prev = _category_stack.pop_back()
	set_active_category(prev)


func cursor_world_position() -> Vector3:
	return _last_cursor_world


## True если курсор сейчас над non-IGNORE Control'ом (UI ловит/наблюдает мышь).
## Подмодули вызывают, чтобы не стартовать новые мышинные действия (LMB grab,
## ПКМ ability/spell/squad-commit) поверх UI: иначе клик по кнопке HUD'а
## параллельно хватал бы предмет под виджетом. Клавиатурные хоткеи (equip
## 1/2/3) гейтить НЕ надо — они работают и над UI.
##
## Уже-активные действия (магнит на удерживаемом, hold-state Flick'а)
## продолжаются независимо: гейт срабатывает только на START-нажатии.
##
## ui_drag_active (HUD выставляет true пока тащит action-slot) принудительно
## возвращает true — иначе при движении ghost-карты за курсором вне области
## слотов pointer_over_ui становится false и Hand начинает магнитить ящики.
func is_pointer_over_ui() -> bool:
	if ui_drag_active:
		return true
	var hovered: Control = get_viewport().gui_get_hovered_control()
	return hovered != null


## Прямой сеттер позиции при locked-режиме. Используется подмодулями (Flick),
## которым нужно крутить руку вокруг цели, не разлочивая позицию.
func set_locked_position(pos: Vector3) -> void:
	assert(_position_locked, "set_locked_position требует _position_locked=true")
	global_position = pos


func register_raycast_excluder(provider: Callable) -> void:
	## provider должен возвращать Array[RID] — кого ИСКЛЮЧИТЬ из raycast террейна.
	_raycast_excluders.append(provider)


func smoothed_velocity() -> Vector3:
	if _velocity_history.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for v in _velocity_history:
		sum += v
	return sum / _velocity_history.size()


## Все тела сейчас в зоне захвата (для подмодулей-кандидатов).
func get_grabbable_bodies() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for body in _grab_area.get_overlapping_bodies():
		if body is Node3D:
			out.append(body as Node3D)
	return out


## Все тела сейчас в магнит-зоне.
func get_magnet_bodies() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for body in _magnet_area.get_overlapping_bodies():
		if body is Node3D:
			out.append(body as Node3D)
	return out


# --- Реализация позиционирования ---

func _update_cursor_world() -> void:
	# Считается каждый кадр, ВКЛЮЧАЯ моменты, когда _position_locked = true.
	# Подмодули (PhysicalActions при щелбане) читают результат через
	# cursor_world_position() — например, чтобы крутить руку вокруг цели по курсору.
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	# Этап 1: raycast'ом узнаём Y поверхности под курсором.
	# Удерживаемый предмет (если PhysicalActions что-то держит) исключаем —
	# иначе рука бесконечно «уезжает» от собственного захваченного ящика.
	var result := _raycast_terrain(ray_origin, ray_dir)
	var surface_y: float = 0.0
	if not result.is_empty():
		surface_y = (result.position as Vector3).y

	# Этап 2: точка на луче камеры на высоте surface_y + hand_height.
	# Только это даёт визуальное соответствие пиксельного курсора и руки.
	var plane := Plane(Vector3.UP, surface_y + hand_height)
	var plane_hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if plane_hit != null:
		_last_cursor_world = plane_hit

	if debug_log and LogConfig.master_enabled:
		_log_surface(result, surface_y)


func _raycast_terrain(origin: Vector3, dir: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_DISTANCE)
	# Базовая маска + временный ACTORS, если несём CampModule — чтобы курсор
	# над башней позиционировал руку на её верхушку, а не сквозь неё на пол.
	var mask := cursor_raycast_mask
	if _is_carrying_module():
		mask |= Layers.ACTORS
	query.collision_mask = mask
	var excluded: Array[RID] = []
	for provider in _raycast_excluders:
		var rids = provider.call()
		if rids is Array:
			for rid in rids:
				excluded.append(rid)
	if not excluded.is_empty():
		query.exclude = excluded
	return space.intersect_ray(query)


## True если рука сейчас держит CampModule (для динамической раскладки маски
## курсора). Не зависит от наличия PhysicalActions — null-safe.
func _is_carrying_module() -> bool:
	if physical_actions == null:
		return false
	var held := physical_actions.get_held_item()
	return held != null and held is CampModule


func _track_velocity(delta: float) -> void:
	if not _initialized:
		_previous_pos = global_position
		_initialized = true
		return
	if delta <= 0.0:
		return
	# Пока позиция залочена, подмодули могут двигать руку напрямую (Flick) —
	# эти движения не должны попасть в smoothed_velocity, иначе при отпускании
	# щелбана накопится бредовая скорость броска.
	if _position_locked:
		_previous_pos = global_position
		return
	var instant_v: Vector3 = (global_position - _previous_pos) / delta
	_velocity_history.append(instant_v)
	if _velocity_history.size() > VELOCITY_HISTORY_FRAMES:
		_velocity_history.pop_front()
	_previous_pos = global_position


# --- Логирование ---

func _log_surface(result: Dictionary, surface_y: float) -> void:
	var label: String
	if result.is_empty():
		label = "(none)"
	else:
		var collider = result.collider
		var n := str(collider.name) if collider else "?"
		var layer_bits: int = 0
		if collider and "collision_layer" in collider:
			layer_bits = collider.collision_layer
		label = "%s [%s]" % [n, Layers.layer_name_for_bits(layer_bits)]
	if label != _last_surface_label:
		print("[Hand] поверхность: %s, y=%.2f" % [label, surface_y])
		_last_surface_label = label
