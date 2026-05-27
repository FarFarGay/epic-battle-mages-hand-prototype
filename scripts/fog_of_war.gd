class_name FogOfWar
extends Node3D
## Туман войны Tier 3 (2026-05-17) — persistent visibility с decay.
##
## Архитектура:
## - **CPU visibility texture**: `Image` 128×128 L8 (греха per-pixel CPU
##   loop'а нет — 16K элементов × 10Hz, <1мс/тик). Каждый тик все пиксели
##   умножаются на `DECAY_PER_TICK` (медленное «забывание»), затем вокруг
##   каждой vision-point рисуется soft circle (max-blend с soft-falloff).
##   Эффект: вход юнита → быстро светлеет (max клиппится в 1.0 в центре);
##   выход → медленно темнеет; долго не заходил → темно как «никогда не был».
## - **Shader sampling**: fog plane material читает текстуру по world-XZ →
##   UV. Alpha = (1 - visibility) × fog_color.a. См. shaders/fog_of_war.gdshader.
## - **Enemy hiding**: каждые UPDATE_INTERVAL врaги вне visibility = 0.5 thresh
##   получают `visible = false`. Физика продолжает работать.
##
## Tier 2 (uniform array) → Tier 3 (texture) — 2026-05-17. Tier 2 не имел
## persistent memory: вход юнита моментально просветлял (alpha snap 1→0),
## выход моментально темнил. Сейчас оба перехода плавные через CPU-decay.

const MAP_HALF: float = 150.0  ## Совпадает с половиной размера Ground (300×300).
const TEX_SIZE: int = 128       ## Разрешение visibility-текстуры (1.17 м/пиксель).
const UPDATE_INTERVAL: float = 0.1  ## 10Hz обновление декей + paint.

## Множитель затухания за тик. История: 0.99 (50% за 7с, 5% за 30с) →
## 0.995 (50% за 14с, 5% за 60с, 1% за ~90с) — рассеянные зоны держатся
## заметно дольше, у магии и огня появляется долговременный «след» на карте.
## Меньше = быстрее «возвращается туман»; больше = «помним дольше».
const DECAY_PER_TICK: float = 0.995
## Минимальный декей-floor — пиксель не обнуляется до 0, оставляя 0..MIN
## «лёгкого следа». 0 = полное забывание. Малое (0.05) даёт тонкую разницу
## между «никогда не был» и «был давно».
const DECAY_FLOOR: float = 0.0

## Порог visibility, ниже которого враги невидимы. 0.3 = «надо хоть слегка
## осветить точку чтобы враг появился». Hysteresis: невидимый показывается
## при visibility ≥ 0.4 (выше threshold), видимый прячется при ≤ 0.2 (ниже).
const ENEMY_VISIBLE_THRESHOLD_ON: float = 0.4
const ENEMY_VISIBLE_THRESHOLD_OFF: float = 0.2

## Tower — мобильный маяк зрения. Шаги 45→200→160→130→120→45→20м.
## После 2026-05-18 (hard-core + soft-edge falloff в _paint_soft_circle) круги
## стали ярче по всей площади, а не только в центре. 45м всё ещё было «слишком
## большой ауры» — когда игрок впервые ставит башню в темноте, эффект
## «рассекаю мглу» не читался, новый круг сливался с уже-освещённым окружением.
## 20м даёт компактный «фонарь башни» — постановка башни в темноте чётко
## вычерчивает круг открытой зоны. Дальше работают только юниты.
const VISION_RADIUS_TOWER: float = 20.0
## Camp.deploy_anchor — постоянный «свет» лагеря пока он развёрнут. Шаги:
## 40→80→160→220→260→300→200→65м→{camp.build_radius}. После 2026-05-18 не
## константа, а ровно build_radius лагеря (читается динамически в
## _paint_vision_points). Дизайнерское решение: свет лагеря строго равен зоне
## строительства — что застроишь, то и видишь. Дальше работает зрение гномов
## (12м), защитников (18м), стрелковых постов (узкий конус). Костёр не
## просвечивает дальше частокола.
##
## VISION_RADIUS_CAMP оставлен как fallback на случай если camp.build_radius
## вдруг будет 0 или невалиден.
const VISION_RADIUS_CAMP: float = 30.0
const VISION_RADIUS_GNOME: float = 12.0
const VISION_RADIUS_DEFENDER: float = 18.0
const VISION_RADIUS_SOLDIER: float = 15.0

