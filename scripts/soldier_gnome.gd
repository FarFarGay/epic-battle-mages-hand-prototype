class_name SoldierGnome
extends Gnome
## Гном-солдат — мобилизованный из gatherer'а через `Camp.recruit_squad`.
## Тип ближнего боя (копейщик): обнаруживает врага в `enemy_detect_radius`,
## догоняет, в `attack_range` бьёт на cooldown'е через
## `Damageable.try_damage`. Лучники как мобильный отряд НЕ призываются —
## только штатные DefenderGnome'ы у палаток. Параметры (hp, enemy_detect_radius,
## attack_range, damage, cooldown, speed) приходят из
## `SoldierSystem.SOLDIER_CATALOG[type].stats` через `setup_soldier`.
##
## Не привязан к палатке (в отличие от DefenderGnome): `_home_tent=null`.
## `_active_tick` переопределён под combat-логику + три squad-режима
## (HOLD / ESCORT / DEFEND).
##
## Группа SOLDIER_GROUP — для squad-сканов и общего учёта.

const SOLDIER_GROUP := &"soldier"

@export_group("Soldier combat (override через setup_soldier)")
## Радиус обнаружения противника. Юнит видит скелетов в этом радиусе и
## идёт на них. Не равен дистанции удара — копейщик подбегает в упор.
@export var enemy_detect_radius: float = 18.0
## Дистанция, с которой можно нанести удар копьём. С учётом capsule
## радиусов (skeleton ≈0.5, pikeman ≈0.28, минимум центр-к-центру ≈0.78м)
## значение 2.2 даёт ~1.4м реального «вылета копья» от тела — достаточно
## для попадания по движущейся цели на one-frame check'е.
@export var attack_range: float = 2.2
@export var attack_damage_min: float = 22.0
@export var attack_damage_max: float = 32.0
@export var attack_cooldown_min: float = 0.6
@export var attack_cooldown_max: float = 1.0
@export var soldier_color: Color = Color(0.85, 0.55, 0.25, 1.0)
## Автолут: всасывает орбы/монеты в своём радиусе и разбивает горшки рядом. По
## дизайну лутают строители, не воины — пока true у всех (флаг под будущее
## разделение ролей: воинам поставим false, строителям true).
@export var can_loot: bool = true
@export_group("")

@export_group("Defend patrol (DEFENDING_CAMP state)")
## Радиус патрулирования вокруг центра лагеря. По образцу
## `DefenderGnome.patrol_radius=12`. Каждый солдат отряда независимо
## выбирает случайные точки на этой окружности — отряд распределяется по
## периметру, как штатные защитники.
@export var defend_patrol_radius: float = 12.0
@export var defend_patrol_arrival: float = 0.6
## Скорость патрульного шага. Меньше боевого move_speed — стража обходит
## периметр размеренно (как `DefenderGnome.patrol_speed=1.0`, +чуть-чуть для
## визуального отличия).
@export var defend_patrol_speed: float = 1.2
@export_group("")

@export_group("Soldier charge (атака с разбега и рывком)")
## Скорость движения в фазе разгона (бежит к цели, корректируя направление
## каждый кадр). Линейно нарастает с 0 до этого значения за
## `approach_accel_time` — даёт «нарастающий бег» без мгновенного rocket-старта.
## Намеренно ниже базового move_speed*1.5: чем медленнее разгон, тем сильнее
## контраст с lunge_speed — рывок читается как «другой режим», не как
## «соседний кадр ускорения».
@export var approach_max_speed: float = 3.5
## Время нарастания скорости разгона от 0 до approach_max_speed.
@export var approach_accel_time: float = 0.18
## Дистанция до цели, при которой копейщик переходит из разгона в lunge —
## молниеносный рывок насквозь. Lunge стартует с заметного расстояния, чтобы
## визуально читался как «прыжок копьём через зазор», а не «дотянулся в упор».
@export var lunge_trigger_range: float = 4.0
## Скорость молниеносного рывка. ~6× approach_max_speed — резкий разрыв
## делает рывок «lightning»: глаз отделяет lunge от разгона как другое
## событие, не продолжение разгона. Направление фиксируется в момент
## перехода APPROACH → LUNGE и больше не меняется (skel может уклониться
## при удаче — это by-design).
@export var lunge_speed: float = 22.0
## Дистанция, которую копейщик пролетает после удара по инерции lunge'а —
## визуально «пробил насквозь». Короче чем раньше: с высокой скоростью
## хватает 1.6м чтобы выглядел проколом, дальше — это уже скольжение.
@export var lunge_pass_distance: float = 1.6
## Длительность заноса/торможения после lunge'а. С 2026-05-19 = 0 — копейщик
## во время окна уязвимости должен СТОЯТЬ на месте, чтобы реально получать
## удары в ответ. Skid'овая инерция (0.25с) превращала первую часть окна в
## «уезжающую мишень» — скелет не успевал ткнуть второй раз.
## Velocity спадает от lunge_speed до 0 по slight-skid кривой (медленный
## начальный спад, быстрый в конце). drift_time=0 → drift-фаза проходит
## за 1 кадр с velocity=0 и сразу даёт recovery (standing).
@export var drift_time: float = 0.0
## Пауза «отдышаться» после страйка. Юнит стоит, не ищет цели, не возвращается
## в строй. В этой фазе он максимально уязвим — это часть импакт-ритма.
## 0.5с (после 2026-05-19 урезано с 0.7 — длительный stagger создавал
## ощущение что копейщик «заваливается»; 0.5 даёт скелету windup 0.32-0.48с
## ровно один strike в окно, второй уже за пределом).
@export var recovery_time: float = 0.5
## Лимит дистанции разгона: если цель не доступна в lunge-range за столько
## метров, копейщик отменяет атаку (drift+recovery, ищет новую цель).
@export var max_approach_distance: float = 9.0
## Радиус «охранной области» — копейщик не атакует цели, чей центр вне
## этого радиуса от центра текущего режима (HOLD = указанная точка,
## ESCORT = башня, DEFEND = anchor лагеря).
@export var combat_leash_radius: float = 12.0
## Knockback на скелета при попадании, если он выжил. Δv в направлении
## lunge'а — соразмерен «молниеносному» удару: цель чувствительно
## отбрасывает, видно столкновение «копьё пробило».
@export var strike_knockback_speed: float = 8.0
## Длительность knockback'а (AI цели заглушен это время).
@export var strike_knockback_duration: float = 0.18
@export_group("")

## Per-soldier combat state machine:
##   READY → APPROACH → WINDUP → LUNGE → DRIFT → RECOVERY → READY.
##  - APPROACH: бежит к цели, скорость линейно с 0 до approach_max_speed.
##    Direction обновляется каждый кадр — если цель сдвинется, повернёт.
##    Когда dist ≤ lunge_trigger_range — переходит в WINDUP.
##  - WINDUP: короткая статичная пауза «замаха», тело coiled-позы. Velocity=0,
##    цель ре-проверяется на валидность, direction обновляется на последний
##    кадр перед взрывом. Дизайнерская роль: anticipation — глаз ловит
##    «копейщик согнулся» прежде чем «выстрелил копьём». Без этой фазы
##    рывок сливается с разгоном и читается как «продолжил ускоряться».
##  - LUNGE: молниеносный рывок. Direction зафиксировано на момент входа.
##    Удар в первый кадр когда dist ≤ attack_range. Продолжает лететь
##    `lunge_pass_distance` метров после удара (пролетает насквозь).
##  - DRIFT: занос. Velocity скидывается с lunge_speed по slight ease-in
##    кривой — слабый начальный спад «в заносе», потом гасит до нуля.
##  - RECOVERY: стоит, отдыхает, уязвим. После — READY.
enum CombatState { READY, APPROACH, WINDUP, LUNGE, DRIFT, RECOVERY }

