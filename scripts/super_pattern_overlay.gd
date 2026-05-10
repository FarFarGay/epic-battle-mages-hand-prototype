class_name SuperPatternOverlay
extends Control
## QTE-overlay для супер-каста. Поверх гейм-плея появляется фейд + сетка
## точек 3×3, из них N (по умолчанию 4) — «отмечены» как путь. Игрок зажимает
## ПКМ и проводит «нитью» через отмеченные точки в порядке. Отпустил ПКМ
## или задел не ту точку — fail. Прошёл все по порядку — success.
##
## Замедление мира делает не overlay, а координатор (HandSuper) — ставит
## Engine.time_scale = pattern_time_scale на pattern_started сигнал, возвращает
## 1.0 на pattern_succeeded/failed. Сам overlay живёт в обычном времени UI
## (CanvasLayer не подвержен time_scale).
##
## Тайм-аут: pattern_timeout секунд. По истечении — fail. Под slow-mo игроку
## кажется «много времени», в реальных секундах — pattern_timeout * time_scale.
##
## Использование:
##   overlay.start_pattern(4)   # 4 точки в паттерне
##   await overlay.pattern_finished   # bool: true если success
##   queue_free() — overlay сам не убивается, координатор владеет жизненным циклом

signal pattern_started
## Финальный сигнал — bool success. Координатор пишет полную/половинную
## цену списания и переходит дальше по state machine.
signal pattern_finished(success: bool)

## Сколько точек в grid'e (3×3 = 9 кандидатов). Не делаем @export — это
## визуальная константа дизайна, меняется кодом.
const GRID_SIZE: int = 3
## Размер квадрата точечной сетки в пикселях overlay-координат. Точки
## раскладываются по углам и центрам сторон/центра — равномерный grid_size×grid_size.
@export var grid_extent_px: float = 280.0
## Радиус «срабатывания» — мышь ближе чем это к точке = задели её.
## 35px на 280px-grid'e = ~10% от размера, удобно но не тривиально.
@export var snap_radius_px: float = 35.0
## Сколько секунд (real time, без учёта time_scale) даётся игроку на проход
## паттерна. Под slow-mo (time_scale 0.15) реальные 8с ≈ 53с игрового времени.
@export var pattern_timeout: float = 8.0
## Радиус визуальной точки (отмеченные — solid, не отмеченные — пустые dim).
@export var dot_radius_px: float = 14.0
## Толщина «нити» между пройденными точками + от последней до курсора.
@export var line_thickness_px: float = 6.0

@export var debug_log: bool = true

## Все 9 точек grid'а в локальных координатах overlay-Control.
var _points: PackedVector2Array = PackedVector2Array()
## Индексы точек (0..8) в порядке прохождения. Длина = pattern_length из start_pattern().
var _expected_sequence: Array[int] = []
## Сколько точек уже пройдено (0..pattern_length). При успехе == pattern_length.
var _passed_count: int = 0
## Зажат ли сейчас ПКМ. Pattern проверяется только в режиме drag.
var _is_dragging: bool = false
## Текущая позиция курсора в локальных координатах (для отрисовки последней нити).
var _cursor_local: Vector2 = Vector2.ZERO
## Время до тайм-аута (real seconds). Тикает в _process независимо от time_scale.
var _time_remaining: float = 0.0
## Активна ли сейчас QTE-сессия. Между finished и след. start — false, ввод игнорируется.
var _active: bool = false
## Real-time момент passed для каждой точки sequence (-1 если ещё не пройдена).
## Используется для hit-flash на 0.4с после прохождения.
var _hit_flash_at: PackedFloat32Array = PackedFloat32Array()
## Trail курсора: последние позиции с временем добавления, для fading-нити
## за курсором. Каждая запись: Vector3(pos.x, pos.y, ts_seconds).
var _cursor_trail: Array[Vector3] = []
## Real-time старта QTE — на нём базируется _now(). Time_scale не влияет
## (Time.get_ticks_msec возвращает реальное время, не game time).
var _start_msec: int = 0
const TRAIL_LIFETIME: float = 0.4
const HIT_FLASH_DURATION: float = 0.45


func _ready() -> void:
	# Растягиваемся на всё окно — ловим mouse_position в любом месте,
	# даже если grid в центре.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # перехватываем ПКМ от gameplay
	visible = false
	# Сетка GRID_SIZE×GRID_SIZE в локальных координатах overlay'а.
	# Центр overlay = размер_окна/2 на _ready не известен (ноль), пересчитываем
	# на каждый _draw / start_pattern. Точки храним нормированно от центра
	# overlay'а: column-row × cell_size.
	# (Реальные позиции делаются на лету в _world_point(), здесь только индексы.)


