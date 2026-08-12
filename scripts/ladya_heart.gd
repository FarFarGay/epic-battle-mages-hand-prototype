class_name LadyaHeart
extends ArtifactElement
## ⭐ СЕРДЦЕ ЛАДЬИ — КЛЮЧ К ФИНАЛУ УРОВНЯ (пивот 2026-08-12).
##
## Лежит в РАЗБИТОЙ БАШНЕ посреди поля — чужой Ладье не повезло дойти. Гномы
## выковыривают сердце и несут к своей: приёмник — САМА БАШНЯ, как у свитка
## огня ([GearElement]), потому что сердце принадлежит машине, а не городу.
##
## ⚠ ЧЕМ ЭТО БЫЛО РАНЬШЕ. До пивота финал открывался ПЛАТОЙ Вратам (900🥉,
## копи и кликни по плите). Плата ушла: деньги стали валютой уровня, а ключом
## к финалу стал предмет, за которым надо СХОДИТЬ. Причина простая — накопить
## можно сидя на месте, а сходить нельзя; выход из уровня обязан быть вылазкой,
## а не таймером казны.
##
## Дальше цепочка уже готовая и не менялась: сердце доставлено → [GateRuin]
## просыпается → предупреждение → мех-страж (соло-дуэль, СТРОГО один) +
## финальная осада со всех сторон → страж пал → створ уезжает вниз → башня в
## проёме = победа акта.
##
## Grab, переноска гномом и доводка-всасывание — от [ArtifactElement]; здесь
## только визуал, приёмник и то, что происходит на доставке.

## Радиус, в котором гном-рабочий подхватывает сердце (как у свитка).
@export var pickup_radius: float = 1.8
## Ближе этого до башни носильщик скидывает груз — и подбор запрещён: башня
## рядом значит рука дотянется сама.
@export var tower_drop_radius: float = 7.0
@export var carry_height: float = 1.7

var _carrier: Node3D = null


func _ready() -> void:
	super()
	deliver_radius = tower_drop_radius
	if pickup_hint.is_empty():
		pickup_hint = "Сердце Ладьи. Донеси его до башни — механизм Врат откликнется на живое ядро"
	_build_visual()


## Приёмник — САМА БАШНЯ: сердце принадлежит машине, а не городу.
func _nearest_receiver() -> Node3D:
	return get_tree().get_first_node_in_group(&"tower") as Node3D


## Сердце в башне → Врата просыпаются. Саму цепочку финала (страж + осада +
## створ) ведёт [GateRuin]: тут мы только дёргаем её за тот же рычаг, за
## который раньше дёргала оплата.
func _on_delivered(_receiver: Node3D) -> void:
	var gate := get_tree().get_first_node_in_group(GateRuin.GROUP)
	if gate != null and gate.has_method(&"awaken_by_heart"):
		gate.call(&"awaken_by_heart")
	else:
		# Врат на сцене нет (дев-запуск/песочница) — молчать нельзя, иначе
		# выглядит как «предмет съелся впустую».
		EventBus.tutorial_hint.emit("Сердце установлено, но Врат поблизости нет", 4.0)


## Визуал — код, а не сцена: сердце должно читаться СИЛУЭТОМ и пульсом даже
## на плейсхолдере (гранёное ядро + свечение), а точную модель подменим позже
## через material_override, как остальные находки.
func _build_visual() -> void:
	var core := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.34
	mesh.height = 0.68
	mesh.radial_segments = 6
	mesh.rings = 3
	core.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.35, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.15)
	mat.emission_energy_multiplier = 2.4
	core.material_override = mat
	add_child(core)
	# Пульс «живого ядра»: то, ради чего игрок вообще заметит предмет в руинах.
	var tw := create_tween().set_loops()
	tw.tween_property(mat, "emission_energy_multiplier", 4.2, 0.8) \
		.set_trans(Tween.TRANS_SINE)
	tw.tween_property(mat, "emission_energy_multiplier", 2.0, 0.8) \
		.set_trans(Tween.TRANS_SINE)
