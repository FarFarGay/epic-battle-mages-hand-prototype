class_name GearElement
extends ArtifactElement
## Древний РЕЦЕПТ Огненного выстрела (сюжет «Верхний Предел»; файл исторически
## gear_element — раньше тут была Шестерня Врат). Лежит в конце лабиринта
## пещеры гномов «под гнома»: башня в проём не пролезает, рука с дистанции не
## дотягивается. Добыча АРТЕЛЬЮ: гном-рабочий, оказавшись рядом (игрок
## командует «Идти сюда» в лабиринт), взваливает свиток на голову и несёт
## КУДА ИДЁТ сам (никакого автопилота — движением рулят обычные команды
## отряда); у башни скидывает. Дальше путь [ArtifactElement]: рука несёт к
## ИНСТИТУТУ МАГИИ → институт изучает рецепт → Кафедра огня доступна в палитре.
##
## Grab / доставка — от [ArtifactElement]; здесь визуал свитка и слой
## «гном-носильщик»: поллинг 0.3с (сигналов «гном дошёл» нет, и они тут
## не нужны — [[feedback_no_redundant_signals]]).

## Радиус, в котором гном-рабочий подхватывает свиток.
@export var pickup_radius: float = 1.8
## Ближе этого до башни носильщик скидывает груз; и подбор запрещён —
## башня рядом значит рука дотянется сама.
@export var tower_drop_radius: float = 7.0
@export var carry_height: float = 1.7

var _carrier: Node3D = null


func _ready() -> void:
	deliver_role = &"magic"
	pickup_hint = "📜 Древний рецепт! Неси в 🔮 ИНСТИТУТ МАГИИ (нет — построй в палитре) — откроет Кафедру огня. Можно положить на крышу башни и везти"
	super()
	mass = 8.0
	var poll := Timer.new()
	poll.wait_time = 0.3
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_poll_carry)


## Свиток-рулон: бумага-цилиндр лёжа + два набалдашника-торца + лента.
## Один материал на всё — highlight красит весь предмет разом.
func _build_visual() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.87, 0.78, 0.58)
	_material.roughness = 0.8
	_material.emission_enabled = true
	_material.emission = Color(1.0, 0.55, 0.2)
	_material.emission_energy_multiplier = 0.9
	var roll := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.22
	cyl.bottom_radius = 0.22
	cyl.height = 1.0
	roll.mesh = cyl
	roll.rotation.z = PI / 2.0
	roll.material_override = _material
	add_child(roll)
	for side in [-1.0, 1.0]:
		var knob := MeshInstance3D.new()
		var kn := CylinderMesh.new()
		kn.top_radius = 0.09
		kn.bottom_radius = 0.09
		kn.height = 0.2
		knob.mesh = kn
		knob.rotation.z = PI / 2.0
		knob.position = Vector3(side * 0.6, 0.0, 0.0)
		knob.material_override = _material
		add_child(knob)
	var ribbon := MeshInstance3D.new()
	var rb := BoxMesh.new()
	rb.size = Vector3(0.14, 0.47, 0.47)
	ribbon.mesh = rb
	ribbon.material_override = _material
	add_child(ribbon)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.3
	shape.height = 1.1
	col.shape = shape
	col.rotation.z = PI / 2.0
	add_child(col)


func _physics_process(_delta: float) -> void:
	if _carrier != null and is_instance_valid(_carrier):
		global_position = _carrier.global_position + Vector3.UP * carry_height


## Пока на голове гнома — в институт не всасываемся (сдаёт рука или сброс у башни).
func _delivery_blocked() -> bool:
	return _carrier != null


## Носильщик: подбор ближайшим гномом-рабочим / сброс у башни.
func _poll_carry() -> void:
	if _held or _delivered:
		return
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if _carrier != null:
		if not is_instance_valid(_carrier):
			_drop()
		elif tower != null and _xz_dist(tower.global_position, global_position) <= tower_drop_radius:
			_drop()
			EventBus.tutorial_hint.emit("Гном донёс рецепт! Хватай рукой и неси в Институт магии", 7.0)
		return
	# Свободен: башня рядом — рука дотянется сама, гномов не дёргаем.
	if tower != null and _xz_dist(tower.global_position, global_position) <= tower_drop_radius:
		return
	var worker := _nearest_worker()
	if worker != null and _xz_dist(worker.global_position, global_position) <= pickup_radius:
		_attach(worker)


func _attach(worker: Node3D) -> void:
	_carrier = worker
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = Layers.MOUNTED_MODULE  # рука видит — можно выхватить с головы
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.8, 6.0)
	EventBus.tutorial_hint.emit("Гном взвалил свиток-рецепт — выведи его к башне", 7.0)


func _drop() -> void:
	_carrier = null
	freeze = false
	collision_layer = Layers.ITEMS


func _nearest_worker() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		var s := n as Node3D
		if s == null or not is_instance_valid(s):
			continue
		if s.get(&"soldier_type") != SoldierSystem.ROLE_WORKER:
			continue
		var d: float = s.global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = s
	return best


## Рука выхватила (в т.ч. с головы носильщика) — гном свободен.
func _on_hand_grabbed(item: Node3D) -> void:
	if item == self:
		_carrier = null
	super(item)


## Институт изучил рецепт → Кафедра огня открыта в палитре (гейт HUD).
func _on_delivered(_receiver: Node3D) -> void:
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	if prof != null and prof.has_method(&"unlock_fire_recipe"):
		prof.call(&"unlock_fire_recipe")
	EventBus.tutorial_hint.emit(
		"📜 Институт изучил древний рецепт! 🔥 Кафедра огня доступна в палитре построек", 8.0)
