class_name Gnome
extends CharacterBody3D
## Гном — обитатель лагеря. По 2 на палатку. Сам ищет ресурсы патрулём,
## находит глазами и сам носит ресурс челноком. По сигналу кампа →
## возвращается в свою палатку.
##
## FSM сбора:
##   SEARCHING — гном ищет ближайший годный pile во ВСЁМ мире (через статический
##     _pile_grid, без cap'а дистанции). Никакого random-wander: зоны ресурсов
##     статичны, fog-of-war здесь не нужен — гном идёт прямо к ближайшему.
##     Если все pile-ы пусты или нацелены другими (Camp.is_pile_claimed) → IDLE.
##   COMMUTING_TO_PILE → COMMUTING_TO_BASE → ... пока закреплённая куча валидна.
##     Позиция pile читается каждый кадр — если бревно укатили рукой, гном
##     следит за ним до тех пор пока не возьмёт или pile не уничтожат/занимают.
##     На pile_lost → SEARCHING → новый ближайший.
##   IDLE_NEAR_BASE — pile-ов нет / все нацелены. Гном слоняется возле anchor'а,
##     раз в idle_pile_rescan_sec пытается найти новый pile (чтобы не залипать
##     если кто-то освободил клейм или истёк pile).
##
## Прочие состояния:
##   IN_TENT — приклеен к палатке, скрыт. Состояние по умолчанию (караван).
##   RETURNING_TO_TENT — лагерь сворачивается, гном идёт к своей палатке.
##                       Несомый ресурс роняется по дороге (queue_free).
##   IDLE_NEAR_BASE — куч на карте нет вообще, гном ошивается возле anchor'а.
##
## Связь с лагерем: setup(camp, home_tent). Гном не сканирует tower/спавнер —
## всё через camp. Кучи между гномами не делятся через broadcast: гном видит
## только свою vision-зону и сам решает, куда бежать.
##
## Цель скелетов: пока гном НЕ IN_TENT, он зарегистрирован в группе
## skeleton_target — скелеты находят его глазами в их vision_radius.
## При переходе в IN_TENT/RETURNING_TO_TENT он из группы выходит. На смерти —
## destroyed signal, Camp вычищает себя из массива _gnomes по сигналу.

signal damaged(amount: float)
signal destroyed

const SKELETON_TARGET_GROUP := &"skeleton_target"
## Группа всех гномов (мирные + DefenderGnome'ы наследуются). Используется
## для cross-cutting'а через контракт «это гном» без `is Gnome` — skeleton'у
## приоритет цели по гномам, xp_orb'у — резолв camp'а через `body.get_camp()`.
const GNOME_GROUP := &"gnome"

enum State {
	IN_TENT,
	SEARCHING,
	COMMUTING_TO_PILE,
	COMMUTING_TO_BASE,
	IDLE_NEAR_BASE,
	RETURNING_TO_TENT,
	## «Бездомный» гном — палатки нет (своя торн_оффнута / разрушена,
	## другие тоже не доступны). Идёт за башней с боковым offset'ом, чтобы
	## не сливаться кучей. В этом state'е всегда видим, в группе skeleton_target.
	## Активируется через `enter_following_caravan()` из CampPart.eject_in_tent
	## и Camp._reassign_orphan_gnomes когда новый home не найден.
	FOLLOWING_CARAVAN,
	## Гном-собиратель идёт к XpOrb (этап 49) — увидел орб в vision_radius
	## во время SEARCHING/IDLE_NEAR_BASE. На касании Area3D орба сам активирует
	## магнит, орб улетает к Camp.deploy_anchor. Гном после этого возвращается
	## в SEARCHING. Если орб коснулся другой союзник раньше или истёк
	## lifetime — `_assigned_orb` инвалидируется, переход в SEARCHING.
	COMMUTING_TO_ORB,
}

@export_group("Stats")
@export var hp: float = 20.0
## Замедление knockback-скорости в секунду — пока knockback_timer > 0,
## AI не управляет скоростью, она затухает к нулю.
@export var knockback_friction: float = 6.0

@export_group("Movement")
@export var move_speed: float = 1.6
@export var gravity: float = 20.0

@export_group("Behaviour")
## Дальность зрения гнома для XP-орбов (см. _scan_orb). Pile-ам vision_radius
## не нужен — гном ищет ближайший глобально, без cap'а. Орбы же исчезают за
## ~60с, и собирать их «всей картой» было бы перебором.
@export var vision_radius: float = 10.0
## Радиус «ошивания» возле anchor'а, когда на карте не осталось куч.
@export var idle_radius: float = 4.0
## Дистанция до кучи, на которой считаем «дошёл — можно брать».
@export var pickup_distance: float = 0.8
## Дистанция до anchor'а лагеря для сдачи ресурса.
@export var deposit_distance: float = 1.2
## Дистанция до палатки, на которой гном «дома».
@export var home_distance: float = 0.8
## Дистанция до wander-точки, чтобы выбрать новую (или после прибытия).
@export var wander_arrival: float = 0.6
## Половина стороны квадратной карты от центра (0,0). Idle wander-точки
## клампятся в этих пределах — на случай, если deploy_anchor близко к краю
## карты. Должно совпадать со Skeleton.wander_map_half_extent.
@export var wander_map_half_extent: float = 145.0
## Пауза между rescan'ами pile-ов в IDLE_NEAR_BASE. Если все pile-ы были
## claim'нуты другими, гном уходит в idle; периодический rescan ловит момент
## когда кто-то освободил pile (доставил, забрал последний unit). Без этого
## гном залипал в idle до следующего deploy'я.
@export var idle_pile_rescan_sec: float = 1.5

@export_group("Caravan follow (для бездомных гномов)")
## Sprint-cap для FOLLOWING_CARAVAN: чем дальше гном от своего слота в
## цепочке, тем быстрее бежит, lerp от move_speed (в слоте) до этого значения
## (отстал на caravan_full_sprint_distance метров). Tower бежит на 8 m/s —
## sprint должен быть выше, иначе отрыв не сократить. 9.0 даёт +1 m/s на
## сокращение дистанции при максимальном отставании.
@export var caravan_sprint_speed: float = 9.0
## Дистанция отставания от chain-слота, на которой гном выходит на полный
## sprint. Меньше — резче переход walk↔run; больше — плавнее (гном дольше
## идёт в «среднем» темпе). 5м = 2× part_gap, разумный диапазон.
@export var caravan_full_sprint_distance: float = 5.0
@export_group("")

