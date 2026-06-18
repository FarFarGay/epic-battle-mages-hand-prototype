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
const ARCHER_SCENE: PackedScene = preload("res://scenes/archer_soldier.tscn")
## Рабочий — это БУРЫЙ ГНОМ (тело gnome.tscn) с поведением SoldierGnome (squad-команды
## + руб-неси-строй по роли). Не отдельная «модель», а существующий визуал гнома.
const WORKER_SCENE: PackedScene = preload("res://scenes/soldier_worker.tscn")

## Id роли «рабочий» (ключ каталога) — единый источник вместо россыпи литералов
## &"worker" по spawner/HUD/контрактам. SoldierGnome.is_worker() сверяется с ним.
const ROLE_WORKER := &"worker"

const SOLDIER_CATALOG: Dictionary = {
	&"archer_squad": {
		"name": "Отряд лучников",
		"description": "Отряд из 3 лучников. Дальний бой, точность растёт с опытом.",
		"icon_color": Color(0.55, 0.35, 0.75, 1.0),
		# 3 свободных gatherer'а конвертятся в 3 ArcherSoldier — через стандартный
		# SoldierGnome-flow (нет диспатча по gnome_class). Управляется как pikeman:
		# squad-команды Hold/Escort/Defend/Dismiss, sticky-aim ЛКМ.
		"squad_size": 3,
		# Найм гейтится зданием: производить лучников можно ТОЛЬКО при построенной
		# Казарме лучников (Camp.can_recruit_squad / recruit_squad). Отряд спавнится
		# у этой казармы.
		"requires_building": &"archer_barracks",
		# Cost дешевле pikeman'а — лёгкий ranged-юнит без брони.
		"cost": {ResourcePile.ResourceType.WOOD: 3, ResourcePile.ResourceType.IRON: 2},
		"scene": ARCHER_SCENE,
		# ULT — волейный AOE-залп. Заряжается per-выстрел (см.
		# ArcherSoldier._fire_at → _squad.add_charge(1.0)). При charge_max=15
		# (≈ 5 выстрелов на лучника в отряде из 3) — готов.
		"charge_max": 15.0,
		# Stats на одного лучника. Большая дистанция, средний урон, медленный
		# cooldown (по сравнению с pikeman'ом). HP меньше — squishy ranged.
		"stats": {
			"hp": 18.0,
			"enemy_detect_radius": 25.0,
			"attack_range": 22.5,
			"attack_damage_min": 20.0,
			"attack_damage_max": 32.0,
			"attack_cooldown_min": 1.0,
			"attack_cooldown_max": 2.0,
			"move_speed": 1.6,
		},
	},
	&"pikeman": {
		"name": "Отряд копейщиков",
		"description": "Отряд из 5 копейщиков. Ближний бой, толстая броня — врываются в скелетов копьём.",
		"icon_color": Color(0.85, 0.55, 0.25, 1.0),
		# Squad — единица призыва: за один recruit-клик конвертится N gatherer'ов
		# в N солдат. Если в лагере свободных гномов < squad_size — призыв
		# невозможен (UI расшифровывает «нужно ≥ N свободных гномов»).
		"squad_size": 5,
		# Найм гейтится зданием: копейщиков можно производить ТОЛЬКО при построенной
		# Казарме копейщиков. Отряд спавнится у неё.
		"requires_building": &"spear_barracks",
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
			# «Толстая броня» — элитные наёмники прорываются сквозь скелетов. HP 100
			# (было 30, как у скелета) — чтобы 3 копейщика держали натиск толпы.
			"hp": 100.0,
			"enemy_detect_radius": 18.0,
			"attack_range": 2.2,
			"attack_damage_min": 22.0,
			"attack_damage_max": 32.0,
			"attack_cooldown_min": 0.6,
			"attack_cooldown_max": 1.0,
			"move_speed": 2.2,
		},
	},
	&"worker": {
		"name": "Артель рабочих",
		"description": "Гномы-работяги: рубят дерево, носят брёвна, строят мост. Утилита, НЕ воюют — берегите копейщиками.",
		"icon_color": Color(0.7, 0.45, 0.25, 1.0),
		"squad_size": 3,
		# Потолок артели: всего рабочих не больше этого (докупка доливает до капа,
		# выше — нельзя). 0/нет = без потолка (копейщики). Стартовая артель = этот кап.
		"squad_cap": 7,
		# БУРЫЙ ГНОМ (soldier_worker.tscn — тело gnome.tscn) с поведением SoldierGnome.
		# Поведение разводится по роли soldier_type==&"worker" (is_worker): не ищет
		# врага, рубит дерево / носит брёвна / строит, прячется в башню по команде.
		"scene": WORKER_SCENE,
		# Stats рабочего: средний HP (уязвимы, не танки — прячь в башню/прикрывай
		# копейщиками), символический урон (бьют по дереву/стройке, не по врагу).
		"stats": {
			# Переживает удар (даже slam Гиганта 84) — рабочий-утилита не должен
			# гибнуть с одного попадания; прячь в башню/прикрывай копейщиками.
			"hp": 120.0,
			# Большой радиус «вижу цель» — рабочий курсирует дерево↔стройка (до ~20м),
			# не должен стопориться на краю детекта между ними.
			"enemy_detect_radius": 26.0,
			"attack_range": 2.2,
			"attack_damage_min": 4.0,
			"attack_damage_max": 6.0,
			"attack_cooldown_min": 0.8,
			"attack_cooldown_max": 1.2,
			"move_speed": 2.4,
			"color": Color(0.7, 0.45, 0.25, 1.0),
		},
	},
}


## Размер отряда заданного типа (squad_size в каталоге, дефолт 1).
## Используется Camp.recruit_squad и UI-кнопкой призыва.
func get_squad_size(id: StringName) -> int:
	var data: Dictionary = SOLDIER_CATALOG.get(id, {})
	return int(data.get("squad_size", 1))


## Потолок численности отряда этого типа (всего особей). 0 = без потолка.
## Спавнер доливает докупку до капа; стартовая артель рабочих = этот кап.
func get_squad_cap(id: StringName) -> int:
	var data: Dictionary = SOLDIER_CATALOG.get(id, {})
	return int(data.get("squad_cap", 0))


## Полная Dictionary'я каталога для id (name, description, cost, stats, scene).
## Empty Dictionary если id неизвестен.
func get_soldier_data(id: StringName) -> Dictionary:
	return SOLDIER_CATALOG.get(id, {})


## True если id зарегистрирован в каталоге.
func has_soldier(id: StringName) -> bool:
	return SOLDIER_CATALOG.has(id)
