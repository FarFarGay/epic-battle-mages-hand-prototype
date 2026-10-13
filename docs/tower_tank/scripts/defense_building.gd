extends Node3D
const Site = preload("res://scripts/defense_site.gd")
const Geo = preload("res://scripts/geo.gd")
const Placement = preload("res://scripts/defense_placement.gd")

enum Mode { IDLE, MENU, PLACE, AIM }
var arena
var sites: Array[Node3D] = []
var mode := Mode.IDLE
var selected: Node3D
var hovered: Node3D
var workshop: Node3D
var pyrotechnician: Node3D
var mechanic: Node3D
var active_shop: Node3D
var placement
var blueprint: PackedScene
var build_cost := 10
var gold_cost := 50
var menu: PanelContainer
var choice: Button
var cost_label: Label
var title: Label
var ghost: Node3D
var sector: MeshInstance3D
var heading := 0.0
var sector_wait := 0.0
var direction_valid := false
var placement_valid := false
var placement_reason := ""
var reorienting := false
var ghost_material: StandardMaterial3D
var sector_material: StandardMaterial3D
var outline_material: StandardMaterial3D

func _ready() -> void:
	name = "DefenseBuilding"
	workshop = arena.level.get_node("AtollC/Village/House01")
	pyrotechnician = arena.level.get_node("AtollC/Village/House03")
	mechanic = preload("res://scripts/mechanic_workshop.gd").new()
	mechanic.name = "MechanicWorkshop"
	arena.level.get_node("AtollC").add_child(mechanic)
	mechanic.global_position = arena.level.C+Vector3(6,0,-20)
	mechanic.rotation.y = -PI/2
	blueprint = workshop.defense_blueprint
	var recipe = blueprint.instantiate()
	build_cost = recipe.crystal_cost
	gold_cost = recipe.gold_cost
	recipe.free()
	placement = Placement.new()
	placement.arena = arena
	placement.atoll = arena.level.get_node("AtollC")
	placement.mesa = arena.level.get_node("AtollC/AtollMesa3")
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
	title = Label.new()
	title.add_theme_color_override("font_color",Color("edb96d"))
	title.add_theme_font_size_override("font_size",13)
	box.add_child(title)
	choice = Button.new()
	choice.name = "DefenseTowerChoice"
	choice.custom_minimum_size = Vector2(360,42)
	choice.focus_mode = Control.FOCUS_NONE
	choice.pressed.connect(_choose_product)
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
	return not arena.crew.members.is_empty() and not arena.tuning_open and arena.interface_visible and not arena.tank.dash.active and not arena.tank.dash.is_aiming() and not is_instance_valid(arena.hand.held)

func reachable(_site: Node3D) -> bool:
	return placement.on_atoll(arena.crew.center())

func _pointer() -> Vector2:
	return arena.hand.test_pointer if arena.hand.test_pointer.is_finite() else get_viewport().get_mouse_position()

func pick_site(pointer: Vector2) -> Node3D:
	var origin: Vector3 = arena.aim_camera.project_ray_origin(pointer)
	var direction: Vector3 = arena.aim_camera.project_ray_normal(pointer)
	var query := PhysicsRayQueryParameters3D.create(origin,origin+direction*250,2048|1|8|32)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return null
	if hit.collider.has_meta("mason_workshop"): return hit.collider.get_meta("mason_workshop")
	if hit.collider.has_meta("pyrotechnician"): return hit.collider.get_meta("pyrotechnician")
	if hit.collider.has_meta("mechanic_workshop"): return hit.collider.get_meta("mechanic_workshop")
	if hit.collider.has_meta("defense_site"): return hit.collider.get_meta("defense_site")
	return null

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
		if pointer_over_ui(): return false
		if event.pressed: cancel()
		return true
	if mode==Mode.PLACE:
		if event.pressed:
			update_placement(event.position)
			confirm_position()
		return true
	if mode==Mode.AIM:
		if event.pressed:
			update_direction(event.position)
			confirm()
		return true
	if not event.pressed or not arena.crew.input_armed: return false
	var target := pick_site(event.position)
	if target:
		if reachable(target): open_menu(target,event.position)
		else: arena.crew.tell("Строительство доступно с плато поселения")
		return true
	return false