@export_group("Tent eject (вылет из палатки на улицу)")
## Окно неуязвимости после выхода из палатки. Гном вылетел оглушённым,
## пока не успел сориентироваться — скелеты не наносят ему damage. По
## истечении времени take_damage снова работает как обычно.
@export var post_eject_invulnerability: float = 2.0
## Скорость scatter'а в случайном направлении при выходе. AI выключен на
## post_eject_scatter_duration секунд (через _knockback) — гном летит по
## инерции, затухает по knockback_friction, потом FSM ведёт его за башней.
@export var post_eject_scatter_speed: float = 5.0
@export var post_eject_scatter_duration: float = 0.5
@export_group("")

@export_group("Visual")
@export var gnome_color: Color = Color(0.7, 0.45, 0.25)
@export var carry_color: Color = Color(0.4, 0.75, 0.3)
@export var carry_visual_size: Vector3 = Vector3(0.3, 0.3, 0.3)

@export_group("Shatter (рассыпание на смерти)")
@export var shatter_fragment_count: int = 6
@export var shatter_lifetime: float = 1.5
## Куда складывать фрагменты. Пусто → fallback на current_scene. Лагерь как
## parent НЕ подходит: при свёртке/смерти кампа дети-фрагменты были бы
## уничтожены вместе с ним; current_scene их переживает.
@export_node_path("Node") var effects_root_path: NodePath
@export_group("")

@export_group("LOD (масштабирование на 100+ гномов)")
## Дистанция до точки интереса камеры (CameraRig), дальше которой гном
## уходит в холодный режим: skip move_and_slide и гравитации, позиция
## обновляется через global_position += velocity * delta. AI продолжает
## работать (дёшево). Это даёт основной win на 126+ гномах при удалённой
## камере от поселений.
@export var lod_far_distance: float = 50.0
## Период переоценки LOD-уровня (с). Distance-чек 100+ гномов на каждом
## физкадре сам по себе нагрузка.
@export var lod_check_interval: float = 0.5
## Угол полу-cone'а «впереди камеры». Гном вне cone'а (за камерой или
## сильно сбоку) форсируется в FAR-режим независимо от расстояния — игрок
## его не видит, симулировать его дёшево (cold-mode без move_and_slide).
## Симметрично frustum-override Skeleton'а. 60° = 120° cone, покрывает
## горизонтальный FOV ~95° (FOV=70 + 16:9) с запасом. До 90° — override
## выключен (всё в полусфере перед камерой считается «видимым»).
@export_range(30.0, 90.0) var lod_offscreen_half_angle_deg: float = 60.0
@export_group("")

@export_group("")
@export var debug_log: bool = true

var _camp: Camp
var _home_tent: Node3D
## Логирование переходов через сеттер — все присваивания `_state = X`
## внутри файла попадают сюда автоматически, не нужно искать каждое место.
## Фронт-триггер: лог только при реальной смене значения, чтобы избежать
## спама при многократном `_state = current_state` подряд.
var _state: State = State.IN_TENT:
	set(value):
		if _state == value:
			return
		if debug_log and LogConfig.master_enabled:
			print("[Gnome:%s] state %s → %s" % [name, State.keys()[_state], State.keys()[value]])
		_state = value
var _assigned_pile: ResourcePile = null
## Тип ресурса, который сейчас несёт гном. Заполняется в _pickup_carry из
## _assigned_pile.resource_type, сбрасывается в _drop_carry. Хранить
## отдельно (а не читать с pile в момент сдачи) обязательно: pile может
## сделать queue_free сразу после take_one (units==0), и к моменту прихода
## к anchor'у его уже не существует. -1 = не несёт.
var _carry_type: int = -1
## Орб, к которому гном сейчас бежит в COMMUTING_TO_ORB. Untyped, чтобы не
## упасть на freed-инстансе (между сканом и тиком орб может улетететь к
## Camp'у и queue_free); проверка через is_instance_valid + as XpOrb.
var _assigned_orb: XpOrb = null
var _wander_target: Vector3 = Vector3.INF
## Время (Time.get_ticks_msec) следующего rescan'а pile-ов в IDLE_NEAR_BASE.
## 0 = пересканировать сразу. Сбрасывается на enter в idle и после каждого
## rescan'а. См. idle_pile_rescan_sec.
var _idle_pile_rescan_msec: int = 0
var _carry_visual: MeshInstance3D = null
var _knockback := KnockbackState.new()
## Время (Time.get_ticks_msec) до которого гном неуязвим после eject'а из
## палатки. До этого момента take_damage возвращает рано. 0 = выключено.
var _post_eject_invulnerable_until_msec: int = 0
## Per-гном random смещение в цепочке-каравана: x = side (perpendicular),
## y = forward. Каждое в [−1, 1], разворачивается Camp'ом в реальные метры
## через gnome_chain_jitter / gnome_chain_gap_variance. Генерируется
## однократно на enter_following_caravan — стабильное «индивидуальное место»
## гнома в строю, не дрожит между кадрами.
var _caravan_chain_offset: Vector2 = Vector2.ZERO
## Time.get_ticks_msec() следующей попытки заселиться в палатку. Бездомный
## гном в FOLLOWING_CARAVAN периодически (раз в ~1-1.5с) спрашивает Camp,
## есть ли свободное место в живых палатках. Если есть — переключается в
## RETURNING_TO_TENT с новым home_tent.
var _next_tent_vacancy_check_msec: int = 0
var _dying: bool = false
var _effects_root: Node = null
var _lod_far: bool = false
var _lod_check_timer: float = 0.0
## Прекомпьют cos(half-angle) для frustum-override. Дешевле, чем deg_to_rad+cos
## на каждом LOD-чеке (раз в 0.5с × 126 гномов).
var _lod_offscreen_cos: float = 0.5
## Hysteresis-cos: чтобы выйти из frustum-FAR обратно в hot-mode, нужно зайти
## в cone глубже на ~5° от границы. Без этого гном на границе угла дёргается
## FAR↔NEAR каждые lod_check_interval (0.5с) с переключением физ-режима.
var _lod_offscreen_cos_exit: float = 0.4

