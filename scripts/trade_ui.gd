extends CanvasLayer
## Стол торга: покупка отряда перетаскиванием монет. Поступки (реплики снизу) дают
## СКИДКУ на цену → итоговое «Купить за: N». Монеты (номинал coin_value) тащишь
## drag-n-drop'ом из кошелька-стопки в зону стола, пока не наберёшь N. Хватило →
## купил: списываем N золота, гасим применённые поступки, эмитим
## purchased(unit_type, squad_size). Тип юнита задаёт open(unit_type) из gnome_house
## (копейщики / рабочие). Пример: цена 200, «Убил Гиганта» −150 → купить за 50
## (2 монеты по 25). Игра на паузе.

const GROUP := &"trade_ui"
const CoinToken := preload("res://scripts/coin_token.gd")

## Номинал одной перетаскиваемой монеты в золоте. Цены кратны ему (200/150/50 / 25).
@export var coin_value: int = 25

signal purchased(unit_type: StringName, squad_size: int)

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

## Цена отряда в золоте (дефолт для типов вне HIRE_PRICE).
@export var base_price: int = 200
## Цена найма по типу юнита (золото). Нет в карте → base_price. Лучники дёшевы (прототип).
const HIRE_PRICE := { &"archer_squad": 10 }


## Цена найма текущего типа.
func _price() -> int:
	return int(HIRE_PRICE.get(_unit_type, base_price))

var _open: bool = false
var _applied: Dictionary = {}  # deed id (StringName) -> value (int)
var _placed: int = 0  # золото, выложенное монетами на стол
## Тип покупаемого юнита (gnome_house задаёт через open). Спавнер маппит тип → сцена.
var _unit_type: StringName = &"pikeman"
## Адресный колбэк покупки. Если задан (открыл КАЗАРМА) — на «Купить» зовём его вместо
## широковещательного purchased: казарма сама спавнит отряд + раздаёт посты гарнизона.
## Пуст (открыл домик гномов) → broadcast purchased → спавнер ловит generic-путём.
var _on_purchase: Callable = Callable()
## Счётчик живых бойцов для гейта «Артель полна». Задаёт КАЗАРМА (свои бойцы — per-barracks);
## пуст → глобальный счёт по типу (_count_of_type, для покупки в домике).
var _count_fn: Callable = Callable()
## Эффективный КАП найма (база типа + бараки квартала). Задаёт КАЗАРМА; пуст → базовый
## SoldierSystem.get_squad_cap. Без него гейт «Артель полна» игнорировал бы бараки.
var _cap_fn: Callable = Callable()


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


func open(unit_type: StringName = &"pikeman", on_purchase: Callable = Callable(), count_fn: Callable = Callable(), cap_fn: Callable = Callable()) -> void:
	if _open:
		return
	_unit_type = unit_type
	_on_purchase = on_purchase
	_count_fn = count_fn
	_cap_fn = cap_fn
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
	_on_purchase = Callable()
	_count_fn = Callable()
	_root.visible = false
	get_tree().paused = false


func _applied_value() -> int:
	var s: int = 0
	for v in _applied.values():
		s += int(v)
	return mini(s, _price())


## Итоговая цена к оплате = цена минус скидка от поступков.
func _remaining() -> int:
	return maxi(0, _price() - _applied_value())


func _gold() -> int:
	var bank := get_tree().get_first_node_in_group(&"gold_bank")
	if bank != null and bank.has_method(&"get_gold"):
		return int(bank.call(&"get_gold"))
	return 0


## Сколько живых юнитов этого типа уже есть (для потолка артели). Считаем по группе
## soldier — спрятанные в башне рабочие остаются в ней (сняты лишь с целей скелетов).
func _count_of_type(unit_type: StringName) -> int:
	var c: int = 0
	for s in get_tree().get_nodes_in_group(&"soldier"):
		if is_instance_valid(s) and s.get(&"soldier_type") == unit_type:
			c += 1
	return c


## Текущий счёт для гейта «Артель полна»: per-barracks (через _count_fn от казармы) либо
## глобально по типу (покупка в домике).
func _current_count() -> int:
	if _count_fn.is_valid():
		return int(_count_fn.call())
	return _count_of_type(_unit_type)


func _get_deeds() -> Array:
	var deeds_log := get_tree().get_first_node_in_group(&"deeds_log")
	if deeds_log != null and deeds_log.has_method(&"get_deeds"):
		return deeds_log.call(&"get_deeds")
	return []


# ---------- перетаскивание монет ----------

## Можно взять ещё монету, если ещё не набрали нужное И в кошельке хватает золота.
func _can_take_coin() -> bool:
	return _placed < _remaining() and _gold() >= _placed + coin_value


func _coin_get_drag(_at: Vector2):
	if not _can_take_coin():
		return null
	_coin_stack.set_drag_preview(_make_coin(false))
	return {"type": "coin"}


func _zone_can_drop(_at: Vector2, data) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.get("type", "") == "coin" and _can_take_coin()


func _zone_drop(_at: Vector2, _data) -> void:
	_placed += coin_value
	_rebuild()


## Заглушки для неиспользуемых направлений drag_forwarding (валидные Callable).
func _no_drag(_at: Vector2):
	return null
func _no_drop(_at: Vector2, _data) -> bool:
	return false
func _noop(_at: Vector2, _data) -> void:
	pass


func _on_coin_removed() -> void:
	_placed = maxi(0, _placed - coin_value)
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
	_wallet_label.text = "Кошелёк: %d   (монета %d)" % [_gold(), coin_value]
	_zone_label.text = "На стол положено: %d / %d" % [mini(_placed, rem), rem]
	for c in _placed_row.get_children():
		c.queue_free()
	var n: int = int(_placed / coin_value)
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
	var unit_name: String = "отряд"
	if SoldierSystem != null and SoldierSystem.has_soldier(_unit_type):
		unit_name = String(SoldierSystem.get_soldier_data(_unit_type).get("name", "отряд"))
	_buy_btn.text = ("Купить: %s" % unit_name) if rem > 0 else ("Купить даром: %s" % unit_name)
	# Потолок артели: эффективный кап (база + бараки квартала, через _cap_fn от казармы); пуст →
	# базовый SoldierSystem.get_squad_cap. Полно → купить нельзя (иначе платил бы зря).
	var cap: int = 0
	if _cap_fn.is_valid():
		cap = int(_cap_fn.call())
	elif SoldierSystem != null:
		cap = SoldierSystem.get_squad_cap(_unit_type)
	if cap > 0 and _current_count() >= cap:
		_buy_btn.disabled = true
		_buy_btn.text = "Артель полна (%d/%d)" % [cap, cap]
		_price_label.text = "Артель уже полна — больше не нанять"


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
	# Размер отряда — ИЗ КАТАЛОГА по типу (копейщик 5, рабочий 3), а не локальный
	# экспорт: каталог — единый источник истины, иначе покупаешь не то число.
	var size: int = SoldierSystem.get_squad_size(_unit_type)
	# Адресный колбэк (казарма) перебивает broadcast: захватываем ДО close (он чистит _on_purchase).
	var cb: Callable = _on_purchase
	if cb.is_valid():
		cb.call(_unit_type, size)
	else:
		purchased.emit(_unit_type, size)
	close()
