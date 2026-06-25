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
## Какой диалог у этого домика — ключ в [DIALOGS]. У каждого дома СВОЙ id, чтобы
## реплики не дублировались. Дефолт — текущий «Загадочный». Новые дома (b/c/d) —
## заглушки, контент наполним позже.
@export var dialog_id: StringName = &"mysterious"

## Реестр диалогов поселения по dialog_id. Узлы: text + choices [{label, next, effect?}].
## next пустой → закрыть. effect (опц.) → DialogUI.effect_selected.
const DIALOGS := {
	&"mysterious": {
	&"root": {
		"text": "Гном в бархатном жилете щурится из дверей: «О, прив-е-ет, {name}! Это ты уделал ту костлявую дылду-переростка? Гру́вно. Просто шага-делик, йе-е! Заходи, котик, потолкуем о деле.» (крутит бёдрами и подмигивает обоими глазами по очереди)",
		"choices": [
			{ "label": "А вы, собственно, кто?", "next": &"who" },
			{ "label": "Что за хартия?", "next": &"charter", "req": &"unsigned" },
			{ "label": "Кхм. Я пойду.", "next": &"" },
		],
	},
	&"who": {
		"text": "«Кто я? Позволь представиться, {name} — мы вольные гномы, мужчины-загадки международного масштаба. Застряли в этом Великом Гномьем Городе на го-оды, и тут было ОЧЕНЬ одиноко, м-м-м. Осели в зальчике — бар, бархат, мягкий свет. А потом БАЦ — дырень в стене, повалила костлявая нечисть, и выход возьми да захлопнись. И вот мы тут. Заперты. Наедине. Зови меня просто... Загадочный. Йе-е.»",
		"choices": [
			{ "label": "Ясно. Так что за хартия?", "next": &"charter", "req": &"unsigned" },
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
	},
	&"b": { &"root": { "text": "[Гномий дом B — диалог наполним позже.]", "choices": [ { "label": "Бывай.", "next": &"" } ] } },
	# Гномы-строители (Room6). Квест: запусти станок в Room11 → знание о постройке
	# стен/башен/казарм (лицензия строителя). Гейты веток через req
	# (building_locked/known) — см. DialogUI._req_met. Найм отрядов — НЕ здесь, а в
	# казармах за золото (см. PadBuilding._open_hire).
	&"builders": {
		&"root": {
			"text": "Коренастый гном в кожаном фартуке, весь в каменной пыли, отрывается от чертежа: «О, живой! А мы уж думали, тут одни костяки шастают. Мы — Гильдия Камня, строители. Когда-то весь этот город по нашим чертежам клали. Чем подсобить, {name}?»",
			"choices": [
				{ "label": "Кто вы и что строите?", "next": &"who" },
				{ "label": "Научите строить?", "next": &"teach_locked", "req": &"building_locked" },
				{ "label": "Спасибо за чертежи!", "next": &"teach_done", "req": &"building_known" },
				{ "label": "Пойду.", "next": &"" },
			],
		},
		&"who": {
			"text": "«Гильдия Камня — мастера стен, башен и хитрых механизмов. Стенами держали орду, башнями били издали. Да вот незадача: чертежи есть, а руки заняты — отбиваемся от костяков. Докажи, что соображаешь в нашем ремесле, — поделимся знанием.»",
			"choices": [
				{ "label": "Как доказать?", "next": &"teach_locked", "req": &"building_locked" },
				{ "label": "Понял. Вернусь.", "next": &"root" },
			],
		},
		&"teach_locked": {
			"text": "«Видал станок-чертёжник в дальнем зале? Старый, заглох. Запусти его: подай ток по схеме, как станок покажет — бей Искрой по контактам в нужном порядке, потом дёрни пускач. Оживишь машину — отпечатает чертежи, и будешь класть стены да сторожевые башни не хуже нас.»",
			"choices": [
				{ "label": "Запущу.", "next": &"root" },
				{ "label": "Звучит непросто.", "next": &"" },
			],
		},
		&"teach_done": {
			"text": "«Ха! Станок загудел впервые за годы — чертежи у тебя в руках. Теперь сам ставь стены и башни, где нужда. Уважаю, {name}.»",
			"choices": [
				{ "label": "Благодарю.", "next": &"" },
			],
		},
	},
	&"c": { &"root": { "text": "[Гномий дом C — диалог наполним позже.]", "choices": [ { "label": "Бывай.", "next": &"" } ] } },
	&"d": { &"root": { "text": "[Гномий дом D — диалог наполним позже.]", "choices": [ { "label": "Бывай.", "next": &"" } ] } },
}

var _hand: Hand = null
var _body_mat: StandardMaterial3D = null


func _ready() -> void:
	if not dialog_enabled:
		set_process(false)  # обычный декор — без интеракции
		return
	add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
	# Точка поселения — отсюда выходит купленный отряд (GnomeSquadSpawner).
	add_to_group(&"gnome_settlement")
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
	# Не реагируем на клик-команды aim-режимов, клик по HUD и при удержании предмета.
	if hand.is_in_aim_mode() or hand.is_pointer_over_ui() or hand.is_holding():
		return
	var hp: Vector3 = hand.cursor_world_position()
	var dx: float = hp.x - global_position.x
	var dz: float = hp.z - global_position.z
	if dx * dx + dz * dz <= engage_radius * engage_radius:
		if dlg != null and dlg.has_method(&"open"):
			if not dlg.is_connected(&"effect_selected", _on_dialog_effect):
				dlg.connect(&"effect_selected", _on_dialog_effect)
			dlg.call(&"open", _dialog(), &"root")


## Обработка эффектов веток диалога (DialogUI.effect_selected). Найм отрядов отсюда
## убран (2026-06-25) — нанимают ТОЛЬКО казармы за золото (PadBuilding._open_hire).
## Остался лишь open_charter (подпись Торговой Хартии).
func _on_dialog_effect(effect_id: StringName) -> void:
	if effect_id == &"open_charter":
		# Награда = подпись Торговой Хартии. Deferred: диалог закроется этим же
		# кадром (ветка next=""), Хартия откроется следующим — без гонки паузы.
		var charter := get_tree().get_first_node_in_group(&"charter_ui")
		if charter != null and charter.has_method(&"open"):
			charter.call_deferred(&"open")


## Диалог этого домика по dialog_id (fallback — «mysterious», если id неизвестен).
func _dialog() -> Dictionary:
	return DIALOGS.get(dialog_id, DIALOGS[&"mysterious"])


func _resolve_hand() -> Hand:
	if _hand != null and is_instance_valid(_hand):
		return _hand
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP)
	return _hand
