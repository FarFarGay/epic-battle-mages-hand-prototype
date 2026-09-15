extends Control
var arena
var panel: PanelContainer
var font: Font
var title_font: Font
var ink := Color("ede9da")
var muted := Color("9faaa6")
var gold := Color("edb96d")
var teal := Color("71d9c8")
var gun_reticle := Vector2.ZERO
var reticle_alpha := 0.0
var reticle_initialized := false
var crew_button: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	var heading := SystemFont.new()
	heading.font_names = PackedStringArray(["Bahnschrift", "Segoe UI"])
	heading.font_weight = 600
	title_font = heading
	_build_tuning()
	_build_crew_button()

func text_at(pos: Vector2, text: String, size: int = 14, color: Color = ink, heading: bool = false) -> void:
	draw_string(title_font if heading else font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

func _draw() -> void:
	if not arena or not arena.tank:
		return
	var viewport := get_viewport_rect().size
	var ui_scale := minf(viewport.x / 1440.0, viewport.y / 900.0)
	ui_scale = maxf(ui_scale, 0.4)
	var w := viewport.x / ui_scale
	var h := viewport.y / ui_scale
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * ui_scale)
	if arena.tank.dash.is_aiming():
		draw_rect(Rect2(0, 0, w, h), Color(0.01, 0.04, 0.08, 0.22))
	# Open composition: thin rules, large title, instruments around the edges.
	draw_rect(Rect2(0, 0, w, 142), Color(0.035, 0.06, 0.07, 0.55))
	draw_rect(Rect2(0, h - 127, w, 127), Color(0.035, 0.06, 0.07, 0.76))
	text_at(Vector2(38, 36), "E P I C   B A T T L E   M A G E S", 13, gold)
	text_at(Vector2(35, 88), "IRON CITADEL", 43, ink, true)
	text_at(Vector2(38, 118), "ШАГАЮЩАЯ БАШНЯ   /   " + ("ЭКИПАЖ НА БОРТУ" if arena.crew.crewed else "ОТРЯД В ПОЛЕ"), 12, muted)
	draw_line(Vector2(38, 140), Vector2(w - 38, 140), Color(0.7, 0.72, 0.63, 0.25), 1)
	var battle = arena.battle
	var combat_mode: bool = battle.waves_enabled or not battle.enemies.is_empty()
	text_at(Vector2(w - 266, 38), "ВОЛНА %02d  /  СКЕЛЕТЫ И ГРОМИЛЫ" % battle.wave if combat_mode else "01   /   ИСПЫТАТЕЛЬНЫЙ ПОЛИГОН", 11, gold)
	text_at(Vector2(w - 266, 83), "%02d" % (battle.remaining() if combat_mode else arena.kills), 38, ink, true)
	text_at(Vector2(w - 190, 69), "ОСТАЛОСЬ ВРАГОВ" if combat_mode else "МИШЕНЕЙ РАЗБИТО", 11, muted)
	text_at(Vector2(w - 190, 90), "%02d  уничтожено" % battle.kills if combat_mode else "%02d  выстрелов" % arena.tank.shot_count, 12, ink)
	draw_circle(Vector2(w - 260, 116), 3, teal)
	var wave_hint := "ВОССТАНОВЛЕНИЕ МИШЕНЕЙ: 8 СЕК"
	if combat_mode:
		wave_hint = "СБЛИЖЕНИЕ → ЗАМАХ → ВЫПАД"
		if battle.remaining() == 0: wave_hint = "НОВАЯ ВОЛНА: %.0f С  ·  N — СРАЗУ" % maxf(battle.next_wave, 0.0)
		if arena.crew.members.is_empty(): wave_hint = "ОТРЯД ПОГИБ · R — НАЧАТЬ ЗАНОВО"
	text_at(Vector2(w - 249, 121), wave_hint, 10, muted)
	# Tank control hints stay visible throughout the test.
	var on_foot: bool = not arena.crew.crewed
	var drive_label := "ШАГАЮЩИЙ ХОД · SHIFT — КРЕЙСЕР"
	if arena.tank.cruising:
		drive_label = "КРЕЙСЕРСКИЙ ХОД" if arena.tank.speed >= arena.tank.forward_speed * arena.tank.cruise_multiplier * 0.98 else "КРЕЙСЕРСКИЙ РАЗГОН"
	text_at(Vector2(38, h - 96), "ОТРЯД · %d ГНОМОВ" % arena.crew.members.size() if on_foot else drive_label, 11, teal if arena.tank.cruising else gold)
	_key(Vector2(38, h - 78), "W S")
	text_at(Vector2(103, h - 59), "вверх / вниз по экрану", 13, ink)
	_key(Vector2(38, h - 42), "A D")
	text_at(Vector2(103, h - 23), "влево / вправо", 13, ink)
	var center := w * 0.5
	if on_foot:
		_draw_abilities(center, h)
	elif arena.hand.enabled and not arena.tank.dash.is_aiming():
		_draw_hand(center, h)
	else:
		_draw_cannon(center, h)
	var speed: float = arena.crew.motion.length() if on_foot else (arena.tank.velocity.length() if arena.tank.dash.active else absf(arena.tank.speed))
	text_at(Vector2(w - 316, h - 96), "%04.1f" % (speed * 3.6), 26, ink, true)
	text_at(Vector2(w - 231, h - 98), "КМ/Ч", 11, muted)
	text_at(Vector2(w - 316, h - 63), "R  сброс     TAB  настройка фила", 12, ink)
	text_at(Vector2(w - 316, h - 39), "КОЛЕСО  масштаб · зажать — обзор", 12, muted)
	text_at(Vector2(w - 316, h - 18), "=  интерфейс    ESC  выход    M  звук" + (" ВЫКЛ." if arena.sound.muted else ""), 10, muted)
	_draw_crew(w, h)
	_draw_hull()
	if not on_foot:
		_draw_dash()
		_draw_crossbows(w)
	if arena.hit_pulse > 0.0:
		text_at(Vector2(center - 45, 179), "ПОПАДАНИЕ", 13, Color(gold, arena.hit_pulse))
	draw_set_transform(Vector2.ZERO)
	if not arena.tuning_open:
		_draw_crosshair()
	if arena.flash_alpha > 0:
		draw_rect(get_viewport_rect(), Color(1.0, 0.84, 0.52, arena.flash_alpha))

