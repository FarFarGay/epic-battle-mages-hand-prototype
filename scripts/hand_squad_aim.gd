class_name HandSquadAim
extends Node
## Координатор aim-режима для команды отряду «Идти сюда». Ввод ЛКМ при
## активном aim'е считается подтверждением точки — squad получает
## `command_hold(pos)`. Aim **остаётся активным** (sticky) — игрок может
## давать команды point-and-click без возврата в HUD. На точке commit'а
## остаётся затухающий ground-ring как визуальное подтверждение.
##
## ЛКМ — приоритет SquadChargeMarker: если игрок над ready+hovered маркером
## (ult'а отряда), ЛКМ кушает marker (ult'а), не commit. Так одна кнопка
## управляет двумя интеракциями без конфликта — на пустом месте едут,
## на маркере применяют ult'у.
##
## По образцу HandSuper.AIMING_TARGET, но без предшествующего QTE — это
## мгновенный command-targeting. UI (gameplay_hud) запускает через
## `start_aim(squad)`; повторный клик той же squad-кнопки → `cancel_aim()`
## (toggle). Esc — основной способ выхода. Старт aim'а для другого squad'а
## переключает контекст. Уничтожение squad'а во время aim'а автоматически
## завершает режим (guard в _process).
##
## Hand-категория переключается в SQUAD_AIM на время aim'а — все остальные
## ввод-системы (hand_physical / hand_spell / hand_super) гасятся ранним return.

const ACTION_AIM_COMMIT := &"hand_grab"  # ЛКМ — commit точки
const ACTION_AIM_CANCEL := &"ui_cancel"  # Esc — отмена aim'а (Godot-дефолт)

@export_group("Visual")
## Цвет ground-ring'а под курсором когда враги ВНЕ зоны прицеливания.
## Голубой — отличается от золотого aim_indicator'а супер-удара и
## оранжевого warning'а магии.
@export var aim_ring_color: Color = Color(0.4, 0.85, 1.0, 0.9)
## Цвет когда внутри зоны есть враги — красный «опасность здесь, отряд
## пойдёт в бой». Используется как сигнал «это указание цели, не просто
## точки».
@export var aim_ring_color_hostile: Color = Color(1.0, 0.25, 0.25, 0.95)
## Радиус кольца в метрах. Используется и как визуал «куда пойдёт отряд»,
## и как зона сканирования врагов: если в радиусе кольца есть скелет —
## кольцо подсвечивается hostile-цветом.
@export var aim_ring_radius: float = 3.5
## Длительность затухающего ground-ring'а, оставляемого на точке commit'а.
## Подтверждает игроку «команда ушла, отряд идёт сюда» — нужно потому что
## sticky-aim продолжается, и обычный (cursor-ring) сразу уходит за курсором.
@export var commit_marker_duration: float = 0.6
## Цвет КОНТУРА зоны добычи вокруг башни. Голубой — тот же язык «зоны», что и
## у build-зоны лагеря; читается на зелёной траве (зелёный сливался).
@export var gather_zone_color: Color = Color(0.45, 0.75, 1.0, 0.8)
## Цвет ЗАЛИВКИ зоны (диск под контуром) — подсветка площади «здесь рабочие
## могут добывать». Низкая alpha, чтобы не забивать сцену.
@export var gather_zone_fill_color: Color = Color(0.45, 0.75, 1.0, 0.12)
## Цвет ВСПЫШКИ зоны при отклонённом приказе (клик по источнику вне радиуса).
## Заливка коротко краснеет — игрок видит «слишком далеко от башни».
@export var gather_zone_reject_color: Color = Color(1.0, 0.3, 0.3, 0.5)
@export var debug_log: bool = true

@export_group("")
@export var effects_root_path: NodePath

var _hand: Hand
var _camp: Camp
var _effects_root: Node = null
var _active_squad: Squad = null
var _aim_indicator: MeshInstance3D = null
## Визуал зоны добычи вокруг башни: залитый диск (_zone_fill, видная площадь) +
## контур-кольцо (_zone_ring) сверху. Видно ТОЛЬКО пока aim активен для РАБОЧЕГО
## отряда («управляешь строителями»). Башня мобильна → каждый кадр переставляем
## на её позицию. Клик по источнику вне радиуса отклоняется (диск краснеет,
## _flash_zone_reject). Чистятся в _finish_aim.
var _zone_fill: MeshInstance3D = null
var _zone_ring: MeshInstance3D = null


func _ready() -> void:
	# _camp пытаемся резолвить тут, но Camp может ещё не быть в группе
	# (порядок _ready bottom-up — HandSquadAim._ready зовётся до Camp._ready
	# если Hand-узел стоит выше Camp в main.tscn). Lazy-lookup в _commit_aim.
	_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


