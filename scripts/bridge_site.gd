extends Node3D
## Стройплощадка-ЧЕРТЁЖ моста через пропасть. Создаётся ИГРОКОМ (HandBridgeAim — два
## клика по краям пропасти задают пролёт), не стоит в сцене заранее. Рабочий-гном
## (роль &"worker") с БРЕВНОМ заряжается на неё и кладёт доску УДАРОМ (gnome_hit) —
## единая модель «гном → точка → действие». Набрали planks_needed досок → мост готов:
## в барьере пропасти вырезается ПОЛОСА под настилом (пройти можно ТОЛЬКО по мосту,
## остальная пропасть — по-прежнему стена; сама пропасть НЕ исчезает), навмеш перепечён.
##
## Узел стоит в СЕРЕДИНЕ пролёта, локальный +X направлен вдоль него (HandBridgeAim
## ориентирует через look_at). Доски спавнятся ПРОЦЕДУРНО по ходу стройки от центра
## к краям (визуал зависит от runtime-прогресса; ср. процедурный провод RedDiode).

const GNOME_STRIKE_GROUP := &"gnome_strike_target"
const WORKER_ROLE := &"worker"
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

var _planks: int = 0
var _complete: bool = false
var _planks_root: Node3D = null
var _ghost: MeshInstance3D = null


func _ready() -> void:
	# Контейнер досок (если не задан в сцене — создаём).
	_planks_root = get_node_or_null(^"Planks")
	if _planks_root == null:
		_planks_root = Node3D.new()
		_planks_root.name = "Planks"
		add_child(_planks_root)
	_spawn_ghost()
	add_to_group(GNOME_STRIKE_GROUP)


## Полупрозрачный «чертёж» во всю длину пролёта — видно, ЧТО будет построено,
## пока доски ещё не уложены. По мере стройки доски ложатся поверх него.
func _spawn_ghost() -> void:
	_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(span_length, 0.1, span_half_z * 2.0)
	_ghost.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ghost_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.material_override = mat
	# Узел стоит на БЛИЖНЕМ конце, пролёт тянется вдоль +X → центр ghost'а на span/2.
	_ghost.position = Vector3(span_length * 0.5, 0.12, 0.0)
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)


## Контракт strike-цели: класть доску может только рабочий С БРЕВНОМ. Пустой сперва
## сходит к дереву. Не рабочий (копейщик) — мимо.
func can_gnome_interact(gnome: Node) -> bool:
	if _complete:
		return false
	if gnome.get(&"soldier_type") != WORKER_ROLE:
		return false
	return gnome.has_method(&"is_carrying") and gnome.is_carrying()


## Рабочий положил бревно: списываем его ношу, кладём доску. Набрали — мост готов.
func gnome_hit(gnome: Node) -> void:
	if _complete or gnome == null or not gnome.has_method(&"deliver_log"):
		return
	if not gnome.deliver_log():
		return  # бревна не оказалось (рассинхрон) — доску не кладём
	_planks += 1
	_spawn_plank(_planks)
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
	# От origin (ближний конец) к +X: доска i по местам 0 .. span_length.
	var local_x: float = (float(i) - 0.5) * step
	plank.position = Vector3(local_x, 0.14, 0.0)
	_planks_root.add_child(plank)


## Мост достроен: убрать ghost + вырезать в барьере полосу ПОД настилом (проход только
## по мосту, пропасть остаётся) + перепечь навмеш + выйти из strike-группы.
func _finish() -> void:
	_complete = true
	remove_from_group(GNOME_STRIKE_GROUP)
	if is_instance_valid(_ghost):
		_ghost.queue_free()
		_ghost = null
	_open_chasm_gap()  # пропасть НЕ исчезает — открывается лишь полоса под мостом
	# Rebake СЛЕДУЮЩИМ кадром: старый цельный барьер уходит через queue_free только в
	# конце текущего кадра, а синхронный bake в этом же кадре ещё парсит его коллизию
	# (gap не открывается). 0-таймер срабатывает после flush'а — барьера уже нет.
	get_tree().create_timer(0.05).timeout.connect(_do_rebake)


## Перепечь навмеш (отложенно из _finish — после удаления старого барьера). Башня и
## юниты получают путь ПО мосту (в открытой полосе), остальная пропасть блокирует.
func _do_rebake() -> void:
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		nav.rebake()


## Вырезает в барьере пропасти полосу шириной настила (по оси Z пропасти) на месте
## моста: старый цельный барьер заменяем двумя сегментами (до и после полосы). Пройти
## можно ТОЛЬКО в полосе (по мосту); остальная пропасть — стена. Сама тёмная полоса
## (ChasmVisual) остаётся — пропасть никуда не девается, просто через неё лёг мост.
func _open_chasm_gap() -> void:
	var barrier := get_tree().get_first_node_in_group(CHASM_BARRIER_GROUP) as Node3D
	if barrier == null:
		return
	var cs := _find_collision_shape(barrier)
	var box: BoxShape3D = null
	if cs != null:
		box = cs.shape as BoxShape3D
	if cs == null or box == null:
		# Геометрию не прочесть — деградируем к старому поведению (убрать барьер).
		if barrier.is_in_group(NAVMESH_SOURCE_GROUP):
			barrier.remove_from_group(NAVMESH_SOURCE_GROUP)
		barrier.queue_free()
		return
	var w: Transform3D = cs.global_transform
	var cx: float = w.origin.x
	var sx: float = box.size.x
	var sy: float = box.size.y
	var sz: float = box.size.z
	var z_min: float = w.origin.z - sz * 0.5
	var z_max: float = w.origin.z + sz * 0.5
	# Полоса под мостом по Z (узел моста стоит в середине пролёта).
	var gap_lo: float = global_position.z - span_half_z
	var gap_hi: float = global_position.z + span_half_z
	var parent := barrier.get_parent()
	var layer: int = barrier.collision_layer
	# Старый цельный барьер нейтрализуем СРАЗУ (queue_free отложен до конца кадра, а
	# rebake синхронный — иначе бейк ещё видит полный барьер и проём не открывается):
	# вон из навмеш-группы + слой коллизии в 0 + коллайдер disabled. Потом удаляем.
	if barrier.is_in_group(NAVMESH_SOURCE_GROUP):
		barrier.remove_from_group(NAVMESH_SOURCE_GROUP)
	if barrier is CollisionObject3D:
		(barrier as CollisionObject3D).collision_layer = 0
	cs.disabled = true
	barrier.queue_free()
	# Сегмент «до» полосы (южная часть пропасти).
	if gap_lo > z_min + 0.1:
		_spawn_barrier_segment(parent, cx, (z_min + gap_lo) * 0.5, sx, sy, gap_lo - z_min, layer)
	# Сегмент «после» полосы (северная часть пропасти).
	if gap_hi < z_max - 0.1:
		_spawn_barrier_segment(parent, cx, (gap_hi + z_max) * 0.5, sx, sy, z_max - gap_hi, layer)


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
