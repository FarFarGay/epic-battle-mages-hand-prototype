class_name ArtelShield
extends StaticBody3D
## Щит-блок артельщика (WASD-группа в данж-песочнице): по ПКМ встаёт между
## группой и курсором. Ломаемый — скелеты-мили видят его (TARGET_GROUP +
## MELEE_ONLY_TARGET_GROUP) и грызут; hp кончилось → осколки и снос. Дальники
## (melee_only-щит) его игнорируют — как палисад. Тело = сам StaticBody:
## AOE/скелеты бьют ПО КОЛЛАЙДЕРУ, damageable обязан быть физтелом.

signal destroyed

var hp: float = 120.0
var _mesh: MeshInstance3D = null
var _mat: StandardMaterial3D = null
var _dead: bool = false


## Собирает щит кодом (плашка size, слой ITEMS — скелеты упираются, гномы и
## рука проходят по своим маскам). Регистрация в target-группах — сразу.
func setup(size: Vector3, shield_hp: float) -> void:
	hp = shield_hp
	collision_layer = Layers.ITEMS
	collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	add_child(cs)
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.55, 0.42, 0.22, 1)
	_mat.roughness = 0.7
	_mat.emission_enabled = true
	_mat.emission = Color(0.9, 0.7, 0.3)
	_mat.emission_energy_multiplier = 0.0
	var bm := BoxMesh.new()
	bm.size = size
	_mesh = MeshInstance3D.new()
	_mesh.mesh = bm
	_mesh.material_override = _mat
	add_child(_mesh)
	add_to_group(Enemy.TARGET_GROUP)
	add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	# Без damageable-группы Damageable.try_damage игнорирует щит — скелеты
	# грызли бы вечную стенку.
	add_to_group(Damageable.GROUP)


func take_damage(amount: float) -> void:
	if _dead:
		return
	hp -= amount
	# Хит-вспышка эмиссией — читаемый «по щиту бьют» без отдельного FX-стека.
	if _mat != null:
		_mat.emission_energy_multiplier = 1.6
		var tw := create_tween()
		tw.tween_property(_mat, "emission_energy_multiplier", 0.0, 0.25)
	if hp <= 0.0:
		_die()


func _die() -> void:
	if _dead:
		return
	_dead = true
	# Из групп — СРАЗУ (queue_free отложен до конца кадра: иначе скелеты и AoE
	# ещё кадр видят «живую» цель в группах).
	remove_from_group(Enemy.TARGET_GROUP)
	remove_from_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	remove_from_group(Damageable.GROUP)
	destroyed.emit()
	ShatterEffect.spawn(get_parent(), global_position + Vector3.UP * 0.6,
			Color(0.55, 0.42, 0.22, 1))
	queue_free()
