class_name SquadCards
extends HBoxContainer
## ⭐ КАРТОЧКИ ОТРЯДА — ОДИН УЗЕЛ НА ВСЕ ЭПИЗОДЫ (вынесено из dungeon_sandbox
## 2026-08-11). Разметка и логика прежние, данжевые: их не переписывали, их
## переставили. Второй набор карточек «для большого мира» заводить нельзя —
## это то же самое окно про тот же отряд.
##
## Карточка — не выбор, а ДИСПЛЕЙ: сколько живых из скольких, какая у класса
## кнопка и готова ли она. Группа мертва → карточка гаснет (гномы = видимое HP).
## Готовность телеграфится БОРДЕРОМ карточки, а не полоской отката: «загорелось»
## читается краем глаза, полоска — нет.
##
## Владелец каждый кадр зовёт refresh() с данными; сам узел ничего не знает ни
## про отряд, ни про кулдауны — только рисует.

## Порядок карточек в ряду. Он же порядок ключей в данных refresh().
const ORDER: Array[StringName] = [&"pikeman", &"archer_squad", &"worker", &"fire_mage"]
const COLORS := [Color(0.85, 0.55, 0.25), Color(0.55, 0.35, 0.75),
		Color(0.7, 0.45, 0.25), Color(0.95, 0.4, 0.2)]

var _cards: Array = []
var _boxes: Array = []


func _ready() -> void:
	_build_styles()


## Стили карточек (как _make_squad_card основной игры: тёмный фон, цветной
## бордер типа, скругление). Узлы — в сцене, тут только StyleBox'ы и ссылки.
func _build_styles() -> void:
	_cards.clear()
	_boxes.clear()
	for i in range(ORDER.size()):
		var card := get_node_or_null("Card%d" % (i + 1)) as PanelContainer
		if card == null:
			return
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.09, 0.09, 0.13, 0.92)
		box.border_color = COLORS[i]
		box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		box.content_margin_left = 8
		box.content_margin_right = 8
		box.content_margin_top = 5
		box.content_margin_bottom = 5
		card.add_theme_stylebox_override("panel", box)
		_cards.append(card)
		_boxes.append(box)


## Обновить ряд. Для каждого класса ждём словарь:
##   alive  — живых сейчас, total — сколько было в полном составе;
##   armed  — готова ли способность (бордер белеет);
##   line   — вторая строка карточки: кнопка и отсчёт («[ПРОБЕЛ] 2.4с»).
##            Пустая строка — оставить надпись из сцены (дефолтную).
##   extra  — необязательный хвост к счётчику (данж вешает туда находки).
## Класса нет в данных → карточка скрыта: пустая карточка врёт о составе.
func refresh(data: Dictionary) -> void:
	if _cards.is_empty():
		_build_styles()
	for i in range(_cards.size()):
		var card: PanelContainer = _cards[i]
		var d: Dictionary = data.get(ORDER[i], {})
		if d.is_empty():
			card.visible = false
			continue
		card.visible = true
		var alive: int = int(d.get("alive", 0))
		var total: int = int(d.get("total", alive))
		var armed: bool = bool(d.get("armed", false))
		var box: StyleBoxFlat = _boxes[i]
		box.border_color = Color(1, 1, 1, 0.95) if armed else COLORS[i]
		box.bg_color = Color(0.16, 0.15, 0.2, 0.95) if armed \
				else Color(0.09, 0.09, 0.13, 0.92)
		# Мёртвая группа — карточка тускнеет целиком, а не прячется: место в ряду
		# держим, иначе оставшиеся прыгают под курсором.
		card.modulate = Color(1, 1, 1, 1.0) if alive > 0 else Color(1, 1, 1, 0.35)
		var cnt := card.get_node_or_null("V/Count") as Label
		if cnt != null:
			cnt.text = "Живых: %d / %d%s" % [alive, total, str(d.get("extra", ""))]
		var key := card.get_node_or_null("V/Key") as Label
		var line: String = str(d.get("line", ""))
		if key != null and line != "":
			key.text = line
