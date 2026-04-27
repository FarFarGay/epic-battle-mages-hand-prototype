class_name CampPart
extends StaticBody3D
## Палатка лагеря. Препятствие для скелетов (CAMP_OBSTACLE) и одновременно
## цель их атаки — но ТОЛЬКО в развёрнутом состоянии лагеря. Управляется
## внешне через set_vulnerable: Camp вызывает true на _start_deploy и false
## на _start_pack / _ready (стартуем в каравне → неуязвимы).
##
## Уязвимая = в группе skeleton_target + take_damage прибавляет урон.
## Неуязвимая = вне группы + take_damage no-op.
##
## При hp <= 0 → destroyed signal + queue_free; владелец-Camp вычищает себя
## из массива _parts по этому же сигналу.

signal damaged(amount: float)
signal destroyed

const SKELETON_TARGET_GROUP := &"skeleton_target"

## Палатке нужно много ударов: 250 hp при skeleton.attack_damage=5 → 50 ударов.
## Лагерь должен ощущаться крепостью, а не палаткой из ткани.
@export var hp: float = 250.0

## Сколько гномов живёт в этой палатке. Camp читает это значение в своём
## _spawn_gnomes() и инстанцирует gnome_scene нужное количество раз для
## каждой палатки. Параметр на палатке (а не на Camp), чтобы разные типы
## палаток могли иметь разную «вместимость» — командная на 1 жителя,
## жилая на 7, склад на 0 и т.п.
@export var gnomes_per_tent: int = 7

@export_group("Shatter (рассыпание на смерти)")
## Палатки крупнее скелета/гнома — больше фрагментов, дольше живут.
@export var shatter_fragment_count: int = 14
@export var shatter_lifetime: float = 2.5
@export var shatter_color: Color = Color(0.45, 0.3, 0.18, 1.0)
## Куда складывать фрагменты. Пусто → fallback на current_scene. Не делаем
## parent'ом сам Camp: при пере-инициализации сцены или удалении кампа дети-
## фрагменты улетели бы вместе с ним, не доиграв.
@export_node_path("Node") var effects_root_path: NodePath
@export_group("")

var _dying: bool = false
var _vulnerable: bool = false
var _effects_root: Node = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	Damageable.register(self)
	# В группу skeleton_target НЕ добавляемся на старте — лагерь стартует в
	# каравне, палатки неуязвимы. Camp.set_vulnerable(true) на _start_deploy.
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	damaged.connect(func(amount: float) -> void: EventBus.camp_part_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.camp_part_destroyed.emit(self))


## Управляется камп'ом по фазам: DEPLOYED → true, CARAVAN/PACKING → false.
## Обновляет и принадлежность к группе целей, и приём урона в take_damage.
func set_vulnerable(value: bool) -> void:
	if _vulnerable == value or _dying:
		return
	_vulnerable = value
	if value:
		add_to_group(SKELETON_TARGET_GROUP)
	else:
		remove_from_group(SKELETON_TARGET_GROUP)


func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	if not _vulnerable:
		# Лагерь свёрнут / в каравне — палатки brončа, удары не проходят.
		return
	hp -= amount
	damaged.emit(amount)
	HitFlash.flash(_mesh)
	if hp <= 0.0:
		_dying = true
		# queue_free отрабатывает только в конце кадра — без снятия флага скелет
		# ещё успел бы зацелиться в умирающую палатку в текущем тике.
		remove_from_group(SKELETON_TARGET_GROUP)
		# Прячем меш и сыплем фрагменты — те живут в _effects_root, переживают
		# queue_free самой палатки.
		if _mesh:
			_mesh.visible = false
		if _effects_root:
			ShatterEffect.spawn(_effects_root, global_position, shatter_color,
				shatter_fragment_count, shatter_lifetime)
		destroyed.emit()
		queue_free()