## Скорость расширения pulse-импактов в м/с. Используется и для grow-фазы
## fog-pulse, и для скорости spark-частиц (AoeVisual.spawn_pulse_sparks), и
## для расчёта продолжительности обоих эффектов. Один источник правды —
## один визуальный темп для всей системы импактов. 10 м/с даёт ~1с роста
## для fog_max=12м и ~0.35с для damage_radius=3.5м.
const PULSE_SPREAD_SPEED: float = 10.0


## Группа дополнительных источников рассеивания тумана: огни/костры/магия.
## Ноды в этой группе должны быть Node3D и (опционально) иметь свойства:
##  - `fog_reveal_radius: float` — круг вокруг ноды; иначе берётся
##    VISION_RADIUS_REVEAL_DEFAULT. Установка в 0 отключает круг.
##  - `fog_reveal_cone_half_angle: float` (рад), `fog_reveal_cone_length: float`
##    (м), `fog_reveal_cone_direction: Vector3` — добавляет конус с soft
##    falloff. Длина 0 или направление-ноль отключают конус. Конус и круг
##    независимы — стрелковый пост рисует и то и другое.
## Используется для:
##  - POI campfire (QuestActor): постоянный «свет костра».
##  - BurnPatch: пятно огня после взрыва на земле.
##  - Mine ARMED: лёгкая засветка вооружённой мины.
##  - ArcherPost: маленький круг + длинный конус по направлению взгляда.
## Для коротких вспышек (Fireball/Mine explosion) используй pulse_reveal().
const FOG_REVEAL_GROUP := &"fog_reveal"
const VISION_RADIUS_REVEAL_DEFAULT: float = 8.0

@onready var _plane: MeshInstance3D = $Plane

static var _instance: FogOfWar = null


## Глобальная точка доступа — единственный FogOfWar на сцене. null если ещё
## не _ready'нулся или уже free'нут (рестарт сцены). Используется UI/cheat
## кодом, который иначе ходил бы по детям сцены в поисках экземпляра.
static func instance() -> FogOfWar:
	return _instance if _instance != null and is_instance_valid(_instance) else null

var _vision_image: Image
var _vision_texture: ImageTexture
var _vision_data: PackedByteArray  ## Working buffer; быстрее set_pixel/get_pixel.
var _update_timer: float = 0.0
## Очередь короткоживущих вспышек рассеивания (взрывы fireball, мин, etc).
## Каждый элемент: {pos: Vector3, max_radius: float, start_radius: float,
## ticks_left: int, total_ticks: int, grow_ticks: int}. Тикается в
## _paint_vision_points: current_radius плавно растёт от start_radius до
## max_radius за первые grow_ticks тиков (smoothstep ease), затем держится
## до конца. На 0 — удаляется.
var _pulses: Array = []
## Время deploy каждого лагеря (Camp.get_instance_id() → msec). Используется
## для анимации «разгорания» — vision-радиус растёт с 0 до полного за
## CAMP_GROW_SECONDS, имитируя пламя костра, постепенно рассеивающее туман.
## Плюс лёгкий sin-пульс для «дыхания» огня.
var _camp_deploy_times: Dictionary = {}
const CAMP_GROW_SECONDS: float = 1.2
## Sin-пульс «дыхания» убран (2026-05-17) — ±5% радиуса 2Hz читались как
## помаргивание, а не атмосфера. Костёр теперь даёт ровный стационарный
## свет после разгорания. Оставлены константы на случай возврата эффекта.
const CAMP_PULSE_AMPLITUDE: float = 0.0
const CAMP_PULSE_FREQ: float = 0.0

## Сцена частиц «пламени, рассеивающего туман» вокруг лагеря. Спавнится на
## camp_deployed, queue_free'ится на camp_packed. Per-camp instance, привязан
## к deploy_anchor. Если null — частицы отключены.
@export var camp_fire_particles_scene: PackedScene
## Per-camp инстансы частиц (Camp.get_instance_id() → GPUParticles3D node).
var _camp_particles: Dictionary = {}


