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

# --- Item ---
signal item_damaged(item: Node3D, amount: float)
signal item_destroyed(item: Node3D)

# --- Enemy ---
signal enemy_damaged(enemy: Node3D, amount: float)
signal enemy_destroyed(enemy: Node3D)

# --- Tower ---
signal tower_damaged(amount: float)
signal tower_destroyed

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
## Отряд получил новый уровень. UpgradeModal слушает и показывает игроку
## выбор улучшения. Параметр — новый уровень (1, 2, 3, ...).
signal squad_leveled_up(level: int)
## Игрок выбрал апгрейд из модала. Все DefenderGnome нашего лагеря читают
## Camp.has_upgrade(id) на каждом тике — отдельных переподписок не нужно.
## Сигнал нужен HUD'у для индикации «активные апгрейды».
signal squad_upgrade_granted(upgrade_id: StringName)
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