## Process независимо от engine time scale — overlay живёт в реал-тайме.
## Сам Control в CanvasLayer уже не подвержен time_scale, но `delta` в _process
## под slow-mo всё ещё уменьшается. Используем тут UNSCALED delta.
func _process(_delta: float) -> void:
	if not _active:
		return
	var real_delta: float = get_process_delta_time() / Engine.time_scale
	_time_remaining -= real_delta
	if _time_remaining <= 0.0:
		_finish(false, "тайм-аут")
		return
	# Чистка trail: записи старше TRAIL_LIFETIME — выбрасываем спереди.
	# Записи приходят упорядоченно по времени, выходим на первой свежей.
	var now: float = _now()
	while _cursor_trail.size() > 0 and now - _cursor_trail[0].z > TRAIL_LIFETIME:
		_cursor_trail.pop_front()
	queue_redraw()


## Точечная позиция (col, row) → локальные коорд. в overlay (центр-anchored).
func _grid_pos(idx: int) -> Vector2:
	var col: int = idx % GRID_SIZE
	var row: int = idx / GRID_SIZE
	var cell: float = grid_extent_px / float(GRID_SIZE - 1)
	var origin: Vector2 = size / 2.0 - Vector2(grid_extent_px, grid_extent_px) / 2.0
	return origin + Vector2(col * cell, row * cell)


## Запуск QTE. pattern_length — сколько точек должен пройти игрок (1..9).
## Sequence генерируется случайно, без повторов, гарантированно валидна.
func start_pattern(pattern_length: int) -> void:
	pattern_length = clampi(pattern_length, 1, GRID_SIZE * GRID_SIZE)
	_expected_sequence = _random_sequence(pattern_length)
	_passed_count = 0
	_is_dragging = false
	_cursor_local = Vector2.ZERO
	_time_remaining = pattern_timeout
	_active = true
	visible = true
	_start_msec = Time.get_ticks_msec()
	_hit_flash_at = PackedFloat32Array()
	_hit_flash_at.resize(pattern_length)
	for i in range(pattern_length):
		_hit_flash_at[i] = -1.0
	_cursor_trail.clear()
	if debug_log and LogConfig.master_enabled:
		print("[SuperPattern] старт, sequence=%s" % str(_expected_sequence))
	pattern_started.emit()
	queue_redraw()


## Реальное время с момента старта QTE (секунды). Не зависит от time_scale —
## используется и для hit-flash, и для cursor-trail.
func _now() -> float:
	return float(Time.get_ticks_msec() - _start_msec) / 1000.0


func _random_sequence(length: int) -> Array[int]:
	var pool: Array[int] = []
	for i in range(GRID_SIZE * GRID_SIZE):
		pool.append(i)
	pool.shuffle()
	var result: Array[int] = []
	for i in range(length):
		result.append(pool[i])
	return result


func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseButton:
		var btn := event as InputEventMouseButton
		if btn.button_index == MOUSE_BUTTON_RIGHT:
			if btn.pressed:
				_start_drag(get_local_mouse_position())
			else:
				_end_drag()
			get_viewport().set_input_as_handled()
		elif btn.button_index == MOUSE_BUTTON_LEFT and btn.pressed:
			# ЛКМ во время QTE — отмена (по UX дизайнерскому решению можно
			# изменить на «не отменяет»; пока просто закрывает QTE как fail).
			_finish(false, "отмена ЛКМ")
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _is_dragging:
		_cursor_local = get_local_mouse_position()
		_cursor_trail.append(Vector3(_cursor_local.x, _cursor_local.y, _now()))
		_check_hit(_cursor_local)


func _start_drag(pos: Vector2) -> void:
	# Первая точка должна быть задета сразу при нажатии (или при последующем
	# motion). Не требуем «начать ровно с первой» — для UX'а удобнее.
	_is_dragging = true
	_cursor_local = pos
	_check_hit(pos)


func _end_drag() -> void:
	if not _is_dragging:
		return
	_is_dragging = false
	# Если все точки пройдены — success. Иначе — fail (отпустил рано).
	if _passed_count >= _expected_sequence.size():
		_finish(true, "пройдено %d точек" % _passed_count)
	else:
		_finish(false, "отпущена ПКМ на %d/%d" % [_passed_count, _expected_sequence.size()])


