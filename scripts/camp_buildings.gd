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
## - `WATCH_BELL` — сторожевой колокол, изымает 1 gatherer'а
## - `PALISADE` — частокол (brush-mode, polyline)
## - `ARCHER_POST` — стрелковый пост, изымает 1 gatherer'а
##
## Camp реэкспортирует эти константы (`Camp.BUILDING_*`) и каталог
## (`Camp.CAMP_BUILDING_CATALOG`) для обратной совместимости callsite'ов.

const NEW_TENT := &"new_tent"
const WATCH_BELL := &"watch_bell"
const PALISADE := &"palisade"
const ARCHER_POST := &"archer_post"

const CATALOG: Dictionary = {
	NEW_TENT: {
		"name": "Новая палатка",
		"description": "Добавляет ещё одну палатку в кольцо лагеря — +жителей, +лучник, +собиратели.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 20,
			ResourcePile.ResourceType.STONE: 10,
			ResourcePile.ResourceType.FOOD: 5,
		},
		"deployed_only": true,
		"repeatable": true,
	},
	WATCH_BELL: {
		"name": "Сторожевой колокол",
		"description": "Гном-сторож замечает врагов в радиусе и зовёт двух защитников из лагеря. Колокол можно поставить где угодно — например, у источника ресурсов.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 12,
			ResourcePile.ResourceType.IRON: 5,
		},
		"deployed_only": true,
		"repeatable": true,
		"requires_gatherer": true,
		"requires_aim": true,
		# Preview-радиус aim-кольца. Совпадает с WatchBell.alarm_radius (7.5м).
		# Если синхронизировать со сценой нужно динамически — в будущем
		# прочитаем из инстанса при aim_start; пока константа достаточна.
		"aim_radius": 7.5,
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
}


## Data lookup: возвращает запись каталога или пустой Dictionary для
## неизвестного id. Caller достаёт нужные поля через `.get("key", default)`.
static func get_data(id: StringName) -> Dictionary:
	return CATALOG.get(id, {})