## Тип солдата из SOLDIER_CATALOG. Ставится в setup_soldier.
var soldier_type: StringName = &""
## Ссылка на squad. Назначается Squad.add_member(self). RefCounted —
## пока хотя бы один член держит ссылку или Camp хранит, объект жив.
var _squad: Squad = null
## Цель эскорта при призыве БЕЗ лагеря (setup_free) — обычно башня. Когда задана,
## заменяет _camp.get_tower_position() как центр ESCORT-строя. null у лагерных солдат.
var _escort_target: Node3D = null
## Рабочий (роль &"worker") несёт ЕДИНИЦУ РЕСУРСА (тип ∈ ResourcePile.ResourceType).
## -1 = руки пусты. Тип переключает, какая strike-цель его примет: пусто → источник
## (WoodSource), гружён → склад башни (TowerStore). Единая
## модель «гном → точка → действие» даёт курьерский цикл добыл-донёс без отдельного
## FSM. Воины (копейщик) ресурс не носят — тип всегда -1.
var _carried_type: int = -1
var _worker_carry_visual: MeshInstance3D = null
## Троттл красного кольца «склад полон» — чтобы не спавнить кольцо каждый кадр.
var _store_full_ring_cd: float = 0.0
## Рабочий спрятан ВНУТРИ башни (механика IN_TENT на Tower): невидим, неуязвим,
## вне группы целей скелетов, позиция приклеена к башне. Выходит по команде «Идти сюда».
var _hidden_in_tower: bool = false
## Дистанция до центра башни, на которой рабочий «забегает внутрь» и прячется.
const HIDE_ENTER_RADIUS := 2.2
var _attack_cd: float = 0.0
## Текущая патрульная точка в DEFENDING_CAMP. INF = «нужно выбрать новую»
## (старт или дошли до прежней).
var _defend_patrol_target: Vector3 = Vector3.INF
## Per-soldier флаг: дошёл ли юнит хоть раз до strict-слота после
## последней команды HOLD. Сбрасывается на любое state_changed (новый
## command_hold с другой точкой = новый strict-march с нуля).
##
## Без этого strict-march re-fire'ил бы после каждого combat-displacement'а
## (lunge выбрасывает юнита из слота на 2-5м), и юнит дёргался бы между
## возвратом к слоту и боем — никогда не успевал нанести второй удар.
var _strict_arrived_at_slot: bool = false
var _combat_state: int = CombatState.READY
var _charge_target: Node3D = null
## Зафиксированное направление LUNGE'а — устанавливается на переходе из
## APPROACH'а, дальше не меняется (рывок прямой, цель может уклониться).
var _charge_dir: Vector3 = Vector3.FORWARD
## Стартовая позиция для подсчёта пробега (max_approach_distance в APPROACH'е,
## lunge_pass_distance в LUNGE'е).
var _charge_start_pos: Vector3 = Vector3.ZERO
var _has_struck_this_charge: bool = false
## Накопитель времени в APPROACH'е (для линейного нарастания скорости).
var _approach_elapsed: float = 0.0
## Остаток дистанции пролёта после удара (lunge_pass_distance).
var _post_strike_remaining: float = 0.0
var _drift_remaining: float = 0.0
var _recovery_remaining: float = 0.0
## Таймер WINDUP-фазы — отсчёт до взрыва в LUNGE.
var _windup_remaining: float = 0.0
## Расстояние «прибытия» к squad-target'у. Меньше — стоим (squad-positioning
## не jitter'ит на под-метровых отклонениях).
const SQUAD_TARGET_ARRIVAL: float = 0.4

## Squash & stretch — две выраженные позы вокруг lunge'а. Контраст между
## ними (особенно по Z) даёт визуальный «всплеск»: глаз чётко отделяет
## anticipation от взрыва, без этого рывок сливается со скоростью точки
## по прямой.
##
## POSE_WINDUP — coiled: сжат по Z (forward), расширен по X (sideways).
## Гном «сел и развернулся как пружина», вид сверху — широкий овал поперёк.
## POSE_LUNGE — extended: вытянут по Z, узкий по X. Вид сверху — длинная
## стрелка вдоль направления удара. Z-разница (0.6 → 1.7) почти 3× —
## заметна на капсуле радиуса 0.28м (≈8см контраста по фронту).
##
## Y оставляем близко к 1.0 — растяжение по вертикали конфликтовало бы
## с гравитацией («прыгнул вверх»). Y=0.95 в windup — лёгкая просадка
## «припал». Volume-preservation приблизительная, точная физика не
## нужна — это поза, не симуляция.
const POSE_NEUTRAL: Vector3 = Vector3.ONE
const POSE_WINDUP: Vector3 = Vector3(1.3, 0.95, 0.6)
const POSE_LUNGE: Vector3 = Vector3(0.6, 1.0, 1.7)
## Позы РЕМОНТА — мягче боевых (рабочий «постукивает» по башне, а не таранит насмерть):
## деформация поскромнее, чтобы гном не плющился драматично на каждый удар.
const POSE_REPAIR_WINDUP: Vector3 = Vector3(1.1, 0.98, 0.88)
const POSE_REPAIR_LUNGE: Vector3 = Vector3(0.9, 1.0, 1.16)

## Тайминги переходов между позами. WINDUP-ramp длиннее чем lunge-ramp:
## anticipation должна успеть «прочитаться» (пара кадров наростания + пара
## кадров на пике), lunge-ramp — быстрый снап «выстрелил».
const POSE_WINDUP_TIME: float = 0.06
const POSE_LUNGE_TIME: float = 0.04
const POSE_RESTORE_TIME: float = 0.22

## Длительность статичной WINDUP-фазы. 90мс ≈ 5-6 кадров на 60fps —
## хватает чтобы поза успела наступить и быть видимой пару кадров до
## взрыва. Длиннее — анимация чувствуется как «затянули с ударом»,
## короче — anticipation не успевает прочитаться.
const LUNGE_WINDUP_DURATION: float = 0.09

## Активный tween позы — храним чтобы убить старый при следующем переходе
## (быстрая серия charge'ей: windup → lunge → drift → новый charge).
var _pose_tween: Tween = null


func _ready() -> void:
	# gnome_color для _apply_visual'а — выставляем ДО super._ready чтобы
	# базовый ready взял правильный цвет, если он туда смотрит. Сейчас в
	# Gnome._ready визуал не применяется (только в setup), но на будущее.
	gnome_color = soldier_color
	super._ready()
	add_to_group(SOLDIER_GROUP)


## Override [Gnome._can_flee]: солдат НЕ убегает от угрозы (в отличие от
## мирного гнома-собирателя). Squad-логика управляет его поведением сама —
## копейщик нападает на ближайшего, archer стреляет с позиции. Без override'а
## handler в Gnome'е переключил бы солдата в State.FLEEING на любой alarm,
## ломая squad-AI и убегая прочь.
func _can_flee() -> bool:
	return false


## Конфиг приходит от Camp.recruit_squad на основе SoldierSystem.SOLDIER_CATALOG.
## Stats — Dictionary с ключами hp / enemy_detect_radius / attack_range / damage_min /
## damage_max / cooldown_min / cooldown_max / move_speed. Отсутствующие ключи —
## оставляют @export-дефолты.
func setup_soldier(p_type: StringName, stats: Dictionary, p_camp: Camp, spawn_pos: Vector3) -> void:
	_apply_soldier_stats(p_type, stats)
	global_position = spawn_pos
	# Базовая Gnome-инициализация. home_tent=null — солдат не привязан.
	# setup() вызывает _enter_in_tent внутри, поэтому _finish переводит в
	# outside-режим (visible, в группе skeleton_target, _state свой).
	setup(p_camp, null)
	_finish_soldier_setup()


## Призыв БЕЗ лагеря: солдат следует за escort_target (башней) напрямую. Camp=null;
## за тик-разрешение отвечает _ticks_without_camp(), за центр строя — _tower_center().
## Используется покупкой отряда у гномов (TradeUI.purchased), вне всякого Camp.
func setup_free(p_type: StringName, stats: Dictionary, spawn_pos: Vector3, escort_target: Node3D) -> void:
	_escort_target = escort_target
	_apply_soldier_stats(p_type, stats)
	global_position = spawn_pos
	setup(null, null)
	_finish_soldier_setup()


## Применяет статы каталога (общее для setup_soldier / setup_free).
func _apply_soldier_stats(p_type: StringName, stats: Dictionary) -> void:
	soldier_type = p_type
	hp = float(stats.get("hp", hp))
	enemy_detect_radius = float(stats.get("enemy_detect_radius", enemy_detect_radius))
	attack_range = float(stats.get("attack_range", attack_range))
	attack_damage_min = float(stats.get("attack_damage_min", attack_damage_min))
	attack_damage_max = float(stats.get("attack_damage_max", attack_damage_max))
	attack_cooldown_min = float(stats.get("attack_cooldown_min", attack_cooldown_min))
	attack_cooldown_max = float(stats.get("attack_cooldown_max", attack_cooldown_max))
	if stats.has("move_speed"):
		move_speed = float(stats.move_speed)
	# Цвет типа (рабочие — зелёные, копейщики — рыжие). gnome_color читает
	# setup()→_apply_visual (вызывается ПОСЛЕ этого метода в setup_free).
	if stats.has("color"):
		soldier_color = stats.color
		gnome_color = stats.color