@onready var _mesh: MeshInstance3D = $MeshInstance3D
## NavAgent для path-following вокруг палисадов / палаток / башни. Все
## методы движения (`_move_toward_xz`) идут через [_resolve_path_step] —
## он возвращает либо следующий waypoint пути, либо сам goal если nav-агент
## не активен или цель уже достигнута. Если ноды нет (наследник не привязал)
## — pathfinding отключён, гном идёт прямо.
@onready var _nav_agent: NavigationAgent3D = $NavigationAgent3D if has_node("NavigationAgent3D") else null
## Кэш последнего set_target'а — чтобы не сбрасывать path-расчёт каждым
## кадром на тот же target (NavigationAgent делает re-path под капотом
## при set_target_position).
var _nav_last_target: Vector3 = Vector3.INF
## Throttle на set_target_position. Цель может «дрожать» (например anchor
## каравана пересчитывается каждый кадр) — без throttle'а path-расчёт
## молотит на пустом месте.
var _nav_set_throttle: float = 0.0
const NAV_SET_INTERVAL: float = 0.2
## Если цель в этом радиусе от текущей позиции — pathfinding выключен,
## идём прямо. Дёрганья на близких целях не нужны.
const NAV_DIRECT_RADIUS: float = 1.5

## Размер cell'а в spatial-grid'е куч ресурсов. Сейчас grid используется
## глобальным поиском _find_nearest_pile (полный обход keys), но cell-структура
## оставлена под будущий spiral-search и под старый код _pile_cell.
const PILE_GRID_CELL_SIZE: float = 10.0
## Период обновления pile-grid'а (с). Кучи статичны (RigidBody freeze=false,
## но обычно лежат, gnome их таскает по одной), позиции почти не меняются —
## редкий refresh ок. С 0.5с stale-боль = max 1 кадр промаха цели.
const PILE_GRID_REFRESH_INTERVAL: float = 0.5

## Spatial grid куч: { Vector2i(cell_x, cell_z) → Array of [Vector3 pos,
## ResourcePile node] }. Один глобальный snapshot, читается всеми гномами,
## refresh ленивый раз в PILE_GRID_REFRESH_INTERVAL.
static var _pile_grid: Dictionary = {}
static var _pile_grid_time: float = -1000.0


## Cell-координаты по плоскости XZ.
static func _pile_cell(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / PILE_GRID_CELL_SIZE)),
		int(floor(pos.z / PILE_GRID_CELL_SIZE)),
	)


## Лениво пересоздаёт _pile_grid из group resource_pile. Зовётся в начале
## _find_nearest_pile. Один pass по группе раз в PILE_GRID_REFRESH_INTERVAL
## глобально (общий для всех гномов).
static func _maybe_refresh_pile_grid(tree: SceneTree) -> void:
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - _pile_grid_time < PILE_GRID_REFRESH_INTERVAL:
		return
	_pile_grid_time = now
	_pile_grid.clear()
	for n in tree.get_nodes_in_group(ResourcePile.GROUP):
		if not is_instance_valid(n):
			continue
		var rp := n as ResourcePile
		if rp == null or rp.units <= 0 or rp.freeze:
			continue
		var cell := _pile_cell(rp.global_position)
		if not _pile_grid.has(cell):
			_pile_grid[cell] = []
		var entries: Array = _pile_grid[cell]
		entries.append([rp.global_position, rp])


## Камп вызывает после спавна гнома. До этого момента — без активной логики.
func setup(camp: Camp, home_tent: Node3D) -> void:
	_camp = camp
	_home_tent = home_tent
	_apply_visual()
	_enter_in_tent()


func _ready() -> void:
	# До setup просто стоим. Без камп-ссылки FSM не имеет смысла.
	visible = false
	Damageable.register(self)
	Pushable.register(self)
	add_to_group(GNOME_GROUP)
	_knockback.friction = knockback_friction
	# _effects_root: явный path → ноду; пустой/неразрешённый → fallback на
	# current_scene. Камп родитель нам НЕ подходит — он мог бы освободиться
	# до окончания shatter-таймера, и фрагменты испарились бы.
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	damaged.connect(func(amount: float) -> void: EventBus.gnome_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.gnome_destroyed.emit(self))
	# Фазовый сдвиг LOD-чека: 126+ гномов не должны пересчитывать дистанцию
	# до камеры одним кадром. Размазываем по 0..lod_check_interval.
	_lod_check_timer = randf() * lod_check_interval
	# Прекомпьют cos(half-angle) для frustum-override + hysteresis (5°
	# шире на выходе) — без него гном на границе cone'а флипал FAR↔NEAR
	# каждые 0.5с с пересчётом физ-режима.
	_lod_offscreen_cos = cos(deg_to_rad(lod_offscreen_half_angle_deg))
	_lod_offscreen_cos_exit = cos(deg_to_rad(lod_offscreen_half_angle_deg + 5.0))
	# Реакция на смену приоритета сбора: гном в COMMUTING_TO_PILE бросает
	# текущий pile и ищет заново под новый план. Несущие (COMMUTING_TO_BASE)
	# донесут — кредит важнее чем мгновенная переоценка. Defender'ы тоже
	# подписываются (extends Gnome), но их state'ы не COMMUTING_TO_PILE,
	# фильтр в обработчике ничего не делает.
	EventBus.collection_priority_changed.connect(_on_collection_priority_changed)
	# NavMesh re-bake → сбрасываем кэш `_nav_last_target`, иначе set_target_position
	# с тем же goal'ом игнорируется и старый невалидный path остаётся.
	EventBus.navmesh_baked.connect(_on_navmesh_baked)
	# Явная отписка на free. EventBus — autoload (жив всю сессию), без
	# disconnect фантомные Callable'ы накапливались бы до GC; на 100+ гномах
	# за матч это сотни мёртвых подписок.
	tree_exiting.connect(_disconnect_eventbus)


func _on_navmesh_baked() -> void:
	# Sentinel-сброс — на следующем _resolve_path_step set_target_position
	# уйдёт заново и NavAgent пересчитает путь по обновлённому navmesh'у.
	_nav_last_target = Vector3.INF


