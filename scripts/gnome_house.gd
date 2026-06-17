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
		"text": "Гном в бархатном жилете щурится из дверей: «О, прив-е-ет, {name}! Это ты уделал ту костлявую дылду-переростка? Гру́вно. Просто шага-делик, йе-е! За такое — лучшая награда, котик: возьму тебя в дело. Скрепим Хартией.» (крутит бёдрами и подмигивает обоими глазами по очереди)",
		"choices": [
			{ "label": "А вы, собственно, кто?", "next": &"who" },
			{ "label": "Что за хартия?", "next": &"charter" },
			{ "label": "Прикупить копейщиков, бэйби.", "next": &"", "effect": &"open_trade" },
			{ "label": "Кхм. Я пойду.", "next": &"" },
		],
	},
	&"who": {
		"text": "«Кто я? Позволь представиться, {name} — мы вольные гномы, мужчины-загадки международного масштаба. Застряли в этом Великом Гномьем Городе на го-оды, и тут было ОЧЕНЬ одиноко, м-м-м. Осели в зальчике — бар, бархат, мягкий свет. А потом БАЦ — дырень в стене, повалила костлявая нечисть, и выход возьми да захлопнись. И вот мы тут. Заперты. Наедине. Зови меня просто... Загадочный. Йе-е.»",
		"choices": [
			{ "label": "Ясно. Так что за хартия?", "next": &"charter" },
			{ "label": "Эм. Ну, бывайте.", "next": &"" },
		],
	},
	&"charter": {
		"text": "«Торговая Хартия гномов, бэйби! Подмахнёшь — и мы партнёры навек: торгуем по чести, обогащаемся вместе. Чисто формальность... почти. Ну что, скрепим, тигр?»",
		"choices": [
			{ "label": "Давай подпишу.", "next": &"", "effect": &"open_charter" },
			{ "label": "Я ещё подумаю.", "next": &"root" },
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
			if not dlg.is_connected(&"effect_selected", _on_dialog_effect):
				dlg.connect(&"effect_selected", _on_dialog_effect)
			dlg.call(&"open", DIALOG, &"root")


## Обработка эффектов веток диалога (DialogUI.effect_selected).
func _on_dialog_effect(effect_id: StringName) -> void:
	if effect_id == &"open_charter":
		# Награда = подпись Торговой Хартии. Deferred: диалог закроется этим же
		# кадром (ветка next=""), Хартия откроется следующим — без гонки паузы.
		var charter := get_tree().get_first_node_in_group(&"charter_ui")
		if charter != null and charter.has_method(&"open"):
			charter.call_deferred(&"open")
	elif effect_id == &"open_trade":
		# Покупка отряда — открываем торг (deferred, как Хартию).
		var trade := get_tree().get_first_node_in_group(&"trade_ui")
		if trade != null and trade.has_method(&"open"):
			trade.call_deferred(&"open")


func _resolve_hand() -> Hand:
	if _hand != null and is_instance_valid(_hand):
		return _hand
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP)
	return _hand
