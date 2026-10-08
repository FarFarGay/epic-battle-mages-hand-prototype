extends Node3D
const Site = preload("res://scripts/defense_site.gd")
const Geo = preload("res://scripts/geo.gd")
enum Mode { IDLE, MENU, AIM }
var arena
var sites: Array[Node3D] = []
var mode := Mode.IDLE
var selected: Node3D
var hovered: Node3D
var menu: PanelContainer
var choice: Button
var cost_label: Label
var ghost: Node3D
var sector: MeshInstance3D
var heading := 0.0
var sector_wait := 0.0
var direction_valid := false
var reorienting := false
var ghost_material: StandardMaterial3D
var sector_material: StandardMaterial3D
var outline_material: StandardMaterial3D

func _ready() -> void:
	name = "DefenseBuilding"
	for node in arena.level.find_children("*","Node3D",true,false):
		if node is Site:
			node.arena = arena
			sites.append(node)
	menu = PanelContainer.new()
	menu.name = "BuildMenu"
	menu.z_index = 20
	menu.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color("172a30")
	style.border_color = Color("ddb574")
	style.set_border_width_all(2)
	style.set_content_margin_all(12)
	style.set_corner_radius_all(5)
	menu.add_theme_stylebox_override("panel",style)
	arena.hud.add_child(menu)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation",8)
	menu.add_child(box)
	var title := Label.new()
	title.text = "СТРОИТЕЛЬНАЯ ТОЧКА"
	title.add_theme_color_override("font_color",Color("edb96d"))
	title.add_theme_font_size_override("font_size",13)
	box.add_child(title)
	choice = Button.new()
	choice.name = "DefenseTowerChoice"
	choice.custom_minimum_size = Vector2(300,42)
	choice.focus_mode = Control.FOCUS_NONE
	choice.pressed.connect(begin_orientation)
	box.add_child(choice)
	cost_label = Label.new()
	cost_label.add_theme_font_size_override("font_size",12)
	box.add_child(cost_label)
	menu.hide()
	ghost_material = Geo.material(Color(0.3,0.9,0.8,0.42),0.0,0.3)
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sector_material = Geo.material(Color(0.25,0.9,0.76,0.14))
	sector_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sector_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sector_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	sector_material.no_depth_test = true
	outline_material = Geo.material(Color("78eed3"),0.0,0.7)
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	outline_material.no_depth_test = true
	sector = MeshInstance3D.new()
	sector.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	Geo.mark_ui(sector)
	add_child(sector)
	sector.hide()

func _context_valid() -> bool:
	return arena.hand.enabled and arena.crew.crewed and not arena.tank.dead and not arena.tuning_open and arena.interface_visible and not arena.tank.dash.active and not arena.tank.dash.is_aiming() and not is_instance_valid(arena.hand.held)

func reachable(site: Node3D) -> bool:
	if not is_instance_valid(site): return false
	if arena.hand._flat_distance(arena.tank.global_position,site.global_position)>arena.hand.REACH: return false
	var excluded: Array[RID] = []
	if is_instance_valid(site.tower): excluded.append(site.tower.get_rid())
	var query := PhysicsRayQueryParameters3D.create(arena.tank.global_position+Vector3.UP*5.8,site.global_position+Vector3.UP*0.4,1,excluded)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _pointer() -> Vector2:
	return arena.hand.test_pointer if arena.hand.test_pointer.is_finite() else get_viewport().get_mouse_position()

func pick_site(pointer: Vector2) -> Node3D:
	var origin: Vector3 = arena.aim_camera.project_ray_origin(pointer)
	var direction: Vector3 = arena.aim_camera.project_ray_normal(pointer)
	var query := PhysicsRayQueryParameters3D.create(origin,origin+direction*250,2048|1|8|32)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.collider.get_meta("defense_site") if hit and hit.collider.has_meta("defense_site") else null

func pointer_over_ui() -> bool:
	return menu.is_visible_in_tree() and menu.get_global_rect().has_point(_pointer())

