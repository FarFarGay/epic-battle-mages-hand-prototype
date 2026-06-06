class_name EnemyMech
extends SkeletonArcher
## Вражеский мех — естественный враг башни (рамка «бой мехов»). Башня — гномий
## мех (APEX), и противостоять ей может только другой мех. Крупный, быстрый,
## стреляет тяжёлым прицельным снарядом по Tower с дистанции. Целит ТОЛЬКО башню
## — лагерь игнорит полностью (роль чистая: лагерь = забота защитников, мех =
## угроза башне).
##
## Механически — наследник SkeletonArcher (готовая kite-FSM: подойти на
## дистанцию → windup-телеграф → выстрел → cooldown + баллистический снаряд).
## Тематически — механический конструкт (холодный металл + emission-реактор),
## не нежить-зверь.
##
## Пока вызывается только читом (WaveDirector.cheat_spawn_mech). Авто-спавн в
## волнах + мех-оружие башни + баланс дуэли — следующий этап.

const MECH_GROUP := &"enemy_mech"

## Туман рассеивает собой — крупный силуэт виден издалека (часть телеграфа).
var fog_reveal_radius: float = 12.0

@export_group("Fireball (как у башни)")
## Снаряд — тот же fireball.tscn, что кастует башня (HandSpellFireball). Так
## «атака меха = атака башни». Если null — fallback на базовый archer-выстрел.
@export var fireball_scene: PackedScene
## Параметры траектории — общий ресурс с башней (resources/ballistic_default.tres).
@export var ballistics: BallisticConfig = preload("res://resources/ballistic_default.tres")
## Урон/радиус — дефолты под башенный фаербол (damage 30, radius 3). Тюнится.
@export var fireball_damage: float = 30.0
@export var fireball_radius: float = 3.0
@export var fireball_knockback_force: float = 35.0
@export var fireball_knockback_lift: float = 0.5
@export var fireball_knockback_duration: float = 0.4
## Откуда вылетает снаряд (над «корпусом» меха).
@export var fireball_launch_offset_y: float = 2.4
@export_group("")

@export_group("Mobility")
## Скорость стрейфа (облёта) вокруг башни во время WINDUP/COOLDOWN. База-лучник
## стоит на месте в эти фазы — мех вместо этого кружит, оставаясь подвижной
## целью. 0 = стоять (старое поведение).
@export var strafe_speed: float = 6.0
## Период смены направления облёта (сек) — чтобы не ходить по кругу предсказуемо.
@export var strafe_flip_interval: float = 2.5
## Evade-рывок (уклонение от фаербола игрока). ИДЕНТИЧЕН рывку игрока по длине и
## визуалу (наклон/стретч/трейл — общий DashFx): скорость и длительность как у
## башни (22 × 0.24 ≈ 5.3м). 0 = рывок выключен.
@export var dash_speed: float = 22.0
## Длительность рывка (сек). dash_speed × dash_duration ≈ путь (22 × 0.24 ≈ 5.3м).
@export var dash_duration: float = 0.24
## Радиус «чувствования» препятствий (палатки/ресурсы) для обтекания. 0 = выкл.
@export var avoid_radius: float = 3.5
## Сила отруливания от препятствий (× move_speed). Подбирается: мало — задевает,
## много — нервно шарахается.
@export var avoid_strength: float = 1.0
## Спринт-преследование: множитель скорости, когда башня ДАЛЬШЕ kite_max_range.
## Закрывает «бублик» — безопасную парковку за зоной связки (мех не шлёт туда
## ничего, но и не даёт спокойно стоять — догоняет). 1.0 = без спринта.
@export var pursuit_speed_mult: float = 1.7
@export_group("")

@export_group("Reactive (уклонение от игрока)")
## Радиус, в котором мех «замечает» летящий фаербол игрока (группа
## player_projectile) и уклоняется рывком вбок. 0 = реакции выключены.
@export var dodge_detect_radius: float = 9.0
## Кулдаун уклонения (сек) — чтобы мех не дёргался непрерывно при серии
## фаерболов, но реагировал быстро.
@export var dodge_cooldown: float = 1.0
## Пуниш: после уворота остаток cooldown сокращается до этого — быстрая
## контратака («увернулся И сразу огрызнулся»). 0 = без сокращения.
@export var punish_cooldown: float = 0.4
## Снап-выстрел после уворота: следующий windup укорачивается до этого значения
## (быстрый замах). 0 = обычный windup.
@export var snap_windup: float = 0.3
@export_group("")

@export_group("Aim")
## Доля упреждения по скорости башни: 0 = бить в текущую позицию (игрок уходит
## просто двигаясь), 1 = полное упреждение (бьёт на перехват). 0.6-0.9 — попадает
## по движущейся башне, но резкая смена курса игроком всё ещё переигрывает.
@export_range(0.0, 1.5) var aim_lead: float = 0.9
## Кап времени упреждения (сек) — на больших дистанциях не уводит точку в небо.
@export var aim_lead_max_time: float = 1.0
## Кап ДИСТАНЦИИ упреждения (м): точка не отъезжает от башни дальше этого. Чуть
## выше нуля даёт упреждению работать (попадать по движущейся), но не «улетать»
## на полкарты. 0 = без капа.
@export var aim_lead_max_distance: float = 4.0
## Разброс тайминга windup/cooldown (доля ±) — рваный ритм, чтобы игрок не
## привыкал и не таймил свои уклонения. 0 = ровный ритм.
@export_range(0.0, 0.8) var rhythm_jitter: float = 0.35
## Плавность «ведения» точки прицела к упреждённой позиции (exp-decay rate):
## выше = точка снаппее, ниже = плавнее/инертнее. Точка = реальная цель выстрела.
@export var telegraph_follow_rate: float = 5.0
## За сколько секунд ДО выстрела точка ФИКСИРУЕТСЯ (перестаёт вести) и начинает
## пульсировать = «коммит». Это окно уворота: видишь финальную точку и уходишь.
@export var telegraph_lock_time: float = 0.35
## Цвет точки в фазе lock (коммит) — тревожнее основного, чтобы момент читался.
@export var telegraph_lock_color: Color = Color(1.0, 0.35, 0.15, 0.95)
@export_group("")

@export_group("Attacks (паттерн)")
## Глобальный «бит»-дирижёр: после ЛЮБОЙ атаки (ближняя/залп/поле) — общая пауза
## (сек), пока которой НИКТО не атакует. Сериализует три подсистемы в один
## читаемый ритм «телеграф → атака → вдох». Главный рычаг плотности боя.
@export var global_attack_cooldown: float = 3.0
## Хореография по дистанции: ближе kite_min_range — ближняя фаза (чередование
## AIMED↔Шквал); в [kite_min..kite_max] — связка Поле→Ракеты («поймал→добил»);
## дальше kite_max — спринт-преследование (мех сближается).
@export var kite_min_range: float = 22.0
@export var kite_max_range: float = 50.0
## Пауза после полной связки Поле→Ракеты перед следующей (сек).
@export var kite_combo_cooldown: float = 3.0
## «Окно наказания»: пока башня поймана замедлением поля — бит умножается на это
## (бодрее стреляет), и мех долбит ракетами подряд без перезахода в поле. <1 = чаще.
@export var frenzy_beat_mult: float = 0.45
## (Ближняя фаза чередует AIMED/Шквал детерминированно; веса оставлены как
## выключатели приёма — 0 убирает его из чередования.)
@export var weight_aimed: float = 1.0
@export var weight_spread: float = 0.6
## Веер: число фаерболов и шаг между точками (перпендикулярно линии огня).
## ЧЕСТНОСТЬ: spread_spacing >= 2×spread_radius → взрывы НЕ перекрываются, игрок
## ловит максимум один (а не 2-3 разом), между ними щели для рывка.
@export var spread_count: int = 4
@export var spread_spacing: float = 6.0
## Радиус взрыва ОДНОГО фаербола Шквала (отдельный от AIMED fireball_radius —
## мельче, чтобы стенка была из отдельных взрывов с просветами, а не сплошной).
@export var spread_radius: float = 3.0
## Интервал между последовательными выстрелами веера (сек) — скорость «развёртки».
@export var spread_interval: float = 0.22
## Сколько живёт наземный маркер каждого выстрела веера (сек, авто-fade).
@export var spread_marker_duration: float = 0.6
@export_group("")

