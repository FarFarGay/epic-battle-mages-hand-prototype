extends Node
## Only completed gameplay events advance the route; leaving never resets a timer.
const Geo = preload("res://scripts/geo.gd")
enum Phase { FIRST_DEFENSE, RESCUE_MECHANIC, RETURN_MECHANIC, PREPARE_SECOND, SECOND_DEFENSE, DUNGEON, RETURN_DUNGEON, PREPARE_FINAL, FINAL_DEFENSE, COMPLETE }
const PREPARATION_SECONDS := 60.0
var enabled := true
var arena
var level
var phase := Phase.FIRST_DEFENSE
var seconds_left := -1.0
var mechanic: Node3D

func setup(owner_level) -> void:
	level = owner_level
	arena = level.arena
	level.defense_waves.wave_started.connect(_wave_started)
	level.defense_waves.wave_completed.connect(_wave_completed)
	mechanic = Node3D.new()
	mechanic.name = "RescueMechanic"
	level.add_child(mechanic)
	mechanic.global_position = level.A+Vector3(7,.04,5)
	var coat := Geo.material(Color("517d88"))
	var beard := Geo.material(Color("d6bc91"))
	var boots := Geo.material(Color("443e39"))
	for x in [-.16,.16]: Geo.box(mechanic,Vector3(.25,.35,.4),Vector3(x,.175,0),boots)
	Geo.cylinder(mechanic,.36,.65,Vector3(0,.65,0),coat)
	Geo.sphere(mechanic,.27,Vector3(0,1.15,0),beard)
	Geo.box(mechanic,Vector3(.42,.35,.2),Vector3(0,.92,.22),beard)
	Geo.cylinder(mechanic,.3,.17,Vector3(0,1.37,0),coat)
	var sign := Label3D.new()
	sign.text = "МЕХАНИК"
	sign.position.y = 2.4
	sign.font_size = 48
	sign.pixel_size = .018
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mechanic.add_child(sign)
	reset()

func reset() -> void:
	phase = Phase.FIRST_DEFENSE
	seconds_left = -1.0
	mechanic.show()
	arena.defenses.mechanic.set_available(false)
	arena.tank.set_cannon_installed(false)

func puzzle_available() -> bool:
	return not enabled or phase>=Phase.RESCUE_MECHANIC

func _wave_started(number: int, _total: int) -> void:
	if not enabled: return
	if number==2: phase = Phase.SECOND_DEFENSE
	elif number==3: phase = Phase.FINAL_DEFENSE
	seconds_left = -1.0

func _wave_completed(number: int) -> void:
	if not enabled: return
	if number==1 and phase==Phase.FIRST_DEFENSE: phase = Phase.RESCUE_MECHANIC
	elif number==2 and phase==Phase.SECOND_DEFENSE: phase = Phase.DUNGEON
	elif number==3 and phase==Phase.FINAL_DEFENSE:
		phase = Phase.COMPLETE
		level.completed = true
	arena.crew.tell(status_text())

func tick(dt: float) -> void:
	if not enabled or arena.tuning_open or arena.battle.player_targets().is_empty(): return
	var center: Vector3 = arena.crew.center()
	match phase:
		Phase.RESCUE_MECHANIC:
			if arena.crew.crewed and level.gate_open and level.gate_lift>6.3 and center.distance_to(mechanic.global_position)<5.5:
				phase = Phase.RETURN_MECHANIC
				mechanic.hide()
				arena.crew.tell("Механик спасён и сел в башню · вернись в деревню на атолле 1")
		Phase.RETURN_MECHANIC, Phase.RETURN_DUNGEON:
			if not arena.crew.crewed or not arena.defenses.placement.on_atoll(center): return
			if phase==Phase.RETURN_MECHANIC:
				arena.defenses.mechanic.set_available(true)
				arena.battle.nav_dirty = true
				phase = Phase.PREPARE_SECOND
				arena.crew.tell("Мастерская построена · 60 секунд на добычу и пушку: 100 золота + 20 кристаллов")
			else:
				phase = Phase.PREPARE_FINAL
				arena.crew.tell("Задание выполнено · последняя волна через 60 секунд")
			seconds_left = PREPARATION_SECONDS
		Phase.PREPARE_SECOND, Phase.PREPARE_FINAL:
			seconds_left = maxf(0,seconds_left-dt)
			if seconds_left<=.000001:
				level.defense_waves.request_wave(1 if phase==Phase.PREPARE_SECOND else 2)
		Phase.DUNGEON:
			if Vector2(center.x-level.B.x,center.z-level.B.z).length()<12 and absf(center.y-level.B.y)<1.2:
				phase = Phase.RETURN_DUNGEON
				arena.crew.tell("Атолл В достигнут · задание засчитано · возвращайся в деревню")

func status_text() -> String:
	match phase:
		Phase.RESCUE_MECHANIC:
			if level.gate_open: return "Б · ПРОЙДИ БАШНЕЙ К МЕХАНИКУ ЗА ВОРОТАМИ · G — КАРТА"
			if level.unlocked: return "Б · ВЕРНИСЬ В БАШНЮ · F — РУКА · НАЖМИ КНОПКУ ВОРОТ"
			return "Б · СПАСИ МЕХАНИКА · ГНОМАМИ ПОСТАВЬ ГРУЗ НА ПЛАТФОРМУ"
		Phase.RETURN_MECHANIC: return "1 · ВЕРНИСЬ С МЕХАНИКОМ В ДЕРЕВНЮ · G — КАРТА"
		Phase.PREPARE_SECOND:
			return "ВОЛНА 2 ЧЕРЕЗ %d С · %s"%[ceili(seconds_left),"ГОТОВЬ ОБОРОНУ" if arena.tank.cannon_installed else "ПУШКА У МЕХАНИКА: 100 ЗОЛОТА + 20 КРИСТАЛЛОВ"]
		Phase.DUNGEON: return "В · ДОБЕРИСЬ ДО АТОЛЛА С ДАНЖЕМ · G — КАРТА"
		Phase.RETURN_DUNGEON: return "1 · ЗАДАНИЕ ВЫПОЛНЕНО · ВЕРНИСЬ В ДЕРЕВНЮ"
		Phase.PREPARE_FINAL: return "ПОСЛЕДНЯЯ ВОЛНА ЧЕРЕЗ %d С · ГОТОВЬ ОБОРОНУ"%ceili(seconds_left)
		Phase.COMPLETE: return "ТРИ ВОЛНЫ ОТБИТЫ · ДАЛЬШЕ БОССФАЙТ (В РАЗРАБОТКЕ)"
	return ""
