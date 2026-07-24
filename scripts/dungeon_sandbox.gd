extends Node3D
## ПЕСОЧНИЦА ДАНЖ-КОНТРОЛА (дизайн-сессия 2026-07-23): щупаем секунда-к-секунде
## феел «автошутер с управлением мышью» — отряд гномов-лучников стайно течёт за
## курсором, автострельба, скелеты волнами от стен. Отдельная сцена, в геймлуп
## rooms НЕ включена — только для плейтеста ощущений до интеграции.
##
## Запуск: открыть scenes/dungeon_sandbox.tscn в редакторе → F6
## (или CLI: godot --path <проект> res://scenes/dungeon_sandbox.tscn).
##
## Управление: ЛКМ (держать) — вести отряд за курсором-«поводком»; отпустил —
##             ЮЗ по инерции (докатываются с трением), потом ёж на месте
##             остановки. (Ранний «резкий стоп» сменён моделью «тачка».)
##             ПКМ (при зажатой ЛКМ) — ТОРМОЗ «как на тачке»: ход и разгон
##             стекают, руление живёт (тормоз в повороте, ручник-дрифт),
##             корпус осаживается назад, пыль как визг колодок.
##             (Пин-свинг отключён 2026-07-23 — его код спит в SoldierGnome.)
##             Визуал приказа — язык дэш-обводки/aim'а: линия отряд→точка
##             (AoeVisual.spawn_ground_line) + кольцо на точке, пульс на отпуск.
##             E — поднять/бросить ГРУЗ: у груза класс (meta "need") =
##             сколько гномов несут ОДНОВРЕМЕННО; носильщики не стреляют
##             (руки заняты) и идут на 80% скорости — жадность физически
##             ослабляет залп. Павшего носильщика сменяет свободный;
##             рук меньше нужного — груз падает.
##             T — вызвать волну сейчас. R — рестарт сцены.
##
## Переиспользованы штатные сущности, новых юнитов НЕ заведено:
##  - ArcherSoldier + Squad: state HOLDING_POSITION, а `hold_position`
##    обновляется каждый кадр в точку курсора → центр строя течёт за мышью.
##    Адаптивный спринт отстающих (Gnome._move_toward) даёт стайность бесплатно.
##  - Эмерджентный зачаток формаций из конуса зрения лучника: на бегу _facing
##    по движению → стреляют только вперёд; встали в кольцо → _outward_facing
##    → круговой «ёж» на 360°. Стоять = обороняться, бежать = прорываться.
##  - Skeleton: спавн у стен + set_forced_target(живой гном) — волна сразу
##    давит на отряд, без ожидания vision-обнаружения.
##
## Контекст строя: setup_free требует escort-цель (иначе _has_squad_context
## false и юниты стоят) — используем узел Banner, приклеенный к курсору.

const ARCHER_TYPE := &"archer_squad"

## Цвет приказов отряду — тот же голубой, что у aim-ring'а HandSquadAim:
## один визуальный язык «команда отряду» по всей игре.
const CMD_COLOR := Color(0.4, 0.85, 1.0, 0.9)
## Радиус кольца-цели (точка назначения, не зона).
const CMD_RING_RADIUS := 0.9
## Дистанция центроид→точка (XZ), ниже которой маркеры приказа гаснут —
## отряд «дошёл», линия под ногами не нужна.
const CMD_ARRIVED_DIST := 2.0

