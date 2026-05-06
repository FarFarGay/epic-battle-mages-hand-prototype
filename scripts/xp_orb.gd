class_name XpOrb
extends Node3D
## Орб опыта отряда, дроп со смерти скелета. Лежит на земле, на касании
## союзника (Tower / CampPart / гном-собиратель) активируется магнит — летит
## к `Camp.deploy_anchor`, на arrival пополняет `_squad_xp` и исчезает.
##
## Архитектура «один путь»:
##   - Все скелеты дропают орб через `XpOrbSpawner` (autoload, слушает
##     `EventBus.enemy_destroyed`).
##   - Орб stateless по отношению к стрелку — кредит идёт лагерю целиком,
##     не отдельному защитнику. Тот, кто коснулся, определяет КУДА орб летит.
##   - Защитник может кoснуться орба своим патрулём, гном-собиратель — через
##     активный поиск (`Gnome._scan_orbs` → `COMMUTING_TO_ORB`), Tower и
##     палатка — пассивно проезжая мимо.
##
## Lifetime fallback: если за 60с никто не коснулся (далеко от каравана,
## гномы не дошли) — queue_free без кредита. Иначе уцелевшие дальние орбы
## накапливались бы пачками после стресс-волн.

signal collected(amount: int, world_position: Vector3)

const GROUP := &"xp_orb"

@export_group("Stats")
## Сколько XP добавится в `Camp._squad_xp` на arrival. Дефолт 10 совпадает с
## прежним `Camp.squad_xp_per_kill`.
@export var amount: int = 10
## Сколько секунд орб лежит, прежде чем самоуничтожиться. Без таймаута дальние
## неподобранные орбы накапливались бы — на 200 скелетов / волну = 200 нодов.
@export var lifetime: float = 60.0

@export_group("Magnet")
## Скорость движения к anchor'у в MAGNETIZED-фазе. Выше Tower=8 — орб догоняет
## караван, даже если тот уже отъехал от точки касания.
@export var magnet_speed: float = 12.0
## Дистанция до anchor'а, на которой орб «прибыл» и зачисляется. Меньше
## arrival_distance = риск проскочить за один тик при magnet_speed=12.
@export var arrival_distance: float = 0.5

@export_group("Idle visual")
## Амплитуда вертикального покачивания в IDLE — даёт орбу «жизнь», глаз
## цепляется за движение в траве.
@export var bobbing_amplitude: float = 0.15
@export var bobbing_speed: float = 2.0

@export_group("")
@export var debug_log: bool = true

enum State { IDLE, MAGNETIZED }

## Шейр'нутый материал — все орбы рисуются одним и тем же золотым emissive'ом,
## GPU батчит draw calls. Не дублируем .duplicate() per-instance.
static var _shared_material: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _magnet_area: Area3D = $MagnetArea

var _state: State = State.IDLE
var _life_elapsed: float = 0.0
## Фаза bobbing'а: рандом per-инстанс — пачка орбов от одной волны не качается
## синхронно, выглядит естественно.
var _bob_phase: float = 0.0
## Базовая Y-координата (точка спавна) — bobbing колеблется относительно неё.
## Также используется как Y магнитного полёта: target_y = _base_y, чтобы орб
## летел строго горизонтально и не нырял в anchor-точку (которая на полу).
var _base_y: float = 0.0
## Куда лететь после активации магнита. None = ещё в IDLE.
var _camp_target: Camp = null


## Орб ещё лежит и ждёт касания. `Gnome._scan_orb` использует это, чтобы
## не выбирать целью орб, который уже улетает к Camp'у (тогда побежал бы
## впустую — другой союзник его подобрал первым).
func is_idle() -> bool:
	return _state == State.IDLE


func _ready() -> void:
	add_to_group(GROUP)
	_ensure_shared_material()
	if _mesh != null and _shared_material != null:
		_mesh.material_override = _shared_material
	_base_y = global_position.y
	_bob_phase = randf() * TAU
	_magnet_area.body_entered.connect(_on_body_entered)
	if debug_log and LogConfig.master_enabled:
		print("[XpOrb:%s] ready: pos=(%.2f, %.2f, %.2f), base_y=%.2f, amount=%d" % [
			name, global_position.x, global_position.y, global_position.z, _base_y, amount,
		])


