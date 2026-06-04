class_name PalisadeSegment
extends StaticBody3D
## Сегмент деревянного частокола. Дешёвая защитная постройка: блокирует
## движение скелетов (физически — `collision_layer = CAMP_OBSTACLE`) и
## служит **целью-отвлечением** (входит в `skeleton_target`-группу).
##
## **Дизайнерская роль:** недорогой расходник. 2 wood за сегмент, hp=30
## (3-4 удара скелета). Игрок рисует ломаную через polyline-кисть в
## `HandBuildAim` — за один ПКМ-commit спавнится несколько сегментов
## вдоль линии. Стена медленно разваливается под напором, защитники
## успевают стрелять, игрок строит новые сегменты позади.
##
## **Не свёртывается с лагерем** — стоит до уничтожения, даже если
## караван уехал. «Забытые крепости» на пути.

const SKELETON_TARGET_GROUP := &"skeleton_target"
## Группа угловых столбов / endpoint'ов частокола. Используется в
## HandBuildAim для snap'а первой вершины новой цепочки к существующей
## стене — игрок может «продолжить» от любого угла. Сегменты-стены в
## этой группе НЕ состоят (palisade_post.tscn ставит `is_post=true`).
const PALISADE_VERTEX_GROUP := &"palisade_vertex"

@export var hp: float = 30.0
## True если этот инстанс — угловой столб (palisade_post.tscn), не stretched
## сегмент-стена (palisade_segment.tscn). Posts добавляются в
## [PALISADE_VERTEX_GROUP] для snap'а в HandBuildAim. Дизайнерский путь:
## `palisade_post.tscn` ставит is_post=true в scene-override (см. .tscn).
@export var is_post: bool = false
## Цвет emission при hover-подсветке. Тёплый жёлтый — единый язык с
## остальными pickup-объектами (колокол, Grabbable RB'и).
@export var highlight_color: Color = Color(1.0, 0.85, 0.4, 1.0)
@export var highlight_intensity: float = 1.0

signal damaged(amount: float)
signal destroyed

@onready var _mesh: MeshInstance3D = $MeshInstance3D

## Per-instance копия материала — иначе hover-emission поднялся бы на всех
## сегментах сразу (sub_resource shared в .tscn).
var _material: StandardMaterial3D = null
var _base_emission_energy: float = 0.0
var _highlighted: bool = false
var _destroyed: bool = false


func _ready() -> void:
	Damageable.register(self)
	add_to_group(SKELETON_TARGET_GROUP)
	# Маркер «только для melee». Лучники и будущие ranged враги пропускают
	# палисад в скане — стрелять в стену бесполезно, цель должна быть «живой».
	add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	# Источник геометрии для NavMesh bake'а — стена должна вырезать кусок
	# навмеша, чтобы гномы и скелеты-обходники её огибали.
	add_to_group(&"navmesh_source")
	# Posts (углы / endpoint'ы) — snap-цели для HandBuildAim brush'а.
	if is_post:
		add_to_group(PALISADE_VERTEX_GROUP)
	# Дублируем материал per-instance для hover-эффекта.
	if _mesh != null and _mesh.material_override is StandardMaterial3D:
		var src := _mesh.material_override as StandardMaterial3D
		_base_emission_energy = src.emission_energy_multiplier
		_material = src.duplicate() as StandardMaterial3D
		_mesh.material_override = _material


## Hover-подсветка через общий сканер Hand'а. Палисад НЕ регистрируется в
## PICKUP_HIGHLIGHT_GROUP пока — relocate'а нет (стены дешёвые, проще
## разбить и поставить новые). Если в будущем понадобится relocate —
## добавить `add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)` в _ready.
func set_highlighted(value: bool) -> void:
	if _material == null or _highlighted == value:
		return
	_highlighted = value
	if value:
		_material.emission_enabled = true
		_material.emission = highlight_color
		_material.emission_energy_multiplier = highlight_intensity
	else:
		_material.emission_energy_multiplier = _base_emission_energy


# --- Damageable ---

func take_damage(amount: float) -> void:
	if _destroyed or amount <= 0.0:
		return
	hp -= amount
	if LogConfig.master_enabled:
		print("[Palisade] получил урон %.1f, hp=%.1f" % [amount, hp])
	damaged.emit(amount)
	if hp <= 0.0:
		_die()


func _die() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(SKELETON_TARGET_GROUP)
	destroyed.emit()
	# call_deferred — Camp подписан на сигнал и может ещё реагировать
	# (например, для счётчика).
	call_deferred("queue_free")
