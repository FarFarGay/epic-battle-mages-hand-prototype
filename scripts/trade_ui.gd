extends CanvasLayer
## Торг с гномами: покупка отряда. Шкалу Цены закрываешь двумя путями —
## ПОСТУПКАМИ (токены доброй воли из DeedsLog, скидка, тратятся при покупке) и
## ЗОЛОТОМ (платишь непокрытый остаток). Применяешь поступок → щит-слой отношения
## (BarShield) покрывает часть бара → остаток платишь золотом. Хватает
## (поступки+золото ≥ цены) → купил: списываем золото за остаток, гасим
## применённые поступки, эмитим purchased(squad_size). Игра на паузе.

const GROUP := &"trade_ui"

signal purchased(squad_size: int)

@onready var _root: Control = $Root
@onready var _price_label: Label = $Root/Panel/Margin/VBox/PriceLabel
@onready var _bar_shield: ColorRect = $Root/Panel/Margin/VBox/Bar/BarShield
@onready var _gold_label: Label = $Root/Panel/Margin/VBox/GoldLabel
@onready var _deeds_list: VBoxContainer = $Root/Panel/Margin/VBox/DeedsList
@onready var _buy_btn: Button = $Root/Panel/Margin/VBox/ButtonRow/BuyButton
@onready var _cancel_btn: Button = $Root/Panel/Margin/VBox/ButtonRow/CancelButton

@export var base_price: int = 200
@export var squad_size: int = 3

var _open: bool = false
var _applied: Dictionary = {}  # deed id (StringName) -> value (int)


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.visible = false
	_buy_btn.pressed.connect(_on_buy)
	_cancel_btn.pressed.connect(close)


func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	_applied = {}
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


func _rebuild() -> void:
	var rem: int = _remaining()
	_price_label.text = "Цена: %d   →   платить: %d золота" % [base_price, rem]
	_gold_label.text = "Ваше золото: %d" % _gold()
	# Щит-слой отношения покрывает долю цены, закрытую поступками.
	_bar_shield.anchor_right = float(_applied_value()) / float(maxi(base_price, 1))
	for c in _deeds_list.get_children():
		c.queue_free()
	var deeds: Array = _get_deeds()
	if deeds.is_empty():
		var lbl := Label.new()
		lbl.text = "(добрых дел пока нет — соверши что-нибудь героическое)"
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_deeds_list.add_child(lbl)
	for deed in deeds:
		var btn := Button.new()
		var on: bool = deed["id"] in _applied
		btn.text = "%s %s  (−%d)" % ["[✓]" if on else "[  ]", String(deed["label"]), int(deed["value"])]
		btn.pressed.connect(_on_deed_toggled.bind(deed))
		_deeds_list.add_child(btn)
	_buy_btn.disabled = _gold() < rem


func _on_deed_toggled(deed: Dictionary) -> void:
	var id: StringName = deed["id"]
	if id in _applied:
		_applied.erase(id)
	else:
		_applied[id] = int(deed["value"])
	_rebuild()


func _on_buy() -> void:
	var rem: int = _remaining()
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