func _draw_cannon(center: float, h: float) -> void:
	if arena.tank.dash.is_aiming():
		var distance: float = arena.tank.position.distance_to(arena.tank.dash.landing)
		text_at(Vector2(center - 186, h - 96), "ПРИЦЕЛ СУПЕРДЭША", 11, muted)
		text_at(Vector2(center - 186, h - 63), "%.1f М  /  11.6 М" % distance, 23, teal, true)
		text_at(Vector2(center - 186, h - 30), "ПРЕГРАДА — РЫВОК ДО СТЕНЫ" if arena.tank.dash.preview_blocked else "МЫШЬ — ТОЧКА ПРИЗЕМЛЕНИЯ", 12, gold if arena.tank.dash.preview_blocked else muted)
		return
	var progress: float = 1.0 - arena.tank.cooldown / arena.tank.reload_time
	var ready: bool = arena.tank.cooldown <= 0.0
	var color := teal if ready else gold
	var status := "ОРУДИЕ ГОТОВО"
	if not ready:
		if progress < 0.16: status = "ОТКАТ"
		elif progress < 0.43: status = "ВЫБРОС ГИЛЬЗЫ"
		elif progress < 0.86: status = "ДОСЫЛАНИЕ СНАРЯДА"
		else: status = "ЗАТВОР ЗАКРЫТ"
	text_at(Vector2(center - 186, h - 96), "ПРИЦЕЛ · 120 ММ     /     F — РУКА", 11, muted)
	text_at(Vector2(center - 186, h - 63), status, 18, color, true)
	text_at(Vector2(center + 129, h - 64), "READY" if ready else "%.1f s" % arena.tank.cooldown, 13, color)
	for i in 32:
		var filled := float(i) / 32.0 < progress
		draw_rect(Rect2(center - 185 + i * 11.5, h - 49, 8.5, 5), color if filled else Color(0.7, 0.7, 0.6, 0.15))
	text_at(Vector2(center - 185, h - 22), "ЛКМ  огонь / удерживать      МЫШЬ  наводка", 12, muted)
	if arena.ready_pulse > 0.0:
		draw_rect(Rect2(center - 193, h - 84, 386, 48), Color(teal, arena.ready_pulse * 0.12))

