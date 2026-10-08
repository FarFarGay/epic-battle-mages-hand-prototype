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
	if level.arena.hand.puzzle.opened: draw_rect(Rect2(p(Vector2(-138,-3)),Vector2(10,6)*factor),Color("74cbc0"))
	for spec in [[Vector2(-79,-21),Vector2(15,17)],[Vector2(-34,4),Vector2(35,11)],[Vector2(69,-43),Vector2(17,17)]]:
		draw_rect(Rect2(p(spec[0]-spec[1]*0.5),spec[1]*factor),Color("444d53"))
	for entry in [[level.A,32.0,"A · ПАЗЛ",Color("ad92bd")],[level.B,32.0,"B · ДАНЖ",Color("7faab8")],[level.C,56.0,"C · ШАХТА",Color("c9a367")]]:
		var pos := Vector2(entry[0].x,entry[0].z)
		var radius: float = entry[1]*factor*0.5
		draw_circle(p(pos),radius,entry[3])
		caption(p(pos)+Vector2(-radius*0.7,4),entry[2],Color("18282e"),15)
	for enemy in level.arena.battle.enemies:
		if enemy.world_resident and not enemy.dead:
			draw_circle(p(Vector2(enemy.position.x,enemy.position.z)),2.0,Color("e29b72") if enemy.shield_guard else Color("ce5e52"))
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
	caption(Vector2(60,view.y-63),"A: гномы → груз на платформе → рукоять рукой → верстак.   B: площадка и два кармана лута.",Color("d0d7d3"),15)
	caption(Vector2(60,view.y-38),"C: разбор породы / рабочие и защита трёх входов.   Красные точки — скелеты, жёлтое — лут.",Color("d0d7d3"),15)
