@tool
class_name SpawnZone
extends Node3D
## Зона спавна врагов — прямоугольник `size` (X×Z, в метрах) с центром в
## собственной global_position. Поворот вокруг Y берётся из transform узла —
## зону можно ставить под углом, сэмплирование учитывает basis.
##
## Два аспекта:
##
## 1. **Neutral-спавн** (initial/ramp/replenish/[-debug). EnemySpawner.pick_random_pos
##    выбирает случайную точку в объединении всех SpawnZone-ов площадно-взвешенно.
##    Wave-budget здесь не учитывается — даже исчерпанная зона участвует в
##    neutral-спавне как фоновая «локация».
##
## 2. **Волны (waves)**. Дирижёр `WaveDirector._spawn_wave` ищет SpawnZone-ы с
##    `_waves_left > 0`, выбирает одну (политика — uniform random) и фейерит
##    группу `skeletons_per_wave` скелетов внутри её прямоугольника. После
##    выстрела зовётся `consume_wave()` — _waves_left декрементится. По
##    исчерпанию зона больше не выбирается для волн (в neutral-спавне остаётся).
##
## Рантайм-API для эвентов типа «приход Короля Ночи»:
## - `set_waves(n)` — переписать остаток (например, всем зонам по 50 разом).
## - `add_waves(n)` — прибавить (накопление).
##
## Визуал — плоский box-индикатор `Mesh` (BoxMesh 1×0.04×1) на y=0.05,
## масштабируемый по `size`. @tool-сеттер `size` обновляет индикатор моментально.
## В рантайме (`Engine.is_editor_hint() == false`) Mesh скрывается — зона
## видна только дизайнеру в редакторе.
##
## Зоны собираются один раз в _ready EnemySpawner — рантайм-добавление новых
## SpawnZone-нод после старта сцены не подхватывается (пополнение _waves_left
## существующих зон работает).

## Полные размеры прямоугольника по локальным X (size.x) и Z (size.y) в метрах.
## Y игнорируется — зона плоская. Поворот живёт в transform узла.
@export var size: Vector2 = Vector2(60.0, 60.0):
	set(value):
		size = Vector2(maxf(value.x, 0.0), maxf(value.y, 0.0))
		_refresh_visual()

@export_group("Waves")
## Метаданные: к какой POI «принадлежит» зона. Для прототипа — справочно (для
## дизайна и потенциальных будущих политик дирижёра вроде «бить по POI с
## ближайшим Tower»). Сама привязка ничего не запрещает: дирижёр выбирает зону
## без учёта target_poi в текущей реализации.
@export_node_path("Node3D") var target_poi: NodePath
## Стартовый budget волн с этой зоны. На _ready копируется в `_waves_left`.
## Decrement'ится `consume_wave()` при каждом выстреле дирижёра. По исчерпанию
## (0) — зона тиха, пока кто-то не вызовет `add_waves`/`set_waves`.
@export var wave_count: int = 5
## Сколько скелетов в группе за одну волну с этой зоны.
@export var skeletons_per_wave: int = 10
@export_group("")

var _waves_left: int = 0


func _ready() -> void:
	_refresh_visual()
	_waves_left = wave_count


func _refresh_visual() -> void:
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh == null:
		return
	mesh.scale = Vector3(maxf(size.x, 0.0), 1.0, maxf(size.y, 0.0))
	# Видим только в редакторе — для дизайнера. В игре зона невидима игроку.
	mesh.visible = Engine.is_editor_hint()


## Площадь прямоугольника. EnemySpawner.pick_random_pos взвешивает выбор зоны
## по этой величине, чтобы плотность спавна не зависела от размера зоны.
func area() -> float:
	return maxf(size.x, 0.0) * maxf(size.y, 0.0)


## Текущий остаток budget волн. Дирижёр читает чтобы понять — может ли
## зона ещё фейерить. Геттер вместо прямого доступа к `_waves_left` —
## чтобы внешние не правили счётчик в обход add/set API.
func waves_left() -> int:
	return _waves_left


## Декремент budget на 1. Возвращает true если волна «прошла», false если
## зона уже исчерпана (sanity — дирижёр не должен звать на пустых зонах).
func consume_wave() -> bool:
	if _waves_left <= 0:
		return false
	_waves_left -= 1
	return true


## Накопительное пополнение — для частичных рефиллов (на N штук добавить).
func add_waves(n: int) -> void:
	_waves_left = maxi(_waves_left + n, 0)


## Жёсткая перезапись остатка — для эвентов типа Король Ночи (всем зонам
## ставим по 100 волн разом, забывая что было раньше).
func set_waves(n: int) -> void:
	_waves_left = maxi(n, 0)