func _draw_hand(center: float, h: float) -> void:
	var hand = arena.hand
	text_at(Vector2(center - 186, h - 96), "РУКА     /     F — ВЕРНУТЬ ПРИЦЕЛ", 11, teal)
	var label := "ВЗАИМОДЕЙСТВИЕ С МИРОМ"
	if is_instance_valid(hand.held): label = hand.held.get_meta("hand_label", "ГРУЗ В РУКЕ")
	text_at(Vector2(center - 186, h - 63), label, 18, ink, true)
	text_at(Vector2(center - 186, h - 39), "ЛКМ держать — нести · отпустить — положить", 12, muted)
	text_at(Vector2(center - 186, h - 18), "Взмах — бросить · ПКМ — мягко отпустить", 12, muted)

func _draw_abilities(center: float, h: float) -> void:
	var combat = arena.crew.combat
	var cards := [
		["ЛУЧНИКИ", "ЛКМ · удерживать", 0.0, 0.7, "archer_squad"],
		["КОПЕЙЩИКИ", "ПРОБЕЛ · удар", combat.spear_cd, 6.0, "pikeman"],
		["АРТЕЛЬ", "ПКМ · каменный вал", combat.wave_cd, 14.0, "worker"],
		["ОГНЕВИКИ", "ПКМ · огненный залп", combat.mage_cd, 5.0, "fire_mage"]]
	for i in cards.size():
		var card: Array = cards[i]
		var x: float = center - 292 + i * 144
		var available: int = combat._available(card[4]).size()
		var unavailable := "НЕТ БОЙЦОВ" if arena.crew.role_count(card[4]) == 0 else "НЕСУТ ГРУЗ"
		var color: Color = teal if float(card[2]) <= 0.0 else gold
		if available == 0: color = muted
		draw_rect(Rect2(x - 9, h - 109, 137, 95), Color(0.12, 0.19, 0.20, 0.8))
		text_at(Vector2(x, h - 90), card[0], 11, muted)
		text_at(Vector2(x, h - 65), unavailable if available == 0 else ("ГОТОВЫ · %d" % available if float(card[2]) <= 0.0 else "%.1f с" % float(card[2])), 14, color, true)
		draw_rect(Rect2(x, h - 51, 114, 3), Color(0.3, 0.36, 0.33))
		draw_rect(Rect2(x, h - 51, 114 * (1.0 - float(card[2]) / float(card[3])), 3), color)
		text_at(Vector2(x, h - 30), card[1], 10, ink)

