class_name ResourcePile
extends RigidBody3D
## Куча ресурсов: гномы забирают по 1 ед. через take_one(). Также — Damageable
## (рука может разнести), Pushable (рука/башня могут толкнуть), Grabbable
## (рука может схватить и кинуть).
##
## Поддерживает 4 типа ресурса (resource_type): WOOD/STONE/IRON/FOOD/GENERIC.
## Тип задаёт визуал по умолчанию (цвет, форма, размер) — переопределяется
## экспортами pile_color/pile_size/pile_shape если нужен кастом.
##
## Гномы видят кучу, только если она не заморожена (freeze=false). Когда игрок
## схватил кучу рукой — freeze=true, гномы воспринимают её как «занятую» и
## идут искать другую (через _on_pile_lost).
##
## hp и units независимы:
##   - units → запас ресурсов; декрементируется при take_one().
##   - hp → урон от руки/slam'а; queue_free при hp ≤ 0 даже если units > 0.

signal damaged(amount: float)
signal destroyed

const GROUP := &"resource_pile"

## Тип ресурса. Определяет дефолтный визуал (если не переопределён) и
## используется внешним кодом (UI/HUD/Camp инвентарь) для агрегирования.
## GENERIC — старый «зелёный ящик» для обратной совместимости с тем кодом,
## который не различает типы.
##
## PAGE — страницы из книги колдовства. Не добываются гномами с pile-зон
## (или добываются — design-decision позже): тратятся на разблокировку и
## улучшение заклинаний башни через SpellSystem. Хранятся как обычный
## ресурс в Camp.economy.
enum ResourceType { GENERIC, WOOD, STONE, IRON, FOOD, PAGE, GOLD }

## Форма pile'а — определяет PrimitiveMesh + CollisionShape3D. По умолчанию
## выбирается по resource_type (BOX для большинства, CYLINDER для дерева).
enum PileShape { AUTO, BOX, CYLINDER, SPHERE }

@export var resource_type: ResourceType = ResourceType.GENERIC
@export var units: int = 5
@export var hp: float = 30.0
## Если оставить дефолтные (Color.BLACK / Vector3.ZERO / AUTO), визуал
## подберётся по resource_type. Чтобы переопределить — выставить значение
## вручную; geometry применит ровно его.
@export var pile_color: Color = Color.BLACK
@export var pile_size: Vector3 = Vector3.ZERO
@export var pile_shape: PileShape = PileShape.AUTO
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6

var _material: StandardMaterial3D
## Идемпотентность смерти: take_damage и take_one могут привести pile к
## уничтожению независимо в одном кадре (например, slam добивает hp, а гном
## параллельно вызывает take_one на units=1). Без флага оба вызвали бы
## destroyed.emit() дважды → подписчики (gnome carry-reset, fx) ловят двойной
## сигнал. queue_free() идемпотентен сам по себе, но сигнал — нет.
var _dying: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	add_to_group(GROUP)
	Damageable.register(self)
	Pushable.register(self)
	Grabbable.register(self)
	_apply_visual()
	_apply_shape()


## Дефолтный цвет по типу ресурса. Публичный — используют HUD/Journal/Gnome
## carry-visual / FX-частицы (`ResourceFx.pulse`). Чтобы не плодить дубли
## цветов — единственный источник истины в проекте.
static func color_for_type(t: int) -> Color:
	match t:
		ResourceType.WOOD:
			return Color(0.45, 0.28, 0.15)
		ResourceType.STONE:
			return Color(0.55, 0.55, 0.55)
		ResourceType.IRON:
			return Color(0.35, 0.38, 0.42)
		ResourceType.FOOD:
			return Color(0.85, 0.35, 0.25)
		ResourceType.PAGE:
			return Color(0.55, 0.35, 0.85)
		ResourceType.GOLD:
			return Color(0.95, 0.78, 0.18)
		_:
			return Color(0.4, 0.75, 0.3)


