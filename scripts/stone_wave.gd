class_name StoneWave
extends Node3D
## ⭐ КАМЕННЫЙ ВАЛ АРТЕЛИ — ОДИН НА ОБА ЭПИЗОДА (2026-08-11).
##
## Раньше вал жил внутри dungeon_sandbox.gd и был намертво сшит с подземельем:
## карточки, тайник, завал К1, мебель интро, своя камера. Из-за этого в большом
## мире ПКМ молчал — переносить было нечего, кроме копипасты. Теперь вал —
## отдельный узел: физика гребня, эхо, урон и рассыпание тут, а всё, что знает
## только эпизод, уходит СИГНАЛАМИ наружу.
##
## ПРАВИЛО: числа и поведение правятся ЗДЕСЬ. Появится третий эпизод — он
## вешает этот же узел, а не пишет свой вал.
##
## Как подключить:
##   var w := StoneWave.new()
##   add_child(w)
##   w.center_provider = func(): return _squad.compute_center()
##   w.crew_provider = func(): return _alive_artel()
##   w.rumble.connect(...)              # непрерывный рокот в полёте
##   w.blocked.connect(...)             # вал разбился обо что-то (ломкое?)
##   w.swept.connect(...)               # полоса прошла — что ещё в неё попало
##   ... каждый физкадр: w.tick(delta)
##   ... по кнопке: if w.launch(center, dir): _vel -= dir * w.recoil

## Вал разбился о преграду. Эпизод решает, ломается ли она (тайник, завал,
## бочка с порохом) — сам вал о такие вещи просто гибнет.
signal blocked(collider: Object, at: Vector3)
## Полоса вала прошла точку: origin — центр гребня, half — полуширина. Эпизод
## добавляет свои цели, которых не знает общий код (мебель интро и т.п.).
signal swept(origin: Vector3, dir: Vector3, half: float)
## Рокот катящегося вала: непрерывная подсыпка травмы тряски за кадр. Отдаём
## наружу, потому что камера у эпизодов разная (риг большого мира / своя в данже).
signal rumble(amount: float, at: Vector3)

## Числа — финальные данжевые (три итерации фидбека по «феелу»). Хозяин может
## их переопределить, но по умолчанию вал везде одинаковый.
var cooldown: float = 14.0
var speed: float = 13.0
## Сколько метров пролетит, если не встретит стену.
var travel_range: float = 20.0
## Полуширина вала (м): кого захватывает по сторонам от оси.
var half_width: float = 1.9
## Урон ЗА КАЖДОГО ЖИВОГО АРТЕЛЬЩИКА: один — вал слабый, трое — таранит толпу.
var damage_per_gnome: float = 45.0
var knockback: float = 14.0
## Отдача запуска: пинок скорости точки строя ПРОТИВ хода вала (м/с). Применяет
## ХОЗЯИН (у него своя инерция) — вал только хранит число.
var recoil: float = 7.0
## Хитстоп жертвам (сек заморозки на попадании). 0 = выкл.
var hitstop: float = 0.06
## Рокот весь полёт: травма/сек вплотную, спадает с удалением вала от отряда.
## Потолок ниже разовых ударов, чтобы они читались поверх дрожи. 0 = выкл.
var travel_shake: float = 1.2
var travel_shake_cap: float = 0.6
## «Эхо в камне»: второй вал идёт ИЗ СТРОЯ вдогонку первому через паузу — не из
## точки, где первый разбился (там он бесполезен, фидбек 2026-07-29).
var echo_delay: float = 0.35
var echo_stones: int = 3
var echo_power: float = 0.55

## Карточки апгрейдов (в данже их выдаёт хижина, в мире их пока нет — нули).
## Читаются НА ЛЕТУ: «Ещё по камню» шире полосу, «Обвал» осколки, «Эхо» догон.
var wide_cards: int = 0
var burst_cards: int = 0
var echo_cards: int = 0

## Откуда стартует эхо и от чего считается близость рокота (центр строя).
var center_provider: Callable = Callable()
## Сколько живых артельщиков сейчас — от этого урон вала В МОМЕНТ ПОПАДАНИЯ.
var crew_provider: Callable = Callable()

## Валов может быть НЕСКОЛЬКО разом (первый + догоняющие «эхо»), поэтому список:
## {node, travelled, half, power, hit}. Направление общее — эхо идёт тем же курсом.
var _waves: Array = []
var _dir: Vector3 = Vector3.ZERO
var _cd: float = 0.0
var _echo_left: int = 0
var _echo_timer: float = 0.0


## Готовность кнопки для HUD/карточек.
func cooldown_left() -> float:
	return _cd


func is_ready() -> bool:
	return _cd <= 0.0 and _waves.is_empty()