## True если сейчас идёт aim для указанного squad'а. UI использует для
## показа highlighted-state кнопки «Идти сюда» на карточке.
func is_aiming(squad: Squad) -> bool:
	return _active_squad != null and _active_squad == squad


## True если идёт aim вообще (для какого-то squad'а).
func is_aiming_any() -> bool:
	return _active_squad != null


## Toggle: если aim активен на этом squad'е → cancel. Иначе → start.
## UI зовёт при клике «Идти сюда».
func toggle_aim_for(squad: Squad) -> void:
	if _active_squad == squad:
		cancel_aim()
	else:
		start_aim(squad)


## Запуск aim'а. Если уже активен на другом squad'е — сначала отменяем
## предыдущий, потом стартуем новый (один aim в один момент времени).
func start_aim(squad: Squad) -> void:
	if squad == null:
		push_warning("[Hand:SquadAim] start_aim получил null squad")
		return
	if not is_instance_valid(_hand):
		push_warning("[Hand:SquadAim] start_aim — _hand не задан (setup не вызван?)")
		return
	if _active_squad != null:
		cancel_aim()
	_active_squad = squad
	_hand.push_category(Hand.Category.SQUAD_AIM)
	_spawn_indicator()
	_spawn_zone_indicator()  # no-op если отряд не рабочий / нет башни
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] aim старт для %s" % str(squad))


## Отмена без команды (повторный клик «Идти сюда» / squad распущен).
func cancel_aim() -> void:
	if _active_squad == null:
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] aim отменён")
	_finish_aim()


func _process(_delta: float) -> void:
	if _active_squad == null:
		return
	# Squad мог быть распущен/уничтожен пока aim активен (sticky-mode
	# держит aim между commit'ами — squad freed-в-промежутке вероятнее
	# чем при one-shot). Guard на freed-ref.
	if not is_instance_valid(_active_squad):
		_finish_aim()
		return
	# Двигаем ring под курсором каждый кадр. Ground-Y берём из cursor world
	# минус hand_height (как у Super.AIMING_TARGET).
	if is_instance_valid(_aim_indicator):
		var ground: Vector3 = _hand.cursor_world_position()
		ground.y -= _hand.hand_height
		_aim_indicator.global_position = ground + Vector3.UP * 0.05
		# Подсветка hostile когда враги в радиусе кольца — игрок видит, что
		# это указание цели, а не просто перемещение в пустое место.
		_set_ring_hostile(_has_enemies_in_aim_zone(ground))
	# Зона добычи следует за башней (WASD двигает башню во время sticky-aim'а).
	if is_instance_valid(_zone_fill) or is_instance_valid(_zone_ring):
		var t := _tower_node()
		if t != null:
			if is_instance_valid(_zone_fill):
				_zone_fill.global_position = t.global_position + Vector3.UP * 0.03
			if is_instance_valid(_zone_ring):
				_zone_ring.global_position = t.global_position + Vector3.UP * 0.05
	# Esc — отмена aim'а без команды. UI-гейт не нужен: ui_cancel не должен
	# использоваться никакой кнопкой HUD'а как клавиатурный shortcut.
	if Input.is_action_just_pressed(ACTION_AIM_CANCEL):
		cancel_aim()
		return
	# ЛКМ — commit точки. UI-гейт: если курсор над виджетом HUD'а, ЛКМ — это
	# клик по кнопке, не команда отряду (иначе клик «За башней» во время aim'а
	# ставил бы юнитов в случайную точку). Marker-приоритет: если игрок над
	# готовым SquadChargeMarker'ом — ЛКМ кушает marker (ult'а), не commit.
	if Input.is_action_just_pressed(ACTION_AIM_COMMIT) \
			and not _hand.is_pointer_over_ui() \
			and not _charge_marker_will_consume_lmb():
		_commit_aim()


## True если в круге aim_ring_radius вокруг центра есть живой враг любого типа.
## Идём через `Enemy.ENEMY_GROUP` — все наследники Enemy (melee-Skeleton +
## Archer + Giant + Thrower + любой будущий тип), NEAR и FAR-LOD одинаково.
## SKELETON_GROUP-only был бы асимметрией: каменщик / обычный archer не
## вошли бы в неё (они extends Archer, не Skeleton) → кольцо не подсвечивалось
## бы hostile-цветом, хотя SoldierGnome их теперь атакует через ENEMY_GROUP.
## См. [[feedback-symmetric-interactions]].
##
## Дёшево: ~50 врагов max × 1 frame, без sqrt.
func _has_enemies_in_aim_zone(center: Vector3) -> bool:
	var r_sq: float = aim_ring_radius * aim_ring_radius
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var node3d := n as Node3D
		if node3d == null:
			continue
		var dx: float = node3d.global_position.x - center.x
		var dz: float = node3d.global_position.z - center.z
		if dx * dx + dz * dz <= r_sq:
			return true
	return false


