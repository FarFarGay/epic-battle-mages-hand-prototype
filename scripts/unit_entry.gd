class_name UnitEntry
extends Resource
## Один тип юнита в составе [CombatGroup] — пара (scene, count). Дизайнер
## кладёт PackedScene и количество, WaveDirector спавнит `count` экземпляров
## scene'ы в общем кластере группы.
##
## Пока в проекте один тип врага (Skeleton), но контракт позволяет добавлять
## вариации (skeleton-archer, mage и т.д.) без правок WaveDirector'а:
## дизайнер создаёт UnitEntry с новой scene'ой, кладёт в группу — и всё.
## Сцена должна быть наследником [Enemy] (иначе forced_target не назначится).

@export var scene: PackedScene = null
@export_range(1, 50) var count: int = 5
