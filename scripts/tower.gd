class_name Tower
extends CharacterBody3D
## Башня — управляется WASD.
## Если башня тяжелее, чем встретившийся Item, она толкает его телом при движении.
## Имеет HP — враги наносят урон через take_damage(amount).

## Минимальная компонента intended_velocity в направлении врага, ниже которой
## считаем, что башня в эту сторону не едет — knockback не применяем.
const MIN_PUSH_VELOCITY := 0.1

## Группа для дискаверинга башни без NodePath. HandSpellFireball спавнит
## фаербол из позиции башни (Tower не один в сцене теоретически — если
## когда-то появится мульти-башня, get_first_node_in_group вернёт первого,
## фаербол всё равно стартует из «какой-то» башни — приемлемо для прототипа).
const GROUP := &"tower"

signal damaged(amount: float)
signal destroyed
## Текущий HP изменился (например, после take_damage). Используется HUD'ом
## для отрисовки полоски здоровья. Стартовый emit идёт из _ready.
signal health_changed(current: float, maximum: float)
## Текущая мана изменилась — потрачена касто́м или восстановлена реген'ом.
## HUD рисует полоску маны, hand_spell_fireball.gd дёргает try_consume_mana.
signal mana_changed(current: float, maximum: float)

@export var move_speed: float = 8.0
@export var gravity: float = 20.0
@export var mass: float = 10.0
## Максимум HP. Текущее значение в `hp`, сетится в _ready = max_hp. Урон —
## через take_damage(amount). Смерть при hp ≤ 0.
@export var max_hp: float = 1000.0
## Сколько HP восстанавливает ОДИН удар гнома-ремонтника (gnome_hit). Башня — strike-цель
## (gnome_strike_target), пока повреждена; рабочие чинят ударами (кнопка «Ремонт башни»
## / «иди сюда» к башне). 7 рабочих × ~1 удар/с × это значение = скорость починки.
@export var repair_per_hit: float = 25.0
## Reach-бонус для расчётов «бьём с края» (Enemy.target_reach_bonus + AOE-фильтр
## AoeDamage). Башня широкая (коллизия 2×2) — её центр дальше малого radius'а
## взрыва/strike'а, хотя коллайдер задет. ≈ полу-размер по XZ (1.0). Без него
## мины/мелкие AOE рвались бы у борта башни вхолостую.
@export var attack_reach_bonus: float = 1.0

@export_group("Mana")
## Максимум маны. Магические действия (Fireball и т.п.) тратят её через
## try_consume_mana. Физика руки (Slam/Flick/grab) маны не требует.
@export var max_mana: float = 100.0
## Скорость регенерации маны, единиц в секунду. 0.8 даёт ~125с до полного рестора
## после 4 кастов фаербола (cost=25 каждый) — выстрелы очень дорогие, каждый каст
## на счету.
@export var mana_regen_rate: float = 0.8

@export_group("Push Items")
@export var push_strength: float = 1.0

@export_group("Push Enemies")
## Множитель горизонтальной скорости, с которой башня сообщает врагу knockback.
## 1.0 — враг получает свою-же-скорость, 1.5 — чуть быстрее, чтобы выходить из-под башни.
@export var enemy_push_speed_factor: float = 1.5
## Длительность knockback'а врагу. Малое значение, потому что в контакте мы
## refresh'им knockback каждый физкадр.
@export var enemy_push_duration: float = 0.2

@export_group("Dash (рывок, Space)")
## Скорость броска (м/с) — заметно выше move_speed. Рывок перекрывает обычное
## движение на dash_duration.
@export var dash_speed: float = 22.0
## Длительность активной фазы рывка (сек). dash_speed × dash_duration ≈ путь
## (22 × 0.24 ≈ 5.3м).
@export var dash_duration: float = 0.24
## Кулдаун между рывками (сек).
@export var dash_cooldown: float = 0.8
## Трейл: спавнить after-image-призраки во время рывка. Сам визуал рывка (наклон/
## стретч/призраки) — общий с врагом-мехом, см. [DashFx] (тюнинг там).
@export var dash_trail_enabled: bool = true
## Урон по СКЕЛЕТАМ при таране рывком (врезался — задавил). Только скелеты, мех
## исключён (как у щита). 100 убивает обычных (hp=30) сразу; гигантов лишь дробит.
## Каждого скелета бьём раз за рывок (без мультихита). 0 = дэш урона не наносит.
@export var dash_damage: float = 100.0

@export_group("Super Dash (зажать Space → прицел → ПКМ)")
## Сколько секунд держать Space, чтобы из обычного рывка перейти в прицел супер-
## рывка. Короткий тап (< порога) = обычный рывок без слоумо. Чем меньше — тем
## «острее» тап, но легче случайно войти в прицел при обычном нажатии. 0.3с —
## обычный тап (≈50-150мс) гарантированно не дотягивает, осознанный зажим — да.
@export var super_dash_hold_threshold: float = 0.3
## Скорость супер-рывка (м/с). Выше обычного — длиннее бросок при той же фазе.
@export var super_dash_speed: float = 34.0
## Длительность фазы супер-рывка. 34 × 0.34 ≈ 11.5м — заметно дальше обычного (5.3м).
@export var super_dash_duration: float = 0.34
## Урон по скелетам при таране супер-рывком. Выше обычного (100) — давит и крупных.
@export var super_dash_damage: float = 250.0
## Стоимость супер-рывка в мане. Списывается на коммите (ПКМ).
@export var super_dash_mana_cost: float = 50.0
## Engine.time_scale во время прицеливания (как у Super-QTE). 0.15 = 6.7× слоумо.
@export var super_dash_time_scale: float = 0.15
## Радиус синего кольца-прицела на земле (в точке руки).
@export var super_dash_marker_radius: float = 2.2
## Цвет кольца-прицела. Синий с блумом (emission бустится при спавне).
@export var super_dash_marker_color: Color = Color(0.3, 0.62, 1.0, 0.95)
## Цвет/прозрачность затемнения экрана на время прицеливания. Лёгкое (alpha ~0.3),
## синевато-тёмное — фокус на прицеле, тот же язык что у Super-QTE, но мягче.
@export var super_dash_dim_color: Color = Color(0.02, 0.03, 0.06, 0.32)