## Меняет albedo + emission материала кольца на hostile/neutral.
## StandardMaterial3D создан в AoeVisual.spawn_ground_ring; мы знаем его
## структуру и берём через material_override.
func _set_ring_hostile(hostile: bool) -> void:
	if not is_instance_valid(_aim_indicator):
		return
	var mat := _aim_indicator.material_override as StandardMaterial3D
	if mat == null:
		return
	var c: Color = aim_ring_color_hostile if hostile else aim_ring_color
	mat.albedo_color = c
	mat.emission = Color(c.r, c.g, c.b, 1.0)


func _commit_aim() -> void:
	if _active_squad == null:
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	# Lazy-resolve: если в _ready Camp ещё не был в группе, пробуем сейчас.
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	# Рабочий отряд: area-клик = НАПРАВЛЕННОЕ действие по тому, на что ткнул.
	# Башня → ремонт; блюпринт → строить; ресурс → собирать; горшок/рычаг → разбить/
	# переключить; пусто → просто идти на точку. Копейщики — обычный hold.
	if _active_squad.soldier_type == SoldierSystem.ROLE_WORKER:
		_commit_worker_order(ground)
	elif is_instance_valid(_camp):
		_camp.command_squad_hold(_active_squad, ground)
	else:
		_active_squad.command_hold(ground)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] commit %s @ (%.1f, %.1f, %.1f)" % [str(_active_squad), ground.x, ground.y, ground.z])
	_spawn_commit_marker(ground)
	# Sticky: aim НЕ завершается. Игрок может тут же ПКМ в другую точку,
	# не возвращаясь в HUD. Выход — Esc / повторный клик кнопки / новый
	# aim для другого squad'а / гибель squad'а.


## Радиус, в котором area-клик «цепляет» strike-цель (кольцо прицела + запас).
const WORK_PICK_RADIUS := 5.0


## Рабочий area-клик → понять, на ЧТО ткнул, и выдать work-order. Башня → ремонт;
## блюпринт → BUILD; ресурс → GATHER; горшок/рычаг → STRIKE; пусто → просто идти.
func _commit_worker_order(ground: Vector3) -> void:
	if _is_tower_click(ground):
		_active_squad.command_escort(true)  # ремонт: выйти, чинить, потом спрятаться
		return
	var target := _nearest_strike_target_near(ground, WORK_PICK_RADIUS)
	if target == null:
		_active_squad.command_hold(ground)  # просто идти на точку (без работы)
	elif target.is_in_group(Layers.BUILD_SITE_GROUP):
		_active_squad.command_work(Squad.WorkKind.BUILD, ground, target)
	elif target.is_in_group(Layers.RESOURCE_SOURCE_GROUP):
		# Зона добычи: нельзя послать рабочих добывать дальше радиуса башни.
		# Источник вне зоны → приказ отклонён, кольцо краснеет, return.
		if not _source_in_gather_zone(target):
			_flash_zone_reject()
			if debug_log and LogConfig.master_enabled:
				print("[Hand:SquadAim] GATHER отклонён — источник вне зоны добычи башни")
			return
		_active_squad.command_work(Squad.WorkKind.GATHER, ground, target)
	else:
		_active_squad.command_work(Squad.WorkKind.STRIKE, ground, target)  # горшок/рычаг


## Ближайшая strike-цель (gnome_strike_target) в радиусе r от точки по XZ, КРОМЕ
## башни (она по area-клику = ремонт, отдельной веткой).
func _nearest_strike_target_near(p: Vector3, r: float) -> Node3D:
	var best: Node3D = null
	var best_d: float = r * r
	for n in get_tree().get_nodes_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null or node.is_in_group(&"tower"):
			continue
		var dx: float = node.global_position.x - p.x
		var dz: float = node.global_position.z - p.z
		var d: float = dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = node
	return best


## Курсор реально наведён на коллайдер башни? Луч из камеры по слою ACTORS (там только
## башня) — точная проверка «клик ПО башне», а НЕ радиус вокруг неё. Радиус-эвристика
## перехватывала команды рядом с башней (мост строят У ПРОПАСТИ, где стоит башня) →
## «иди сюда» к мосту срывалось в ремонт. Точный луч бьёт только по самой башне.
func _is_tower_click(_ground: Vector3) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = cam.project_ray_origin(mouse)
	var to: Vector3 = from + cam.project_ray_normal(mouse) * 1000.0
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.ACTORS)
	var hit: Dictionary = cam.get_world_3d().direct_space_state.intersect_ray(q)
	var collider = hit.get("collider")
	return collider is Node and (collider as Node).is_in_group(&"tower")


