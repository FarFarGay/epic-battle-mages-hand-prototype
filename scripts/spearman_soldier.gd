class_name SpearmanSoldier
extends SoldierGnome
## Гарнизонный копейщик казармы-стены: стоит на ФИКС-посту своей клетки (на боевом ходу, высота
## _WALL_H) и колет ближайшего скелета в attack_range С МЕСТА — не гонится. За башней (escort по F)
## ведёт себя как ОБЫЧНЫЙ копейщик (super._physics_process). Зеркало гарнизона лучника, но без
## маршрутов по стенам: один фикс-пост на клетку + melee вместо стрельбы.

var _post_assigned: bool = false
var _post: Vector3 = Vector3.ZERO        # абсолютный пост на верху клетки (PadBuilding.cell_top)
var _post_cell: Vector2i = Vector2i.ZERO # клетка поста (детект сноса опоры — казарму снесли → падаем)
var _post_ground_y: float = 0.0          # земля у казармы (плавный спуск при снятии)
var _post_active: bool = false
var _spear_skinned: bool = false

## Скорость БЕГА обратно на пост (как лучник wall_return_speed) — не плестись от башни к стене.
const GARRISON_RETURN_SPEED := 6.0


## Блочная моделька гнома-копейщика (по образцу лучника, но с КОПЬЁМ и красной одеждой) вместо
## голой капсулы. Прячем капсулу, лепим тело/голову/древко/наконечник. Гард — один раз.
func _apply_visual() -> void:
	if _spear_skinned:
		return
	_spear_skinned = true
	if _mesh != null:
		_mesh.visible = false
	var holder := Node3D.new()
	holder.position = Vector3(0, -0.4, 0)  # капсула центрирована в origin — опускаем «ноги»
	add_child(holder)
	var cloth := _spear_mat(Color(0.72, 0.3, 0.26))  # красный — копейщики
	var skin := _spear_mat(Color(0.85, 0.7, 0.55))
	var wood := _spear_mat(Color(0.3, 0.2, 0.12))
	var steel := _spear_mat(Color(0.72, 0.74, 0.8))
	_spear_box(holder, Vector3(0.34, 0.5, 0.26), Vector3(0, 0.45, 0), cloth)        # тело
	_spear_box(holder, Vector3(0.26, 0.26, 0.24), Vector3(0, 0.82, 0), skin)        # голова
	_spear_box(holder, Vector3(0.05, 1.2, 0.05), Vector3(0.24, 0.66, 0), wood)      # древко копья (выше лука)
	_spear_box(holder, Vector3(0.09, 0.22, 0.09), Vector3(0.24, 1.32, 0), steel)    # стальной наконечник


func _spear_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


func _spear_box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## Казарма назначает пост (одна клетка) этому копейщику. Зовётся из PadBuilding._assign_spear_garrison.
func assign_post(post: Vector3, cell: Vector2i, ground_y: float) -> void:
	_post_assigned = true
	_post = post
	_post_cell = cell
	_post_ground_y = ground_y


## Гарнизоним, только когда отряд в МЯГКОМ hold (дефолт казармы). escort (F) / strict-move → мобилка.
func _grn_should_garrison() -> bool:
	return _post_assigned and _squad != null \
		and _squad.state == Squad.State.HOLDING_POSITION and not _squad.is_strict_move()


func _physics_process(delta: float) -> void:
	if _grn_should_garrison() and _post_cell_walkable():
		_post_active = true
		_garrison_stab(delta)
		return
	# Сошли с поста (escort / снесли казарму под ногами) — плавный спуск к земле ПРЯМЫМ
	# управлением (не зависаем в воздухе), потом штатная мобилка SoldierGnome.
	if _post_active:
		if global_position.y > _post_ground_y + 0.15:
			global_position.y = lerp(global_position.y, _post_ground_y, 1.0 - exp(-10.0 * delta))
			velocity = Vector3.ZERO
			return
		_post_active = false
	super._physics_process(delta)


## Опора цела? Клетка поста в walkable-сети (is_wall/gate/barracks). Снесли казарму → выпадаем из неё.
func _post_cell_walkable() -> bool:
	var tree := get_tree()
	return tree != null and PadBuilding.walkable_set(tree).has(_post_cell)


## Стоим на посту и колем ближайшего скелета в attack_range С МЕСТА (3D-дистанция — достаёт скелетов
## у основания стены). Переиспользуем штатные _find_target_in_leash (поиск+claim) и _strike_at (удар).
func _garrison_stab(delta: float) -> void:
	# Прятались в башне? Выходим (иначе остаёмся visible=false на посту — «закис в башне»).
	_exit_hidden()
	velocity = Vector3.ZERO
	if _attack_cd > 0.0:
		_attack_cd -= delta
	# Встаём на пост: XZ к посту, Y лерпом к высоте боевого хода. Возврат на пост — БЫСТРО (как
	# лучник), на месте — спокойно. «returning» = далеко по XZ или ниже поста (бежим от башни/снизу).
	var flat := Vector3(_post.x - global_position.x, 0.0, _post.z - global_position.z)
	var fd: float = flat.length()
	var returning: bool = fd > 0.4 or global_position.y < _post.y - 0.3
	var speed: float = GARRISON_RETURN_SPEED if returning else move_speed
	if fd > 0.06:
		global_position += (flat / fd) * speed * delta
	global_position.y = lerp(global_position.y, _post.y, 1.0 - exp(-9.0 * delta))
	# Ближайший скелет (тот же путь, что у мобильного копейщика) → укол с места, если в радиусе.
	var foe: Node3D = _find_target_in_leash()
	if foe == null or not is_instance_valid(foe):
		return
	var to: Vector3 = foe.global_position - global_position
	var tf := Vector3(to.x, 0.0, to.z)
	if tf.length() > 0.001:
		look_at(global_position + tf, Vector3.UP)
	if to.length() <= attack_range and _attack_cd <= 0.0:
		_strike_at(foe)
		_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