func _ready() -> void:
	_instance = self
	_vision_image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_L8)
	_vision_image.fill(Color(0, 0, 0, 1))
	_vision_data = _vision_image.get_data()
	_vision_texture = ImageTexture.create_from_image(_vision_image)
	# Привязка к shader-uniform делается через material параметр.
	if _plane != null:
		var mat := _plane.material_override as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("vision_texture", _vision_texture)
			mat.set_shader_parameter("map_half", MAP_HALF)
	# Подписки на deploy/pack — фиксируем время начала «разгорания» костра.
	EventBus.camp_deployed.connect(_on_camp_deployed_for_fog)
	EventBus.camp_packed.connect(_on_camp_packed_for_fog)


func _on_camp_deployed_for_fog(anchor: Vector3) -> void:
	# anchor — Vector3, не Camp-ссылка. Находим лагерь по близости к anchor'у.
	for c in get_tree().get_nodes_in_group(Camp.CAMP_GROUP):
		if not is_instance_valid(c):
			continue
		var camp := c as Camp
		if camp == null or not camp.is_deployed():
			continue
		var id := camp.get_instance_id()
		if not _camp_deploy_times.has(id):
			_camp_deploy_times[id] = Time.get_ticks_msec()
		# Спавн «огня» — частицы вокруг anchor'а.
		if camp_fire_particles_scene != null and not _camp_particles.has(id):
			var fx := camp_fire_particles_scene.instantiate() as Node3D
			if fx != null:
				add_child(fx)
				fx.global_position = anchor
				_camp_particles[id] = fx


func _on_camp_packed_for_fog() -> void:
	# Чистим записи свёрнутых/невалидных лагерей.
	var to_remove: Array = []
	for id in _camp_deploy_times.keys():
		var c := instance_from_id(id) as Camp
		if c == null or not is_instance_valid(c) or not c.is_deployed():
			to_remove.append(id)
	for id in to_remove:
		_camp_deploy_times.erase(id)
		# Кильнуть связанные частицы.
		if _camp_particles.has(id):
			var fx: Node = _camp_particles[id]
			if is_instance_valid(fx):
				fx.queue_free()
			_camp_particles.erase(id)


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


## True если visibility в точке ≥ ENEMY_VISIBLE_THRESHOLD_ON. Без hysteresis —
## простой бинарный чек. Для враг-visibility hysteresis применяется внутри
## _update_enemy_visibility (там есть previous state).
static func is_visible_at(pos: Vector3) -> bool:
	if _instance == null or not is_instance_valid(_instance):
		return true
	return _instance._sample_visibility(pos) >= _instance.ENEMY_VISIBLE_THRESHOLD_ON


## Короткоживущая вспышка рассеивания. Используется для взрывов магии и мин —
## после визуальной вспышки область «выгорает» из тумана на N тиков, затем
## естественный CPU-decay постепенно возвращает мглу. Не требует подписки на
## группы — fire-and-forget.
##
## `radius` в метрах — максимальный размер зоны рассеивания.
## `ticks` — длительность всей вспышки (1 тик = UPDATE_INTERVAL = 0.1с).
## Дефолт 5 тиков = 0.5с.
## `grow_ticks` — за сколько первых тиков радиус плавно (smoothstep) растёт
## от `start_radius` до `radius`. Дефолт 0 = мгновенная вспышка (старое поведение).
## Положительное значение (например, 6 = 0.6с) даёт «раскрытие как костёр» —
## вспышка не «появляется», а «распускается».
## `start_radius` — стартовый размер pulse'а. Используется когда у источника
## уже был fog-trail (например, файрбол в полёте), чтобы pulse не «провисал»
## визуально, пока он растёт ВНУТРИ уже прокрашенной trail-зоны. Pulse должен
## стартовать оттуда, где закончился trail, и продолжать расширение наружу.
static func pulse_reveal(pos: Vector3, radius: float, ticks: int = 5, grow_ticks: int = 0, start_radius: float = 0.0) -> void:
	if _instance == null or not is_instance_valid(_instance):
		return
	_instance._pulses.append({
		"pos": pos,
		"max_radius": radius,
		"start_radius": start_radius,
		"ticks_left": ticks,
		"total_ticks": ticks,
		"grow_ticks": grow_ticks,
	})
	if LogConfig.master_enabled:
		print("[Fog:pulse-add] pos=(%.1f,%.1f,%.1f) start_r=%.1fм max_r=%.1fм ticks=%d grow=%d" % [
			pos.x, pos.y, pos.z, start_radius, radius, ticks, grow_ticks,
		])


