extends Area3D
## Горшок: разбивается от контакта башни (включая «пройти над ним» — Area ловит
## тело башни по её слою). Сам без коллизии (collision_layer=0) → башня проходит
## свободно, Area только детектит. На разбитии — осколки (ShatterEffect) + монеты
## (XpOrb с gold-payload), которые башня вакуумит магнитом и кладёт золото в GoldBank.

const COIN_SCENE := preload("res://scenes/xp_orb.tscn")

@export var coin_count: int = 3
@export var gold_per_coin: int = 10
@export var shatter_color: Color = Color(0.62, 0.42, 0.26)
@export var shatter_fragments: int = 10
## Разброс монет по XZ от центра горшка.
@export var coin_scatter: float = 0.7

var _broken: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	# Искра (и прочие spark-механизмы) бьёт по горшку — тот же контракт, что у диода.
	add_to_group(&"spark_target")


## Попадание Искрой (SparkBolt._notify_spark_targets в impact_radius) — разбиваем.
func on_spark() -> void:
	_break()


func _on_body_entered(body: Node) -> void:
	if _broken:
		return
	if not body.is_in_group(Tower.GROUP):
		return
	_break()


func _break() -> void:
	_broken = true
	var scene := get_tree().current_scene
	if scene == null:
		return
	ShatterEffect.spawn(scene, global_position + Vector3.UP * 0.3, shatter_color, shatter_fragments, 1.2)
	for i in range(coin_count):
		var coin := COIN_SCENE.instantiate() as XpOrb
		if coin == null:
			continue
		coin.mana_amount = 0.0
		coin.gold_amount = gold_per_coin
		# position ДО add_child: XpOrb._ready ловит _base_y из global_position.
		coin.position = global_position + Vector3(
			randf_range(-coin_scatter, coin_scatter), 0.5, randf_range(-coin_scatter, coin_scatter))
		scene.add_child(coin)
	queue_free()
