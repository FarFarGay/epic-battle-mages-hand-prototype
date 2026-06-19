extends StaticBody3D
## Стройплощадка-ЧЕРТЁЖ моста через пропасть. Создаётся ИГРОКОМ (HandBridgeAim — два
## клика: силуэт первой доски в руке → тянем ряд досок-силуэтов → второй клик ставит
## дальний край). Рабочий-гном (роль &"worker") с БРЕВНОМ заряжается на неё и кладёт
## доску УДАРОМ (gnome_hit) — единая модель «гном → точка → действие». Набрали
## planks_needed досок → мост готов.
##
## ПРОПАСТЬ ФЕЙКОВАЯ: пол (Ground) сплошной и под пропастью, тёмная полоса
## (ChasmVisual) — лишь визуал, а реально путь перекрывает невидимая СТЕНА-БАРЬЕР
## (ChasmBarrier, слой CAMP_OBSTACLE|PALISADE_OBSTACLE). Башня ходит ФИЗИКОЙ (не по
## навмешу), потому её пускает именно открытие барьера, а не доски.
##
## ПРОГРЕССИВНЫЙ БАРЬЕР («башня идёт по уложенным доскам»): при создании сразу режем
## в барьере ДВЕРНОЙ ПРОЁМ по ширине моста (два боковых сегмента по Z остаются стеной)
## и ставим ЗАТЫЧКУ — короб, перекрывающий ещё-не-замощённую часть пролёта по X (в
## пределах толщины стены). По мере укладки досок затычка отъезжает к дальнему краю:
## башня заходит на построенную часть и упирается в остаток стены (не падает — пол под
## ней есть). Достроили → затычку убрать + перепечь навмеш (гномы/скелеты тоже идут).
##
## Узел стоит на БЛИЖНЕМ конце пролёта, локальный +X направлен к дальнему (HandBridgeAim
## ориентирует через rotation.y). Доски спавнятся ПРОЦЕДУРНО от ближнего конца к дальнему.
##
## РАЗРУШАЕМ как любая постройка: сам узел — StaticBody3D с коллайдером-настилом на
## слое DESTRUCTIBLE_DECK (mask 0, навмеш игнорит, ходьбу башни не блокирует). Магия/
## слэм/burn (MASK_HAND_SLAM), а также дэш и щит башни бьют его через Damageable. Враги
## и Искра его не трогают (см. [Layers.DESTRUCTIBLE_DECK]). HP кончилось → коллапс:
## доски прочь, барьер пропасти восстановлен, навмеш перепечён — переход снова закрыт.

## Damageable-контракт (урон проходит через Damageable.try_damage по коллайдеру).
signal damaged(amount: float)
signal destroyed

const NAV_GROUP := &"nav_region"
const NAVMESH_SOURCE_GROUP := &"navmesh_source"
## Барьер пропасти помечен этой группой в сцене — находим по ней (чертёж создаётся в
## runtime, NodePath'а до барьера нет). Тёмную полосу (ChasmVisual) НЕ трогаем — пропасть
## остаётся, мост лишь ложится через неё.
const CHASM_BARRIER_GROUP := &"chasm_barrier"

## Сколько брёвен (досок) нужно на мост. HandBridgeAim ставит по длине пролёта.
@export var planks_needed: int = 8
## Длина пролёта вдоль локального +X (ширина, которую перекрываем досками).
@export var span_length: float = 8.0
## Полуширина настила по Z (ходимая ширина моста).
@export var span_half_z: float = 2.0
@export var plank_color: Color = Color(0.5, 0.35, 0.2)
## Цвет ghost-чертежа (полупрозрачные «недостроенные» доски на старте).
@export var ghost_color: Color = Color(0.55, 0.75, 0.95, 0.35)
## Прочность моста (HP). Разрушается атаками башни (магия/слэм/дэш/щит), не Искрой.
@export var hp_max: float = 120.0

var _planks: int = 0
var _complete: bool = false
var _destroyed: bool = false
var _hp: float = 0.0
var _planks_root: Node3D = null
## Силуэт-слоты досок (по одному на planks_needed). По мере укладки гасим i-й.
var _ghost_planks: Array[MeshInstance3D] = []

