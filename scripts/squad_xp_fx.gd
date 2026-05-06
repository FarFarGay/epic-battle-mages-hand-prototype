extends Node
## Координатор визуального фидбэка squad XP. Держит:
##  - popup'ы «+10» (когда орб дошёл до anchor'а и зачислил XP);
##  - kill-trail-частицы (этап 49) — на смерть скелета мини-орб летит к
##    ближайшему живому защитнику и гаснет на нём. Чисто визуальный flavor:
##    «энергия от трупа → стрелок». XP при этом идёт через `XpOrb` (gameplay),
##    trail XP не несёт.
##
## Регистрируется как autoload — глобальный слушатель EventBus. Autoload
## парсится до глобального class_name-registry, поэтому SquadXpPopup
## подгружаем явным `preload` (не через class_name).
##
## Сами popup'ы и trail'ы — Node3D в дереве `current_scene`, не потомки
## этого autoload'а (тот не Node3D, не имеет world transform).

const SquadXpPopupScene = preload("res://scripts/squad_xp_popup.gd")

## Длительность полёта trail-частицы от трупа к защитнику. Короче — теряется
## в визуальном шуме волны; длиннее — частицы накапливаются на экране.
const KILL_TRAIL_DURATION: float = 0.45
## Радиус поиска защитника от позиции трупа. ≈ DefenderGnome.attack_radius (22.5)
## с запасом — если ни одного защитника в зоне «логического кила» нет, trail
## не спавним (skeleton мог быть убит slam'ом руки игрока, частица «в никуда»
## выглядит ложно). 25² = 625, проверка через length_squared.
const KILL_TRAIL_SEARCH_RADIUS_SQ: float = 25.0 * 25.0
## Высота над трупом, откуда стартует частица — иначе она вылезает из-под пола
## (труп в момент destroyed.emit ещё на ground.y, но частице нужно «над»).
const KILL_TRAIL_SOURCE_OFFSET_Y: float = 0.5

## Shared material для всех trail-частиц — один экземпляр на весь проект,
## батчится GPU. Лениво создаётся в первом spawn'е.
static var _trail_material: StandardMaterial3D
## Shared mesh для trail'ов — тоже один на всех. SphereMesh маленького размера
## с emissive золотом, читается как «искорка XP».
static var _trail_mesh: SphereMesh


func _ready() -> void:
	EventBus.squad_xp_gained_at.connect(_on_xp_gained)
	EventBus.enemy_destroyed.connect(_on_enemy_destroyed)


func _on_xp_gained(amount: int, world_position: Vector3) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var popup = SquadXpPopupScene.new()
	popup.text = "+%d" % amount
	scene.add_child(popup)
	popup.global_position = world_position


## Скелет умер — спавним маленькую trail-частицу от трупа к ближайшему
## живому защитнику. Только visual; XP идёт отдельно через `XpOrb`.
##
## Если защитника в радиусе 25м нет — пропускаем спавн. Это значит скелета
## убил не лучник (slam, flick, magic), и trail «в никого» выглядел бы
## странно. У slam'а свой визуал, у flick'а свой — лишнего feedback'а не надо.
func _on_enemy_destroyed(enemy: Node3D) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var defender := _nearest_defender_to(enemy.global_position)
	if defender == null:
		return
	_spawn_kill_trail(scene, enemy.global_position, defender.global_position)


## Ищем ближайшего живого защитника в `KILL_TRAIL_SEARCH_RADIUS_SQ` от точки
## смерти. Группа `DefenderGnome.DEFENDER_GROUP` уже поддерживается лучниками
## в _ready (см. defender_gnome.gd). Возвращает null если никого в радиусе.
func _nearest_defender_to(pos: Vector3) -> DefenderGnome:
	var nearest: DefenderGnome = null
	var nearest_d_sq := KILL_TRAIL_SEARCH_RADIUS_SQ
	for d in get_tree().get_nodes_in_group(DefenderGnome.DEFENDER_GROUP):
		if not is_instance_valid(d):
			continue
		var df := d as DefenderGnome
		if df == null:
			continue
		var d_sq: float = (df.global_position - pos).length_squared()
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = df
	return nearest


## Маленький MeshInstance3D с tween'ом global_position от source к target.
## По завершении queue_free. Snapshot target-позиции при создании — если
## защитник убежит/умрёт mid-flight, частица всё равно долетит до точки
## (визуально не критично, частица гаснет в любом месте за 0.45с).
func _spawn_kill_trail(scene: Node, from: Vector3, to: Vector3) -> void:
	_ensure_trail_assets()
	var trail := MeshInstance3D.new()
	trail.mesh = _trail_mesh
	trail.material_override = _trail_material
	scene.add_child(trail)
	trail.global_position = from + Vector3.UP * KILL_TRAIL_SOURCE_OFFSET_Y

	var tween := trail.create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(trail, "global_position", to, KILL_TRAIL_DURATION).set_ease(Tween.EASE_IN)
	tween.tween_callback(trail.queue_free)


static func _ensure_trail_assets() -> void:
	if _trail_mesh == null:
		var sphere := SphereMesh.new()
		sphere.radius = 0.1
		sphere.height = 0.2
		sphere.radial_segments = 8
		sphere.rings = 4
		_trail_mesh = sphere
	if _trail_material == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.85, 0.3)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.7, 0.2)
		mat.emission_energy_multiplier = 2.0
		_trail_material = mat
