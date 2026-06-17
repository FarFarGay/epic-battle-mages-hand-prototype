extends CanvasLayer
## Стол торга: покупка отряда перетаскиванием монет. Поступки (реплики снизу) дают
## СКИДКУ на цену → итоговое «Купить за: N». Монеты (номинал COIN_VALUE) тащишь
## drag-n-drop'ом из кошелька-стопки в зону стола, пока не наберёшь N. Хватило →
## купил: списываем N золота, гасим применённые поступки, эмитим
## purchased(squad_size). Пример: цена 200, «Убил Гиганта» −150 → купить за 50
## (2 монеты по 25). Игра на паузе.

const GROUP := &"trade_ui"
## Номинал одной перетаскиваемой монеты в золоте. Цены кратны ему (200/150/50 / 25).
const COIN_VALUE := 25
const CoinToken := preload("res://scripts/coin_token.gd")

signal purchased(squad_size: int)

@onready var _root: Control = $Root
@onready var _price_label: Label = $Root/Panel/Margin/VBox/PriceLabel
@onready var _pay_zone: Panel = $Root/Panel/Margin/VBox/PayZone
@onready var _zone_label: Label = $Root/Panel/Margin/VBox/PayZone/Margin/VBox/ZoneLabel
@onready var _placed_row: GridContainer = $Root/Panel/Margin/VBox/PayZone/Margin/VBox/PlacedRow
@onready var _coin_stack: Panel = $Root/Panel/Margin/VBox/WalletRow/CoinStack
@onready var _wallet_label: Label = $Root/Panel/Margin/VBox/WalletRow/WalletLabel
@onready var _deeds_list: VBoxContainer = $Root/Panel/Margin/VBox/DeedsList
@onready var _buy_btn: Button = $Root/Panel/Margin/VBox/ButtonRow/BuyButton
@onready var _cancel_btn: Button = $Root/Panel/Margin/VBox/ButtonRow/CancelButton

## Цена отряда в золоте.
@export var base_price: int = 200
@export var squad_size: int = 3

var _open: bool = false
var _applied: Dictionary = {}  # deed id (StringName) -> value (int)
var _placed: int = 0  # золото, выложенное монетами на стол


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.visible = false
	_buy_btn.pressed.connect(_on_buy)
	_cancel_btn.pressed.connect(close)
	# Кошелёк-стопка — источник перетаскивания; зона стола — приёмник.
	_coin_stack.set_drag_forwarding(_coin_get_drag, _no_drop, _noop)
	_pay_zone.set_drag_forwarding(_no_drag, _zone_can_drop, _zone_drop)
	# Монета-затравка в кошельке — наглядно «вот это и тащи».
	var purse_box := _coin_stack.get_node_or_null("HBox")
	if purse_box != null:
		var seed_coin := CoinToken.new()
		seed_coin.radius = 15.0
		purse_box.add_child(seed_coin)
		purse_box.move_child(seed_coin, 0)


func is_open() -> bool:
	return _open


## Пока тащишь монету — подсвечиваем стол (зелёный «принимающий» оттенок).
func _process(_delta: float) -> void:
	if not _open:
		return
	var dragging: bool = get_viewport().gui_is_dragging()
	_pay_zone.self_modulate = Color(1.25, 1.35, 1.2) if dragging else Color(1, 1, 1)


func open() -> void:
	if _open:
		return
	_open = true
	_applied = {}
	_placed = 0
	_root.visible = true
	get_tree().paused = true
	_rebuild()


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	get_tree().paused = false


func _applied_value() -> int:
	var s: int = 0
	for v in _applied.values():
		s += int(v)
	return mini(s, base_price)


## Итоговая цена к оплате = цена минус скидка от поступков.
func _remaining() -> int:
	return maxi(0, base_price - _applied_value())


func _gold() -> int:
	var bank := get_tree().get_first_node_in_group(&"gold_bank")
	if bank != null and bank.has_method(&"get_gold"):
		return int(bank.call(&"get_gold"))
	return 0