## Очистка глобальных подписок EventBus. Подклассы override'ят и зовут super,
## чтобы добавить отписки от своих сигналов.
func _disconnect_eventbus() -> void:
	if EventBus.collection_priority_changed.is_connected(_on_collection_priority_changed):
		EventBus.collection_priority_changed.disconnect(_on_collection_priority_changed)
	if EventBus.navmesh_baked.is_connected(_on_navmesh_baked):
		EventBus.navmesh_baked.disconnect(_on_navmesh_baked)


func _apply_visual() -> void:
	if not _mesh:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = gnome_color
	_mesh.material_override = mat


# --- API для Camp ---

## Лагерь развернулся — выходим в фазу поиска.
func enter_deployed() -> void:
	visible = true
	_assigned_pile = null
	_wander_target = Vector3.INF
	_state = State.SEARCHING
	# Снаружи и виден → цель скелетов.
	add_to_group(SKELETON_TARGET_GROUP)
	if debug_log and LogConfig.master_enabled:
		print("[Gnome:%s] вышел из палатки" % name)


## Палатка-дом получила удар (отрыв от каравана, удар о землю, разрушение).
## Гном выходит из IN_TENT БЕЗ damage — целая палатка защитила его при ударе,
## а в момент разрушения «вытряхнула» наружу.
##
## После вылета:
## - окно неуязвимости `post_eject_invulnerability` секунд (take_damage гейтится),
## - случайный horizontal scatter-импульс через apply_push (AI off на
##   `post_eject_scatter_duration` — гном по инерции разлетается),
## - state → FOLLOWING_CARAVAN: идёт за башней независимо от того, остались
##   ли в кампе живые палатки. Кикнутый из дома гном больше домой не лезет.
func eject_from_tent() -> void:
	if _state != State.IN_TENT or _dying:
		return
	# Меняем state ДО любых side-effects, чтобы _physics_process в IN_TENT-ветке
	# не приклеил нас обратно к палатке на следующем тике. enter_following_caravan
	# ниже выставит итоговый FOLLOWING_CARAVAN.
	_state = State.SEARCHING
	visible = true
	_assigned_pile = null
	_wander_target = Vector3.INF
	# Неуязвимость на 2с — пока не отлетит и не сориентируется.
	_post_eject_invulnerable_until_msec = Time.get_ticks_msec() + int(post_eject_invulnerability * 1000.0)
	# Random scatter в горизонтальной плоскости. Через apply_push, чтобы AI
	# выключился на длительность knockback'а (иначе FSM сразу же начнёт
	# править velocity к башне и scatter не успеет визуально проиграться).
	var scatter_dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if scatter_dir.length_squared() > 0.0001:
		scatter_dir = scatter_dir.normalized()
	else:
		scatter_dir = Vector3.RIGHT
	apply_push(scatter_dir * post_eject_scatter_speed, post_eject_scatter_duration)
	# Идём за башней. _home_tent больше не нужен — кикнутый из дома гном
	# к другим палаткам не возвращается.
	_home_tent = null
	enter_following_caravan()


## Гном без дома (выкинут из палатки или его палатка разрушена). Встраивается
## в общую цепочку каравана за палатками: Camp.register_caravan_follower
## добавляет его в хвост, а в _tick_following_caravan гном идёт к
## chain-слоту, рассчитанному Camp.get_chain_target_for_follower.
## Используется из eject_from_tent и Camp._reassign_orphan_gnomes.
func enter_following_caravan() -> void:
	if _dying:
		return
	# Идемпотентно: если уже в FOLLOWING_CARAVAN, не перерандомиваем
	# chain-offset и не дёргаем register повторно. Иначе пакет вызовов
	# request_return → enter_following_caravan на уже-follower'ах визуально
	# дёргает позиции в строю.
	if _state == State.FOLLOWING_CARAVAN:
		return
	visible = true
	_assigned_pile = null
	_wander_target = Vector3.INF
	add_to_group(SKELETON_TARGET_GROUP)
	# Random per-гном смещение в строю: чтоб не выстраивались ровной очередью.
	# Camp читает через get_caravan_chain_offset и масштабирует в метры.
	_caravan_chain_offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	_state = State.FOLLOWING_CARAVAN
	if _camp != null:
		_camp.register_caravan_follower(self)
	if debug_log and LogConfig.master_enabled:
		print("[Gnome:%s] идёт за караваном (бездомный)" % name)


## True если гном в строю каравана (FOLLOWING_CARAVAN). Camp проверяет на
## _all_gnomes_home для финализации pack: «дома» теперь = IN_TENT либо
## встроился в колонну.
func is_following_caravan() -> bool:
	return _state == State.FOLLOWING_CARAVAN


## Геттер для Camp.get_chain_target_for_follower. Per-гном random смещение
## (стабильно после enter_following_caravan) — формация выглядит как толпа,
## а не очередь.
func get_caravan_chain_offset() -> Vector2:
	return _caravan_chain_offset


## Бездомный гном нашёл свободное место в палатке (Camp.find_tent_with_vacancy_for).
## Снимаемся из caravan-цепочки и переходим в RETURNING_TO_TENT — _tick_returning
## побежит к новому home'у sprint-скоростью. По прибытии _enter_in_tent
## переведёт нас в IN_TENT (palatка-щит, неуязвимость).
func _claim_tent_as_home(tent: CampPart) -> void:
	_home_tent = tent
	_state = State.RETURNING_TO_TENT
	if _camp != null:
		_camp.unregister_caravan_follower(self)
	if debug_log and LogConfig.master_enabled:
		print("[Gnome:%s] нашёл свободное место в %s, идёт заселяться" % [name, tent.name])


## Лагерь свёртывается — возвращаемся в палатку. Roняем то, что несли.
##
## Геймдизайнерское правило (2026-05-06): палатка — безопасное место для
## гномов-собирателей, поэтому при свёртке они идут домой (RETURNING_TO_TENT
## → _enter_in_tent → IN_TENT, скрыты, неуязвимы). Бездомные (без `_home_tent`)
## идут в общую колонну за караваном — им просто некуда возвращаться.
##
## Защитники переопределяют `request_return` (см. DefenderGnome.request_return)
## и сразу уходят в FOLLOWING_CARAVAN — палатка для них не «безопасное место»,
## а склад, в который они не садятся принципиально.
##
## Pack timeout (Camp.pack_timeout=12с) защищает от зависания: если гном застрял
## далеко от палатки, Camp force-finalize'ит свёртку и trigger'ит караван.
func request_return() -> void:
	if _state == State.IN_TENT:
		return
	_drop_carry()
	_assigned_pile = null
	if is_instance_valid(_home_tent):
		# Снимаемся из caravan-цепочки если уже были там (бездомный) —
		# теперь у нас есть валидная палатка-цель. _tick_returning сделает
		# sprint к home, _enter_in_tent посадит внутрь.
		if _camp != null and _state == State.FOLLOWING_CARAVAN:
			_camp.unregister_caravan_follower(self)
		_state = State.RETURNING_TO_TENT
	else:
		# Бездомный — некуда возвращаться, идём в колонну за караваном.
		enter_following_caravan()