func _draw_crew(w: float, h: float) -> void:
	var c = arena.crew
	draw_rect(Rect2(38, 161, 314, 156), Color(0.035, 0.065, 0.07, 0.88))
	draw_line(Vector2(38, 161), Vector2(352, 161), teal, 2.0)
	text_at(Vector2(53, 185), ("ЭКИПАЖ  %d / 9" if c.crewed else "ЭКИПАЖ СНАРУЖИ  %d / 9") % c.members.size(), 13, teal, true)
	var colors := [gold, gold, Color("ad86d4"), Color("ad86d4"), Color("ad86d4"), Color("d9a833"), Color("d9a833"), Color("ff804c"), Color("ff804c")]
	for i in c.roster.size():
		var member = c.roster[i]
		var x: float = 62.0 + i * 32
		var color: Color = muted.darkened(0.5) if member.dead else colors[i]
		draw_circle(Vector2(x, 205), 4.0, color)
		draw_rect(Rect2(x - 5, 211, 10, 9), color)
		if member.dead:
			draw_line(Vector2(x - 7, 202), Vector2(x + 7, 219), Color("d77b65"), 1.5)
		else:
			draw_rect(Rect2(x - 8, 224, 16, 2), muted.darkened(0.5))
			draw_rect(Rect2(x - 8, 224, 16 * member.hp / member.max_hp, 2), color)
		if member.hauling:
			draw_rect(Rect2(x - 6, 196, 12, 4), ink)
	text_at(Vector2(53, 242), "МОНЕТЫ  %03d    ЗАПАСЫ В БАШНЕ  %02d" % [c.loot.coins, c.loot.supplies], 11, gold)
	text_at(Vector2(53, 260), "%d носильщиков · Q — опустить груз" % c.loot.haulers.size() if c.loot.cargo != null else "%d лучн. · %d копья · %d рабоч. · %d мага" % [c.role_count("archer_squad"), c.role_count("pikeman"), c.role_count("worker"), c.role_count("fire_mage")], 10, muted)
	if not arena.tuning_open:
		var label: String = c.context_action().text
		if arena.hand.enabled: label = arena.hand.status_text()
		if arena.camera_rotating: label = "ОБЗОР · ОТПУСТИ КОЛЕСО, ЧТОБЫ ВЕРНУТЬСЯ"
		if arena.tank.dash.is_aiming():
			label = "ПКМ — СУПЕРДЭШ   ·   отпусти SPACE — отмена"
		var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_style_box(_key_style(), Rect2((w - width) * 0.5 - 18, h - 169, width + 36, 31))
		text_at(Vector2((w - width) * 0.5, h - 148), label, 14, teal)
		if c.notice_time > 0.0 and not arena.tank.dash.is_aiming():
			var message: String = c.notice
			var length := font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			draw_rect(Rect2((w - length) * 0.5 - 10, h - 197, length + 20, 22), Color(0.035, 0.065, 0.07, 0.88))
			text_at(Vector2((w - length) * 0.5, h - 182), message, 12, ink)

func _draw_hull() -> void:
	var y := 431.0 if arena.crew.crewed else 330.0
	var hull = arena.tank
	var color := Color("ed8069") if hull.dead or hull.hp < hull.MAX_HP * 0.3 else teal
	draw_rect(Rect2(38, y, 314, 70), Color(0.035, 0.065, 0.07, 0.88))
	text_at(Vector2(53, y + 22), "БАШНЯ РАЗБИТА" if hull.dead else "ПРОЧНОСТЬ БАШНИ", 12, color, true)
	text_at(Vector2(248, y + 22), "%d / %d" % [ceili(hull.hp), int(hull.MAX_HP)], 11, ink)
	draw_rect(Rect2(53, y + 34, 283, 4), Color(0.25, 0.30, 0.29))
	draw_rect(Rect2(53, y + 34, 283 * hull.hp / hull.MAX_HP, 4), color)
	text_at(Vector2(53, y + 58), "ЭКИПАЖ МОЖЕТ ПРОДОЛЖАТЬ БОЙ" if hull.dead else "R — новый бой с полным экипажем", 10, muted)
	if hull.damage_pulse > 0.0:
		draw_rect(Rect2(38, y, 3, 70), Color("ed8069", hull.damage_pulse))

func _draw_dash() -> void:
	var dash = arena.tank.dash
	draw_rect(Rect2(38, 330, 314, 88), Color(0.035, 0.065, 0.07, 0.86))
	var status := "SPACE  ОТПУСТИТЬ — РЫВОК"
	if dash.is_aiming(): status = "СУПЕРДЭШ  ·  ВЫБЕРИ ТОЧКУ"
	elif dash.active: status = "СУПЕРДЭШ" if dash.is_super else "РЫВОК"
	elif dash.cooldown > 0.0: status = "РЫВОК  ·  %.1f С" % dash.cooldown
	text_at(Vector2(53, 352), status, 13, teal, true)
	text_at(Vector2(53, 374), "WASD — курс · держи SPACE → ПКМ", 11, ink)
	draw_rect(Rect2(53, 385, 283, 3), Color(0.25, 0.3, 0.29))
	draw_rect(Rect2(53, 385, 283 * (1.0 - dash.cooldown / dash.COOLDOWN), 3), teal)
	text_at(Vector2(53, 408), "РАЗДАВЛЕНО ПРЕДМЕТОВ  %02d" % arena.props.broken_count, 10, gold)

