class_name VeinBoulder
extends StaticBody3D
## СТОЯЧАЯ ЖИЛА (DESIGN.md §4, «пук-пук»): валун с кристаллами в поле. Рука
## КРОШИТ её ударами (slam/flick/магия — любой урон, симметрия взаимодействий),
## каждый выбитый шматок — [ResourceOrb], выпрыгивает дугой и лежит рядом;
## подъехала башня с местом в трюме — орб сам магнитится и сдаётся (не-дерево
## конвертится в монеты на складе, см. tower_store.deposit).
##
## Урон копится в _damage_pool: каждый damage_per_chunk выбивает шматок. Так
## slam (25×falloff) даёт ~1 шматок за шлепок, fireball — пару, burn-тик
## доковыривает медленно — без per-source особых случаев. Запас кончился —
## залежь рассыпается (ShatterEffect) и исчезает.
##
## Тело САМО damageable (принцип «collider = damageable», не родитель).
## Слой CAMP_OBSTACLE: рука/магия видят через MASK_HAND_SLAM, башня и скелеты
## упираются как в валун. Визуал — общий язык залежей (VeinVisuals), как у
## маркеров жил в гриде города, но крупнее (deco_scale).

signal damaged(amount: float)
signal destroyed
## Шматок выбит; remaining — сколько ещё осталось в жиле.
signal chunk_popped(remaining: int)

const GROUP := &"vein_boulder"

## Тип ресурса шматков (ResourcePile.ResourceType). Камень/железо на складе
## сразу конвертятся в монеты; дерево — стройматериал (буфер трюма).
@export_enum("Stone:2", "Iron:3", "Wood:1") var resource_type: int = ResourcePile.ResourceType.STONE
## Сколько шматков в жиле всего.
@export_range(1, 120) var units: int = 24
## Сколько накопленного урона выбивает один шматок. Slam в упор ≈ 25×falloff —
## подобрано так, чтобы шлепок выбивал ВЕЕР из ~4-5 осколков (импакт, юзер
## 2026-07-21), fireball ~7; жила при units=24 живёт ~5-6 шлепков.
@export var damage_per_chunk: float = 5.0
## Единиц ресурса в одном шматке (amount орба). Жирные жилы — больше.
@export_range(1, 5) var chunk_units: int = 1
## Масштаб визуала залежи (1.0 = маркер грида; в поле жила крупнее).
@export var deco_scale: float = 2.0
## Разлёт шматка: горизонтальная / вертикальная скорость подлёта.
@export var pop_speed_horizontal: float = 3.0
@export var pop_speed_vertical: float = 5.0
@export var debug_log: bool = true

## Пауза между осколками одного веера: удар выбивает их ОЧЕРЕДЬЮ («бр-р-рт»),
## а не все в один кадр — читается щедрее и мощнее (импакт-пакет 2026-07-21).
const POP_STAGGER: float = 0.045
## Порог amount, ниже которого удар не трясёт камеру (burn-тик ковыряет тихо).
const SHAKE_MIN_HIT: float = 8.0

var _damage_pool: float = 0.0
## Идемпотентность смерти (контракт Damageable): destroyed ровно один раз.
var _dying: bool = false
var _deco: Node3D = null
var _punch_tween: Tween = null
## Цвета залежи [rock, crystal] — для мини-шаттера на удар и рассыпания.
var _rock_color: Color = Color(0.5, 0.5, 0.52)
var _crystal_color: Color = Color(0.62, 0.72, 0.92)
## Очередь стаггера: сколько осколков ещё должно вылететь (units уже списаны).
var _pending_pops: int = 0
var _pop_timer: float = 0.0
## Горизонтальный вектор последнего удара (из meta last_hit_dir, кладёт
## Damageable.try_damage) — веер летит ОТ руки, конусом вокруг него.
var _last_hit_dir: Vector3 = Vector3.ZERO
## Все меши залежи — для hit-flash всей жилы разом.
var _flash_meshes: Array[MeshInstance3D] = []
## Кристаллы (или кроны у леска): конусы залежи. Редеют с запасом — удары
## оставляют след, к последнему шлепку валун почти голый.
var _sparkle_meshes: Array[MeshInstance3D] = []
var _initial_units: int = 1


