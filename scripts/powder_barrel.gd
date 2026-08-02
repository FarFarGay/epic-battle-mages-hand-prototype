extends StaticBody3D
## Пороховая бочка мастерской (К3 интро). Damageable-контракт: копит урон от
## ЛЮБОГО источника (стрелы полива, вал, супер, взрыв соседки) и по нулю HP
## эмитит exploded — сам AOE-взрыв (урон всем, цепь, флоу-рефреш) делает
## владелец-сцена (dungeon_sandbox._on_barrel_exploded), бочка мира не знает.
##
## Слой TERRAIN сознательно: скелеты и гномы упираются, стрелы втыкаются
## (свип-луч Arrow метёт TERRAIN), вал разбивается об неё, LOS-прицел полива
## клампится к бочке — «стреляй в бочку» появляется без единого спец-кейса.

signal damaged(amount: float)
signal destroyed
signal exploded(pos: Vector3)

@export var hp: float = 8.0

var _dead: bool = false


func _ready() -> void:
	Damageable.register(self)
	add_to_group(&"powder_barrel")


func take_damage(amount: float) -> void:
	if _dead:
		return
	hp -= amount
	damaged.emit(amount)
	if hp > 0.0:
		return
	_dead = true
	# Из групп СРАЗУ, до эмитов: queue_free отложен до конца кадра, а цепные
	# взрывы уже сканируют группы этим же кадром (паттерн _die + queue_free).
	remove_from_group(Damageable.GROUP)
	remove_from_group(&"powder_barrel")
	destroyed.emit()
	exploded.emit(global_position)
	queue_free()
