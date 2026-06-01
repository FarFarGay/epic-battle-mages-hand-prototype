extends Node3D
## Скрипт на корне main.tscn. Единственная задача — на старте сцены применить
## pending-позиции Tower и POI из MatchConfig autoload'а. Это путь, по которому
## StartMenu прокидывает «новый матч»: задаёт next_tower_pos / next_poi_pos и
## вызывает reload_current_scene(); следующая загрузка ловит их здесь.
##
## При первом запуске (до клика «Начать игру») MatchConfig пуст, скрипт ничего
## не делает — сцена использует .tscn-дефолты.
##
## Camp двигается на ту же XZ-дельту, что и Tower. Camp._ready уже отработал к
## моменту нашего _ready (порядок bottom-up): палатки и Harvester уже спавнены
## за башней относительно .tscn-дефолта Tower=(0,3,0). Если двинуть только
## Tower — палатки останутся у (0,0,0), а в caravan-follow они доедут с
## задержкой. Camp.global_position += delta тащит за собой всех своих детей
## (палатки, Harvester, гномов) — их local-позиции сохраняются, global
## съезжает синхронно с Tower'ом. Игрок видит лагерь сразу за башней без
## фазы «телепортация Tower → подтягивание каравана».

@export var tower_path: NodePath = ^"Tower"
@export var poi_path: NodePath = ^"PointsOfInterest/Poi_Heart"
@export var camp_path: NodePath = ^"Camp"


func _ready() -> void:
	var tower := get_node_or_null(tower_path) as Node3D
	if tower != null and MatchConfig.next_tower_pos != MatchConfig.SENTINEL:
		var tp: Vector3 = MatchConfig.consume_tower_pos()
		var delta := Vector3(tp.x - tower.global_position.x, 0.0, tp.z - tower.global_position.z)
		tower.global_position = Vector3(tp.x, tower.global_position.y, tp.z)
		var camp := get_node_or_null(camp_path) as Node3D
		if camp != null:
			camp.global_position += delta
	var poi := get_node_or_null(poi_path) as Node3D
	if poi != null and MatchConfig.next_poi_pos != MatchConfig.SENTINEL:
		var pp: Vector3 = MatchConfig.consume_poi_pos()
		poi.global_position = Vector3(pp.x, poi.global_position.y, pp.z)
