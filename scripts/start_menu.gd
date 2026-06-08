class_name StartMenu
extends CanvasLayer
## Меню старта матча. Чёрная полупрозрачная заслонка с двумя кнопками
## «Начать игру» / «Закрыть». Открывается/закрывается Esc.
##
## Esc-поведение трёхступенчатое:
##   1. Меню открыто → Esc закрывает.
##   2. Меню закрыто, рука в aim-режиме (SQUAD_AIM / BUILD_AIM / SUPER) →
##      Esc уходит в aim-координаторы, меню НЕ открывается. Игрок ожидает
##      что Esc отменит aim, а не выкинет в меню.
##   3. Иначе → Esc открывает меню.
##
## «Начать игру» — выбирает новые случайные позиции для Tower и POI вне
## DungeonZone и вне зоны видимости башни, кладёт в [MatchConfig] и
## перезагружает текущую сцену. Гарантирует полностью чистый старт (враги,
## орбы, squad'ы, прогресс — всё с нуля) без точечной зачистки runtime-state.
##
## «Закрыть» — просто скрывает оверлей.

const GROUP := &"start_menu"

## Половина играбельной зоны для спавна POI и Tower. Карта 300×300 (MAP_HALF=150),
## но края выглядят пустынно — спавн в 120-радиусе вокруг центра. Плюс 8м
## safety-margin'а отступает от каждой стороны.
const PLAY_HALF: float = 120.0

## Минимальная дистанция между POI и Tower. Tower vision = 20м (FogOfWar.
## VISION_RADIUS_TOWER); POI должен быть ВНЕ видимости + запас, чтобы игрок
## реально шёл его искать. 60м даёт ~3 сек пешком гному.
const MIN_POI_TOWER_DISTANCE: float = 60.0

## Минимальная дистанция Gate до Tower и POI. Tower не должен пройти ворота
## случайно сразу при старте (gate ≥ 40м от tower); и Gate не должен ставиться
## впритык к POI (gate ≥ 25м), чтобы он визуально читался отдельной целью,
## а не «дополнением» к костру.
const MIN_GATE_DISTANCE: float = 40.0

## Safety-margin вокруг bounds подземелья — POI и Tower не должны попадать
## ни в зону, ни вплотную к ней (чтобы скелетов на этапах рядом не валило).
const DUNGEON_MARGIN: float = 8.0

## Максимум попыток подобрать случайную точку прежде чем сдаться (и плюнуть
## в центр карты с предупреждением). На разумной карте 30 попыток с большим
## запасом.
const MAX_PLACEMENT_ATTEMPTS: int = 30

@onready var _panel: Control = $Root
@onready var _btn_start: Button = $Root/Panel/VBox/StartButton
@onready var _btn_close: Button = $Root/Panel/VBox/CloseButton


func _ready() -> void:
	add_to_group(GROUP)
	# Меню паузы работает НА ПАУЗЕ: открытие ставит get_tree().paused, поэтому
	# само меню должно продолжать ловить Esc/клики (иначе не закроешь).
	process_mode = Node.PROCESS_MODE_ALWAYS
	# По умолчанию меню скрыто — игрок видит игровое поле, открывает Esc'ом.
	_panel.visible = false
	# Сами кнопки забирают input (mouse_filter STOP), и только при visible.
	_btn_start.pressed.connect(_on_start_pressed)
	_btn_close.pressed.connect(_on_close_pressed)


func is_open() -> bool:
	return _panel != null and _panel.visible


## Открыть меню = поставить игру на паузу (Esc). Игра замирает за оверлеем.
func open() -> void:
	_panel.visible = true
	get_tree().paused = true
	# Фокус на «Начать игру» — позволяет Enter подтвердить без клика.
	_btn_start.grab_focus()


## Закрыть меню = снять паузу и продолжить игру.
func close() -> void:
	_panel.visible = false
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if is_open():
		close()
		get_viewport().set_input_as_handled()
		return
	# Матч окончен (победа/поражение) — Esc не открывает меню паузы поверх
	# финального оверлея (у того своя кнопка «Новая партия»).
	if _match_over():
		return
	# Когда aim активен — пропускаем Esc дальше, hand_squad_aim/hand_build_aim
	# сами поллят ui_cancel в _process и отменят aim. Меню НЕ открываем —
	# иначе игрок ожидал отмены aim'а, а получил оверлей поверх отменённого.
	var hand: Hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if hand != null and hand.is_in_aim_mode():
		return
	open()
	get_viewport().set_input_as_handled()


## True если показан финальный оверлей (победа/поражение) — тогда Esc-меню паузы
## не нужно. Проверяем оба по группам (узлы CanvasLayer с .visible-полем Root).
func _match_over() -> bool:
	for group in [&"win_overlay", &"defeat_overlay"]:
		var node := get_tree().get_first_node_in_group(group)
		if node != null and node.has_method("is_showing") and node.is_showing():
			return true
	return false


func _on_start_pressed() -> void:
	restart_match()


func _on_close_pressed() -> void:
	close()