## Проверяет, попал ли cursor на следующую ожидаемую точку. Если попал —
## продвигает _passed_count. Если попал на «не ту» точку из sequence — fail
## (нельзя прыгать через шаги). Точки вне sequence — игнорируются (можно
## пройти через них).
func _check_hit(cursor: Vector2) -> void:
	if _passed_count >= _expected_sequence.size():
		return
	var snap_sq: float = snap_radius_px * snap_radius_px
	# Сначала проверяем «не ту» — если задели любую точку из sequence, кроме
	# ожидаемой, и она ещё не пройдена — fail. Иначе — пробуем next.
	for i in range(_expected_sequence.size()):
		if i == _passed_count:
			continue  # это ожидаемая, не trip-point
		if i < _passed_count:
			continue  # уже пройдена — не trip-point (нить может пройти повторно)
		var p_idx: int = _expected_sequence[i]
		var p_pos: Vector2 = _grid_pos(p_idx)
		if cursor.distance_squared_to(p_pos) <= snap_sq:
			_finish(false, "задели не ту: индекс %d вместо %d" % [i, _passed_count])
			return
	# Ожидаемая точка
	var expected_pos: Vector2 = _grid_pos(_expected_sequence[_passed_count])
	if cursor.distance_squared_to(expected_pos) <= snap_sq:
		# Помечаем hit-flash на этой (то есть уходящей) точке ДО инкремента,
		# индекс совпадает с _passed_count.
		if _passed_count < _hit_flash_at.size():
			_hit_flash_at[_passed_count] = _now()
		_passed_count += 1
		if debug_log and LogConfig.master_enabled:
			print("[SuperPattern] точка %d пройдена" % _passed_count)
		if _passed_count >= _expected_sequence.size():
			# Не финализируем здесь — ждём release ПКМ. Так UX чувствуется
			# как «ты завершил, но ещё держишь нить»; release = коммит.
			pass


func _finish(success: bool, reason: String) -> void:
	if not _active:
		return
	_active = false
	_is_dragging = false
	visible = false
	if debug_log and LogConfig.master_enabled:
		print("[SuperPattern] %s — %s" % ["SUCCESS" if success else "FAIL", reason])
	pattern_finished.emit(success)


# --- Drawing ---

