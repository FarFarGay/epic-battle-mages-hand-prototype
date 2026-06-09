class_name Harvester
extends StaticBody3D
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
## Золото зачисляется напрямую через _economy.add_resource.

## Damageable-контракт: эмитятся при уроне / разрушении ядра. MatchGoal/Camp
## слушают через EventBus.harvester_destroyed (re-emit в _die).
signal damaged(amount: float)
signal destroyed

enum State { IN_CARAVAN, DEPLOYED }

@export_group("Gold harvest")
## Скорость добычи золота, единиц в секунду. Тикает только в DEPLOYED.
## 0.5 = 1 gold каждые 2с.
@export var gold_per_second: float = 0.5

@export_group("Health")
## Прочность ядра лагеря (HP). Скелеты бьют харвестер как палатку/здание
## (Damageable + skeleton_target). Ядро — самое прочное в лагере; его
## уничтожение = поражение матча. Тюнится под баланс осады.
@export var max_hp: float = 600.0
## Бонус досягаемости атаки (м) для атакующих по ядру. Ядро широкое (коллизия
## ~1.7м радиус) — скелет упирается в стенку далеко от центра, и обычный
## attack_range/strike-радиус до ЦЕНТРА не срабатывает. Этот бонус прибавляется
## к их дальности (см. Enemy.target_reach_bonus), чтобы ядро били с края. ~ радиус
## коллизии; меньше → бьют ближе к поверхности, больше → замахиваются дальше.
@export var attack_reach_bonus: float = 1.0

@export_group("Death explosion (детонация ядра)")
## Ядро детонирует при гибели — урон по площади, уничтожая стоящие рядом
## постройки (кольцо генераторов, стены) и врагов. 0 = радиус выкл. Радиус
## крупнее башенного — ядро большое и набито маной. Единый язык с башней/мехом.
@export var death_explosion_radius: float = 9.0
## Урон детонации всем damageable в радиусе (без falloff). Высокий — сносит
## соседние постройки (генератор hp=220) с запасом.
@export var death_explosion_damage: float = 400.0
## Импульс отбрасывания pushable-целей (скелетов) от центра (м/с). 0 = без push.
@export var death_explosion_knockback: float = 11.0
## Цвет ударной волны детонации (золото маны).
@export var death_explosion_color: Color = Color(1.0, 0.78, 0.25, 0.95)
## Сколько осколков-кубиков разлетается при гибели ядра (крупное — много).
@export var death_shatter_fragments: int = 24
## Время жизни осколков (сек).
@export var death_shatter_lifetime: float = 2.5
## Цвет осколков ядра (металл корпуса).
@export var death_shatter_color: Color = Color(0.6, 0.62, 0.68, 1.0)

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

## Боевое состояние ядра. _hp ведём от max_hp; _destroyed гейтит повторный урон.
var _hp: float = 0.0
var _destroyed: bool = false
## Per-instance материал тела для hit-flash (дублируем baked-материал, чтобы не
## мутировать общий .tres). Берём с меша Body визуала в _ready.
var _body_mesh: MeshInstance3D = null
var _body_mat: StandardMaterial3D = null

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
	# Боевое: ядро — разрушаемая цель. Корень харвестера сам физтело-StaticBody
	# (collision в harvester.tscn) И damageable-узел — как Tower/BuildBlock.
	# Тогда урон проходит ОДИНАКОВО для всех источников: скелет бьёт по группе
	# (skeleton_target), а AOE/спеллы башни (MASK_HAND_SLAM включает CAMP_OBSTACLE)
	# — по коллайдеру, и это тот же узел. Никаких хардкод-исключений: ядро
	# уязвимо как любое здание лагеря.
	_hp = max_hp
	Damageable.register(self)
	add_to_group(Enemy.TARGET_GROUP)
	# Тело для hit-flash: дублируем baked-материал, чтобы не мутировать общий .tres.
	_body_mesh = get_node_or_null("VisualRoot/HarvesterVisual/Body") as MeshInstance3D
	if _body_mesh != null and _body_mesh.material_override is StandardMaterial3D:
		_body_mat = (_body_mesh.material_override as StandardMaterial3D).duplicate()
		_body_mesh.material_override = _body_mat
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


## Reach-бонус для атакующих (Enemy.target_reach_bonus): ядро широкое, бьём с края.
func get_attack_reach_bonus() -> float:
	return attack_reach_bonus


## Текущая фактическая скорость добычи золота (единиц/сек) с учётом числа
## генераторов. 0 если харвестер не развёрнут или генераторов нет. Для HUD —
## показывает игроку реальный темп прихода золота.
func get_current_gold_rate() -> float:
	if _state != State.DEPLOYED:
		return 0.0
	return gold_per_second * _production_scale


## Масштаб добычи [0..1] — Camp задаёт его по числу установленных генераторов
## (0 = нет генераторов, добыча стоит; 1 = оптимум на generators_required).
## Фактическая скорость = gold_per_second × _production_scale. _running —
## производное (scale > 0): включает бур и частицы.
var _production_scale: float = 0.0
var _running: bool = false