## Выбирает новые позиции для Tower и POI, кладёт в MatchConfig и дергает
## reload_current_scene(). main_setup.gd на корне новой сцены прочитает
## позиции и применит к Tower / Poi_Heart. Все runtime-сущности (враги, орбы,
## squad'ы, прогресс волн, fog) сбрасываются естественно — это перезагрузка.
##
## QuestProgress autoload переживает reload и НЕ обнуляется — сбрасываем
## руками. Это нужно чтобы новый матч начинался с первого квеста.
##
## Публичная — WinOverlay переиспользует на кнопке «Новая партия».
func restart_match() -> void:
	var dungeon_bounds: AABB = _dungeon_bounds_xz()
	var tower_pos: Vector3 = _pick_position_outside_dungeon(dungeon_bounds, [])
	var poi_pos: Vector3 = _pick_position_outside_dungeon(
		dungeon_bounds, [_avoid(tower_pos, MIN_POI_TOWER_DISTANCE)]
	)
	# Gate — далеко от обоих (Tower и POI). Иначе игрок может пройти его
	# случайно при первом шаге или ворота сливаются с костром POI.
	var gate_pos: Vector3 = _pick_position_outside_dungeon(
		dungeon_bounds,
		[
			_avoid(tower_pos, MIN_GATE_DISTANCE),
			_avoid(poi_pos, MIN_GATE_DISTANCE),
		],
	)
	MatchConfig.next_tower_pos = tower_pos
	MatchConfig.next_poi_pos = poi_pos
	MatchConfig.next_gate_pos = gate_pos
	MatchConfig.match_started = true
	QuestProgress.current_index = 0
	# Скрываем оверлей до reload'а — иначе игрок видит чёрный фон долю секунды,
	# пока сцена пересоздаётся.
	close()
	get_tree().reload_current_scene()


## XZ-AABB подземелья в world-coords. Считаем по DungeonZone (если найдём) +
## безопасный margin. Y игнорируется — спавним на земле.
func _dungeon_bounds_xz() -> AABB:
	for d in get_tree().get_nodes_in_group(&"dungeon_zone"):
		if d is DungeonZone:
			return _aabb_from_dungeon(d as DungeonZone)
	# Fallback: ноды нет, разрешаем спавн где угодно. Не должно произойти.
	return AABB(Vector3.ZERO, Vector3.ZERO)


func _aabb_from_dungeon(zone: DungeonZone) -> AABB:
	# DungeonZone.size — локальный размер, Transform внешний может scale'ить.
	# Берём итог через global_transform.basis. По XZ.
	var half_x: float = abs(zone.global_transform.basis.x.x * zone.size.x * 0.5) \
			+ abs(zone.global_transform.basis.z.x * zone.size.z * 0.5)
	var half_z: float = abs(zone.global_transform.basis.x.z * zone.size.x * 0.5) \
			+ abs(zone.global_transform.basis.z.z * zone.size.z * 0.5)
	var c: Vector3 = zone.global_position
	var pos := Vector3(c.x - half_x - DUNGEON_MARGIN, 0.0, c.z - half_z - DUNGEON_MARGIN)
	var sz := Vector3((half_x + DUNGEON_MARGIN) * 2.0, 1.0, (half_z + DUNGEON_MARGIN) * 2.0)
	return AABB(pos, sz)


## Подбирает случайную точку в круге PLAY_HALF, вне dungeon-AABB и (если задан
## avoid_center с ненулевым avoid_radius) вне круга от центра-другой-сущности.
## Если за MAX_PLACEMENT_ATTEMPTS не нашли — возвращает (0, 0) и пишет
## предупреждение в лог: лучше плохой спавн, чем зависание.
## Подбирает случайную точку в круге PLAY_HALF, вне dungeon-AABB и вне
## кругов avoid'ов. avoids — массив Dictionary'ев `{center: Vector3, radius_sq: float}`,
## создаваемый через [_avoid] helper. Пустой массив — фильтрация только
## по dungeon.
func _pick_position_outside_dungeon(dungeon_xz: AABB, avoids: Array) -> Vector3:
	for i in range(MAX_PLACEMENT_ATTEMPTS):
		var angle: float = randf() * TAU
		var radius: float = sqrt(randf()) * PLAY_HALF  # uniform по площади
		var pos := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		if _point_in_xz_aabb(pos, dungeon_xz):
			continue
		var ok: bool = true
		for a in avoids:
			var center: Vector3 = a["center"]
			var r_sq: float = a["radius_sq"]
			var dx: float = pos.x - center.x
			var dz: float = pos.z - center.z
			if dx * dx + dz * dz < r_sq:
				ok = false
				break
		if ok:
			return pos
	push_warning("[StartMenu] не нашли свободную точку за %d попыток — fallback в (0,0)" % MAX_PLACEMENT_ATTEMPTS)
	return Vector3.ZERO


## Helper для составления avoid-dictionary с предкэшированным r².
func _avoid(center: Vector3, radius: float) -> Dictionary:
	return {"center": center, "radius_sq": radius * radius}


func _point_in_xz_aabb(p: Vector3, aabb: AABB) -> bool:
	return p.x >= aabb.position.x and p.x <= aabb.position.x + aabb.size.x \
			and p.z >= aabb.position.z and p.z <= aabb.position.z + aabb.size.z
