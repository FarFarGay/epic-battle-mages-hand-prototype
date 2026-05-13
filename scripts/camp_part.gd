class_name CampPart
extends RigidBody3D
## Палатка лагеря. RigidBody3D с freeze=true в обычном режиме — Camp ведёт её
## плавно через global_position (как Item в руке: while frozen transform-set
## работает, ни гравитации, ни forces). На физический отрыв (Slam, Flick,
## бросок рукой, любой Pushable.try_push) палатка переходит в torn_off:
## freeze=false, impulse+torque, damping снижается для читаемого кувырка.
##
## **Палатка как щит для гномов**: пока цела (hp > 0), гномы внутри неуязвимы
## и урона не получают, даже когда палатка кубарем катится по земле. На
## каждом ударе о землю/тело (`body_entered` со speed ≥ min) палатка
## вытряхивает наружу `gnomes_per_impact` штук — здоровыми. На улице эти
## гномы попадают в SKELETON_TARGET_GROUP и становятся уязвимы к скелетам.
## Если палатку разнесёт по hp раньше, чем все вылезут — `_destroy` выпускает
## оставшихся, тоже без урона. Дальше — обычный физический обломок,
## Camp его не трогает.
##
## Управляется внешне через set_vulnerable из Camp:
##   - _ready (caravan-старт): true — скелеты могут атаковать караван.
##   - _start_deploy: true — без изменений, в DEPLOYED тоже атакуемы.
##   - _start_pack: false — лагерь свёртывается, тент бронируется.
##   - _finalize_pack: true — возврат в caravan-mode, цель снова открыта.

signal damaged(amount: float)
signal destroyed

const SKELETON_TARGET_GROUP := &"skeleton_target"

## HP палатки. Slam (hand_physical_slam.slam_damage=60 × falloff) рассчитан
## на 2 точных хлопка → hp=120. Скелеты (attack_damage=5) бьют 24 раза для
## разрушения — лагерь по-прежнему ощущается крепостью против обычных врагов.
## Контактный damage от полётов (после tear-off) поверх — палатку можно
## «добить» броском, если первый хлопок уже снёс часть hp.
@export var hp: float = 120.0

## Сколько гномов живёт в этой палатке. Camp читает это значение в своём
## _spawn_gnomes() и инстанцирует gnome_scene нужное количество раз.
@export var gnomes_per_tent: int = 7

## Сколько из gnomes_per_tent — защитники-лучники (DefenderGnome).
## Остальные — собиратели (Gnome). Дефолт 7 жителей: 1 защитник + 6 собирателей.
@export var defenders_per_tent: int = 1

@export_group("Tear-off (физический отрыв от каравана)")
## Множитель импульса при apply_push. Pushable.try_push передаёт желаемый
## Δv (без учёта массы). Стандарт RB: `impulse = Δv * mass` → тело получает
## velocity ровно Δv. Множитель <1 удерживает скорость в визуально красивом
## диапазоне (slam_force=30 без множителя дал бы 30 m/s — палатка за горизонт).
@export var push_velocity_factor: float = 0.6
## Угловой импульс при отрыве. Случайный 3D-вектор × magnitude. Magnitude
## масштабируется от силы удара — слабый щелбан не вращает как пропеллер.
@export var torque_factor: float = 0.8
## Контактный урон от ударов о препятствия после tear-off. Множитель × скорость
## контакта (м/с): damage = (speed - min_speed) × factor. Палатка катится, отскакивает,
## кувыркается, при каждом ударе о землю/тело берёт damage. Hp=250 → ~3-8 ударов
## при средней скорости, чтобы разрушиться. Slam/Flick применяют этот же путь,
## так что лежащий обломок можно «добить» ещё одним хлопком.
##
## **Гномы внутри урон не получают** — целая палатка щит, при ударе их
## просто вытряхивает наружу здоровыми. Уязвимыми они становятся только на
## улице (после eject'а в SKELETON_TARGET_GROUP). См. _eject_in_tent_gnomes.
@export var contact_damage_factor: float = 4.0
## Скорости ниже этого порога не дают damage (тихие касания, скольжение).
@export var contact_damage_min_speed: float = 4.0
## Сколько гномов вылетает за один удар о землю/препятствие. На каждый
## body_entered (со speed ≥ contact_damage_min_speed) палатка выплёвывает
## столько гномов из тех, кто ещё внутри. 7 гномов на палатку при значении 1
## → нужно 7 ударов чтобы опустошить, при 2 → 4 удара. Если палатку разнесёт
## раньше — оставшихся выпустит _destroy (тоже без урона, палатка их защищала).
@export var gnomes_per_impact: int = 1
## Минимальный интервал между eject'ами от ударов. Несколько одновременных
## body_entered (палатка коснулась двух тел в одном кадре) не дублируют выпуск.
@export var impact_eject_cooldown: float = 0.15
## Damping палатки после tear-off. tent.tscn держит linear=2.0, angular=2.5
## для статики в строю — но эти же значения гасят кувырок брошенной палатки
## за пару десятых секунды. На отрыве снижаем damping, чтобы обломок красиво
## летел и крутился до первого удара/полной остановки.
@export var torn_off_linear_damp: float = 0.5
@export var torn_off_angular_damp: float = 0.3

