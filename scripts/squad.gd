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
## Заряженная AOE-атака отряда: накопилось ещё единиц / достигнут max / списано.
## Маркер над отрядом подписан и обновляет визуал (прогресс bar / пульсация).
signal charge_changed(value: float, max_value: float)
## Шкала впервые в этом цикле достигла max — маркер триггерит «готов»-анимацию
## один раз (а не в каждом on_change).
signal charge_ready

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
## Тип направленной работы рабочих (по area-клику ЛКМ на цель). NONE = просто стоять
## в точке. GATHER — рубить деревья у work_point и носить на склад. BUILD — строить
## work_target (блюпринт), беря ресурс со склада. STRIKE — разбить/переключить
## work_target (горшок/рычаг). Ремонт башни идёт отдельно (repair_intent, см. ниже).
enum WorkKind { NONE, GATHER, BUILD, STRIKE }
var work_kind: int = WorkKind.NONE
## Точка work-приказа (центр области сбора / куда идти).
var work_point: Vector3 = Vector3.ZERO
## Конкретная цель для BUILD/STRIKE (блюпринт/горшок/рычаг). Может стать freed —
## читать через is_instance_valid.
var work_target: Node3D = null
## Намерение «чинить башню» (рабочие): при ESCORTING_TOWER юнит выходит и ЧИНИТ
## повреждённую башню (strike), а не прячется; башня цела → прячется (см.
## SoldierGnome). Ставит кнопка «Ремонт башни» (command_escort(true)); любая
## другая команда сбрасывает.
var repair_intent: bool = false
## Намерение «спрятаться внутрь башни» (неуязвимы). Для рабочих эскорт = прятка
## всегда; для КОПЕЙЩИКОВ это отдельная команда «В башню» (а «За башней» — боевой
## эскорт рядом). Ставит command_escort(hide=true); другая команда сбрасывает.
var hide_in_tower: bool = false
## Точка удержания при HOLDING_POSITION. Игнорируется в ESCORTING_TOWER.
var hold_position: Vector3 = Vector3.ZERO
## Жёсткий приоритет последней `command_hold`. Пока true — каждый юнит,
## не дошедший до своего слота, игнорирует бой и марширует к точке.
## Дойдя — естественно начинает стрелять (per-soldier dist ≤ arrival),
## флаг squad'а при этом остаётся true (не мешает: дошедшие в нём не
## участвуют). На `command_escort` сбрасывается. Дизайнерское правило:
## «точное указание места — четкое указание, всё прерывает».
var _strict_move: bool = false

## Заряд squad-ability — копится от убийств членами отряда (SoldierGnome._strike_at
## зовёт add_charge на kill'е). При >= charge_max — маркер над отрядом пульсирует
## и ловит hand-slam → trigger_charge_ability. Семантика по типам:
##   - pikeman: круговая push-волна + лёгкий damage (отогнать натиск).
## Списывается полностью на trigger.
var _charge: float = 0.0
## Максимум шкалы. Назначается Camp.recruit_squad по типу (SoldierSystem.SOLDIER_CATALOG[type].charge_max).
## Дефолт 5 — если каталог не задал.
var charge_max: float = 5.0


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
	repair_intent = false
	hide_in_tower = false
	work_kind = WorkKind.NONE
	work_target = null
	state_changed.emit()


## Направленная работа рабочих по area-клику: kind (GATHER/BUILD/STRIKE), точка и
## (для BUILD/STRIKE) конкретная цель. Выводит из башни (HOLDING), не прячет/не чинит.
func command_work(kind: int, point: Vector3, target: Node3D = null) -> void:
	state = State.HOLDING_POSITION
	hold_position = point
	_strict_move = false
	repair_intent = false
	hide_in_tower = false
	work_kind = kind
	work_point = point
	work_target = target
	state_changed.emit()


## Команда: эскорт башни. Юниты идут за башней, стреляют по пути (бой
## приоритетнее перемещения — обычный attack-and-move). Для рабочих эскорт =
## спрятаться внутрь башни. repair=true (кнопка «Ремонт башни») — вместо прятки
## выйти и ЧИНИТЬ башню (пока повреждена), затем спрятаться. hide=true (кнопка
## «В башню») — спрятаться ВНУТРЬ (и копейщики тоже), а не вставать рядом.
func command_escort(repair: bool = false, hide: bool = false) -> void:
	state = State.ESCORTING_TOWER
	_strict_move = false
	repair_intent = repair
	hide_in_tower = hide
	work_kind = WorkKind.NONE
	work_target = null
	state_changed.emit()


## Команда: защищать лагерь. Юниты идут к кольцу defend_ring_radius вокруг
## anchor'а лагеря и стреляют. Дополнительный слой к штатным DefenderGnome'ам.
## На свёртке (anchor stale) SoldierGnome fallback'ом считает центром башню —
## юниты тогда жмутся к башне как мини-эскорт.
func command_defend() -> void:
	state = State.DEFENDING_CAMP
	_strict_move = false
	repair_intent = false
	hide_in_tower = false
	work_kind = WorkKind.NONE
	work_target = null
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


## Геометрический центр живых членов отряда. Используется маркером заряда
## (визуал над центром) и AOE-каста (точка взрыва). Если живых нет — Vector3.INF
## как сигнал caller'у что squad пуст (маркер сам себя освободит).
func compute_center() -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in members:
		if is_instance_valid(m):
			sum += m.global_position
			n += 1
	if n == 0:
		return Vector3.INF
	return sum / float(n)


## Прирастить заряд (1.0 = один kill членом отряда). Эмитит charge_changed,
## один раз charge_ready на переходе через max.
func add_charge(amount: float) -> void:
	if amount <= 0.0 or charge_max <= 0.0:
		return
	var was_ready: bool = _charge >= charge_max
	_charge = clampf(_charge + amount, 0.0, charge_max)
	charge_changed.emit(_charge, charge_max)
	if not was_ready and _charge >= charge_max:
		charge_ready.emit()


func get_charge() -> float:
	return _charge


func is_charge_ready() -> bool:
	return _charge >= charge_max


## Списать всю шкалу — вызывается маркером после успешного триггера AOE.
func consume_charge() -> void:
	if _charge <= 0.0:
		return
	_charge = 0.0
	charge_changed.emit(_charge, charge_max)