@export_group("Parry (парирование, Q)")
## Тайминг-парирование: короткое окно, в которое любой вражеский снаряд
## (Reflectable.GROUP) в радиусе разворачивается обратно в стрелка и становится
## дружественным. Чистый скилл — гейт только по кулдауну, маны не требует.
@export var parry_enabled: bool = true
## Длительность активного окна отражения (сек). Короткое — награждает реакцию на
## телеграф/подлёт снаряда, а не зажатие.
@export var parry_window: float = 0.25
## Кулдаун между парированиями (сек) — нельзя спамить, надо ловить момент.
@export var parry_cooldown: float = 1.5
## Радиус ловли снарядов (м, 360° вокруг башни). Достаточно большой, чтобы отбить
## на подлёте, но не вся карта.
@export var parry_radius: float = 6.0
## Цвет щита/волны отражения (ледяной — отличен от оранжевых вражеских телеграфов
## и голубого recall'а).
@export var parry_color: Color = Color(0.5, 0.9, 1.0, 0.95)
## Урон щита по СКЕЛЕТАМ в зоне при подъёме (только скелеты, НЕ мех/башня/гномы).
## 100 убивает обычных (hp=30) и лучников наповал; гиганты (высокий hp) лишь
## получают урон. Разовый импульс на активацию — не тикает каждый кадр. 0 = выкл.
@export var parry_skeleton_damage: float = 100.0

@export_group("Death explosion (детонация при смерти)")
## Башня детонирует при гибели — урон по площади (враги + постройки + палисад +
## ядро). 0 = радиус выкл. Единый язык с death-взрывом меха/ядра.
@export var death_explosion_radius: float = 7.0
## Урон детонации всем damageable в радиусе (без falloff).
@export var death_explosion_damage: float = 220.0
## Импульс отбрасывания pushable-целей (скелетов) от центра (м/с). 0 = без push.
@export var death_explosion_knockback: float = 9.0
## Цвет ударной волны детонации.
@export var death_explosion_color: Color = Color(1.0, 0.55, 0.15, 0.95)
## Сколько осколков-кубиков разлетается при гибели (башня крупная — много).
@export var death_shatter_fragments: int = 22
## Время жизни осколков (сек).
@export var death_shatter_lifetime: float = 2.5
## Цвет осколков башни (камень).
@export var death_shatter_color: Color = Color(0.55, 0.55, 0.6, 1.0)

@export_group("")
## Высота, ниже которой считаем что башня провалилась под карту.
@export var fall_threshold: float = -10.0
@export var debug_log: bool = true

var _was_on_floor: bool = true
## Только для _debug_log (детект смены направления ввода). Хранит сырой input.
var _last_input_dir: Vector2 = Vector2.ZERO
## Последнее НАПРАВЛЕНИЕ движения в мировых XZ (уже камера-относительное) — для
## рывка «стоя». Отдельно от _last_input_dir, чтобы дебаг-лог не путал.
var _last_move_dir: Vector2 = Vector2.ZERO
## Кэш камеры-рига: камера-относительное движение. Орбита камеры (MMB) крутит
## риг только по Y, поэтому его basis — чистый yaw, которым и поворачиваем ввод.
var _camera_rig: Node3D = null
var _was_stuck: bool = false
## Рывок (Space): остаток активной фазы, кулдаун, зафиксированное направление.
var _dash_timer: float = 0.0
var _dash_cd: float = 0.0
var _dash_dir: Vector2 = Vector2.ZERO
## Скелеты, уже задетые текущим рывком — чтобы один таран не бил одного скелета
## каждый физкадр контакта (иначе и гиганты бы складывались). Чистится на старте рывка.
var _dash_hit_set: Array = []
## Сглаженная интенсивность dash-визуала (наклон/стретч): плавно 0↔1 — нет рывка
## в самом эффекте при старте/конце рывка. Таймер спавна призраков трейла.
var _dash_fx: float = 0.0
var _dash_ghost_t: float = 0.0
## True пока активный рывок — супер (другая скорость/урон). Ставится на старте.
var _dash_is_super: bool = false
## Супер-дэш FSM (ввод обрабатывается в _process — отзывчив под слоумо;
## исполнение рывка — в _physics_process через флаги ниже).
enum SDash { IDLE, HOLDING, AIMING }
var _sdash_state: int = SDash.IDLE
var _sdash_hold_t: float = 0.0
var _sdash_marker: MeshInstance3D = null
var _sdash_dim: CanvasLayer = null  # лёгкое затемнение экрана на время прицела
var _sdash_hand: Node = null
## Флаги-мост _process → _physics_process (исполнение рывка в физкадре).
var _normal_dash_requested: bool = false
var _sdash_commit: bool = false
var _sdash_commit_target: Vector3 = Vector3.ZERO
## Замедление от вражеского темпорального поля (SlowField): фактор скорости (1 =
## норма, <1 = медленнее) и время действия (мс). Сильнейшее перекрывает, пока
## активно; рефрешится полем каждый тик, пока башня внутри.
var _slow_factor: float = 1.0
var _slow_until_msec: int = 0
## Knockback от тарана врага-меха: вектор отброса (XZ) и время действия (мс). Пока
## активен — перебивает ввод и рывок (башню отбрасывает, управление возвращается
## по затуханию). Зеркало Enemy-knockback, но на игрока.
var _kb_vel: Vector3 = Vector3.ZERO
var _kb_until_msec: int = 0
## Парирование: до какого msec активно окно отражения и когда снова готово.
var _parry_active_until_msec: int = 0
var _parry_cd_until_msec: int = 0
## Центр зоны ловли — фиксируется в точке каста (не едет за башней). Совпадает с
## куполом-визуалом: «развернул барьер здесь», снаряды в этом круге отлетают.
var _parry_center: Vector3 = Vector3.ZERO
# Item -> "push" | "block": набор Item'ов, с которыми сейчас контакт.
# Используется для логов фронт-перехода (старт/смена/конец контакта).
var _contacts_last: Dictionary = {}
var _dying: bool = false

## Текущий HP. Init = max_hp в _ready. Меняется только через take_damage.
var hp: float = 0.0
## Текущая мана. Init = max_mana в _ready. Регенерится в _physics_process,
## тратится через try_consume_mana.
var mana: float = 0.0

@onready var _floor_normal_threshold: float = cos(get_floor_max_angle())
# Каменная масса башни (тело+корона+зубцы) из выпеченной модели tower_visual.tscn.
# По ней идут HitFlash (вспышка урона) и DashFx-призрак — это основной силуэт.
@onready var _mesh: MeshInstance3D = $VisualRoot/TowerVisual/Body
# Светящиеся жилы-каналы реактора: их яркость гоним от количества маны.
@onready var _glow_mesh: MeshInstance3D = $VisualRoot/TowerVisual/Glow
@onready var _visual_root: Node3D = $VisualRoot