## Возвращает visibility в точке 0..1 — сэмплирует кэш CPU-image без round-trip
## через GPU. Используется в _update_enemy_visibility и публично через
## is_visible_at.
func _sample_visibility(pos: Vector3) -> float:
	var u: float = (pos.x + MAP_HALF) / (MAP_HALF * 2.0)
	var v: float = (pos.z + MAP_HALF) / (MAP_HALF * 2.0)
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return 0.0
	var px: int = clampi(int(u * float(TEX_SIZE)), 0, TEX_SIZE - 1)
	var py: int = clampi(int(v * float(TEX_SIZE)), 0, TEX_SIZE - 1)
	return float(_vision_data[py * TEX_SIZE + px]) / 255.0


func _process(delta: float) -> void:
	if _cheat_disabled:
		return
	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_timer = UPDATE_INTERVAL
		_decay_visibility()
		_paint_vision_points()
		_upload_texture()
		_update_enemy_visibility()


## Чит: отключить туман целиком. Скрывает meshes-плейн + показывает всех
## врагов разом, останавливает _process (decay/paint/upload/visibility
## пропускаются). Toggle через [is_cheat_disabled]. Включить обратно —
## set_cheat_disabled(false): _process возвращается к нормальному циклу,
## визуал врагов обновится через 0.1с (UPDATE_INTERVAL).
var _cheat_disabled: bool = false


func set_cheat_disabled(value: bool) -> void:
	if _cheat_disabled == value:
		return
	_cheat_disabled = value
	# Туман — несколько плейнов (Plane, Plane2..Plane9) на разных высотах для
	# атмосферного эффекта. Переключаем все, иначе остаются «слои».
	for child in get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = not value
	# При отключении принудительно показываем всех живых врагов — иначе
	# те что были hidden останутся невидимыми до восстановления тумана.
	if value:
		for e in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
			if is_instance_valid(e):
				(e as Node3D).visible = true


func is_cheat_disabled() -> bool:
	return _cheat_disabled


## Затухание всей visibility-карты. Работаем с PackedByteArray напрямую —
## set_pixel/get_pixel слишком медленные для 16K пикселей × 10Hz.
func _decay_visibility() -> void:
	var floor_byte: int = int(DECAY_FLOOR * 255.0)
	for i in range(_vision_data.size()):
		var v: int = int(float(_vision_data[i]) * DECAY_PER_TICK)
		if v < floor_byte:
			v = floor_byte
		_vision_data[i] = v


