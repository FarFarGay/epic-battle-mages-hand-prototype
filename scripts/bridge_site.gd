extends Node3D
## Стройплощадка-ЧЕРТЁЖ моста через пропасть. Создаётся ИГРОКОМ (HandBridgeAim — два
## клика по краям пропасти задают пролёт), не стоит в сцене заранее. Рабочий-гном
## (роль &"worker") с БРЕВНОМ заряжается на неё и кладёт доску УДАРОМ (gnome_hit) —
## единая модель «гном → точка → действие». Набрали planks_needed досок → мост готов:
## барьер пропасти снят, навмеш перепечён (башня и юниты проходят на ту сторону).
##
## Узел стоит в СЕРЕДИНЕ пролёта, локальный +X направлен вдоль него (HandBridgeAim
## ориентирует через look_at). Доски спавнятся ПРОЦЕДУРНО по ходу стройки от центра
## к краям (визуал зависит от runtime-прогресса; ср. процедурный провод RedDiode).

const GNOME_STRIKE_GROUP := &"gnome_strike_target"
const WORKER_ROLE := &"worker"
const NAV_GROUP := &"nav_region"
const NAVMESH_SOURCE_GROUP := &"navmesh_source"
## Барьер пропасти и тёмная полоса помечены этими группами в сцене — находим по ним
## (чертёж создаётся в runtime, NodePath'ов до них нет).
const CHASM_BARRIER_GROUP := &"chasm_barrier"
const CHASM_VISUAL_GROUP := &"chasm_visual"

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
	_ghost.position = Vector3(0.0, 0.12, 0.0)
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


## Доска №i (1-based) — настил кладётся от центра пролёта к краям.
func _spawn_plank(i: int) -> void:
	if _planks_root == null:
		return
	var step: float = span_length / float(planks_needed)
	var plank := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(step * 0.92, 0.16, span_half_z * 2.0)
	plank.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = plank_color
	plank.material_override = mat
	# Локально вдоль +X, центрировано на узле: доска i по местам -span/2 .. +span/2.
	var local_x: float = -span_length * 0.5 + (float(i) - 0.5) * step
	plank.position = Vector3(local_x, 0.14, 0.0)
	_planks_root.add_child(plank)


## Мост достроен: убрать ghost + снять барьер пропасти + перепечь навмеш (как двери) +
## спрятать тёмную полосу + выйти из strike-группы.
func _finish() -> void:
	_complete = true
	remove_from_group(GNOME_STRIKE_GROUP)
	if is_instance_valid(_ghost):
		_ghost.queue_free()
		_ghost = null
	var barrier := get_tree().get_first_node_in_group(CHASM_BARRIER_GROUP)
	if barrier != null:
		# Снять с навмеша СРАЗУ (queue_free отложен до конца кадра — иначе rebake
		# ещё «видит» барьер и проём не откроется). Затем убрать тело.
		if barrier.is_in_group(NAVMESH_SOURCE_GROUP):
			barrier.remove_from_group(NAVMESH_SOURCE_GROUP)
		barrier.queue_free()
	var chasm_vis := get_tree().get_first_node_in_group(CHASM_VISUAL_GROUP)
	if chasm_vis != null and chasm_vis is Node3D:
		(chasm_vis as Node3D).visible = false
	# Проём открыт — перепечь навмеш (башня/юниты пойдут на ту сторону).
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		nav.rebake()
