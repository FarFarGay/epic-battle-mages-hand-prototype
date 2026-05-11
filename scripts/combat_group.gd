class_name CombatGroup
extends Resource
## Атомарная единица атаки — пачка юнитов, спавнящаяся в одной точке и
## нацеленная на одну цель. Несколько групп в одной волне (см. [WaveStage]
## .groups) дают многофронтовую атаку.
##
## **Композиция:** массив [UnitEntry]. Дизайнер кладёт «8 обычных скелетов
## + 3 скелета-лучника» в одну группу — они спавнятся вместе одним кластером.
## Тактика «маг прикрывает мили» эмерджентно появляется через per-unit AI,
## не через group-coordinator: маг сам ищет ближайшего союзника-melee и
## кастит щит. Группа определяет «кто пришёл», не «кто что делает».
##
## **spawn_zone_index** определяет ОТКУДА группа приходит:
##   - `-1` (default): случайная live zone (как legacy single-front).
##   - `0, 1, 2, …`: индекс конкретной SpawnZone (порядок из
##     [EnemySpawner].get_zones()). Дизайнер выставляет «эта группа с
##     севера, эта с юга» — реализация многофронта через .tres.
## Если запрошенный индекс мёртвый (zone destroyed / waves_left=0) —
## fallback на random live zone.
##
## **cluster_spread** — множитель базового `WaveDirector.wave_group_radius`
## при спавне. 1.0 = базовый кластер, >1 = разреженный (юниты идут
## веером), <1 = плотный.

@export var composition: Array[UnitEntry] = []
@export var spawn_zone_index: int = -1
@export_range(0.3, 3.0) var cluster_spread: float = 1.0


## True если группа пустая (нет UnitEntry'ев с count > 0). WaveDirector
## пропускает такие группы.
func is_empty() -> bool:
	for entry in composition:
		if entry != null and entry.scene != null and entry.count > 0:
			return false
	return true


## Общее количество юнитов в группе (сумма count по всем UnitEntry).
## Используется логом / UI для отображения «группа из N».
func total_count() -> int:
	var n: int = 0
	for entry in composition:
		if entry != null and entry.count > 0:
			n += entry.count
	return n