func _draw() -> void:
	if not _active:
		return
	# Полупрозрачный фейд на весь экран — отделяет UI от gameplay.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.1, 0.75))

	# 1) Все 9 точек: невидимые (вне sequence) — маленький dim круг; sequence —
	# большой золотой; passed — зелёный.
	var sequence_set: Dictionary = {}
	var sequence_order: Dictionary = {}
	for i in range(_expected_sequence.size()):
		sequence_set[_expected_sequence[i]] = true
		sequence_order[_expected_sequence[i]] = i

	var now: float = _now()
	for idx in range(GRID_SIZE * GRID_SIZE):
		var p: Vector2 = _grid_pos(idx)
		if sequence_set.has(idx):
			var order: int = sequence_order[idx]
			var passed: bool = order < _passed_count
			var is_next: bool = order == _passed_count and _passed_count < _expected_sequence.size()
			var color: Color
			var halo_color: Color
			if passed:
				color = Color(0.3, 0.95, 0.4, 1.0)  # зелёный — пройдено
				halo_color = Color(0.3, 0.95, 0.4, 0.35)
			elif is_next:
				color = Color(1.0, 0.85, 0.2, 1.0)  # золотой — текущая
				halo_color = Color(1.0, 0.85, 0.2, 0.45)
			else:
				color = Color(0.85, 0.85, 0.95, 0.85)  # светло-белый — ещё впереди
				halo_color = Color(0.85, 0.85, 0.95, 0.18)

			# Halo: 3 концентрических круга с убывающей opacity. Создаёт мягкий
			# glow без шейдеров. Самый внешний — крупный с малой opacity, ближний
			# к точке — почти полный.
			draw_circle(p, dot_radius_px * 2.4, halo_color * Color(1, 1, 1, 0.35))
			draw_circle(p, dot_radius_px * 1.7, halo_color * Color(1, 1, 1, 0.6))
			draw_circle(p, dot_radius_px * 1.25, halo_color)

			# Pulse-scale на текущей (is_next) — лёгкий вдох-выдох. Использует
			# real-time, не зависит от time_scale.
			var dot_scale: float = 1.0
			if is_next:
				dot_scale = 1.0 + 0.12 * sin(now * 6.0)

			# Hit-flash на недавно пройденной: растущий ring с убывающей alpha.
			if order < _hit_flash_at.size() and _hit_flash_at[order] >= 0.0:
				var dt: float = now - _hit_flash_at[order]
				if dt < HIT_FLASH_DURATION:
					var prog: float = dt / HIT_FLASH_DURATION
					var flash_radius: float = dot_radius_px * (1.0 + prog * 2.5)
					var flash_alpha: float = 1.0 - prog
					draw_arc(p, flash_radius, 0.0, TAU, 32,
						Color(0.4, 1.0, 0.5, flash_alpha), 3.0)

			draw_circle(p, dot_radius_px * dot_scale, color)
			# Цифра порядка внутри точки (1..N)
			var label: String = str(order + 1)
			var font := ThemeDB.fallback_font
			var font_size: int = 16
			var text_size: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
			draw_string(font, p - text_size / 2.0 + Vector2(0, font_size * 0.35),
				label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(0.1, 0.1, 0.1, 1.0))
		else:
			# Не в sequence — маленькая dim-точка (для ориентации в grid'е).
			draw_circle(p, dot_radius_px * 0.4, Color(0.4, 0.4, 0.5, 0.5))

	# 2) Нить — между пройденными точками в порядке + от последней до курсора.
	# Сначала тёмный shadow (ниже на 2px), сверху основная нить — даёт
	# глубину и делает её читаемой на любом фоне.
	if _passed_count > 0:
		for i in range(1, _passed_count):
			var a: Vector2 = _grid_pos(_expected_sequence[i - 1])
			var b: Vector2 = _grid_pos(_expected_sequence[i])
			draw_line(a + Vector2(0, 2), b + Vector2(0, 2), Color(0.2, 0.1, 0.0, 0.5), line_thickness_px + 1.0)
			draw_line(a, b, Color(1.0, 0.85, 0.2, 0.95), line_thickness_px)
		# От последней пройденной до cursor — пока ПКМ зажата
		if _is_dragging:
			var last: Vector2 = _grid_pos(_expected_sequence[_passed_count - 1])
			draw_line(last + Vector2(0, 2), _cursor_local + Vector2(0, 2), Color(0.2, 0.1, 0.0, 0.4), line_thickness_px * 0.8)
			draw_line(last, _cursor_local, Color(1.0, 0.85, 0.2, 0.7), line_thickness_px * 0.7)

	# 2.5) Cursor-trail: точки последних позиций cursor с fading opacity.
	# Создаёт «магический хвост» нити. Точки маленькие, цвет тот же золотой.
	if _is_dragging and _cursor_trail.size() > 1:
		for i in range(_cursor_trail.size() - 1):
			var rec_a: Vector3 = _cursor_trail[i]
			var rec_b: Vector3 = _cursor_trail[i + 1]
			var age_a: float = now - rec_a.z
			if age_a > TRAIL_LIFETIME:
				continue
			var alpha: float = 1.0 - (age_a / TRAIL_LIFETIME)
			# Тонкая линия между соседними trail-точками с fading.
			draw_line(
				Vector2(rec_a.x, rec_a.y),
				Vector2(rec_b.x, rec_b.y),
				Color(1.0, 0.7, 0.3, alpha * 0.6),
				line_thickness_px * 0.4,
			)

	# 3) Прогресс-бар тайм-аута — тонкая полоска снизу overlay'a.
	var bar_height: float = 4.0
	var bar_y: float = size.y - bar_height - 30.0
	var bar_w: float = grid_extent_px
	var bar_x: float = (size.x - bar_w) / 2.0
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_height), Color(0.2, 0.2, 0.25, 0.8))
	var fill_w: float = bar_w * clampf(_time_remaining / pattern_timeout, 0.0, 1.0)
	var fill_color: Color = Color(1.0, 0.85, 0.2, 1.0) if _time_remaining > pattern_timeout * 0.3 else Color(0.95, 0.3, 0.3, 1.0)
	draw_rect(Rect2(bar_x, bar_y, fill_w, bar_height), fill_color)

	# 4) Подсказка сверху grid'а
	var hint_text: String = "Зажми ПКМ и проведи нитью по числам"
	var font := ThemeDB.fallback_font
	var hint_size: Vector2 = font.get_string_size(hint_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 16)
	draw_string(font, Vector2(size.x / 2.0 - hint_size.x / 2.0, size.y / 2.0 - grid_extent_px / 2.0 - 20.0),
		hint_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 16, Color(0.95, 0.95, 1.0, 0.9))
