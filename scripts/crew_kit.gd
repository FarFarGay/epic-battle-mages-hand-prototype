class_name CrewKit
extends RefCounted
## ⭐ ЕДИНАЯ СБОРКА ГНОМА (2026-08-11). Один способ родить гнома-экипажа — и в
## подземелье, и в большом мире. Раньше их было два: данж лепил бойца сам
## (каталожная сцена + данж-статы + блочный скин), а мир спавнил ГРАЖДАНСКОГО
## рабочего лагеря с каталожной скоростью 2.2 и рабочим AI. Из-за этого «те же
## гномы» в двух эпизодах выглядели и ехали по-разному — а поверх ещё стоял
## контроллер, который пытался их вести. Отсюда весь брак.
##
## ПРАВИЛО: гном рождается ТОЛЬКО здесь. Хочешь поменять модель, скорость или
## сцепление — правишь одно место, и оба эпизода меняются вместе.
##
## Модели держим ТУТ ЖЕ (skin_artel / skin_fire_mage): «модель» — часть того,
## как выглядит класс, и разъезжаться с его статами она не должна.

## Класс-лучник в каталоге SoldierSystem (в отряде — «полив»).
const ARCHER := &"archer_squad"

## Кнопки отряда. Кнопка называет НЕ способность, а СЛОТ: кто на неё назначен,
## тот по ней и работает (SoldierGnome.bind_slot).
const BIND_LKM: int = 0
const BIND_SPACE: int = 1
const BIND_RMB: int = 2

## Раскладка «из коробки»: лучники поливают по ЛКМ, копейщики бьют по ПРОБЕЛУ,
## спецы (артель/огневики) работают по ПКМ.
const DEFAULT_BIND := {
	ARCHER: BIND_LKM,
	&"pikeman": BIND_SPACE,
	&"worker": BIND_RMB,
	&"fire_mage": BIND_RMB,
}


## Настройки сборки. Числа — финальные из данжа: они прошли три итерации
## фидбека по «феелу» twin-stick, заново их не подбираем НИГДЕ.
static func default_cfg() -> Dictionary:
	return {
		# Бодрый twin-stick: у слота юниты ходят на BASE move_speed (спринт
		# только вдали) — каталожные 1.6–2.2 давали «вязкую» группу.
		"unit_speed": 8.0,
		"grip": 16.0,
		# Мягкий подход к слоту: лечит дрожь при отходе строя спиной.
		"arrival_damp": 1.6,
		# Данж-баланс лучника + steer_inertia>0: выстрел НЕ стопит бег —
		# полив на ходу, ядро twin-stick-феела.
		"archer_range": 12.0,
		"archer_cd_min": 0.64,
		"archer_cd_max": 0.76,
		"archer_dmg_min": 8.0,
		"archer_dmg_max": 12.0,
		"archer_steer_inertia": 2.6,
		# Копейщик НЕ ВОЮЕТ САМ: детект 0 → цель не находится → ни погони, ни
		# укола. Между супер-ударами он тело в строю, вся его работа — ПРОБЕЛ.
		"spear_detect": 0.0,
		"punch_speed": 28.0,
		"stamina_hits": 0,
		"stamina_restore": 0.6,
		"stamina_delay": 0.9,
		"quiver_size": 5,
		"quiver_reload": 0.08,
		"quiver_delay": 0.8,
		"quiver_decor": 6,
	}


static func default_bind_for(cls: StringName) -> int:
	return int(DEFAULT_BIND.get(cls, BIND_LKM))