func _finish_aim() -> void:
	_clear_indicator()
	_clear_zone_indicator()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.SQUAD_AIM:
		_hand.pop_category()
	_active_squad = null


func _spawn_indicator() -> void:
	_clear_indicator()
	if _effects_root == null:
		return
	# duration=0 → AoeVisual возвращает mesh без auto-fade.
	_aim_indicator = AoeVisual.spawn_ground_ring(
		_effects_root,
		_hand.cursor_world_position() - Vector3.UP * _hand.hand_height,
		aim_ring_radius,
		0.0,
		aim_ring_color,
	)


func _clear_indicator() -> void:
	if is_instance_valid(_aim_indicator):
		_aim_indicator.queue_free()
	_aim_indicator = null


## Башня сцены (мобильный центр зоны добычи) или null. Через группу — без NodePath,
## как остальной discovery башни в этом файле.
func _tower_node() -> Tower:
	return get_tree().get_first_node_in_group(Tower.GROUP) as Tower


## Кольцо зоны добычи спавним ТОЛЬКО для рабочего отряда и только если в сцене
## есть башня с положительным gather_radius. Иначе no-op (копейщики, легаси-сцены
## без башни) — зона не для них.
func _spawn_zone_indicator() -> void:
	_clear_zone_indicator()
	if _effects_root == null or not is_instance_valid(_active_squad):
		return
	if _active_squad.soldier_type != SoldierSystem.ROLE_WORKER:
		return
	var t := _tower_node()
	if t == null or t.gather_radius <= 0.0:
		return
	# Залитый диск (видная площадь) + контур-кольцо сверху (граница).
	_zone_fill = AoeVisual.spawn_ground_disc(
		_effects_root, t.global_position, t.gather_radius, gather_zone_fill_color,
	)
	_zone_ring = AoeVisual.spawn_ground_ring(
		_effects_root, t.global_position, t.gather_radius, 0.0, gather_zone_color,
	)


func _clear_zone_indicator() -> void:
	if is_instance_valid(_zone_fill):
		_zone_fill.queue_free()
	_zone_fill = null
	if is_instance_valid(_zone_ring):
		_zone_ring.queue_free()
	_zone_ring = null


## Источник внутри радиуса добычи башни? XZ-дистанция от текущей позиции башни.
## Нет башни / radius<=0 → true (не блокируем в сценах без зоны, напр. легаси-лагерь).
func _source_in_gather_zone(source: Node3D) -> bool:
	var t := _tower_node()
	if t == null or t.gather_radius <= 0.0:
		return true
	var dx: float = source.global_position.x - t.global_position.x
	var dz: float = source.global_position.z - t.global_position.z
	return dx * dx + dz * dz <= t.gather_radius * t.gather_radius


## Красная вспышка ЗАЛИВКИ зоны — приказ на добычу вне радиуса отклонён.
## Tween возвращает цвет к нейтральной заливке. Заливка — самый заметный
## элемент зоны, на ней вспышка читается лучше тонкого контура.
func _flash_zone_reject() -> void:
	if not is_instance_valid(_zone_fill):
		return
	var mat := _zone_fill.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = gather_zone_reject_color
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color", gather_zone_fill_color, 0.4)


## True если в этот кадр любой SquadChargeMarker готов «съесть» ЛКМ —
## готов к ult'е и игрок наводится на него. Тогда commit движения пропускаем,
## marker сам обработает свой trigger (он тоже на ЛКМ). Чтобы избежать
## двойного срабатывания «ult'а + move в ту же точку».
func _charge_marker_will_consume_lmb() -> bool:
	for m in get_tree().get_nodes_in_group(SquadChargeMarker.GROUP):
		if not is_instance_valid(m):
			continue
		var marker := m as SquadChargeMarker
		if marker == null:
			continue
		if marker.would_consume_lmb():
			return true
	return false


## Spawn'ит независимое затухающее кольцо на точке commit'а. Цвет берём
## из текущего material'а cursor-ring'а — если игрок commit'ил в hostile-зону,
## метка тоже hostile-красная.
func _spawn_commit_marker(pos: Vector3) -> void:
	if _effects_root == null:
		return
	var color: Color = aim_ring_color
	if is_instance_valid(_aim_indicator):
		var cur_mat := _aim_indicator.material_override as StandardMaterial3D
		if cur_mat != null:
			color = cur_mat.albedo_color
	AoeVisual.spawn_ground_ring(
		_effects_root,
		pos,
		aim_ring_radius,
		commit_marker_duration,
		color,
	)