func _get_deeds() -> Array:
	var deeds_log := get_tree().get_first_node_in_group(&"deeds_log")
	if deeds_log != null and deeds_log.has_method(&"get_deeds"):
		return deeds_log.call(&"get_deeds")
	return []


# ---------- перетаскивание монет ----------

## Можно взять ещё монету, если ещё не набрали нужное И в кошельке хватает золота.
func _can_take_coin() -> bool:
	return _placed < _remaining() and _gold() >= _placed + COIN_VALUE


func _coin_get_drag(_at: Vector2):
	if not _can_take_coin():
		return null
	_coin_stack.set_drag_preview(_make_coin(false))
	return {"type": "coin"}


func _zone_can_drop(_at: Vector2, data) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.get("type", "") == "coin" and _can_take_coin()


func _zone_drop(_at: Vector2, _data) -> void:
	_placed += COIN_VALUE
	_rebuild()


## Заглушки для неиспользуемых направлений drag_forwarding (валидные Callable).
func _no_drag(_at: Vector2):
	return null
func _no_drop(_at: Vector2, _data) -> bool:
	return false
func _noop(_at: Vector2, _data) -> void:
	pass


func _on_coin_removed() -> void:
	_placed = maxi(0, _placed - COIN_VALUE)
	_rebuild()


## Рисованная монета. clickable=true → её можно снять со стола (вернуть в кошелёк).
func _make_coin(clickable: bool) -> Control:
	var c := CoinToken.new()
	c.radius = 16.0
	c.clickable = clickable
	return c


func _rebuild() -> void:
	var rem: int = _remaining()
	_price_label.text = "Купить за: %d золота" % rem
	_wallet_label.text = "Кошелёк: %d   (монета %d)" % [_gold(), COIN_VALUE]
	_zone_label.text = "На стол положено: %d / %d" % [mini(_placed, rem), rem]
	for c in _placed_row.get_children():
		c.queue_free()
	var n: int = int(_placed / COIN_VALUE)
	for i in range(n):
		var coin := _make_coin(true)
		coin.clicked.connect(_on_coin_removed)
		_placed_row.add_child(coin)
	for c in _deeds_list.get_children():
		c.queue_free()
	var deeds: Array = _get_deeds()
	if deeds.is_empty():
		var lbl := Label.new()
		lbl.text = "(добрых дел нет — плати золотом сполна)"
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_deeds_list.add_child(lbl)
	for deed in deeds:
		var btn := Button.new()
		var on: bool = deed["id"] in _applied
		btn.text = "%s %s  (скидка −%d)" % ["[✓]" if on else "[  ]", String(deed["label"]), int(deed["value"])]
		btn.pressed.connect(_on_deed_toggled.bind(deed))
		_deeds_list.add_child(btn)
	_buy_btn.disabled = _placed < rem
	_buy_btn.text = "Купить отряд" if rem > 0 else "Купить (даром!)"


func _on_deed_toggled(deed: Dictionary) -> void:
	var id: StringName = deed["id"]
	if id in _applied:
		_applied.erase(id)
	else:
		_applied[id] = int(deed["value"])
	# Скидка снизила цену ниже выложенного — лишние монеты возвращаются в кошелёк.
	_placed = mini(_placed, _remaining())
	_rebuild()


func _on_buy() -> void:
	var rem: int = _remaining()
	if _placed < rem:
		return
	var bank := get_tree().get_first_node_in_group(&"gold_bank")
	if bank == null or int(bank.call(&"get_gold")) < rem:
		return
	if rem > 0:
		bank.call(&"try_spend", rem)
	var deeds_log := get_tree().get_first_node_in_group(&"deeds_log")
	if deeds_log != null and not _applied.is_empty():
		deeds_log.call(&"consume", _applied.keys())
	purchased.emit(squad_size)
	close()
