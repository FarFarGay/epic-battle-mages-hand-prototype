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
	add_to_group(Layers.SPARK_TARGET_GROUP)
	# Цель автолута: гном-лутер ЗАРЯЖАЕТСЯ на горшок и разбивает ударом (не proximity).
	add_to_group(Layers.GNOME_STRIKE_TARGET_GROUP)
	# Щит башни (парирование) разбивает кувшины в радиусе. Отдельная группа, НЕ
	# spark_target — иначе щит активировал бы и диоды-пазлы рядом.
	add_to_group(Layers.SHIELD_BREAKABLE_GROUP)


## Контракт strike-цели: лутать горшок может гном с can_loot, но НЕ с занятыми руками
## (несёт бревно — сперва донесёт). «Не лутать с полными руками» — общее правило.
func can_gnome_interact(gnome: Node) -> bool:
	# Контракт принимает Node — читаем роль через get() (не прямой .can_loot), чтобы
	# не падать на юните без этого поля (сегодня бьёт только SoldierGnome, но контракт
	# duck-typed — рядом is_carrying уже защищён has_method).
	if _broken or not bool(gnome.get(&"can_loot")):
		return false
	return not (gnome.has_method(&"is_carrying") and gnome.is_carrying())


## Гном ударил по горшку зарядом (SoldierGnome._strike_at по gnome_strike_target).
func gnome_hit(_gnome: Node = null) -> void:
	if _broken:
		return
	_break()


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