func _draw_crossbows(w: float) -> void:
	if arena.hand.enabled:
		_draw_cargo(w)
		return
	var gun = arena.tank.crossbows
	var x := w - 352.0
	var loading: bool = gun.reload_left > 0.0
	var color := gold if loading or gun.ammo <= 40 else teal
	draw_rect(Rect2(x, 162, 314, 132), Color(0.035, 0.065, 0.07, 0.86))
	text_at(Vector2(x + 15, 185), "БОРТОВЫЕ АРБАЛЕТЫ", 12, muted)
	text_at(Vector2(x + 15, 221), "%03d" % gun.ammo, 32, color, true)
	text_at(Vector2(x + 80, 219), "/ 200", 16, muted)
	var status := "%.1f С" % gun.reload_left if loading else ("ОЧЕРЕДЬ" if gun.firing_pulse > 0.0 else "ГОТОВЫ")
	text_at(Vector2(x + 207, 219), status, 13, color)
	var fraction: float = 1.0 - gun.reload_left / gun.RELOAD_TIME if loading else float(gun.ammo) / gun.CAPACITY
	for i in 20:
		draw_rect(Rect2(x + 15 + i * 14.2, 235, 11, 5), color if float(i) / 20.0 < fraction else Color(0.25, 0.30, 0.29))
	var hint := "ПЕРЕЗАРЯДКА  ·  ЗАМЕНА ОБОЙМЫ" if loading else "ПКМ  удерживать  ·  20 болтов/с"
	if arena.tank.dash.is_aiming(): hint = "ПРИЦЕЛ СУПЕРДЭША  ·  ОГОНЬ ЗАКРЫТ"
	text_at(Vector2(x + 15, 262), hint, 11, ink)
	text_at(Vector2(x + 15, 281), "АВТОПЕРЕЗАРЯДКА  ·  7 СЕК", 10, muted)
	if gun.firing_pulse > 0.0 or gun.ready_pulse > 0.0:
		draw_rect(Rect2(x, 162, 3, 132), Color(color, maxf(gun.firing_pulse, gun.ready_pulse)))

func _draw_cargo(w: float) -> void:
	var x := w - 352.0
	var hand = arena.hand
	draw_rect(Rect2(x, 162, 314, 132), Color(0.035, 0.065, 0.07, 0.86))
	draw_line(Vector2(x, 162), Vector2(x + 314, 162), teal, 2.0)
	text_at(Vector2(x + 15, 185), "ГРУЗ НА БАШНЕ · 1 МЕСТО", 12, teal)
	var cargo: String = hand.mounted.get_meta("hand_label", "ГРУЗ") if is_instance_valid(hand.mounted) else "КРЕПЛЕНИЕ СВОБОДНО"
	text_at(Vector2(x + 15, 215), cargo, 16, ink, true)
	text_at(Vector2(x + 15, 242), "Схвати груз на крыше, чтобы снять" if is_instance_valid(hand.mounted) else "Отпусти груз рядом с башней", 12, muted)
	text_at(Vector2(x + 15, 265), "КУБ → ГНЕЗДО → ОТКРЫТЬ ВОРОТА", 11, gold)
	text_at(Vector2(x + 15, 284), "ДОСЯГАЕМОСТЬ РУКИ · 18 М", 10, muted)

func _build_crew_button() -> void:
	crew_button = Button.new()
	add_child(crew_button)
	crew_button.focus_mode = Control.FOCUS_NONE
	crew_button.add_theme_stylebox_override("normal", _key_style())
	crew_button.add_theme_font_size_override("font_size", 13)
	crew_button.add_theme_color_override("font_color", teal)
	crew_button.pressed.connect(func():
		arena.crew.board_requested = true
		arena.crew.input_armed = false
		arena.tank.buffered_shot = 0.0)

func pointer_over_ui() -> bool:
	if not is_visible_in_tree(): return false
	var cursor := get_viewport().get_mouse_position()
	return (panel.visible and panel.get_global_rect().has_point(cursor)) or crew_button.get_global_rect().has_point(cursor)

func _key(pos: Vector2, label: String) -> void:
	draw_style_box(_key_style(), Rect2(pos, Vector2(51, 27)))
	text_at(pos + Vector2(10, 18), label, 12, ink)

