class_name MetalDoor
extends StaticBody3D
## Металлическая дверь: дэш её НЕ берёт (не в группе room_door, шаттер игнорирует).
## Открывается активацией механизма — [SparkDiode] ловит попадание Искрой и зовёт
## [open], дверь СЪЕЗЖАЕТ ВНИЗ в пол, проём открывается (rebake навмеша). Одноразово.

const NAVMESH_SOURCE_GROUP := &"navmesh_source"
const NAV_GROUP := &"nav_region"

## На сколько метров уехать вниз. Дверь 3м высотой (низ на y=0) → 3.4 уводит её
## целиком под пол.
@export var slide_depth: float = 3.4
## Длительность съезда (сек).
@export var slide_duration: float = 1.0

var _opening: bool = false


## Унифицированный «активировать» для катализаторов (SparkDiode/Lever зовут activate).
func activate() -> void:
	open()


## Открыть дверь: убрать с навмеша, съехать вниз, перепечь навмеш. Идемпотентно.
func open() -> void:
	if _opening:
		return
	_opening = true
	# НЕ снимаем с навмеша сразу: коллайдер физически стоит в проёме всю секунду
	# съезда, а rebake асинхронный — если за этот кадр сработает ЧУЖОЙ rebake (спарк
	# второго диода / достройка моста рядом), он перепёк бы навмеш с «открытым» проёмом,
	# пока дверь ещё блокирует → агенты утыкаются в невидимую дверь. Снимаем с группы
	# СИНХРОННО в _rebake_nav (t=slide_duration), когда дверь уже уехала под пол —
	# состояние навмеша и физического коллайдера всегда согласованы.
	var tween := create_tween()
	tween.tween_property(self, "position:y", position.y - slide_depth, slide_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_rebake_nav)


func _rebake_nav() -> void:
	if is_in_group(NAVMESH_SOURCE_GROUP):
		remove_from_group(NAVMESH_SOURCE_GROUP)
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		nav.rebake()
