extends Node3D
## Дерево — источник брёвен для стройки моста. Рабочий-гном (роль &"worker")
## ЗАРЯЖАЕТСЯ на него и рубит УДАРОМ (gnome_hit) — единая модель «гном → точка →
## действие» (как горшок/рычаг). Каждый удар выдаёт рабочему одно БРЕВНО (если руки
## свободны) и тратит запас. Кончился запас — дерево выходит из strike-группы (срублено,
## остаётся пенёк). Визуал (ствол/крона) — узлы сцены (Trunk/Foliage), скрипт = поведение.

const GNOME_STRIKE_GROUP := &"gnome_strike_target"
const WORKER_ROLE := &"worker"

## Сколько брёвен можно нарубить. Для моста нужно ~planks_needed; ставим с запасом.
@export var wood_remaining: int = 16

var _initial_wood: int = 16
@onready var _foliage: Node3D = get_node_or_null(^"Foliage")
@onready var _trunk: Node3D = get_node_or_null(^"Trunk")


func _ready() -> void:
	_initial_wood = maxi(wood_remaining, 1)
	if wood_remaining > 0:
		add_to_group(GNOME_STRIKE_GROUP)


## Контракт strike-цели: рубить дерево может только рабочий со свободными руками
## (гружёный сперва донесёт бревно на стройку). Не рабочий (копейщик) — мимо.
func can_gnome_interact(gnome: Node) -> bool:
	if wood_remaining <= 0:
		return false
	if gnome.get(&"soldier_type") != WORKER_ROLE:
		return false
	return not (gnome.has_method(&"is_carrying") and gnome.is_carrying())


## Цвет осколков при сломе (зелёная крона разлетается).
@export var shatter_color: Color = Color(0.24, 0.5, 0.22)


## Рабочий ударил топором: выдаём бревно, тратим запас, крона редеет. Re-валидируем
## (между поиском цели и ударом мог измениться запас/ноша другого рабочего).
func gnome_hit(gnome: Node) -> void:
	if wood_remaining <= 0:
		return
	if gnome == null or not gnome.has_method(&"receive_log"):
		return
	if gnome.has_method(&"is_carrying") and gnome.is_carrying():
		return
	gnome.receive_log()
	wood_remaining -= 1
	_refresh_visual()
	if wood_remaining <= 0:
		_break()  # срублено — рабочие сами перейдут к следующему дереву


## Крона убывает с запасом (визуальная обратная связь «дерево рубят»).
func _refresh_visual() -> void:
	var ratio: float = clampf(float(wood_remaining) / float(_initial_wood), 0.0, 1.0)
	if _foliage != null and wood_remaining > 0:
		_foliage.scale = Vector3.ONE * lerpf(0.45, 1.0, ratio)


## Дерево срублено: выходим из strike-группы (рабочие переключатся на следующее),
## крона разлетается осколками (ShatterEffect — общий язык разрушения), ствол
## падает в пенёк. Рабочие сами найдут другое дерево через _find_interact_target.
func _break() -> void:
	remove_from_group(GNOME_STRIKE_GROUP)
	if _foliage != null:
		ShatterEffect.spawn(get_tree().current_scene, _foliage.global_position,
			shatter_color, 8, 1.4)
		_foliage.visible = false
	if _trunk != null:
		# Ствол кренится и оседает в пенёк (короткий tween-«падёж»).
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(_trunk, "scale", Vector3(1.0, 0.3, 1.0), 0.4).set_trans(Tween.TRANS_BACK)
		tw.tween_property(_trunk, "rotation:z", deg_to_rad(8.0), 0.4)