@export_group("Missiles (анти-кайт — вдогонку)")
## Дальнобойная подсистема (НЕ в _pick_attack): пока башня за пределом обычной
## дальности и кайтит, мех пускает залп слабо-самонаводящихся ракет, которые
## ведут движущуюся башню. Закрывает дыру «воюю на 40м, где он не достаёт».
@export var missiles_enabled: bool = true
## Ракет в залпе. Залп вызывается связкой Поле→Ракеты (см. kite-комбо), не сам.
@export var missile_count: int = 3
## Телеграф-лок на башне перед залпом (сек).
@export var missile_warn: float = 0.5
## Интервал «пуск-пуск-пуск» внутри залпа (сек).
@export var missile_spawn_interval: float = 0.12
## Сколько мех ВЕДЁТ ракету к башне (сек); после — летит к последней точке и рвётся.
@export var missile_lifetime: float = 4.0
@export var missile_damage: float = 40.0
@export var missile_radius: float = 3.0
## Homing: скорость и поворотливость. Слабый turn_rate — рывок игрока СБИВАЕТ
## ракету (так и задумано: ракеты не должны решать сами по себе, см. slow-field —
## ловим мобильность дебафом, а не цепкостью homing'а).
@export var missile_max_speed: float = 20.0
@export var missile_turn_rate: float = 3.0
@export var missile_drift_deg: float = 25.0
@export_group("")

@export_group("Missile Super (парируемый супер-залп)")
## Редкий читаемый супер: мех заряжает рой ракет В ОДНУ ТОЧКУ (под башню). Длинный
## телеграф + длинный кулдаун = драматично и нечасто. Ракеты Reflectable — поймал
## окном парирования (Q) → весь рой летит обратно в меха (жирный урон). Риск/награда:
## не отбил — съел весь залп.
@export var missile_super_enabled: bool = true
## Ракет в супер-залпе (5-6 — заметно больше обычных 3).
@export var missile_super_count: int = 6
## Длинный кулдаун (сек) — супер редкий, не спамится.
@export var missile_super_cooldown: float = 14.0
## Длинный телеграф-лок перед роем (сек) — игрок успевает прочитать и приготовить Q.
@export var missile_super_warn: float = 1.3
## Интервал пуска внутри роя (сек) — МАЛЕНЬКИЙ: ракеты летят кучно, прилетают
## плотным роем, одно окно парирования ловит весь залп.
@export var missile_super_interval: float = 0.05
## Урон одной ракеты супера (× count = суммарный отражённый урон в меха).
@export var missile_super_damage: float = 40.0
## Высота над мехом, где собирается сгусток-заряд и ОТКУДА вылетают ракеты супера
## (над корпусом, выше обычного дула fireball_launch_offset_y).
@export var missile_super_launch_y: float = 4.6
@export_group("")

@export_group("Slow-field (темпоральное поле — анти-мобильность)")
## Сетап-инструмент (НЕ в _pick_attack): мех ставит наземную зону в упреждённую
## точку игрока; внутри башня замедляется (ходьба И рывок) → ракеты/Шквал
## достреливают пойманного. Само поле урона НЕ наносит. Главный рычаг баланса —
## ловим мобильность дебафом, а не гонкой урона.
@export var field_enabled: bool = true
## Заряд-пузырь: летит на игрока с homing'ом (как ракета, но медленнее/слабее), НЕ
## метит зону на земле. Догнал → лопается зоной; не успел за lifetime — гаснет.
@export var field_charge_speed: float = 11.0
## Поворотливость homing'а заряда (низкая — пузырь дугой, уворачиваемый рывком).
@export var field_charge_turn: float = 2.5
## Время жизни заряда (сек). Не догнал за это — гаснет без эффекта (увернулся).
@export var field_charge_lifetime: float = 5.0
## Радиус «догнал» — на этой дистанции до башни пузырь лопается зоной.
@export var field_charge_burst_radius: float = 2.5
## Высота вылета пузыря над мехом (плывёт на этой высоте).
@export var field_charge_launch_y: float = 1.8
## Радиус slow-зоны (м), в которую лопается пузырь.
@export var field_radius: float = 8.0
## Сколько живёт поле (сек).
@export var field_duration: float = 3.0
## Фактор замедления внутри (1 = норма, 0.45 ≈ вдвое медленнее — рывок ослаблен).
@export var field_slow_factor: float = 0.45
## Период рефреша замедления (сек).
@export var field_refresh: float = 0.15
## Цвет поля (фиолетово-голубой «застывшее время» — отличен от оранжевых телеграфов).
@export var field_color: Color = Color(0.55, 0.4, 1.0, 0.85)
@export_group("")

@export_group("Shockwave (отброс — анти-зажим, МГНОВЕННЫЙ)")
## Мех — дальнобойный, в ближний бой не лезет. Подполз в УПОР — МГНОВЕННО отброшен
## (панишинг, без замаха и телеграфа): урон по башне + сильный отброс ПРОЧЬ + глушит
## управление. Не догоняет — отталкивает. Кулдаун, чтобы не срабатывал каждый кадр.
@export var shock_enabled: bool = true
## Дистанция-триггер (горизонтальная, центр-к-центру): игрок ближе — мгновенный
## отброс. Держим ЗАМЕТНО МЕНЬШЕ attack_radius_min (14м, на котором мех кайтит) —
## иначе мех бьёт «по краю» со своей же натуральной дистанции (инородно). 10м =
## «вломился в буфер на ~4м» = реальный зажим.
@export var shock_trigger_range: float = 10.0
## Радиус волны (м) — чуть больше триггера, чтобы отброс достал зажавшего.
@export var shock_radius: float = 11.0
## Кулдаун между отбросами (сек).
@export var shock_cooldown: float = 5.0
## Урон по башне на попадании.
@export var shock_damage: float = 80.0
## Отброс башни ПРОЧЬ от меха: скорость (м/с) и длительность (сек) — сильный «пинок».
@export var shock_knockback_speed: float = 24.0
@export var shock_knockback_duration: float = 0.45
## Цвет телеграфа/волны (красно-оранжевый «опасность»).
@export var shock_color: Color = Color(1.0, 0.3, 0.1, 0.9)
@export_group("")

@export_group("Death (механическая смерть)")
## Радиус взрыва корпуса (AoeVisual.spawn_explosion + урон по скелетам).
@export var death_explosion_radius: float = 6.0
## Радиус расходящейся ударной волны (shockwave-кольцо).
@export var death_shockwave_radius: float = 9.0
## Урон взрыва корпуса по СКЕЛЕТАМ в радиусе (в гуще боя смерть меха расчищает
## толпу — награда за победу в дуэли). 0 = без урона. Башню/гномов НЕ задевает.
@export var death_explosion_damage: float = 120.0
## Отброс скелетов взрывом корпуса (м/с). 0 = без отброса.
@export var death_explosion_knockback: float = 12.0
@export_group("")

@export_group("Telemetry (поведение игрока)")
## Логировать поведение башни в бою и печатать сводку по смерти/удалению меха.
## Дев-инструмент для дизайна 3-го приёма (видим: кайт / укрытие / напор).
@export var telemetry_enabled: bool = true
@export_group("")

## Набор атак меха (паттерн). Базовый AIMED + добавляемые. Выбор — _pick_attack.
enum MechAttack { AIMED, SPREAD }
## Атака текущего цикла — выбирается на входе в WINDUP, используется и телеграфом,
## и выстрелом.
var _current_attack: int = MechAttack.AIMED

