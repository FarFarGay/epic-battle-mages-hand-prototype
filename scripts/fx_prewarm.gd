extends Node
## Прогрев FX-пайплайнов на загрузке уровня. Godot компилит пайплайн материала/
## партиклов при ПЕРВОМ рендере — отсюда лаг-хитч на первом выстреле/дэше. Спавним
## каждый визуал способностей раз ПОД полом у точки старта: объект в frustum камеры
## (draw-call выдаётся → пайплайн компилится), но перекрыт землёй по глубине →
## невидимо. Держим несколько кадров (GPU успевает скомпилить), затем удаляем.
##
## Покрывает: GPU-Trail снарядов (spark/fireball/frost), процедурные AOE-материалы
## (кольцо-телеграф, искры-пульс), аддитивный материал dash-призрака.

## Под полом у старта башни (пол сверху на y≈0): в кадре, но перекрыт землёй.
const WARM_POS := Vector3(0.0, -3.0, 0.0)
const BOLT_SCENES: Array = [
	preload("res://scenes/spark_bolt.tscn"),
	preload("res://scenes/fireball.tscn"),
	preload("res://scenes/frost_bolt.tscn"),
]
## Сколько кадров держать визуалы в кадре, чтобы GPU успел скомпилить пайплайны.
const WARM_FRAMES := 6


func _ready() -> void:
	_prewarm()


func _prewarm() -> void:
	# На _ready сцена ещё «busy setting up children» — ждём кадр перед add_child.
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var temps: Array[Node] = []
	# Снаряды с GPU-Trail: логику ГЛУШИМ (не летят/не взрываются — иначе урон у
	# старта), Trail сам рендерится GPU-side → пайплайн партиклов компилится.
	for ps in BOLT_SCENES:
		if ps == null:
			continue
		var b := (ps as PackedScene).instantiate() as Node3D
		if b == null:
			continue
		scene.add_child(b)
		b.set_process(false)
		b.set_physics_process(false)
		b.global_position = WARM_POS
		for child in b.get_children():
			if child is GPUParticles3D:
				(child as GPUParticles3D).emitting = true
		temps.append(b)
	# Процедурные AOE-материалы (самоудаляются по duration).
	AoeVisual.spawn_ground_ring(scene, WARM_POS, 1.0, 0.3)
	AoeVisual.spawn_pulse_sparks(scene, WARM_POS, 1.0, 5.0)
	# Dash-призрак (аддитивный alpha-unshaded) на временном меше.
	var dummy := MeshInstance3D.new()
	dummy.mesh = BoxMesh.new()
	scene.add_child(dummy)
	dummy.global_position = WARM_POS
	temps.append(dummy)
	DashFx.spawn_ghost(scene, dummy, Vector3.RIGHT)
	# Держим в кадре несколько кадров → GPU компилит пайплайны, затем чистим.
	for _i in range(WARM_FRAMES):
		await get_tree().process_frame
		if not is_inside_tree():
			return
	for t in temps:
		if is_instance_valid(t):
			t.queue_free()