func _key_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.25, 0.30, 0.30, 0.45)
	style.border_color = Color(0.65, 0.68, 0.61, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	return style

func _draw_crosshair() -> void:
	if arena.camera_rotating: return
	if arena.tank.dash.is_aiming():
		var landing: Vector2 = arena.aim_camera.unproject_position(arena.tank.dash.landing)
		var color := gold if arena.tank.dash.preview_blocked else teal
		draw_arc(landing, 11.0, 0, TAU, 32, color, 2.0, true)
		draw_circle(landing, 2.0, color)
		return
	if arena.hand.enabled:
		_draw_hand_cursor()
		return
	var cursor := get_viewport().get_mouse_position()
	if arena.test_aim:
		cursor = arena.aim_camera.unproject_position(arena.aim_position)
	var p := gun_reticle
	var ready: bool = not arena.crew.crewed or arena.tank.cooldown <= 0.0
	var col := ink if ready else gold
	var gap := 7.0
	for axis in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(cursor + axis * gap, cursor + axis * (gap + 8), Color(0.04, 0.06, 0.07, 0.8), 4.0, true)
		draw_line(cursor + axis * gap, cursor + axis * (gap + 8), col, 1.5, true)
	draw_circle(cursor, 1.8, col)
	if not ready:
		draw_arc(cursor, 24, -PI / 2, -PI / 2 + TAU * (1.0 - arena.tank.cooldown / arena.tank.reload_time), 48, gold, 2.0, true)
	if reticle_alpha > 0.01 and arena.crew.crewed:
		draw_arc(p, 6.0, 0, TAU, 24, Color(gold, reticle_alpha), 1.4, true)
		draw_circle(p, 1.5, Color(gold, reticle_alpha))
		var distance := p.distance_to(cursor)
		var link_alpha := smoothstep(24.0, 64.0, distance) * (1.0 - smoothstep(300.0, 420.0, distance)) * reticle_alpha
		if link_alpha > 0.01:
			for i in range(1, 9):
				draw_circle(p.lerp(cursor, i / 10.0), 1.0, Color(gold, 0.30 * link_alpha))
	if arena.hit_pulse > 0.0:
		for dir in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			draw_line(cursor + dir * 18, cursor + dir * 25, Color(gold, arena.hit_pulse), 2, true)

func _draw_hand_cursor() -> void:
	if arena.pointer_over_ui(): return
	var hand = arena.hand
	var cursor: Vector2 = hand.test_pointer if hand.test_pointer.is_finite() else get_viewport().get_mouse_position()
	var color: Color = gold if is_instance_valid(hand.candidate) or hand.snap_destination != "" else teal
	if not hand.cursor_valid: color = Color("ed8069")
	# A glove silhouette, rather than a weapon crosshair. The world palm closes on grab.
	var points := PackedVector2Array([Vector2(-6, 12), Vector2(-14, 1), Vector2(-13, -3), Vector2(-10, -3), Vector2(-6, 2), Vector2(-6, -12), Vector2(-3, -15), Vector2(0, -12), Vector2(0, -3), Vector2(1, -3), Vector2(1, -17), Vector2(3, -19), Vector2(6, -16), Vector2(6, -3), Vector2(7, -3), Vector2(7, -13), Vector2(9, -15), Vector2(12, -12), Vector2(12, -1), Vector2(13, -1), Vector2(13, -7), Vector2(15, -9), Vector2(18, -6), Vector2(18, 6), Vector2(12, 14)])
	if is_instance_valid(hand.held):
		points = PackedVector2Array([Vector2(-7, 13), Vector2(-14, 3), Vector2(-14, -3), Vector2(-10, -5), Vector2(-5, 0), Vector2(-5, -7), Vector2(0, -10), Vector2(5, -8), Vector2(10, -8), Vector2(15, -4), Vector2(16, 6), Vector2(10, 14)])
	draw_set_transform(cursor)
	draw_colored_polygon(points, Color(0.035, 0.065, 0.07, 0.94))
	points.append(points[0])
	draw_polyline(points, color, 2.0, true)
	draw_set_transform(Vector2.ZERO)
	if hand.snap_destination != "": draw_arc(cursor, 27, 0, TAU, 40, gold, 2.0, true)

func reset_reticle() -> void:
	reticle_initialized = false
	reticle_alpha = 0.0

func update_reticle(dt: float) -> void:
	if not arena.crew.crewed or arena.hand.enabled or arena.camera_rotating:
		reticle_alpha = 0.0
		return
	# Damping affects only the HUD. Hits still use the current muzzle ray.
	var desired: Vector2 = arena.aim_camera.unproject_position(arena.actual_hit)
	var visible_hit: bool = desired.is_finite() and get_viewport_rect().grow(-20).has_point(desired) and not arena.aim_camera.is_position_behind(arena.actual_hit)
	reticle_alpha = lerpf(reticle_alpha, 1.0 if visible_hit else 0.0, 1.0 - exp(-dt * 20.0))
	if not visible_hit:
		return
	if not reticle_initialized:
		gun_reticle = desired
		reticle_initialized = true
	else:
		var movement := (desired - gun_reticle) * (1.0 - exp(-dt * 16.0))
		gun_reticle += movement.limit_length(1200.0 * dt)

func _build_tuning() -> void:
	panel = PanelContainer.new()
	add_child(panel)
	panel.position = Vector2(1030, 166)
	panel.custom_minimum_size = Vector2(365, 440)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color("142328")
	style.border_color = Color("8b7955")
	style.set_border_width_all(1)
	style.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = "НАСТРОЙКА ФИЛА"
	title.add_theme_color_override("font_color", gold)
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	_slider(box, "Запаздывание наводки", 0.04, 0.5, arena.tank.aim_lag, func(v: float): arena.tank.aim_lag = v, " с")
	_slider(box, "Перезарядка", 0.65, 3.0, arena.tank.reload_time, func(v: float):
		var fraction: float = arena.tank.cooldown / arena.tank.reload_time
		arena.tank.reload_time = v
		arena.tank.cooldown = fraction * v, " с")
	_slider(box, "Отдача", 0.3, 1.8, arena.tank.recoil_force, func(v: float): arena.tank.recoil_force = v, "")
	_slider(box, "Удар камеры", 0.0, 1.7, arena.shake_strength, func(v: float): arena.shake_strength = v, "")
	_slider(box, "Скорость башни", 3.0, 10.0, arena.tank.forward_speed, func(v: float): arena.tank.forward_speed = v, " м/с")
	_slider(box, "Отзывчивость хода", 0.6, 1.6, arena.tank.drive_response, func(v: float): arena.tank.drive_response = v, "×")
	var note := Label.new()
	note.text = "Изменения действуют сразу.\nTAB — вернуться в игру."
	note.add_theme_font_size_override("font_size", 13)
	note.modulate = muted
	box.add_child(note)
	panel.hide()

func _slider(parent: VBoxContainer, title: String, minimum: float, maximum: float, value: float, callback: Callable, suffix: String) -> void:
	var row := VBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title + "   %.2f" % value + suffix
	label.add_theme_font_size_override("font_size", 13)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.01
	slider.value = value
	slider.custom_minimum_size.y = 20
	row.add_child(slider)
	slider.value_changed.connect(func(v: float):
		callback.call(v)
		label.text = title + "   %.2f" % v + suffix)

func _process(_dt: float) -> void:
	if panel:
		panel.position = Vector2(maxf(16, get_viewport_rect().size.x - 410), 160)
	if crew_button:
		var viewport := get_viewport_rect().size
		var factor := maxf(0.4, minf(viewport.x / 1440.0, viewport.y / 900.0))
		crew_button.position = Vector2(53, 274) * factor
		crew_button.size = Vector2(284, 29)
		crew_button.scale = Vector2.ONE * factor
		crew_button.text = "ВЫСАДИТЬ ЭКИПАЖ  [E]" if arena.crew.crewed else "СЕСТЬ В БАШНЮ  ·  %d м" % int(arena.crew.board_distance())
		if arena.crew.members.is_empty(): crew_button.text = "ОТРЯД ПОГИБ  ·  R — ЗАНОВО"
		elif arena.tank.dead and not arena.crew.crewed: crew_button.text = "БАШНЯ РАЗБИТА"
		crew_button.disabled = arena.tuning_open or arena.crew.members.is_empty() or (arena.tank.dead and not arena.crew.crewed)