## Группа, в которую HandSpellFireball кладёт фаерболы игрока (см. там же).
const PLAYER_PROJECTILE_GROUP := &"player_projectile"
## Слои препятствий для обтекания: палатки/посты (CAMP_OBSTACLE) + ресурсы/предметы
## (ITEMS). Башню (ACTORS) и стены НЕ избегаем — башня цель, через стены и так не
## сталкивается по своей маске.
const AVOID_MASK: int = Layers.CAMP_OBSTACLE | Layers.ITEMS

## AOE-маска атак меха (фаербол/Шквал/ракеты): как у hostile-снаряда
## (башня/лагерь/стены/гномы) ПЛЮС ENEMIES — взрыв задевает и СКЕЛЕТОВ. В толпе
## это обогащает бой (мех бьёт «как башня» — её фаербол тоже ловит скелетов через
## ENEMIES в MASK_HAND_SLAM). Flight-маска (что детонирует снаряд в полёте)
## остаётся БЕЗ ENEMIES — иначе снаряд рвался бы о первого скелета по пути, не
## долетая до прицела; AOE на импакте всё равно достаёт ближних скелетов.
const MECH_AOE_MASK: int = Layers.MASK_HOSTILE_PROJECTILE | Layers.ENEMIES

## Кого задевает урон взрыва корпуса при смерти: только скелетов (ENEMIES + резерв
## COLD_ENEMY под FAR-LOD). НЕ башню/гномов — это награда за победу, не наказание.
const DEATH_AOE_MASK: int = Layers.ENEMIES | Layers.COLD_ENEMY
var _dodge_cd: float = 0.0
## Снап-выстрел запрошен (после уворота) — укорачивает следующий windup.
var _snap_next: bool = false
## Живой телеграф (одно кольцо) — «tell» в WINDUP, ведёт за упреждённой точкой.
var _telegraph_ring: MeshInstance3D = null
## Веер-развёртка: активна ли последовательность, её точки, индекс, таймер шага.
## Снаряды и наземные маркеры выпускаются по одному с интервалом spread_interval.
var _spread_active: bool = false
var _spread_points: Array = []
var _spread_index: int = 0
var _spread_step_timer: float = 0.0
## Сглаженная точка прицела (y=0, на земле). Источник истины: и кольцо, и сам
## выстрел используют её. INF = не инициализирована (вне WINDUP).
var _aim_point: Vector3 = Vector3.INF
## Точка зафиксирована (фаза lock последние telegraph_lock_time сек замаха).
var _aim_locked: bool = false

var _strafe_dir: float = 1.0
var _strafe_flip_timer: float = 0.0
## Рывок (evade): остаток активной фазы и его вектор скорости.
var _dash_remaining: float = 0.0
var _dash_vec: Vector3 = Vector3.ZERO
## Dash-визуал (общий с башней, см. DashFx): база меша + сглаженная интенсивность
## наклона/стретча + таймер призраков трейла.
var _mesh_base_basis: Basis = Basis.IDENTITY
var _dash_fx: float = 0.0
var _dash_ghost_t: float = 0.0

## --- Ракеты «вдогонку» (анти-кайт) ---
## Активные ракеты: [{m: Fireball, t: остаток времени ведения}]. Каждый кадр
## обновляем их target на текущую позицию башни; по t<=0 перестаём вести.
var _missiles: Array = []
var _missile_warn_timer: float = 0.0
var _missile_spawn_timer: float = 0.0
var _missile_salvo_index: int = 0
var _missile_pending: bool = false
## Параметры текущего залпа (обычный или супер) — задаёт _start_missile_salvo.
var _missile_active_count: int = 0
var _missile_active_interval: float = 0.0
var _missile_active_damage: float = 0.0
## Высота старта ракет текущего залпа (супер — из сгустка над корпусом, обычный — дуло).
var _missile_active_launch_y: float = 0.0
## Кулдаун редкого парируемого супер-залпа (рой ракет в одну точку).
var _missile_super_cd: float = 0.0

## Глобальный бит: общий «вдох» после любой атаки. Пока > 0 — никто не стреляет
## (ближний windup растягивается до него, kite-комбо ждёт). Сериализует ритм.
var _global_action_cd: float = 0.0
## Ближняя фаза: переключатель чередования AIMED↔Шквал (детерминированно).
var _near_toggle: bool = false
## Kite-комбо: шаг (0 = следующее Поле, 1 = следующее Ракеты) + пауза после связки.
var _combo_step: int = 0
var _combo_cd: float = 0.0
## Поймана ли башня замедлением прямо сейчас (обновляется в _ai_step) — для frenzy.
var _target_slowed: bool = false


## Текущий «вдох» (бит): короче, пока башня поймана замедлением (frenzy-наказание).
func _beat() -> float:
	return global_attack_cooldown * (frenzy_beat_mult if _target_slowed else 1.0)
## Отброс (анти-зажим, мгновенный): только кулдаун между срабатываниями.
var _shock_cd: float = 0.0

## --- Телеметрия боя (поведение игрока) ---
var _telem_active: bool = false
var _telem_reported: bool = false
var _telem_time: float = 0.0
var _telem_frames: int = 0
var _telem_dist_sum: float = 0.0
var _telem_close: int = 0       # дистанция < attack_radius_min (вплотную)
var _telem_mid: int = 0         # в боевой полосе
var _telem_far: int = 0         # дальше attack_radius_max (кайт)
var _telem_speed_sum: float = 0.0
var _telem_moving: int = 0      # башня движется (> 0.5 м/с)
var _telem_flee: int = 0        # курс «прочь от меха»
var _telem_approach: int = 0    # курс «на меха»
var _telem_lateral: int = 0     # боком
var _telem_cover: int = 0       # LoS до башни перекрыт укрытием
var _telem_aggro: int = 0       # снаряд игрока рядом с мехом
var _telem_tower_hp_start: float = -1.0
## Нагрузка: счётчики атак за бой (ближние AIMED/Шквал, залпы ракет, поля) — для
## оценки плотности/ритма (атак в минуту, средний промежуток).
var _telem_atk_near: int = 0
var _telem_atk_missile: int = 0
var _telem_atk_field: int = 0
var _telem_atk_shock: int = 0

## Shared material всех мехов — один draw-call. Холодный металл с emission'ом
## «реактора», отличает от скелетов (beige/фиолет) и гигантов (багряный/камень).
static var _shared_mech_material: StandardMaterial3D


func _ready() -> void:
	super._ready()
	add_to_group(MECH_GROUP)
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	_ensure_mech_material()
	if _mesh:
		_mesh.material_override = _shared_mech_material
		_mesh_base_basis = _mesh.basis  # база для dash-наклона/стретча (DashFx)
	# Hit-feedback: короткая вспышка эмиссии ТОЛЬКО в момент попадания (как у всех
	# врагов проекта). Никакого постоянного мигания.
	damaged.connect(_on_self_damaged)
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0
	_strafe_flip_timer = strafe_flip_interval


static func _ensure_mech_material() -> void:
	if _shared_mech_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.32, 0.34, 0.4, 1.0)
		m.metallic = 0.6
		m.roughness = 0.5
		m.emission_enabled = true
		m.emission = Color(0.35, 0.7, 1.0, 1.0)
		m.emission_energy_multiplier = 0.6
		_shared_mech_material = m


# --- Телеметрия боя (поведение игрока) ---