## Общий хвост призыва: выход из палатки в боевой outside-режим.
func _finish_soldier_setup() -> void:
	_state = State.SEARCHING  # любой outdoor-state, AI в _active_tick переопределён
	visible = true
	add_to_group(SKELETON_TARGET_GROUP)
	# Стартовый cd = 0: первый удар после спавна / arrival должен быть
	# мгновенным. Залп копейщиков на charge-attack визуально импактен.
	_attack_cd = 0.0


## SoldierGnome тикает и без Camp, если задана escort-цель (купленный отряд за башней).
func _ticks_without_camp() -> bool:
	return _escort_target != null


## Есть ли контекст центра строя (лагерь ИЛИ escort-цель). Без него squad-
## позиционирование стоит на месте.
func _has_squad_context() -> bool:
	return _camp != null or (_escort_target != null and is_instance_valid(_escort_target))


## Роль «рабочий»: рубит дерево, носит брёвна, строит мост. Не ищет врага (утилита,
## не комбатант — берегите копейщиками). Воин (копейщик) — false.
func is_worker() -> bool:
	return soldier_type == SoldierSystem.ROLE_WORKER


## Намерен ли отряд чинить башню (кнопка «Ремонт» / клик ЛКМ по башне). Гейт для
## Tower.can_gnome_interact: БЕЗ намерения рабочий рядом с башней её НЕ трогает —
## ремонт только по явной команде, не по близости (обычный «иди сюда» — мимо).
func wants_repair() -> bool:
	return _squad != null and _squad.repair_intent


## Контракт для strike-целей: руки заняты? Источник пускает только пустого,
## стройка/склад — только гружёного, горшок — только пустого («не лутает с полными руками»).
func is_carrying() -> bool:
	return _carried_type >= 0


## Тип несомого ресурса (-1 = пусто). Склад/стройка сверяют, что им принесли.
func carried_type() -> int:
	return _carried_type


## Источник выдал единицу ресурса рабочему (WoodSource.gnome_hit) — показываем ношу
## над гномом, цвет по типу (общий ResourcePile.color_for_type — единый язык материалов).
func receive_resource(type: int) -> void:
	_carried_type = type
	if _worker_carry_visual == null:
		_worker_carry_visual = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.72, 0.22, 0.22)
		_worker_carry_visual.mesh = box
		_worker_carry_visual.material_override = StandardMaterial3D.new()
		_worker_carry_visual.position = Vector3(0.0, 1.0, 0.35)  # перед/над гномом
		add_child(_worker_carry_visual)
	(_worker_carry_visual.material_override as StandardMaterial3D).albedo_color = ResourcePile.color_for_type(type)
	_worker_carry_visual.visible = true


## Рабочий сдал единицу (TowerStore). Возвращает ТИП сданного (-1 если рук
## не было — рассинхрон). Вызывающий сверяет тип, если ему нужен конкретный материал.
func deliver_resource() -> int:
	if _carried_type < 0:
		return -1
	var t: int = _carried_type
	_carried_type = -1
	if _worker_carry_visual != null:
		_worker_carry_visual.queue_free()
		_worker_carry_visual = null
	return t


## Площадь сбора вокруг work_point: рабочий рубит ЛЮБЫЕ деревья в этом радиусе от
## указанной точки (а не одно), пока не кончатся — тогда стоит.
const GATHER_AREA_RADIUS := 8.0
## Ресурс, которым строится мост (берётся со склада башни при BUILD).
const BUILD_RESOURCE := ResourcePile.ResourceType.WOOD


## Направленная работа рабочего по area-клику (work_kind отряда). Единая модель:
## ткнул область на цель → идём туда и делаем контекстное действие.
func _tick_worker_order(delta: float) -> void:
	if _store_full_ring_cd > 0.0:
		_store_full_ring_cd -= delta
	if _squad == null:
		velocity = Vector3.ZERO
		return
	match _squad.work_kind:
		Squad.WorkKind.GATHER:
			_tick_gather(delta)
		Squad.WorkKind.BUILD:
			_tick_build(delta)
		Squad.WorkKind.STRIKE:
			_tick_strike_order(delta)
		_:
			_tick_worker_idle()  # NONE — просто стоим у точки


## GATHER: пусто → рубим ближайшее дерево в области work_point; несём → сдаём на склад,
## а если склад ПОЛОН по типу — роняем кучку (ResourceOrb) ПРЯМО ТУТ, у источника
## (башня заберёт магнитом, когда освободится место). Не таскаем к башне впустую.
func _tick_gather(_delta: float) -> void:
	if is_carrying():
		# ДЕРЕВО: продажа казне у башни (2026-07-07) — склад/переполнение не при чём.
		if _carried_type == ResourcePile.ResourceType.WOOD:
			_tick_deposit_to_store()
			return
		# Руда/камень едут в ТРЮМ башни (склад): монетой станут на РАЗГРУЗОЧНОЙ
		# ПЛАТФОРМЕ в городе (2026-07-03; плавильня — чистый сапорт шахты).
		var store := get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
		# Нет склада ИЛИ трюм полон → роняем орб (а не застреваем навсегда с грузом).
		if store == null or store.is_full(_carried_type):
			_drop_carried_as_orb()
		else:
			_tick_deposit_to_store()
		return
	var tree: Node3D = _nearest_in_group_near(Layers.RESOURCE_SOURCE_GROUP, _squad.work_point, GATHER_AREA_RADIUS)
	if tree == null:
		_tick_worker_idle()  # деревья в области кончились — стоим
		return
	_approach_and_hit(tree)


## Склад полон — роняем несомую единицу кучкой ([ResourceOrb]) на своём месте (у
## источника). Рядом есть idle-кучка того же типа → вливаем в неё (не плодим), иначе
## новая. Ношу списываем (deliver_resource). Башня заберёт магнитом, когда будет место.
func _drop_carried_as_orb() -> void:
	velocity = Vector3.ZERO
	var type: int = _carried_type
	# Слияние с соседней idle-кучкой того же типа.
	for o in get_tree().get_nodes_in_group(ResourceOrb.GROUP):
		var orb := o as ResourceOrb
		if orb == null or not is_instance_valid(orb) or not orb.is_idle():
			continue
		if orb.resource_type != type:
			continue
		var dx: float = orb.global_position.x - global_position.x
		var dz: float = orb.global_position.z - global_position.z
		if dx * dx + dz * dz <= ResourceOrb.MERGE_RADIUS * ResourceOrb.MERGE_RADIUS:
			orb.add_units(1)
			deliver_resource()  # ноша ушла в кучку
			return
	# Новой кучки рядом нет — спавним.
	var scene := get_tree().current_scene
	if scene != null:
		var orb := ResourceOrb.new()
		orb.resource_type = type
		orb.amount = 1
		scene.add_child(orb)
		orb.global_position = global_position + Vector3.UP * 0.35
	deliver_resource()  # ноша ушла в кучку


## Радиус поиска дерева для авто-рубки под мост (склад пуст). Покрывает комнату.
const BUILD_WOOD_SEARCH_RADIUS := 60.0

## Радиус поиска блюпринтов, если у башни нет зоны (нет башни/gather_radius=0).
const BUILD_ZONE_FALLBACK_RADIUS := 60.0