static func _ensure_shared_material() -> void:
	if _shared_material != null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.2)
	mat.emission_energy_multiplier = 1.5
	_shared_material = mat


func _physics_process(delta: float) -> void:
	_life_elapsed += delta
	if _life_elapsed >= lifetime:
		if debug_log and LogConfig.master_enabled:
			print("[XpOrb:%s] expired (lifetime=%.0fс) at pos=(%.2f, %.2f, %.2f), state=%s" % [
				name, lifetime, global_position.x, global_position.y, global_position.z,
				"IDLE" if _state == State.IDLE else "MAGNETIZED",
			])
		queue_free()
		return
	match _state:
		State.IDLE:
			# Bobbing вокруг _base_y. Не трогаем X/Z — лежит на месте.
			global_position.y = _base_y + sin(_life_elapsed * bobbing_speed + _bob_phase) * bobbing_amplitude
		State.MAGNETIZED:
			_tick_magnetized(delta)


func _tick_magnetized(delta: float) -> void:
	if _camp_target == null or not is_instance_valid(_camp_target):
		# Camp умер до прибытия — орб не имеет получателя, просто исчезает.
		queue_free()
		return
	# Целимся в X/Z `current_center()` (среднее живых палаток, fallback на Tower),
	# но Y держим равной `_base_y` — высоте, на которой орб появился и
	# bobbing'ал в IDLE. Это даёт горизонтальный полёт без ныряний:
	#  - `current_center().y` ≈ половина высоты палатки (origin палатки в
	#    центре меша) — не та высота, что у орба;
	#  - `deploy_anchor.y` = 0 пока лагерь не развёрнут — вообще не вариант.
	# Один источник правды для высоты — точка рождения орба.
	var center: Vector3 = _camp_target.current_center()
	var target_pos := Vector3(center.x, _base_y, center.z)
	var to_target: Vector3 = target_pos - global_position
	var dist: float = to_target.length()
	if dist <= arrival_distance:
		if debug_log and LogConfig.master_enabled:
			print("[XpOrb:%s] arrival: pos=(%.2f, %.2f, %.2f), camp_center=(%.2f, %.2f, %.2f), +%d xp" % [
				name, global_position.x, global_position.y, global_position.z,
				center.x, center.y, center.z, amount,
			])
		_camp_target.add_squad_xp(amount, global_position)
		collected.emit(amount, global_position)
		queue_free()
		return
	var step: float = magnet_speed * delta
	if step >= dist:
		# Этот шаг доедет до цели — телепортируемся, чтобы не проскочить.
		global_position = target_pos
		return
	global_position += to_target / dist * step


## Касание союзника — активируем магнит. Идемпотентно: повторное касание в
## MAGNETIZED-фазе игнорируется (мы уже летим).
func _on_body_entered(body: Node) -> void:
	if _state != State.IDLE:
		return
	var camp := _resolve_camp_from(body)
	if camp == null:
		return
	_activate_magnet(camp)


## Найти Camp-владельца коснувшегося тела. Tower/CampPart/Gnome — три
## случая. Tower не хранит ссылку на Camp напрямую — итерируем группу
## `camp` (1-2 инстанса на карте, дёшево).
func _resolve_camp_from(body: Node) -> Camp:
	if body is Gnome:
		return (body as Gnome).get_camp()
	if body is CampPart:
		return body.get_parent() as Camp
	# Tower-ветка: единственный кейс, когда нужно искать Camp по ссылке.
	for c in get_tree().get_nodes_in_group(Camp.CAMP_GROUP):
		if not is_instance_valid(c):
			continue
		var camp := c as Camp
		if camp == null:
			continue
		if camp.get_tower() == body:
			return camp
	return null


func _activate_magnet(camp: Camp) -> void:
	_camp_target = camp
	_state = State.MAGNETIZED
	# Снимаем Area3D.monitoring — больше не интересны новые касания.
	# Лишнее body_entered в полёте к anchor'у только зря тратит physics-call'ы.
	_magnet_area.monitoring = false
	if debug_log and LogConfig.master_enabled:
		var center: Vector3 = camp.current_center()
		print("[XpOrb:%s] magnet activated: pos=(%.2f, %.2f, %.2f), target_xz=(%.2f, %.2f), target_y=%.2f (=base_y), camp_center.y=%.2f" % [
			name, global_position.x, global_position.y, global_position.z,
			center.x, center.z, _base_y, center.y,
		])