## Сэмпл поведения башни за кадр: дистанция (бэнды), движение, курс относительно
## «прочь от меха», перекрыт ли LoS укрытием, есть ли снаряд игрока рядом.
## Накапливаем счётчики кадров — по смерти меха печатаем доли (см. _telemetry_report).
func _telemetry_sample(target: Node3D, delta: float) -> void:
	if not telemetry_enabled or target == null:
		return
	_telem_active = true
	_telem_time += delta
	_telem_frames += 1
	if _telem_tower_hp_start < 0.0 and "hp" in target:
		_telem_tower_hp_start = target.hp
	# Дистанция + бэнды.
	var to: Vector3 = target.global_position - global_position
	to.y = 0.0
	var dist: float = to.length()
	_telem_dist_sum += dist
	if dist < attack_radius_min:
		_telem_close += 1
	elif dist <= attack_radius_max:
		_telem_mid += 1
	else:
		_telem_far += 1
	# Движение башни + курс относительно направления «прочь от меха» (= to).
	var vel: Vector3 = (target as CharacterBody3D).velocity if target is CharacterBody3D else Vector3.ZERO
	vel.y = 0.0
	var speed: float = vel.length()
	_telem_speed_sum += speed
	if speed > 0.5:
		_telem_moving += 1
		var away: Vector3 = to.normalized() if dist > 0.01 else Vector3.FORWARD
		var d: float = vel.normalized().dot(away)
		if d > 0.3:
			_telem_flee += 1
		elif d < -0.3:
			_telem_approach += 1
		else:
			_telem_lateral += 1
	# Укрытие: луч от дула меха к корпусу башни сквозь слои стен/лагеря.
	var space := get_world_3d().direct_space_state
	if space != null:
		var from: Vector3 = global_position + Vector3.UP * fireball_launch_offset_y
		var to_pos: Vector3 = target.global_position + Vector3.UP * 1.5
		var q := PhysicsRayQueryParameters3D.create(from, to_pos,
			Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE | Layers.WALL_GATE_BLOCK)
		q.exclude = [self]
		if not space.intersect_ray(q).is_empty():
			_telem_cover += 1
	# Напор: снаряд игрока в радиусе реакции меха (тот же скан, что для уклонения).
	if _scan_threat() != null:
		_telem_aggro += 1


## Печать сводки боя — раз (death или despawn). Доли в % от кадров боя.
func _telemetry_report() -> void:
	if _telem_reported or not telemetry_enabled or not _telem_active or _telem_frames == 0:
		return
	_telem_reported = true
	var f: float = float(_telem_frames)
	var mv: float = float(maxi(_telem_moving, 1))
	var avg_dist: float = _telem_dist_sum / f
	var avg_speed: float = _telem_speed_sum / f
	var hp_lost: float = 0.0
	var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
	if _telem_tower_hp_start >= 0.0 and tower != null and "hp" in tower:
		hp_lost = _telem_tower_hp_start - float(tower.hp)
	print("[MechTelemetry:%s] бой %.1fс | ср.дист %.1fм" % [name, _telem_time, avg_dist])
	print("  дистанция: вплотную %.0f%% | полоса %.0f%% | далеко(кайт) %.0f%%" % [
		100.0 * _telem_close / f, 100.0 * _telem_mid / f, 100.0 * _telem_far / f])
	print("  движение: в движении %.0f%% (ср.скор %.1f) | стоит %.0f%%" % [
		100.0 * _telem_moving / f, avg_speed, 100.0 * (f - _telem_moving) / f])
	print("  курс(в движ): убегает %.0f%% | сближается %.0f%% | боком %.0f%%" % [
		100.0 * _telem_flee / mv, 100.0 * _telem_approach / mv, 100.0 * _telem_lateral / mv])
	print("  укрытие(LoS перекрыт) %.0f%% | напор(снаряд рядом) %.0f%%" % [
		100.0 * _telem_cover / f, 100.0 * _telem_aggro / f])
	print("  башня потеряла: %.0f HP" % hp_lost)
	var atk_total: int = _telem_atk_near + _telem_atk_missile + _telem_atk_field + _telem_atk_shock
	var per_min: float = 60.0 * float(atk_total) / maxf(_telem_time, 0.01)
	var gap: float = _telem_time / float(maxi(atk_total, 1))
	print("  НАГРУЗКА: атак %d (ближние %d / залпы %d / поля %d / отбросы %d) = %.1f/мин, ср.промежуток %.1fс" % [
		atk_total, _telem_atk_near, _telem_atk_missile, _telem_atk_field, _telem_atk_shock, per_min, gap])


## Целит ТОЛЬКО башню (apex vs apex). В отличие от SkeletonGiantThrower НЕ
## падаем на super (камп-скан) — лагерь игнорится полностью. Башня мертва
## (снимает себя с Damageable.GROUP) → null, мех стоит (редкий edge, despawn
## добавим позже при необходимости).
func _resolve_target() -> Node3D:
	var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
	if tower != null and is_instance_valid(tower) and Damageable.is_damageable(tower):
		return tower as Node3D
	return null


## Forced_target=Tower (от чита/спавнера) проходит фильтр — Tower не в
## TARGET_GROUP, base иначе отшибал бы её.
func _target_still_valid(target: Node3D) -> bool:
	if target.is_in_group(Tower.GROUP):
		return Damageable.is_damageable(target)
	return super._target_still_valid(target)


## Override: рваный ритм (джиттер длительности windup/cooldown) + снап-выстрел
## после уворота. База (_enter_state) уже выставила _state_timer в attack_windup/
## cooldown — правим его после. super сохраняет телеграф SkeletonArcher.
func _on_state_enter(new_state: int) -> void:
	super._on_state_enter(new_state)
	match new_state:
		AttackState.WINDUP:
			_current_attack = _pick_attack()
			if _snap_next:
				_snap_next = false
				if snap_windup > 0.0:
					_state_timer = snap_windup
					return
			if rhythm_jitter > 0.0:
				_state_timer *= randf_range(1.0 - rhythm_jitter, 1.0 + rhythm_jitter)
			# Бит-дирижёр: тянем windup минимум до конца общей паузы — ближняя атака
			# не стартует, пока «вдох» не прошёл (snap-пуниш выше это минует).
			_state_timer = maxf(_state_timer, _global_action_cd)
		AttackState.COOLDOWN:
			if rhythm_jitter > 0.0:
				_state_timer *= randf_range(1.0 - rhythm_jitter, 1.0 + rhythm_jitter)


## Override SkeletonArcher._perform_strike: вместо archer-стрелы кастуем ТОТ ЖЕ
## фаербол, что и башня (fireball.tscn + ballistic_default.tres), но с маской
## MASK_HOSTILE_PROJECTILE — она включает ACTORS (слой башни), поэтому AOE бьёт
## именно башню (башенный MASK_HAND_SLAM её не задевает — потому урон и не шёл).
## Снаряд целит в тело башни (target.global_position, y≈3), взрыв на её уровне.
func _perform_strike(target: Node3D) -> void:
	if not is_instance_valid(target):
		return
	if fireball_scene == null:
		super._perform_strike(target)
		return
	# Центр = живой телеграф (_aim_point) — совпадает с «tell»-кольцом windup'а.
	var center: Vector3 = _aim_point if _aim_point != Vector3.INF else _predicted_aim(target)
	match _current_attack:
		MechAttack.SPREAD:
			_start_spread_sequence(center)  # развёртка: снаряды по очереди (см. _tick)
		_:
			_fire_one(center)
	_telegraphed_aim = Vector3.INF
	_global_action_cd = _beat()  # общий «вдох» (короче, если башня поймана замедлением)
	_telem_atk_near += 1
	if debug_log and LogConfig.master_enabled:
		print("[EnemyMech:%s] атака %s" % [name, MechAttack.keys()[_current_attack]])


# --- Ракеты «вдогонку» (анти-кайт): дальнобойная подсистема ---