## BUILD: достраиваем ВСЕ блюпринты в зоне башни ПО ПОРЯДКУ (ближайший к башне первым).
## Текущая цель достроена/снята → берём следующую в gather_radius башни. Несём ресурс →
## кладём; пусто → берём со склада, склад пуст → рубим ближайшее дерево (замыкаем петлю).
## Зоны нет блюпринтов → сдаём лишнее и встаём.
func _tick_build(_delta: float) -> void:
	var site: Node3D = _squad.work_target if is_instance_valid(_squad.work_target) else null
	if site == null or not site.is_in_group(Layers.BUILD_SITE_GROUP):
		# Цель готова/снята — следующий блюпринт в зоне башни (общий для артели: все
		# гномы детерминированно выбирают ближайший к башне → строят по очереди вместе).
		site = _next_build_site_in_tower_zone()
		if site != null:
			_squad.work_target = site
	if site == null:
		# Все блюпринты в зоне построены: лишний ресурс в руках вернуть на склад, иначе встать.
		if is_carrying():
			_tick_deposit_to_store()
		else:
			velocity = Vector3.ZERO
		return
	if is_carrying():
		_approach_and_hit(site)  # кладём ресурс
		return
	var store := get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
	if store != null and int(store.call(&"get_amount", BUILD_RESOURCE)) > 0:
		_ferry_take_from_store()  # на складе есть запас — несём оттуда
		return
	# Склад пуст: рубим ближайший источник дерева напрямую (получим ресурс в руки → на
	# следующем тике понесём к блюпринту). Источников рядом нет — ждём у блюпринта.
	var tree: Node3D = _nearest_in_group_near(Layers.RESOURCE_SOURCE_GROUP, global_position, BUILD_WOOD_SEARCH_RADIUS)
	if tree != null:
		_approach_and_hit(tree)
	else:
		_approach_point(site.global_position)


## Ближайший к БАШНЕ непостроенный блюпринт (BUILD_SITE_GROUP) в её зоне стройки
## (gather_radius — тот же leash, что у зоны добычи). Детерминирован (по дистанции до
## башни) — вся артель сходится на одну цель, строя по очереди. Нет башни/зоны → fallback
## радиус вокруг себя. null = блюпринтов в зоне нет.
func _next_build_site_in_tower_zone() -> Node3D:
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	var center: Vector3 = global_position
	var radius_sq: float = BUILD_ZONE_FALLBACK_RADIUS * BUILD_ZONE_FALLBACK_RADIUS
	if tower != null:
		center = tower.global_position
		var gr: Variant = tower.get(&"gather_radius")
		var r: float = float(gr) if gr != null else 0.0
		if r > 0.0:
			radius_sq = r * r
	var best: Node3D = null
	var best_d: float = radius_sq
	for n in get_tree().get_nodes_in_group(Layers.BUILD_SITE_GROUP):
		if not is_instance_valid(n):
			continue
		var node3d := n as Node3D
		if node3d == null:
			continue
		var dx: float = node3d.global_position.x - center.x
		var dz: float = node3d.global_position.z - center.z
		var d: float = dx * dx + dz * dz
		if d <= best_d:
			best_d = d
			best = node3d
	return best


## STRIKE: разбить/переключить указанную цель (горшок/рычаг). Несём — сперва сдаём.
func _tick_strike_order(_delta: float) -> void:
	var target: Node3D = _squad.work_target if is_instance_valid(_squad.work_target) else null
	if target == null or not target.is_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
		velocity = Vector3.ZERO  # разбито/переключено (вышло из группы) — стоим
		return
	if is_carrying():
		_tick_deposit_to_store()
		return
	_approach_and_hit(target)


## Подойти к цели ПО НАВМЕШУ и стукнуть НА МЕСТЕ на cooldown'е (gnome_hit: рубит/кладёт/
## разбивает/переключает). Без боевого выпада — рабочий не прошивает точку насквозь.
func _approach_and_hit(target: Node3D) -> void:
	var to := Vector3(target.global_position.x - global_position.x, 0.0, target.global_position.z - global_position.z)
	var d: float = to.length()
	if d > attack_range:
		_move_toward(to, d)
		return
	velocity = Vector3.ZERO
	if d > 0.001:
		look_at(global_position + to / d, Vector3.UP)
	if _attack_cd <= 0.0:
		_strike_at(target)
		_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)


## Идти к точке по навмешу и встать (для idle / ожидания у склада).
func _approach_point(p: Vector3) -> void:
	var to := Vector3(p.x - global_position.x, 0.0, p.z - global_position.z)
	var d: float = to.length()
	if d <= SQUAD_TARGET_ARRIVAL:
		velocity = Vector3.ZERO
		return
	_move_toward(to, d)


## Идём за ресурсом на склад башни: дошёл → берём 1 единицу (BUILD_RESOURCE) в руки.
func _ferry_take_from_store() -> void:
	var store := get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
	if store == null:
		velocity = Vector3.ZERO
		return
	var dest: Vector3 = _tower_center()
	var to := Vector3(dest.x - global_position.x, 0.0, dest.z - global_position.z)
	var d: float = to.length()
	if d > attack_range:
		_move_toward(to, d)
		return
	velocity = Vector3.ZERO
	if int(store.call(&"get_amount", BUILD_RESOURCE)) > 0 and bool(store.call(&"take", BUILD_RESOURCE, 1)):
		receive_resource(BUILD_RESOURCE)


## Нет работы → строимся на слоте режима (HOLD-точка) по навмешу. Так артель не
## разбегается, а стоит кучкой у указанной точки.
func _tick_worker_idle() -> void:
	if _squad == null or not _has_squad_context():
		velocity = Vector3.ZERO
		return
	var goal: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
	_approach_point(goal)


## Ближайший узел группы в радиусе r от точки p (XZ), который примет нас сейчас
## (can_gnome_interact). Для GATHER — ближайшее дерево с ресурсом в области.
func _nearest_in_group_near(group: StringName, p: Vector3, r: float) -> Node3D:
	var best: Node3D = null
	var best_d: float = r * r
	for n in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		if node.has_method(&"can_gnome_interact") and not node.can_gnome_interact(self):
			continue
		var dx: float = node.global_position.x - p.x
		var dz: float = node.global_position.z - p.z
		var dd: float = dx * dx + dz * dz
		if dd < best_d:
			best_d = dd
			best = node
	return best


## Башня повреждена и ждёт ремонта? Сигнал — её членство в gnome_strike_target
## (Tower добавляет себя туда при уроне, убирает на полном HP). Так репорка не
## дёргает hp напрямую — тот же контракт «гном → точка → действие».
func _tower_needs_repair() -> bool:
	var tower := get_tree().get_first_node_in_group(&"tower")
	return tower != null and is_instance_valid(tower) \
			and (tower as Node).is_in_group(Layers.GNOME_STRIKE_TARGET_GROUP)


## Радиус кольца ремонта — рабочие встают ВНЕ модели башни (коллайдер ~1м), видны
## рядом, бьют внутрь. Угол на гнома стабилен (по индексу в отряде) — распределяет
## артель вокруг башни, а не кучей в одной точке.
const REPAIR_RING_RADIUS := 2.6
var _repair_angle: float = INF
## Фаза замаха ремонта: 0=готов, 1=замах (coil), 2=удержание выпада → возврат.
var _repair_swing_phase: int = 0
var _repair_swing_t: float = 0.0


## Шаг ремонта башни: рабочий ИДЁТ К БАШНЕ (на свою точку кольца вокруг неё), и только
## дойдя — чинит замахом-позой (_repair_swing). Был спрятан внутри (в центре, в навмеш-
## hole) → выскакивает на кольцо разом; снаружи и далеко → идёт по навмешу. Так ремонт
## происходит У БАШНИ, а не в точке, где рабочего застала команда.
func _tick_repair_tower(delta: float) -> void:
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower):
		velocity = Vector3.ZERO
		return
	var center: Vector3 = _tower_center()
	if _repair_angle == INF:
		_repair_angle = _compute_repair_angle()
		# Рассинхрон ударов: на старте ремонта у каждого рабочего свой случайный
		# сдвиг cooldown'а — иначе вся артель машет в унисон (стартуют с cd=0 разом).
		_attack_cd = randf_range(0.0, attack_cooldown_max)
	var goal := Vector3(
		center.x + cos(_repair_angle) * REPAIR_RING_RADIUS,
		global_position.y,
		center.z + sin(_repair_angle) * REPAIR_RING_RADIUS)
	# Из прятки (в центре башни, внутри навмеш-hole — путь наружу не строится) —
	# выскакиваем на кольцо телепортом. Иначе — обычный навмеш-подход.
	if _hidden_in_tower:
		_exit_hidden()
		global_position = goal
		velocity = Vector3.ZERO
		return
	var to := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var d: float = to.length()
	if d > SQUAD_TARGET_ARRIVAL:
		_move_toward(to, d)  # идём к башне (на своё место кольца), а не чиним на месте
		return
	# На кольце у башни — лицом к ней, бьём-чиним замахом.
	velocity = Vector3.ZERO
	if Vector2(global_position.x - center.x, global_position.z - center.z).length() > 0.001:
		look_at(Vector3(center.x, global_position.y, center.z), Vector3.UP)
	_repair_swing(delta, tower as Node3D)


