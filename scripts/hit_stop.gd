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
