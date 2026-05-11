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
##   - `DEFENDING_CAMP` — кольцо вокруг развёрнутого лагеря, доп. слой обороны
##     поверх штатных DefenderGnome'ов. Радиус кольца больше (defend ring),
##     чтобы не стоять прямо на палатках. На свёртке — fallback на эскорт.

signal members_changed
signal state_changed
## Эмитится один раз при потере последнего члена. Camp слушает чтобы убрать
## squad из _squads и эмитнуть squad_disbanded.
signal disbanded

enum State { HOLDING_POSITION, ESCORTING_TOWER, DEFENDING_CAMP }

## Базовый радиус компактного кольца для HOLD/ESCORT — формация «отряд кучкой».
## DEFENDING_CAMP не использует кольцо: SoldierGnome ведёт wander-патруль
## по периметру лагеря (см. `SoldierGnome._tick_defend_patrol`).
## На малых отрядах (≤5) — используется как есть. На больших — `target_for_member`
## раздвигает кольцо до тех пор, пока каждому юниту достаётся ≥ `HOLD_RING_MIN_ARC`
## метров дуги (иначе капсулы налезают и юниты толкаются на тике).
const HOLD_RING_RADIUS: float = 1.6
## Минимум длины дуги на одного юнита (метров). При squad_size=5 и базовом
## радиусе 1.6м на каждого приходится ~2м — комфортно. На 10+ юнитах радиус
## нужно увеличить, иначе кольцо тесное. Дуга 1.3м чуть больше диаметра
## капсулы гнома (~0.56м × 2 + зазор).
const HOLD_RING_MIN_ARC: float = 1.3

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
## Жёсткий приоритет последней `command_hold`. Пока true — каждый юнит,
## не дошедший до своего слота, игнорирует бой и марширует к точке.
## Дойдя — естественно начинает стрелять (per-soldier dist ≤ arrival),
## флаг squad'а при этом остаётся true (не мешает: дошедшие в нём не
## участвуют). На `command_escort` сбрасывается. Дизайнерское правило:
## «точное указание места — четкое указание, всё прерывает».
var _strict_move: bool = false


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


## Команда: занять точку.
##   - `strict=true` (дефолт, для «Идти сюда»): юниты маршируют, игнорируя
##     бой по пути. Дойдя — обычный attack-and-stand.
##   - `strict=false` (для Q-стопа отряда): мягкий HOLD — юниты фиксируют
##     позицию вокруг точки, но при враге в leash сразу charge'ятся.
func command_hold(pos: Vector3, strict: bool = true) -> void:
	state = State.HOLDING_POSITION
	hold_position = pos
	_strict_move = strict
	state_changed.emit()


## Команда: эскорт башни. Юниты идут за башней, стреляют по пути (бой
## приоритетнее перемещения — обычный attack-and-move).
func command_escort() -> void:
	state = State.ESCORTING_TOWER
	_strict_move = false
	state_changed.emit()


## Команда: защищать лагерь. Юниты идут к кольцу defend_ring_radius вокруг
## anchor'а лагеря и стреляют. Дополнительный слой к штатным DefenderGnome'ам.
## На свёртке (anchor stale) SoldierGnome fallback'ом считает центром башню —
## юниты тогда жмутся к башне как мини-эскорт.
func command_defend() -> void:
	state = State.DEFENDING_CAMP
	_strict_move = false
	state_changed.emit()


## True если последняя команда была HOLD и точка считается «точным указанием»
## — юниты должны сначала дойти, потом включаться в бой.
func is_strict_move() -> bool:
	return _strict_move


## Удалить члена БЕЗ trigger'а его смерти. Аналог `_on_member_destroyed`,
## но публичный — нужен на dismiss-конверсии (Camp queue_free'ит солдата
## без `_die`, destroyed-сигнал не фронтит, и автоматическая чистка не
## срабатывает). Эмитит members_changed; на пустом списке — disbanded.
func remove_member(soldier: SoldierGnome) -> void:
	if not (soldier in members):
		return
	members.erase(soldier)
	members_changed.emit()
	if members.is_empty():
		disbanded.emit()


## Целевая точка для конкретного юнита в HOLD/ESCORT-режимах: кольцо вокруг
## резолвнутого center'а. Радиус адаптивный — `HOLD_RING_RADIUS` как floor,
## выше — когда на каждого юнита приходится меньше `HOLD_RING_MIN_ARC` метров
## дуги. На squad_size=5 формула возвращает базовый радиус 1.6м, на 10+
## раздвигает кольцо чтобы юниты не налезали.
##
## DEFENDING_CAMP сюда не приходит — там SoldierGnome сам ведёт wander-патруль
## по периметру через `_tick_defend_patrol` (центр выбирается динамически,
## без фиксированных слотов).
func target_for_member(soldier: SoldierGnome, center: Vector3) -> Vector3:
	var idx: int = members.find(soldier)
	if idx < 0:
		idx = 0
	var n: int = maxi(members.size(), 1)
	var radius: float = maxf(HOLD_RING_RADIUS, HOLD_RING_MIN_ARC * float(n) / TAU)
	var angle: float = TAU * float(idx) / float(n)
	return center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