## Визуал-defaults по resource_type. Возвращает (color, size, shape).
## Используется при `pile_color == BLACK / pile_size == ZERO / pile_shape == AUTO`.
static func _defaults_for_type(t: int) -> Array:
	match t:
		ResourceType.WOOD:
			# Бревно: коричневый цилиндр, лежит вертикально (высокий-узкий).
			return [color_for_type(t), Vector3(0.5, 1.4, 0.5), PileShape.CYLINDER]
		ResourceType.STONE:
			# Каменный блок: серый куб.
			return [color_for_type(t), Vector3(0.9, 0.7, 0.9), PileShape.BOX]
		ResourceType.IRON:
			# Куча оружия/доспехов: тёмно-стальной приплюснутый бокс.
			return [color_for_type(t), Vector3(0.8, 0.4, 0.8), PileShape.BOX]
		ResourceType.FOOD:
			# Фруктовый куст/ягоды: красно-оранжевая сфера.
			return [color_for_type(t), Vector3(0.7, 0.7, 0.7), PileShape.SPHERE]
		ResourceType.PAGE:
			# Стопка страниц/книга: фиолетовый приплюснутый бокс.
			return [color_for_type(t), Vector3(0.55, 0.25, 0.7), PileShape.BOX]
		ResourceType.GOLD:
			# Слиток золота: золотой компактный бокс.
			return [color_for_type(t), Vector3(0.45, 0.3, 0.7), PileShape.BOX]
		_:
			# GENERIC — старый зелёный ящик.
			return [color_for_type(t), Vector3(0.6, 0.6, 0.6), PileShape.BOX]


func _resolve_visual_params() -> Array:
	var defaults: Array = _defaults_for_type(resource_type)
	var c: Color = pile_color if pile_color != Color.BLACK else defaults[0]
	var s: Vector3 = pile_size if pile_size != Vector3.ZERO else defaults[1]
	var sh: int = int(pile_shape) if pile_shape != PileShape.AUTO else int(defaults[2])
	return [c, s, sh]


func _apply_visual() -> void:
	if _mesh == null:
		return
	var params: Array = _resolve_visual_params()
	var c: Color = params[0]
	var s: Vector3 = params[1]
	var sh: int = params[2]
	var mesh: PrimitiveMesh
	match sh:
		PileShape.CYLINDER:
			var cyl := CylinderMesh.new()
			cyl.top_radius = s.x * 0.5
			cyl.bottom_radius = s.x * 0.5
			cyl.height = s.y
			mesh = cyl
		PileShape.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = s.x * 0.5
			sphere.height = s.y
			mesh = sphere
		_:
			var box := BoxMesh.new()
			box.size = s
			mesh = box
	_mesh.mesh = mesh
	_material = StandardMaterial3D.new()
	_material.albedo_color = c
	_mesh.material_override = _material


func _apply_shape() -> void:
	if _shape == null:
		return
	var params: Array = _resolve_visual_params()
	var s: Vector3 = params[1]
	var sh: int = params[2]
	var shape: Shape3D
	match sh:
		PileShape.CYLINDER:
			var cyl := CylinderShape3D.new()
			cyl.radius = s.x * 0.5
			cyl.height = s.y
			shape = cyl
		PileShape.SPHERE:
			var sphere := SphereShape3D.new()
			sphere.radius = s.x * 0.5
			shape = sphere
		_:
			var box := BoxShape3D.new()
			box.size = s
			shape = box
	_shape.shape = shape


# --- Damageable ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		_dying = true
		destroyed.emit()
		queue_free()


# --- Pushable ---

func apply_push(velocity_change: Vector3, _duration: float) -> void:
	# freeze=true — кучу держит рука; импульс ушёл бы в никуда.
	if freeze:
		return
	apply_central_impulse(velocity_change * mass)


# --- Grabbable (рамка-кандидат) ---

func set_highlighted(value: bool) -> void:
	if not _material:
		return
	if value:
		_material.emission_enabled = true
		_material.emission = highlight_color
		_material.emission_energy_multiplier = highlight_intensity
	else:
		_material.emission_enabled = false


# --- Гномы ---

## Гном забирает 1 единицу. Возвращает true, если получилось.
## Не отдаёт, если кучу сейчас держит рука (freeze=true) — гном считает
## её «занятой» и ищет другую через _on_pile_lost.
func take_one() -> bool:
	if _dying or freeze or units <= 0:
		return false
	units -= 1
	if units == 0:
		_dying = true
		destroyed.emit()
		queue_free()
	return true


## Полное потребление кучи: возвращает все units разом и уничтожает pile.
## Используется когда лагерь засчитывает кучу целиком (бросок рукой в
## anchor-зону). Идемпотентно: повторный вызов на _dying возвращает 0.
##
## В отличие от take_one не проверяет `freeze`: caller сам должен убедиться,
## что рука не держит pile (иначе мы бы вырвали кучу из-под пальцев). Camp
## делает это перед вызовом.
func consume_all() -> int:
	if _dying:
		return 0
	var amount: int = units
	if amount <= 0:
		return 0
	units = 0
	_dying = true
	destroyed.emit()
	queue_free()
	return amount