## Per-instance материал жил (дубль общего .tres) — меняем его emission по мане,
## не трогая ресурс на диске. Заполняется в _ready.
var _glow_mat: StandardMaterial3D = null
## Свечение жил при пустой / полной мане (emission_energy_multiplier). MAX держим
## чуть выше HDR-порога блума (~1.3 в Environment) — ядро светится, но без жирного
## ореола. Поднимешь MAX — сильнее блум.
const REACTOR_GLOW_MIN := 0.15
const REACTOR_GLOW_MAX := 1.7

## Motion-feedback в caravan-mode. Tower — большое тяжёлое здание, эффекты
## мелкие (амплитуды ≈половина палаточных), но дают «вес» при езде. На
## stationary tower (стоит, lend не двигается) speed_norm ≈ 0 → fx гаснет.
var _motion_fx: SegmentMotionFx = null
var _visual_base_y: float = 0.0
var _visual_base_pos: Vector3 = Vector3.ZERO  # база позиции VisualRoot (для лурча отдачи по xz)
var _visual_base_basis: Basis = Basis()
# Отдача при выстреле: башня кренится + лурчит НАЗАД (противоположно касту), с
# whip-перехлёстом (HitTilt.envelope по _recoil_age). _recoil_dir — направление
# (мир = локаль, башня не вращается).
var _recoil_dir: Vector3 = Vector3.ZERO
var _recoil_age: float = 0.0
var _recoil_active: bool = false
## Tween scale-punch'а от ремонта (трекаем, чтобы частые удары не штабелировались).
var _repair_punch_tween: Tween = null
const _RECOIL_TILT_FRAC := 0.33  # доля HitTilt.MAX_TILT_DEG (~7° на пике)
const _RECOIL_KICK := 0.22       # м — позиционный рывок назад на пике
# Шейк камеры только на СИЛЬНЫЙ удар по башне (≥ порога) — отсекает чип рядовых
# скелетов, ловит гиганта (28) / меха (40-80). Амплитуда ∝ урону.
const _SHAKE_HIT_THRESHOLD := 20.0


func _ready() -> void:
	add_to_group(GROUP)
	Damageable.register(self)
	# В navmesh_source номинально, но НЕ выгрызается: башня — CharacterBody3D, а
	# навмеш (STATIC_COLLIDERS) парсит коллайдеры только у StaticBody3D. Это и
	# нужно: башня — дом гномов, выгрызать её нельзя (дом стал бы недостижим).
	# Физически башня всё равно препятствие (коллайдер), юниты упираются.
	add_to_group(&"navmesh_source")
	hp = max_hp
	mana = 0.0  # старт с пустой маной — копится регеном / XP-орбами
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	destroyed.connect(func() -> void: EventBus.tower_destroyed.emit())
	health_changed.connect(func(current: float, maximum: float) -> void: EventBus.tower_health_changed.emit(current, maximum))
	mana_changed.connect(func(current: float, maximum: float) -> void: EventBus.tower_mana_changed.emit(current, maximum))
	EventBus.tower_fired.connect(_on_tower_fired)  # отдача-тильт на каждый выстрел
	# Стартовый sync HUD'у: emit'им текущие значения после connect'а — HUD
	# подписывается на EventBus в своём _ready, поэтому даже если он ready'ится
	# раньше Tower'а, сначала возьмёт snapshot через get_first_node_in_group.
	health_changed.emit(hp, max_hp)
	mana_changed.emit(mana, max_mana)
	# Жилы реактора: свой материал на инстанс (чтобы не мутировать .tres), яркость
	# далее ведём по мане. Стартовое значение — под текущую ману.
	if _glow_mesh != null and _glow_mesh.material_override is StandardMaterial3D:
		_glow_mat = (_glow_mesh.material_override as StandardMaterial3D).duplicate()
		_glow_mesh.material_override = _glow_mat
		_update_reactor_glow()
	# Motion-fx: bobbing/tilt/squash-stretch на VisualRoot.
	if _visual_root != null:
		_visual_base_y = _visual_root.position.y
		_visual_base_pos = _visual_root.position
		_visual_base_basis = _visual_root.basis
		_motion_fx = SegmentMotionFx.new()
		# Мелкие амплитуды — башня тяжёлая, не картон. Низкая частота bob'а
		# (1.5 Гц) даёт «медленный шаг» здания.
		_motion_fx.bob_amplitude = 0.04
		_motion_fx.bob_frequency = 1.5
		# Заметнее вытягивается при движении (запрос на «импакт»); dash добавляет
		# сверху свой сильный стретч/наклон (см. _process).
		_motion_fx.stretch_factor = 0.09
		_motion_fx.ss_response = 4.5
		_motion_fx.speed_reference = move_speed
		_motion_fx.reset(global_position)


# --- Публичный API ---

## Reach-бонус для «бьём с края» (Enemy.target_reach_bonus + AoeDamage-фильтр):
## башня широкая, её центр дальше малого radius'а, хотя коллайдер задет.
func get_attack_reach_bonus() -> float:
	return attack_reach_bonus


func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	health_changed.emit(maxf(hp, 0.0), max_hp)
	HitFlash.flash(_mesh)
	# Повреждена → становится strike-целью гномов-ремонтников (рабочие чинят ударами).
	# Единая модель «гном → точка → действие»; снимется на полном HP в gnome_hit.
	if hp > 0.0 and not is_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
		add_to_group(Layers.GNOME_STRIKE_TARGET_GROUP)
	if amount >= _SHAKE_HIT_THRESHOLD:
		EventBus.camera_shake.emit(clampf(amount / 100.0, 0.2, 0.7), global_position)
	if debug_log and LogConfig.master_enabled:
		print("[Tower] получил %.1f урона, hp=%.1f" % [amount, hp])
	if hp <= 0.0:
		_dying = true
		# Замораживаем ввод/физику: WASD больше не двигает тело, slide-коллизии
		# не пересчитываются. Тело остаётся на месте с активной коллизией —
		# скелеты упираются в "стену", но дальнейшие take_damage становятся
		# no-op'ом через ранний return по _dying в начале функции.
		set_physics_process(false)
		velocity = Vector3.ZERO
		# Мёртвую башню не чинят — вон из strike-группы ремонтников.
		if is_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
			remove_from_group(Layers.GNOME_STRIKE_TARGET_GROUP)
		# Снимаем флаг damageable ДО детонации: взрыв (MASK_DEATH_BLAST включает
		# ACTORS) не должен задеть саму мёртвую башню. Сама стенка-коллизия остаётся.
		remove_from_group(Damageable.GROUP)
		_spawn_death_explosion()
		# Башня детонировала — рассыпаем визуал на осколки, прячем меш и убираем
		# коллизию-стену: тело исчезает, а не висит болванкой. Сама нода остаётся
		# жива (камера держит её как _default_target; смерть башни ≠ game-over).
		_shatter_and_vanish()
		destroyed.emit()
		if debug_log and LogConfig.master_enabled:
			print("[Tower] DEAD")