## Каждый кадр: ведём живые ракеты к башне (live-homing) и крутим ripple текущего
## залпа. САМ залп стартует не здесь, а из kite-комбо (шаг «добивание»).
func _tick_missiles(delta: float, target: Node3D) -> void:
	# 1) Ведём активные ракеты к текущей позиции башни, истёкшие — отпускаем.
	var i: int = _missiles.size() - 1
	while i >= 0:
		var e: Dictionary = _missiles[i]
		var m = e["m"]
		if not is_instance_valid(m):
			_missiles.remove_at(i)
		else:
			e["t"] = float(e["t"]) - delta
			if e["t"] <= 0.0:
				_missiles.remove_at(i)  # перестаём вести — летит к последней точке и рвётся
			elif target != null:
				# Целим в ЗЕМЛЮ под башней (y=0) — как обычные фаерболы меха. Иначе
				# y-pierce страховка фаербола (взрыв при y<=target.y) рвёт ракету
				# над мехом, как только буст роняет её ниже target.y. AOE достаёт.
				var gp: Vector3 = target.global_position
				gp.y = 0.0
				m.retarget(gp)
		i -= 1
	if not missiles_enabled or missile_count <= 0 or target == null:
		return
	# 2) Идёт залп (ripple «пуск-пуск-пуск» после телеграф-лока)?
	if _missile_pending:
		_missile_warn_timer -= delta
		if _missile_warn_timer <= 0.0:
			_missile_spawn_timer -= delta
			if _missile_spawn_timer <= 0.0:
				_launch_one_missile(target)
				_missile_salvo_index += 1
				_missile_spawn_timer = _missile_active_interval
				if _missile_salvo_index >= _missile_active_count:
					_missile_pending = false
		return
	# Сам залп НЕ триггерим здесь — его вызывает kite-комбо (Поле→Ракеты) или
	# редкий супер (_tick_missile_super).


## Старт залпа: ставим телеграф-лок на башне (warn), дальше ripple-пуск в _tick.
## Параметры опциональны (<0 = взять обычные missile_*) — супер-залп передаёт свои:
## больше ракет, кучнее пуск, свой урон и крупнее/тревожнее телеграф.
func _start_missile_salvo(target: Node3D, count: int = -1, warn: float = -1.0, interval: float = -1.0, damage: float = -1.0, is_super: bool = false) -> void:
	_missile_pending = true
	_missile_warn_timer = warn if warn >= 0.0 else missile_warn
	_missile_spawn_timer = 0.0
	_missile_salvo_index = 0
	_missile_active_count = count if count > 0 else missile_count
	_missile_active_interval = interval if interval >= 0.0 else missile_spawn_interval
	_missile_active_damage = damage if damage > 0.0 else missile_damage
	# Супер пускает ракеты из сгустка над корпусом, обычный залп — из дула.
	_missile_active_launch_y = missile_super_launch_y if is_super else fireball_launch_offset_y
	var root: Node = get_tree().current_scene
	if root != null:
		# Супер — крупнее/тревожнее телеграф (читаемый «сейчас рой в одну точку»),
		# обычный залп — компактное кольцо-лок.
		if is_super:
			AoeVisual.spawn_ground_ring(root, target.global_position, 4.5, _missile_warn_timer, shock_color)
			# Телеграф НА МЕХЕ: сгустки энергии сходятся в один шар НАД КОРПУСОМ за
			# время зарядки, держатся, пока из них вылетают ракеты (ребёнок меха —
			# следует за ним). Точка совпадает со стартом ракет супера.
			var charge := MechChargeFx.new()
			add_child(charge)
			charge.position = Vector3.UP * missile_super_launch_y
			var emit_time: float = missile_super_interval * float(missile_super_count) + 0.2
			charge.setup(_missile_warn_timer, shock_color, 3.0, emit_time)
		else:
			AoeVisual.spawn_ground_ring(root, target.global_position, 2.5, _missile_warn_timer, telegraph_lock_color)
	if debug_log and LogConfig.master_enabled:
		print("[EnemyMech:%s] %s (ракет %d, дист %.0f)" % [
			name, "СУПЕР-ЗАЛП" if is_super else "залп ракет", _missile_active_count,
			global_position.distance_to(target.global_position)])


## Один пуск: тот же fireball.tscn, но со слабым homing'ом (turn_rate/скорость
## из missile_*), хостайл-маской и регистрацией в _missiles для live-ведения.
func _launch_one_missile(target: Node3D) -> void:
	if fireball_scene == null:
		return
	var fb := fireball_scene.instantiate() as Fireball
	if fb == null:
		return
	var root: Node = _projectiles_root if is_instance_valid(_projectiles_root) else get_tree().current_scene
	root.add_child(fb)
	var launch_pos: Vector3 = global_position + Vector3.UP * _missile_active_launch_y
	var aim_ground: Vector3 = target.global_position
	aim_ground.y = 0.0  # земля под башней (см. _tick_missiles: иначе y-pierce рвёт у меха)
	fb.setup(
		launch_pos,
		aim_ground,
		ballistics.boost_duration,
		ballistics.boost_velocity_up,
		ballistics.boost_velocity_forward,
		ballistics.boost_gravity,
		ballistics.boost_drift_velocity,
		ballistics.homing_initial_speed,
		ballistics.homing_acceleration,
		missile_max_speed,
		missile_drift_deg,
		missile_turn_rate,
		_missile_active_damage,  # урон текущего залпа (обычный или супер)
		missile_radius,
		MECH_AOE_MASK,  # AOE задевает башню/лагерь/стены/гномов И скелетов (ENEMIES)
		fireball_knockback_force,
		fireball_knockback_lift,
		fireball_knockback_duration,
	)
	fb.setup_fog_pulse(10.0)
	# Flight-маска БЕЗ ENEMIES — ракета не рвётся о скелетов по пути, ведёт башню.
	fb.set_collide_in_flight(true, Layers.MASK_HOSTILE_PROJECTILE)
	Reflectable.register(fb)  # башня может отбить ракету тайминг-парированием
	_missiles.append({"m": fb, "t": missile_lifetime})


# --- Супер-залп (редкий парируемый рой ракет в одну точку) ---

## Редкий читаемый супер на боевой дистанции: длинный телеграф → плотный рой ракет
## в башню. Своя длинная перезарядка. Ракеты кучные → ловятся одним окном парирования
## (Q) и отлетают в меха = награда за риск. Не перекрывается с обычным залпом (общий
## _missile_pending) и общим битом (_global_action_cd).
func _tick_missile_super(delta: float, target: Node3D) -> void:
	_missile_super_cd = maxf(_missile_super_cd - delta, 0.0)
	if not missile_super_enabled or not missiles_enabled or target == null:
		return
	if _missile_super_cd > 0.0 or _missile_pending or _global_action_cd > 0.0:
		return
	var dist: float = global_position.distance_to(target.global_position)
	if dist < kite_min_range or dist > kite_max_range:
		return  # супер — на боевой дистанции (вблизи рулит ближняя фаза, далеко спринт)
	_missile_super_cd = missile_super_cooldown
	_global_action_cd = _beat()
	_telem_atk_missile += 1
	_start_missile_salvo(target, missile_super_count, missile_super_warn,
		missile_super_interval, missile_super_damage, true)


# --- Kite-комбо: связка Поле→Ракеты (хореография дальней дистанции) ---

