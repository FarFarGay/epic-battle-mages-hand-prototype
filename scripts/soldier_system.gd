extends Node
## Каталог типов солдат и runtime-метаданные. Регистрируется как autoload
## `SoldierSystem`. Симметрично SpellSystem — single source of truth для
## параметров рекрутируемых юнитов.
##
## Дизайнерское решение: melee-юниты (копейщики) призываются как Squad — с
## командной системой (идти/защищать/за башней). Защитники (DefenderGnome,
## лучники) с 2026-05-15 ТОЖЕ призываются через меню, но **не образуют
## Squad** — присоединяются к общему пулу защитников лагеря, распределяются
## по палаткам round-robin'ом, управляются как штатные defender'ы (cone-vision,
## bell-alarm, DefenseMarker'ы). Это даёт игроку рост периметра без отдельного
## контроля «отряда».
##
## Диспетч по типу gnome_class в каталоге: пустое поле (или отсутствует) —
## SoldierGnome flow (Squad); &"defender" — DefenderGnome flow (без Squad,
## tent-bound).
##
## Каталог декларативный — id → Dictionary с полями:
##   - `name`, `description`, `icon_color`
##   - `cost: Dictionary` (ResourceType → amount). Дополнительно к 1 gnome
##     (любая мобилизация требует одного gatherer'а; стоимость в каталоге —
##     это РЕСУРСЫ поверх gnome'а).
##   - `scene: PackedScene` — что инстанцировать (обычно extends SoldierGnome)
##   - `stats: Dictionary` — параметры юнита (hp, vision_radius, attack_range,
##     damage, attack_cooldown, move_speed, …). SoldierGnome.setup_soldier
##     читает отсюда — добавление новых полей не требует правок Camp.
##
## Прокачка пока не реализована (1 уровень на тип). Если придёт время —
## добавим `levels[]` как у SpellSystem.

const PIKEMAN_SCENE: PackedScene = preload("res://scenes/soldier_pikeman.tscn")
const DEFENDER_SCENE: PackedScene = preload("res://scenes/defender_gnome.tscn")

const SOLDIER_CATALOG: Dictionary = {
	&"defender": {
		"name": "Отряд защитников",
		"description": "Отряд из 3 лучников. Привязаны к палаткам, патрулируют периметр, реагируют на тревогу. В формации точность выше.",
		"icon_color": Color(0.78, 0.2, 0.2, 1.0),
		# 3 свободных gatherer'а конвертятся в 3 защитников и распределяются
		# round-robin по живым палаткам (`Camp._recruit_defenders`).
		"squad_size": 3,
		# Cost — за весь отряд. Дерево + железо (древки + наконечники стрел).
		# История: 6w+4i (старт) → 3w+2i (2026-05-17) — ждать рекрут было «прилично»,
		# особенно после перехода стартовых защитников в «производятся за ресурсы».
		# Снижение в 2× ускорило цикл «накопить → нанять» с ~30-60с до ~15-30с.
		# Now defender дешевле per-юнит (1w+0.67i) чем pikeman (1.6w+1i) — по дизайну
		# базовый юнит, дальняя статистика дешевле толстой melee-броня.
		"cost": {ResourcePile.ResourceType.WOOD: 3, ResourcePile.ResourceType.IRON: 2},
		"scene": DEFENDER_SCENE,
		# Маркер для Camp.recruit_squad — диспатч в _recruit_defenders вместо
		# обычного SoldierGnome-flow. Defender'ы используют свои @export'ы
		# (cone_vision_radius, attack_radius, inaccuracy и т.д.), runtime-stats
		# из каталога не применяются — поэтому stats пустой.
		"gnome_class": &"defender",
		"stats": {},
	},
	&"pikeman": {
		"name": "Отряд копейщиков",
		"description": "Отряд из 5 копейщиков. Ближний бой, толстая броня — врываются в скелетов копьём.",
		"icon_color": Color(0.85, 0.55, 0.25, 1.0),
		# Squad — единица призыва: за один recruit-клик конвертится N gatherer'ов
		# в N солдат. Если в лагере свободных гномов < squad_size — призыв
		# невозможен (UI расшифровывает «нужно ≥ N свободных гномов»).
		"squad_size": 5,
		# Cost — за весь отряд, не per-soldier. Дерево + железо (на копья).
		"cost": {ResourcePile.ResourceType.WOOD: 8, ResourcePile.ResourceType.IRON: 5},
		"scene": PIKEMAN_SCENE,
		# Squad charge-ability ([[project-ebm-charge-abilities]]). 5 убийств членами
		# отряда — заряжен; маркер над отрядом ловит hand-slam, бьёт круговой
		# push-волной + damage'ом вокруг центра формации. Тест-значения.
		"charge_max": 5.0,
		# Stats — на одного солдата отряда. Melee: толще (hp), быстрее
		# (move_speed для догона), больно бьёт в упор (damage), чаще чем
		# лучник (cooldown — 1 удар/сек примерно).
		"stats": {
			"hp": 30.0,
			"enemy_detect_radius": 18.0,
			"attack_range": 2.2,
			"attack_damage_min": 22.0,
			"attack_damage_max": 32.0,
			"attack_cooldown_min": 0.6,
			"attack_cooldown_max": 1.0,
			"move_speed": 2.2,
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
