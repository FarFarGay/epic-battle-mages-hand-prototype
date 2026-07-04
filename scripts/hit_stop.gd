extends Node
## Хитстоп: краткое оглушение ВРАГА в момент попадания — его AI/действия замирают
## (не атакует, не маневрирует), но физика продолжает работать, поэтому он ОТЛЕТАЕТ
## от удара во время стопа («оглушён, но летит»), а не «замирает и потом прыгает».
## Сам эффект исполняет Enemy.apply_hitstop (флаг + гейт _ai_step в _physics_process);
## глобальный Engine.time_scale НЕ трогаем — рука игрока не должна замирать.
##
## Этот автозагруз — только ПОЛИТИКА: на какие цели и как часто. Срабатывает лишь
## на «весомых» (HEAVY_GROUPS: гигант/мех) — рядовой фоддер давится пачками, стоп на
## каждом = каша. Зовётся через Damageable.try_damage(target, amount, hitstop) и spark.

# Длительность оглушения врага (сек) по силе удара.
const LIGHT := 0.04   # быстрый зап (искра)
const MEDIUM := 0.07  # средний удар, парир, град firestorm
const HEAVY := 0.11   # фаербол, мина, слэм, таран, отражёнка, супер
const SUPER := 0.16
const MAX_DURATION := 0.20

# «Весомые» цели — только их морозим. Литералы дублируют SkeletonGiant.GIANT_GROUP /
# EnemyMech.MECH_GROUP (держим без import'а классов в автозагрузку).
const HEAVY_GROUPS: Array[StringName] = [&"skeleton_giant", &"enemy_mech"]

# Рефрактор: после оглушения врага нельзя оглушать снова это время (сек). Серии
# попаданий (firestorm/супер) иначе держали бы босса в непрерывном стан-локе — с
# рефрактором барраж даёт периодические «впечатывания», а не сплошной стан.
const REFRACTORY := 0.35
const _CD := &"_hitstop_cd_until_msec"

# --- Slow-mo БИТЫ (глобальный Engine.time_scale, короткие кульминации) ---
# Иерархия импакта: мелочь (искра/болт) время не трогает; средний (фаербол) —
# per-target хитстоп выше; КУЛЬМИНАЦИИ — краткий глобальный бит. Биты не
# стакаются (второй скипается, пока время искажено) и не мешают чужому слоумо
# (супер-QTE, прицел супер-рывка): бит стартует только с time_scale=1 и
# восстанавливает 1.0 только если время всё ещё ЕГО.
const BEAT_HEAVY_DEATH_SCALE := 0.3    # смерть гиганта/меха
const BEAT_HEAVY_DEATH_TIME := 0.25
const BEAT_MULTIKILL_SCALE := 0.35     # AOE снял 3+ врагов разом
const BEAT_MULTIKILL_TIME := 0.2
const BEAT_CLEAR_SCALE := 0.3          # последний враг зачистки (после ≥ CLEAR_MIN_KILLS)
const BEAT_CLEAR_TIME := 0.35
## Сколько убийств должно накопиться с прошлой «чистой поляны», чтобы добить
## последнего врага битом. Отсекает случайного одиночку-бродягу.
const CLEAR_MIN_KILLS := 4
## Шейк/вспышка кульминации смерти тяжёлого (поверх его собственного death-FX).
const HEAVY_DEATH_SHAKE := 0.5

var _beat_token: int = 0
## Убийств с последней «чистой поляны» — для гейта clear-бита.
var _kills_since_clear: int = 0


func _ready() -> void:
	# Кульминации смертей — централизованно тут (политика тайм-фила), а не в
	# каждом классе врага: смерть тяжёлого → бит+шейк+флеш; последний враг → бит.
	EventBus.enemy_destroyed.connect(_on_enemy_destroyed)


## Короткий глобальный slow-mo бит. Скипается, если время уже искажено (чужое
## слоумо или предыдущий бит). Таймер восстановления идёт в РЕАЛЬНОМ времени
## (ignore_time_scale) — иначе бит длился бы duration/scale.
func slowmo_beat(scale: float, duration: float) -> void:
	if Engine.time_scale < 0.999 or scale >= 1.0 or duration <= 0.0:
		return
	Engine.time_scale = scale
	_beat_token += 1
	var token := _beat_token
	get_tree().create_timer(duration, true, false, true).timeout.connect(func() -> void:
		# Возвращаем 1.0 только если время всё ещё наше: не наш токен или чужое
		# значение time_scale (вошёл супер-QTE/прицел) — не трогаем.
		if _beat_token == token and is_equal_approx(Engine.time_scale, scale):
			Engine.time_scale = 1.0)


func _on_enemy_destroyed(enemy: Node3D) -> void:
	_kills_since_clear += 1
	# Кульминация: смерть «весомого» (гигант/мех) — бит + шейк + лёгкий флеш-кадр.
	if is_instance_valid(enemy):
		for g in HEAVY_GROUPS:
			if enemy.is_in_group(g):
				slowmo_beat(BEAT_HEAVY_DEATH_SCALE, BEAT_HEAVY_DEATH_TIME)
				EventBus.camera_shake.emit(HEAVY_DEATH_SHAKE, enemy.global_position)
				AoeVisual.spawn_screen_flash(get_tree(), Color(1.0, 0.9, 0.75), 0.16, 0.14)
				break
	# «Поляна чистая»: этот враг был последним. Умирающий ещё в группе (queue_free
	# отложен) — считаем живых, исключая его и уже помеченных на удаление.
	# Литерал группы — как HEAVY_GROUPS (без import'а классов в автозагрузку).
	var remaining: int = 0
	for n in get_tree().get_nodes_in_group(&"enemy"):
		if n != enemy and is_instance_valid(n) and not n.is_queued_for_deletion():
			remaining += 1
	if remaining == 0:
		if _kills_since_clear >= CLEAR_MIN_KILLS:
			slowmo_beat(BEAT_CLEAR_SCALE, BEAT_CLEAR_TIME)
		_kills_since_clear = 0


## Хитстоп по цели: оглушает её на `duration` сек, если она «весомая» и не в
## рефракторе. Удар по рядовому скелету/лучнику игнорируется. `hit_dir` (travel
## снаряда, мир) задаёт сторону тильт-реакции — см. Enemy.apply_hitstop.
func fire_for(target: Object, duration: float, hit_dir: Vector3 = Vector3.ZERO) -> void:
	if duration <= 0.0 or not (target is Node):
		return
	var node := target as Node
	var heavy := false
	for g in HEAVY_GROUPS:
		if node.is_in_group(g):
			heavy = true
			break
	if not heavy or not node.has_method(&"apply_hitstop"):
		return
	var now := Time.get_ticks_msec()
	if now < int(node.get_meta(_CD, 0)):
		return  # ещё в рефракторе после прошлого оглушения
	var dur: float = minf(duration, MAX_DURATION)
	node.call(&"apply_hitstop", dur, hit_dir)
	node.set_meta(_CD, now + int((dur + REFRACTORY) * 1000.0))