func _ready() -> void:
	add_to_group(GROUP)
	Damageable.register(self)
	_deco = Node3D.new()
	_deco.name = "Deco"
	add_child(_deco)
	if resource_type == ResourcePile.ResourceType.WOOD:
		VeinVisuals.build_grove(_deco)
	else:
		var cols: Array = VeinVisuals.colors_for_type(resource_type)
		_rock_color = cols[0]
		_crystal_color = cols[1]
		VeinVisuals.build_ore_pile(_deco, _rock_color, _crystal_color)
	_deco.scale = Vector3.ONE * deco_scale
	_initial_units = maxi(units, 1)
	# Разбор мешей залежи: все — под hit-flash; конусы (кристаллы у руды,
	# кроны у леска: CylinderMesh с top_radius=0) — под редение с запасом.
	for ch in _deco.get_children():
		var mi := ch as MeshInstance3D
		if mi == null:
			continue
		_flash_meshes.append(mi)
		var cyl := mi.mesh as CylinderMesh
		if cyl != null and cyl.top_radius <= 0.001:
			_sparkle_meshes.append(mi)
	if debug_log and LogConfig.master_enabled:
		print("[VeinBoulder] жила %s готова: type=%d, шматков=%d" % [name, resource_type, units])


## Стаггер веера: очередь _pending_pops разряжается по осколку раз в
## POP_STAGGER. Когда запас и очередь пусты — жила рассыпается (die здесь,
## а не в take_damage: иначе queue_free оборвал бы недолетевший веер).
func _physics_process(delta: float) -> void:
	if _dying:
		return
	if _pending_pops > 0:
		_pop_timer -= delta
		if _pop_timer <= 0.0:
			_pop_timer = POP_STAGGER
			_pending_pops -= 1
			_pop_chunk()
	elif units <= 0:
		_die()


# --- Damageable ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	_damage_pool += amount
	damaged.emit(amount)
	_hit_punch()
	# Вспышка всей залежи (единый FX-контракт ударов, HitFlash как у врагов).
	for mi in _flash_meshes:
		HitFlash.flash(mi)
	# Вектор удара — из meta (кладёт Damageable.try_damage при hit_dir).
	# Обновляем только когда источник его дал (слэм); AOE без вектора
	# (fireball/burn) оставляют прошлый/нулевой → веер радиальный.
	var raw_dir: Variant = get_meta(&"last_hit_dir", Vector3.ZERO)
	_last_hit_dir = VecUtil.horizontal(raw_dir) if raw_dir is Vector3 else Vector3.ZERO
	set_meta(&"last_hit_dir", Vector3.ZERO)
	# Сколько осколков выбил этот удар — списываем запас сразу (экономика),
	# вылетают очередью в _physics_process (стаггер).
	var pops: int = mini(int(_damage_pool / damage_per_chunk), units)
	if pops > 0:
		_damage_pool -= float(pops) * damage_per_chunk
		units -= pops
		if _pending_pops == 0:
			_pop_timer = 0.0  # первый осколок веера — в этот же кадр
		_pending_pops += pops
		_refresh_richness()
		# Вздрог камеры ∝ размеру веера; DoT-тики (amount < порога) не трясут.
		if amount >= SHAKE_MIN_HIT:
			EventBus.camera_shake.emit(clampf(0.04 * float(pops), 0.06, 0.16), global_position)