# --- Прогрессивный барьер (дверной проём + отъезжающая затычка) ---
## Затычка — физкороб, перекрывающий ещё-не-замощённую часть пролёта (в толщине стены).
var _plug: StaticBody3D = null
var _plug_col: CollisionShape3D = null
## Толщина стены пропасти по миру X (затычку режем в этих пределах — вне стены
## перекрывать нечего, иначе башня встала бы на ровном месте).
var _wall_x_min: float = 0.0
var _wall_x_max: float = 0.0
var _wall_y: float = 3.0
## Полоса моста по миру Z (ширина проёма).
var _gap_lo: float = 0.0
var _gap_hi: float = 0.0
## Слой исходного барьера пропасти — чтобы восстановить его при коллапсе моста.
var _barrier_layer: int = Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
var _barrier_ready: bool = false


func _ready() -> void:
	# Контейнер досок (если не задан в сцене — создаём).
	_planks_root = get_node_or_null(^"Planks")
	if _planks_root == null:
		_planks_root = Node3D.new()
		_planks_root.name = "Planks"
		add_child(_planks_root)
	_spawn_ghost_planks()
	_spawn_deck_collider()
	_hp = hp_max
	Damageable.register(self)  # урон от атак башни через Damageable.try_damage
	# Барьер режем ОТЛОЖЕННО: _ready срабатывает на add_child СИНХРОННО, ДО того как
	# HandBridgeAim выставит global_position/rotation.y моста. Прорезали бы проём вокруг
	# (0,0,0). call_deferred гонит setup в конце кадра — трансформ уже на месте.
	call_deferred(&"_setup_barrier")
	add_to_group(Layers.GNOME_STRIKE_TARGET_GROUP)
	add_to_group(Layers.BUILD_SITE_GROUP)  # area-клик → BUILD


## Коллайдер-настил во всю длину пролёта на слое DESTRUCTIBLE_DECK (mask 0): через него
## магия/слэм/дэш/щит наносят урон (Damageable по коллайдеру). Навмеш его не парсит
## (нет в navmesh_source), башня/враги его не маскируют — ходьбу по мосту не ломает.
func _spawn_deck_collider() -> void:
	collision_layer = Layers.DESTRUCTIBLE_DECK
	collision_mask = 0
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(span_length, 0.5, span_half_z * 2.0)
	col.shape = box
	# Узел на ближнем конце, настил тянется вдоль +X → центр короба на span/2.
	col.position = Vector3(span_length * 0.5, 0.25, 0.0)
	add_child(col)


## Локальный X центра доски №i (1-based) — настил от ближнего конца (origin) к дальнему.
func _slot_local_x(i: int) -> float:
	var step: float = span_length / float(maxi(planks_needed, 1))
	return (float(i) - 0.5) * step


## Полупрозрачные «слоты» досок во всю длину пролёта — видно, ЧТО будет построено.
## По мере стройки i-й слот гаснет, на его месте ложится настоящая доска.
func _spawn_ghost_planks() -> void:
	var step: float = span_length / float(maxi(planks_needed, 1))
	for i in range(1, planks_needed + 1):
		var g := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(step * 0.92, 0.1, span_half_z * 2.0)
		g.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = ghost_color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		g.material_override = mat
		g.position = Vector3(_slot_local_x(i), 0.12, 0.0)
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(g)
		_ghost_planks.append(g)


## Контракт strike-цели: класть доску может только рабочий С БРЕВНОМ. Пустой сперва
## сходит к дереву. Не рабочий (копейщик) — мимо.
func can_gnome_interact(gnome: Node) -> bool:
	if _complete:
		return false
	if not (gnome.has_method(&"is_worker") and gnome.is_worker()):
		return false
	return gnome.has_method(&"is_carrying") and gnome.is_carrying()


