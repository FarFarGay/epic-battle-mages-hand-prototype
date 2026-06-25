@tool
extends Node3D
## Маркер-якорь грида уровня (группа [CityGrid.ANCHOR_GROUP]). ОДИН на уровень. Его позиция
## = начало координат единого грида — [CityGrid] читает её для снапа/клеток/площадки. Двигаешь
## эту ноду → весь грид и зона застройки едут вместе (грид НЕ плавает за замком, он тут фикс).
##
## @tool: рисует превью ВО ВЬЮПОРТЕ редактора — сетку клеток (тот же шейдер build_grid, что
## грид размещения в игре) + зелёную границу площадки 9×9. Чтобы ставить залежи/постройки
## ровно по клеткам. В ИГРЕ превью скрыто (там грид размещения рисует [HandPlaceAim] при стройке).

const GRID_SHADER := "res://shaders/build_grid.gdshader"


func _ready() -> void:
	add_to_group(CityGrid.ANCHOR_GROUP)  # якорь нужен и в игре, и в редакторе
	if not Engine.is_editor_hint():
		visible = false  # в игре превью не нужно — грид рисует HandPlaceAim при размещении
		return
	_rebuild()


## Размер плоскости превью (м) — на всю карту (пол уровня ~300×300), чтобы сетка была видна
## везде и ресурсы ставились по клеткам в любой точке.
const PREVIEW_SIZE := 300.0


func _rebuild() -> void:
	for ch in get_children():
		ch.free()
	_build_grid()


## Плоскость с шейдером сетки клеток (как в игре): шаг CityGrid.CELL, якорь = позиция ноды.
## Затухание шейдера отключаем (fade за горизонт) — сетка видна по ВСЕЙ карте, не пятном.
## Площадку 9×9 тут НЕ рисуем: она динамическая, считается вокруг ЗАМКА в рантайме.
func _build_grid() -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
	mi.mesh = pm
	mi.position = Vector3(0, 0.06, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Прозрачная плоскость 300×300 не должна лезть в SDFGI/освещение (иначе config-ворнинги
	# про GI на сцене с sdfgi_enabled) — выключаем её участие в global illumination.
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var sh := load(GRID_SHADER)
	if sh != null:
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter(&"cell", CityGrid.CELL)
		mat.set_shader_parameter(&"grid_anchor", Vector2(global_position.x, global_position.z))
		mat.set_shader_parameter(&"fade_start", PREVIEW_SIZE)   # без затухания в пределах карты
		mat.set_shader_parameter(&"fade_end", PREVIEW_SIZE * 1.5)
		mi.material_override = mat
	add_child(mi)