## ПКМ: запустить вал от центра строя по направлению. Направление ФИКСИРУЕТСЯ
## на запуске: вал не подруливает, целиться надо заранее. true = ушёл (хозяин
## применяет отдачу и тряску запуска).
func launch(center: Vector3, dir: Vector3) -> bool:
	if _cd > 0.0 or not _waves.is_empty():
		return false
	if center == Vector3.INF or dir.length_squared() < 0.01:
		return false
	_dir = Vector3(dir.x, 0.0, dir.z).normalized()
	_cd = cooldown
	_echo_left = echo_cards
	_echo_timer = echo_delay
	_spawn_body(center + _dir * 1.6, 5 + 2 * wide_cards, current_half_width(), 1.0)
	AoeVisual.spawn_dust(self, center + _dir * 1.6)
	return true


## Полуширина с учётом карточки «Ещё по камню».
func current_half_width() -> float:
	return half_width + 0.85 * float(wide_cards)


## Урон СЕЙЧАС = вклад каждого живого артельщика. Считается в момент попадания,
## а не на запуске: погиб носитель — вал слабеет на лету.
func damage_now() -> float:
	var crew: int = int(crew_provider.call()) if crew_provider.is_valid() else 0
	return damage_per_gnome * float(crew)


## Ход валов: каждый едет вперёд, бьёт КАЖДОГО один раз, рассыпается о стену
## или выдохшись на travel_range. Зовёт ХОЗЯИН из своего _physics_process —
## так порядок с ходом отряда остаётся за ним.
func tick(delta: float) -> void:
	if _cd > 0.0:
		_cd = maxf(_cd - delta, 0.0)
	# Эхо стартует ИЗ СТРОЯ через паузу после первого вала — вдогонку, не с
	# места гибели. Тоньше основного и урон вполсилы.
	if _echo_left > 0:
		_echo_timer -= delta
		if _echo_timer <= 0.0:
			_echo_left -= 1
			_echo_timer = echo_delay
			var ec: Vector3 = _center()
			if ec != Vector3.INF:
				_spawn_body(ec + _dir * 1.6, echo_stones,
						current_half_width() * 0.62, echo_power)
	if _waves.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var step: float = speed * delta
	# Рокот катящегося вала: тряска живёт всё время полёта и глохнет с удалением
	# вала от отряда — «грохот уходит вдаль».
	if travel_shake > 0.0:
		var sc: Vector3 = _center()
		if sc != Vector3.INF:
			var near_fall: float = 0.0
			for wv in _waves:
				var wn: Node3D = wv["node"]
				if is_instance_valid(wn):
					near_fall = maxf(near_fall, 1.0 - clampf(
							wn.global_position.distance_to(sc) / travel_range, 0.0, 1.0))
			if near_fall > 0.0:
				rumble.emit(travel_shake * near_fall * delta, sc)
	for i in range(_waves.size() - 1, -1, -1):
		var w: Dictionary = _waves[i]
		var node: Node3D = w["node"]
		if not is_instance_valid(node):
			_waves.remove_at(i)
			continue
		var from: Vector3 = node.global_position + Vector3.UP * 0.6
		var q := PhysicsRayQueryParameters3D.create(from, from + _dir * (step + 0.6),
				Layers.TERRAIN | Layers.WALL_GATE_BLOCK | Layers.CHASM_BARRIER)
		var ray: Dictionary = space.intersect_ray(q)
		var is_blocked: bool = not ray.is_empty()
		# Вал разбился о преграду — сам гибнет, но эпизод может её вскрыть
		# (треснувшая стенка тайника, завал, бочка с порохом).
		if is_blocked:
			blocked.emit(ray.get("collider"), ray.get("position", node.global_position))
		node.global_position += _dir * step
		w["travelled"] = float(w["travelled"]) + step
		_damage_pass(w)
		if is_blocked or float(w["travelled"]) >= travel_range:
			_break_wave(w)
			_waves.remove_at(i)


## Вал: гребень из плит разной высоты поперёк хода — читается как «поднявшийся
## камень», а не снаряд. Unshaded, тени выключены (их тут десятки за забег).
func _spawn_body(pos: Vector3, stones: int, half: float, power: float) -> void:
	var root := Node3D.new()
	add_child(root)
	root.global_position = Vector3(pos.x, 0.0, pos.z)
	root.look_at(root.global_position + _dir, Vector3.UP)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.38, 0.34)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var n: int = maxi(stones, 2)
	for i in range(n):
		var t: float = float(i) / float(n - 1)
		var h: float = lerpf(0.7, 1.5, 1.0 - absf(t - 0.5) * 2.0) * randf_range(0.85, 1.15)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(half * 2.0 / float(n) * 0.95, h, 0.5)
		mi.mesh = bm
		mi.material_override = mat
		# Локальный X — поперёк хода (root смотрит вдоль _dir).
		mi.position = Vector3(lerpf(-half, half, t), h * 0.5, 0.0)
		mi.rotation.z = randf_range(-0.12, 0.12)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	_waves.append({"node": root, "travelled": 0.0, "half": half, "power": power, "hit": {}})