## Рабочий положил бревно: списываем ношу, кладём доску, гасим слот-силуэт, отодвигаем
## затычку (открываем башне ещё кусок). Набрали — мост готов.
func gnome_hit(gnome: Node) -> void:
	if _complete or gnome == null or not gnome.has_method(&"deliver_resource"):
		return
	if gnome.deliver_resource() < 0:
		return  # ресурса не оказалось (рассинхрон) — доску не кладём
	_planks += 1
	_spawn_plank(_planks)
	if _planks - 1 < _ghost_planks.size():
		var g := _ghost_planks[_planks - 1]
		if is_instance_valid(g):
			g.visible = false
	_advance_plug()
	if _planks >= planks_needed:
		_finish()


## Доска №i (1-based) — настил кладётся ОТ БЛИЖНЕГО конца (origin) к дальнему вдоль +X.
func _spawn_plank(i: int) -> void:
	if _planks_root == null:
		return
	var step: float = span_length / float(maxi(planks_needed, 1))
	var plank := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(step * 0.92, 0.16, span_half_z * 2.0)
	plank.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = plank_color
	plank.material_override = mat
	plank.position = Vector3(_slot_local_x(i), 0.14, 0.0)
	_planks_root.add_child(plank)


## Мост достроен: убрать слоты-силуэты + затычку + перепечь навмеш + выйти из групп.
func _finish() -> void:
	_complete = true
	remove_from_group(Layers.GNOME_STRIKE_TARGET_GROUP)
	if is_in_group(Layers.BUILD_SITE_GROUP):
		remove_from_group(Layers.BUILD_SITE_GROUP)  # достроен — больше не цель BUILD
	for g in _ghost_planks:
		if is_instance_valid(g):
			g.queue_free()
	_ghost_planks.clear()
	if is_instance_valid(_plug):
		_plug.queue_free()
	_plug = null
	_plug_col = null
	# Rebake СЛЕДУЮЩИМ кадром: queue_free отложен до конца кадра, а синхронный bake в
	# этом же кадре ещё парсит уходящую геометрию. 0-таймер срабатывает после flush'а.
	get_tree().create_timer(0.05).timeout.connect(_do_rebake)


## Перепечь навмеш (отложенно из _finish/_collapse). Гномы/скелеты получают путь ПО
## мосту (через проём) либо снова упираются в восстановленную стену.
func _do_rebake() -> void:
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		nav.rebake()


# --- Damageable (мост рушится атаками башни, не Искрой) ---

## Урон от атаки башни (магия/слэм/дэш/щит — все идут через Damageable.try_damage по
## коллайдеру-настилу). Искра/враги сюда не попадают (см. [Layers.DESTRUCTIBLE_DECK]).
func take_damage(amount: float) -> void:
	if _destroyed or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash_planks()
	if LogConfig.master_enabled:
		print("[BridgeSite] урон %.1f, hp=%.1f/%.1f" % [amount, maxf(_hp, 0.0), hp_max])
	if _hp <= 0.0:
		_collapse()


## Мост разрушен: доски/силуэты/затычка прочь, проём снова заделан стеной (пропасть
## закрывается), навмеш перепечён — переход закрыт. Из групп выходим СРАЗУ до emit
## (queue_free отложен — см. [[reference_godot_queue_free_deferred]]).
func _collapse() -> void:
	if _destroyed:
		return
	_destroyed = true
	_complete = true
	remove_from_group(Damageable.GROUP)
	remove_from_group(Layers.GNOME_STRIKE_TARGET_GROUP)
	if is_in_group(Layers.BUILD_SITE_GROUP):
		remove_from_group(Layers.BUILD_SITE_GROUP)
	collision_layer = 0  # больше не цель урона
	for g in _ghost_planks:
		if is_instance_valid(g):
			g.queue_free()
	_ghost_planks.clear()
	if _planks_root != null:
		for c in _planks_root.get_children():
			c.queue_free()
	if is_instance_valid(_plug):
		_plug.queue_free()
	_plug = null
	_plug_col = null
	_reclose_chasm()
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_dust(root, global_position)
	destroyed.emit()
	# Ребейк вешаем на сам nav-узел (не на self): мост сейчас queue_free'нется, а
	# колбэк, привязанный к освобождённому узлу, был бы тихо пропущен.
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		get_tree().create_timer(0.05).timeout.connect(Callable(nav, "rebake"))
	queue_free()