@export_group("Отряд")
## Сколько гномов в отряде. Дизайн: 7 = вся артель (кап населения).
@export var squad_size: int = 7
## ГЛАВНАЯ ручка темпа: пропорциональный множитель ВСЕЙ скорости отряда
## (шаг + спринт догона + буст разгона поверх). Медленнее — крути сюда
## (0.85 = −15%), НЕ gnome_move_speed: тот влияет только на шаг у самого
## слота, а крейсер ведомого отряда — спринт (Gnome.caravan_sprint_speed=9).
@export var gnome_speed_scale: float = 1.0
## Скорость ШАГА у слота (каталожные 1.6 — челнок по базе). В ведении почти
## не ощущается — крейсер задаёт спринт × gnome_speed_scale.
@export var gnome_move_speed: float = 3.0
## Дальность выстрела. Каталожные 22.5 (оборона базы) в комнате 50×50 били бы
## через всю карту — толпа не успевала бы подойти. Короткая дистанция заставляет
## подпускать врага = появляется рулёжка.
@export var gnome_attack_range: float = 12.0
## Темп стрельбы (каталожные 1.0–2.0 — вальяжная оборона; данжу нужен ливень).
@export var gnome_cooldown_min: float = 0.5
@export var gnome_cooldown_max: float = 0.9
## Урон выстрела. Каталожные 20–32 ваншотили скелета (hp=30) — «жоско»
## (фидбек 2026-07-23). 8–12 = ~3 выстрела на скелета: толпа успевает
## доползти, появляется челлендж.
@export var gnome_damage_min: float = 8.0
@export var gnome_damage_max: float = 12.0
## ЗАНОСЫ (эксперимент 2026-07-23): инерция руления гнома, 1/с. Скорость
## доворачивается к цели, на резких поворотах кучу сносит дугой. 0 = выкл
## (мгновенное руление, как в основной игре). В модели «дрифт-событие» это
## темп доворота В СКОЛЬЖЕНИИ: радиус дуги ≈ скорость/этот темп. 1.2 давало
## радиус ~3.5м = «летишь прямо»; 2.6 ≈ дуга ~1.6м — читаемый карв.
@export var gnome_steer_inertia: float = 2.6
## Базовое сцепление (руление вне скольжения). 9 → 7 → 5.5 по фидбекам
## «чуть больше инерции» (×2) при вводе ПКМ-тормоза и юза: обычная езда
## плывёт, контроль добирается тормозом.
@export var gnome_steer_grip: float = 5.5
## Трение карва в скольжении: величина скорости сходится к желаемой с этим
## темпом (1/с). Меньше = момент живёт дольше (шире орбиты, риск разлёта),
## больше = быстрее гаснет к управляемому.
@export var gnome_drift_scrub: float = 1.6
## Сцепка строя в скольжении: подтяжка каждого гнома к своему слоту (1/с).
## Больше = куча дрифтит плотной пачкой (не напарываются на ловушки),
## меньше = каждый скользит сам (живописнее, но разъезд).
@export var gnome_drift_formation_pull: float = 2.0
## Максимум «поводка»: точка приказа не может убегать дальше этого от центра
## отряда (кламп при ведении ЛКМ). С заносами обязателен — иначе далёкая
## точка разгоняет кучу так, что дуги становятся неуправляемыми.
@export var leash_max: float = 7.0
## Поводок на ПОЛНОМ разгоне: длина растёт с ramp'ом от leash_max к этому —
## на скорости появляется запас на замах для манёвра.
@export var leash_max_full: float = 10.0
## Длина «хвоста кометы» на полном разгоне: на бегу строй вытягивается за
## точкой (читается «мы летим», проход между столбами), на стопе — ёж-кольцо.
@export var tail_length_full: float = 4.5

@export_group("Груз (E)")
## Радиус подбора: E цепляет ближайший груз в этом радиусе от центра отряда.
@export var cargo_pickup_radius: float = 4.0
## Высота полёта груза над центром отряда (низ куба).
@export var cargo_carry_height: float = 1.15
## ДРИФТ-СОБЫТИЕ: угол (°) между средней скоростью отряда и направлением на
## точку, при котором на скорости врубается скольжение (вход-триггер).
@export var drift_enter_angle_deg: float = 55.0
## Угол выравнивания (°), ниже которого скольжение отпускает (выход).
@export var drift_exit_angle_deg: float = 18.0
## Минимальная средняя скорость отряда (м/с) для входа в дрифт — на шаге
## резкий поворот остаётся чётким рулением.
@export var drift_min_speed: float = 2.8
## Разгон: секунды непрерывного бега до полной скорости (0 = выкл).
## Дольше катишься → быстрее → шире занос. Стоп/выстрел сбрасывает.
## 2.0 → 3.5 по фидбеку — разгон должен зарабатываться дольше.
@export var gnome_run_ramp_time: float = 3.5
## Прибавка на полном разгоне (0.7 = +70% к скорости).
@export var gnome_run_boost: float = 0.7

@export_group("Волны скелетов")
@export var skeleton_scene: PackedScene
## Пауза между волнами (сек). Первая волна — через first_wave_delay.
@export var wave_interval: float = 10.0
@export var first_wave_delay: float = 3.0
## Размер волны: base + growth × (номер волны − 1).
@export var wave_base_count: int = 4
@export var wave_growth: int = 2
## Потолок живых скелетов одновременно (защита от каши и просадок).
@export var max_alive_skeletons: int = 45

