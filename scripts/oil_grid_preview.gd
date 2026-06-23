@tool
extends MeshInstance3D
## РЕДАКТОРНОЕ превью нефте-решётки: рисует клетки вокруг себя (узел — ребёнок
## коллектора, ЯКОРЬ = его global_position, как у рантайм-снапа). Дизайнер видит грид
## прямо в редакторе и ровно расставляет залежи/постройки по клеткам. В ИГРЕ скрыто —
## рантайм-сетка показывается лишь при стройке ([HandPlaceAim]). Шейдер общий
## (res://shaders/build_grid.gdshader).

## Размер клетки нефте-решётки (= PipeSegment.ARM_LEN * 2). Один источник правды о
## клетке держим в трубе; здесь дублируем константой, т.к. @tool грузится без неё.
const CELL := 2.0
## Сторона превью-плоскости (м) — берём с запасом, чтобы накрыть комнаты с залежами.
@export var preview_size: float = 220.0


func _ready() -> void:
	if not Engine.is_editor_hint():
		visible = false  # в игре превью не нужно (рантайм-сетка — у HandPlaceAim)
		return
	_rebuild()


func _rebuild() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(preview_size, preview_size)
	mesh = pm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/build_grid.gdshader")
	mat.set_shader_parameter(&"cell", CELL)
	mat.set_shader_parameter(&"fade_start", preview_size * 0.42)
	mat.set_shader_parameter(&"fade_end", preview_size * 0.5)
	material_override = mat
	position = Vector3(0.0, 0.06, 0.0)  # чуть над землёй, поверх травы


## Фаза сетки = собственная мировая XZ (узел сидит на коллекторе). Обновляем каждый
## редакторный кадр — двигаешь коллектор, грид едет следом. Дёшево (один параметр).
func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	var mat := material_override as ShaderMaterial
	if mat == null:
		_rebuild()
		mat = material_override as ShaderMaterial
	if mat != null:
		var a: Vector3 = global_position
		mat.set_shader_parameter(&"grid_anchor", Vector2(a.x, a.z))