func is_home() -> bool:
	return _state == State.IN_TENT


## Геттер home_tent — Camp использует для поиска гномов, чья палатка
## была уничтожена (см. Camp._reassign_orphan_gnomes).
func get_home_tent() -> Node3D:
	return _home_tent


## Геттер ссылки на родительский Camp. Используется `XpOrb._resolve_camp_from`
## когда орб коснулся гнома — нужно понять, к какому лагерю отправлять XP.
func get_camp() -> Camp:
	return _camp


## Переназначить home_tent. Camp вызывает после _on_part_destroyed для
## осиротевших гномов: вместо мёртвого инстанса палатки получают новую
## (ближайшую живую). Это позволяет IN_TENT-приклейке (физпроцесс) и
## RETURNING_TO_TENT-логике корректно работать.
func set_home_tent(new_tent: Node3D) -> void:
	_home_tent = new_tent


## Камп использует, чтобы понять «занята ли куча» — другие гномы её пропустят.
## Возвращает null, если гном не «привязан» к куче сейчас.
func get_assigned_pile() -> ResourcePile:
	if _state != State.COMMUTING_TO_PILE and _state != State.COMMUTING_TO_BASE:
		return null
	if not is_instance_valid(_assigned_pile):
		return null
	return _assigned_pile


# --- Damageable / Pushable ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	# Целая палатка щит: пока IN_TENT, никакой damage не проходит — ни от Slam'а
	# по AOE Damageable, ни от случайных скелетов. Уязвимость включается на
	# выходе через eject_from_tent / enter_deployed (там state ≠ IN_TENT).
	if _state == State.IN_TENT:
		return
	# Окно «оглушения» сразу после вылета из палатки: пара секунд гном бежит
	# к каравану безнаказанно, чтобы не быть мгновенно срезанным окружившими
	# скелетами в момент разрушения палатки.
	if Time.get_ticks_msec() < _post_eject_invulnerable_until_msec:
		return
	hp -= amount
	damaged.emit(amount)
	HitFlash.flash(_mesh)
	if hp <= 0.0:
		_dying = true
		# Снимаем флаг цели заранее: queue_free отрабатывает только в конце кадра,
		# и без этого скелет ещё успел бы взять умирающего гнома в целеуказание
		# в текущем тике (get_nodes_in_group видит queued-инстансы до фактической смерти).
		remove_from_group(SKELETON_TARGET_GROUP)
		# Если гном был в цепочке-каравана — вычищаем его слот, чтобы Camp
		# не итерировал invalid ссылку и не считал её леидером для следующих.
		if _camp != null:
			_camp.unregister_caravan_follower(self)
		# Прячем тело и спавним фрагменты — те живут в _effects_root, переживают
		# queue_free самого гнома (queue_free ниже прибьёт его в конце кадра).
		if _mesh:
			_mesh.visible = false
		if _effects_root:
			ShatterEffect.spawn(_effects_root, global_position, gnome_color,
				shatter_fragment_count, shatter_lifetime)
		destroyed.emit()
		queue_free()


## Pushable-контракт: knockback, на длительность которого AI отключён,
## и горизонтальная скорость затухает к нулю по knockback_friction.
func apply_push(velocity_change: Vector3, duration: float) -> void:
	if _state == State.IN_TENT:
		# В палатке — позиция приклеена, импульс не имеет смысла.
		return
	velocity = KnockbackState.compose(velocity, velocity_change)
	_knockback.start(duration)


# --- Цикл ---

func _physics_process(delta: float) -> void:
	if _camp == null:
		return

	if _state == State.IN_TENT:
		# Приклеены к палатке — позиция ведомая, физикой не трогаем.
		if is_instance_valid(_home_tent):
			global_position = _home_tent.global_position
		return

	# LOD-чек раз в lod_check_interval. Дальше lod_far_distance от camera-rig
	# уходим в холодный режим: skip move_and_slide и гравитации, position
	# обновляется напрямую. AI продолжает работать.
	_lod_check_timer -= delta
	if _lod_check_timer <= 0.0:
		_update_lod()
		_lod_check_timer = lod_check_interval

	# Гравитация — только в hot mode. На FAR-mode пол плоский, Y не меняется.
	if not _lod_far:
		if not is_on_floor():
			velocity.y -= gravity * delta
		else:
			velocity.y = 0.0

	_knockback.tick(delta)
	if _knockback.is_active():
		# Под knockback'ом — AI заглушен, скорость затухает по trение-coeff.
		velocity = _knockback.apply_friction(velocity, delta)
	else:
		_active_tick(delta)

	if _lod_far:
		# Cold-mode: position += velocity без физики/коллизий. Гном на
		# collision_layer=0, ни с кем не сталкивается даже в hot — поэтому
		# визуально неотличимо от move_and_slide на плоской карте.
		global_position.x += velocity.x * delta
		global_position.z += velocity.z * delta
	else:
		move_and_slide()


## Виртуальный hook — подклассы переопределяют свою активную AI-логику.
## Базовая реализация — собиратель: match _state → _tick_searching/...
## DefenderGnome переопределяет на «стой и стреляй».
func _active_tick(_delta: float) -> void:
	match _state:
		State.SEARCHING:
			_tick_searching()
		State.COMMUTING_TO_PILE:
			_tick_commuting_to_pile()
		State.COMMUTING_TO_BASE:
			_tick_commuting_to_base()
		State.COMMUTING_TO_ORB:
			_tick_commuting_to_orb()
		State.IDLE_NEAR_BASE:
			_tick_idle_near_base()
		State.RETURNING_TO_TENT:
			_tick_returning()
		State.FOLLOWING_CARAVAN:
			_tick_following_caravan()