## Рисует soft circle вокруг каждого друга. Tower (большой круг) + Camp-anchor
## (если развёрнут — свет «домашней» зоны) + все гномы / защитники / солдаты.
## Cap MAX_VISION_POINTS не нужен — мы не передаём массив в shader, а сами
## рисуем все по очереди.
func _paint_vision_points() -> void:
	var tower_nodes := get_tree().get_nodes_in_group(Tower.GROUP)
	for t in tower_nodes:
		if not is_instance_valid(t):
			continue
		var tp := t as Node3D
		if tp == null:
			continue
		_paint_soft_circle(tp.global_position, VISION_RADIUS_TOWER)
	for c in get_tree().get_nodes_in_group(Camp.CAMP_GROUP):
		if not is_instance_valid(c):
			continue
		var camp := c as Camp
		if camp == null or not camp.is_deployed():
			continue
		# Анимация «разгорания»: радиус растёт от 0 до VISION_RADIUS_CAMP за
		# CAMP_GROW_SECONDS. Плюс лёгкий sin-пульс — костёр «дышит», туман
		# отползает рывками. Если запись deploy_time отсутствует (например,
		# start_deployed=true и сигнала не было) — fallback на полный радиус.
		var id := camp.get_instance_id()
		var radius_factor: float = 1.0
		var pulse: float = 1.0
		if _camp_deploy_times.has(id):
			var elapsed_ms: int = Time.get_ticks_msec() - int(_camp_deploy_times[id])
			var elapsed: float = float(elapsed_ms) / 1000.0
			radius_factor = clampf(elapsed / CAMP_GROW_SECONDS, 0.0, 1.0)
			# Smoothstep ease-out — старт медленный, к концу замедление.
			radius_factor = radius_factor * radius_factor * (3.0 - 2.0 * radius_factor)
			pulse = 1.0 + sin(elapsed * CAMP_PULSE_FREQ * TAU) * CAMP_PULSE_AMPLITUDE
			# После полного разгорания гасим частицы — искры летят только
			# во время «вспышки», дальше тихое свечение без эффектов.
			if elapsed >= CAMP_GROW_SECONDS and _camp_particles.has(id):
				var fx_node := _camp_particles[id] as GPUParticles3D
				if fx_node != null and fx_node.emitting:
					fx_node.emitting = false
		# Свет лагеря = его build_radius (дизайн 2026-05-18: видимость строго
		# по зоне строительства). Если build_radius невалиден — fallback на
		# константу VISION_RADIUS_CAMP.
		var camp_vision_max: float = camp.build_radius if camp.build_radius > 0.1 else VISION_RADIUS_CAMP
		var animated_radius: float = camp_vision_max * radius_factor * pulse
		if animated_radius > 0.5:
			_paint_soft_circle(camp.deploy_anchor, animated_radius)
	for g in get_tree().get_nodes_in_group(Gnome.GNOME_GROUP):
		if not is_instance_valid(g):
			continue
		var gp := g as Node3D
		if gp == null:
			continue
		var r: float = VISION_RADIUS_GNOME
		if g is DefenderGnome:
			r = VISION_RADIUS_DEFENDER
		elif g is SoldierGnome:
			r = VISION_RADIUS_SOLDIER
		_paint_soft_circle(gp.global_position, r)
	# Доп. источники: огни/костры/магия в FOG_REVEAL_GROUP. Каждый узел
	# может иметь свой `fog_reveal_radius` (круг) и/или конус (cone-stamp).
	# См. документацию FOG_REVEAL_GROUP выше — duck-type контракт.
	for fr in get_tree().get_nodes_in_group(FOG_REVEAL_GROUP):
		if not is_instance_valid(fr):
			continue
		var frp := fr as Node3D
		if frp == null:
			continue
		# 1. Круг — если радиус > 0 (дефолт VISION_RADIUS_REVEAL_DEFAULT, явный 0
		#    отключает).
		var rr: float = VISION_RADIUS_REVEAL_DEFAULT
		if "fog_reveal_radius" in fr:
			rr = float(fr.fog_reveal_radius)
		if rr > 0.1:
			_paint_soft_circle(frp.global_position, rr)
		# 2. Конус — если у ноды есть все три свойства и длина > 0.
		if "fog_reveal_cone_half_angle" in fr and "fog_reveal_cone_length" in fr and "fog_reveal_cone_direction" in fr:
			var c_len: float = float(fr.fog_reveal_cone_length)
			var c_dir: Vector3 = fr.fog_reveal_cone_direction
			c_dir.y = 0.0
			if c_len > 0.1 and c_dir.length_squared() > 0.0001:
				var c_half: float = float(fr.fog_reveal_cone_half_angle)
				_paint_soft_cone(frp.global_position, c_dir.normalized(), c_half, c_len)
	# Короткоживущие pulse'ы: радиус «распускается» через smoothstep за первые
	# grow_ticks тиков от 0 до max_radius, затем держится до конца. На каждом
	# тике paint'им текущий радиус, декрементируем ticks_left.
	var alive_pulses: Array = []
	for pulse in _pulses:
		var max_r: float = pulse["max_radius"]
		var start_r: float = pulse.get("start_radius", 0.0)
		var total: int = pulse["total_ticks"]
		var grow: int = pulse["grow_ticks"]
		var ticks_left: int = pulse["ticks_left"]
		var elapsed: int = total - ticks_left
		var current_r: float = max_r
		var stage: String = "plateau"
		if grow > 0 and elapsed < grow:
			# Smoothstep ease: t² × (3 − 2t). Тот же curve, что у CAMP_GROW_SECONDS.
			# Растёт от start_r до max_r, чтобы pulse подхватил у trail'а
			# (например, у файрбола 8м-trail в полёте → pulse стартует с 8м, не с 0).
			var t: float = float(elapsed) / float(grow)
			var s: float = t * t * (3.0 - 2.0 * t)
			current_r = start_r + (max_r - start_r) * s
			stage = "grow"
		if current_r > 0.1:
			_paint_soft_circle(pulse["pos"], current_r)
		if LogConfig.master_enabled:
			var pos: Vector3 = pulse["pos"]
			print("[Fog:pulse-tick] @(%.1f,%.1f) tick=%d/%d stage=%s r=%.1fм" % [
				pos.x, pos.z, elapsed + 1, total, stage, current_r,
			])
		pulse["ticks_left"] = ticks_left - 1
		if pulse["ticks_left"] > 0:
			alive_pulses.append(pulse)
		elif LogConfig.master_enabled:
			var pos2: Vector3 = pulse["pos"]
			print("[Fog:pulse-end] @(%.1f,%.1f) total_ticks=%d (CPU-decay начинает разъедать пятно)" % [
				pos2.x, pos2.z, total,
			])
	_pulses = alive_pulses


