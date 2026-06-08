class_name SquadChargeMarker
extends Node3D
## Визуальный маркер заряженной атаки отряда. Висит над центром формации,
## показывает прогресс ([Squad._charge] / [Squad.charge_max]) и пульсирует
## когда готов. На hand-slam рядом — триггерит squad-ability по типу отряда
## ([[project-ebm-charge-abilities]]).
##
## Жизненный цикл: создаётся Camp'ом на squad_created, освобождается на
## squad_disbanded (или сам себя — на пустых member'ах).
##
## Архитектура:
## - Squad — RefCounted, без своего узла в сцене → визуал/AOE-каст здесь
##   (Node3D, имеет get_tree() и transform).
## - Активация: ЛКМ при hover'е курсора над маркером. Hover считаем сами по
##   XZ-дистанции от cursor_world_position до маркера ([HOVER_RADIUS]) —
##   независимо от категории руки (PHYSICAL/MAGIC), иначе при выбранном
##   заклинании маркер «застывал»: [Hand._update_pickup_highlight] фильтрует
##   подсветку только под PHYSICAL и в set_highlighted не зовёт. Игроку же
##   ability'у отряда должна быть доступна всегда, кроме явных aim-режимов
##   (SUPER/SQUAD_AIM/BUILD_AIM — там ЛКМ занят).
## - AOE-каст через [AoeVisual] + [AoeDamage.apply_uniform] — переиспользуем
##   shared util'и slam'ов/fireball'ов.
##
## По типам (squad.soldier_type):
## - pikeman: круговая push-волна от центра формации (damage + radial push).

const ACTION_TRIGGER := &"hand_grab"  # ЛКМ — клик по маркеру

## Группа всех живых маркеров. [HandSquadAim] итерирует её, чтобы пропустить
## commit движения в кадре, когда маркер тоже сработает на ЛКМ (иначе ult'а
## + move в ту же точку одним кликом).
const GROUP := &"squad_charge_marker"

const FLOAT_HEIGHT: float = 2.2
const FOLLOW_SMOOTH: float = 12.0
## Радиус hover'а курсора по XZ. Совпадает с [Hand.PICKUP_HIGHLIGHT_RADIUS]
## (1.5м) — единый visual contract для всех interactable'ов под рукой.
const HOVER_RADIUS: float = 1.5

@export_group("Pikeman ability")
## Радиус круговой push-волны вокруг центра отряда. ~6м — покрывает
## пятерых копейщиков (formation ~3м диаметр) + 1.5м буфер с обоих сторон.
@export var pikeman_ability_radius: float = 6.0
## Damage по каждому скелету в зоне. Лёгкий — главная роль ability'а это
## отбрасывание, damage добивает раненых.
@export var pikeman_damage: float = 30.0
## Magнитуда radial push'а (м/с). Сильный — «отогнать натиск».
@export var pikeman_push_speed: float = 14.0
@export var pikeman_push_duration: float = 0.35
## Mask AOE — только враги. FRIENDLY_UNIT/CampObstacle/палисад не задеваем
## (squad-ability — only-enemy, в отличие от player slam'а который дружбу
## тоже бьёт).
@export_flags_3d_physics var pikeman_aoe_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY
@export var pikeman_ring_color: Color = Color(1.0, 0.65, 0.2, 0.95)
@export_group("")

@export_group("Archer volley ability")
## Радиус разлёта стрел вокруг центра отряда. Больше pikeman'а — лучник
## бьёт по площади дальше, AOE-эффект «дождь стрел».
@export var archer_ability_radius: float = 8.0
## Стрел на одного лучника. 5 × 3 лучника = 15 стрел в залпе.
@export var archer_arrows_per_member: int = 5
## Damage одной стрелы залпа. Чуть выше обычной (20-32 → 35) — компенсация
## за расход squad-charge'а.
@export var archer_volley_damage: float = 35.0
## Цвет визуального кольца на земле под залпом (тёмно-фиолетовый под цвет
## лучника).
@export var archer_ring_color: Color = Color(0.55, 0.35, 0.75, 0.95)
@export_group("")

@export var debug_log: bool = true

var _squad: Squad = null
var _mesh: MeshInstance3D = null
var _material: StandardMaterial3D = null
var _torus: TorusMesh = null
## Smoothed follow-anchor для tween-like движения за центром отряда.
var _last_center: Vector3 = Vector3.INF
## True если курсор руки внутри XZ-радиуса HOVER_RADIUS. Считается в _process
## (не через [Hand.set_highlighted] — тот гасится в не-PHYSICAL категориях).
var _is_hovered: bool = false
## Ссылка на руку — берём один раз, дёшево хранить per-frame.
var _hand: Hand = null


