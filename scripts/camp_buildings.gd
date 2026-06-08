class_name CampBuildings
extends RefCounted
## Каталог построек лагеря и helper'ы доступа к данным каталога.
## Spawn-логика (try_build / try_build_palisade_line / _build_* + destroy-handlers
## + _validate_garrison_build) остаётся в [Camp] — она переплетена с
## ресурсами / gatherer-roster / state / списками _bells/_archer_posts.
## Этот модуль выносит только **данные и предикаты по данным**, чтобы
## убрать 70+ строк const Dictionary из camp.gd и дать одно место для
## look-up'ов (которые делает Camp / JournalPanel / HandBuildAim).
##
## ID-константы:
## - `NEW_TENT` — добавить палатку в кольцо лагеря (повторяемо)
## - `PALISADE` — частокол (brush-mode, polyline)
## - `ARCHER_POST` — стрелковый пост, изымает 1 gatherer'а
##
## Camp реэкспортирует эти константы (`Camp.BUILDING_*`) и каталог
## (`Camp.CAMP_BUILDING_CATALOG`) для обратной совместимости callsite'ов.

const NEW_TENT := &"new_tent"
const PALISADE := &"palisade"
const ARCHER_POST := &"archer_post"
const WALL_GATE := &"wall_gate"

# Новые здания грид-базы (ставятся рукой в ячейку BuildGrid соответствующего
# кольца, см. ring_tier). grid_building=true → Журнал не зовёт try_build/aim,
# а спавнит здание в руку (Camp.spawn_building_into_hand).
const GENERATOR := &"generator"
const ARCHER_BARRACKS := &"archer_barracks"
const SPEAR_BARRACKS := &"spear_barracks"
const GNOME_PORTAL := &"gnome_portal"
const WALL := &"wall"

