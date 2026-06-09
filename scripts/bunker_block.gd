class_name BunkerBlock
extends BuildBlock
## Защитный блиндаж — грид-здание в 1 ячейку со встроенным лучником. На постройке
## внутрь спавнится ТУРЕЛЬ (ArcherPost, embedded=true), направленная НАРУЖУ от
## ядра: лучник стреляет конусом по врагам, конус медленно сканирует сектор.
## Характеристики лучника — дефолты ArcherPost (= стрелковый пост). HP/коллизию/
## навмеш держит сам блиндаж (BuildBlock); турель — только стрельба/обзор.
##
## Визуал v1 — переиспользует вышку ArcherPost (тело-меш блиндажа скрываем). При
## желании заменить на модель-блиндаж — поле "model" в каталоге как у генератора,
## но турели нужно поведение, поэтому пока это ArcherPost-инстанс.

const ARCHER_POST_SCENE: PackedScene = preload("res://scenes/archer_post.tscn")

var _turret: ArcherPost = null


func _activate_combat() -> void:
	super._activate_combat()  # блиндаж = Damageable + skeleton_target + препятствие/навмеш-carve
	_spawn_turret()


## Встроить лучника-турель: ArcherPost (embedded) у центра блиндажа, лицом НАРУЖУ
## от ядра. look_at(ядро) уже применён на установке → +Z (basis.z) смотрит ПРОЧЬ
## от ядра = направление огня. Тело-меш блиндажа скрываем — визуал = турель.
func _spawn_turret() -> void:
	if _turret != null and is_instance_valid(_turret):
		return
	var post := ARCHER_POST_SCENE.instantiate() as ArcherPost
	if post == null:
		push_warning("BunkerBlock: archer_post.tscn не инстанцируется как ArcherPost")
		return
	post.embedded = true  # турель: без своего таргета/коллизии (держит блиндаж)
	# НАПРАВЛЕНИЕ ОГНЯ — наружу от ядра. Читаем basis.z блиндажа (он повёрнут
	# look_at(ядро) → -Z к ядру, +Z прочь) ДО add_child, в МИРОВЫХ координатах.
	var outward: Vector3 = global_transform.basis.z
	outward.y = 0.0
	if outward.length_squared() < 0.0001:
		outward = Vector3.FORWARD
	add_child(post)
	_turret = post
	# Снимаем УНАСЛЕДОВАННУЮ от блиндажа ротацию (он повёрнут к ядру): ArcherPost.
	# setup ставит yaw головы в МИРОВЫХ координатах, а применяется он локально в
	# фрейме родителя. Без сброса повёрнутый фрейм блиндажа разворачивал лучника
	# обратно В ГОРОД. global_rotation=0 → локальный yaw головы = мировой.
	post.global_rotation = Vector3.ZERO
	var camp := get_tree().get_first_node_in_group(&"camp") as Camp
	# Турель ставим на ЗЕМЛЮ ячейки: origin блиндажа поднят на mount_lift=height/2.
	var ground := Vector3(global_position.x, global_position.y - mount_lift, global_position.z)
	post.setup(ground, outward, camp)
	# Блиндаж — обычный СЕКТОР-БЛОК (как все грид-здания, _mesh виден). Из поста
	# прячем вышку (нога+платформа) и сажаем лучника на ВЕРХ блока.
	_dress_turret_as_bunker(post)


## Визуал блиндажа: тело = сектор-блок (видимый _mesh, как у прочих зданий), а
## ArcherPost редуцируем до лучника на крыше — прячем вышку (PostLeg/Platform) и
## опускаем Head с 2.5м на верх блока (=height над землёй); конус-визуал (смещён
## в _build_cone_visual на -2.44 под старую высоту головы) возвращаем на землю.
func _dress_turret_as_bunker(post: ArcherPost) -> void:
	for n in ["PostLeg", "Platform"]:
		var m := post.get_node_or_null(n) as Node3D
		if m != null:
			m.visible = false
	var head := post.get_node_or_null("Head") as Node3D
	if head != null:
		head.position.y = height  # верх блока над землёй (origin на mount_lift=height/2)
		var cone := head.get_node_or_null("ConeVisual") as Node3D
		if cone != null:
			cone.position.y = 0.06 - height  # конус-веер обратно на землю (~0.06м)