@export_group("Комната и камера")
## Центр комнаты НАМЕРЕННО сдвинут от мирового origin: в сцене нет навмеша,
## пустая нав-карта снапит цели в точный (0,0,0), а zero-guard в
## Gnome._resolve_path_step распознаёт этот баг только для целей дальше 1м
## от origin. Комната вокруг (0,0,0) давала «кучу-залипание» гномов в центре.
## Должен совпадать с расстановкой Floor/стен/столбов в .tscn.
@export var room_center: Vector3 = Vector3(40.0, 0.0, 40.0)
## Полуразмер комнаты (стены на room_center ± room_half). Курсор клампится внутрь.
@export var room_half: float = 25.0
## Смещение камеры от точки взгляда (высота/отступ = ракурс).
@export var camera_offset: Vector3 = Vector3(0.0, 21.0, 11.0)
## Насколько точка взгляда камеры тянется от центра отряда к курсору (0..1).
## Чуть видно «куда веду», но отряд не уезжает из кадра. Фидбек 2026-07-23:
## 0.25 укачивало, полное отключение — скучно; «небольшие совсем» → 0.1,
## потом «ещё чуть тише» → 0.06.
@export var camera_cursor_bias: float = 0.06
## Доля вращательной качки (0..1): 0 = ракурс намертво фиксирован (чистый
## пан), 1 = камера каждый кадр целится точно в догоняющую точку (как было
## при «укачивает»). Малые значения дают живое микро-подруливание взгляда.
## 0.3 → 0.15 → 0.08 по фидбекам «уменьши повороты/ещё чуть тише».
@export_range(0.0, 1.0) var camera_sway: float = 0.08
## Скорость догона камеры (экспоненциальное сглаживание).
@export var camera_follow_speed: float = 5.0

var _squad: Squad = null
var _banner: Node3D = null
var _camera: Camera3D = null
var _wave_timer: float = 0.0
var _wave_number: int = 0
var _kills: int = 0
var _look_target: Vector3 = Vector3.ZERO
var _game_over: bool = false
var _lmb_was_down: bool = false
## ПКМ-тормоз зажат (транслируется в SoldierGnome.brake_active).
var _braking: bool = false
## Несомый груз (Node3D с meta "need") и его носильщики. null = руки пусты.
var _cargo: Node3D = null
var _haulers: Array = []
## Средний разгон отряда в этом кадре (0..1) — питает все визуалы разгона.
var _ramp_now: float = 0.0
var _dust_timer: float = 0.0
## Отряд в дрифт-событии (вход/выход синхронные — «одна машинка»).
var _drifting: bool = false
## Маркеры приказа (caller-owned, живут всю сцену, видимость переключается).
var _cmd_line: MeshInstance3D = null
var _cmd_ring: MeshInstance3D = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_banner = $Banner
	_camera = $Camera3D
	_banner.global_position = room_center
	_look_target = room_center
	# Ракурс фиксируется ОДИН раз: дальше камера только скользит (пан без
	# вращения). look_at каждый кадр в догоняющую точку давал качку —
	# направление взгляда подруливало, пока позиция отстаёт («укачивает»).
	_camera.look_at_from_position(room_center + camera_offset, room_center, Vector3.UP)
	_cmd_line = AoeVisual.spawn_ground_line(self, room_center, room_center, CMD_COLOR, 0.16)
	_cmd_ring = AoeVisual.spawn_ground_ring(self, room_center, CMD_RING_RADIUS, 0.0, CMD_COLOR)
	_cmd_line.visible = false
	_cmd_ring.visible = false
	_wave_timer = first_wave_delay
	_spawn_squad()
	# Тестовые грузы трёх классов: сколько гномов нужно, чтобы поднять.
	_spawn_cargo(room_center + Vector3(-6, 0, 5), 1)
	_spawn_cargo(room_center + Vector3(6, 0, 6), 3)
	_spawn_cargo(room_center + Vector3(0, 0, -7), 5)
	_update_labels()
	print("[DungeonSandbox] boot ok: gnomes=%d, skeleton_scene=%s"
			% [_alive_gnomes(), skeleton_scene != null])