## На кайт-дистанции [kite_min..kite_max] мех ведёт связку из двух битов:
##   шаг 0 — Поле (пузырь-капкан),  шаг 1 — залп Ракет по пойманному (добивание).
## Каждый шаг проходит через общий бит (вдох). После связки — пауза kite_combo_cooldown.
## Вблизи (dist < kite_min) — ближняя фаза (AIMED↔Шквал) рулит, комбо сброшено.
func _tick_kite_combo(delta: float, target: Node3D) -> void:
	_combo_cd = maxf(_combo_cd - delta, 0.0)
	if not field_enabled or target == null:
		return
	if _global_action_cd > 0.0:
		return  # общий «вдох» между битами
	# ОКНО НАКАЗАНИЯ: башня уже поймана замедлением → не перезаходим в поле, а
	# ДОЛБИМ ракетами подряд на коротком (frenzy) бите — вот это «достреливание».
	if _target_slowed:
		_global_action_cd = _beat()  # короткий бит, пока поймана
		_telem_atk_missile += 1
		_start_missile_salvo(target)
		_combo_step = 0
		_combo_cd = 0.0  # пауза связки не мешает добиванию
		return
	if _combo_step == 1:
		# Шаг 2 — добивание: залп ракет. КОММИТ — на следующем бите независимо от
		# дистанции (иначе при заходе игрока в ближний бой добивание терялось —
		# поля без залпов). Ракеты самонаводящиеся, долетят откуда угодно.
		_global_action_cd = _beat()
		_telem_atk_missile += 1
		_start_missile_salvo(target)
		_combo_step = 0
		_combo_cd = kite_combo_cooldown
		return
	# Шаг 1 — старт связки (капкан-поле): только на кайт-дистанции и после паузы.
	if _combo_cd > 0.0:
		return
	var dist: float = global_position.distance_to(target.global_position)
	if dist < kite_min_range or dist > kite_max_range:
		return  # вблизи — рулит ближняя фаза; слишком далеко — спринт догоняет
	_global_action_cd = _beat()
	_telem_atk_field += 1
	_launch_temporal_charge(target)
	_combo_step = 1


func _launch_temporal_charge(target: Node3D) -> void:
	var root: Node = get_tree().current_scene
	if root == null:
		return
	var charge := TemporalCharge.new()
	root.add_child(charge)
	var start: Vector3 = global_position + Vector3.UP * field_charge_launch_y
	charge.setup(
		start, target.global_position,
		field_charge_speed, field_charge_turn, field_charge_lifetime, field_charge_burst_radius,
		field_radius, field_duration, field_slow_factor, field_refresh, field_color,
	)
	if debug_log and LogConfig.master_enabled:
		print("[EnemyMech:%s] темпоральный заряд пущен" % name)


## Спавнит один фаербол меха в точку aim_point (тот же fireball.tscn, что и у
## башни, но с хостайл-маской + столкновение в полёте).
func _fire_one(aim_point: Vector3, radius: float = -1.0) -> void:
	var fb := fireball_scene.instantiate() as Fireball
	if fb == null:
		push_warning("EnemyMech: fireball_scene не инстанцируется как Fireball")
		return
	var use_radius: float = radius if radius > 0.0 else fireball_radius
	var root: Node = _projectiles_root if is_instance_valid(_projectiles_root) else get_tree().current_scene
	root.add_child(fb)
	var launch_pos: Vector3 = global_position + Vector3.UP * fireball_launch_offset_y
	fb.setup(
		launch_pos,
		aim_point,
		ballistics.boost_duration,
		ballistics.boost_velocity_up,
		ballistics.boost_velocity_forward,
		ballistics.boost_gravity,
		ballistics.boost_drift_velocity,
		ballistics.homing_initial_speed,
		ballistics.homing_acceleration,
		ballistics.homing_max_speed,
		ballistics.homing_drift_angle_deg,
		ballistics.homing_turn_rate,
		fireball_damage,
		use_radius,
		MECH_AOE_MASK,  # AOE задевает башню/лагерь/стены/гномов И скелетов (ENEMIES)
		fireball_knockback_force,
		fireball_knockback_lift,
		fireball_knockback_duration,
	)
	fb.setup_fog_pulse(12.0)
	# Flight-маска БЕЗ ENEMIES — снаряд не рвётся о скелетов, долетает до прицела.
	fb.set_collide_in_flight(true, Layers.MASK_HOSTILE_PROJECTILE)
	Reflectable.register(fb)  # башня может отбить фаербол тайминг-парированием


# --- Отброс/Шоквейв (анти-зажим): МГНОВЕННЫЙ панишинг, мех остаётся дальнобойным ---

## Подполз в упор (dist <= shock_trigger_range) и кулдаун готов → МГНОВЕННО бьёт
## волной: урон по башне + сильный отброс ПРОЧЬ + глушит управление. Без замаха и
## телеграфа — это наказание за зажим, а не игра в уворот. Движение меха не трогает
## (мех продолжает свой цикл) — отброс мгновенный.
func _tick_shock(delta: float, target: Node3D) -> void:
	_shock_cd = maxf(_shock_cd - delta, 0.0)
	if not shock_enabled or target == null:
		return
	if _shock_cd > 0.0:
		return
	# Горизонтальная дистанция (без Y) центр-к-центру.
	var dx: float = target.global_position.x - global_position.x
	var dz: float = target.global_position.z - global_position.z
	if dx * dx + dz * dz > shock_trigger_range * shock_trigger_range:
		return
	_shock_cd = shock_cooldown
	_telem_atk_shock += 1
	# Лёгкий «вдох» после отброса, чтобы ближняя атака не прилетела в тот же миг.
	_global_action_cd = maxf(_global_action_cd, global_attack_cooldown * 0.5)
	_burst_shock(target)


## Сама волна: VFX-кольцо + урон/отброс башни. Отброс направлен ПРОЧЬ от меха
## (от центра к башне) — отталкивает, а не притягивает.
func _burst_shock(target: Node3D) -> void:
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_expanding_ring(root, global_position, shock_radius, 0.4, shock_color, 0.4)
	var dir: Vector3 = target.global_position - global_position
	dir.y = 0.0
	if dir.length() > shock_radius:
		return
	if Damageable.is_damageable(target):
		Damageable.try_damage(target, shock_damage)
	if target.has_method("apply_knockback"):
		dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD
		target.apply_knockback(dir * shock_knockback_speed, shock_knockback_duration)


## Ближняя фаза: детерминированное чередование AIMED↔Шквал (читаемый «джеб-ритм»,
## не рандом). Вес 0 выключает приём — тогда чередования нет, идёт только включённый.
func _pick_attack() -> int:
	var use_aimed: bool = weight_aimed > 0.0
	var use_spread: bool = weight_spread > 0.0
	if use_aimed and not use_spread:
		return MechAttack.AIMED
	if use_spread and not use_aimed:
		return MechAttack.SPREAD
	if not use_aimed and not use_spread:
		return MechAttack.AIMED
	_near_toggle = not _near_toggle
	return MechAttack.AIMED if _near_toggle else MechAttack.SPREAD


## Запуск развёртки (Шквал): сохраняем точки веера и тикаем последовательность
## в _ai_step. Снаряды и наземные маркеры выпускаются по одному.
func _start_spread_sequence(center: Vector3) -> void:
	_spread_points = _fan_points(center)
	_spread_index = 0
	_spread_step_timer = 0.0
	_spread_active = _spread_points.size() > 0


## Пошаговая развёртка: каждые spread_interval сек — следующий маркер + выстрел.
## State-driven (без таймер-лямбд) — при смерти меха _ai_step просто перестаёт
## вызываться, висячих колбэков нет.
func _tick_spread_sequence(delta: float) -> void:
	_spread_step_timer -= delta
	if _spread_step_timer > 0.0:
		return
	if _spread_index >= _spread_points.size():
		_spread_active = false
		return
	var p: Vector3 = _spread_points[_spread_index]
	_spread_index += 1
	_spread_step_timer = spread_interval
	# Наземный маркер шага (авто-fade за spread_marker_duration) — видно, куда
	# сейчас прилетит; рядом летит сам снаряд.
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_ground_ring(root, p + Vector3.UP * 0.05, spread_radius, spread_marker_duration, telegraph_lock_color)
	_fire_one(p, spread_radius)


## Веер из spread_count точек, разнесённых на spread_spacing перпендикулярно
## линии «мех → центр». Боком из такого не уйти — надо искать просвет.
func _fan_points(center: Vector3) -> Array:
	var n: int = maxi(spread_count, 1)
	if n == 1:
		return [center]
	var dir: Vector3 = center - global_position
	dir.y = 0.0
	dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD
	var perp: Vector3 = dir.cross(Vector3.UP).normalized()
	var points: Array = []
	for i in range(n):
		var off: float = (float(i) - float(n - 1) * 0.5) * spread_spacing
		points.append(center + perp * off)
	return points