func handle_input(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE and mode!=Mode.IDLE:
			cancel()
			return true
		if event.physical_keycode in [KEY_F,KEY_E,KEY_TAB,KEY_SPACE,KEY_R,KEY_G,KEY_EQUAL,KEY_F2]: cancel()
	if not event is InputEventMouseButton or arena.camera_rotating: return false
	if not _context_valid():
		cancel()
		return false
	if event.button_index == MOUSE_BUTTON_RIGHT and mode!=Mode.IDLE:
		if event.pressed: cancel()
		return true
	if event.button_index != MOUSE_BUTTON_LEFT: return false
	if mode==Mode.MENU:
		if pointer_over_ui(): return false # Let Control deliver the button press.
		if event.pressed: cancel()
		return true
	if mode==Mode.AIM:
		if event.pressed:
			update_direction(event.position)
			confirm()
		return true
	if not event.pressed or not arena.crew.input_armed: return false
	var site := pick_site(event.position)
	if site:
		if reachable(site): open_menu(site,event.position)
		else: arena.crew.tell("Подойди башней ближе к строительной точке")
		return true
	return false

func open_menu(site: Node3D, pointer: Vector2) -> void:
	if not _context_valid() or not reachable(site): return
	cancel()
	arena.hand.cancel_drag()
	selected = site
	reorienting = is_instance_valid(site.tower)
	mode = Mode.MENU
	choice.text = "Изменить направление" if reorienting else "Защитная башня · %d кристаллов"%site.crystal_cost
	_update_cost()
	menu.reset_size()
	menu.show()
	var bounds := get_viewport().get_visible_rect().size
	menu.position = (pointer+Vector2(16,12)).clamp(Vector2(8,8),bounds-menu.size-Vector2(8,8))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _update_cost() -> void:
	var available: int = arena.crew.loot.crystals
	choice.disabled = not reorienting and available<selected.crystal_cost
	cost_label.text = "Направление меняется бесплатно" if reorienting else "В башне: %d · %s"%[available,"далее — направление огня" if available>=selected.crystal_cost else "сдай кристаллы из шахты"]
	cost_label.add_theme_color_override("font_color",Color("b3d6cb") if not choice.disabled else Color("ee9676"))

func begin_orientation() -> void:
	if mode!=Mode.MENU or not _context_valid() or not reachable(selected): return
	if not reorienting and arena.crew.loot.crystals<selected.crystal_cost: return
	menu.hide()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	mode = Mode.AIM
	heading = selected.tower.global_rotation.y if reorienting else selected.global_rotation.y
	ghost = selected.tower_scene.instantiate()
	ghost.preview = true
	add_child(ghost)
	ghost.global_position = selected.global_position
	ghost.global_rotation.y = heading
	for mesh in ghost.find_children("*","MeshInstance3D",true,false):
		mesh.material_override = ghost_material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	Geo.mark_ui(ghost)
	sector.show()
	direction_valid = false
	sector_wait = 0
	arena.crew.tell("Мышью выбери сектор огня · ЛКМ — построить · ПКМ / Esc — отмена" if not reorienting else "Выбери новое направление · ЛКМ — применить · ПКМ / Esc — отмена")

func update_direction(pointer: Vector2) -> void:
	if mode!=Mode.AIM: return
	var origin: Vector3 = arena.aim_camera.project_ray_origin(pointer)
	var direction: Vector3 = arena.aim_camera.project_ray_normal(pointer)
	var point = arena.terrain_point(origin,direction)
	if point == null:
		direction_valid = false
		return
	var delta: Vector3 = point-selected.global_position
	delta.y = 0
	direction_valid = delta.length_squared()>1.0
	if direction_valid:
		heading = atan2(-delta.x,-delta.z)
		ghost.global_rotation.y = heading

func confirm() -> bool:
	if mode!=Mode.AIM or not direction_valid or not _context_valid() or not reachable(selected): return false
	if reorienting:
		if not is_instance_valid(selected.tower): cancel(); return false
		selected.tower.change_heading(heading)
	else:
		if is_instance_valid(selected.tower): cancel(); return false
		if arena.crew.loot.crystals<selected.crystal_cost:
			arena.crew.tell("Не хватает кристаллов · принеси и сдай ресурс в башню")
			cancel()
			return false
		# The final click is the single transaction boundary; previews cost nothing.
		selected.construct(heading)
		arena.crew.loot.crystals -= selected.crystal_cost
		arena.fx.dust(selected.global_position,Vector3.LEFT*2)
		arena.fx.dust(selected.global_position,Vector3.RIGHT*2)
	arena.sound.play("lock",-3.0,0.65)
	arena.crew.tell("Направление изменено" if reorienting else "Защитная башня построена · автоматически стреляет в выбранном секторе")
	cancel()
	return true

func cancel() -> void:
	mode = Mode.IDLE
	selected = null
	direction_valid = false
	if menu: menu.hide()
	if is_instance_valid(ghost): ghost.queue_free()
	ghost = null
	if sector: sector.hide()
	if arena and not arena.camera_rotating:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if arena.tuning_open else Input.MOUSE_MODE_HIDDEN

func reset() -> void:
	cancel()
	for site in sites: site.reset()

func tick(dt: float) -> void:
	for site in sites:
		if is_instance_valid(site.tower): site.tower.tick(dt)
	if not _context_valid():
		if mode!=Mode.IDLE: cancel()
		hovered = null
		return
	if mode!=Mode.IDLE and not reachable(selected): cancel()
	if mode==Mode.MENU: _update_cost()
	if arena.camera_rotating: return
	if mode==Mode.AIM:
		update_direction(_pointer())
		sector_wait -= dt
		if sector_wait<=0:
			sector_wait = 0.05
			_draw_sector()
	else: hovered = pick_site(_pointer())

func status_text() -> String:
	if mode==Mode.AIM: return "НАПРАВЛЕНИЕ ОГНЯ · ЛКМ — ПОДТВЕРДИТЬ · ПКМ / ESC — ОТМЕНА"
	if mode==Mode.MENU: return "ВЫБЕРИ ПОСТРОЙКУ"
	if is_instance_valid(hovered):
		if not reachable(hovered): return "СТРОИТЕЛЬНАЯ ТОЧКА · ПОДОЙДИ БЛИЖЕ"
		return "ЛКМ · НАПРАВЛЕНИЕ ЗАЩИТНОЙ БАШНИ" if is_instance_valid(hovered.tower) else "ЛКМ · ПОСТРОИТЬ ЗАЩИТНУЮ БАШНЮ · %d КРИСТАЛЛОВ"%hovered.crystal_cost
	return ""

func _draw_sector() -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES,sector_material)
	var origin: Vector3 = selected.global_position
	var half: float = deg_to_rad(selected.sector_degrees*0.5)
	# A faint overlay is projected to local ground height. No physical geometry.
	for i in 40:
		var a: Vector3 = origin+Vector3.FORWARD.rotated(Vector3.UP,heading-half+2*half*i/40.0)*selected.firing_range
		var b: Vector3 = origin+Vector3.FORWARD.rotated(Vector3.UP,heading-half+2*half*(i+1)/40.0)*selected.firing_range
		a.y = arena.ground_height(a)+0.09
		b.y = arena.ground_height(b)+0.09
		for p in [origin+Vector3.UP*0.09,a,b]: mesh.surface_add_vertex(p)
	mesh.surface_end()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES,outline_material)
	var start: Vector3 = origin+Vector3.FORWARD.rotated(Vector3.UP,heading-half)*selected.firing_range
	var finish: Vector3 = origin+Vector3.FORWARD.rotated(Vector3.UP,heading+half)*selected.firing_range
	_outline(mesh,origin,start)
	_outline(mesh,origin,finish)
	for i in 40:
		var a: Vector3 = origin+Vector3.FORWARD.rotated(Vector3.UP,heading-half+2*half*i/40.0)*selected.firing_range
		var b: Vector3 = origin+Vector3.FORWARD.rotated(Vector3.UP,heading-half+2*half*(i+1)/40.0)*selected.firing_range
		_outline(mesh,a,b)
	var forward := Vector3.FORWARD.rotated(Vector3.UP,heading)
	var side := forward.cross(Vector3.UP)
	var tip := origin+forward*7
	_outline(mesh,origin+forward*2,tip,0.14)
	_outline(mesh,tip,tip-forward*1.6+side*1.1,0.14)
	_outline(mesh,tip,tip-forward*1.6-side*1.1,0.14)
	mesh.surface_end()
	sector.mesh = mesh

func _outline(mesh: ImmediateMesh, a: Vector3, b: Vector3, width: float = 0.08) -> void:
	a.y = arena.ground_height(a)+0.13
	b.y = arena.ground_height(b)+0.13
	var side := (b-a).cross(Vector3.UP).normalized()*width*0.5
	for p in [a-side,a+side,b+side,a-side,b+side,b-side]: mesh.surface_add_vertex(p)
