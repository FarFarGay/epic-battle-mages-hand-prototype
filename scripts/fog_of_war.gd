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

## Tower — основной маяк зрения. 45м даёт «свой круг» вокруг башни даже без
## юнитов рядом; в каравне башня двигается и тащит этот круг за собой.
const VISION_RADIUS_TOWER: float = 45.0
## Camp.deploy_anchor — постоянный «свет» лагеря пока он развёрнут. С 2026-05-17
## расширен 40→80→160→220м — лагерь главный «маяк» зрения, перекрывает
## большую часть карты 300×300. Тематически: палатки, костёр, дым, гномы —
## мощный «очаг цивилизации» в туманной пустоши.
## В каравне якорь незначителен — vision не рисуем.
const VISION_RADIUS_CAMP: float = 220.0
const VISION_RADIUS_GNOME: float = 12.0
const VISION_RADIUS_DEFENDER: float = 18.0
const VISION_RADIUS_SOLDIER: float = 15.0

## Группа дополнительных источников рассеивания тумана: огни/костры/магия.
## Ноды в этой группе должны быть Node3D и (опционально) иметь свойство
## `fog_reveal_radius: float` — иначе берётся VISION_RADIUS_REVEAL_DEFAULT.
## Используется для:
##  - POI campfire (QuestActor): постоянный «свет костра».
##  - BurnPatch: пятно огня после взрыва на земле.
##  - Mine ARMED: лёгкая засветка вооружённой мины.
## Для коротких вспышек (Fireball/Mine explosion) используй pulse_reveal().
const FOG_REVEAL_GROUP := &"fog_reveal"
const VISION_RADIUS_REVEAL_DEFAULT: float = 8.0

@onready var _plane: MeshInstance3D = $Plane

static var _instance: FogOfWar = null

var _vision_image: Image
var _vision_texture: ImageTexture
var _vision_data: PackedByteArray  ## Working buffer; быстрее set_pixel/get_pixel.
var _update_timer: float = 0.0
## Очередь короткоживущих вспышек рассеивания (взрывы fireball, мин, etc).
## Каждый элемент: {pos: Vector3, radius: float, ticks_left: int}. Тикается
## в _paint_vision_points: рисуется и декрементируется, на 0 удаляется.
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
## `radius` в метрах, `ticks` — количество paint-итераций (1 тик = UPDATE_INTERVAL
## = 0.1с). Дефолт 5 тиков = 0.5с активной засветки. Decay начнётся после.
static func pulse_reveal(pos: Vector3, radius: float, ticks: int = 5) -> void:
	if _instance == null or not is_instance_valid(_instance):
		return
	_instance._pulses.append({"pos": pos, "radius": radius, "ticks_left": ticks})


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
	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_timer = UPDATE_INTERVAL
		_decay_visibility()
		_paint_vision_points()
		_upload_texture()
		_update_enemy_visibility()


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
		var animated_radius: float = VISION_RADIUS_CAMP * radius_factor * pulse
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
	# может иметь свой `fog_reveal_radius`; без свойства — default.
	for fr in get_tree().get_nodes_in_group(FOG_REVEAL_GROUP):
		if not is_instance_valid(fr):
			continue
		var frp := fr as Node3D
		if frp == null:
			continue
		var rr: float = VISION_RADIUS_REVEAL_DEFAULT
		if "fog_reveal_radius" in fr:
			rr = float(fr.fog_reveal_radius)
		_paint_soft_circle(frp.global_position, rr)
	# Короткоживущие pulse'ы: рисуем и декрементируем ticks. Удаление по 0.
	var alive_pulses: Array = []
	for pulse in _pulses:
		_paint_soft_circle(pulse["pos"], pulse["radius"])
		pulse["ticks_left"] -= 1
		if pulse["ticks_left"] > 0:
			alive_pulses.append(pulse)
	_pulses = alive_pulses


## Рисует круг в _vision_data с soft falloff (1.0 в центре → 0 на radius).
## Max-blend с существующим: вход в свет повышает значение, но не понижает,
## затухание делается отдельно в _decay_visibility.
func _paint_soft_circle(world_pos: Vector3, radius: float) -> void:
	var u: float = (world_pos.x + MAP_HALF) / (MAP_HALF * 2.0)
	var v: float = (world_pos.z + MAP_HALF) / (MAP_HALF * 2.0)
	var cx: float = u * float(TEX_SIZE)
	var cy: float = v * float(TEX_SIZE)
	var r_px: float = (radius / (MAP_HALF * 2.0)) * float(TEX_SIZE)
	var r_px_int: int = int(ceil(r_px))
	var r_sq: float = r_px * r_px
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
			# Smooth falloff: 1 в центре, 0 на radius. Квадрат для более
			# выраженного «ядра» (внешние пиксели тусклее).
			var f: float = 1.0 - sqrt(d_sq) / r_px
			f = f * f
			var v_new: int = int(f * 255.0)
			var idx: int = py * TEX_SIZE + px
			if _vision_data[idx] < v_new:
				_vision_data[idx] = v_new


## Заливаем обновлённые байты обратно в Image и пушим в ImageTexture.
## ImageTexture.update() — единственный способ обновить GPU-копию.
func _upload_texture() -> void:
	_vision_image.set_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_L8, _vision_data)
	_vision_texture.update(_vision_image)


## Скрывает Enemy-ноды вне visibility-порога. Hysteresis: уже-видимый
## скрывается только при visibility ≤ OFF; уже-скрытый показывается при
## ≥ ON. Между порогами — keeps previous state, без мерцания.
func _update_enemy_visibility() -> void:
	for e in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(e):
			continue
		var en := e as Node3D
		if en == null:
			continue
		var vis: float = _sample_visibility(en.global_position)
		if en.visible:
			if vis <= ENEMY_VISIBLE_THRESHOLD_OFF:
				en.visible = false
		else:
			if vis >= ENEMY_VISIBLE_THRESHOLD_ON:
				en.visible = true
