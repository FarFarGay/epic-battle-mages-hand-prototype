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

# --- Enemy ---
signal enemy_damaged(enemy: Node3D, amount: float)
signal enemy_destroyed(enemy: Node3D)

# --- Tower ---
signal tower_destroyed

# --- Harvester ---
## Харвестер (ядро лагеря, источник золота) уничтожен. Camp гасит добычу и
## обнуляет ссылку; MatchGoal слушает → эмитит match_lost (поражение).
signal harvester_destroyed
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
## Клик по Кафедре Волшебных свитков → HUD открывает магазин заклинаний (покупка за монеты).
signal spell_shop_requested
## ЛКМ-клик по плите Верфи → HUD открывает окно срезов башни (TowerUpgrades,
## покупка за монеты). Заезд-триггер пробовали 2026-07-04 — неудобно, вернули клик.
signal tower_dock_requested
## Из башни вылетел снаряд — на КАЖДЫЙ выстрел, не на каст: шквал/мины эмитят
## per-shot (по снаряду), одиночные — раз. target — точка цели снаряда. Башня
## использует для отдачи-тильта (направление = башня→target). Честная серия отдач.
signal tower_fired(target: Vector3)
## Тряска камеры (trauma-based). amount 0..1, position — МИРОВАЯ точка события:
## камера ослабляет травму по расстоянию от центра обзора (близко=полно, далеко=0).
## Звать ТОЛЬКО на сильных/редких событиях (супер, взрыв, смерть босса) — не на каждый выстрел.
signal camera_shake(amount: float, position: Vector3)

# --- Hand: захват / бросок / способности ---
signal hand_grabbed(item: Node3D)
signal hand_released(item: Node3D, velocity: Vector3)

# --- Camp ---
signal camp_deployed(anchor: Vector3)
signal camp_packed

# --- Camp alarm: скелет бьёт по «мирному» лагерю (палатка / гном-собиратель) ---
## Эмитится из Skeleton._perform_strike, когда скелет наносит урон CampPart
## или НЕ-DefenderGnome'у. DefenderGnome подписан и использует attacker как
## приоритетную цель (override конуса зрения) на период тревоги. Defender,
## получающий урон, alarm НЕ триггерит — иначе лучник, по которому уже
## стреляют, сам бы развернулся в свой обстрел.
signal skeleton_attacked_camp(attacker: Node3D, victim: Node3D, position: Vector3)

## Превентивный сигнал: скелет ПРИБЛИЗИЛСЯ к цели в лагере (палатка/гном)
## на дистанцию [Skeleton.approach_alarm_distance], но ещё не ударил. Один
## раз per-цель — флаг сбрасывается на смене _cached_target. Цель сигнала —
## дать защитникам ~1с предупреждения до первого удара:
##  - ArcherSoldier при victim=CampPart развернётся/выстрелит, как и на
##    attacked_camp (тот же handler).
##  - Gnome при victim=self переключается в FLEE — бежит к лагерю.
signal skeleton_targeting_camp(attacker: Node3D, victim: Node3D, position: Vector3)

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

# --- Match goal ---
## Условие победы матча выполнено. Эмитится один раз за партию из
## [MatchGoal] когда выполнены ВСЕ условия (gold ≥ target И tower прошёл
## через gate с ключом). WinOverlay слушает — показывает панель «Победа».
signal match_won

## Условие поражения матча. Эмитится один раз за партию из [MatchGoal] когда
## разрушено ядро лагеря (харвестер) ИЛИ уничтожена башня. `reason` — причина
## для текста оверлея. DefeatOverlay слушает — показывает панель «Поражение» и
## ставит игру на паузу. Зеркало match_won.
signal match_lost(reason: String)

## Ключ занесён в башню (KeyItem перешёл в AT_TOWER). Разблокирует Gate.
signal key_delivered_to_tower
## Tower прошёл через Gate. Эмитится один раз за жизнь сцены. Условие
## победы дополнительно требует gold ≥ target.
signal tower_passed_gate

# --- Boss wave warning (предупреждение о приближающейся боссовой волне) ---
## Эмитится из [WaveDirector] за `seconds_until_spawn` секунд до спавна
## боссовой волны (Giant + N Throwers с разных сторон). HUD/overlay
## слушает чтобы показать предупреждающий баннер «Гигант приближается»
## — даёт игроку время приготовить super/мины/защиту.
signal boss_wave_incoming(seconds_until_spawn: float)

# --- Day/Night cycle ---
## Фаза day/night сменилась. is_night=true → ночь (волны крупные, Giant/
## Thrower/Boss-триггеры активны), false → день (волны редкие, слабые,
## большие угрозы выключены). duration_seconds — длительность новой фазы
## (HUD рисует countdown от этой величины). Эмитится из [WaveDirector] на
## каждой смене + один раз на старте кампании (initial day).
signal day_phase_changed(is_night: bool, duration_seconds: float)

# --- Quests ---
## Прогресс сюжета продвинулся: new_index = новый QuestProgress.current_index.
## Слушают QuestActor (для перекраса) и потенциально HUD.
signal quest_advanced(new_index: int)

## ТРЕВОГА населения (rooms, Population.set_alarm, клавиша V): рабочие прячутся
## в убежище (замок/башня), добыча и мана встают. HUD рисует баннер.
signal alarm_changed(active: bool)

## Из казны потрачены монеты (GoldBank.spend_cost/try_spend; value — бронза-эквивалент).
## HUD панчит счётчик казны и показывает «−N» — трата ощущается на ЛЮБОЙ покупке
## (стройка, найм, магазин заклинаний) из одной точки.
signal coins_spent(value: int)

## Гномы-строители (Room6): станок-чертёжник в Room11 запущен ([BlueprintMachine])
## → игрок получил знание о постройке стен/башен. HUD слушает, чтобы
## разблокировать меню построек. Идемпотентно (флаг живёт в PlayerProfile).
signal building_unlocked

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

@warning_ignore_restore("unused_signal")
