class_name QuestActor
extends Node3D
## Сюжетный «актор» — выдатчик задания на конкретной POI. **И сама POI-зона**:
## один и тот же узел совмещает визуал костра, выдачу квеста и параметры
## осады лагеря. Дизайнерская идея: точка интереса = костёр; лагерь ставится
## ровно на костёр; ресурсы вокруг костра спавнятся ResourceZone-ами как
## дочерние ноды этого QuestActor'а.
##
## Визуал — костёр (поленья + GPUParticles3D пламени и дыма + OmniLight3D).
## Состояние читается из QuestProgress по `quest_order`:
##   - locked    — потухший: тлеющие поленья, лёгкий дым, без пламени, без света;
##   - active    — горящий: яркое оранжевое пламя, активный дым, тёплый свет;
##   - completed — отгоревший: бело-голубое тление, минимум дыма, тусклый зелёный свет
##                 (символика «задание сделано», в отличие от обычного потухшего костра).
##
## **POI-зона:** регистрируется в группе [POI_GROUP] на _ready. Camp читает
## группу, чтобы разрешить deploy только в радиусе `safe_radius` от костра.
## WaveDirector читает группу + `wave_schedule` чтобы запустить осаду на
## конкретном POI когда лагерь развернулся.
##
## `actor_id` — уникальный ID для будущих скриптовых триггеров (диалог,
## выдача награды, ивенты в EventBus). Сейчас не используется кроме логов.
##
## Подписан на `EventBus.quest_advanced`, чтобы перекраситься без явных
## связей с другими акторами.

## Группа всех POI-зон на сцене. Camp ищет ближайшую через
## get_nodes_in_group(POI_GROUP) для deploy-gate'а. WaveDirector — для
## привязки осады к конкретному POI на camp_deployed.
const POI_GROUP := &"poi_zone"

@export var actor_id: StringName
@export var quest_order: int = 0

@export_group("Journal")
## Заголовок задания, видимый в Журнале (вкладка «Задания»). Если пусто —
## журнал покажет fallback "Задание #<order+1>". Отображается во всех трёх
## состояниях, но locked-карточка скрывает его за «???».
@export var quest_title: String = ""

## Описание задания: что делать, контекст, цели. Multi-line. Журнал рендерит
## с word-wrap'ом. В locked-состоянии скрыто. В completed — приглушено.
## Пока (фаза-прототипа) геймплейного триггера сдачи нет — только описание;
## продвижение через Журнал → Читы → «Продвинуть квест» или
## программный `QuestProgress.advance()`.
@export_multiline var quest_description: String = ""

@export_group("POI zone")
## Радиус, в котором лагерь может развернуться вокруг костра. Должен быть
## ≥ Camp.deploy_radius (8м), иначе палатки кольцом вылезут за пределы
## «зоны костра» и визуально POI будет выглядеть просто как точка в пустоте.
## Игрок жмёт R только в пределах этого круга — иначе deploy игнорируется.
## Также используется как "anchor": Camp на deploy ставит _deploy_anchor
## ровно в global_position костра (а не в текущую позицию башни) — палатки
## кольцом строятся симметрично вокруг костра, не уезжают на пол-метра.
@export var safe_radius: float = 12.0

## Радиус рассеивания тумана от костра. Используется FogOfWar (FOG_REVEAL_GROUP).
## Костёр виден издалека, vision вокруг него постоянно, даже без юнитов.
## С 2026-05-18 расширен 14→25м — POI-костёр заметный «маяк» на карте.
@export var fog_reveal_radius: float = 25.0

## Расписание осады. Если null — POI «мирный»: лагерь развернётся, но волны
## на него не идут. Если задан — WaveDirector проигрывает stages по порядку
## с момента camp_deployed. См. [WaveSchedule] для формата.
@export var wave_schedule: WaveSchedule
@export_group("")

@export_group("Resources")
## Сцена ResourceZone для авто-спавна 4 типов ресурсов вокруг POI. При null
## ресурсы не появляются — POI остаётся «голым» (можно для специфических
## квестов-арен без эконом-этапа).
@export var resource_zone_scene: PackedScene = preload("res://scenes/resource_zone.tscn")

## Сколько единиц каждого ресурсного типа должно быть вокруг POI. Делится на
## resource_units_per_pile и даёт count кучек на тип. Дизайнерский knob:
## «сколько раз гнома хватит ходить за дровами/камнем», не «сколько кучек на
## земле». 100 единиц = много, лагерь живёт долго; 30 — туже, быстрее
## деплет.
@export_range(0, 1000) var resource_total_per_type: int = 100

## Единиц на одну кучку (= сколько раз гном с неё возьмёт). При
## total_per_type=100 и per_pile=20 получаем 5 кучек на тип = 20 кучек
## всего вокруг POI — просторно, скелеты не упираются. Меньше — больше
## кучек, гном бегает чаще; больше — кучек меньше, гном дольше «жуёт»
## одну.
@export_range(1, 100) var resource_units_per_pile: int = 20