## Кристаллы (кроны) редеют с запасом: часть гаснет совсем, остальные мельчают.
## Honest-индикатор «сколько осталось» без цифр — след от ударов накапливается.
func _refresh_richness() -> void:
	var n: int = _sparkle_meshes.size()
	if n == 0:
		return
	var ratio: float = clampf(float(units) / float(_initial_units), 0.0, 1.0)
	var visible_count: int = int(ceil(ratio * float(n)))
	for i in range(n):
		var mi: MeshInstance3D = _sparkle_meshes[i]
		if not is_instance_valid(mi):
			continue
		mi.visible = i < visible_count
		mi.scale = Vector3.ONE * lerpf(0.55, 1.0, ratio)


## Сквош-панч по визуалу на любой удар («жила отозвалась»), даже если шматок
## не выбился. Только _deco — StaticBody не скейлим (скейл коллайдера = боль).
func _hit_punch() -> void:
	if _deco == null or not is_instance_valid(_deco):
		return
	if _punch_tween != null and _punch_tween.is_valid():
		_punch_tween.kill()
	_deco.scale = Vector3.ONE * deco_scale
	_punch_tween = create_tween()
	_punch_tween.tween_property(_deco, "scale",
		Vector3(1.12, 0.82, 1.12) * deco_scale, 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_punch_tween.tween_property(_deco, "scale",
		Vector3.ONE * deco_scale, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Шматок: ResourceOrb-осколок (кристалл цвета жилы) выпрыгивает дугой в
## случайную сторону. Отдельного FX-шаттера НЕТ намеренно (юзер 2026-07-21):
## осколок, вылетающий из жилы, и ЕСТЬ шматок — один визуальный язык, один
## смысл. Кристальный цвет в полёте = «это ресурс, его можно собрать».
func _pop_chunk() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var orb := ResourceOrb.new()
	orb.resource_type = resource_type
	orb.amount = chunk_units
	if resource_type != ResourcePile.ResourceType.WOOD:
		orb.shard_color = _crystal_color
	scene.add_child(orb)
	var top := global_position + Vector3.UP * (0.9 * deco_scale)
	orb.global_position = top
	# Направленный веер (F1): есть вектор удара → конус ~±50° ВОКРУГ него
	# («выбил ОТ руки»); нет (fireball/burn) — радиально.
	var ang: float
	if _last_hit_dir.length_squared() > 0.01:
		ang = atan2(_last_hit_dir.z, _last_hit_dir.x) + randf_range(-0.9, 0.9)
	else:
		ang = randf() * TAU
	var dir := Vector3(cos(ang), 0.0, sin(ang))
	# Скорости слегка рандомные — веер из нескольких осколков за один удар
	# разлетается неровно, живо, а не синхронным кольцом.
	var h: float = pop_speed_horizontal * randf_range(0.6, 1.4)
	var v: float = pop_speed_vertical * randf_range(0.8, 1.25)
	orb.launch(dir * h + Vector3.UP * v)
	chunk_popped.emit(units)
	if debug_log and LogConfig.master_enabled:
		print("[VeinBoulder] шматок выбит (%s), осталось %d" % [name, units])


## Запас кончился: жила рассыпается shatter'ом ПОРОДЫ (без кристального цвета —
## кристалл в полёте теперь значит «ресурс-шматок», пустая порода серая),
## тело исчезает (StaticBody уходит из мира, башня больше не упирается).
## Рассыпание = локальная кульминация: короткий slowmo-бит + шейк. Рядовые
## шлепки время НЕ трогают (иерархия импакта HitStop: мелочь без слоумо).
func _die() -> void:
	if _dying:
		return
	_dying = true
	var scene := get_tree().current_scene
	if scene != null:
		var center := global_position + Vector3.UP * (0.5 * deco_scale)
		ShatterEffect.spawn(scene, center, _rock_color, 12, 1.6, _last_hit_dir)
	HitStop.slowmo_beat(0.45, 0.12)
	EventBus.camera_shake.emit(0.25, global_position)
	destroyed.emit()
	if debug_log and LogConfig.master_enabled:
		print("[VeinBoulder] жила %s исчерпана и рассыпалась" % name)
	queue_free()