func setup(squad: Squad) -> void:
	_squad = squad
	if _squad != null:
		_squad.charge_changed.connect(_on_charge_changed)
		_squad.disbanded.connect(_on_squad_disbanded, CONNECT_ONE_SHOT)


func _ready() -> void:
	add_to_group(GROUP)
	_build_visual()
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
	_update_visual_state()


## Сработает ли маркер на ЛКМ в этот кадр? True = ult'а готова, курсор
## наводится, режим руки позволяет. [HandSquadAim] зовёт чтобы не дать
## SQUAD_AIM-commit'у выстрелить в тот же кадр.
func would_consume_lmb() -> bool:
	if _squad == null or not _squad.is_charge_ready():
		return false
	return _is_hovered and _is_input_allowed()


func _build_visual() -> void:
	# Torus на высоте плеча/головы. Тонкое плоское кольцо, parallel to ground —
	# хорошо читается сверху (top-down прицельная камера), не загораживает
	# отряд. Diameter = 1м (outer 0.5, inner 0.4) — компактный, не визуальный
	# спам над каждым squad'ом.
	_torus = TorusMesh.new()
	_torus.outer_radius = 0.5
	_torus.inner_radius = 0.38
	_torus.rings = 36
	_torus.ring_segments = 8
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.emission_enabled = true
	# Поверх тумана войны — маркер заряда должен читаться, даже когда отряд в дыму.
	_material.render_priority = AoeVisual.GROUND_MARKER_PRIORITY
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _torus
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)


func _process(delta: float) -> void:
	if _squad == null:
		return
	if _squad.count_alive() == 0:
		queue_free()
		return
	var center: Vector3 = _squad.compute_center()
	if center == Vector3.INF:
		return
	var goal: Vector3 = center + Vector3.UP * FLOAT_HEIGHT
	if _last_center == Vector3.INF:
		global_position = goal
		_last_center = goal
	else:
		# Exp-decay smoothing — на резких движениях squad'а (lunge'и копейщиков)
		# маркер не «дёргается» вместе с каждым выпадом одного юнита.
		var t: float = 1.0 - exp(-FOLLOW_SMOOTH * delta)
		global_position = global_position.lerp(goal, t)
		_last_center = goal
	# Постоянный медленный spin — визуально живой маркер, чтобы игрок отличал
	# готовый ability от статичной иконки HUD'а.
	rotate_y(delta * 1.2)
	_update_hover()
	# Пульсация когда готов: scale 1.0..1.18 sin-волной. Скорость на ~1.5Гц —
	# спокойное «бьётся сердце», не нервная мигалка. При hover'е амплитуда
	# растёт (видимый «отклик на наведение») и cursor-handler ловит ЛКМ.
	if _squad.is_charge_ready():
		var amplitude: float = 0.28 if _is_hovered else 0.18
		var s: float = 1.0 + sin(Time.get_ticks_msec() * 0.001 * 9.0) * amplitude
		_mesh.scale = Vector3(s, 1.0, s)
		if _is_hovered and _is_input_allowed() and Input.is_action_just_pressed(ACTION_TRIGGER):
			_trigger_ability(_squad.compute_center())


## Прогресс заряда в визуал: цвет/emission от dim-серого до яркого
## огненно-оранжевого, alpha из прозрачного в полную видимость. На full
## (is_charge_ready) — белёсая вспышка emission'а.
func _update_visual_state() -> void:
	if _material == null or _squad == null:
		return
	var t: float = clampf(_squad.get_charge() / maxf(_squad.charge_max, 0.001), 0.0, 1.0)
	if _squad.is_charge_ready():
		var ready_color: Color = Color(1.0, 0.85, 0.35, 0.95)
		_material.albedo_color = ready_color
		_material.emission = ready_color
		_material.emission_energy_multiplier = 4.0
	else:
		# Тёмный → огненный по мере заряда. Низкий alpha когда charge=0 — маркер
		# почти не виден на свежем (не заряженном) squad'е, не отвлекает.
		var col: Color = Color(0.5, 0.35, 0.2, 1.0).lerp(Color(1.0, 0.55, 0.15, 1.0), t)
		col.a = lerpf(0.25, 0.85, t)
		_material.albedo_color = col
		_material.emission = col
		_material.emission_energy_multiplier = lerpf(0.4, 2.5, t)
		_mesh.scale = Vector3.ONE


func _on_charge_changed(_value: float, _max_value: float) -> void:
	_update_visual_state()


func _on_squad_disbanded() -> void:
	queue_free()