## Урон по полосе: цель считается задетой, если она в пределах полуширины по
## бокам и не дальше полушага по ходу — вал именно СМЕТАЕТ, а не тянет за собой.
func _damage_pass(w: Dictionary) -> void:
	var origin: Vector3 = (w["node"] as Node3D).global_position
	var hit: Dictionary = w["hit"]
	var power: float = float(w["power"])
	var kills: int = 0
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or (sk as Node).is_queued_for_deletion():
			continue
		if hit.has(sk.get_instance_id()):
			continue
		var to := Vector3((sk as Node3D).global_position.x - origin.x, 0.0,
				(sk as Node3D).global_position.z - origin.z)
		var along: float = to.dot(_dir)
		var side: float = absf(to.dot(Vector3(-_dir.z, 0.0, _dir.x)))
		if absf(along) > 1.1 or side > float(w["half"]) + 0.5:
			continue
		hit[sk.get_instance_id()] = true
		Damageable.try_damage(sk, damage_now() * power, hitstop, _dir, true)
		if not is_instance_valid(sk) or (sk as Node).is_queued_for_deletion():
			kills += 1
		elif sk.has_method(&"apply_knockback"):
			sk.call(&"apply_knockback", _dir * knockback * power + Vector3.UP * 2.5, 0.3)
	# Что ещё попало в полосу, знает эпизод (мебель интро и прочая ломкая мелочь).
	swept.emit(origin, _dir, float(w["half"]))
	# Кульминация как у фаербола башни: пачка (3+) одним проходом → слоумо-бит.
	# slowmo_beat сам не стакается, если время уже искажено.
	if kills >= 3:
		HitStop.slowmo_beat(HitStop.BEAT_MULTIKILL_SCALE, HitStop.BEAT_MULTIKILL_TIME)


## Рассыпание: камень летит по ходу вала (направленный shatter, §6.1 F1).
## Карточка «Обвал» добавляет осколочный удар по кругу в точке разрушения.
func _break_wave(w: Dictionary) -> void:
	var node: Node3D = w["node"]
	if not is_instance_valid(node):
		return
	var p: Vector3 = node.global_position
	var power: float = float(w["power"])
	ShatterEffect.spawn(self, p + Vector3.UP * 0.6, Color(0.42, 0.38, 0.34),
			int((10 + 4 * burst_cards) * power), 1.6, _dir, 1.2)
	AoeVisual.spawn_dust(self, p)
	node.queue_free()
	if burst_cards > 0:
		_burst(p, power)


## «Обвал»: круговой осколочный удар в точке разрушения вала.
func _burst(p: Vector3, power: float = 1.0) -> void:
	var r: float = 4.5 * power
	var r_sq: float = r * r
	var kills: int = 0
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or (sk as Node).is_queued_for_deletion():
			continue
		var to := Vector3((sk as Node3D).global_position.x - p.x, 0.0,
				(sk as Node3D).global_position.z - p.z)
		if to.length_squared() > r_sq:
			continue
		# Осколки «Обвала» тоже не пробивают стены.
		if not _los_clear(p, (sk as Node3D).global_position):
			continue
		var dir: Vector3 = to.normalized() if to.length_squared() > 0.0001 else _dir
		# «Обвал» — вторичный удар, заморозка вполовину от основного вала.
		Damageable.try_damage(sk, damage_now() * 0.6 * power, hitstop * 0.5, dir, true)
		if not is_instance_valid(sk) or (sk as Node).is_queued_for_deletion():
			kills += 1
		elif sk.has_method(&"apply_knockback"):
			sk.call(&"apply_knockback", dir * knockback * 0.7 * power, 0.2)
	if kills >= 3:
		HitStop.slowmo_beat(HitStop.BEAT_MULTIKILL_SCALE, HitStop.BEAT_MULTIKILL_TIME)
	AoeVisual.spawn_expanding_ring(self, p, r, 0.25, Color(0.7, 0.65, 0.6, 0.9))
	EventBus.camera_shake.emit(0.45 * power, p)


func _los_clear(a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(a.x, 0.9, a.z), Vector3(b.x, 0.9, b.z),
			Layers.TERRAIN | Layers.WALL_GATE_BLOCK)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _center() -> Vector3:
	return center_provider.call() if center_provider.is_valid() else Vector3.INF