## Контракт strike-цели: чинить башню может рабочий со свободными руками, пока башня
## жива и повреждена, И ТОЛЬКО ПО ЯВНОМУ НАМЕРЕНИЮ ремонта (кнопка / клик по башне —
## wants_repair). Без намерения рабочий рядом её не трогает (обычный «иди сюда» —
## просто встаёт на точку, не чинит). Гружёный сперва сдаст ресурс; копейщик — мимо.
func can_gnome_interact(gnome: Node) -> bool:
	if _dying or hp >= max_hp:
		return false
	if not (gnome.has_method(&"is_worker") and gnome.is_worker()):
		return false
	if not (gnome.has_method(&"wants_repair") and gnome.wants_repair()):
		return false
	return not (gnome.has_method(&"is_carrying") and gnome.is_carrying())


## Рабочий ударил по башне (ремонт) — восстанавливаем HP. Полное HP → выходим из
## strike-группы (рабочие сами переключатся: вернутся в башню / к другой работе).
func gnome_hit(_gnome: Node = null) -> void:
	if _dying or hp >= max_hp:
		return
	hp = minf(hp + repair_per_hit, max_hp)
	health_changed.emit(hp, max_hp)
	_play_repair_impact(_gnome)
	if hp >= max_hp and is_in_group(Layers.GNOME_STRIKE_TARGET_GROUP):
		remove_from_group(Layers.GNOME_STRIKE_TARGET_GROUP)


## Визуальный отклик на ремонт: башня «вздрагивает» (лёгкий scale-punch меша) +
## искры у точки удара рабочего. Punch трекаем tween'ом — на 7 рабочих удары
## частые, без трекинга они бы штабелировались на scale.
func _play_repair_impact(gnome: Node) -> void:
	_repair_punch_tween = HitPunch.punch(_mesh, _repair_punch_tween, 1.05, 0.05, 0.13)
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var at: Vector3 = global_position + Vector3.UP * 1.2
	if gnome is Node3D and is_instance_valid(gnome):
		# Точка контакта — между рабочим и центром башни (искры летят у её основания).
		at = (gnome as Node3D).global_position.lerp(global_position, 0.4)
		at.y = global_position.y + 1.2
	AoeVisual.spawn_pulse_sparks(scene, at, 0.8, 7.0)


## Детонация при гибели: визуал взрыва + ударная волна + урон по площади всем
## damageable в радиусе (враги, постройки, палисад, ядро). Единый паттерн с
## death-взрывом меха (EnemyMech._on_destroyed). Себя не задевает — вышли из
## Damageable-группы выше. Гномы (FRIENDLY_UNIT) намеренно не в MASK_DEATH_BLAST.
func _spawn_death_explosion() -> void:
	var root: Node = get_tree().current_scene
	if root != null and death_explosion_radius > 0.0:
		AoeVisual.spawn_explosion(root, global_position + Vector3.UP * 1.5, death_explosion_radius)
		AoeVisual.spawn_expanding_ring(root, global_position, death_explosion_radius, 0.6, death_explosion_color, 0.3)
	if death_explosion_radius > 0.0 and death_explosion_damage > 0.0:
		AoeDamage.apply_uniform(get_tree(), global_position, death_explosion_radius,
			Layers.MASK_DEATH_BLAST, death_explosion_damage, death_explosion_knockback, 0.3)


## Рассыпать визуал на осколки (на current_scene — переживают возможный freeze
## ноды), спрятать меш и снять коллизию: башня визуально исчезает. Ноду не
## освобождаем — её держит камера (_default_target) и кэши Camp/HandSpell;
## они обнуляются по tower_destroyed, но сам узел оставляем живым во избежание
## freed-ссылок. Стена-коллизия убирается (collision_layer=0) — нет «невидимого
## препятствия» там, где башни уже нет.
func _shatter_and_vanish() -> void:
	var root: Node = get_tree().current_scene
	if root != null:
		ShatterEffect.spawn(root, global_position + Vector3.UP * 1.5, death_shatter_color,
			death_shatter_fragments, death_shatter_lifetime)
	var vis := get_node_or_null("VisualRoot") as Node3D
	if vis != null:
		vis.visible = false
	collision_layer = 0