## Доля радиуса, на которой происходит fade. Внутри (1.0 - REVEAL_EDGE_FRACTION)
## радиуса — полная видимость (alpha=1.0, туман полностью рассеян). На внешних
## REVEAL_EDGE_FRACTION пикселях — линейный спад до 0. Чем меньше — тем «жёстче»
## край, чем больше — тем мягче. 0.35 = «70% площади полностью открыто, внешние
## 30% — мягкий край». Применяется и к кругам, и к конусам.
##
## Изменено 2026-05-18: было `f*f` (квадратичный пик в центре, дающий тусклый
## ореол). Игрок жаловался, что юниты «не рассеивают туман в своей области» —
## фактически область была почти полностью полу-туманной. Теперь area юнита
## действительно ярко рассеяна, fade только у самой границы.
const REVEAL_EDGE_FRACTION: float = 0.35


## Рисует круг в _vision_data с hard-core + soft-edge: внутри
## (1.0 - REVEAL_EDGE_FRACTION) радиуса — полный alpha=1.0, внешние пиксели
## линейно затухают до 0 на границе. Max-blend с существующим: вход в свет
## повышает значение, но не понижает, затухание делается отдельно в
## _decay_visibility.
func _paint_soft_circle(world_pos: Vector3, radius: float) -> void:
	var u: float = (world_pos.x + MAP_HALF) / (MAP_HALF * 2.0)
	var v: float = (world_pos.z + MAP_HALF) / (MAP_HALF * 2.0)
	var cx: float = u * float(TEX_SIZE)
	var cy: float = v * float(TEX_SIZE)
	var r_px: float = (radius / (MAP_HALF * 2.0)) * float(TEX_SIZE)
	var r_px_int: int = int(ceil(r_px))
	var r_sq: float = r_px * r_px
	var core_r_px: float = r_px * (1.0 - REVEAL_EDGE_FRACTION)
	var inv_edge: float = 1.0 / maxf(r_px - core_r_px, 0.0001)
	var x_min: int = maxi(0, int(cx) - r_px_int)
	var x_max: int = mini(TEX_SIZE - 1, int(cx) + r_px_int)
	var y_min: int = maxi(0, int(cy) - r_px_int)
	var y_max: int = mini(TEX_SIZE - 1, int(cy) + r_px_int)
	for py in range(y_min, y_max + 1):
		var dy: float = float(py) + 0.5 - cy
		for px in range(x_min, x_max + 1):
			var dx: float = float(px) + 0.5 - cx
			var d_sq: float = dx * dx + dy * dy
			if d_sq > r_sq:
				continue
			var d: float = sqrt(d_sq)
			# Hard core: до core_r_px — полностью 1.0. Затем линейный fade.
			var f: float
			if d <= core_r_px:
				f = 1.0
			else:
				f = (r_px - d) * inv_edge
			var v_new: int = int(f * 255.0)
			var idx: int = py * TEX_SIZE + px
			if _vision_data[idx] < v_new:
				_vision_data[idx] = v_new