@export_group("Highlight (рамка-кандидата для руки)")
@export var highlight_color: Color = Color(1.0, 0.85, 0.4, 1.0)
@export var highlight_intensity: float = 0.6

@export_group("Shatter (рассыпание на смерти от hp)")
## Палатки крупнее скелета/гнома — больше фрагментов, дольше живут.
@export var shatter_fragment_count: int = 14
@export var shatter_lifetime: float = 2.5
@export var shatter_color: Color = Color(0.45, 0.3, 0.18, 1.0)
## Куда складывать фрагменты. Пусто → fallback на current_scene. Не делаем
## parent'ом сам Camp — при пересоздании сцены / уничтожении кампа
## дети-фрагменты улетели бы вместе с ним.
@export_node_path("Node") var effects_root_path: NodePath
@export_group("")

var _dying: bool = false
var _vulnerable: bool = false
var _torn_off: bool = false
var _in_hand: bool = false
## True если палатка стоит вне placement-зоны после тихого release. Camp её
## не таскает (filter skip), но это ОБРАТИМО: на _on_hand_grabbed флаг
## сбрасывается, и при placed-в-зоне следующего release палатка возвращается
## в строй. В отличие от `_torn_off` (необратимо, физический отрыв).
var _outside_caravan: bool = false
var _effects_root: Node = null
## Время последнего eject'а от удара (Time.get_ticks_msec()/1000.0). Гейт
## против дублирования при кучных body_entered'ах в одном кадре.
var _last_impact_eject_time: float = -INF
## Per-instance копия материала меша для индивидуальной emission-рамки.
## tent.tscn ссылается на shared StandardMaterial3D — без duplicate подсветка
## одной палатки засветила бы все. Дублируем в _ready и держим ref.
var _highlight_material: StandardMaterial3D = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	Damageable.register(self)
	Pushable.register(self)
	Grabbable.register(self)
	# Источник геометрии для NavMesh — палатки вырезают участки навмеша,
	# гномы и скелеты обходят. При перемещении палатки (drag рукой) navmesh
	# не пересчитывается до следующего try_build / явного rebake — это OK,
	# палатки в каравне обычно стабильны, а гномы используют slide-collisions.
	add_to_group(&"navmesh_source")
	## Soft-release: рука не применяет impulse при тихом release; CampPart
	## считает release с velocity > 0 «броском», а с velocity == 0 — «поставил».
	add_to_group(Layers.HAND_SOFT_RELEASE_GROUP)
	## Контактный damage после tear-off: contact_monitor включаем сразу,
	## хендлер сам гейтит по _torn_off — frozen палатка в строю не получает
	## body_entered'ы (RB на freeze не процессит контакты этим путём).
	contact_monitor = true
	max_contacts_reported = 6
	body_entered.connect(_on_body_entered)
	if _mesh != null:
		var src := _mesh.material_override
		if src is StandardMaterial3D:
			_highlight_material = (src as StandardMaterial3D).duplicate() as StandardMaterial3D
			_mesh.material_override = _highlight_material
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	damaged.connect(func(amount: float) -> void: EventBus.camp_part_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.camp_part_destroyed.emit(self))
	## Hand-события: грэб ставит in_hand-флаг, release решает «бросок vs поставил».
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)
	# Явная отписка на free. EventBus — autoload, без disconnect фантомные
	# Callable'ы оставались бы до GC. Палатки уничтожаются скелетами в матче
	# (×4 палатки), эффект мелкий, но систематический.
	tree_exiting.connect(_disconnect_eventbus)