## Camp зовёт при изменении набора генераторов в гриде. scale=0 → добыча стоит.
func set_production_scale(scale: float) -> void:
	scale = clampf(scale, 0.0, 1.0)
	if is_equal_approx(scale, _production_scale):
		return
	_production_scale = scale
	var now_running: bool = scale > 0.0
	if now_running != _running:
		_running = now_running
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
	# Развёрнутое ядро (StaticBody, слой CAMP_OBSTACLE ∈ маски навмеша 4129) —
	# препятствие навмеша: гномы/скелеты огибают его, а не идут сквозь. Гном-
	# собиратель не доходит до ЦЕНТРА (там дыра), а сдаёт ресурс у КРАЯ дыры:
	# Gnome.deposit_distance ≥ радиуса дыры (~1.5м). Camp ребейкает после деплоя.
	add_to_group(&"navmesh_source")


## Camp зовёт при свёртке. Harvester возвращается в IN_CARAVAN — двигаться
## дальше будет уже логика caravan-follow в Camp'е. Идемпотентно.
func pack_to_caravan() -> void:
	if _state == State.IN_CARAVAN:
		return
	_state = State.IN_CARAVAN
	_gold_accumulator = 0.0
	_reset_motion_visuals()
	_apply_visual_state()


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
	# Скорость добычи масштабируется числом генераторов (Camp дёргает
	# set_production_scale). 0 генераторов → scale=0, стоит, золото не качает.
	if not _running:
		return
	if _drill != null:
		_drill.rotate_y(delta * TAU * drill_rps)
	var rate: float = gold_per_second * _production_scale
	if rate <= 0.0:
		return
	_gold_accumulator += rate * delta
	if _gold_accumulator < 1.0:
		return
	var whole: int = int(_gold_accumulator)
	_gold_accumulator -= float(whole)
	if _economy != null:
		_economy.add_resource(ResourcePile.ResourceType.GOLD, whole)


func _apply_visual_state() -> void:
	if _harvest_particles != null:
		_harvest_particles.emitting = (_state == State.DEPLOYED) and _running


# --- Damageable (ядро лагеря) ---

## Damageable-контракт. Скелеты бьют ядро как любую цель skeleton_target.
## Идемпотентно после _die (повторный урон по трупу — no-op).
func take_damage(amount: float) -> void:
	if _destroyed or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash_damage()
	if LogConfig.master_enabled:
		print("[Harvester] урон %.1f, hp=%.1f/%.1f" % [amount, maxf(_hp, 0.0), max_hp])
	if _hp <= 0.0:
		_die()


## Уничтожение ядра = поражение матча. Из групп-целей выходим СРАЗУ до emit
## (queue_free отложен — см. reference_godot_queue_free_deferred), чтобы скан
## скелетов/AoE не били труп. Re-emit на EventBus.harvester_destroyed: Camp
## гасит добычу, MatchGoal эмитит match_lost (DefeatOverlay показывает панель).
func _die() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(Enemy.TARGET_GROUP)
	remove_from_group(Damageable.GROUP)
	_spawn_death_explosion()
	destroyed.emit()
	EventBus.harvester_destroyed.emit()
	queue_free()


## Детонация ядра: визуал взрыва + ударная волна + урон по площади — уничтожает
## стоящие рядом постройки (кольцо генераторов, стены) и врагов. Себя не задевает
## (вышли из Damageable выше). Визуалы спавнятся на current_scene, потому
## переживают queue_free ядра. Единый паттерн с башней/мехом.
func _spawn_death_explosion() -> void:
	var root: Node = get_tree().current_scene
	if root != null and death_explosion_radius > 0.0:
		AoeVisual.spawn_explosion(root, global_position + Vector3.UP * 1.5, death_explosion_radius)
		AoeVisual.spawn_expanding_ring(root, global_position, death_explosion_radius, 0.7, death_explosion_color, 0.35)
	# Осколки корпуса — на current_scene (ядро уходит в queue_free, фрагменты-дети
	# улетели бы вместе с ним). Единый язык shatter'а с врагами/палатками.
	if root != null:
		ShatterEffect.spawn(root, global_position + Vector3.UP * 1.5, death_shatter_color,
			death_shatter_fragments, death_shatter_lifetime)
	if death_explosion_radius > 0.0 and death_explosion_damage > 0.0:
		AoeDamage.apply_uniform(get_tree(), global_position, death_explosion_radius,
			Layers.MASK_DEATH_BLAST, death_explosion_damage, death_explosion_knockback, 0.3)


## Красный flash при ударе — единый язык FX с палатками/зданиями/врагами.
## Модифицирует per-instance _body_mat (дубль baked-материала), tween к базе.
func _flash_damage() -> void:
	if _body_mat == null:
		return
	if not _body_mat.emission_enabled:
		_body_mat.emission_enabled = true
	var orig_emission: Color = _body_mat.emission
	var orig_mult: float = _body_mat.emission_energy_multiplier
	_body_mat.emission = Color(1.0, 0.2, 0.2, 1.0)
	_body_mat.emission_energy_multiplier = 2.5
	var tween := create_tween()
	tween.tween_property(_body_mat, "emission", orig_emission, 0.18)
	tween.parallel().tween_property(_body_mat, "emission_energy_multiplier", orig_mult, 0.18)