## Родить одного бойца экипажа: каталожная сцена + статы отряда + модель класса.
## В отряд НЕ добавляет и на сигналы не подписывает — это дело вызывающего
## (у данжа и мира разный учёт потерь). Возвращает null, если класса нет.
##
## escort — узел, за которым боец таскается, когда отряд не под управлением
## (в данже это баннер строя, в мире — фокус камеры отряда).
static func create_soldier(parent: Node, t: StringName, at: Vector3,
		cfg: Dictionary, escort: Node3D = null) -> SoldierGnome:
	if SoldierSystem == null:
		return null
	var data: Dictionary = SoldierSystem.get_soldier_data(t)
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("[CrewKit] нет сцены для %s в SOLDIER_CATALOG" % t)
		return null
	var stats: Dictionary = (data.get("stats", {}) as Dictionary).duplicate()
	stats["move_speed"] = float(cfg.get("unit_speed", 8.0))
	stats["caravan_sprint_speed"] = float(cfg.get("unit_speed", 8.0)) * 1.3
	stats["steer_grip"] = float(cfg.get("grip", 16.0))
	if t == ARCHER:
		stats["attack_range"] = float(cfg.get("archer_range", 12.0))
		stats["attack_cooldown_min"] = float(cfg.get("archer_cd_min", 0.64))
		stats["attack_cooldown_max"] = float(cfg.get("archer_cd_max", 0.76))
		stats["attack_damage_min"] = float(cfg.get("archer_dmg_min", 8.0))
		stats["attack_damage_max"] = float(cfg.get("archer_dmg_max", 12.0))
		stats["steer_inertia"] = float(cfg.get("archer_steer_inertia", 2.6))
	elif t == &"pikeman":
		stats["enemy_detect_radius"] = float(cfg.get("spear_detect", 0.0))
	var soldier := scene.instantiate() as SoldierGnome
	if soldier == null:
		return null
	# LOD выключен + телесность со скелетами: в кастомных сценах дальний режим
	# гоняет юнита БЕЗ коллизий — он улетал сквозь стены.
	soldier.lod_far_distance = 100000.0
	soldier.lod_offscreen_half_angle_deg = 90.0
	soldier.collision_mask |= Layers.ENEMIES
	soldier.arrival_damp_radius = float(cfg.get("arrival_damp", 1.6))
	parent.add_child(soldier)
	soldier.setup_free(t, stats, at, escort)
	if t == ARCHER:
		# С первого кадра под гейтом прицела: до первого тика боевого кода
		# дефолтный false давал 1-2 «левых» выстрела по видимым.
		soldier.fire_suppressed = true
		if soldier is ArcherSoldier:
			var qs: int = int(cfg.get("quiver_size", 5))
			if qs > 0:
				(soldier as ArcherSoldier).setup_quiver(qs,
						float(cfg.get("quiver_reload", 0.08)),
						float(cfg.get("quiver_delay", 0.8)))
			else:
				(soldier as ArcherSoldier).setup_quiver_decor(int(cfg.get("quiver_decor", 6)))
	elif t == &"pikeman":
		# Оборона по умолчанию: укол с места, из строя не выходит.
		soldier.hold_ground = true
		soldier.punch_speed = float(cfg.get("punch_speed", 28.0))
		var sh: int = int(cfg.get("stamina_hits", 0))
		if sh > 0:
			soldier.setup_stamina(sh, float(cfg.get("stamina_restore", 0.6)),
					float(cfg.get("stamina_delay", 0.9)))
	elif t == &"worker":
		skin_artel(soldier)
	elif t == &"fire_mage":
		skin_fire_mage(soldier)
	soldier.bind_slot = default_bind_for(t)
	return soldier


# --- Модели классов ----------------------------------------------------------
# Блочные модельки поверх спрятанного GLB-тела: артельщик и огневик читаются
# силуэтом (молоток / посох), а не только цветом.


static func skin_artel(w: Node3D) -> void:
	var holder := _skin_holder(w)
	var cloth := _mat(Color(0.85, 0.66, 0.2))
	var skin := _mat(Color(0.85, 0.7, 0.55))
	var wood := _mat(Color(0.3, 0.2, 0.12))
	var steel := _mat(Color(0.72, 0.74, 0.8))
	_box(holder, Vector3(0.34, 0.5, 0.26), Vector3(0, 0.45, 0), cloth)      # тело
	_box(holder, Vector3(0.26, 0.26, 0.24), Vector3(0, 0.82, 0), skin)      # голова
	_box(holder, Vector3(0.05, 0.55, 0.05), Vector3(0.24, 0.6, 0), wood)    # рукоять молотка
	_box(holder, Vector3(0.16, 0.1, 0.1), Vector3(0.24, 0.92, 0), steel)    # боёк молотка
	_box(holder, Vector3(0.3, 0.42, 0.06), Vector3(-0.2, 0.55, 0.14), wood) # заплечная доска


static func skin_fire_mage(w: Node3D) -> void:
	var holder := _skin_holder(w)
	var robe := _mat(Color(0.78, 0.2, 0.12))
	var skin := _mat(Color(0.85, 0.7, 0.55))
	var wood := _mat(Color(0.3, 0.2, 0.12))
	var ember := _mat(Color(1.0, 0.55, 0.15))
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.45, 0.1)
	ember.emission_energy_multiplier = 1.6
	_box(holder, Vector3(0.34, 0.5, 0.26), Vector3(0, 0.45, 0), robe)       # роба
	_box(holder, Vector3(0.26, 0.26, 0.24), Vector3(0, 0.82, 0), skin)      # голова
	_box(holder, Vector3(0.2, 0.16, 0.2), Vector3(0, 0.98, 0), robe)        # капюшон
	_box(holder, Vector3(0.05, 0.9, 0.05), Vector3(0.24, 0.55, 0), wood)    # посох
	_box(holder, Vector3(0.12, 0.12, 0.12), Vector3(0.24, 1.05, 0), ember)  # навершие
	w.set_meta(&"fire_mage_ember", ember)


## Прячем штатное тело и вешаем узел под блоки. Скин зовут и на уже одетом
## гноме (пересборка витрины) — второй holder не плодим.
static func _skin_holder(w: Node3D) -> Node3D:
	var vis := w.get_node_or_null("Visual") as Node3D
	if vis != null:
		vis.visible = false
	var mesh_node := w.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_node != null:
		mesh_node.visible = false
	var old := w.get_node_or_null("CrewSkin") as Node3D
	if old != null:
		old.queue_free()
	var holder := Node3D.new()
	holder.name = "CrewSkin"
	holder.position = Vector3(0, -0.4, 0)
	w.add_child(holder)
	return holder


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