func _disconnect_eventbus() -> void:
	if EventBus.hand_grabbed.is_connected(_on_hand_grabbed):
		EventBus.hand_grabbed.disconnect(_on_hand_grabbed)
	if EventBus.hand_released.is_connected(_on_hand_released):
		EventBus.hand_released.disconnect(_on_hand_released)


## Half-height палатки (от центра до низа). Используется Camp'ом и
## _snap_to_ground для расчёта Y стояния на полу: pos.y = ground_y + offset.
## Считаем из CollisionShape3D BoxShape3D — подойдёт под tent.tscn (1.5 высота).
func floor_offset_y() -> float:
	if _shape != null and _shape.shape is BoxShape3D:
		return (_shape.shape as BoxShape3D).size.y * 0.5
	return 0.75


## Управляется камп'ом по фазам: DEPLOYED → true, CARAVAN/PACKING → false.
func set_vulnerable(value: bool) -> void:
	if _vulnerable == value or _dying:
		return
	_vulnerable = value
	if value:
		add_to_group(SKELETON_TARGET_GROUP)
	else:
		remove_from_group(SKELETON_TARGET_GROUP)


## True если палатка физически оторвана от каравана (apply_push'нута хотя бы
## раз). Camp пропускает torn_off в follow-логике — палатка живёт по физике
## до hp-разрушения. Tear-off необратим.
func is_torn_off() -> bool:
	return _torn_off


## True если палатка сейчас зажата в руке. Camp пропускает её в follow,
## пока Hand двигает её через global_position.
func is_in_hand() -> bool:
	return _in_hand


## True если палатка ИЗ строя (Camp таскает в цепочке/кольце). False если
## torn_off (необратимо) или временно вне placement-зоны после тихого release.
func is_in_caravan() -> bool:
	return not _torn_off and not _outside_caravan


## Grabbable-контракт: подсветка рамки-кандидата для руки.
func set_highlighted(value: bool) -> void:
	if _highlight_material == null:
		return
	if value:
		_highlight_material.emission_enabled = true
		_highlight_material.emission = highlight_color
		_highlight_material.emission_energy_multiplier = highlight_intensity
	else:
		_highlight_material.emission_enabled = false


# --- Hand handlers ---

func _on_hand_grabbed(item: Node3D) -> void:
	if item != self:
		return
	_in_hand = true
	# Поднятие сбрасывает флаги «вне строя» И «оторванная»: после release
	# решим заново, как палатку обработать. Это позволяет вернуть и палатку
	# далеко поставленную (outside_caravan), и палатку, которую ударили в
	# караване и она вылетела (torn_off, но HP > 0 — иначе она бы уже
	# queue_free'нулась через _destroy). Если игрок снова бросает (release
	# с velocity > 0) — _become_torn_off в hand_released ставит _torn_off
	# обратно в true. Soft-release с целой палаткой → notify_part_settled
	# и палатка возвращается в строй / встаёт на свободное место.
	_outside_caravan = false
	_torn_off = false
	# Hand сам ставит freeze=true в _attach.


