extends StaticBody3D
## Гномий домик — точка поселения гномов. Наведи руку → подсветка (контракт
## pickup_highlight); ЛКМ вблизи → открывается диалог поселения (выбор-ветки).
## Эффекты веток пока проброшены как DialogUI.effect_selected (логику найма/наград
## навесим следующим шагом). Открытие диалога ставит игру на паузу (см. DialogUI).

const ACTION_GRAB := &"hand_grab"
const DIALOG_GROUP := &"dialog_ui"

## Только домики с dialog_enabled=true интерактивны (подсветка + ЛКМ-диалог).
## Остальные — обычный декор поселения. Включить на ОДНОМ домике в сцене.
@export var dialog_enabled: bool = false
## Радиус (XZ) вокруг домика, в котором рука может «поговорить» по ЛКМ.
@export var engage_radius: float = 3.2
@export var highlight_color: Color = Color(0.95, 0.85, 0.4)

## Дерево диалога поселения. Узлы: text + choices [{label, next, effect?}].
## next пустой → закрыть. effect (опц.) → DialogUI.effect_selected.
const DIALOG := {
	&"root": {
		"text": "Гном в бархатном жилете и кружевных манжетах вальяжно разваливается в дверях: «О, прив-е-ет, бэйби! Это ты уделал того костлявого здоровягу? Гру́вно. Просто шага-делик, йе-е! Иди сюда, котик, у меня для тебя кое-что го-о-рячее... награда, я имею в виду. Йе-е!» (крутит бёдрами и подмигивает обоими глазами по очереди)",
		"choices": [
			{ "label": "А вы, собственно, кто?", "next": &"who" },
			{ "label": "Награда? Не желаете ли... показать.", "next": &"reward" },
			{ "label": "Кхм. Я пойду.", "next": &"" },
		],
	},
	&"who": {
		"text": "«Кто я? Позволь представиться, бэйби — мы вольные гномы, мужчины-загадки международного масштаба. Застряли в этом Великом Гномьем Городе на го-оды, и тут было ОЧЕНЬ одиноко, м-м-м. Осели мы в этом зальчике, всё чин по чину — бар, бархат, мягкий свет. А потом — БАЦ! — дырень в стене, повалила костлявая нечисть, и выход возьми да захлопнись. И вот мы тут. Заперты. Наедине. Зови меня просто... Загадочный. Йе-е.»",
		"choices": [
			{ "label": "Ясно. Так что там с наградой?", "next": &"reward" },
			{ "label": "Эм. Ну, бывайте.", "next": &"" },
		],
	},
	&"reward": {
		"text": "«Вот это по-нашему, тигр!» Гном вкрадчиво вкладывает тебе награду в ладонь и мурлычет: «Только тссс... и веди себя прилично, бэйби. О, веди себя прили-и-ично. Йе-е.» (целует кончики пальцев)",
		"choices": [
			{ "label": "Беру. Спасибо, э... красавчик.", "next": &"", "effect": &"gnome_reward" },
		],
	},
}

var _hand: Hand = null
var _body_mat: StandardMaterial3D = null


func _ready() -> void:
	if not dialog_enabled:
		set_process(false)  # обычный декор — без интеракции
		return
	add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
	# Дублируем материал тела per-instance — подсветка одного домика не красит все.
	var body := get_node_or_null("Body") as MeshInstance3D
	if body != null and body.material_override != null:
		_body_mat = (body.material_override as StandardMaterial3D).duplicate()
		body.material_override = _body_mat


## Контракт pickup-подсветки (Hand._update_pickup_highlight): рука наводится → emission.
func set_highlighted(value: bool) -> void:
	if _body_mat == null:
		return
	_body_mat.emission_enabled = value
	if value:
		_body_mat.emission = highlight_color
		_body_mat.emission_energy_multiplier = 0.55
	else:
		_body_mat.emission_energy_multiplier = 0.0


func _process(_delta: float) -> void:
	var dlg := get_tree().get_first_node_in_group(DIALOG_GROUP)
	if dlg != null and dlg.has_method(&"is_open") and dlg.call(&"is_open"):
		return  # диалог уже открыт
	if not Input.is_action_just_pressed(ACTION_GRAB):
		return
	var hand := _resolve_hand()
	if hand == null:
		return
	var hp: Vector3 = hand.cursor_world_position()
	var dx: float = hp.x - global_position.x
	var dz: float = hp.z - global_position.z
	if dx * dx + dz * dz <= engage_radius * engage_radius:
		if dlg != null and dlg.has_method(&"open"):
			dlg.call(&"open", DIALOG, &"root")


func _resolve_hand() -> Hand:
	if _hand != null and is_instance_valid(_hand):
		return _hand
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP)
	return _hand