## Замах-удар ремонта НА МЕСТЕ (тело не движется — у башни origin приподнят y≈3,
## боевой выпад мерит 3D-дистанцию и в неё бы не попал; плюс рабочий не пролетает
## сквозь модель). Поза копейщика: coil (замах) → выпад + удар-починка (_strike_at —
## надёжно лечит, без дист-гейта) → возврат. Стоим (velocity=0), фазы по таймеру.
func _repair_swing(delta: float, target: Node3D) -> void:
	velocity = Vector3.ZERO
	match _repair_swing_phase:
		0:  # готов — на cooldown'е начинаем замах (мягкая coil-поза)
			if _attack_cd <= 0.0:
				_repair_swing_phase = 1
				_repair_swing_t = LUNGE_WINDUP_DURATION
				_tween_pose_to(POSE_REPAIR_WINDUP, POSE_WINDUP_TIME)
		1:  # замах на исходе → выпад + удар-починка
			_repair_swing_t -= delta
			if _repair_swing_t <= 0.0:
				_tween_pose_to(POSE_REPAIR_LUNGE, POSE_LUNGE_TIME)
				if is_instance_valid(target):
					_strike_at(target)  # gnome_hit → лечит башню + её импакт-FX
				_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
				_repair_swing_phase = 2
				_repair_swing_t = POSE_RESTORE_TIME
		2:  # удержание выпада → возврат в нейтраль
			_repair_swing_t -= delta
			if _repair_swing_t <= 0.0:
				_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)
				_repair_swing_phase = 0


## Стабильный угол на кольце ремонта — по индексу гнома в отряде (равномерно).
func _compute_repair_angle() -> float:
	var idx: int = 0
	var n: int = 1
	if _squad != null:
		var i: int = _squad.members.find(self)
		if i >= 0:
			idx = i
		n = maxi(_squad.members.size(), 1)
	return TAU * float(idx) / float(n)


## Монет за одно сданное бревно (единая валюта, 2026-07-07: рубка = ЗАРАБОТОК,
## дерево-как-ресурс из живого пути убрано; мостки покупаются за монеты).
const WOOD_SALE_BRONZE := 4

func _tick_deposit_to_store() -> void:
	var dest: Vector3 = _tower_center()
	var to := Vector3(dest.x - global_position.x, 0.0, dest.z - global_position.z)
	var d: float = to.length()
	if d > attack_range:
		_move_toward(to, d)
		return
	velocity = Vector3.ZERO
	# ДЕРЕВО продаётся казне прямо на сдаче у башни (склад не участвует): бревно —
	# предмет-носка, монетой становится в момент сдачи. Руда/камень по-прежнему
	# едут в трюм (город: плавильня/разгрузочная платформа).
	if _carried_type == ResourcePile.ResourceType.WOOD:
		var bank := get_tree().get_first_node_in_group(GoldBank.GROUP)
		if bank != null and bank.has_method(&"add_coin"):
			bank.call(&"add_coin", ResourcePile.ResourceType.BRONZE, WOOD_SALE_BRONZE)
			AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
				global_position + Vector3.UP * 0.8, 0.7, 5.0)
			# Попап «+4🥉» над гномом — продажа видна в момент сдачи.
			EventBus.coins_gained_at.emit(WOOD_SALE_BRONZE, global_position)
		deliver_resource()
		return
	var store := get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
	if store == null:
		return
	# Склад полон по этому типу — сдать нельзя: ждём, периодически краснеет кольцо.
	if store.is_full(_carried_type):
		if _store_full_ring_cd <= 0.0:
			AoeVisual.spawn_ground_ring(get_tree().current_scene, dest, 2.2, 0.8, Color(1.0, 0.25, 0.2, 0.9))
			_store_full_ring_cd = 1.2
		return
	if store.deposit(_carried_type, 1) > 0:
		deliver_resource()


## Шаг «спрятаться в башню» (рабочий в ESCORT). Обёртка над _tick_hide_at.
func _tick_hide_in_tower() -> void:
	_tick_hide_at(_tower_center())


## Центр убежища ТРЕВОГИ: ЗАМОК (соц-ядро, группа castle), пока замка нет — башня.
func _shelter_center() -> Vector3:
	var castle := get_tree().get_first_node_in_group(&"castle") as Node3D
	if castle != null and is_instance_valid(castle):
		return castle.global_position
	return _tower_center()


## Шаг «спрятаться в точке dest». Бежит к центру; добежал — прячется
## (невидим/неуязвим/приклеен), как гном IN_TENT в палатке. Уже спрятан →
## остаётся приклеенным к dest (мобильное убежище-башня его «возит»).
func _tick_hide_at(dest: Vector3) -> void:
	if _hidden_in_tower:
		# Приклеены ТОЛЬКО по XZ — origin башни приподнят (y≈3), тянуть
		# рабочего по Y нельзя (повисал бы в воздухе на высоте башни). Y держим
		# наземный (свой текущий) — на выходе из прятки рабочий стоит на полу.
		velocity = Vector3.ZERO
		global_position = Vector3(dest.x, global_position.y, dest.z)
		return
	var to := Vector3(dest.x - global_position.x, 0.0, dest.z - global_position.z)
	var d: float = to.length()
	if d <= HIDE_ENTER_RADIUS:
		_enter_hidden()
		velocity = Vector3.ZERO
	else:
		_move_toward(to, d)  # бежим к убежищу (sprint-догон)


## Спрятался в башню: невидим, вне целей скелетов, неуязвим (см. take_damage),
## боевой стейт сброшен. Несомое бревно сохраняется — выйдет и достроит.
func _enter_hidden() -> void:
	if _hidden_in_tower:
		return
	_hidden_in_tower = true
	visible = false
	if _combat_state != CombatState.READY:
		_reset_combat_state()
	if is_in_group(SKELETON_TARGET_GROUP):
		remove_from_group(SKELETON_TARGET_GROUP)


## Вышел из башни наружу (команда «Идти сюда»): снова видим и уязвим, цель скелетов.
func _exit_hidden() -> void:
	if not _hidden_in_tower:
		return
	_hidden_in_tower = false
	visible = true
	if not is_in_group(SKELETON_TARGET_GROUP):
		add_to_group(SKELETON_TARGET_GROUP)


## Спрятан ли солдат внутри башни сейчас. Публичный контракт для TowerUpgrades:
## лучники внутри = экипаж арбалетных окон (активных стволов = min(окон, экипажа)).
func is_hidden_in_tower() -> bool:
	return _hidden_in_tower


## Спрятанный в башне рабочий неуязвим (как гном IN_TENT). Иначе — обычный урон.
func take_damage(amount: float) -> void:
	if _hidden_in_tower:
		return
	super.take_damage(amount)


## Squad назначает себя на add_member. Двусторонняя ссылка нужна юниту
## чтобы запросить target_for_member и читать squad.state. На смерть юнита
## squad сам отлавливает destroyed-сигнал и убирает из members'а.
##
## Подписываемся на state_changed — на любое изменение команды (новый
## hold-pos, переход на escort/defend) сбрасываем _strict_arrived_at_slot,
## чтобы strict-march снова отработал «один раз до слота».
func set_squad(squad: Squad) -> void:
	_squad = squad
	if squad != null and not squad.state_changed.is_connected(_on_squad_state_changed):
		squad.state_changed.connect(_on_squad_state_changed)


func _on_squad_state_changed() -> void:
	_strict_arrived_at_slot = false


