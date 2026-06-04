class_name Campfire
extends Node3D
## Маленький костёр у палатки — flavor-объект «жизни лагеря». Спавнится
## [Camp] при развёртке (по одному на палатку), стоит UNLIT, пока назначенный
## гном-разжигатель (Gnome.IdleRole.FIRE_TENDER) не дойдёт и не вызовет [light].
##
## Дрова (Logs) видны всегда; пламя (партиклы + свет) включается в lit-состоянии.
## Партиклы — инстанс scenes/camp_fire_particles.tscn, уменьшенный scale'ом ноды
## (оригинал крупный, используется как самостоятельный FX в других местах —
## его не трогаем, подгоняем размер локально здесь).
##
## Слоты вокруг костра считает Camp (_fire_slot_positions), не сам Campfire —
## единый источник истины по расстановке, как и ring палаток.

## Узлы пламени. Опциональны: если в сцене их нет, lit-toggle — no-op (костёр
## останется визуально «дрова», без краша). Партиклы — ОДНОРАЗОВЫЙ всполох в
## момент поджога (one_shot в сцене), постоянное «горение» — только мягкое
## свечение FireLight (не сыплем искрами всё время).
@onready var _particles: GPUParticles3D = get_node_or_null("CampFireParticles") as GPUParticles3D
@onready var _light: OmniLight3D = get_node_or_null("FireLight") as OmniLight3D

var _lit: bool = false


func _ready() -> void:
	# Старт всегда UNLIT — пламя зажигает гном из фазы LIGHTING.
	set_lit(false)


func is_lit() -> bool:
	return _lit


## Зажечь костёр. Идемпотентно. Зовётся Gnome'ом-разжигателем по завершении
## фазы LIGHTING.
func light() -> void:
	set_lit(true)


func set_lit(value: bool) -> void:
	_lit = value
	# Свет — постоянное «лёгкое свечение», пока костёр зажжён.
	if _light != null:
		_light.visible = value
	# Партиклы — один короткий всполох в момент поджога (one_shot). Гасим при
	# unlit, чтобы при повторном зажигании всполох сыграл заново.
	if _particles != null:
		if value:
			_particles.restart()
			_particles.emitting = true
		else:
			_particles.emitting = false