## XZ-дистанция от cursor_world_position (на земле) до маркера (xz отряда).
## Hand-cursor сам по себе на высоте hand_height над поверхностью — приводим
## к ground'у вычитанием hand_height (тот же приём в [HandSuper._process]).
func _update_hover() -> void:
	if _hand == null or not is_instance_valid(_hand):
		_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
		if _hand == null:
			_is_hovered = false
			return
	var cursor: Vector3 = _hand.cursor_world_position()
	var dx: float = cursor.x - global_position.x
	var dz: float = cursor.z - global_position.z
	_is_hovered = (dx * dx + dz * dz) <= HOVER_RADIUS * HOVER_RADIUS


## Гейт ЛКМ: PHYSICAL/MAGIC — ОК (LMB grab свободен или хватает только если
## под курсором есть Grabbable — маркер таковым не является, конфликта нет).
## SUPER (QTE) / BUILD_AIM (brush-vertex) — ЛКМ в этих режимах занят, маркер
## молчит. SQUAD_AIM использует только ПКМ (`hand_action`) + Esc — ЛКМ
## свободна, маркер должен срабатывать (со sticky-aim категория висит до
## явного выхода; без этого ability недоступен в самом нужный момент —
## когда ведёшь отряд в гущу). UI поверх курсора — глушим через
## [Hand.is_pointer_over_ui].
func _is_input_allowed() -> bool:
	if _hand == null or not is_instance_valid(_hand):
		return false
	match _hand.active_category:
		Hand.Category.SUPER, Hand.Category.BUILD_AIM:
			return false
	return not _hand.is_pointer_over_ui()


func _trigger_ability(center: Vector3) -> void:
	if _squad == null:
		return
	if debug_log and LogConfig.master_enabled:
		print("[SquadChargeMarker] %s триггерит ability @ (%.1f, %.1f, %.1f)" % [str(_squad), center.x, center.y, center.z])
	match _squad.soldier_type:
		&"pikeman":
			_cast_pikeman_push(center)
		&"archer_squad":
			_cast_archer_volley(center)
		_:
			push_warning("[SquadChargeMarker] нет ability для типа %s" % _squad.soldier_type)
			return
	_squad.consume_charge()


## Круговая push-волна для копейщиков. Огненно-оранжевое expanding ring как
## визуальный «удар по земле копьями кругом», плюс лёгкая explosion-вспышка
## в центре + dust для импакта. Damage + radial push всем enemy'ам в зоне.
func _cast_pikeman_push(center: Vector3) -> void:
	var root: Node = get_tree().current_scene
	if not is_instance_valid(root):
		return
	# Визуал: expanding ring (волна расходится наружу до полного радиуса) +
	# короткая ground-ring подсветка под центром + dust. Без full explosion
	# (огонь/дым) — это push-эффект, не взрыв. По цвету в один тон с маркером
	# (огненно-оранжевый) — игрок видит «знак с маркера превратился в волну».
	AoeVisual.spawn_expanding_ring(root, center, pikeman_ability_radius, 0.4,
		pikeman_ring_color, 0.25)
	AoeVisual.spawn_ground_ring(root, center, pikeman_ability_radius, 0.35,
		pikeman_ring_color)
	AoeVisual.spawn_dust(root, center)
	# Damage + push враждебным целям. mask = ENEMIES only — палатки/гномы/
	# башню/палисад не задеваем.
	AoeDamage.apply_uniform(get_tree(), center, pikeman_ability_radius,
		pikeman_aoe_mask, pikeman_damage,
		pikeman_push_speed, pikeman_push_duration)


## Волейный залп для лучников. Каждый живой ArcherSoldier в отряде спавнит
## `archer_arrows_per_member` стрел с прицелом на случайные точки внутри
## `archer_ability_radius` вокруг `center`. Damage применяется при попадании
## (Arrow это уже делает по своему пути). Визуал: ground-ring +
## expanding-ring под цвет лучника.
func _cast_archer_volley(center: Vector3) -> void:
	var root: Node = get_tree().current_scene
	if not is_instance_valid(root):
		return
	AoeVisual.spawn_ground_ring(root, center, archer_ability_radius, 0.5, archer_ring_color)
	AoeVisual.spawn_expanding_ring(root, center, archer_ability_radius, 0.5,
		archer_ring_color, 0.2)
	for member in _squad.members:
		if not is_instance_valid(member):
			continue
		var archer := member as ArcherSoldier
		if archer == null:
			continue
		for j in range(archer_arrows_per_member):
			var angle: float = randf() * TAU
			# sqrt — uniform по площади круга (иначе плотность к центру).
			var r: float = sqrt(randf()) * archer_ability_radius
			var aim_pos := Vector3(
				center.x + cos(angle) * r,
				center.y,
				center.z + sin(angle) * r,
			)
			archer.volley_fire_at(aim_pos, archer_volley_damage)