## Override базового AI. Combat — charge-attack state machine:
##   1. Cooldown удара тикает всегда.
##   2. **Strict-march** (HOLD после `command_hold`): идём к слоту,
##      игнорируя бой; любой активный charge сбрасываем — точное указание
##      места приоритетнее боевого ритма.
##   3. Если в CHARGING/DECEL — продолжаем state machine, не дёргаем squad.
##   4. READY: ищем цель в `combat_leash_radius`е от центра режима. Есть
##      цель и cooldown готов → стартуем charge. Нет — squad-positioning
##      (HOLD/ESCORT кольцо или DEFEND patrol).
func _active_tick(delta: float) -> void:
	if _attack_cd > 0.0:
		_attack_cd -= delta

	# Рабочий + режим ESCORT = «спрятаться в башню» (не вставать рядом, как
	# копейщики, а забежать ВНУТРЬ — рабочие не воюют). Прячемся механикой
	# IN_TENT, наведённой на башню. Команда «Идти сюда» (HOLD) выводит из
	# башни на стройку. См. _tick_hide_in_tower / _enter_hidden / _exit_hidden.
	if is_worker():
		# ТРЕВОГА (Population.alarm_active, клавиша V): рабочий бросает любой
		# приказ и прячется в убежище — замок, пока замка нет — башня. Той же
		# IN_TENT-механикой; отбой тревоги → обычные ветки выведут наружу.
		if Population != null and Population.alarm_active:
			_tick_hide_at(_shelter_center())
			return
		if _squad != null and _squad.state == Squad.State.ESCORTING_TOWER:
			# «Ремонт башни» (кнопка): вместо прятки ВЫХОДИМ ИЗ башни наружу, встаём
			# в кольцо вокруг неё (физически видны рядом) и бьём-чиним внутрь.
			# Башня отремонтирована → сбрасываем намерение и прячемся обратно внутрь.
			if _squad.repair_intent and _tower_needs_repair():
				_tick_repair_tower(delta)
				return
			if _squad.repair_intent:
				_squad.repair_intent = false
				_repair_angle = INF  # следующий ремонт пере-распределит по кольцу
				_repair_swing_phase = 0  # ремонт окончен — сбросить замах
				_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)
			_tick_hide_in_tower()
			return
		if _hidden_in_tower:
			_exit_hidden()  # сменили на HOLD/строить — выходим наружу
		# Направленная работа по area-клику (work_kind): GATHER/BUILD/STRIKE/идти.
		# Рабочий НЕ воюет и НЕ делает боевой выпад — подходит ПО НАВМЕШУ и бьёт НА МЕСТЕ.
		_tick_worker_order(delta)
		return

	# «В башню» для КОПЕЙЩИКОВ (флаг hide_in_tower): прячутся ВНУТРЬ башни (неуязвимы),
	# той же IN_TENT-механикой, что рабочие — но по отдельной команде, НЕ вместо боевого
	# эскорта «За башней». Рабочие сюда не доходят (их прятка — выше, в is_worker-ветке).
	if _squad != null and _squad.state == Squad.State.ESCORTING_TOWER and _squad.hide_in_tower:
		_tick_hide_in_tower()
		return
	if _hidden_in_tower:
		_exit_hidden()  # сменили команду на эскорт/бой → выходим из башни

	# Strict-march: ИНИЦИАЛЬНОЕ исполнение команды «Идти сюда» — идём
	# к слоту напролом. Combat-assist: если по дороге попался враг в
	# lunge-range — НЕ тормозим у слота, а вбегаем в lunge напрямую.
	# Игрок указал точку на врагов (красная подсветка zone-индикатора) —
	# отряд должен «вбежать в бой», а не тормозить и потом атаковать.
	# После первого прибытия (`_strict_arrived_at_slot`) переключаемся на
	# нормальное поведение: combat-приоритет, возврат в строй когда нет
	# цели. Иначе lunge выбрасывал бы из слота, strict снова марш back,
	# и юнит дёргался.
	if _squad != null and _has_squad_context() \
			and _squad.state == Squad.State.HOLDING_POSITION \
			and _squad.is_strict_move() \
			and not _strict_arrived_at_slot:
		if _combat_state != CombatState.READY:
			_reset_combat_state()
		# Combat-assist на марше: ловим близкого врага и бьём с ходу. Рабочий —
		# не комбатант, врага не ловит (только марш к слоту, потом стройка).
		if _attack_cd <= 0.0 and not is_worker():
			var assist_target: Node3D = _find_target_in_leash()
			if assist_target != null:
				var to_assist: float = global_position.distance_to(assist_target.global_position)
				if to_assist <= lunge_trigger_range:
					_strict_arrived_at_slot = true
					_start_charge(assist_target)
					return
		var goal_strict: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
		var to_goal_strict := Vector3(goal_strict.x - global_position.x, 0.0, goal_strict.z - global_position.z)
		var dist_strict: float = to_goal_strict.length()
		if dist_strict > SQUAD_TARGET_ARRIVAL:
			_move_toward(to_goal_strict, dist_strict)
			return
		# Дошёл первый раз — фиксируем и больше strict не блокирует бой.
		_strict_arrived_at_slot = true

	# Внутри charge/decel — гонит state machine, squad-логика не вмешивается.
	if _combat_state != CombatState.READY:
		_tick_charge_state(delta)
		return

	# READY: пробуем стартовать новый charge, если cooldown готов и есть цель
	# в leash-области. Иначе — squad-движение.
	if _attack_cd <= 0.0:
		# Рабочий врага не ищет (утилита, не комбатант) — сразу к strike-точке
		# (дерево/стройка/горшок). Копейщик — враг в приоритете, утварь когда чисто.
		var target: Node3D = null
		if not is_worker():
			target = _find_target_in_leash()
		# Нет врага → ищем strike-точку; кто может — решает сама цель
		# (can_gnome_interact: дерево/стройка → роль+ноша, горшок → can_loot). Тем же зарядом.
		if target == null:
			target = _find_interact_target_in_leash()
		if target != null:
			_start_charge(target)
			return

	if _squad == null or not _has_squad_context():
		velocity = Vector3.ZERO
		return
	if _squad.state == Squad.State.DEFENDING_CAMP:
		_tick_defend_patrol()
		return
	var goal: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
	var to_goal_xz := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var dist: float = to_goal_xz.length()
	if dist <= SQUAD_TARGET_ARRIVAL:
		velocity = Vector3.ZERO
		return
	_move_toward(to_goal_xz, dist)


## Шаг state machine во всех нон-READY стейтах. Velocity полностью
## управляется здесь — squad-positioning не вмешивается до возврата в READY.
func _tick_charge_state(delta: float) -> void:
	match _combat_state:
		CombatState.APPROACH:
			# Цель умерла во время разгона — отменяем без штрафа cd.
			if not is_instance_valid(_charge_target):
				_enter_recovery(recovery_time)
				return
			# Re-aim каждый кадр: если цель сдвинулась, корректируем курс.
			var to_t := Vector3(
				_charge_target.global_position.x - global_position.x,
				0.0,
				_charge_target.global_position.z - global_position.z,
			)
			var dist_t: float = to_t.length()
			if dist_t > 0.001:
				var dir := to_t / dist_t
				look_at(global_position + dir, Vector3.UP)
				_approach_elapsed += delta
				var spd_t: float = clampf(_approach_elapsed / maxf(approach_accel_time, 0.001), 0.0, 1.0)
				velocity = dir * (approach_max_speed * spd_t)
			# Триггер windup: подбежали достаточно близко — переходим в coiled-позу.
			# Лunge стартует не отсюда, а из WINDUP-фазы после anticipation-паузы.
			if dist_t <= lunge_trigger_range:
				_charge_dir = (to_t / dist_t) if dist_t > 0.001 else _charge_dir
				_combat_state = CombatState.WINDUP
				_windup_remaining = LUNGE_WINDUP_DURATION
				velocity = Vector3.ZERO
				_tween_pose_to(POSE_WINDUP, POSE_WINDUP_TIME)
				return
			# Превысили лимит разгона без сближения — отменяем атаку (короткий drift).
			var approach_run: float = global_position.distance_to(_charge_start_pos)
			if approach_run > max_approach_distance:
				_enter_drift(drift_time * 0.5)
		CombatState.WINDUP:
			# Юнит замер в coiled-позе. Velocity жёстко 0 — никаких физических
			# дрейфов от наследия APPROACH-velocity. Look-at обновляем чтобы
			# в момент взрыва быть лицом к цели (за 90мс она может сдвинуться).
			velocity = Vector3.ZERO
			if not is_instance_valid(_charge_target):
				# Цель умерла во время замаха — отмена без удара.
				_enter_recovery(recovery_time)
				return
			var to_w := Vector3(
				_charge_target.global_position.x - global_position.x,
				0.0,
				_charge_target.global_position.z - global_position.z,
			)
			var dist_w: float = to_w.length()
			if dist_w > 0.001:
				var dir_w := to_w / dist_w
				look_at(global_position + dir_w, Vector3.UP)
				_charge_dir = dir_w  # фиксируем направление на момент release
			_windup_remaining -= delta
			if _windup_remaining <= 0.0:
				# Взрыв: переход в LUNGE с уже коректным направлением. Snap-tween
				# на lunge-позу за POSE_LUNGE_TIME (40мс) — это и есть «выстрел».
				_charge_start_pos = global_position
				_post_strike_remaining = lunge_pass_distance
				_has_struck_this_charge = false
				_combat_state = CombatState.LUNGE
				velocity = _charge_dir * lunge_speed
				_tween_pose_to(POSE_LUNGE, POSE_LUNGE_TIME)
		CombatState.LUNGE:
			velocity = _charge_dir * lunge_speed
			if not _has_struck_this_charge:
				if is_instance_valid(_charge_target):
					var dist_lunge: float = global_position.distance_to(_charge_target.global_position)
					if dist_lunge <= attack_range:
						_strike_at(_charge_target)
						_has_struck_this_charge = true
						_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
				else:
					# Цель умерла в воздухе — продолжаем по инерции до конца pass.
					_has_struck_this_charge = true
			if _has_struck_this_charge:
				_post_strike_remaining -= lunge_speed * delta
				if _post_strike_remaining <= 0.0:
					_enter_drift(drift_time)
			else:
				# Промах в процессе lunge'а: лимит пробега.
				var lunge_run: float = global_position.distance_to(_charge_start_pos)
				if lunge_run > lunge_pass_distance + 1.5:
					_enter_drift(drift_time)
		CombatState.DRIFT:
			_drift_remaining -= delta
			if _drift_remaining <= 0.0:
				_combat_state = CombatState.RECOVERY
				_recovery_remaining = recovery_time
				velocity = Vector3.ZERO
				return
			# Skid-curve: pow(t, 0.6) — медленный начальный спад («занос держит
			# инерцию»), резкий в конце. t=1 → speed=lunge; t=0 → 0.
			var dt_t: float = clampf(_drift_remaining / maxf(drift_time, 0.001), 0.0, 1.0)
			var skid_speed: float = lunge_speed * pow(dt_t, 0.6)
			velocity = _charge_dir * skid_speed
		CombatState.RECOVERY:
			velocity = Vector3.ZERO
			_recovery_remaining -= delta
			if _recovery_remaining <= 0.0:
				_combat_state = CombatState.READY
				_charge_target = null