func _spawn_squad() -> void:
	var data: Dictionary = SoldierSystem.get_soldier_data(ARCHER_TYPE)
	if data.is_empty():
		push_error("[DungeonSandbox] нет %s в SOLDIER_CATALOG" % ARCHER_TYPE)
		return
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("[DungeonSandbox] у %s нет scene в каталоге" % ARCHER_TYPE)
		return
	# Статы из каталога + данж-оверрайды темпа (см. доки exports выше).
	var stats: Dictionary = (data.get("stats", {}) as Dictionary).duplicate()
	stats["move_speed"] = gnome_move_speed * gnome_speed_scale
	# 9.0 = дефолт Gnome.caravan_sprint_speed — крейсер ведомого отряда.
	stats["caravan_sprint_speed"] = 9.0 * gnome_speed_scale
	stats["attack_range"] = gnome_attack_range
	stats["attack_cooldown_min"] = gnome_cooldown_min
	stats["attack_cooldown_max"] = gnome_cooldown_max
	stats["attack_damage_min"] = gnome_damage_min
	stats["attack_damage_max"] = gnome_damage_max
	stats["steer_inertia"] = gnome_steer_inertia
	stats["steer_grip"] = gnome_steer_grip
	stats["drift_scrub"] = gnome_drift_scrub
	stats["drift_formation_pull"] = gnome_drift_formation_pull
	stats["run_ramp_time"] = gnome_run_ramp_time
	stats["run_speed_boost"] = gnome_run_boost
	_squad = Squad.new()
	_squad.id = 1
	_squad.soldier_type = ARCHER_TYPE
	_squad.icon_color = data.get("icon_color", Color.WHITE)
	_squad.charge_max = float(data.get("charge_max", 15.0))
	for i in range(squad_size):
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			continue
		# LOD ВЫКЛЮЧЕН (баг «разлёт за карту»): якорь LOD — родитель камеры,
		# в песочнице это корень сцены в мировом нуле, а комната сдвинута на
		# (40,40) → дальняя половина всегда считалась «FAR» = движение БЕЗ
		# коллизий/гравитации, на 15 м/с гномы улетали сквозь стены. Конус 90°
		# = полусфера (не срабатывает с камерой сверху). До add_child —
		# cos конуса кэшируется в _ready.
		soldier.lod_far_distance = 100000.0
		soldier.lod_offscreen_half_angle_deg = 90.0
		# ТЕЛЕСНОСТЬ (фидбек 2026-07-23): гном врезается в скелетов. В основной
		# игре выключено ради перфа толп (см. Layers.MASK_SKELETON) — тут
		# масштабы крошечные, включаем per-instance обоюдно (см. _spawn_wave).
		soldier.collision_mask |= Layers.ENEMIES
		add_child(soldier)
		var ang: float = TAU * float(i) / float(squad_size)
		var pos := room_center + Vector3(cos(ang) * 1.5, 0.5, sin(ang) * 1.5)
		soldier.setup_free(ARCHER_TYPE, stats, pos, _banner)
		_squad.add_member(soldier)
		soldier.destroyed.connect(_on_gnome_died)
	# strict=false: мягкий HOLD — стрельба всегда приоритетнее марша.
	# Стоячий строй — «черепаха»-блок вместо кольца (фидбек 2026-07-23).
	_squad.hold_grid = true
	_squad.command_hold(room_center, false)


func _physics_process(delta: float) -> void:
	var cursor: Vector3 = _cursor_ground_point()
	# Движение по ЛКМ-«поводку»: пока держишь — точка приказа течёт за курсором;
	# отпустил — фиксируется, отряд доходит и встаёт (ёж на 360°). Постоянное
	# следование убрано по фидбеку 2026-07-23: стоять/идти — осознанный выбор.
	var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _game_over
	# ПКМ = ТОРМОЗ «как на тачке» (2026-07-23; пин-свинг отключён, его код в
	# SoldierGnome спит): ход гасится, руление живёт — тормоз в повороте и
	# ручник-дрифт работают. Точка приказа продолжает следовать за курсором.
	var brake: bool = lmb and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	_ramp_now = _avg_ramp()
	if lmb and not _lmb_was_down and _squad != null:
		# ЛКМ = педаль газа: нажатие МГНОВЕННО перебивает юз — руление
		# подхватывает юнита с текущей скоростью, не дожидаясь остановки.
		for m in _squad.members:
			if is_instance_valid(m):
				m.coast_active = false
	if lmb and cursor != Vector3.INF and _squad != null:
		# Поводок ограничен от центра отряда (куча идёт дугами, не хвостом) и
		# РАСТЁТ с разгоном: на скорости появляется запас на замах.
		var leash: float = lerpf(leash_max, leash_max_full, _ramp_now)
		var target: Vector3 = cursor
		var c: Vector3 = _squad.compute_center()
		if c != Vector3.INF:
			var to_cursor := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
			var d: float = to_cursor.length()
			if d > leash:
				target = Vector3(c.x, 0.0, c.z) + to_cursor * (leash / d)
		_squad.hold_position = target
		_banner.global_position = target
	if brake != _braking and _squad != null:
		_braking = brake
		for m in _squad.members:
			if is_instance_valid(m):
				m.brake_active = brake
	if _lmb_was_down and not lmb and _squad != null:
		# Отпустили — ЮЗ по инерции (модель «тачка», сменила ранний «резкий
		# стоп»): каждый гном докатывается с трением и встаёт сам; ёж
		# собирается там, где остановились (точка приказа едет за центроидом
		# ниже). Пульс — подтверждение «отпустил» на месте отпускания.
		for m in _squad.members:
			if is_instance_valid(m):
				m.start_coast()
		AoeVisual.spawn_ground_ring(self, _squad.hold_position, CMD_RING_RADIUS + 0.25, 0.5, CMD_COLOR)
	_lmb_was_down = lmb
	if not lmb and _squad != null:
		# Пока не ведём: точка приказа следует за центроидом — после юза
		# позиционирование паркует всех на месте остановки, а не тянет
		# назад к точке отпускания. МЁРТВАЯ ЗОНА 0.75м — асимметрия строя
		# (неполный ряд черепахи) иначе создаёт фидбек-луп «центроид смещён →
		# точка уехала → строй пополз» и отряд бесконечно пятится.
		var cc: Vector3 = _squad.compute_center()
		if cc != Vector3.INF:
			var dxh: float = cc.x - _squad.hold_position.x
			var dzh: float = cc.z - _squad.hold_position.z
			if dxh * dxh + dzh * dzh > 0.5625:
				_squad.hold_position = Vector3(cc.x, 0.0, cc.z)
				_banner.global_position = _squad.hold_position
	_update_drift(lmb)
	_update_tail(lmb, delta)
	_tick_dust(delta, lmb)
	_tick_cargo(delta)
	_update_cmd_visuals(lmb)
	if not _game_over:
		_wave_timer -= delta
		if _wave_timer <= 0.0:
			_wave_timer = wave_interval
			_spawn_wave()
	_update_camera(delta, cursor)