const CATALOG: Dictionary = {
	GENERATOR: {
		"name": "Генератор",
		"description": "Большой блок (внутреннее кольцо). Питает харвестер: 1 генератор — добыча золота идёт медленно, каждый следующий ускоряет её; на 4 генераторах — полная скорость.",
		"cost": {ResourcePile.ResourceType.WOOD: 8, ResourcePile.ResourceType.STONE: 6},
		"deployed_only": true,
		"repeatable": true,
		"grid_building": true,
		"ring_tier": 0,
		"color": Color(1.0, 0.8, 0.2, 1.0),
		# Прочность здания (HP). Скелеты бьют его как палатку/пост. Генератор —
		# крупный, самый прочный из построек.
		"hp": 220.0,
		# Декор-модель поверх сектор-основания (паровая машина). BuildBlock
		# инстансит её на готовом здании; узел "Gear" крутится. Опциональный слот —
		# у других зданий пока нет своих моделей (остаются сектор-блоком).
		"model": "res://models/generator_visual.tscn",
	},
	ARCHER_BARRACKS: {
		"name": "Казарма лучников",
		"description": "Среднее здание (2 мелкие ячейки). Позволяет набирать отряды лучников. Ставится в любой не-генераторной зоне.",
		"cost": {ResourcePile.ResourceType.WOOD: 12, ResourcePile.ResourceType.IRON: 4},
		"deployed_only": true,
		"repeatable": true,
		"grid_building": true,
		"ring_tier": 1,
		"footprint": 2,
		"color": Color(0.4, 0.6, 0.32, 1.0),
		"hp": 150.0,
	},
	SPEAR_BARRACKS: {
		"name": "Казарма копейщиков",
		"description": "Среднее здание (2 мелкие ячейки). Позволяет набирать отряды копейщиков. Ставится в любой не-генераторной зоне.",
		"cost": {ResourcePile.ResourceType.WOOD: 12, ResourcePile.ResourceType.IRON: 8},
		"deployed_only": true,
		"repeatable": true,
		"grid_building": true,
		"ring_tier": 1,
		"footprint": 2,
		"color": Color(0.6, 0.35, 0.3, 1.0),
		"hp": 150.0,
	},
	GNOME_PORTAL: {
		"name": "Гномий портал",
		"description": "Среднее здание (2 мелкие ячейки). Позволяет за золото нанимать гномов группами по 3. Ставится в любой не-генераторной зоне.",
		"cost": {ResourcePile.ResourceType.STONE: 12, ResourcePile.ResourceType.IRON: 6},
		"deployed_only": true,
		"repeatable": true,
		"grid_building": true,
		"ring_tier": 1,
		"footprint": 2,
		"color": Color(0.5, 0.3, 0.7, 1.0),
		"hp": 130.0,
	},
	WALL: {
		"name": "Стена",
		"description": "Тонкая стена в 1 мелкую ячейку. Ставится по одной на любой не-генераторной зоне — стыкуются в линию (кирпичики).",
		"cost": {ResourcePile.ResourceType.STONE: 3},
		"deployed_only": true,
		"repeatable": true,
		"grid_building": true,
		"ring_tier": 1,
		"color": Color(0.55, 0.55, 0.58, 1.0),
		"thin": true,
		# Каменная стена покрепче деревянного частокола (hp=30), но всё ещё
		# расходник — мели-скелеты её прогрызают.
		"hp": 60.0,
	},
	NEW_TENT: {
		"name": "Новая палатка",
		"description": "Добавляет ещё одну палатку в кольцо лагеря — +жителей-собирателей.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 20,
			ResourcePile.ResourceType.STONE: 10,
			ResourcePile.ResourceType.FOOD: 5,
		},
		"deployed_only": true,
		"repeatable": true,
	},
	PALISADE: {
		"name": "Деревянный частокол",
		"description": "Дешёвые сегменты стены 2м длиной. Скелеты ломают их, но тратят на это время — защитники успевают стрелять. Рисуй ломаную линию: ЛКМ ставит точки, ПКМ — построить, Esc — отмена.",
		# brush_mode → стоимость per-segment, total зависит от длины линии.
		# UI рисует «N wood / сегмент» вместо обычного total.
		"cost_per_segment": {ResourcePile.ResourceType.WOOD: 2},
		"deployed_only": true,
		"repeatable": true,
		"brush_mode": true,
		# Длина одного сегмента в метрах. Совпадает с BoxMesh.size.x в
		# palisade_segment.tscn (2м). Polyline AB длиной N разбивается на
		# floor(N / segment_length) сегментов.
		"segment_length": 2.0,
	},
	ARCHER_POST: {
		"name": "Стрелковый пост",
		"description": "Стационарный лучник на башенке. Видит дальше обычного защитника, но только в направлении взгляда — конус света медленно сканирует сектор. Игрок выбирает направление при установке: короткий клик — наружу от лагеря, drag — точное направление.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 8,
			ResourcePile.ResourceType.IRON: 3,
		},
		"deployed_only": true,
		"repeatable": true,
		# Изымает 1 свободного гнома (как watch_bell). Пост — это не палатка, а
		# самостоятельное здание с встроенным лучником; гном «исчезает» из
		# каравана пока пост стоит. На свёртке/разрушении гном возвращается
		# обратно spawn'ом gatherer'а на месте поста (см. _on_archer_post_destroyed).
		"requires_gatherer": true,
		"requires_aim": true,
		# direction-aim mode (drag для направления, короткий клик → наружу от
		# лагеря). См. HandBuildAim — этот флаг переводит start_aim в
		# direction-aim flow с generic dispatch.
		"requires_direction": true,
		# Preview-кольцо размером с площадку поста, ~1.5м.
		"aim_radius": 1.5,
	},
	WALL_GATE: {
		"name": "Ворота",
		"description": "Ворота в частоколе шириной 4м. Своих юнитов пропускают (автоматически открываются), врагов блокируют физически (как обычная стена). Наведи курсор на готовую стену длиной ≥ 4м — превью ворот зелёное = можно ставить, красное = слишком короткая или нет стены. ЛКМ — построить. На месте ворот удаляются 2 сегмента частокола.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 15,
			ResourcePile.ResourceType.IRON: 5,
		},
		"deployed_only": true,
		"repeatable": true,
		"requires_aim": true,
		# Wall-snap aim: курсор магнитится к ближайшему сегменту стены, ось
		# и позиция превью считаются из неё. Цвет = green/red по валидности
		# длины стены. ЛКМ → построить.
		"requires_wall_snap": true,
	},
}


## Data lookup: возвращает запись каталога или пустой Dictionary для
## неизвестного id. Caller достаёт нужные поля через `.get("key", default)`.
static func get_data(id: StringName) -> Dictionary:
	return CATALOG.get(id, {})
