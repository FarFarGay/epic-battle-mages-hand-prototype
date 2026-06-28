@tool
class_name OilDeposit
extends Node3D
## Жила-месторождение — 1 клетка грида, на которую ставят добытчик (шахту/бур). Маркер;
## дизайнер расставляет по сетке ([CityGrid], превью [grid_anchor.gd]). group oil_deposit.
##
## tier — что добывается (богатство жилы → номинал монеты): 🥉 бронза / 🥈 серебро / 🥇 золото.
## `coin_type()` мапит тир в [ResourcePile.ResourceType] для казны. richness — множитель
## добычи (для бура нефти, легаси). occupied — занято ли добытчиком (чтобы не лез второй).
##
## @tool: тинтит «Seep» по тиру прямо в редакторе — видно, какая это жила, при расстановке.

const GROUP := &"oil_deposit"

## Тир жилы = что из неё добывают (номинал монеты).
enum Tier { BRONZE, SILVER, GOLD }

## Тир (бронза/серебро/золото). Меняешь в инспекторе → жила перекрашивается вживую.
@export var tier: Tier = Tier.BRONZE:
	set(v):
		tier = v
		_apply_tint()
## Множитель добычи (богатая жила = больше). Используется буром нефти (легаси).
@export var richness: float = 1.0

var occupied: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	_apply_tint()


## Клетка грида, на которой стоит жила (1 клетка).
func deposit_cell(tree: SceneTree) -> Vector2i:
	return CityGrid.world_to_cell(global_position, tree)


## Карта {клетка: OilDeposit} по всем жилам сцены — для гейта размещения (на жилу только
## шахту, шахту только на жилу) в [HandPlaceAim]._pad_valid и привязки шахты.
static func cell_map(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for n in tree.get_nodes_in_group(GROUP):
		var d := n as OilDeposit
		if d != null and is_instance_valid(d):
			out[d.deposit_cell(tree)] = d
	return out


## Номинал добычи. ЕДИНАЯ валюта (2026-06-28): все жилы дают БРОНЗУ, она сама копится в
## серебро/золото в казне (одометр, [[project_ebm_coin_economy]]). `tier` оставлен как
## легаси-поле (не влияет) — чтобы не ломать сцены с уже расставленными жилами.
func coin_type() -> int:
	return ResourcePile.ResourceType.BRONZE


## Цвет жилы — единый (1 тип жил). Бронза/медь.
func _tier_color() -> Color:
	return Color(0.74, 0.46, 0.22)


## Перекрасить диск «Seep» под тир (металлический блеск + свечение). Материал создаём в
## коде (per-instance) — не мутируем общий ресурс сцены.
func _apply_tint() -> void:
	var seep := get_node_or_null(^"Seep") as MeshInstance3D
	if seep == null:
		return
	var c: Color = _tier_color()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.metallic = 0.6
	mat.roughness = 0.3
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 0.35
	seep.material_override = mat