## Размер прямоугольника каждой ResourceZone (X×Z, м). Дефолт 50×50 — кучки
## раскидываются на ~25м в каждую сторону от костра; внутренний круг
## safe_radius (12м) отфильтруется в ResourceZone._pick_position, кучки
## лягут снаружи палаток. Большая зона = есть «коридоры» между кучками,
## скелет (агент ~0.5м) пройдёт сквозь карьер не упираясь в пень.
@export var resource_zone_size: Vector2 = Vector2(50.0, 50.0)

## Минимальная дистанция между соседними кучками ВНУТРИ одной ResourceZone.
## Передаётся каждой 4 зонам. ResourceZone использует rejection sampling
## (до 10 попыток), при невозможности — кладёт в случайное место. 2.5м
## оставляет ширину для пары скелетов плечом-к-плечу или одного гиганта.
@export var resource_min_spacing: float = 2.5
@export_group("")

@onready var _logs_root: Node3D = $Logs
@onready var _flame_core: MeshInstance3D = $FlameCore
@onready var _flame_particles: GPUParticles3D = $FlameParticles
@onready var _smoke_particles: GPUParticles3D = $SmokeParticles
@onready var _light: OmniLight3D = $Light

# Per-instance копия материала поленьев — иначе все QuestActor'ы на сцене
# делили бы один material_override и emission переключался бы у всех разом.
var _log_material: StandardMaterial3D
## Базовое количество частиц дыма (читается из .tscn в _ready). Все три
## состояния (locked/active/completed) меняют через amount_ratio — НЕ amount.
## Запись в GPUParticles3D.amount пересоздаёт буфер симуляции и вызывает
## визуальную «икоту»: дым на кадр пропадает и стартует заново. amount_ratio
## масштабирует уже существующий пул без перезапуска.
var _smoke_amount_max: int = 14
## True если лагерь сейчас развёрнут на этом POI (anchor в safe_radius).
## Драйвер «горения» костра — пока флаг true, _refresh_visual гонит active.
## Завязки на quest-state нет: костёр горит просто потому что у его костра
## стоит лагерь, независимо от того, открыт ли тут квест.
var _is_camp_deployed_here: bool = false


func _ready() -> void:
	# POI-зона: регистрация в группе для discovery'я Camp'ом и WaveDirector'ом.
	add_to_group(POI_GROUP)
	# Туман: костёр — постоянный источник рассеивания, fog_reveal_radius выше.
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	_clone_log_material()
	# Зафиксируем максимум амоунта (active-состояние). Все переключения —
	# через amount_ratio, см. _smoke_amount_max в комменте выше.
	if _smoke_particles != null:
		_smoke_amount_max = maxi(_smoke_particles.amount, 1)
	EventBus.quest_advanced.connect(_on_quest_advanced)
	EventBus.camp_deployed.connect(_on_camp_deployed)
	EventBus.camp_packed.connect(_on_camp_packed)
	_refresh_visual()
	_spawn_resource_zones()


## Спавнит 4 ResourceZone (Wood/Stone/Iron/Food) как детей POI'я. Каждая
## разбрасывает ~total_per_type / units_per_pile кучек в прямоугольнике
## resource_zone_size вокруг POI. Внутренний safe_radius (палатки) отсечётся
## фильтром ResourceZone._pick_position — игроку видны кольца кучек снаружи
## костра, никакие пни не торчат в очаге.
##
## Архитектура: ResourceZone сама в deferred-frame инстанцирует pile'ы и
## кладёт их в current_scene (через spawn_root_path null → fallback). Это
## значит pile'ы НЕ дети POI'я (переживают reload вместе со сценой, но не
## с POI). Само Zone-нода прозрачна (Mesh.visible = false на _ready) — у нас
## остаётся только логический spawner, можно держать как ребёнка POI без
## визуальных артефактов.
func _spawn_resource_zones() -> void:
	if resource_zone_scene == null or resource_total_per_type <= 0:
		return
	var per_pile: int = maxi(resource_units_per_pile, 1)
	var count: int = maxi(roundi(float(resource_total_per_type) / float(per_pile)), 1)
	# 1=Wood, 2=Stone, 3=Iron, 4=Food (см. ResourceZone.resource_type enum).
	for type_id in [1, 2, 3, 4]:
		var zone := resource_zone_scene.instantiate() as ResourceZone
		if zone == null:
			push_warning("[QuestActor] resource_zone_scene не инстанцируется как ResourceZone")
			continue
		zone.size = resource_zone_size
		zone.resource_type = type_id
		zone.count = count
		zone.units_per_pile = per_pile
		zone.min_spacing = resource_min_spacing
		add_child(zone)
		# Все 4 зоны центрированы на POI (Z3D position = (0,0,0) локально).
		# Геометрический overlap не страшен: pile'ы спавнятся через rejection
		# sampling с min_spacing, тип на тип не конфликтует (4 типа × 20 куч =
		# 80 точек на 28×28 минус safe_radius=12 кружок = плотность ~0.15
		# куч/м², просторно).