func open_menu(target: Node3D, pointer: Vector2) -> void:
	if not _context_valid() or not reachable(target): return
	if target!=workshop and target!=pyrotechnician and target!=mechanic and (not target is Site or not is_instance_valid(target.tower)): return
	if target==mechanic and not mechanic.available: return
	cancel()
	arena.hand.cancel_drag()
	arena.tank.crossbows.cancel_trigger()
	reorienting = target is Site
	active_shop = workshop if reorienting else target
	selected = target if reorienting else null
	mode = Mode.MENU
	title.text = "НАПРАВЛЕНИЕ БАШНИ" if reorienting else "ДОМ КАМЕНЩИКА · ЗАЩИТНЫЕ СООРУЖЕНИЯ"
	choice.text = "Изменить направление" if reorienting else "Башня · %d золота + %d кристаллов"%[gold_cost,build_cost]
	if active_shop==pyrotechnician:
		title.text = "ЛАВКА ПИРОТЕХНИКА · ВЗРЫВНЫЕ БОЧКИ"
		choice.text = "Взрывная бочка · %d золота"%pyrotechnician.barrel_gold_cost
	if active_shop==mechanic:
		title.text = "МАСТЕРСКАЯ МЕХАНИКА · УЛУЧШЕНИЯ БАШНИ"
		choice.text = "Пушка · %d золота + %d кристаллов"%[mechanic.cannon_gold_cost,mechanic.cannon_crystal_cost]
	_update_cost()
	menu.reset_size()
	menu.show()
	var bounds := get_viewport().get_visible_rect().size
	menu.position = (pointer+Vector2(16,12)).clamp(Vector2(8,8),bounds-menu.size-Vector2(8,8))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _update_cost() -> void:
	var available: int = arena.crew.loot.crystals
	var gold: int = arena.crew.loot.coins
	if active_shop==mechanic:
		choice.disabled = not mechanic.available or arena.tank.cannon_installed or gold<mechanic.cannon_gold_cost or available<mechanic.cannon_crystal_cost
		cost_label.text = "Пушка уже установлена" if arena.tank.cannon_installed else "Золото: %d · кристаллы: %d\n%s"%[gold,available,"Установить пушку на башню" if not choice.disabled else "Не хватает золота или кристаллов"]
		cost_label.add_theme_color_override("font_color",Color("b3d6cb"))
		return
	if active_shop==pyrotechnician:
		var blocked: String = pyrotechnician.output_reason(arena)
		choice.disabled = gold<pyrotechnician.barrel_gold_cost or not blocked.is_empty()
		cost_label.text = "Золото: %d · кристаллы не нужны\n"%gold
		cost_label.text += blocked if not blocked.is_empty() else ("Бочка появится на площадке у лавки" if not choice.disabled else "Не хватает золота")
		cost_label.add_theme_color_override("font_color",Color("ee9676") if choice.disabled else Color("b3d6cb"))
		return
	choice.disabled = not reorienting and (available<build_cost or gold<gold_cost)
	cost_label.text = "Направление меняется бесплатно" if reorienting else "Золото: %d · кристаллы: %d\n%s"%[gold,available,"Выбери место на атолле" if not choice.disabled else "Не хватает золота или кристаллов"]
	if not reorienting and arena.level.defense_waves.completed==0 and arena.level.defense_waves.active<0 and arena.level.defense_waves.first_wave_left<0:
		cost_label.text += "\nПервая постройка вызовет волну через 5 секунд"
	cost_label.add_theme_color_override("font_color",Color("b3d6cb") if not choice.disabled else Color("ee9676"))