## Старт атаки: переход в APPROACH. Скорость стартует с 0 и нарастает
## линейно за approach_accel_time. Lunge запускается из WINDUP-фазы после
## APPROACH'а, поэтому даже если цель уже в lunge-range — пропускаем разгон
## и сразу садимся в coiled-позу (windup).
func _start_charge(target: Node3D) -> void:
	_charge_target = target
	_charge_start_pos = global_position
	_has_struck_this_charge = false
	_post_strike_remaining = lunge_pass_distance
	_approach_elapsed = 0.0
	var to_target := Vector3(
		target.global_position.x - global_position.x,
		0.0,
		target.global_position.z - global_position.z,
	)
	var d: float = to_target.length()
	if d > 0.001:
		_charge_dir = to_target / d
		look_at(global_position + _charge_dir, Vector3.UP)
	# Если цель уже в lunge-range — пропускаем разгон, сразу в WINDUP (coiled).
	# Anticipation важна даже в упор: без неё рывок в трёх метрах от цели
	# выглядит как «дёрнулся вперёд», а не как удар.
	if d <= lunge_trigger_range:
		_combat_state = CombatState.WINDUP
		_windup_remaining = LUNGE_WINDUP_DURATION
		velocity = Vector3.ZERO
		_tween_pose_to(POSE_WINDUP, POSE_WINDUP_TIME)
	else:
		_combat_state = CombatState.APPROACH
		velocity = Vector3.ZERO


## Тwееn-переход тела + facing-индикатора к указанной позе за `duration`.
## Параллельный tween на двух нодах — синхронно. Старый tween (если есть)
## убивается чтобы не было перекрытия (например быстрый WINDUP→LUNGE
## не должен ждать завершения windup-ramp'а — он стартует с момента, на
## котором windup был, и идёт в lunge-pose).
##
## FacingIndicator — необязательная нода (только у Pikeman'а, в base Gnome
## её нет). Через get_node_or_null чтобы не падать на других классах.
## _mesh — onready из Gnome, MeshInstance3D тела.
func _tween_pose_to(target: Vector3, duration: float) -> void:
	if _mesh == null:
		return
	if _pose_tween != null and _pose_tween.is_valid():
		_pose_tween.kill()
	var facing: Node3D = get_node_or_null(^"FacingIndicator") as Node3D
	_pose_tween = create_tween()
	_pose_tween.set_parallel(true)
	_pose_tween.tween_property(_mesh, "scale", target, duration).set_ease(Tween.EASE_OUT)
	if facing != null:
		_pose_tween.tween_property(facing, "scale", target, duration).set_ease(Tween.EASE_OUT)


## Переход в DRIFT с заданной длительностью + восстановление позы. Один
## хелпер, потому что все три места выхода в DRIFT (успешный pass, промах,
## превышение approach-лимита) должны и state переключить, и позу вернуть.
func _enter_drift(d: float) -> void:
	_combat_state = CombatState.DRIFT
	_drift_remaining = d
	_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)


## Переход в RECOVERY (без DRIFT) — для случая «цель умерла в APPROACH'е /
## WINDUP'е», восстанавливаем нейтральную позу.
func _enter_recovery(r: float) -> void:
	_combat_state = CombatState.RECOVERY
	_recovery_remaining = r
	velocity = Vector3.ZERO
	_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)


## Принудительный сброс боевого state machine'а (для strict-march override
## когда игрок указал новую точку командой Hold). Поза тоже сбрасывается —
## без этого юнит мог бы пойти к слоту в windup/lunge-форме.
func _reset_combat_state() -> void:
	_combat_state = CombatState.READY
	_charge_target = null
	_approach_elapsed = 0.0
	_post_strike_remaining = 0.0
	_drift_remaining = 0.0
	_recovery_remaining = 0.0
	_windup_remaining = 0.0
	_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)


## Патрульный шаг для DEFENDING_CAMP: юнит выбирает точку на навмеше в зоне лагеря
## и идёт к ней ЧЕРЕЗ навмеш (`_resolve_path_step` огибает стены/здания по улицам,
## не упирается в них), по прибытии выбирает следующую. Скорость — ровный walk
## `defend_patrol_speed` (не adaptive-sprint `_move_toward`: патруль это прогулка
## по улицам, а не догон строя). На бой переключается из `_active_tick` (combat-
## проверка ВЫШЕ этого блока).
func _tick_defend_patrol() -> void:
	var center: Vector3 = _resolve_squad_center()
	if _defend_patrol_target == Vector3.INF:
		_defend_patrol_target = _pick_defend_patrol_point(center)
	var to_target := Vector3(
		_defend_patrol_target.x - global_position.x, 0.0,
		_defend_patrol_target.z - global_position.z)
	if to_target.length() < defend_patrol_arrival:
		_defend_patrol_target = _pick_defend_patrol_point(center)
	# Шаг по навмешу к патрульной точке — обход зданий по «улицам», а не в стену.
	var step_target: Vector3 = _resolve_path_step(_defend_patrol_target)
	var step_dir := Vector3(step_target.x - global_position.x, 0.0, step_target.z - global_position.z)
	if step_dir.length_squared() < VecUtil.EPSILON_SQ:
		velocity = Vector3.ZERO
		return
	step_dir = step_dir.normalized()
	look_at(global_position + step_dir, Vector3.UP)
	velocity = step_dir * defend_patrol_speed


## Патрульная точка: случайный угол + случайный радиус в кольце [0.3R..R] вокруг
## центра лагеря (роум по РАЗНЫМ кольцам-улицам, а не одной окружности), затем
## проекция на ближайшую точку навмеша (`_snap_to_navmesh`) → точка ВСЕГДА на
## улице между зданиями и достижима. R = `defend_patrol_radius`.
func _pick_defend_patrol_point(center: Vector3) -> Vector3:
	var angle: float = randf() * TAU
	var radius: float = lerpf(defend_patrol_radius * 0.3, defend_patrol_radius, randf())
	var p := Vector3(center.x + cos(angle) * radius, center.y, center.z + sin(angle) * radius)
	return _snap_to_navmesh(p)