## Бездомный гном — идёт в свой слот цепочки каравана за палатками. Camp
## считает target по той же формуле, что и для палаток в _update_caravan_follow:
## leader_pos − (leader_pos − me).normalized() × part_gap. Каждый follower
## слотится за предыдущим follower'ом (или за последней активной палаткой,
## или за башней — если в кампе никого больше нет).
##
## Скорость не фиксированная: чем дальше гном от слота, тем быстрее идёт
## (lerp move_speed → caravan_sprint_speed по дистанции). В слоте — walk;
## оторвался караван — sprint. Tower бегает на 8 m/s, гном в слоте — на 1.6,
## и без catch-up'а догнать невозможно. Это естественный аналог «пешее
## сопровождение бежит когда отстало», без фиксированной overall-ускоренной
## скорости (которая делала бы гномов дешёвыми и в спокойном состоянии).
##
## Arrival 0.4м — в слоте стоим, чтобы не дрожать поверх target'а. Меньше
## arrival для палатки (там лерп Camp'а гладкий), но гном-walker с дискретной
## скоростью легко перепрыгнет ноль и задёргает velocity.
func _tick_following_caravan() -> void:
	if _camp == null:
		velocity = Vector3.ZERO
		return
	# Раз в ~1-1.5с спрашиваем Camp, есть ли в палатках свободное место.
	# Если есть — заселяемся: home_tent → найденная палатка, state →
	# RETURNING_TO_TENT (бежим домой sprint-скоростью). Это даёт «динамическое
	# заполнение» — после смерти жильца палатки бездомный гном из колонны
	# подхватывает вакансию.
	var now_msec: int = Time.get_ticks_msec()
	if now_msec >= _next_tent_vacancy_check_msec:
		_next_tent_vacancy_check_msec = now_msec + 1000 + (randi() % 500)
		var t: CampPart = _camp.find_tent_with_vacancy_for(self)
		if t != null:
			_claim_tent_as_home(t)
			return
	var target: Vector3 = _camp.get_chain_target_for_follower(self)
	var to_target := target - global_position
	to_target.y = 0.0
	var dist_sq: float = to_target.length_squared()
	if dist_sq < 0.16:  # < 0.4м — на слоте, стоим
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dist: float = sqrt(dist_sq)
	var dir: Vector3 = to_target / dist  # normalized без второго sqrt
	var t: float = clampf(dist / maxf(caravan_full_sprint_distance, 0.001), 0.0, 1.0)
	var speed: float = lerpf(move_speed, caravan_sprint_speed, t)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed


## Расчёт LOD-уровня по дистанции до точки интереса камеры (CameraRig).
## CameraRig — родитель Camera3D, lerp'ом следует за Tower; зум на него не
## влияет. Симметрично подходу у Skeleton.
##
## **Frustum-override:** если гном вне cone'а вокруг forward-направления
## Camera3D (угол > lod_offscreen_half_angle_deg), форсируем FAR-режим
## независимо от расстояния. Игрок не видит — нет смысла гонять
## move_and_slide и гравитацию. Симметрично Skeleton._update_lod_level.
## Cone от позиции **Camera3D** (реальная точка наблюдения), forward
## из basis Camera3D. AI продолжает работать в FAR-mode (гном идёт к
## своей цели), но дёшево.
func _update_lod() -> void:
	if not is_inside_tree():
		_lod_far = false
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_lod_far = false
		return

	# Frustum-cone override: если гном вне обзора, FAR без оглядки на distance.
	# Hysteresis: вход в FAR по основному cos'у; чтобы выйти обратно — нужно
	# зайти глубже в cone (cos_exit). Без этого гном на границе угла флипает
	# каждые 0.5с с пересчётом hot/cold-mode.
	var to_self: Vector3 = global_position - camera.global_position
	var dist_to_camera: float = to_self.length()
	if dist_to_camera > 0.001:
		var forward: Vector3 = -camera.global_transform.basis.z
		var cos_angle: float = forward.dot(to_self) / dist_to_camera
		var threshold: float = _lod_offscreen_cos_exit if _lod_far else _lod_offscreen_cos
		if cos_angle < threshold:
			_lod_far = true
			return

	var anchor: Node3D = camera.get_parent() as Node3D
	var anchor_pos: Vector3 = anchor.global_position if anchor != null else camera.global_position
	var d: float = global_position.distance_to(anchor_pos)
	_lod_far = d > lod_far_distance


func _tick_searching() -> void:
	# Шаг 0 (этап 49): орб приоритетнее куч — он исчезает через lifetime.
	# Ресурс может полежать минутами, орб — 60с, и пропавший XP в стресс-волне
	# теряется навсегда. Поэтому проверяем сначала.
	var orb := _scan_orb()
	if orb != null:
		_assigned_orb = orb
		_wander_target = Vector3.INF
		_state = State.COMMUTING_TO_ORB
		return

	# Шаг 1: ближайший годный pile во ВСЁМ мире (не cap'нуто vision_radius'ом).
	# Если нашёл — идём прямо к нему. Если не нашёл (пусто или всё claimed) —
	# в idle: подождать, рассканировать раз в idle_pile_rescan_sec.
	var pile := _find_nearest_pile()
	if pile != null:
		_assigned_pile = pile
		_wander_target = Vector3.INF
		_state = State.COMMUTING_TO_PILE
		return
	_wander_target = Vector3.INF
	_idle_pile_rescan_msec = 0  # rescan сразу после входа в idle, потом по расписанию
	_state = State.IDLE_NEAR_BASE


func _tick_commuting_to_pile() -> void:
	# freeze=true → кучу схватила рука, take_one провалится; не топчем зря.
	if not is_instance_valid(_assigned_pile) or _assigned_pile.units <= 0 or _assigned_pile.freeze:
		_on_pile_lost()
		return
	var pile_pos := _assigned_pile.global_position
	_move_toward_xz(pile_pos)
	if _horizontal_distance(pile_pos) <= pickup_distance:
		if _assigned_pile.take_one():
			_pickup_carry()
			_state = State.COMMUTING_TO_BASE
		else:
			# take_one() провалился — кучу выбили в этом же кадре.
			_on_pile_lost()