func _on_hand_released(item: Node3D, velocity: Vector3) -> void:
	if item != self:
		return
	_in_hand = false
	if _dying:
		return
	# Hand применил linear_velocity ДО emit'а сигнала. Velocity == 0 — это
	# soft-release ветка Hand'а сработала (рука двигалась медленнее
	# soft_release_velocity_threshold). Это и есть «осторожно поставил».
	# Velocity > 0 — игрок резко махнул рукой, это бросок.
	if velocity.length_squared() > 0.0:
		# Бросок: Hand уже задал linear_velocity. Tear-off + torque + ejection.
		# Палатка дальше живёт по физике как обломок: катится, кувыркается,
		# при каждом ударе о препятствие в _on_body_entered берёт damage.
		# Через несколько сильных ударов разрушается через стандартный
		# destroy. Slam/Flick идут через apply_push с тем же поведением.
		_become_torn_off(velocity, false)
		return
	# Тихий release. Если палатка уже была torn_off (подобрали обломок и тихо
	# положили обратно) — оставляем как обломок, freeze=false, под гравитацией.
	if _torn_off:
		return
	# Обычная палатка, переставленная рукой. Velocity сбрасываем ДО freeze
	# (Godot 4 порядок имеет значение) и snap'аем на пол — Hand держит
	# палатку выше уровня земли (cursor + hold_offset = ~1.5м над полом),
	# без snap'а она бы висела в воздухе.
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_snap_to_ground()
	freeze = true
	sleeping = true
	var camp := get_parent() as Camp
	if camp != null:
		camp.notify_part_settled(self)
	else:
		# Без Camp-родителя palatka стоит сама по себе. Маркируем «вне строя»
		# на всякий случай (хотя без Camp некому фильтровать).
		_outside_caravan = true


## Camp вызывает при тихом release ВНЕ placement-зоны: палатка остаётся стоять
## там, где её положили; Camp.follow её больше не таскает (filter skip по
## is_in_caravan). Подъёмом рукой состояние сбрасывается.
func mark_outside_caravan() -> void:
	_outside_caravan = true


## Camp вызывает на _finalize_pack, чтобы вернуть в строй ВСЕ палатки,
## которые были «вне строя» в развёрнутом лагере (свободно расставлены
## игроком). После этого is_in_caravan() снова true и палатка попадает в
## _update_caravan_follow → плавно вытягивается в цепочку за башней.
## Не сбрасывает _torn_off — физически оторванные обломки остаются обломками.
func restore_to_caravan() -> void:
	if _torn_off or _dying:
		return
	_outside_caravan = false


## Сажает палатку ровно на пол под её текущей XZ-позицией: raycast вниз по
## TERRAIN, Y = hit.y + half-height. Без snap'а тихий release из руки оставлял
## палатку висеть на ~метр над землёй (рука держит на cursor.y + hold_offset).
func _snap_to_ground() -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var from := global_position + Vector3.UP * 5.0
	var to := global_position + Vector3.DOWN * 50.0
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.TERRAIN)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var ground_y: float = (hit.position as Vector3).y
	global_position = Vector3(global_position.x, ground_y + floor_offset_y(), global_position.z)


# --- Контактный урон torn_off палатки ---

## body_entered летит на каждый physics-контакт RB (не frozen). Гейтим по
## _torn_off — frozen палатка в строю и так не получает контактов
## (RB-frozen пропускает контакт-callbacks). Damage пропорционален скорости
## касания: linear_velocity на момент сигнала ≈ скорость удара. На том же
## ударе выпускаем gnomes_per_impact гномов — палатка ведёт себя как
## пиньята: каждый удар о землю / тело роняет наружу очередную партию.
##
## Eject ИДЁТ ПЕРЕД take_damage: если этот удар добивает hp до нуля,
## _destroy выпустит оставшихся как «их завалило» — без двойного eject'а
## (gnome.eject_from_tent переключает is_home → false, второй проход отфильтрует).
func _on_body_entered(_body: Node) -> void:
	if not _torn_off or _dying:
		return
	var speed: float = linear_velocity.length()
	if speed < contact_damage_min_speed:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_impact_eject_time >= impact_eject_cooldown:
		_last_impact_eject_time = now
		_eject_in_tent_gnomes(gnomes_per_impact)
	var damage: float = (speed - contact_damage_min_speed) * contact_damage_factor
	take_damage(damage)


# --- Damageable / take_damage ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	if not _vulnerable and not _torn_off:
		# Бронированная палатка в строю (PACKING_RETURNING) — удары не проходят.
		# Torn_off обломки урон принимают всегда: дизайн «бросил → катится →
		# разрушается от ударов» работает независимо от _vulnerable, который
		# для них больше не релевантен (палатка уже не часть каравана).
		return
	hp -= amount
	damaged.emit(amount)
	HitFlash.flash(_mesh)
	if hp <= 0.0:
		_destroy()


