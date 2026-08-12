extends Node
## Конфиг старта матча. Autoload: переживает reload_current_scene().
##
## Используется StartMenu для передачи позиций Tower/POI следующей загрузке
## main.tscn. main_setup.gd на корневой ноде main.tscn в _ready читает поля
## и применяет к существующим Tower/Poi_Heart.
##
## Если поле равно SENTINEL — main_setup не трогает соответствующую сущность,
## остаётся .tscn-дефолт (нужно при первом старте игры, до клика «Начать игру»).

const SENTINEL: Vector3 = Vector3(INF, INF, INF)

var next_tower_pos: Vector3 = SENTINEL
var next_poi_pos: Vector3 = SENTINEL
## Случайная позиция Gate для нового матча. Не в подземелье; не вплотную к
## Tower (иначе можно пройти случайно сразу при старте). Применяется
## main_setup.gd при загрузке сцены.
var next_gate_pos: Vector3 = SENTINEL

## True если игрок нажал «Начать игру» — WaveDirector использует флаг для
## автостарта кампании на _ready (фоновый прилив + caravan-волны сразу,
## без ожидания первого camp_deployed). При первом запуске игры (до клика)
## false — игра показывает «спокойный» старт.
var match_started: bool = false

## ⭐ ОТРЯД, ВЫВЕЗЕННЫЙ ИЗ ДАНЖА (2026-08-07). Гномы башни больше не берутся из
## кошелька: артель-магазин выпилен, единственный источник рук — подземелье.
## Список = по одному элементу на ЖИВОГО гнома, элемент = словарь:
##     {"cls": StringName, "bind": int}
## `cls` — класс из SoldierSystem.SOLDIER_CATALOG (worker / archer_squad /
## pikeman / fire_mage), `bind` — КНОПКА, на которую игрок его поставил
## (CrewKit.BIND_LKM / BIND_SPACE / BIND_RMB).
##
## Класс едет вместе с гномом и в башне НЕ МЕНЯЕТСЯ: кем собрал отряд в данже,
## тем он и работает наверху. Привёл трёх лучников и ноль рабочих — шахта стоит.
##
## ⚠ КНОПКА ЕДЕТ ВМЕСТЕ С КЛАССОМ (2026-08-11). Раньше возили голый класс, и
## мир раздавал биндинги заново по дефолтной раскладке — собранный на пятаках
## расклад («лучников на ПКМ») молча терялся на выходе. Раз экран сбора считает
## слот частью состава, то и канал обязан его везти.
##
## Живёт здесь, а не в новом синглтоне: MatchConfig и заведён как «состояние,
## которое переживает смену сцены и достаётся следующей» (позиции башни/врат от
## StartMenu), и consume-паттерн у него уже есть.
var next_squad: Array = []

## ⭐ ДОБЫЧА ЗАБЕГА (2026-08-11). Раньше из данжа выезжали только тела: монеты,
## находки и вскрытый тайник умирали вместе со сценой, хотя игрок собирал их
## руками. Теперь тем же каналом едет ВСЁ нажитое.
##
## Остаток казны забега в БРОНЗЕ (монета данжа = 1 бронза, единая валюта).
var next_coins: int = 0
## Остаток ЕДИНОГО ОПЫТА забега. Золото — валюта уровня и тратится внизу, опыт
## живёт дальше: наверху он ложится в профиль башни и ждёт мета-покупок
## (улучшения базы, новые типы гномов). Возить его начали, когда у него
## появился сток, — до того числа без двери в канале не было.
var next_xp: int = 0
## Карточки-находки: id → сколько раз взята. В мире действуют, ПОКА ЖИВЫ
## носители класса (вариант «карточка = выучка отряда», решение юзера
## 2026-08-11): погиб последний артельщик — «Эхо в камне» ушло с ним.
var next_cards: Dictionary = {}
## Постоянная добыча: чему тайник научил НАСОВСЕМ. Пишется в user://tower_profile
## уже на той стороне — PlayerProfile живёт узлом в сцене мира, и данж до него
## дотянуться не может, поэтому едет через канал, а не пишется на месте.
var next_scrolls: Array = []
var next_blueprints: Array = []


## Забрать отряд и очистить: следующая загрузка мира не должна получить его
## повторно (иначе рестарт сцены дублировал бы гномов).
func consume_squad() -> Array:
	var s: Array = next_squad.duplicate(true)
	next_squad.clear()
	return s


## Забрать всю добычу забега одним куском. Как и отряд — ОДИН раз: рестарт
## сцены не должен повторно начислять монеты и находки.
func consume_haul() -> Dictionary:
	var haul := {
		"coins": next_coins,
		"xp": next_xp,
		"cards": next_cards.duplicate(),
		"scrolls": next_scrolls.duplicate(),
		"blueprints": next_blueprints.duplicate(),
	}
	next_coins = 0
	next_xp = 0
	next_cards = {}
	next_scrolls = []
	next_blueprints = []
	return haul


func has_pending() -> bool:
	return next_tower_pos != SENTINEL or next_poi_pos != SENTINEL


func consume_tower_pos() -> Vector3:
	var p: Vector3 = next_tower_pos
	next_tower_pos = SENTINEL
	return p


func consume_poi_pos() -> Vector3:
	var p: Vector3 = next_poi_pos
	next_poi_pos = SENTINEL
	return p


func consume_gate_pos() -> Vector3:
	var p: Vector3 = next_gate_pos
	next_gate_pos = SENTINEL
	return p