func _tick_commuting_to_base() -> void:
	var anchor := _camp.deploy_anchor
	_move_toward_xz(anchor)
	if _horizontal_distance(anchor) <= deposit_distance:
		# Кредитуем ресурс лагерю ДО _drop_carry — drop сбрасывает _carry_type.
		# Делаем это здесь, а не в _drop_carry: гном роняет визуал и в смерти,
		# и при свёртке (RETURNING_TO_TENT) — в этих случаях ресурс теряется
		# (буквально: упал по дороге). Кредит только на честной доставке.
		if _carry_type >= 0:
			_camp.add_resource(_carry_type, 1)
			ResourceFx.pulse(global_position, ResourcePile.color_for_type(_carry_type))
		_drop_carry()
		# После каждой доставки полный rescan через SEARCHING — гном пере-
		# выбирает pile под текущий приоритет. Если приоритет не менялся,
		# тот же pile часто остаётся ближайшим по weighted-dist (челнок
		# работает естественно). Если игрок только что переключил план —
		# гном переключается на тип нового приоритета. Стоимость лишнего
		# поиска ~10мкс, незначима.
		_on_pile_lost()


## Гном идёт к XpOrb. Касание Area3D орба сработает само — наш job только
## довести гнома до него. Если орб улетел/просрочился до контакта (касание
## другого союзника, lifetime expire) — сваливаемся в SEARCHING.
##
## arrival-чека по pickup_distance НЕТ: Area3D на орбе (radius=0.6м) сама
## триггернет body_entered ещё до того как гном дотянется по дистанции.
## Если же сцена орба настроена так, что Area3D меньше pickup_distance —
## гном упрётся в орб и будет дёргаться; для текущей сцены это не важно.
func _tick_commuting_to_orb() -> void:
	if not is_instance_valid(_assigned_orb) or not _assigned_orb.is_idle():
		_on_orb_lost()
		return
	_move_toward_xz(_assigned_orb.global_position)


## Орб исчез или коснулся другого. Вернуться в SEARCHING — там приоритет:
## новый орб → pile → idle/patrol.
func _on_orb_lost() -> void:
	_assigned_orb = null
	_state = State.SEARCHING


## «Глаза» гнома для XP-орбов — ближайший ещё-IDLE орб в vision_radius.
## Без spatial grid: на 30 гномах × ~50-100 орбах × 60fps = ~150k checks/сек,
## ~2мс CPU/сек. Если стресс-волны генерируют 500+ орбов одновременно —
## добавить grid по аналогии с _pile_grid (см. PILE_GRID_*).
func _scan_orb() -> XpOrb:
	var pos := global_position
	var vr_sq := vision_radius * vision_radius
	var nearest: XpOrb = null
	var nearest_d_sq := vr_sq
	for n in get_tree().get_nodes_in_group(XpOrb.GROUP):
		if not is_instance_valid(n):
			continue
		var orb := n as XpOrb
		if orb == null:
			continue
		# Идёт к идле-орбу. MAGNETIZED уже к лагерю летит, гном за ним
		# не угонится и не нужен.
		if not orb.is_idle():
			continue
		var d_sq: float = (orb.global_position - pos).length_squared()
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = orb
	return nearest


func _tick_idle_near_base() -> void:
	# Орб приоритет (этап 49): появляется прямо во время idle когда скелеты
	# бьются о лагерь, идти собирать.
	var orb := _scan_orb()
	if orb != null:
		_assigned_orb = orb
		_wander_target = Vector3.INF
		_state = State.COMMUTING_TO_ORB
		return

	# Периодический rescan pile-ов: ловим момент, когда другие гномы освободили
	# клейм или pile истёк. Без этого гном застрял бы в idle, пока не deploy.
	var now: int = Time.get_ticks_msec()
	if now >= _idle_pile_rescan_msec:
		_idle_pile_rescan_msec = now + int(idle_pile_rescan_sec * 1000.0)
		var pile := _find_nearest_pile()
		if pile != null:
			_assigned_pile = pile
			_wander_target = Vector3.INF
			_state = State.COMMUTING_TO_PILE
			return

	var anchor := _camp.deploy_anchor
	if _wander_target == Vector3.INF or _horizontal_distance(_wander_target) < wander_arrival:
		_wander_target = _random_point_around(anchor, idle_radius)
	_move_toward_xz(_wander_target)


func _tick_returning() -> void:
	if not is_instance_valid(_home_tent):
		# Палатка пропала — фиксируем дома там, что стоим, чистим состояние.
		_enter_in_tent()
		return
	var tent_pos := _home_tent.global_position
	# Бегут домой sprint-скоростью (та же, что и догон каравана) — иначе
	# свёртка лагеря висит pack_timeout секунд из-за гномов, шагающих
	# 1.6 m/s через всё поле.
	var to_tent := tent_pos - global_position
	to_tent.y = 0.0
	if to_tent.length_squared() > VecUtil.EPSILON_SQ:
		var dir := to_tent.normalized()
		velocity.x = dir.x * caravan_sprint_speed
		velocity.z = dir.z * caravan_sprint_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	if _horizontal_distance(tent_pos) <= home_distance:
		_enter_in_tent()


# --- Helpers ---

func _enter_in_tent() -> void:
	_state = State.IN_TENT
	_assigned_pile = null
	_wander_target = Vector3.INF
	_drop_carry()
	visible = false
	velocity = Vector3.ZERO
	# Скрыт в палатке — снимаем «целеустойчивость» для скелетов.
	remove_from_group(SKELETON_TARGET_GROUP)


## Куча, которую мы вели, исчезла или опустела. Просто перевод в SEARCHING —
## следующий кадр сам решит (память / глаза / патруль / idle).
func _on_pile_lost() -> void:
	_assigned_pile = null
	_wander_target = Vector3.INF
	_state = State.SEARCHING


## Игрок поменял приоритет сбора. Гном идёт к pile старого приоритета —
## бросаем, выбираем заново под новый план. Гном с carry в COMMUTING_TO_BASE
## не трогаем — донесёт текущую единицу, после доставки в _tick_commuting_to_base
## уже сделает rescan под новый приоритет.
func _on_collection_priority_changed(_weights: Dictionary) -> void:
	if _state == State.COMMUTING_TO_PILE:
		_on_pile_lost()