## Пытается списать ману. Возвращает true если хватило (и mana уменьшилась
## на amount). Иначе false — caller отказывается от действия. Mana не идёт
## в минус.
func try_consume_mana(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if _dying or mana < amount:
		return false
	mana -= amount
	mana_changed.emit(mana, max_mana)
	return true


## Пополнить ману (сбор XP-орба со скелета и т.п.). Капится на max_mana, эмитит
## mana_changed только при реальном изменении. На мёртвой башне — no-op.
func restore_mana(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	var prev: float = mana
	mana = minf(mana + amount, max_mana)
	if mana != prev:
		mana_changed.emit(mana, max_mana)


## Замедление от вражеского темпорального поля (SlowField зовёт каждый тик, пока
## башня внутри). factor: 1 = норма, 0.45 ≈ «вдвое медленнее». Сильнейшее (меньший
## factor) перекрывает, пока активно; until продлевается. Скейлит ходьбу И рывок
## (см. _physics_process). На мёртвой башне — no-op.
func apply_movement_slow(factor: float, duration: float) -> void:
	if _dying:
		return
	var now: int = Time.get_ticks_msec()
	var f: float = clampf(factor, 0.05, 1.0)
	if now < _slow_until_msec:
		_slow_factor = minf(_slow_factor, f)
	else:
		_slow_factor = f
	_slow_until_msec = maxi(_slow_until_msec, now + int(duration * 1000.0))


## Отброс от тарана врага-меха. vel — горизонтальная скорость отброса (м/с),
## duration — сколько перебивать управление (сек). На мёртвой башне — no-op.
func apply_knockback(vel: Vector3, duration: float) -> void:
	if _dying:
		return
	_kb_vel = Vector3(vel.x, 0.0, vel.z)
	_kb_until_msec = Time.get_ticks_msec() + int(duration * 1000.0)


## Сейчас ли башня под замедлением темпорального поля (для меха: «окно наказания»
## — пока поймана, стреляем бодрее).
func is_movement_slowed() -> bool:
	return Time.get_ticks_msec() < _slow_until_msec


# --- Парирование (тайминг-блок, отражает снаряды обратно в стрелка) ---

## По нажатию F (если готово) открываем короткое окно отражения + ставим кулдаун
## и спавним щит-волну. Сам разворот снарядов — в _tick_parry, пока окно активно.
func _try_start_parry() -> void:
	if not parry_enabled or _dying:
		return
	var now: int = Time.get_ticks_msec()
	if now < _parry_cd_until_msec:
		return
	if not Input.is_action_just_pressed("parry"):
		return
	_parry_active_until_msec = now + int(parry_window * 1000.0)
	_parry_cd_until_msec = now + int(parry_cooldown * 1000.0)
	_parry_center = global_position  # фиксируем зону ловли в точке каста (= купол)
	# Щит-пузырь: купол на весь радиус ловли мгновенно вспыхивает и гаснет (см.
	# ParryShield). Визуал держится чуть дольше окна, чтобы прочитался.
	var shield := ParryShield.new()
	get_tree().current_scene.add_child(shield)
	shield.setup(global_position, parry_radius, parry_color, parry_window + 0.25)
	# Щит дробит скелетов в зоне (разовый импульс, только скелеты — НЕ мех/гномы).
	_shield_zap_skeletons()
	_shield_shatter_scenery()
	_shield_damage_structures()
	if debug_log and LogConfig.master_enabled:
		print("[Tower] парирование: окно открыто (r=%.1f)" % parry_radius)


## Пока окно активно — отражаем каждый вражеский снаряд (Reflectable.GROUP) в
## радиусе обратно в стрелка. Отражённый снимается с группы → дважды не словим.
func _tick_parry() -> void:
	if Time.get_ticks_msec() >= _parry_active_until_msec:
		return
	var r_sq: float = parry_radius * parry_radius
	for n in get_tree().get_nodes_in_group(Reflectable.GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		# Меряем от ЗАФИКСИРОВАННОГО центра каста (= купол), не от текущей башни.
		if node.global_position.distance_squared_to(_parry_center) > r_sq:
			continue
		if Reflectable.try_reflect(node, _parry_center):
			# Вспышка в точке отбитого снаряда — читаемый «дзынь».
			AoeVisual.spawn_expanding_ring(get_tree().current_scene,
				node.global_position, 2.0, 0.25, parry_color, 0.12)
			if debug_log and LogConfig.master_enabled:
				print("[Tower] отбит снаряд %s" % node.name)


## Разовый импульс урона по СКЕЛЕТАМ в зоне щита при его подъёме. Только скелеты
## (SKELETON_GROUP), мех исключён (он — через парирование/отражение). Обычные
## скелеты (hp=30) гибнут сразу; гиганты лишь получают урон. Разово на активацию
## (не каждый кадр) — иначе за окно щита накопилось бы много тиков и легло бы всё.
func _shield_zap_skeletons() -> void:
	if parry_skeleton_damage <= 0.0:
		return
	var r_sq: float = parry_radius * parry_radius
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(n):
			continue
		if (n as Node).is_in_group(EnemyMech.MECH_GROUP):
			continue  # мех зоной щита не трогаем — только парированием/отражением
		if (n as Node).is_in_group(&"super_dash_only"):
			continue  # тяжёлые (гигант) не берутся щитом — только супер-рывок (+AoE/магия)
		var node := n as Node3D
		if node == null:
			continue
		if node.global_position.distance_squared_to(_parry_center) > r_sq:
			continue
		Damageable.try_damage(node, parry_skeleton_damage, HitStop.MEDIUM)


## Разовый «удар щитом» по разрушаемой утвари (кувшины, группа shield_breakable) в
## зоне купола — разбиваем через их же on_spark (тот же энерго-импульс, что от Искры).
## Отдельно от скелетов: утварь без hp/Damageable, ломается контрактом, не уроном.
func _shield_shatter_scenery() -> void:
	var r_sq: float = parry_radius * parry_radius
	for n in get_tree().get_nodes_in_group(Layers.SHIELD_BREAKABLE_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		if node.global_position.distance_squared_to(_parry_center) > r_sq:
			continue
		if node.has_method(&"on_spark"):
			node.call(&"on_spark")


## Разовый удар щитом по разрушаемым ПОСТРОЙКАМ-настилам (мост) в зоне купола — через
## Damageable (HP), как магия/дэш. Sphere-query по слою DESTRUCTIBLE_DECK: ничего
## другого на нём нет, потому це́лит ровно настил. Разово на активацию (не каждый кадр).
func _shield_damage_structures() -> void:
	if parry_skeleton_damage <= 0.0:
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = parry_radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = Layers.DESTRUCTIBLE_DECK
	q.transform = Transform3D(Basis(), _parry_center)
	for hit in space.intersect_shape(q, 8):
		var c = hit.get("collider")
		if c != null and is_instance_valid(c) and Damageable.is_damageable(c):
			Damageable.try_damage(c, parry_skeleton_damage, HitStop.MEDIUM)


func _process(delta: float) -> void:
	# Ввод дэша — до visual-guard'а: должен работать даже если _motion_fx ещё null.
	_update_super_dash_input(delta)
	if _motion_fx == null or _visual_root == null:
		return
	var fx: Dictionary = _motion_fx.tick(global_position, delta)
	var vbasis: Basis = _visual_base_basis * (fx["basis"] as Basis)
	# Dash-juice (общий с врагом-мехом, см. DashFx): наклон вперёд + вытягивание
	# вдоль рывка поверх motion_fx. _dash_fx плавно 0↔1 (нет щелчка). World-space
	# (башня не вращается) — домножаем слева.
	var target_fx: float = 1.0 if _dash_timer > 0.0 else 0.0
	_dash_fx = lerpf(_dash_fx, target_fx, 1.0 - exp(-DashFx.FX_RATE * delta))
	var dir: Vector3 = Vector3(_dash_dir.x, 0.0, _dash_dir.y)
	vbasis = DashFx.dash_basis(dir, _dash_fx) * vbasis
	# Отдача выстрела: whip-наклон+squash (impact_basis) + позиционный лурч назад.
	# env с перехлёстом (<0) даёт кратко обратный клевок/толчок вперёд = «пружинит».
	var env: float = 0.0
	if _recoil_active:
		_recoil_age += delta
		env = HitTilt.envelope(_recoil_age)
		if _recoil_age >= HitTilt.RECOVER_DUR:
			_recoil_active = false
	if env != 0.0:
		vbasis = HitTilt.impact_basis(_recoil_dir, env * _RECOIL_TILT_FRAC) * vbasis
	var kick: Vector3 = _recoil_dir * (env * _RECOIL_KICK)  # _recoil_dir = назад от цели
	_visual_root.position = _visual_base_pos + Vector3(kick.x, fx["bob_y"] as float, kick.z)
	_visual_root.basis = vbasis
	# Трейл: призраки с интервалом, пока идёт рывок.
	if _dash_fx > 0.005 and dash_trail_enabled:
		_dash_ghost_t -= delta
		if _dash_ghost_t <= 0.0:
			_dash_ghost_t = DashFx.GHOST_INTERVAL
			DashFx.spawn_ghost(get_tree().current_scene, _mesh, dir)


## --- Super Dash: ввод-флоу (зажать Space → слоумо+прицел → ПКМ коммит) ---
## В _process, не в _physics_process: под слоумо физкадры редки, а Input-поллинг
## на реальном кадре ловит ПКМ/отпускание мгновенно. Исполнение рывка — в
## _physics_process через флаги _sdash_commit / _normal_dash_requested.
func _update_super_dash_input(delta: float) -> void:
	if _dying:
		if _sdash_state != SDash.IDLE:
			_exit_sdash_aim()
		return
	match _sdash_state:
		SDash.IDLE:
			if Input.is_action_just_pressed("dash"):
				# Обычный рывок СРАЗУ на нажатии — без паузы. Если игрок продолжит
				# держать → ниже войдём в прицел супер-рывка (он перебьёт обычный).
				_normal_dash_requested = true
				_sdash_state = SDash.HOLDING
				_sdash_hold_t = 0.0
		SDash.HOLDING:
			if not Input.is_action_pressed("dash"):
				# Отпустил — обычный рывок уже сработал на нажатии, просто выходим.
				_sdash_state = SDash.IDLE
			else:
				_sdash_hold_t += delta
				if _sdash_hold_t >= super_dash_hold_threshold and _can_super_dash():
					_enter_sdash_aim()
		SDash.AIMING:
			var hand := _resolve_dash_hand()
			if hand != null and is_instance_valid(_sdash_marker):
				var p: Vector3 = hand.cursor_world_position()
				_sdash_marker.global_position = Vector3(p.x, 0.05, p.z)
			if Input.is_action_just_pressed("hand_action"):
				# ПКМ — коммит супер-рывка в точку прицела.
				if hand != null:
					_sdash_commit_target = hand.cursor_world_position()
					_sdash_commit = true
				_exit_sdash_aim()
			elif not Input.is_action_pressed("dash"):
				# Отпустил Space до коммита — отмена.
				_exit_sdash_aim()


## Можно ли войти в супер-рывок: жив + хватает маны. КД/активность обычного рывка
## не блокируют — на нажатии обычный рывок уже сработал, супер его перебьёт.
func _can_super_dash() -> bool:
	return not _dying and mana >= super_dash_mana_cost


func _enter_sdash_aim() -> void:
	_sdash_state = SDash.AIMING
	Engine.time_scale = super_dash_time_scale
	var hand := _resolve_dash_hand()
	if hand != null:
		hand.push_category(Hand.Category.DASH_AIM)  # подавляет grab/cast на ПКМ
	var origin: Vector3 = hand.cursor_world_position() if hand != null else global_position
	# Синее кольцо-прицел — та же «отметка области», с бустнутым emission под блум.
	_sdash_marker = AoeVisual.spawn_ground_ring(
		get_tree().current_scene, origin, super_dash_marker_radius, 0.0, super_dash_marker_color)
	if is_instance_valid(_sdash_marker):
		var mat := _sdash_marker.material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = 5.0
	# Лёгкое затемнение экрана (отдельный CanvasLayer, вне слоумо).
	_sdash_dim = CanvasLayer.new()
	_sdash_dim.layer = 9  # над gameplay-HUD, под Super-QTE (10)
	_sdash_dim.process_mode = Node.PROCESS_MODE_ALWAYS
	var rect := ColorRect.new()
	rect.color = super_dash_dim_color
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sdash_dim.add_child(rect)
	get_tree().current_scene.add_child(_sdash_dim)


func _exit_sdash_aim() -> void:
	Engine.time_scale = 1.0
	if is_instance_valid(_sdash_marker):
		_sdash_marker.queue_free()
	_sdash_marker = null
	if is_instance_valid(_sdash_dim):
		_sdash_dim.queue_free()
	_sdash_dim = null
	var hand := _resolve_dash_hand()
	if hand != null and hand.active_category == Hand.Category.DASH_AIM:
		# DEFERRED: коммит-ПКМ читается и тут (commit), и в hand_spell._handle_input
		# в ТОМ ЖЕ кадре. Поппнём категорию сразу — hand_spell увидит MAGIC и
		# кастанёт спелл на тот же ПКМ. Откладываем pop на конец кадра: hand_spell
		# в этом кадре ещё видит DASH_AIM (каст подавлен), а на следующем ПКМ уже
		# не just_pressed.
		hand.call_deferred("pop_category")
	_sdash_state = SDash.IDLE
	_sdash_hold_t = 0.0


## Сейф: если башню удалят (рестарт/перезагрузка сцены) во время прицеливания —
## вернуть глобальный Engine.time_scale, иначе слоумо «залипнет» на новой сцене.
func _exit_tree() -> void:
	if _sdash_state == SDash.AIMING:
		Engine.time_scale = 1.0
	if is_instance_valid(_sdash_dim):
		_sdash_dim.queue_free()
		_sdash_dim = null


func _resolve_dash_hand() -> Hand:
	if _sdash_hand != null and is_instance_valid(_sdash_hand):
		return _sdash_hand as Hand
	_sdash_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP)
	return _sdash_hand as Hand


## Отдача на каждый выстрел (EventBus.tower_fired): крен НАЗАД, противоположно
## выстрелу. d = башня→цель (отдача в эту сторону = назад от выстрела). Башня не
## вращается → мир = локаль. Знак направления подобрать по ощущению (инвертить d).
func _on_tower_fired(target: Vector3) -> void:
	var d: Vector3 = global_position - target
	d.y = 0.0
	if d.length_squared() > 0.0001:
		_recoil_dir = d.normalized()
		_recoil_age = 0.0
		_recoil_active = true


## Яркость жил реактора = доля маны. Пусто → тлеет (MIN), полный бак → ярко (MAX).
func _update_reactor_glow() -> void:
	if _glow_mat == null:
		return
	var frac: float = clampf(mana / max_mana, 0.0, 1.0) if max_mana > 0.0 else 0.0
	_glow_mat.emission_energy_multiplier = lerpf(REACTOR_GLOW_MIN, REACTOR_GLOW_MAX, frac)


## Basis камеры-рига (чистый yaw) для камера-относительного движения. Риг
## находим лениво по группе и кэшируем. Нет рига → Basis() (мировое управление).
func _camera_yaw_basis() -> Basis:
	if not is_instance_valid(_camera_rig):
		_camera_rig = get_tree().get_first_node_in_group(CameraRig.CAMERA_RIG_GROUP) as Node3D
	if is_instance_valid(_camera_rig):
		return _camera_rig.global_transform.basis
	return Basis()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# Регенерация маны: только до max_mana, эмитим только когда реально
	# изменилось (внутри cap), чтобы не дёргать HUD каждый кадр на full mana.
	if not _dying and mana < max_mana:
		var prev: float = mana
		mana = minf(mana + mana_regen_rate * delta, max_mana)
		if mana != prev:
			mana_changed.emit(mana, max_mana)
	# Свечение жил всегда под текущую ману (учитывает и трату, и реген).
	_update_reactor_glow()

	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_axis("move_left", "move_right")
	input_dir.y = Input.get_axis("move_forward", "move_back")
	input_dir = input_dir.normalized()
	# Камера-относительное движение: поворот орбиты камеры (MMB) разворачивает и
	# систему координат управления — «вперёд» всегда «вглубь экрана». Риг крутится
	# только по Y, поэтому его basis поворачивает ввод вокруг вертикали (длина
	# сохраняется). При yaw=0 даёт ровно прежнее мировое управление.
	var move_world: Vector3 = _camera_yaw_basis() * Vector3(input_dir.x, 0.0, input_dir.y)
	var move_dir := Vector2(move_world.x, move_world.z)
	# Запоминаем последнее направление движения (в мире) — для рывка «стоя».
	if move_dir != Vector2.ZERO:
		_last_move_dir = move_dir

	# Рывок: ввод обрабатывает _update_super_dash_input (в _process), сюда приходит
	# через флаги. Тап Space → _normal_dash_requested; зажал+ПКМ → _sdash_commit.
	# Перекрывает обычную скорость на dash_duration (super — на super_dash_duration).
	_dash_cd = maxf(_dash_cd - delta, 0.0)
	if _sdash_commit:
		# Супер-рывок к точке прицела + 50 маны. Перебивает обычный рывок (если тот
		# ещё в полёте от нажатия) — гейт только мана, не кд.
		_sdash_commit = false
		_normal_dash_requested = false
		if not _dying and try_consume_mana(super_dash_mana_cost):
			var sdir := Vector2(_sdash_commit_target.x - global_position.x,
					_sdash_commit_target.z - global_position.z)
			if sdir.length() > 0.05:
				_dash_dir = sdir.normalized()
				_dash_is_super = true
				_dash_timer = super_dash_duration
				_dash_cd = dash_cooldown
				_dash_ghost_t = 0.0
				_dash_hit_set.clear()
	elif _normal_dash_requested:
		_normal_dash_requested = false
		if _dash_timer <= 0.0 and _dash_cd <= 0.0 and not _dying:
			var ddir := move_dir if move_dir != Vector2.ZERO else _last_move_dir
			if ddir != Vector2.ZERO:
				_dash_dir = ddir
				_dash_is_super = false
				_dash_timer = dash_duration
				_dash_cd = dash_cooldown
				_dash_ghost_t = 0.0  # первый призрак трейла — сразу
				_dash_hit_set.clear()  # новый рывок — заново можно задеть скелетов

	# Парирование (Q): открыть окно отражения по нажатию + отражать снаряды, пока
	# окно активно. Независимо от движения/рывка/knockback — парируем на ходу.
	_try_start_parry()
	_tick_parry()

	# Knockback от тарана меха перебивает всё: пока активен — башню отбрасывает
	# (ввод/рывок игнорируются), сила затухает, потом управление возвращается.
	if Time.get_ticks_msec() < _kb_until_msec:
		velocity.x = _kb_vel.x
		velocity.z = _kb_vel.z
		_dash_timer = maxf(_dash_timer - delta, 0.0)  # не копим рывок под отбросом
		_kb_vel = _kb_vel.lerp(Vector3.ZERO, 1.0 - exp(-8.0 * delta))
	else:
		# Замедление от вражеского темпорального поля (SlowField): скейлит И ходьбу,
		# И рывок (рывок «ослаблен» — короче, но не выключен). Истёкло → factor=1.
		var slow: float = 1.0
		if Time.get_ticks_msec() < _slow_until_msec:
			slow = _slow_factor
		else:
			_slow_factor = 1.0

		if _dash_timer > 0.0:
			_dash_timer -= delta
			var dspeed: float = super_dash_speed if _dash_is_super else dash_speed
			velocity.x = _dash_dir.x * dspeed * slow
			velocity.z = _dash_dir.y * dspeed * slow
			_dash_try_damage_structures()  # таран рвёт настил-постройки (мост) на пути
		else:
			velocity.x = move_dir.x * move_speed * slow
			velocity.z = move_dir.y * move_speed * slow

	# Сохраняем скорость до слайда — после move_and_slide компонент в сторону
	# препятствия обнулится, и факт "шли в предмет" будет потерян.
	var intended_velocity := velocity

	move_and_slide()

	_resolve_contacts(intended_velocity)

	if debug_log and LogConfig.master_enabled:
		_debug_log(input_dir)


func _resolve_contacts(intended_velocity: Vector3) -> void:
	# Items — push с массовым ratio (mass-mediation вшита, единый Pushable
	# не даст условный mass-check). Kinematic-цели (враги) — простой Δv-push
	# через Pushable, без знания конкретного класса.
	var contacts_now: Dictionary = {}

	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if collider is Item:
			_push_item(collider as Item, col, intended_velocity, contacts_now)
		elif Pushable.is_pushable(collider) and collider is CharacterBody3D:
			_push_kinematic(collider as Node, col, intended_velocity)
			if _dash_timer > 0.0:
				_dash_damage_enemy(collider as Node)
			# В contacts_now kinematic'ов не записываем — для 50+ скелетов получится спам логов.
		elif _dash_timer > 0.0 and _dash_is_super and collider is Node \
				and (collider as Node).is_in_group(&"room_door"):
			# Супер-рывок сносит дверь комнаты: она сама разносится по физике,
			# открывает проём и удаляется. Только супер-рывок (_dash_is_super).
			if (collider as Node).has_method(&"shatter"):
				(collider as Node).call(&"shatter")

	if debug_log and LogConfig.master_enabled:
		_log_contact_transitions(contacts_now)
	_contacts_last = contacts_now


func _push_item(item: Item, col: KinematicCollision3D, intended_velocity: Vector3, contacts_now: Dictionary) -> void:
	if item.freeze:
		return
	# Подписка на tree_exited, чтобы не оставлять zombie-ключи в _contacts_last.
	# Используем флаг в meta — bind(item) делает Callable не-сравнимым через is_connected.
	if not item.has_meta(&"_tower_contact_hooked"):
		item.set_meta(&"_tower_contact_hooked", true)
		item.tree_exited.connect(_on_contact_item_exited.bind(item))
	if mass <= item.mass:
		contacts_now[item] = "block"
		return
	contacts_now[item] = "push"
	var push_dir: Vector3 = -col.get_normal()
	var v_into := intended_velocity.dot(push_dir)
	if v_into <= 0.0:
		return
	var item_v_into := item.linear_velocity.dot(push_dir)
	var v_diff := v_into - item_v_into
	if v_diff <= 0.0:
		return
	var ratio: float = clampf((mass - item.mass) / mass, 0.0, 1.0)
	item.apply_central_impulse(push_dir * v_diff * item.mass * ratio * push_strength)


## Таран рывком: урон скелету при контакте во время дэша. Только скелеты (мех
## исключён, как у щита); каждого бьём раз за рывок (_dash_hit_set). Обычные гибнут.
func _dash_damage_enemy(collider: Node) -> void:
	var dmg: float = super_dash_damage if _dash_is_super else dash_damage
	if dmg <= 0.0 or collider == null:
		return
	if not collider.is_in_group(Skeleton.SKELETON_GROUP):
		return  # таран бьёт только скелетов
	if collider.is_in_group(EnemyMech.MECH_GROUP):
		return  # меха рывком не давим
	if not _dash_is_super and collider.is_in_group(&"super_dash_only"):
		return  # тяжёлые враги (гигант) не берутся обычным тараном — только супер-рывок (как красную дверь)
	if collider in _dash_hit_set:
		return  # уже задели этим рывком
	_dash_hit_set.append(collider)
	Damageable.try_damage(collider, dmg, HitStop.HEAVY)


## Радиус «тарана» дэша по настилам-постройкам (мост): настил НЕ блокирует башню
## физически (другой слой), потому slide-collision его не ловит — добираем sphere-query.
const DASH_STRUCTURE_RADIUS := 2.5

## Рывок рвёт разрушаемые настилы (мост) на пути: sphere-query по слою DESTRUCTIBLE_DECK
## каждый физкадр рывка, каждую цель бьём раз за рывок (_dash_hit_set, как у скелетов).
func _dash_try_damage_structures() -> void:
	var dmg: float = super_dash_damage if _dash_is_super else dash_damage
	if dmg <= 0.0:
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = DASH_STRUCTURE_RADIUS
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = Layers.DESTRUCTIBLE_DECK
	q.transform = Transform3D(Basis(), global_position)
	for hit in space.intersect_shape(q, 8):
		var c = hit.get("collider")
		if c == null or not is_instance_valid(c):
			continue
		if c in _dash_hit_set:
			continue
		if Damageable.is_damageable(c):
			_dash_hit_set.append(c)
			Damageable.try_damage(c, dmg, HitStop.HEAVY)


func _push_kinematic(target: Node, col: KinematicCollision3D, intended_velocity: Vector3) -> void:
	var push_dir: Vector3 = -col.get_normal()
	var push_dir_h := VecUtil.horizontal(push_dir)
	if push_dir_h.length_squared() < VecUtil.EPSILON_SQ:
		return
	push_dir_h = push_dir_h.normalized()
	var v_into := intended_velocity.dot(push_dir_h)
	if v_into <= MIN_PUSH_VELOCITY:
		return  # башня не движется в эту сторону — нечего толкать
	Pushable.try_push(target, push_dir_h * v_into * enemy_push_speed_factor, enemy_push_duration)


func _on_contact_item_exited(item: Item) -> void:
	_contacts_last.erase(item)


func _log_contact_transitions(contacts_now: Dictionary) -> void:
	# Новые или изменившиеся контакты
	for item in contacts_now:
		if not is_instance_valid(item):
			continue
		var status: String = contacts_now[item]
		var prev: String = _contacts_last.get(item, "")
		if prev == status:
			continue
		if status == "push":
			print("[Tower] толкаем %s (mass=%.1f)" % [item.name, item.mass])
		else:
			print("[Tower] упёрлись в %s (mass=%.1f ≥ наша %.1f) — не толкнуть" % [item.name, item.mass, mass])
	# Контакты, которых больше нет
	for item in _contacts_last:
		if not contacts_now.has(item):
			if is_instance_valid(item):
				print("[Tower] контакт прекращён: %s" % item.name)


func _debug_log(input_dir: Vector2) -> void:
	var on_floor := is_on_floor()
	var is_moving := input_dir.length_squared() > 0.0
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var is_stuck := is_moving and horizontal_speed < move_speed * 0.1

	# Контакт с полом (фронт изменения)
	if _was_on_floor != on_floor:
		if on_floor:
			print("[Tower] приземление @ y=%.2f" % global_position.y)
		else:
			print("[Tower] оторвались от пола @ y=%.2f" % global_position.y)

	# Любое изменение ввода: старт / стоп / смена направления
	if input_dir != _last_input_dir:
		var p := global_position
		if _last_input_dir.is_zero_approx():
			print("[Tower] старт, input=%s, pos=(%.2f, %.2f, %.2f)" % [input_dir, p.x, p.y, p.z])
		elif input_dir.is_zero_approx():
			print("[Tower] стоп, pos=(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z])
		else:
			print("[Tower] смена направления: %s → %s, pos=(%.2f, %.2f, %.2f)" % [_last_input_dir, input_dir, p.x, p.y, p.z])
		_last_input_dir = input_dir

	# Подозрительно: пытаемся идти, но скорость почти нулевая (фронт)
	if is_stuck and not _was_stuck:
		printerr("[Tower] застряли: input=%s, h_speed=%.2f" % [input_dir, horizontal_speed])

	# Коллизии со стенами (не пол, не Item, не kinematic-pushable —
	# Item уже залогирован в _push_item, kinematic'и (враги) спамили бы при толпе).
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var n := col.get_normal()
		if n.y > _floor_normal_threshold:
			continue
		var collider := col.get_collider()
		if collider is Item:
			continue
		if Pushable.is_pushable(collider) and collider is CharacterBody3D:
			continue
		var collider_name := str(collider.name) if collider else "?"
		print("[Tower] коллизия со стеной: %s, normal=(%.2f, %.2f, %.2f)" % [collider_name, n.x, n.y, n.z])

	# Провалились ниже карты
	if global_position.y < fall_threshold:
		printerr("[Tower] провалились ниже карты: y=%.2f" % global_position.y)

	_was_on_floor = on_floor
	_was_stuck = is_stuck
