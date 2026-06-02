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
