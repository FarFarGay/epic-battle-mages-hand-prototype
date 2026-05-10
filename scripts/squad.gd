class_name Squad
extends RefCounted
## Отряд солдат — RTS-сущность с двумя режимами поведения. RefCounted: пока
## хотя бы один SoldierGnome держит ссылку (через `_squad`) или Camp хранит
## в `_squads`, объект жив. Когда все members'ы умерли и Camp снял ссылку
## — squad автоматически освобождается.
##
## Не Node — у squad'а нет своего узла в сцене. Это чистая логическая сущность:
## state + target_pos + список членов. Юниты сами читают эти поля в _active_tick.
##
## **States:**
##   - `HOLDING_POSITION(pos)` — стоят (или идут к pos если далеко). Стреляют
##     в видимых врагов. По дефолту после призыва — на позиции спавна.
##   - `ESCORTING_TOWER` — следуют за башней с боковым offset'ом, стреляют
##     по пути. Когда башня едет — двигаются с ней; когда стоит — стоят рядом.

signal members_changed
signal state_changed
## Эмитится один раз при потере последнего члена. Camp слушает чтобы убрать
## squad из _squads и эмитнуть squad_disbanded.
signal disbanded

enum State { HOLDING_POSITION, ESCORTING_TOWER }

## Уникальный ID — counter в Camp при создании. Используется UI'ем для
## идентификации (карточка → конкретный squad).
var id: int = 0
var soldier_type: StringName = &""
## Цвет иконки из SOLDIER_CATALOG[type].icon_color — кэш для UI'я.
var icon_color: Color = Color.WHITE
var members: Array[SoldierGnome] = []
var state: int = State.HOLDING_POSITION
## Точка удержания при HOLDING_POSITION. Игнорируется в ESCORTING_TOWER.
var hold_position: Vector3 = Vector3.ZERO


func _to_string() -> String:
	return "Squad#%d[%s × %d, state=%s]" % [id, soldier_type, count_alive(), State.keys()[state]]


## Добавить юнита в отряд. Двусторонняя ссылка: squad.members.append + soldier._squad = self.
func add_member(soldier: SoldierGnome) -> void:
	if soldier in members:
		return
	members.append(soldier)
	soldier.set_squad(self)
	# Подписка на смерть юнита — Camp слушает destroyed-сигнал гнома, но
	# squad самообслуживает _on_member_destroyed для чистки members'а.
	if not soldier.destroyed.is_connected(_on_member_destroyed.bind(soldier)):
		soldier.destroyed.connect(_on_member_destroyed.bind(soldier), CONNECT_ONE_SHOT)
	members_changed.emit()


func _on_member_destroyed(soldier: SoldierGnome) -> void:
	members.erase(soldier)
	members_changed.emit()
	if members.is_empty():
		disbanded.emit()


## Количество живых членов. Используется UI'ем (счётчик «3 / 5»).
func count_alive() -> int:
	var n: int = 0
	for m in members:
		if is_instance_valid(m):
			n += 1
	return n


## Команда: занять точку. Юниты идут туда и стоят, стреляя в видимых врагов.
func command_hold(pos: Vector3) -> void:
	state = State.HOLDING_POSITION
	hold_position = pos
	state_changed.emit()


## Команда: эскорт башни. Юниты идут за башней, стреляют по пути.
func command_escort() -> void:
	state = State.ESCORTING_TOWER
	state_changed.emit()


## Целевая точка для конкретного юнита в текущем state'е. Squad-controlled
## движение: каждый soldier в _active_tick спрашивает «куда мне идти?», потом
## двигается + стреляет.
##
## Distribution внутри отряда — простое: каждый юнит индексирован в `members`,
## смещение в кольце вокруг центра по этому индексу. Так толпа не сваливается
## в одну точку, а равномерно распределяется.
func target_for_member(soldier: SoldierGnome, tower_pos: Vector3) -> Vector3:
	var center: Vector3 = hold_position if state == State.HOLDING_POSITION else tower_pos
	# Простейший offset по индексу — кольцо вокруг center. На малом
	# squad_size=5 углы 72°.
	var idx: int = members.find(soldier)
	if idx < 0:
		idx = 0
	var n: int = maxi(members.size(), 1)
	var angle: float = TAU * float(idx) / float(n)
	var ring_radius: float = 1.6  # компактное кольцо ~1.6м
	return center + Vector3(cos(angle) * ring_radius, 0.0, sin(angle) * ring_radius)