## Линия отряд→точка + кольцо на точке. Видимы, пока приказ «в исполнении»
## (держим ЛКМ или отряд ещё не дошёл); по прибытии гаснут. Линия наливается
## цветом с разгоном, при натянутой верёвке пина — вспышка до белого.
func _update_cmd_visuals(lmb: bool) -> void:
	if _squad == null or _cmd_line == null or _cmd_ring == null:
		return
	var hold: Vector3 = _squad.hold_position
	var center: Vector3 = _squad.compute_center()
	var dist: float = 0.0
	if center != Vector3.INF:
		dist = Vector2(center.x - hold.x, center.z - hold.z).length()
	var active: bool = center != Vector3.INF and (lmb or dist > CMD_ARRIVED_DIST)
	if not active:
		_cmd_line.visible = false
		_cmd_ring.visible = false
		return
	_cmd_ring.visible = true
	_cmd_ring.global_position = Vector3(hold.x, 0.05, hold.z)
	AoeVisual.update_ground_line(_cmd_line,
			Vector3(center.x, 0.0, center.z), Vector3(hold.x, 0.0, hold.z))
	# Линия «горит» в скольжении; вне него — тлеет по разгону (слабо:
	# разгон — второстепенный сигнал).
	var hot: float = _ramp_now * 0.45
	if _drifting:
		hot = 1.0
	var mat := _cmd_line.material_override as StandardMaterial3D
	if mat != null:
		var c: Color = CMD_COLOR.lerp(Color(0.92, 0.99, 1.0, 1.0), hot * 0.85)
		mat.albedo_color = c
		mat.emission = Color(c.r, c.g, c.b, 1.0)
		mat.emission_energy_multiplier = 2.5 + 4.5 * hot


## Детектор дрифт-события (уровень ОТРЯДА, вход/выход синхронные): на скорости
## резкий увод точки вбок (угол скорость↔направление > enter-порога) → все
## разом в скольжение + отдача (пыль-залп); дуга выровнялась (< exit-порога)
## или ход упал — все разом выходят. Гистерезис порогов держит состояние
## стабильным внутри дуги.
func _update_drift(lmb: bool) -> void:
	if _squad == null:
		return
	if not lmb:
		_set_drifting(false)
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		_set_drifting(false)
		return
	var avg_v := Vector3.ZERO
	var n: int = 0
	for m in _squad.members:
		if is_instance_valid(m):
			avg_v += Vector3(m.velocity.x, 0.0, m.velocity.z)
			n += 1
	if n == 0:
		_set_drifting(false)
		return
	avg_v /= float(n)
	var speed: float = avg_v.length()
	var desired := Vector3(_squad.hold_position.x - c.x, 0.0, _squad.hold_position.z - c.z)
	if speed < 0.5 or desired.length_squared() < 0.25:
		if _drifting and speed < 1.0:
			_set_drifting(false)
		return
	var ang: float = rad_to_deg(avg_v.angle_to(desired))
	if not _drifting:
		if speed >= drift_min_speed and ang >= drift_enter_angle_deg:
			_set_drifting(true)
	elif ang <= drift_exit_angle_deg or speed < 1.0:
		_set_drifting(false)


## Синхронный вход/выход скольжения для всего отряда. На входе — отдача:
## пых пыли из-под каждого гнома («сорвались») + сброс троттла пыли.
func _set_drifting(on: bool) -> void:
	if _drifting == on or _squad == null:
		return
	_drifting = on
	for m in _squad.members:
		if is_instance_valid(m):
			m.drift_active = on
			if on:
				_spawn_soft_dust(Vector3(m.global_position.x, 0.1, m.global_position.z))
	if on:
		_dust_timer = 0.0


const CARGO_GROUP := &"dungeon_cargo"

