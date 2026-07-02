extends RefCounted
## FX «печати» установки здания (2026-07-03): падение с высоты + сквош при приземлении +
## кольцо пыли по футпринту + рябь по гриду + тряска камеры; отдельно — линк-пульс
## «сапорт → продюсер». Подключение preload-константой (const PlaceFx = preload(...)),
## БЕЗ class_name — не трогаем class_cache.
##
## play() зовётся ПОСЛЕ установки финального трансформа здания. Все твины node-bound
## (create_tween на здании/мехе) — умирают вместе с нодой, freed-capture невозможен.
## Сквош через scale КОРНЯ безопасен: проект уже скейлит StaticBody перманентно
## (room_build_site растягивает стены по X) — сквош восстанавливает В базовый scale.

const DROP_HEIGHT := 3.5   # м — высота «впечатывания» рукой
const DROP_TIME := 0.13    # сек падения (ease-in — ускоряясь к земле)
const SQUASH := Vector3(1.12, 0.68, 1.12)  # сплющивание при касании (× к базовому scale)
const SQUASH_TIME := 0.24  # восстановление с овершутом (TRANS_BACK)
const SHAKE := 0.35        # травма камеры (EventBus.camera_shake, falloff по дистанции)
## Грид-голубой — визуальный язык СТРОЙКИ (превью/маркеры слотов), не боя.
const RIPPLE_COLOR := Color(0.55, 0.8, 1.0, 0.7)


## Полный удар установки: падение → приземление (сквош/пыль/рябь/тряска).
## radius — полурадиус футпринта (для ширины пыльного кольца и ряби).
##
## СТЕНЫ: их визуал — top_level-меши (мировые координаты, стыковка рукавов между
## клетками) — трансформ КОРНЯ они игнорируют. Поэтому цели анимации выбираются:
## есть top_level-дети → падают/сквошатся САМИ чанки; нет → корень целиком
## (коллизия едет с ним). Пивот сквоша — пол y=0: position.y × k, единая математика
## для обоих случаев (origin обычного здания на земле → y≈0, не смещается).
static func play(b: Node3D, radius: float) -> void:
	if b == null or not is_instance_valid(b):
		return
	# [node, base_y, base_scale] по каждой цели анимации.
	var bases: Array = []
	for ch in b.get_children():
		if ch is Node3D and (ch as Node3D).top_level:
			var t := ch as Node3D
			bases.append([t, t.global_position.y, t.scale])
	if bases.is_empty():
		bases.append([b, b.global_position.y, b.scale])
	for e in bases:
		(e[0] as Node3D).global_position.y = float(e[1]) + DROP_HEIGHT
	var tw := b.create_tween()
	tw.tween_method(_apply_drop.bind(bases), 1.0, 0.0, DROP_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_land.bind(b, bases, radius))


static func _apply_drop(t: float, bases: Array) -> void:
	for e in bases:
		var node = e[0]
		if node != null and is_instance_valid(node):
			(node as Node3D).global_position.y = float(e[1]) + DROP_HEIGHT * t


static func _land(b: Node3D, bases: Array, radius: float) -> void:
	if b == null or not is_instance_valid(b) or not b.is_inside_tree():
		return
	# Сквош вокруг пола и упругое восстановление (TRANS_BACK даёт овершут k>1 — ок).
	_apply_squash(0.0, bases)
	var tw := b.create_tween()
	tw.tween_method(_apply_squash.bind(bases), 0.0, 1.0, SQUASH_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var root: Node = b.get_tree().current_scene
	var ground: Vector3 = b.global_position
	# Кольцо пыли по краю футпринта: чем крупнее здание, тем больше клубов.
	var n: int = clampi(int(radius * 4.0), 4, 10)
	for i in range(n):
		var a: float = TAU * float(i) / float(n)
		AoeVisual.spawn_dust(root, ground + Vector3(sin(a), 0.0, cos(a)) * radius)
	# Рябь по гриду: два расходящихся кольца со сдвигом — «сетка почувствовала удар».
	AoeVisual.spawn_expanding_ring(root, ground, radius + CityGrid.CELL, 0.3, RIPPLE_COLOR)
	var tw2 := b.create_tween()
	tw2.tween_interval(0.09)
	tw2.tween_callback(_second_ripple.bind(b, ground, radius))
	# Тряска: автолоад берём через /root — не полагаемся на глобальное имя в static-контексте.
	var bus: Node = b.get_node_or_null(^"/root/EventBus")
	if bus != null:
		bus.camera_shake.emit(SHAKE, ground)


## t: 0 (полный сквош) → 1 (базовый вид). Пивот — пол y=0: сжатие по Y тянет
## центр меша вниз пропорционально (top_level-чанк стены стоит серединой на h/2).
static func _apply_squash(t: float, bases: Array) -> void:
	var kx: float = lerpf(SQUASH.x, 1.0, t)
	var ky: float = lerpf(SQUASH.y, 1.0, t)
	for e in bases:
		var node = e[0]
		if node == null or not is_instance_valid(node):
			continue
		var n3 := node as Node3D
		var base_scale: Vector3 = e[2]
		n3.scale = Vector3(base_scale.x * kx, base_scale.y * ky, base_scale.z * kx)
		n3.global_position.y = float(e[1]) * ky


static func _second_ripple(b: Node3D, ground: Vector3, radius: float) -> void:
	if b == null or not is_instance_valid(b) or not b.is_inside_tree():
		return
	var faded := Color(RIPPLE_COLOR.r, RIPPLE_COLOR.g, RIPPLE_COLOR.b, 0.45)
	AoeVisual.spawn_expanding_ring(b.get_tree().current_scene, ground, radius + CityGrid.CELL * 2.0, 0.34, faded)


## Световой импульс «сапорт → продюсер»: сфера летит от from к to и гаснет кольцом у цели.
## Показывает игроку, что установка закрыла грань квартала (см. PadBuilding.flash_quarter_links).
static func link_pulse(root: Node, from: Vector3, to: Vector3, color: Color) -> void:
	if root == null:
		return
	var mesh := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	mesh.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 3.0
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = from + Vector3.UP * 1.2
	var tw := mesh.create_tween()
	tw.tween_property(mesh, "global_position", to + Vector3.UP * 1.2, 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_link_arrive.bind(mesh, to, color))


static func _link_arrive(mesh: MeshInstance3D, to: Vector3, color: Color) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	AoeVisual.spawn_ground_ring(mesh.get_tree().current_scene, Vector3(to.x, 0.0, to.z), 1.1, 0.35, color)
	mesh.queue_free()
