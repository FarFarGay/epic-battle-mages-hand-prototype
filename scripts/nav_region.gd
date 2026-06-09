extends NavigationRegion3D
## Без `class_name` — иначе class_cache требует editor-pass перед --check-only
## (см. memory `reference_godot_class_cache`). Camp.gd зовёт `rebake()` через
## duck-typing (has_method), типизация не нужна.
## Тонкая обёртка над [NavigationRegion3D] с двумя задачами:
##   1. Первичный async bake при загрузке сцены (без него navmesh пуст и
##      `NavigationAgent3D.get_next_path_position` возвращает текущую позицию).
##   2. Публичный API `rebake()` для re-bake'а после изменения статической
##      геометрии (постройка/уничтожение палисада, новой палатки, и т.д.).
##
## Bake идёт через `bake_navigation_mesh(on_thread=true)` — не блокирует
## main thread. Пока bake не завершён, агенты используют **старый**
## (предыдущий) navmesh — пути ещё валидны, только новых препятствий
## пока «не видят». На большом проекте 300×300 первичный bake занимает
## ≈ 100-300мс на background thread'е.
##
## Source geometry — collision shapes на слоях, указанных в
## `navigation_mesh.geometry_collision_mask`. Должен включать TERRAIN
## (ходимая поверхность) + CAMP_OBSTACLE (палатки, палисады).

func _ready() -> void:
	# Defer bake до конца кадра, чтобы все child-узлы scene'ы успели спавниться
	# и зарегистрировать свои StaticBody3D (Ground, Tower, палатки Camp'а).
	# Без defer'а первичный bake может пройти до того как Camp._ready
	# заспавнил палатки, и navmesh не учтёт их как препятствия.
	call_deferred("rebake")
	# Глобальная нотификация на bake — гномы/скелеты сбросят `_nav_last_target`
	# и на следующем _resolve_path_step переcalc'нут path через новый navmesh.
	bake_finished.connect(_on_bake_finished)


func _on_bake_finished() -> void:
	var polys: int = -1
	if navigation_mesh != null:
		polys = navigation_mesh.get_polygon_count()
	if LogConfig.master_enabled:
		print("[NavRegion] bake finished, polygons=%d" % polys)
	EventBus.navmesh_baked.emit()


## Re-bake. Вызывать после спавна/удаления статической геометрии.
## В ИГРЕ — async (on_thread=true): bake идёт в фоновом потоке, главный поток НЕ
## блокируется (карта 300×300 при cell_size=0.3 = ~1M ячеек, sync давал «адские
## пролаги» на каждой постройке). Пока bake идёт, агенты используют старый navmesh;
## по готовности bake_finished → EventBus.navmesh_baked → агенты пересчитают путь.
## В `--headless` async даёт polygons=0 (баг bake'а из server-thread'а) → там sync,
## чтобы verify-прогоны видели реальную геометрию.
func rebake() -> void:
	if navigation_mesh == null:
		push_warning("[NavRegion] navigation_mesh не задан — bake пропущен")
		return
	var on_thread: bool = not OS.has_feature("headless")
	bake_navigation_mesh(on_thread)
