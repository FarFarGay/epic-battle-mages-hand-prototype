extends StaticBody3D
## РАЗРУШАЕМАЯ КОЛОННА (ангар, 2026-08-08). Опора свода, которую башня сносит
## ТАРАНОМ: въехал рывком — колонна сложилась. Даёт залу то, чего в нём не было,
## — изменяемую геометрию: укрытия, за которыми прячутся скелеты, и коридоры,
## которые игрок может пробить сам.
##
## ⚙ ПОЧЕМУ ИМЕННО ТАРАН, а не «любой урон». Новых код-путей не заводим: у башни
## УЖЕ есть `_dash_try_damage_structures` — sphere-query по слою
## DESTRUCTIBLE_DECK каждый физкадр рывка, который бьёт всё Damageable на пути
## (написан для настилов-мостков). Колонна просто встаёт на тот же слой и
## попадает в него бесплатно. Заклинания её не берут намеренно: ломать зал —
## глагол КОРПУСА, а не магии, и читается он однозначно.
##
## ⚙ ДВА СЛОЯ. ITEMS — чтобы колонна была ФИЗИЧЕСКИМ препятствием (маска башни
## включает ITEMS, MASK_SKELETON тоже: башня упирается, скелеты прячутся).
## DESTRUCTIBLE_DECK — чтобы её нашёл свип рывка. Одно без другого не работает:
## на одном ITEMS рывок её не увидит, на одном DECK сквозь неё будут проходить.
##
## ⚙ ФЛОУ-ФИЛД НЕ ТРОГАЕМ. Он растеризует TERRAIN | WALL_GATE_BLOCK, колонны туда
## не входят — значит их снос не требует refresh_around, и поле не пересчитывается
## посреди боя. Скелеты обтекают колонны телом (боидами и коллизией), а не полем.

## Прочность. 120 = обычный таран (dash_damage 100) сносит с ДВУХ въездов,
## любой супер-рывок (130 без заряда / 250 заряженный) — с одного.
@export var hp: float = 120.0
## Цвет осколков и вспышки. Держим в @export, чтобы колонны разных залов могли
## отличаться, не заводя второго скрипта.
@export var debris_color: Color = Color(0.34, 0.33, 0.38, 1.0)

var _mesh: MeshInstance3D = null
var _mat: StandardMaterial3D = null
var _dead: bool = false


func _ready() -> void:
	collision_layer = Layers.ITEMS | Layers.DESTRUCTIBLE_DECK
	collision_mask = 0
	# Без damageable-группы try_damage молча проигнорирует колонну (ловушка, на
	# которой уже обжигался щит артели: бессмертный объект без единой ошибки).
	add_to_group(Damageable.GROUP)
	_mesh = get_node_or_null(^"Mesh") as MeshInstance3D
	if _mesh != null and _mesh.material_override is StandardMaterial3D:
		# Материал общий на все колонны — дублируем на инстанс, иначе вспышка
		# от удара по одной зажгла бы разом весь зал.
		_mat = (_mesh.material_override as StandardMaterial3D).duplicate()
		_mesh.material_override = _mat


func take_damage(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	hp -= amount
	if _mat != null:
		_mat.emission_enabled = true
		_mat.emission = Color(1.0, 0.85, 0.6)
		_mat.emission_energy_multiplier = 1.8
		var tw := create_tween()
		tw.tween_property(_mat, "emission_energy_multiplier", 0.0, 0.3)
	if hp <= 0.0:
		_collapse()


## Обвал. Урона по площади НЕТ намеренно: «взрыв, который бьёт всех» — это язык
## пороховой бочки, и один визуальный язык должен значить одно. Колонна просто
## складывается: пыль, осколки, толчок камерой.
func _collapse() -> void:
	if _dead:
		return
	_dead = true
	# Из групп СРАЗУ, до queue_free: тот отложен до конца кадра, и свип рывка
	# успел бы ударить уже мёртвую колонну второй раз.
	remove_from_group(Damageable.GROUP)
	var p: Vector3 = global_position
	var root: Node = get_tree().current_scene
	if root != null:
		ShatterEffect.spawn(root, p + Vector3.UP * 1.2, debris_color, 14, 1.8)
		AoeVisual.spawn_dust(root, Vector3(p.x, 0.05, p.z))
	EventBus.camera_shake.emit(0.35, p)
	queue_free()