## Рисует конический «луч прожектора» в _vision_data с soft falloff по углу
## и дистанции. Используется стрелковым постом (ArcherPost): пост видит
## дальше обычного защитника, но только в направлении сканирования.
##
## `origin` — точка старта конуса (мировые XYZ, Y игнорируется).
## `dir_xz` — направление в плоскости XZ, должно быть нормализованным.
## `half_angle` — половина раствора конуса в радианах (π/12 = 15° → конус
## шириной 30°).
## `length` — длина конуса в метрах.
##
## Falloff: внутри (1.0 - REVEAL_EDGE_FRACTION) × длины и до (1.0 -
## REVEAL_EDGE_FRACTION) × угла — полный alpha=1.0. На внешних
## REVEAL_EDGE_FRACTION — линейный fade. Это даёт «жёсткий» конус с мягкими
## краями (визуально читается как чёткий луч прожектора). Max-blend с
## существующим — конус не затемняет уже освещённые места.
func _paint_soft_cone(origin: Vector3, dir_xz: Vector3, half_angle: float, length: float) -> void:
	if length <= 0.1:
		return
	var u: float = (origin.x + MAP_HALF) / (MAP_HALF * 2.0)
	var v: float = (origin.z + MAP_HALF) / (MAP_HALF * 2.0)
	var cx: float = u * float(TEX_SIZE)
	var cy: float = v * float(TEX_SIZE)
	var r_px: float = (length / (MAP_HALF * 2.0)) * float(TEX_SIZE)
	var r_px_int: int = int(ceil(r_px))
	# Bounding box — квадрат вокруг origin со стороной 2 × length. Не оптимально
	# для узкого конуса (можно сузить по углу), но проще и при cone-length 40м
	# и TEX_SIZE 128 даёт ~17×17 пикселей max — копейки.
	var x_min: int = maxi(0, int(cx) - r_px_int)
	var x_max: int = mini(TEX_SIZE - 1, int(cx) + r_px_int)
	var y_min: int = maxi(0, int(cy) - r_px_int)
	var y_max: int = mini(TEX_SIZE - 1, int(cy) + r_px_int)
	# Маппинг dir.xz → pixel-space: X-пиксель растёт с world.x, Y-пиксель растёт
	# с world.z (см. _sample_visibility: v = (pos.z + MAP_HALF)/...). Поэтому
	# (dir.x, dir.z) можно использовать как (dir_px.x, dir_px.y) напрямую.
	var dx_u: float = dir_xz.x
	var dy_u: float = dir_xz.z
	var cos_half: float = cos(half_angle)
	# Углы "ядра": внутри cos_half_core угол даёт полный alpha. На внешнем
	# кольце (cos_half .. cos_half_core) — линейный fade.
	var cos_half_core: float = cos(half_angle * (1.0 - REVEAL_EDGE_FRACTION))
	var inv_angle_edge: float = 1.0 / maxf(cos_half_core - cos_half, 0.0001)
	var core_r_px: float = r_px * (1.0 - REVEAL_EDGE_FRACTION)
	var inv_dist_edge: float = 1.0 / maxf(r_px - core_r_px, 0.0001)
	for py in range(y_min, y_max + 1):
		var dy: float = float(py) + 0.5 - cy
		for px in range(x_min, x_max + 1):
			var dx: float = float(px) + 0.5 - cx
			var d: float = sqrt(dx * dx + dy * dy)
			if d > r_px or d < 0.5:
				continue
			# cos(angle) между (dx, dy) и (dx_u, dy_u). Если меньше cos(half) —
			# пиксель вне конуса, скип.
			var cos_theta: float = (dx * dx_u + dy * dy_u) / d
			if cos_theta < cos_half:
				continue
			# Angular factor: 1.0 в ядре (≥ cos_half_core), линейно fade до 0
			# на границе (cos_half).
			var angle_factor: float
			if cos_theta >= cos_half_core:
				angle_factor = 1.0
			else:
				angle_factor = (cos_theta - cos_half) * inv_angle_edge
			# Distance factor: 1.0 в ядре (≤ core_r_px), линейно fade до 0 на
			# конце конуса.
			var dist_factor: float
			if d <= core_r_px:
				dist_factor = 1.0
			else:
				dist_factor = (r_px - d) * inv_dist_edge
			var f: float = angle_factor * dist_factor
			var v_new: int = int(f * 255.0)
			var idx: int = py * TEX_SIZE + px
			if _vision_data[idx] < v_new:
				_vision_data[idx] = v_new


## Заливаем обновлённые байты обратно в Image и пушим в ImageTexture.
## ImageTexture.update() — единственный способ обновить GPU-копию.
func _upload_texture() -> void:
	_vision_image.set_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_L8, _vision_data)
	_vision_texture.update(_vision_image)


## Раньше скрывал врагов вне видимости. С 2026-05-22 (дизайнерское решение)
## враги всегда видны — fog теперь только визуальная дымка низко над землёй
## (fog_top_height=2.5м, ниже Tower), скелеты-капсулы силуэтами читаются
## сквозь неё. Если захочется вернуть hiding — раскомментировать тело.
func _update_enemy_visibility() -> void:
	pass