func _choose_product() -> void:
	if mode!=Mode.MENU or not _context_valid() or not reachable(active_shop): return
	if active_shop==mechanic:
		mechanic.purchase(arena)
		_update_cost()
	elif active_shop==pyrotechnician:
		pyrotechnician.purchase(arena)
		_update_cost()
	else: begin_orientation()

func create_site(point: Vector3, register: bool = true) -> Node3D:
	var site = blueprint.instantiate()
	site.arena = arena
	arena.level.get_node("AtollC/DefenseSites").add_child(site)
	site.global_position = point
	if register: sites.append(site)
	return site

func begin_orientation() -> void:
	if mode!=Mode.MENU or not _context_valid() or not reachable(workshop): return
	if active_shop==pyrotechnician or active_shop==mechanic: return
	if not reorienting and (arena.crew.loot.crystals<build_cost or arena.crew.loot.coins<gold_cost): return
	menu.hide()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	if not reorienting: selected = create_site(arena.level.C,false)
	mode = Mode.AIM if reorienting else Mode.PLACE
	heading = selected.tower.global_rotation.y if reorienting else 0.0
	ghost_material.albedo_color = Color(0.3,0.9,0.8,0.48)
	ghost = selected.tower_scene.instantiate()
	ghost.preview = true
	add_child(ghost)
	ghost.global_position = selected.global_position
	ghost.global_rotation.y = heading
	for mesh in ghost.find_children("*","MeshInstance3D",true,false):
		mesh.material_override = ghost_material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	Geo.mark_ui(ghost)
	sector.visible = reorienting
	direction_valid = false
	placement_valid = false
	sector_wait = 0
	if not reorienting: update_placement(_pointer())

func update_placement(pointer: Vector2) -> void:
	if mode!=Mode.PLACE: return
	var origin: Vector3 = arena.aim_camera.project_ray_origin(pointer)
	var direction: Vector3 = arena.aim_camera.project_ray_normal(pointer)
	var point = Plane(Vector3.UP,arena.level.C.y).intersects_ray(origin,direction)
	if point==null:
		placement_valid = false
		placement_reason = "Наведи курсор на плато"
		ghost.hide()
		return
	var local: Vector3 = placement.atoll.to_local(point)
	local.x = snappedf(local.x,0.5)
	local.z = snappedf(local.z,0.5)
	selected.global_position = placement.atoll.to_global(local)
	ghost.global_position = selected.global_position
	ghost.show()
	placement_reason = placement.reason(selected.global_position)
	placement_valid = placement_reason.is_empty()
	ghost_material.albedo_color = Color(0.3,0.9,0.8,0.48) if placement_valid else Color(1.0,0.22,0.16,0.55)

func confirm_position() -> bool:
	if mode!=Mode.PLACE or not placement_valid or not _context_valid() or not reachable(workshop): return false
	placement_reason = placement.reason(selected.global_position)
	placement_valid = placement_reason.is_empty()
	if not placement_valid: return false
	mode = Mode.AIM
	sector.show()
	direction_valid = false
	return true

func update_direction(pointer: Vector2) -> void:
	if mode!=Mode.AIM: return
	var origin: Vector3 = arena.aim_camera.project_ray_origin(pointer)
	var direction: Vector3 = arena.aim_camera.project_ray_normal(pointer)
	var point = Plane(Vector3.UP,selected.global_position.y).intersects_ray(origin,direction)
	if point==null:
		direction_valid = false
		return
	var delta: Vector3 = point-selected.global_position
	delta.y = 0
	direction_valid = delta.length_squared()>1.0
	if direction_valid:
		heading = atan2(-delta.x,-delta.z)
		ghost.global_rotation.y = heading

