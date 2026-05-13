extends Node
## Глобальный event bus. Регистрируется как autoload в project.godot под именем `EventBus`.
## Сущности эмитят свои локальные сигналы И перенаправляют их сюда — UI / звук /
## статистика подписываются один раз на нужный глобальный сигнал, не зная про
## конкретные инстансы.
##
## Конвенция именования: <entity>_<event>(args).
## Локальные сигналы entity-классов остаются прежними — bus не их замена,
## а параллельный канал для cross-cutting слушателей.
##
## Аргументы типизированы как Node3D / Node (а не как Item/Enemy/...) — чтобы
## EventBus как autoload не зависел от конкретных геймплейных классов.
## Слушатели сами кастуют по необходимости (или работают на уровне Node3D).
##
## @warning_ignore_start("unused_signal") — все сигналы здесь объявлены, но
## emit'аются из других скриптов (паттерн event-bus). GDScript warning «declared
## but never used in the class» — false-positive для этого паттерна.
@warning_ignore_start("unused_signal")

# --- Item ---
signal item_damaged(item: Node3D, amount: float)
signal item_destroyed(item: Node3D)

# --- Enemy ---
signal enemy_damaged(enemy: Node3D, amount: float)
signal enemy_destroyed(enemy: Node3D)

# --- Tower ---
signal tower_damaged(amount: float)
signal tower_destroyed
## Текущий HP башни изменился. HUD рисует hp-bar.
signal tower_health_changed(current: float, maximum: float)
## Текущая мана башни изменилась — потрачена касто́м или восстановлена реген'ом.
## HUD рисует mana-bar.
signal tower_mana_changed(current: float, maximum: float)

# --- Spell system ---
## Заклинание разблокировано (через SpellSystem.try_unlock). Журнал
## перерисовывает вкладку «Заклинания», в будущем — звук/уведомление.
signal spell_unlocked(id: StringName)
## Заклинание прокачано на новый уровень. level — уже актуальный (после апгрейда).
signal spell_upgraded(id: StringName, level: int)

# --- Hand: захват / бросок / способности ---
signal hand_grabbed(item: Node3D)
signal hand_released(item: Node3D, velocity: Vector3)
signal hand_slammed(position: Vector3, radius: float)
signal hand_flicked(target: Node3D, velocity: Vector3)

# --- Camp ---
signal camp_deployed(anchor: Vector3)
signal camp_packed
signal camp_part_damaged(part: Node3D, amount: float)
signal camp_part_destroyed(part: Node3D)

# --- Gnome ---
signal gnome_damaged(gnome: Node3D, amount: float)
signal gnome_destroyed(gnome: Node3D)

# --- Camp alarm: скелет бьёт по «мирному» лагерю (палатка / гном-собиратель) ---
## Эмитится из Skeleton._perform_strike, когда скелет наносит урон CampPart
## или НЕ-DefenderGnome'у. DefenderGnome подписан и использует attacker как
## приоритетную цель (override конуса зрения) на период тревоги. Defender,
## получающий урон, alarm НЕ триггерит — иначе лучник, по которому уже
## стреляют, сам бы развернулся в свой обстрел.
signal skeleton_attacked_camp(attacker: Node3D, victim: Node3D, position: Vector3)

# --- Defender squad: общий опыт отряда лучников + апгрейды ---
## XP отряда изменился (накапливается за убийства скелетов). HUD/UI слушает
## для отображения шкалы прогресса.
signal squad_xp_changed(xp: int, level: int)
## Отряд получил новый уровень. JournalPanel инкрементит банк выборов;
## HUD моргает баром. Параметр — новый уровень (1, 2, 3, ...).
signal squad_leveled_up(level: int)
## Игрок выбрал апгрейд из модала. Все DefenderGnome нашего лагеря читают
## Camp.has_upgrade(id) на каждом тике — отдельных переподписок не нужно.
## Сигнал нужен HUD'у для индикации «активные апгрейды».
signal squad_upgrade_granted(upgrade_id: StringName)
## Изменилось число невыбранных апгрейдов (банк выборов отряда). Эмитится
## из Camp.add_squad_xp (на новом уровне) и Camp.grant_upgrade (на трате).
## HUD слушает чтобы рисовать бэйдж на кнопке журнала.
signal pending_upgrade_choices_changed(count: int)