## Груз-куб (RigidBody3D): meta "need" = сколько гномов несут ОДНОВРЕМЕННО.
## Размер/теплота цвета растут с классом. В руках заморожен (freeze) и
## ведётся кодом; брошен/выпал — размораживается и летит по уровню физикой
## (слой ITEMS: пол/стены/скелеты его останавливают, гномы проходят).
func _spawn_cargo(pos: Vector3, need: int) -> void:
	var side: float = 0.35 + 0.22 * float(need)
	var body := RigidBody3D.new()
	body.collision_layer = Layers.ITEMS
	body.collision_mask = Layers.TERRAIN | Layers.ITEMS
	body.mass = 2.0 * float(need)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(side, side, side)
	shape.shape = box_shape
	body.add_child(shape)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(side, side, side)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.62 - 0.07 * float(need), 0.2, 1.0)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 0.6
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)
	body.set_meta(&"need", need)
	body.add_to_group(CARGO_GROUP)
	add_child(body)
	body.global_position = Vector3(pos.x, side * 0.5 + 0.05, pos.z)


## E: поднять ближайший груз (если хватает гномов) / бросить несомый.
func _toggle_cargo() -> void:
	if _squad == null:
		return
	if _cargo != null:
		_drop_cargo()
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	var item: Node3D = _nearest_cargo(c)
	if item == null:
		return
	var need: int = int(item.get_meta(&"need", 1))
	var alive: Array = []
	for m in _squad.members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.size() < need:
		# Не хватает рук — короткий красный пульс на грузе (язык «нельзя»).
		AoeVisual.spawn_ground_ring(self, item.global_position, 0.9, 0.4,
				Color(1.0, 0.25, 0.25, 0.9))
		return
	# Носильщики — ближайшие к грузу N (sticky до смерти/броска).
	_haulers.clear()
	while _haulers.size() < need and not alive.is_empty():
		var w: Node3D = _pop_nearest_unit(alive, item.global_position)
		w.hauling = true
		_haulers.append(w)
	_cargo = item
	var rb := item as RigidBody3D
	if rb != null:
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
	AoeVisual.spawn_ground_ring(self, item.global_position, 1.0, 0.4, CMD_COLOR)
	_update_labels()


## Бросок/выпадение: груз размораживается и летит физикой, наследуя средний
## ход носильщиков (+подброс) — на дрифте его красиво выносит по дуге.
func _drop_cargo() -> void:
	if _cargo == null:
		return
	var toss := Vector3.ZERO
	var n: int = 0
	for h in _haulers:
		if is_instance_valid(h):
			toss += Vector3(h.velocity.x, 0.0, h.velocity.z)
			n += 1
			h.hauling = false
	if n > 0:
		toss /= float(n)
	_haulers.clear()
	var rb := _cargo as RigidBody3D
	if rb != null:
		rb.freeze = false
		rb.linear_velocity = toss * 1.1 + Vector3.UP * 2.2
		rb.angular_velocity = Vector3(randf_range(-2, 2), randf_range(-3, 3), randf_range(-2, 2))
	_cargo = null
	_update_labels()


## Тик переноски: груз жёстко над центроидом носильщиков; павших сменяют
## свободные; рук меньше, чем нужно → груз падает сам.
func _tick_cargo(_delta: float) -> void:
	if _cargo == null or _squad == null:
		return
	var need: int = int(_cargo.get_meta(&"need", 1))
	var free: Array = []
	for i in range(_haulers.size() - 1, -1, -1):
		if not is_instance_valid(_haulers[i]):
			_haulers.remove_at(i)
	for m in _squad.members:
		if is_instance_valid(m) and not (m in _haulers):
			free.append(m)
	while _haulers.size() < need and not free.is_empty():
		var w: Node3D = _pop_nearest_unit(free, _cargo.global_position)
		w.hauling = true
		_haulers.append(w)
	if _haulers.size() < need:
		_drop_cargo()
		return
	# Груз висит над ЦЕНТРОИДОМ НОСИЛЬЩИКОВ (не всего отряда) — видно, кто
	# именно тащит, и куб мотается вместе с их группой.
	var c := Vector3.ZERO
	var cnt: int = 0
	for h in _haulers:
		if is_instance_valid(h):
			c += h.global_position
			cnt += 1
	if cnt == 0:
		_drop_cargo()
		return
	c /= float(cnt)
	# ЖЁСТКАЯ сцепка (фидбек 2026-07-23): без лерпа — сглаживание отставало
	# на ходу/дрифте («куб вылетает за группу»). Буквально несут в руках.
	_cargo.global_position = Vector3(c.x, cargo_carry_height, c.z)


func _nearest_cargo(near: Vector3) -> Node3D:
	var best: Node3D = null
	var best_sq: float = cargo_pickup_radius * cargo_pickup_radius
	for n in get_tree().get_nodes_in_group(CARGO_GROUP):
		var e := n as Node3D
		if e == null or not is_instance_valid(e) or e == _cargo:
			continue
		var dx: float = e.global_position.x - near.x
		var dz: float = e.global_position.z - near.z
		if dx * dx + dz * dz < best_sq:
			best_sq = dx * dx + dz * dz
			best = e
	return best


