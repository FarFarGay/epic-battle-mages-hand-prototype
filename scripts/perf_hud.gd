class_name PerfHud
extends CanvasLayer
## Перфоманс-оверлей: FPS, время кадра по подсистемам (process/physics ms),
## render-нагрузка (draw calls + objects), число скелетов с разбивкой по LOD,
## память и общее количество нод. Используется при стресс-тестах больших волн
## (2000+ скелетов) — позволяет быстро локализовать узкое место: CPU-AI
## (process_ms растёт), CPU-physics (physics_ms растёт), GPU/draw calls
## (RENDER_TOTAL_DRAW_CALLS_IN_FRAME растёт). Toggle на F3.
##
## Содержимое и layout — самодостаточно: один Label, который перерисовывает
## строку по таймеру 0.25с. Не подписан ни на чьи сигналы — только пуллит
## состояние группы `Skeleton.SKELETON_GROUP` и `Performance.get_monitor(...)`.
##
## Стоимость HUD'а сама по себе: один проход по группе скелетов + 6 monitor
## reads раз в 0.25с + один Label.text setter. На 2000 врагов — < 0.1мс/обновление.

const UPDATE_INTERVAL: float = 0.25

@export var debug_log: bool = false

@onready var _label: Label = $Panel/Label

var _update_timer: float = 0.0
## FPS-сглаживание по последним N значениям, чтобы не дёргалось от кадра к
## кадру (особенно важно когда сам HUD триггерится в кадре с GC-просадкой).
var _fps_history: Array[float] = []
const FPS_HISTORY_SIZE: int = 8


func _ready() -> void:
	_update_label()  # сразу что-то показать, не ждать первый таймер


func _process(delta: float) -> void:
	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_label()
		_update_timer = UPDATE_INTERVAL


func _unhandled_input(event: InputEvent) -> void:
	# F3 — стандартный hotkey для перфоманс-оверлея в играх. Не регистрируем
	# в InputMap (это debug-инструмент), читаем напрямую из event'а.
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_F3:
			visible = not visible
			if debug_log and LogConfig.master_enabled:
				print("[PerfHud] visible=%s" % visible)
			get_viewport().set_input_as_handled()


func _update_label() -> void:
	if _label == null:
		return
	var fps := _smoothed_fps()
	var skeletons := get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP)
	var near_count := 0
	var mid_count := 0
	var far_count := 0
	for s in skeletons:
		if not is_instance_valid(s):
			continue
		var sk := s as Skeleton
		if sk == null:
			continue
		match sk.get_lod_level():
			Skeleton.LodLevel.NEAR:
				near_count += 1
			Skeleton.LodLevel.MID:
				mid_count += 1
			Skeleton.LodLevel.FAR:
				far_count += 1
	var total := near_count + mid_count + far_count
	# Performance-мониторы: TIME_PROCESS / TIME_PHYSICS_PROCESS возвращают секунды
	# (за последний кадр), поэтому ×1000 → миллисекунды. На 60fps бюджет кадра
	# ~16.6мс — process+physics суммарно должны в него влезать.
	var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# Render-нагрузка: на 2000 уникальных MeshInstance3D ожидаем ~2000 draw calls.
	# Если упрёмся — сигнал к MultiMesh (1 draw call на пачку).
	var draw_calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var render_objects: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	# MEMORY_STATIC — байты выделенные движком (без GPU-памяти). Для контекста.
	var mem_mb: float = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	# OBJECT_NODE_COUNT — все ноды в SceneTree. На стрессе видно, сколько
	# реально живёт скелетов+эффектов+гномов+палаток вместе.
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_label.text = "FPS: %.0f   Process: %.2fms   Physics: %.2fms\nDraw calls: %d   Objects: %d   Mem: %.0f MB   Nodes: %d\nSkeletons: %d (NEAR: %d  MID: %d  FAR: %d)" % [
		fps, process_ms, physics_ms,
		draw_calls, render_objects, mem_mb, nodes,
		total, near_count, mid_count, far_count,
	]


func _smoothed_fps() -> float:
	var current := float(Engine.get_frames_per_second())
	_fps_history.append(current)
	if _fps_history.size() > FPS_HISTORY_SIZE:
		_fps_history.pop_front()
	var sum := 0.0
	for v in _fps_history:
		sum += v
	return sum / float(_fps_history.size())
