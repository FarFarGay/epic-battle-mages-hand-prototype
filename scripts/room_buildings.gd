class_name RoomBuildings
extends RefCounted
## Каталог построек КОМНАТНОГО режима (level_rooms). Единая простая модель:
## рука тащит силуэт → клик ставит на точку (драг = поворот), площадка-воркер-хаул
## строит здание за ресурс, который гномы доставляют. Отменяет грид/кольца/секторы
## из [CampBuildings]. См. [[project_ebm_building_rework]].
##
## ID-константы зданий. Spawn/размещение — generic: [HandPlaceAim] читает footprint
## для силуэта, [RoomBuildSite] читает resource/needed/scene для стройки. Мост —
## отдельный span-flow ([HandBridgeAim]), в этот каталог не входит.

const WALL := &"wall"
const WATCHTOWER := &"watchtower"

const CATALOG: Dictionary = {
	WALL: {
		"name": "Стена",
		"menu_label": "🧱 Стена",
		# Магнитится к соседним стенам (центр+края) — лабиринт. Башня не магнитится.
		"snap_target": true,
		# Построенное здание = готовый сегмент частокола (DRY: блокировка скелетов,
		# навмеш, разрушаемость, melee-only target уже в нём).
		"scene": "res://scenes/palisade_segment.tscn",
		# Габариты силуэта/футпринта (локальный X — длина вдоль поворота). Длиннее
		# нативного сегмента — стена тянется на несколько метров, строим лабиринт.
		"footprint": Vector3(5.0, 1.5, 0.3),
		# Нативная длина сцены по X (palisade_segment = 2м). RoomBuildSite тянет
		# построенную стену scale.x = footprint.x / native, чтобы совпасть с силуэтом.
		"native_scene_length": 2.0,
		# Чем и сколько «доставок» строит рабочий. WOOD для тестируемости (деревья
		# в сцене есть); тип/количество/стоимость дизайнер крутит здесь.
		"resource_type": ResourcePile.ResourceType.WOOD,
		"resources_needed": 4,
		# Прочность стройплощадки (скелеты могут сорвать стройку).
		"site_hp": 35.0,
		"ghost_color": Color(0.6, 0.8, 1.0, 0.4),
	},
	WATCHTOWER: {
		"name": "Сторожевая башня",
		"menu_label": "🗼 Сторожевая башня",
		# Построенное здание = готовый пост-лучник (DRY: конус обзора, стрельба по
		# врагам, разрушаемость, skeleton-target — всё в archer_post). Это и есть
		# «вмещённый» лучник башни.
		"scene": "res://scenes/archer_post.tscn",
		"footprint": Vector3(1.8, 3.0, 1.8),
		# Строить можно ТОЛЬКО при наличии отряда лучников (их покупают в домах).
		# Гейт проверяет gameplay_hud перед стартом размещения.
		"requires_squad": &"archer_squad",
		"resource_type": ResourcePile.ResourceType.WOOD,
		"resources_needed": 6,
		"site_hp": 50.0,
		"ghost_color": Color(0.7, 0.6, 1.0, 0.45),
	},
}


## Запись каталога или пустой Dictionary для неизвестного id.
static func get_data(id: StringName) -> Dictionary:
	return CATALOG.get(id, {})