## Вынуть из массива юнита, ближайшего к point (XZ).
func _pop_nearest_unit(units: Array, point: Vector3) -> Node3D:
	var best_i: int = 0
	var best_d: float = INF
	for i in range(units.size()):
		var u: Node3D = units[i]
		var dx: float = u.global_position.x - point.x
		var dz: float = u.global_position.z - point.z
		var d: float = dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best_i = i
	var out: Node3D = units[best_i]
	units.remove_at(best_i)
	return out


## Средний разгон живых членов отряда (0..1).
func _avg_ramp() -> float:
	if _squad == null:
		return 0.0
	var sum: float = 0.0
	var n: int = 0
	for m in _squad.members:
		if is_instance_valid(m):
			sum += m.run_ramp()
			n += 1
	return sum / float(n) if n > 0 else 0.0


## Хвост кометы: на бегу слоты вытягиваются за точкой (длина с разгоном),
## на стопе/пине — штатное кольцо-«ёж». Направление хвоста СГЛАЖЕНО:
## мгновенный флип на резкой смене курса телепортировал слоты на
## противоположную сторону (до 4.5м) — гномы лютовали за ними врассыпную.
func _update_tail(lmb: bool, delta: float) -> void:
	if _squad == null:
		return
	if not lmb or _ramp_now < 0.15:
		_squad.tail_length = 0.0
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		_squad.tail_length = 0.0
		return
	var dir := Vector3(_squad.hold_position.x - c.x, 0.0, _squad.hold_position.z - c.z)
	if dir.length_squared() < 1.0:
		_squad.tail_length = 0.0
		return
	dir = dir.normalized()
	var prev: Vector3 = _squad.tail_dir
	if prev != Vector3.ZERO and _squad.tail_length > 0.0:
		var k: float = 1.0 - exp(-4.0 * delta)
		var blended: Vector3 = prev.lerp(dir, k)
		# Разворот ~180°: лерп схлопывается в ноль — берём новый курс сразу.
		if blended.length_squared() > 0.04:
			dir = blended.normalized()
	_squad.tail_dir = dir
	_squad.tail_length = tail_length_full * _ramp_now


## Пыль из-под ног на высоком разгоне — «заряжен» читается боковым зрением.
func _tick_dust(delta: float, moving: bool) -> void:
	_dust_timer -= delta
	# Пыль = «визг шин»: сыпется в скольжении и на тормозе.
	if not moving or not (_drifting or _braking) or _dust_timer > 0.0 or _squad == null:
		return
	_dust_timer = 0.12
	var alive: Array = []
	for m in _squad.members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.is_empty():
		return
	var m2: Node3D = alive[randi() % alive.size()]
	_spawn_soft_dust(Vector3(m2.global_position.x, 0.1, m2.global_position.z))


## Деликатный пых пыли: AoeVisual.spawn_dust — это slam-взрыв (72 частицы,
## «непонятно, что за взрывы» — фидбек), тут те же ассеты, но 4 мелкие
## частицы с коротким веком — лёгкий след, не событие.
func _spawn_soft_dust(pos: Vector3) -> void:
	var process_mat := load(AoeVisual.DUST_PROCESS_PATH) as ParticleProcessMaterial
	var dust_mat := load(AoeVisual.DUST_MATERIAL_PATH) as StandardMaterial3D
	if process_mat == null or dust_mat == null:
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var particles := GPUParticles3D.new()
	particles.process_material = process_mat
	particles.draw_pass_1 = quad
	particles.material_override = dust_mat
	particles.amount = 4
	particles.lifetime = 0.45
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.finished.connect(particles.queue_free)
	add_child(particles)
	particles.global_position = pos
	particles.emitting = true


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_R:
		get_tree().reload_current_scene()
	elif key.keycode == KEY_T and not _game_over:
		_wave_timer = wave_interval
		_spawn_wave()
	elif key.keycode == KEY_E and not _game_over:
		_toggle_cargo()


## Пересечение луча курсора с плоскостью пола (math, без физики) + кламп в комнату.
func _cursor_ground_point() -> Vector3:
	if _camera == null:
		return Vector3.INF
	var mp: Vector2 = get_viewport().get_mouse_position()
	var origin: Vector3 = _camera.project_ray_origin(mp)
	var dir: Vector3 = _camera.project_ray_normal(mp)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	if hit == null:
		return Vector3.INF
	var p: Vector3 = hit
	p.x = clampf(p.x, room_center.x - room_half + 2.0, room_center.x + room_half - 2.0)
	p.z = clampf(p.z, room_center.z - room_half + 2.0, room_center.z + room_half - 2.0)
	return p