## Лагерь развернулся где-то на сцене. Если anchor в нашем safe_radius —
## это наш костёр, поджигаем. Иначе — игнор (это другой POI).
func _on_camp_deployed(anchor: Vector3) -> void:
	if not is_within_safe_radius(anchor):
		return
	_is_camp_deployed_here = true
	_refresh_visual()


## Лагерь свёрнут. Camp в проекте один, поэтому camp_packed без аргументов —
## однозначно «свёрнут наш лагерь». Гасим костёр (если не completed).
func _on_camp_packed() -> void:
	if not _is_camp_deployed_here:
		return
	_is_camp_deployed_here = false
	_refresh_visual()


## True если world-точка в радиусе safe_radius от костра. Camp использует
## для deploy-gate'а: hold R вне круга — игнор. Расчёт по горизонтали
## (XZ), Y игнорируется — для плоской карты разница несущественна.
func is_within_safe_radius(world_pos: Vector3) -> bool:
	var dx: float = world_pos.x - global_position.x
	var dz: float = world_pos.z - global_position.z
	return (dx * dx + dz * dz) <= (safe_radius * safe_radius)


## Геттер расписания осады для WaveDirector'а. Может вернуть null —
## тогда POI «мирный», волны не идут.
func get_wave_schedule() -> WaveSchedule:
	return wave_schedule


func _on_quest_advanced(_new_index: int) -> void:
	_refresh_visual()


## Каждый Log* в .tscn ссылается на общий sub_resource Material_log.
## Чтобы менять emission per-instance (locked / active / completed), делаем
## уникальную копию и переназначаем на все 4 полена один раз в _ready.
func _clone_log_material() -> void:
	if _logs_root == null:
		return
	var first_log := _logs_root.get_child(0) as MeshInstance3D
	if first_log == null or first_log.material_override == null:
		_log_material = StandardMaterial3D.new()
	else:
		_log_material = (first_log.material_override as StandardMaterial3D).duplicate()
	for child in _logs_root.get_children():
		var mi := child as MeshInstance3D
		if mi != null:
			mi.material_override = _log_material


func _refresh_visual() -> void:
	# Completed имеет приоритет над лагерем: задание выполнено = «отгоревший»
	# костёр (зелёный след) даже если игрок снова поставил тут лагерь.
	# Иначе — горит ровно когда лагерь развёрнут именно на этом POI; квест
	# active без лагеря костёр НЕ зажигает (раньше зажигал, но дизайнерская
	# семантика «костёр = очаг лагеря»: нет лагеря — нет очага).
	if QuestProgress.is_completed(quest_order):
		_apply_completed()
	elif _is_camp_deployed_here:
		_apply_active()
	else:
		_apply_locked()


## Locked — костёр не разожжён. Тёмные поленья, дыма мало (просто струйка),
## нет пламени, без света. Как место будущего костра, но без задания не зажжён.
func _apply_locked() -> void:
	_log_material.emission_enabled = true
	_log_material.emission = Color(0.5, 0.2, 0.05, 1.0)
	_log_material.emission_energy_multiplier = 0.05
	_flame_core.visible = false
	_flame_particles.emitting = false
	_smoke_particles.emitting = true
	# 5 / max ≈ 0.36 — едва тлеющая струйка.
	_smoke_particles.amount_ratio = 5.0 / float(_smoke_amount_max)
	_light.light_energy = 0.0


## Active — горящий костёр. Яркое пламя, активный дым, тёплый свет.
func _apply_active() -> void:
	_log_material.emission_enabled = true
	_log_material.emission = Color(0.95, 0.35, 0.05, 1.0)
	_log_material.emission_energy_multiplier = 0.6
	_flame_core.visible = true
	_flame_particles.emitting = true
	_smoke_particles.emitting = true
	_smoke_particles.amount_ratio = 1.0
	_light.light_color = Color(1.0, 0.55, 0.2, 1.0)
	_light.light_energy = 1.6


## Completed — задание выполнено. Костёр догорел, но угли тлеют бело-голубым
## (магический след). Свет тусклый зелёный — игрок видит, что был тут и закрыл.
func _apply_completed() -> void:
	_log_material.emission_enabled = true
	_log_material.emission = Color(0.4, 0.85, 0.55, 1.0)
	_log_material.emission_energy_multiplier = 0.3
	_flame_core.visible = false
	_flame_particles.emitting = false
	_smoke_particles.emitting = true
	# 3 / max ≈ 0.21 — почти невидимая ниточка. Минимум выше нуля,
	# чтобы игрок видел: «здесь был квест, я его закрыл».
	_smoke_particles.amount_ratio = 3.0 / float(_smoke_amount_max)
	_light.light_color = Color(0.5, 0.95, 0.6, 1.0)
	_light.light_energy = 0.7