## Заделать проём обратно: ставим сегмент-барьер во всю ширину моста по Z и всю толщину
## стены по X (боковые сегменты уже стоят с _setup_barrier). Пропасть снова непроходима.
func _reclose_chasm() -> void:
	if not _barrier_ready:
		return  # проём ещё не резали (snесли мгновенно) — оригинальный барьер на месте
	var parent: Node = get_parent()
	var cx: float = (_wall_x_min + _wall_x_max) * 0.5
	var sx: float = _wall_x_max - _wall_x_min
	var cz: float = (_gap_lo + _gap_hi) * 0.5
	var sz: float = _gap_hi - _gap_lo
	# Слой как у исходного барьера/боковых сегментов (тот же барьер пропасти).
	_spawn_barrier_segment(parent, cx, cz, sx, _wall_y, sz, _barrier_layer)


## Красный flash настила при ударе (язык урона как у зданий).
func _flash_planks() -> void:
	if _planks_root == null:
		return
	for c in _planks_root.get_children():
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		var orig: Color = mat.albedo_color
		mat.albedo_color = Color(1.0, 0.3, 0.25)
		var tw := create_tween()
		tw.tween_property(mat, "albedo_color", orig, 0.18)


## Режет в барьере пропасти ДВЕРНОЙ ПРОЁМ по ширине моста (по Z): старый цельный
## барьер заменяем двумя боковыми сегментами (до и после полосы), а саму полосу
## перекрываем ЗАТЫЧКОЙ (она потом отъезжает по мере стройки). Навмеш НЕ перепекаем
## (гномы/скелеты видят старый бейк с цельным барьером — на недостроенный мост им
## нельзя; перепекаем только в _finish).
##
## ДОПУЩЕНИЕ (как и прежде): барьер axis-aligned, длинной осью по миру Z; мост кладут
## поперёк по X. Повёрнутый барьер/диагональный мост дадут рассинхрон — предупреждаем.
func _setup_barrier() -> void:
	if _destroyed:
		return  # мост снесли до того, как отложенный setup успел отработать
	var barrier := get_tree().get_first_node_in_group(CHASM_BARRIER_GROUP) as Node3D
	if barrier == null:
		return
	var cs := _find_collision_shape(barrier)
	var box: BoxShape3D = null
	if cs != null:
		box = cs.shape as BoxShape3D
	if cs == null or box == null:
		# Геометрию не прочесть — деградируем к старому поведению (убрать барьер целиком).
		if barrier.is_in_group(NAVMESH_SOURCE_GROUP):
			barrier.remove_from_group(NAVMESH_SOURCE_GROUP)
		barrier.queue_free()
		return
	var w: Transform3D = cs.global_transform
	if absf(w.basis.x.y) > 0.01 or absf(w.basis.z.y) > 0.01 or absf(w.basis.x.z) > 0.05:
		push_warning("[BridgeSite] барьер пропасти повёрнут — проём может не совпасть с мостом")
	var cx: float = w.origin.x
	var sx: float = box.size.x
	var sy: float = box.size.y
	var sz: float = box.size.z
	_wall_x_min = cx - sx * 0.5
	_wall_x_max = cx + sx * 0.5
	_wall_y = sy
	var z_min: float = w.origin.z - sz * 0.5
	var z_max: float = w.origin.z + sz * 0.5
	# Полоса под мостом по Z (узел моста стоит на ближнем конце, но по Z он в середине
	# ширины пролёта — настил симметричен по локальному Z вокруг origin.z).
	_gap_lo = global_position.z - span_half_z
	_gap_hi = global_position.z + span_half_z
	var parent := barrier.get_parent()
	var layer: int = barrier.collision_layer
	_barrier_layer = layer
	# Нейтрализуем оригинал СРАЗУ (queue_free отложен): вон из навмеш-группы + слой 0 +
	# коллайдер disabled. Навмеш не перепекаем — старый бейк держит цельный барьер.
	if barrier.is_in_group(NAVMESH_SOURCE_GROUP):
		barrier.remove_from_group(NAVMESH_SOURCE_GROUP)
	if barrier is CollisionObject3D:
		(barrier as CollisionObject3D).collision_layer = 0
	cs.disabled = true
	barrier.queue_free()
	# Боковые сегменты (вне ширины моста по Z) — постоянные части пропасти, в навмеш-группе.
	if _gap_lo > z_min + 0.1:
		_spawn_barrier_segment(parent, cx, (z_min + _gap_lo) * 0.5, sx, sy, _gap_lo - z_min, layer)
	if _gap_hi < z_max - 0.1:
		_spawn_barrier_segment(parent, cx, (_gap_hi + z_max) * 0.5, sx, sy, z_max - _gap_hi, layer)
	# Затычка проёма — физкороб БЕЗ навмеш-группы (временный, перекрывает недострой по X
	# для башни). Размер/позицию задаёт _advance_plug по числу уложенных досок.
	_plug = StaticBody3D.new()
	_plug.collision_layer = layer
	_plug.collision_mask = 0
	parent.add_child(_plug)
	_plug_col = CollisionShape3D.new()
	_plug_col.shape = BoxShape3D.new()
	_plug.add_child(_plug_col)
	_barrier_ready = true
	_advance_plug()