func _update_camera(delta: float, cursor: Vector3) -> void:
	var center: Vector3 = room_center
	if _squad != null:
		var c: Vector3 = _squad.compute_center()
		if c != Vector3.INF:
			center = c
		elif cursor != Vector3.INF:
			center = cursor
	var goal: Vector3 = center
	if cursor != Vector3.INF:
		goal = center.lerp(Vector3(cursor.x, 0.0, cursor.z), camera_cursor_bias)
	var k: float = 1.0 - exp(-camera_follow_speed * delta)
	_look_target = _look_target.lerp(goal, k)
	_camera.global_position = _camera.global_position.lerp(_look_target + camera_offset, k)
	# Микро-качка взгляда: aim — смесь «нулевой» точки (позиция минус offset,
	# даёт неподвижный ракурс) и живой догоняющей точки. camera_sway дозирует
	# амплитуду вращения, не меняя характер движения.
	var aim: Vector3 = (_camera.global_position - camera_offset).lerp(_look_target, camera_sway)
	_camera.look_at(aim, Vector3.UP)


func _spawn_wave() -> void:
	if skeleton_scene == null:
		push_warning("[DungeonSandbox] skeleton_scene не задан")
		return
	_wave_number += 1
	var count: int = wave_base_count + wave_growth * (_wave_number - 1)
	var alive: int = get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP).size()
	count = mini(count, maxi(max_alive_skeletons - alive, 0))
	for i in range(count):
		var sk := skeleton_scene.instantiate() as Node3D
		if sk == null:
			continue
		# LOD выключен по той же причине, что у гномов (см. _spawn_squad):
		# FAR-скелет отключает коллизии и ходит сквозь стены.
		sk.set(&"lod_far_distance", 100000.0)
		sk.set(&"lod_offscreen_half_angle_deg", 90.0)
		# Зеркало телесности: скелет упирается в гномов, а не проходит сквозь.
		# Через extra_collision_mask — простое `|=` затиралось бы
		# Skeleton._apply_lod_physics_mode на LOD-переходах.
		sk.set(&"extra_collision_mask", Layers.FRIENDLY_UNIT)
		if sk is CollisionObject3D:
			(sk as CollisionObject3D).collision_mask |= Layers.FRIENDLY_UNIT
		add_child(sk)
		sk.global_position = _edge_spawn_point()
		var target: Node3D = _random_alive_gnome()
		if target != null and sk.has_method(&"set_forced_target"):
			sk.call(&"set_forced_target", target)
		if sk.has_signal(&"destroyed"):
			sk.connect(&"destroyed", _on_skeleton_died)
	var c: Vector3 = _squad.compute_center() if _squad != null else Vector3.INF
	print("[DungeonSandbox] волна %d: +%d скелетов, отряд @ (%.1f, %.1f), цель @ (%.1f, %.1f)"
			% [_wave_number, count, c.x, c.z, _squad.hold_position.x, _squad.hold_position.z])
	_update_labels()


## Случайная точка у внутренней кромки случайной стены (наземный Y).
func _edge_spawn_point() -> Vector3:
	var t: float = randf_range(-room_half + 3.0, room_half - 3.0)
	var edge: float = room_half - 2.5
	var local: Vector3
	match randi() % 4:
		0: local = Vector3(t, 0.6, -edge)
		1: local = Vector3(t, 0.6, edge)
		2: local = Vector3(-edge, 0.6, t)
		_: local = Vector3(edge, 0.6, t)
	return Vector3(room_center.x, 0.0, room_center.z) + local


func _random_alive_gnome() -> Node3D:
	if _squad == null:
		return null
	var alive: Array = []
	for m in _squad.members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.is_empty():
		return null
	return alive[randi() % alive.size()]


func _alive_gnomes() -> int:
	return _squad.count_alive() if _squad != null else 0


func _on_gnome_died() -> void:
	print("[DungeonSandbox] гном пал, осталось %d" % _alive_gnomes())
	_update_labels()
	if _alive_gnomes() <= 0 and not _game_over:
		_game_over = true
		print("[DungeonSandbox] отряд погиб (волна %d, убито %d)" % [_wave_number, _kills])
		($HUD/Center/GameOverLabel as Label).visible = true


func _on_skeleton_died() -> void:
	_kills += 1
	_update_labels()


func _update_labels() -> void:
	($HUD/Panel/Rows/WaveLabel as Label).text = "Волна: %d" % _wave_number
	($HUD/Panel/Rows/SquadLabel as Label).text = "Гномов: %d / %d" % [_alive_gnomes(), squad_size]
	($HUD/Panel/Rows/KillLabel as Label).text = "Убито: %d" % _kills
	var cargo_txt: String = "Груз: —"
	if _cargo != null:
		cargo_txt = "Груз: несут %d (стволов −%d)" % [_haulers.size(), _haulers.size()]
	($HUD/Panel/Rows/CargoLabel as Label).text = cargo_txt