# --- Camp resources (фаза 2 ресурсной экономики) ---
## Изменился запас одного типа ресурса лагеря. Эмитится из Camp.add_resource
## и Camp.try_spend. type — значение ResourcePile.ResourceType (int).
## amount — итоговый накопленный запас этого типа после изменения.
## HUD слушает чтобы реактивно обновлять счётчики; JournalPanel — чтобы
## переоценивать «по карману ли» постройки.
signal resources_changed(type: int, amount: int)

# --- Camp buildings (фаза 3) ---
## Состав построек лагеря изменился: новая палатка построена, или одноразовая
## постройка типа watchtower стала «уже куплена». JournalPanel слушает,
## чтобы перерисовать карточки. Без аргументов — UI читает текущее состояние
## из Camp напрямую.
signal camp_buildings_changed

# --- Camp collection orders (план распределения + alarm/work режим) ---
## Игрок переключил режим сбора (C — работать, V — тревога). HUD рисует
## индикатор; гномы реагируют через Camp.set_collection_mode (request_return /
## enter_deployed). mode = Camp.CollectionMode (int).
signal collection_mode_changed(mode: int)
## Игрок поменял приоритет сбора по типам (Journal-вкладка «План»). weights —
## Dictionary[ResourcePile.ResourceType (int) → float], нормированный к сумме 1.
## Гномы читают через Camp.get_collection_priority_weight в _find_nearest_pile.
signal collection_priority_changed(weights: Dictionary)
## XP-инкремент с привязкой к мировой точке (позиция убитого скелета).
## Используется визуальным feedback'ом (всплывающий «+10» над трупом).
## Идёт ПЕРЕД squad_xp_changed — слушатели popup'а получают свежий amount,
## слушатели бара — итоговый XP/level.
signal squad_xp_gained_at(amount: int, world_position: Vector3)

# --- Modules / mount slots ---
signal module_mounted(module: Node, slot: Node)
signal module_unmounted(module: Node, slot: Node)

# --- Quests ---
## Прогресс сюжета продвинулся: new_index = новый QuestProgress.current_index.
## Слушают QuestActor (для перекраса) и потенциально HUD.
signal quest_advanced(new_index: int)

# --- Squads / Army (мобилизованные солдаты) ---
## Отряд создан (recruit_squad) — UI добавляет карточку.
signal squad_created(squad: RefCounted)
## Отряд изменился (members_changed / state_changed) — UI перерисовывает карточку.
signal squad_changed(squad: RefCounted)
## Все члены отряда погибли — UI убирает карточку, Camp снимает ссылку.
signal squad_disbanded(squad: RefCounted)
## Игрок попытался recall'нуть отряд (Q или кнопка), но он вне зоны вызова.
## UI флешит карточку красным; Camp уже залогировал.
signal squad_recall_ignored(squad: RefCounted)
## Игрок нажал Q — волна вызова от башни. center = башня, radius = граница
## зоны, duration = время распространения волны (radius / wave_speed).
## HUD рисует расширяющееся кольцо за это время; юниты получают команду
## когда фронт волны до них доходит (Camp scheduling per distance).
signal recall_zone_pulsed(center: Vector3, radius: float, duration: float)


# --- Navigation ---
## Эмитится когда NavigationRegion3D закончил async re-bake (новые препятствия
## учтены, path-запросы вернут актуальные пути). Слушают агенты с NavAgent3D
## чтобы сбросить кэш `_nav_last_target` — без этого `set_target_position`
## с тем же goal'ом игнорируется и старый (невалидный после изменения карты)
## path не пересчитывается.
signal navmesh_baked


# --- Super spell (великая сила, ковровая бомбардировка) ---
## Шкала «великой силы» отряда изменилась. Накопление по нанесённому damage'у
## врагам. value/max = сырые единицы (сейчас 0..100 ≈ 100 hp нанесённого damage).
signal super_charge_changed(value: float, max_value: float)
## Игрок начал каст супер-удара (нажат Space, шкала full). UI замораживает
## мир time_scale=0.15, показывает QTE-паттерн.
signal super_cast_started
## QTE завершён. success=true → игрок прицеливается и кастует, шкала спишется
## полностью; success=false → шкала спишется на половину, мир возвращается.
signal super_cast_finished(success: bool)

@warning_ignore_restore("unused_signal")