## Отодвинуть затычку к дальнему краю по числу уложенных досок: перекрываем только
## ещё-не-замощённую часть пролёта, пересечённую со стеной по X. Доски прошли стену
## насквозь → затычку убираем (проём открыт для башни до полного _finish).
func _advance_plug() -> void:
	if not _barrier_ready or not is_instance_valid(_plug) or _plug_col == null:
		return
	var frac: float = clampf(float(_planks) / float(maxi(planks_needed, 1)), 0.0, 1.0)
	var near_x: float = global_position.x
	var far_x: float = to_global(Vector3(span_length, 0.0, 0.0)).x
	var front_x: float = lerpf(near_x, far_x, frac)  # фронт уложенного по миру X
	# Незамощённая часть [front..far] (порядок краёв любой), пересечённая со стеной.
	var unbuilt_lo: float = minf(front_x, far_x)
	var unbuilt_hi: float = maxf(front_x, far_x)
	var plo: float = maxf(unbuilt_lo, _wall_x_min)
	var phi: float = minf(unbuilt_hi, _wall_x_max)
	if phi <= plo + 0.05:
		# Доски прошли стену — затычка не нужна.
		_plug.queue_free()
		_plug = null
		_plug_col = null
		return
	(_plug_col.shape as BoxShape3D).size = Vector3(phi - plo, _wall_y, _gap_hi - _gap_lo)
	_plug_col.position = Vector3(0.0, _wall_y * 0.5, 0.0)  # низ короба на y=0
	_plug.global_position = Vector3((plo + phi) * 0.5, 0.0, (_gap_lo + _gap_hi) * 0.5)


func _find_collision_shape(body: Node) -> CollisionShape3D:
	for c in body.get_children():
		if c is CollisionShape3D:
			return c as CollisionShape3D
	return null


## Создаёт сегмент барьера пропасти (StaticBody с box-коллайдером) в мире. Те же группы
## и слой, что у исходного барьера — навмеш снова выгрызает эту часть пропасти.
func _spawn_barrier_segment(parent: Node, cx: float, cz: float, sx: float, sy: float, sz: float, layer: int) -> void:
	if parent == null:
		return
	var sb := StaticBody3D.new()
	sb.collision_layer = layer
	sb.collision_mask = 0
	sb.add_to_group(NAVMESH_SOURCE_GROUP)
	sb.add_to_group(CHASM_BARRIER_GROUP)
	parent.add_child(sb)
	sb.global_position = Vector3(cx, 0.0, cz)
	var col := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(sx, sy, sz)
	col.shape = b
	col.position = Vector3(0.0, sy * 0.5, 0.0)  # низ короба на y=0 (как у исходного)
	sb.add_child(col)