## Уничтожение от исчерпания hp. Прячет меш, сыплет фрагменты, queue_free.
## Используется только из take_damage — tear-off / drop сами по себе НЕ
## разрушают палатку (она остаётся как меш-обломок).
##
## Перед shatter'ом вытряхиваем всех ещё-сидящих внутри гномов БЕЗ урона —
## целая палатка их защищала, при разрушении они просто оказываются на
## улице. Дальше они уязвимы как обычные гномы (в SKELETON_TARGET_GROUP).
func _destroy() -> void:
	_dying = true
	remove_from_group(SKELETON_TARGET_GROUP)
	_eject_in_tent_gnomes(-1)
	if _mesh:
		_mesh.visible = false
	if _effects_root:
		ShatterEffect.spawn(_effects_root, global_position, shatter_color,
			shatter_fragment_count, shatter_lifetime)
	destroyed.emit()
	queue_free()


# --- Pushable / tear-off ---

## Pushable-контракт. Δv — желаемый прирост скорости от вызывающей системы.
## Первый вызов отрывает палатку (`_become_torn_off`); subsequent — просто
## добавляют impulse поверх (можно пинать лежащий обломок дальше).
func apply_push(velocity_change: Vector3, _duration: float) -> void:
	if _dying:
		return
	if not _torn_off:
		_become_torn_off(velocity_change, true)
	else:
		# Уже обломок — добавляем impulse сверху, без второй eject-волны.
		apply_central_impulse(velocity_change * push_velocity_factor * mass)


## Универсальный путь tear-off: снимает freeze, понижает damping (чтобы
## обломок красиво кувыркался и далеко летел), кидает random torque.
## Опционально применяет central impulse (Slam/Flick передают Δv → нужен
## impulse; Hand-throw уже задал linear_velocity напрямую → impulse не нужен,
## иначе ускорение удвоится).
##
## **Гномов сам tear-off НЕ выкидывает** — они вылетают порциями на каждом
## ударе через _on_body_entered → _eject_in_tent_gnomes. Если палатку
## разнесёт по hp раньше, чем все вылезут, _destroy выпустит оставшихся.
func _become_torn_off(impact_velocity: Vector3, do_impulse: bool) -> void:
	_torn_off = true
	freeze = false
	# RB после freeze→false иногда остаётся спящим — будим явно, чтобы
	# impulse и торque сработали в этом же кадре.
	sleeping = false
	# Низкий damping — палатка летит и крутится визуально читаемо.
	# В строю (frozen=true) damping не считается, так что пониженные значения
	# здесь не аффектят покоящуюся палатку.
	linear_damp = torn_off_linear_damp
	angular_damp = torn_off_angular_damp
	if do_impulse:
		apply_central_impulse(impact_velocity * push_velocity_factor * mass)
	var torque_dir := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	if torque_dir.length_squared() > 0.0:
		torque_dir = torque_dir.normalized()
	var torque_magnitude: float = impact_velocity.length() * torque_factor * mass
	apply_torque_impulse(torque_dir * torque_magnitude)


## Гномы внутри палатки выходят на улицу БЕЗ damage — целая палатка щит.
## На улице каждый получает scatter-импульс в случайном направлении +
## ~2с неуязвимости (см. Gnome.eject_from_tent), затем уходит в FOLLOWING_CARAVAN
## (за башней). К другим палаткам кикнутые гномы не возвращаются.
##
## `max_count`: максимум гномов за один вызов. -1 → выпустить всех оставшихся
## (используется в _destroy, когда палатку разнесли). Положительное значение
## ограничивает порцию (1-2 гнома за удар в _on_body_entered).
func _eject_in_tent_gnomes(max_count: int) -> void:
	var camp := get_parent() as Camp
	if camp == null:
		return
	var ejected: int = 0
	for g in camp.get_gnomes():
		if max_count >= 0 and ejected >= max_count:
			break
		if not is_instance_valid(g):
			continue
		if g.get_home_tent() != self:
			continue
		if not g.is_home():
			continue
		g.eject_from_tent()
		ejected += 1