func _move_toward_xz(target: Vector3) -> void:
	# Pathfinding-обёртка: вместо прямого движения к target идём к следующей
	# точке пути из NavAgent. На близких целях (≤ NAV_DIRECT_RADIUS) и без
	# nav-агента — fallback на прямое движение.
	var step_target: Vector3 = _resolve_path_step(target)
	var to_target := step_target - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir := to_target.normalized()
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed


## Возвращает следующую точку, к которой нужно двигаться: либо waypoint
## NavAgent'а, либо сам goal (если nav недоступен / цель близко / waypoint
## слишком близко к текущей позиции). Подклассы используют через
## `_move_toward_xz` автоматически.
func _resolve_path_step(goal: Vector3) -> Vector3:
	if _nav_agent == null:
		return goal
	# На близких целях path-расчёт даёт «дрожащий» next_position — идём прямо.
	var goal_xz := Vector2(goal.x - global_position.x, goal.z - global_position.z)
	if goal_xz.length_squared() <= NAV_DIRECT_RADIUS * NAV_DIRECT_RADIUS:
		return goal
	# Set target каждый кадр без throttle'а: NavAgent сам кэширует и не
	# пересчитывает path если goal не сильно изменился. Старый throttle
	# с `get_physics_process_delta_time()` ломался когда метод вызывался
	# не из _physics_process (delta=0 → throttle никогда не истекал).
	_nav_agent.target_position = goal
	_nav_last_target = goal
	# Safety: если NavAgent ещё не успел построить path или цель недостижима,
	# is_navigation_finished()=true → next_path_position часто возвращает
	# текущую позицию агента. Тогда _move_toward_xz вычислит velocity=0 и
	# гном застывает. Fallback на прямой goal — пусть упрётся в стену, чем
	# стоит столбом.
	if _nav_agent.is_navigation_finished():
		return goal
	var next_pos: Vector3 = _nav_agent.get_next_path_position()
	# Дополнительный safety: waypoint слишком близко к текущей позиции
	# (< 0.2м по горизонтали) → агент считает что мы «дошли» до waypoint'а,
	# но дальше path ещё не advance'ил. Идём прямо к goal как fallback,
	# physics-slide вытолкнет нас по стене если стоит на пути.
	var to_next := Vector2(next_pos.x - global_position.x, next_pos.z - global_position.z)
	if to_next.length_squared() < 0.04:
		return goal
	return next_pos


func _horizontal_distance(target: Vector3) -> float:
	var d := target - global_position
	d.y = 0.0
	return d.length()


## Находит лучший pile с учётом collection_priority лагеря: weighted_dist =
## real_dist / priority_weight (типы с высоким приоритетом «приближаются»,
## с нулевым — игнорируются). Без cap'а дистанции — гном «знает» где ресурсы.
## Пропускает: пустые, замороженные (рука держит), нацеленные другим гномом,
## с типом приоритета 0.
##
## Использует static [Gnome._pile_grid]. Полный обход всех cells O(N pile-ов):
## на тестовых 30-100 pile × 60 гномов × 60fps это ~360k checks/сек.
func _find_nearest_pile() -> ResourcePile:
	Gnome._maybe_refresh_pile_grid(get_tree())
	var pos := global_position
	var nearest: ResourcePile = null
	var best_weighted_dist_sq := INF
	for cell_key in Gnome._pile_grid.keys():
		var entries: Array = Gnome._pile_grid[cell_key]
		for entry in entries:
			var ppos: Vector3 = entry[0]
			var raw = entry[1]
			if not is_instance_valid(raw):
				continue
			var rp := raw as ResourcePile
			if rp == null or rp.units <= 0 or rp.freeze:
				continue
			# Priority-фильтр через Camp: weight=0 (или близко) → тип «выключен»,
			# гном проходит мимо. Так работает план «не собирать камень».
			var weight: float = _camp.get_collection_priority_weight(int(rp.resource_type))
			if weight <= 0.001:
				continue
			# Эффективная дистанция: distance² / weight². Эквивалентно (d/w)²,
			# а возведение в квадрат сохраняет монотонность для сравнения.
			# При weight=0.5 pile «отодвигается» в 4 раза по cost'у; при
			# weight=2 (если бы были такие веса в нормализованной системе) —
			# приближается в 4 раза. В нашей нормализации weights ≤ 1, так что
			# веса всегда «отодвигают» — относительный порядок типов сохраняется.
			var d_sq: float = pos.distance_squared_to(ppos)
			var weighted_sq: float = d_sq / (weight * weight)
			if weighted_sq >= best_weighted_dist_sq:
				continue
			if _camp.is_pile_claimed(rp, self):
				continue
			best_weighted_dist_sq = weighted_sq
			nearest = rp
	return nearest


func _random_point_around(center: Vector3, radius: float) -> Vector3:
	var angle := randf() * TAU
	var dist := radius * sqrt(randf())  # uniform в круге, не в кольце
	var p := Vector3(
		center.x + cos(angle) * dist,
		center.y,
		center.z + sin(angle) * dist
	)
	# Клампим idle-wander к границам карты — на случай если deploy_anchor
	# близко к краю и idle_radius уводит за пределы пола.
	p.x = clampf(p.x, -wander_map_half_extent, wander_map_half_extent)
	p.z = clampf(p.z, -wander_map_half_extent, wander_map_half_extent)
	return p


func _pickup_carry() -> void:
	if _carry_visual:
		return
	# Запоминаем тип В МОМЕНТ pickup'а — pile сразу после take_one() мог уйти
	# в queue_free (units стало 0), к моменту сдачи его уже не достать.
	if is_instance_valid(_assigned_pile):
		_carry_type = int(_assigned_pile.resource_type)
	_carry_visual = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = carry_visual_size
	_carry_visual.mesh = box
	var mat := StandardMaterial3D.new()
	# Цвет визуала переноса = цвет типа ресурса. Раньше был фикс carry_color
	# (зелёный), теперь различимо: жёлто-коричневый над гномом → wood,
	# красно-оранжевый → food и т.д. Игрок видит что таскают.
	mat.albedo_color = ResourcePile.color_for_type(_carry_type) if _carry_type >= 0 else carry_color
	_carry_visual.material_override = mat
	_carry_visual.position = Vector3(0, 1.0, 0)  # над головой гнома
	add_child(_carry_visual)


func _drop_carry() -> void:
	if _carry_visual:
		_carry_visual.queue_free()
		_carry_visual = null
	_carry_type = -1
