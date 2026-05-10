extends Node
## Каталог типов солдат и runtime-метаданные. Регистрируется как autoload
## `SoldierSystem`. Симметрично SpellSystem — single source of truth для
## параметров рекрутируемых юнитов.
##
## Каталог декларативный — id → Dictionary с полями:
##   - `name`, `description`, `icon_color`
##   - `cost: Dictionary` (ResourceType → amount). Дополнительно к 1 gnome
##     (любая мобилизация требует одного gatherer'а; стоимость в каталоге —
##     это РЕСУРСЫ поверх gnome'а).
##   - `scene: PackedScene` — что инстанцировать (обычно extends SoldierGnome)
##   - `stats: Dictionary` — параметры юнита (hp, attack_radius, damage,
##     attack_cooldown, move_speed, …). SoldierGnome.setup_soldier читает
##     отсюда — добавление новых полей не требует правок Camp.
##
## Прокачка пока не реализована (1 уровень на тип). Если придёт время —
## добавим `levels[]` как у SpellSystem.

const ARCHER_SCENE: PackedScene = preload("res://scenes/soldier_archer.tscn")

const SOLDIER_CATALOG: Dictionary = {
	&"archer": {
		"name": "Отряд лучников",
		"description": "Отряд из 5 лучников. Дальняя атака стрелами, тонкая броня — держатся сзади.",
		"icon_color": Color(0.4, 0.65, 1.0, 1.0),
		# Squad — единица призыва: за один recruit-клик конвертится N gatherer'ов
		# в N солдат. Если в лагере свободных гномов < squad_size — призыв
		# невозможен (UI расшифровывает «нужно ≥ N свободных гномов»).
		"squad_size": 5,
		# Cost — за весь отряд, не per-soldier. Дизайнер крутит цифры по фану.
		"cost": {ResourcePile.ResourceType.WOOD: 12, ResourcePile.ResourceType.IRON: 3},
		"scene": ARCHER_SCENE,
		# Stats — на одного солдата отряда. Параметры боевого поведения
		# применяются к каждому SoldierGnome через setup_soldier.
		"stats": {
			"hp": 22.0,
			"attack_radius": 18.0,
			"attack_damage_min": 18.0,
			"attack_damage_max": 28.0,
			"attack_cooldown_min": 1.0,
			"attack_cooldown_max": 1.8,
			"move_speed": 1.8,
		},
	},
}


## Размер отряда заданного типа (squad_size в каталоге, дефолт 1).
## Используется Camp.recruit_squad и UI-кнопкой призыва.
func get_squad_size(id: StringName) -> int:
	var data: Dictionary = SOLDIER_CATALOG.get(id, {})
	return int(data.get("squad_size", 1))


## Полная Dictionary'я каталога для id (name, description, cost, stats, scene).
## Empty Dictionary если id неизвестен.
func get_soldier_data(id: StringName) -> Dictionary:
	return SOLDIER_CATALOG.get(id, {})


## True если id зарегистрирован в каталоге.
func has_soldier(id: StringName) -> bool:
	return SOLDIER_CATALOG.has(id)
