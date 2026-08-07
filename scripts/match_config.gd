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
## Список = по одному элементу на ЖИВОГО гнома, значение = его класс
## (SoldierSystem.SOLDIER_CATALOG: worker / archer_squad / pikeman / fire_mage).
##
## Класс едет вместе с гномом и в башне НЕ МЕНЯЕТСЯ: кем собрал отряд в данже,
## тем он и работает наверху. Привёл трёх лучников и ноль рабочих — шахта стоит.
##
## Живёт здесь, а не в новом синглтоне: MatchConfig и заведён как «состояние,
## которое переживает смену сцены и достаётся следующей» (позиции башни/врат от
## StartMenu), и consume-паттерн у него уже есть.
var next_squad: Array[StringName] = []


## Забрать отряд и очистить: следующая загрузка мира не должна получить его
## повторно (иначе рестарт сцены дублировал бы гномов).
func consume_squad() -> Array[StringName]:
	var s: Array[StringName] = next_squad.duplicate()
	next_squad.clear()
	return s


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