## Резолв центра кольца отряда исходя из squad.state. Squad — RefCounted
## без ссылки на Camp, поэтому контекст лагеря (anchor / tower) собираем
## здесь и пробрасываем готовым Vector3'ом.
##
## - HOLDING_POSITION → точка, которую указал игрок.
## - ESCORTING_TOWER → текущая позиция башни.
## - DEFENDING_CAMP → anchor развёрнутого лагеря; на свёртке (anchor stale) —
##   fallback на башню (мини-эскорт), чтобы юниты не «защищали» пустое
##   место после переезда. Когда лагерь снова развернут — auto-возврат к
##   anchor'у на следующем тике.
func _resolve_squad_center() -> Vector3:
	if _squad == null:
		return global_position
	match _squad.state:
		Squad.State.HOLDING_POSITION:
			return _squad.hold_position
		Squad.State.ESCORTING_TOWER:
			return _tower_center()
		Squad.State.DEFENDING_CAMP:
			if _camp != null and _camp.is_deployed():
				return _camp.deploy_anchor
			return _tower_center()
	return global_position


## Позиция башни как центр строя: из лагеря (get_tower_position) или напрямую из
## escort-цели (призыв без Camp). Fallback — собственная позиция.
func _tower_center() -> Vector3:
	if _camp != null and _camp.has_method(&"get_tower_position"):
		return _camp.get_tower_position()
	if _escort_target != null and is_instance_valid(_escort_target):
		return _escort_target.global_position
	return global_position


## Адаптивная скорость по образцу DefenderGnome._tick_following_caravan:
## близко к слоту — walk на base move_speed; далеко — лerp к caravan_sprint_speed
## (унаследованные exports из Gnome). Это даёт «строй идёт спокойно, отстающие
## догоняют бегом» — критично для эскорта подвижной башни и для быстрого
## исполнения команды «Идти сюда» через всю карту.
##
## Pathfinding: путь к финальной цели (`global_position + to_goal_xz`) идёт
## через [Gnome._resolve_path_step] — обходит стены/палатки. Скорость
## sprint'а считается от **финальной** дистанции, не от шага path'а:
## юнит не должен замедляться на промежуточных waypoint'ах.
func _move_toward(to_goal_xz: Vector3, dist: float) -> void:
	var final_goal: Vector3 = global_position + to_goal_xz
	var step_target: Vector3 = _resolve_path_step(final_goal)
	var step_dir: Vector3 = step_target - global_position
	step_dir.y = 0.0
	if step_dir.length_squared() < VecUtil.EPSILON_SQ:
		velocity = Vector3.ZERO
		return
	step_dir = step_dir.normalized()
	look_at(global_position + step_dir, Vector3.UP)
	var speed: float = _sprint_speed_for(dist)
	velocity = step_dir * speed


## Цель в `enemy_detect_radius`е + охранной зоне (`combat_leash_radius` от
## центра режима), ТОЛЬКО если её ещё никто из своих не атакует. Если все
## цели в зоне уже заняты — null, копейщик возвращается в строй (формация
## вокруг центра режима / patrol). Дизайн: каждый бьёт своего; целей
## меньше чем юнитов → лишние стоят и ждут.
##
## Claim считается per-tick через скан SOLDIER_GROUP. Дёшево: ~500 ops/сек
## на юнита (10 копейщиков × 5 кандидатов × ~10 сканов/сек между charge'ами).
##
## Скан по `Enemy.ENEMY_GROUP` — все наследники Enemy: melee-Skeleton + Archer +
## Giant + Thrower + любой будущий тип. SKELETON_GROUP-only был бы асимметрией:
## SkeletonArcher и SkeletonGiantThrower extends Archer не входят в SKELETON_GROUP
## (она только melee-Skeleton'ы) → копейщики игнорировали бы их и игрок не смог
## бы их «отправить туда». См. [[feedback-symmetric-interactions]].
##
## ENEMY_GROUP — и NEAR, и FAR-LOD враги (в отличие от broad-phase, которая
## FAR-Skeleton'ов пропускает). Archer'ы и гиганты — без LOD'а, всегда видимы.
func _find_target_in_leash() -> Node3D:
	# БЕЗ зоны-leash'а от центра строя: воюющие юниты вступают в бой по СВОЕМУ радиусу
	# обнаружения (enemy_detect_radius), не привязаны к зоне (решение юзера 2026-06-21).
	var detect_sq: float = enemy_detect_radius * enemy_detect_radius
	var nearest: Enemy = null
	var nearest_d_sq: float = detect_sq
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		var enemy := n as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var d_sq: float = (enemy.global_position - global_position).length_squared()
		if d_sq >= detect_sq:
			continue
		if _is_target_claimed_by_other(enemy):
			continue
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = enemy
	return nearest


## Strike-цель (горшок/рычаг, группа gnome_strike_target) в combat_leash_radius от
## центра режима + enemy_detect_radius от себя. Только когда нет врага. Цель сама
## решает, годится ли гном (can_gnome_interact: горшок→can_loot, рычаг→роль).
## Ближайшая подходящая. См. [[feedback-symmetric-interactions]].
func _find_interact_target_in_leash() -> Node3D:
	# Только КОПЕЙЩИКИ (утварь/рычаги в бою): цель в боевом leash'е от центра строя,
	# чтобы не убегать от башни. Рабочие сюда не ходят — у них направленный work_order
	# (см. _tick_worker_order), цели берутся явно по area-клику.
	var leash_center: Vector3 = _resolve_squad_center()
	var leash_sq: float = combat_leash_radius * combat_leash_radius
	var nearest: Node3D = null
	var nearest_d_sq: float = enemy_detect_radius * enemy_detect_radius
	for n in get_tree().get_nodes_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
		if not is_instance_valid(n):
			continue
		var node3d := n as Node3D
		if node3d == null:
			continue
		if node3d.has_method(&"can_gnome_interact") and not node3d.can_gnome_interact(self):
			continue
		var dx_l: float = node3d.global_position.x - leash_center.x
		var dz_l: float = node3d.global_position.z - leash_center.z
		if dx_l * dx_l + dz_l * dz_l > leash_sq:
			continue
		var d_sq: float = (node3d.global_position - global_position).length_squared()
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = node3d
	return nearest


## True если другой копейщик (НЕ self) уже выбрал эту цель в активной
## боевой фазе (APPROACH / LUNGE / DRIFT). RECOVERY-юниты освобождают
## claim — цель снова свободна для следующего.
##
## Дизайн: каждый бьёт своего. Целей меньше чем юнитов → лишние стоят
## в формации до RECOVERY первого, потом подхватывают.
func _is_target_claimed_by_other(target: Node3D) -> bool:
	for s in get_tree().get_nodes_in_group(SOLDIER_GROUP):
		if s == self or not is_instance_valid(s):
			continue
		var sg := s as SoldierGnome
		if sg == null:
			continue
		match sg._combat_state:
			CombatState.APPROACH, CombatState.LUNGE, CombatState.DRIFT:
				if sg._charge_target == target:
					return true
	return false


## Контактный удар: damage через `Damageable.try_damage`. Если цель выжила
## (не убита с первого удара) — лёгкий knockback в направлении lunge'а.
## Это даёт visual impact «врезался копьём, скелета отшатнуло», а не
## «прошёл насквозь без реакции».
##
## Knockback применяется ТОЛЬКО на survival, чтобы не толкать уже
## queue_free'нутый труп (бесполезно + лишняя физика на пачку умирающих).
func _strike_at(target: Node3D) -> void:
	# Strike-цель (горшок/рычаг) — бьём через gnome_hit, без enemy-логики
	# (knockback/squad-charge). Горшок разбивается, рычаг перекидывается.
	if target.is_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
		if target.has_method(&"gnome_hit"):
			# Передаём себя: дерево/стройка кредитуют/списывают бревно у этого гнома.
			target.call(&"gnome_hit", self)
		return
	var damage: float = randf_range(attack_damage_min, attack_damage_max)
	Damageable.try_damage(target, damage)
	# Survival-чек через hp: try_damage может вызвать queue_free, но
	# is_instance_valid останется true до конца кадра. hp поле есть у Enemy.
	var alive: bool = is_instance_valid(target) and "hp" in target and target.hp > 0.0
	if alive:
		Pushable.try_push(target, _charge_dir * strike_knockback_speed, strike_knockback_duration)
	# Squad charge-абилка убрана (overload, дублировала контроль толпы у башни) —
	# на kill ничего не копим. Ценность отряда: число + автобой + утилита.
	if debug_log and LogConfig.master_enabled:
		print("[SoldierGnome:%s] удар по %s (dmg=%.1f, alive=%s)" % [name, target.name, damage, str(alive)])
