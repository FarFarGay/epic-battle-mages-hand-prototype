extends Control
var level
var origin := Vector2.ZERO
var factor := 1.0
var font: Font

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	hide()

func p(world: Vector2) -> Vector2:
	return origin + (world-level.WORLD_BOUNDS.position)*factor

func caption(at: Vector2, text: String, color: Color = Color("ece7dc"), size: int = 15) -> void:
	draw_string(font,at,text,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)

func _draw() -> void:
	if not level: return
	var view := get_viewport_rect().size
	var bounds: Rect2 = level.WORLD_BOUNDS
	factor = minf((view.x-120)/bounds.size.x,(view.y-230)/bounds.size.y)
	origin = Vector2((view.x-bounds.size.x*factor)*0.5,(view.y-bounds.size.y*factor)*0.5+10)
	draw_rect(Rect2(Vector2.ZERO,view),Color(0.055,0.07,0.08,0.97))
	caption(Vector2(60,55),"КАНЬОН · КАРТА БЛОКАУТА",Color("edc589"),27)
	caption(Vector2(60,82),"%d × 176 м · входной коридор %d × 20 м · G — закрыть карту · F2 — старый полигон" % [int(bounds.size.x),int(level.ENTRY_LENGTH)],Color("acb9b9"),16)
	var polygon := PackedVector2Array()
	for point in level.OUTLINE: polygon.append(p(point))
	draw_colored_polygon(polygon,Color("857e6c"))
	polygon.append(polygon[0])
	draw_polyline(polygon,Color("c5b597"),2)
	draw_rect(Rect2(p(level.ENTRY_RECT.position),level.ENTRY_RECT.size*factor),Color("b09f7c"))
	draw_rect(Rect2(p(Vector2(128,-10)),Vector2(36,20)*factor),Color("b09f7c"))
	draw_rect(Rect2(p(Vector2(-138,-10)),Vector2(10,20)*factor),Color("333e49"))
	if level.deep_mine:
		var mouth: Vector3 = level.deep_mine.get_node("Markers/Entrance").global_position
		var end: Vector3 = level.deep_mine.get_node("Markers/DeepChamber").global_position
		draw_rect(Rect2(p(Vector2(mouth.x-5,mouth.z-20)),Vector2(end.x-mouth.x+15,60)*factor),Color("424d50"))
		draw_line(p(Vector2(mouth.x,mouth.z)),p(Vector2(end.x,end.z)),Color("b39866"),4.0)
		caption(p(Vector2(mouth.x+15,mouth.z-22)),"ГЛУБОКАЯ ШАХТА",Color("e0c28c"),13)
	if level.arena.hand.puzzle.opened: draw_rect(Rect2(p(Vector2(-138,-3)),Vector2(10,6)*factor),Color("74cbc0"))
	for spec in [[Vector2(-79,-21),Vector2(15,17)],[Vector2(-34,4),Vector2(35,11)],[Vector2(41,-43),Vector2(17,17)]]:
		draw_rect(Rect2(p(spec[0]-spec[1]*0.5),spec[1]*factor),Color("444d53"))
	for entry in [[level.A,32.0,"Б · МЕХАНИК",Color("ad92bd")],[level.B,32.0,"В · ДАНЖ",Color("7faab8")],[level.C,56.0,"1 · ДЕРЕВНЯ",Color("c9a367")]]:
		var pos := Vector2(entry[0].x,entry[0].z)
		var radius: float = entry[1]*factor*0.5
		draw_circle(p(pos),radius,entry[3])
		caption(p(pos)+Vector2(-radius*0.7,4),entry[2],Color("18282e"),15)
	for enemy in level.arena.battle.enemies:
		if enemy.world_resident and not enemy.dead:
			draw_circle(p(Vector2(enemy.position.x,enemy.position.z)),2.0,Color("e29b72") if enemy.shield_guard else Color("ce5e52"))
	if level.roaming_groups:
		for route_id in 2:
			var route: Array = level.roaming_groups.SHORT_ROUTE if route_id == 0 else level.roaming_groups.LONG_ROUTE
			var line := PackedVector2Array()
			for point in route: line.append(p(Vector2(point.x,point.z)))
			draw_polyline(line,Color("d99d61") if route_id == 0 else Color("71c7bd"),3.0,true)
		for group in level.roaming_groups.groups:
			var alive: Array = group.members.filter(func(e): return is_instance_valid(e) and not e.dead)
			if alive.is_empty(): continue
			var at := p(Vector2(group.center.x,group.center.z))
			draw_arc(at,12*factor,0,TAU,32,Color("eb795e"),1.5)
			caption(at+Vector2(-30,-14),"%d · ГРОМИЛЫ %d"%[alive.size(),alive.filter(func(e):return e.giant).size()],Color("ffe0c4"),12)
		caption(Vector2(60,110),"ЗОЛОТОЙ: КОРОТКИЙ ПУТЬ ЧЕРЕЗ ПАТРУЛИ    БИРЮЗОВЫЙ: ДЛИННЫЙ ОБХОД",Color("d6d7c9"),14)
	var loot_positions := [Vector2(0,44),Vector2(-8,-76),Vector2(-42,73)]
	for i in loot_positions.size():
		var pos: Vector2 = loot_positions[i]
		draw_circle(p(pos),3.0*factor,Color("f7d681"))
		caption(p(pos)+Vector2(14,-9),"Л%d"%(i+1),Color("f7d681"),13)
	var player: Vector3 = level.arena.crew.center()
	var dot := p(Vector2(player.x,player.z))
	draw_circle(dot,8,Color("72eee0"))
	draw_arc(dot,12,0,TAU,30,Color.WHITE,2)
	caption(dot+Vector2(15,-9),"ВЫ ЗДЕСЬ",Color.WHITE,13)
	caption(p(Vector2(level.ENTRY_WEST+1,-13)),"ВХОД · %d М · %d СКЕЛЕТОВ" % [int(level.ENTRY_LENGTH),level.ENTRY_ATTACK_SIZE],Color.WHITE,14)
	caption(p(Vector2(129,-13)),"ВЫХОД",Color.WHITE,14)
	caption(Vector2(60,view.y-63),level.defense_waves.status_text(),Color("e0c28c"),15)
	caption(Vector2(60,view.y-38),"1: деревня и шахта.  Б: груз → кнопка рукой → механик.  В: задание на посещение.  Г: будущий босс.",Color("d0d7d3"),15)
	caption(p(Vector2(0,0)),"Г · БОСС (ПОЗЖЕ)",Color("d0d7d3"),13)