func confirm() -> bool:
	if mode!=Mode.AIM or not direction_valid or not _context_valid() or not reachable(workshop): return false
	if reorienting:
		if not is_instance_valid(selected.tower): cancel(); return false
		selected.tower.change_heading(heading)
	else:
		if arena.crew.loot.crystals<selected.crystal_cost or arena.crew.loot.coins<selected.gold_cost:
			arena.crew.tell("Не хватает золота или кристаллов")
			cancel()
			return false
		# Recheck moving actors and concurrent buildings at the transaction boundary.
		placement_reason = placement.reason(selected.global_position)
		if not placement_reason.is_empty():
			mode = Mode.PLACE
			sector.hide()
			update_placement(_pointer())
			return false
		sites.append(selected)
		selected.construct(heading)
		arena.crew.loot.crystals -= selected.crystal_cost
		arena.crew.loot.coins -= selected.gold_cost
		arena.fx.dust(selected.global_position,Vector3.LEFT*2)
		arena.fx.dust(selected.global_position,Vector3.RIGHT*2)
	arena.sound.play("lock",-3.0,0.65)
	arena.crew.tell("Направление изменено" if reorienting else "Защитная башня построена")
	cancel()
	return true

func cancel() -> void:
	if is_instance_valid(selected) and not sites.has(selected): selected.queue_free()
	mode = Mode.IDLE
	active_shop = null
	selected = null
	direction_valid = false
	placement_valid = false
	if menu: menu.hide()
	if is_instance_valid(ghost): ghost.queue_free()
	ghost = null
	if sector: sector.hide()
	if arena and not arena.camera_rotating:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if arena.tuning_open else Input.MOUSE_MODE_HIDDEN

func reset() -> void:
	cancel()
	for site in sites:
		site.reset()
		site.queue_free()
	sites.clear()
	hovered = null

func tick(dt: float) -> void:
	for site in sites:
		if is_instance_valid(site.tower): site.tower.tick(dt)
	if not _context_valid():
		if mode!=Mode.IDLE: cancel()
		hovered = null
		return
	if mode!=Mode.IDLE and not reachable(workshop): cancel()
	if mode==Mode.MENU: _update_cost()
	if arena.camera_rotating: return
	if mode==Mode.PLACE:
		update_placement(_pointer())
	elif mode==Mode.AIM:
		update_direction(_pointer())
		sector_wait -= dt
		if sector_wait<=0:
			sector_wait = 0.05
			_draw_sector()
	else: hovered = pick_site(_pointer())

func status_text() -> String:
	if mode==Mode.PLACE:
		return "ЛКМ · ВЫБРАТЬ МЕСТО · ПКМ / ESC — ОТМЕНА" if placement_valid else placement_reason
	if mode==Mode.AIM: return "НАПРАВЛЕНИЕ ОГНЯ · ЛКМ — ПОСТРОИТЬ · ПКМ / ESC — ОТМЕНА" if not reorienting else "НАПРАВЛЕНИЕ ОГНЯ · ЛКМ — ПРИМЕНИТЬ"
	if mode==Mode.MENU:
		if active_shop==mechanic: return "МАСТЕРСКАЯ МЕХАНИКА · УЛУЧШЕНИЯ БАШНИ"
		return "ЛАВКА ПИРОТЕХНИКА · КУПИТЬ БОЧКУ" if active_shop==pyrotechnician else "ДОМ КАМЕНЩИКА · ВЫБЕРИ ПОСТРОЙКУ"
	if is_instance_valid(hovered):
		if not reachable(hovered): return "СТРОИТЕЛЬСТВО ДОСТУПНО С ПЛАТО ПОСЕЛЕНИЯ"
		if hovered==pyrotechnician: return "ЛКМ · ЛАВКА ПИРОТЕХНИКА · ВЗРЫВНЫЕ БОЧКИ"
		if hovered==mechanic: return "ЛКМ · МАСТЕРСКАЯ МЕХАНИКА · УЛУЧШЕНИЯ БАШНИ"
		return "ЛКМ · ДОМ КАМЕНЩИКА · СТРОИТЕЛЬСТВО" if hovered==workshop else "ЛКМ · НАПРАВЛЕНИЕ ЗАЩИТНОЙ БАШНИ"
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