## Предсказанная точка удара: позиция башни + её скорость × время полёта × aim_lead.
## Общая для выстрела и живого телеграфа — поэтому маркер на земле и реальный
## импакт совпадают. aim_lead=0 → текущая позиция.
func _predicted_aim(target: Node3D) -> Vector3:
	var aim: Vector3 = target.global_position
	if aim_lead > 0.0 and target is CharacterBody3D:
		var tv: Vector3 = (target as CharacterBody3D).velocity
		tv.y = 0.0
		var dist: float = global_position.distance_to(target.global_position)
		# Время до импакта = полёт + фаза lock (точка замирает за telegraph_lock_time
		# до выстрела, башня всё это время едет — без учёта снаряд ложится позади).
		var lead_time: float = ballistics.boost_duration + dist / maxf(ballistics.homing_max_speed, 1.0) + telegraph_lock_time
		lead_time = clampf(lead_time, 0.0, aim_lead_max_time)
		var offset: Vector3 = tv * lead_time * aim_lead
		# Кап дистанции: точка не уезжает от башни дальше aim_lead_max_distance.
		if aim_lead_max_distance > 0.0 and offset.length() > aim_lead_max_distance:
			offset = offset.normalized() * aim_lead_max_distance
		aim += offset
	aim.y = 0.0  # точка на земле — и кольцо, и приземление снаряда там же
	return aim


## Живой телеграф: кольцо на земле под текущей упреждённой точкой. Двигается
## каждый кадр в WINDUP — игрок видит, как точка удара «ведёт» за движущейся
## башней (и может сорвать прицел резкой сменой курса). Размер = реальный AOE.
func _update_telegraph(target: Node3D, delta: float) -> void:
	var predicted: Vector3 = _predicted_aim(target)
	# Фаза lock — последние telegraph_lock_time секунд замаха: центр замирает.
	var locked: bool = _state_timer <= telegraph_lock_time
	if _aim_point == Vector3.INF:
		_aim_point = predicted
	elif not locked:
		# Ведение: плавный exp-decay к упреждённой точке (не снап).
		var t: float = 1.0 - exp(-telegraph_follow_rate * delta)
		_aim_point = _aim_point.lerp(predicted, t)
	# Одно кольцо-«tell» (и AIMED, и Шквал). Шквал свои поточечные маркеры рисует
	# во время развёртки — по одному перед каждым выстрелом (см. _tick_spread_sequence).
	_update_single_telegraph(locked)


## Одно кольцо-«tell» (AIMED): ведёт за упреждённой точкой, в lock замирает/пульсирует.
func _update_single_telegraph(locked: bool) -> void:
	if not is_instance_valid(_telegraph_ring):
		var root: Node = get_tree().current_scene
		if root == null:
			return
		_telegraph_ring = AoeVisual.spawn_ground_ring(root, _aim_point, fireball_radius, 0.0, telegraph_color)
		_aim_locked = false
	if not is_instance_valid(_telegraph_ring):
		return
	_telegraph_ring.global_position = _aim_point + Vector3.UP * 0.05
	if locked:
		if not _aim_locked:
			_aim_locked = true
			_set_ring_color(telegraph_lock_color)
		var mat := _telegraph_ring.material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = 2.0 + 3.0 * absf(sin(float(Time.get_ticks_msec()) * 0.02))


## Перекрашивает кольцо-телеграф (albedo + emission) — для фазы lock.
func _set_ring_color(c: Color) -> void:
	if not is_instance_valid(_telegraph_ring):
		return
	var mat := _telegraph_ring.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = c
		mat.emission = Color(c.r, c.g, c.b, 1.0)


func _hide_telegraph() -> void:
	if is_instance_valid(_telegraph_ring):
		_telegraph_ring.queue_free()
	_telegraph_ring = null
	_aim_point = Vector3.INF
	_aim_locked = false


func _exit_tree() -> void:
	_telemetry_report()  # на случай despawn'а без смерти (guard не даст дубль)
	_hide_telegraph()


## Dash-визуал евейда — ИДЕНТИЧЕН рывку игрока (общий DashFx): наклон вперёд +
## вытягивание вдоль рывка + after-image-трейл. Применяем к _mesh во время evade
## (_dash_remaining > 0); вне рывка _dash_fx→0 → dash_basis = IDENTITY (база меша).
func _process(delta: float) -> void:
	if not is_instance_valid(_mesh):
		return
	var target_fx: float = 1.0 if _dash_remaining > 0.0 else 0.0
	_dash_fx = lerpf(_dash_fx, target_fx, 1.0 - exp(-DashFx.FX_RATE * delta))
	_mesh.basis = DashFx.dash_basis(_dash_vec, _dash_fx) * _mesh_base_basis
	if _dash_fx > 0.005:
		_dash_ghost_t -= delta
		if _dash_ghost_t <= 0.0:
			_dash_ghost_t = DashFx.GHOST_INTERVAL
			DashFx.spawn_ghost(get_tree().current_scene, _mesh, _dash_vec)


# --- Presence: hit-flash + механическая смерть ---

## Металлический «лязг» при попадании: короткий flash эмиссии (HitFlash подменяет
## material_override и возвращает обратно). ТОЛЬКО on-hit, никакого постоянного
## мигания.
func _on_self_damaged(_amount: float) -> void:
	if is_instance_valid(_mesh):
		HitFlash.flash(_mesh)


## Механическая смерть: к осколкам (super) добавляем взрыв корпуса + ударную
## волну — мех «детонирует», а не просто рассыпается.
func _on_destroyed() -> void:
	_telemetry_report()  # сводка боя в консоль (поведение игрока)
	super._on_destroyed()  # прячет меш + металлические осколки (ShatterEffect)
	var root: Node = _effects_root if is_instance_valid(_effects_root) else get_tree().current_scene
	if root == null:
		return
	AoeVisual.spawn_explosion(root, global_position + Vector3.UP * 2.0, death_explosion_radius)
	AoeVisual.spawn_expanding_ring(root, global_position, death_shockwave_radius, 0.6, telegraph_lock_color, 0.3)
	# Урон по СКЕЛЕТАМ в радиусе: смерть меха детонирует и расчищает толпу вокруг
	# (награда за дуэль). Башню/гномов не трогает (DEATH_AOE_MASK = только ENEMIES).
	if death_explosion_damage > 0.0:
		AoeDamage.apply_uniform(get_tree(), global_position, death_explosion_radius,
			DEATH_AOE_MASK, death_explosion_damage, death_explosion_knockback, 0.3)
		# FAR-LOD скелеты вне broad-phase (collision_layer=0) — догоняем group-scan'ом
		# (тот же паттерн, что в Mine/Fireball._explode).
		var r_sq: float = death_explosion_radius * death_explosion_radius
		for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
			var skel := n as Skeleton
			if skel == null or skel.get_lod_level() != Skeleton.LodLevel.FAR:
				continue
			if skel.global_position.distance_squared_to(global_position) <= r_sq:
				Damageable.try_damage(skel, death_explosion_damage)


## Override SkeletonArcher._ai_step: база стоит на месте в WINDUP/COOLDOWN
## (velocity=0) — мех был лёгкой статичной целью. Теперь весь цикл (kite/windup/
## strike/cooldown) и выстрел отрабатывает база (super), а мы поверх неё в фазах
## замаха/кулдауна перекрываем нулевую скорость стрейфом — мех кружит вокруг
## башни и остаётся подвижной целью всё время атаки.
func _ai_step(delta: float) -> void:
	super._ai_step(delta)
	var target: Node3D = _resolve_target()
	_telemetry_sample(target, delta)  # дев-лог поведения игрока (для дизайна 3-го приёма)
	_target_slowed = target != null and target.has_method("is_movement_slowed") and target.is_movement_slowed()
	_global_action_cd = maxf(_global_action_cd - delta, 0.0)  # бит-дирижёр (вдох между атаками)
	# Ракеты в полёте: live-наведение + ripple текущего залпа (сам залп — из комбо).
	_tick_missiles(delta, target)
	# Отброс в упор: мгновенный панишинг (подполз — откинуло). Движение не трогает.
	_tick_shock(delta, target)
	# Спринт-преследование: дальше kite_max_range мех прибавляет в скорости
	# (масштабируем APPROACH-velocity базы) — нет «безопасной парковки» за зоной
	# связки. Близко (strafe/evade) — d мал, условие ложно; в evade — перетрётся ниже.
	if target != null and pursuit_speed_mult > 1.0:
		var d_pursuit: float = global_position.distance_to(target.global_position)
		if d_pursuit > kite_max_range:
			velocity.x *= pursuit_speed_mult
			velocity.z *= pursuit_speed_mult
	# Редкий парируемый супер-залп (рой ракет в одну точку) — приоритет над комбо
	# (ставит общий бит, комбо в этот кадр ждёт). Гейт по своему длинному кулдауну.
	_tick_missile_super(delta, target)
	# Kite-комбо (хореография дали): связка Поле→Ракеты «поймал→добил».
	_tick_kite_combo(delta, target)
	# Развёртка Шквала (если активна) — выпускает снаряды/маркеры по очереди.
	# Идёт параллельно движению (мех продолжает стрейфить/уклоняться во время неё).
	if _spread_active:
		_tick_spread_sequence(delta)
	# Живой телеграф: в WINDUP кольцо едет за упреждённой точкой; иначе скрыт.
	# До dash-return — чтобы маркер обновлялся даже когда мех уклоняется в замахе.
	if _state == AttackState.WINDUP and target != null:
		_update_telegraph(target, delta)
	else:
		_hide_telegraph()
	# РЕАКЦИЯ на игрока: летящий фаербол рядом → уклонение вбок (приоритет над
	# таймер-рывком; уже активный рывок не прерываем). Это и делает меха «умнее
	# скелетов» — он уходит с линии огня.
	_dodge_cd -= delta
	if _dash_remaining <= 0.0 and _dodge_cd <= 0.0 and dash_speed > 0.0:
		var threat: Node3D = _scan_threat()
		if threat != null:
			_start_evade(threat.global_position, target)
			_dodge_cd = dodge_cooldown
	# Активный рывок (evade) перекрывает обычное движение (kite/strafe).
	if _dash_remaining > 0.0:
		_dash_remaining -= delta
		velocity.x = _dash_vec.x
		velocity.z = _dash_vec.z
		return
	# Стрейф вокруг башни в фазах атаки (база там стоит на месте).
	if _state == AttackState.WINDUP or _state == AttackState.COOLDOWN:
		_strafe_flip_timer -= delta
		if _strafe_flip_timer <= 0.0:
			_strafe_flip_timer = strafe_flip_interval
			_strafe_dir = -_strafe_dir
		if strafe_speed > 0.0 and target != null:
			_strafe_around(target)
	# Обтекание препятствий (палатки/ресурсы) — добавляем отруливающий вектор к
	# уже выставленной velocity. Не в dash (тот ушёл ранним return'ом).
	_apply_obstacle_avoidance()


## Тангенциальное движение вокруг башни + радиальная коррекция, удерживающая
## дистанцию в полосе [attack_radius_min, attack_radius_max]. Перекрывает
## velocity, выставленную базой в 0 для WINDUP/COOLDOWN.
func _strafe_around(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	var dist: float = to_target.length()
	if dist < 0.01:
		return
	var radial: Vector3 = to_target / dist
	var tangent: Vector3 = radial.cross(Vector3.UP).normalized()
	var radial_pull: float = 0.0
	if dist > attack_radius_max:
		radial_pull = 1.0
	elif dist < attack_radius_min:
		radial_pull = -1.0
	var move: Vector3 = tangent * _strafe_dir + radial * radial_pull
	if move.length_squared() > 0.0001:
		move = move.normalized()
	velocity.x = move.x * strafe_speed
	velocity.z = move.z * strafe_speed


## Локальное обтекание: сфера-запрос по AVOID_MASK (палатки/ресурсы), суммируем
## отталкивание от каждого в радиусе и добавляем к velocity — мех огибает их,
## а не таранит. Явный distance-check после intersect_shape (Godot 4.6 подмешивает
## AABB-broadphase вне сферы — см. гайдлайны проекта).
func _apply_obstacle_avoidance() -> void:
	if avoid_radius <= 0.0 or avoid_strength <= 0.0:
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = avoid_radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis(), global_position)
	q.collision_mask = AVOID_MASK
	q.collide_with_bodies = true
	var results: Array = space.intersect_shape(q, 16)
	var here: Vector3 = global_position
	var push: Vector3 = Vector3.ZERO
	for r in results:
		var col = r.collider
		if not (col is Node3D):
			continue
		var to_self: Vector3 = here - (col as Node3D).global_position
		to_self.y = 0.0
		var d: float = to_self.length()
		if d > avoid_radius or d < 0.001:
			continue
		var falloff: float = (avoid_radius - d) / avoid_radius
		push += (to_self / d) * falloff
	if push.length_squared() > 0.0001:
		push = push.normalized()
		velocity.x += push.x * move_speed * avoid_strength
		velocity.z += push.z * move_speed * avoid_strength


## Ближайший фаербол игрока (группа player_projectile) в радиусе
## dodge_detect_radius (горизонтально). null если угроз нет. Фаербол homing'ит
## в ЗАФИКСИРОВАННУЮ точку каста (не трекает меха), поэтому уклонение реально
## уводит с траектории.
func _scan_threat() -> Node3D:
	if dodge_detect_radius <= 0.0:
		return null
	var here: Vector3 = global_position
	var best: Node3D = null
	var best_d_sq: float = dodge_detect_radius * dodge_detect_radius
	for n in get_tree().get_nodes_in_group(PLAYER_PROJECTILE_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var dx: float = node.global_position.x - here.x
		var dz: float = node.global_position.z - here.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < best_d_sq:
			best_d_sq = d_sq
			best = node
	return best


## Evade-рывок: уход с линии угрозы (перпендикуляр к threat→mech) + чуть прочь
## от снаряда. Сторону перпендикуляра выбираем так, чтобы не нырнуть под башню.
## Реюзает dash-механизм (_dash_vec/_dash_remaining).
func _start_evade(threat_pos: Vector3, target: Node3D) -> void:
	var away: Vector3 = global_position - threat_pos
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	away = away.normalized()
	var perp: Vector3 = away.cross(Vector3.UP).normalized()
	if target != null:
		var to_tower: Vector3 = target.global_position - global_position
		to_tower.y = 0.0
		if perp.dot(to_tower) > 0.0:
			perp = -perp  # не уклоняться в сторону башни
	var dir: Vector3 = (perp * 0.8 + away * 0.4)
	if dir.length_squared() < 0.0001:
		dir = perp
	dir = dir.normalized()
	_dash_vec = dir * dash_speed
	_dash_remaining = dash_duration
	_dash_ghost_t = 0.0  # первый призрак трейла — сразу (как у башни)
	# Пуниш: огрызаемся после уворота. Снап следующего windup'а + срез остатка
	# cooldown'а (если сейчас в нём) → контратака почти сразу за уклонением.
	_snap_next = true
	if _state == AttackState.COOLDOWN and punish_cooldown > 0.0:
		_state_timer = minf(_state_timer, punish_cooldown)
	if debug_log and LogConfig.master_enabled:
		print("[EnemyMech:%s] уклонение + пуниш" % name)
