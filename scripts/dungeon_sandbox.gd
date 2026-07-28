extends Node3D
## ПЕСОЧНИЦА ДАНЖ-КОНТРОЛА (дизайн-сессия 2026-07-23): щупаем секунда-к-секунде
## феел «автошутер с управлением мышью» — отряд гномов-лучников стайно течёт за
## курсором, автострельба, скелеты волнами от стен. Отдельная сцена, в геймлуп
## rooms НЕ включена — только для плейтеста ощущений до интеграции.
##
## Запуск: открыть scenes/dungeon_sandbox.tscn в редакторе → F6
## (или CLI: godot --path <проект> res://scenes/dungeon_sandbox.tscn).
##
## Управление: ЛКМ (держать) — вести отряд за курсором-«поводком»; отпустил —
##             ЮЗ по инерции (докатываются с трением), потом ёж на месте
##             остановки. (Ранний «резкий стоп» сменён моделью «тачка».)
##             ПКМ (при зажатой ЛКМ) — ТОРМОЗ «как на тачке»: ход и разгон
##             стекают, руление живёт (тормоз в повороте, ручник-дрифт),
##             корпус осаживается назад, пыль как визг колодок.
##             (Пин-свинг отключён 2026-07-23 — его код спит в SoldierGnome.)
##             Визуал приказа — язык дэш-обводки/aim'а: линия отряд→точка
##             (AoeVisual.spawn_ground_line) + кольцо на точке, пульс на отпуск.
##             E — поднять/бросить ГРУЗ: у груза класс (meta "need") =
##             сколько гномов несут ОДНОВРЕМЕННО; носильщики не стреляют
##             (руки заняты) и идут на 80% скорости — жадность физически
##             ослабляет залп. Павшего носильщика сменяет свободный;
##             рук меньше нужного — груз падает.
##             T — вызвать волну сейчас. R — рестарт сцены.
##
## Переиспользованы штатные сущности, новых юнитов НЕ заведено:
##  - ArcherSoldier + Squad: state HOLDING_POSITION, а `hold_position`
##    обновляется каждый кадр в точку курсора → центр строя течёт за мышью.
##    Адаптивный спринт отстающих (Gnome._move_toward) даёт стайность бесплатно.
##  - Эмерджентный зачаток формаций из конуса зрения лучника: на бегу _facing
##    по движению → стреляют только вперёд; встали в кольцо → _outward_facing
##    → круговой «ёж» на 360°. Стоять = обороняться, бежать = прорываться.
##  - Skeleton: спавн у стен + set_forced_target(живой гном) — волна сразу
##    давит на отряд, без ожидания vision-обнаружения.
##
## Контекст строя: setup_free требует escort-цель (иначе _has_squad_context
## false и юниты стоят) — используем узел Banner, приклеенный к курсору.

const ARCHER_TYPE := &"archer_squad"

## Цвет приказов отряду — тот же голубой, что у aim-ring'а HandSquadAim:
## один визуальный язык «команда отряду» по всей игре.
const CMD_COLOR := Color(0.4, 0.85, 1.0, 0.9)
## Радиус кольца-цели (точка назначения, не зона).
const CMD_RING_RADIUS := 0.9
## Дистанция центроид→точка (XZ), ниже которой маркеры приказа гаснут —
## отряд «дошёл», линия под ногами не нужна.
const CMD_ARRIVED_DIST := 2.0

@export_group("Отряд")
## Сколько гномов в отряде. Дизайн: 7 = вся артель (кап населения).
@export var squad_size: int = 7
## ГЛАВНАЯ ручка темпа: пропорциональный множитель ВСЕЙ скорости отряда
## (шаг + спринт догона + буст разгона поверх). Медленнее — крути сюда
## (0.85 = −15%), НЕ gnome_move_speed: тот влияет только на шаг у самого
## слота, а крейсер ведомого отряда — спринт (Gnome.caravan_sprint_speed=9).
@export var gnome_speed_scale: float = 1.0
## Скорость ШАГА у слота (каталожные 1.6 — челнок по базе). В ведении почти
## не ощущается — крейсер задаёт спринт × gnome_speed_scale.
@export var gnome_move_speed: float = 3.0
## Дальность выстрела. Каталожные 22.5 (оборона базы) в комнате 50×50 били бы
## через всю карту — толпа не успевала бы подойти. Короткая дистанция заставляет
## подпускать врага = появляется рулёжка.
@export var gnome_attack_range: float = 12.0
## Темп стрельбы (каталожные 1.0–2.0 — вальяжная оборона; данжу нужен ливень).
@export var gnome_cooldown_min: float = 0.5
@export var gnome_cooldown_max: float = 0.9
## Урон выстрела. Каталожные 20–32 ваншотили скелета (hp=30) — «жоско»
## (фидбек 2026-07-23). 8–12 = ~3 выстрела на скелета: толпа успевает
## доползти, появляется челлендж.
@export var gnome_damage_min: float = 8.0
@export var gnome_damage_max: float = 12.0
## ЗАНОСЫ (эксперимент 2026-07-23): инерция руления гнома, 1/с. Скорость
## доворачивается к цели, на резких поворотах кучу сносит дугой. 0 = выкл
## (мгновенное руление, как в основной игре). В модели «дрифт-событие» это
## темп доворота В СКОЛЬЖЕНИИ: радиус дуги ≈ скорость/этот темп. 1.2 давало
## радиус ~3.5м = «летишь прямо»; 2.6 ≈ дуга ~1.6м — читаемый карв.
@export var gnome_steer_inertia: float = 2.6
## Базовое сцепление (руление вне скольжения). 9 → 7 → 5.5 по фидбекам
## «чуть больше инерции» (×2) при вводе ПКМ-тормоза и юза: обычная езда
## плывёт, контроль добирается тормозом.
@export var gnome_steer_grip: float = 5.5
## Трение карва в скольжении: величина скорости сходится к желаемой с этим
## темпом (1/с). Меньше = момент живёт дольше (шире орбиты, риск разлёта),
## больше = быстрее гаснет к управляемому.
@export var gnome_drift_scrub: float = 1.6
## Сцепка строя в скольжении: подтяжка каждого гнома к своему слоту (1/с).
## Больше = куча дрифтит плотной пачкой (не напарываются на ловушки),
## меньше = каждый скользит сам (живописнее, но разъезд).
@export var gnome_drift_formation_pull: float = 2.0
## Максимум «поводка»: точка приказа не может убегать дальше этого от центра
## отряда (кламп при ведении ЛКМ). С заносами обязателен — иначе далёкая
## точка разгоняет кучу так, что дуги становятся неуправляемыми.
@export var leash_max: float = 7.0
## Поводок на ПОЛНОМ разгоне: длина растёт с ramp'ом от leash_max к этому —
## на скорости появляется запас на замах для манёвра.
@export var leash_max_full: float = 10.0
## Длина «хвоста кометы» на полном разгоне: на бегу строй вытягивается за
## точкой (читается «мы летим», проход между столбами), на стопе — ёж-кольцо.
@export var tail_length_full: float = 4.5

@export_group("Груз (E)")
## Радиус подбора: E цепляет ближайший груз в этом радиусе от центра отряда.
@export var cargo_pickup_radius: float = 4.0
## Высота полёта груза над центром отряда (низ куба).
@export var cargo_carry_height: float = 1.15
## ДРИФТ-СОБЫТИЕ: угол (°) между средней скоростью отряда и направлением на
## точку, при котором на скорости врубается скольжение (вход-триггер).
@export var drift_enter_angle_deg: float = 55.0
## Угол выравнивания (°), ниже которого скольжение отпускает (выход).
@export var drift_exit_angle_deg: float = 18.0
## Минимальная средняя скорость отряда (м/с) для входа в дрифт — на шаге
## резкий поворот остаётся чётким рулением.
@export var drift_min_speed: float = 2.8
## Разгон: секунды непрерывного бега до полной скорости (0 = выкл).
## Дольше катишься → быстрее → шире занос. Стоп/выстрел сбрасывает.
## 2.0 → 3.5 по фидбеку — разгон должен зарабатываться дольше.
@export var gnome_run_ramp_time: float = 3.5
## Прибавка на полном разгоне (0.7 = +70% к скорости).
@export var gnome_run_boost: float = 0.7

@export_group("Ловушки (Room2)")
## Сцепление руления на льду (заменяет gnome_steer_grip внутри зоны И
## доминирует над дрифтом). Низкое = сильно скользко: влетел на скорости →
## занос, легко впечататься в шипы. 1.5 «слабовато» (фидбек) → 0.7: занос
## вдвое сильнее + лёд теперь скользит и в дрифт-событии (см. SoldierGnome).
## Ещё ×2 (фидбек) → 0.35: доворот почти нулевой, гнома несёт по прямой пока
## не съедет со льда/не врежется. ~16× ниже обычного grip (5.5).
@export var ice_grip: float = 0.35
## Урон отряду за один «укол» шипов и период уколов (пока гном у стены).
@export var spike_damage: float = 8.0
@export var spike_interval: float = 0.45
## Отскок гнома от шипастой стены (м/с, в −X от стены).
@export var spike_knockback: float = 7.0

@export_group("Волны скелетов")
@export var skeleton_scene: PackedScene
## Пауза между волнами (сек). Первая волна — через first_wave_delay.
@export var wave_interval: float = 10.0
@export var first_wave_delay: float = 3.0
## Размер волны: base + growth × (номер волны − 1).
@export var wave_base_count: int = 4
@export var wave_growth: int = 2
## Потолок живых скелетов одновременно (защита от каши и просадок).
@export var max_alive_skeletons: int = 45
## Волн НА КОМНАТУ (фидбек 2026-07-28 «прошёл и всё — открываешь дверь и идёшь
## дальше»): комната выдаёт столько волн и затихает; добил последних → WaveLabel
## «Волны отбиты ✓». Каждая комната считает свои волны отдельно (вернулся в
## зачищенную — тишина). 0 = бесконечно (старое поведение). Чит T лимит обходит.
@export var room_wave_limit: int = 5

@export_group("Директор давления (WASD)")
## ЗАМЕНА волн-по-таймеру (фидбек 2026-07-28 «весело должно быть с первых
## секунд»). Диагноз старой подачи: 3с пауза + скелет 2.0 м/с идёт от стены
## 22м ≈ 11с → первые ~7 секунд игроку НЕЧЕГО делать; 4 скелета с четырёх
## разных стен = 12 стрел за 10с, колчан/стамина/щит не включаются вовсе.
## Директор вместо этого ДЕРЖИТ давление: кривая говорит, сколько врага должно
## быть в лицо ПРЯМО СЕЙЧАС, долив идёт поштучно и непрерывно. Пустых пауз нет;
## передышка = провал кривой, а не мёртвый таймер. Одна модель вместо четырёх
## ручек (interval/base/growth/limit) = DK-урок weight-бюджета (DESIGN §3.2).
## Только wasd_mode: модели 1/2 живут на старых волнах (§6.2 «ветки независимы»).
@export var director_enabled: bool = true
## Стартовая пачка: столько скелетов УЖЕ на арене в t=0 (пустой старт не бывает
## весёлым). Делится на две кучи — есть куда стрелять и от чего пятиться.
@export var director_start_pack: int = 7
## Радиус стартовой пачки от центра комнаты. Внутри дальности лучника (12м):
## первое действие игрока на ПЕРВОЙ секунде — зажал ЛКМ, что-то развалилось.
@export var director_start_radius: float = 9.5
## Кривая давления (живых скелетов): сразу после входа в комнату → к чему растём.
@export var director_pressure_start: float = 8.0
@export var director_pressure_peak: float = 18.0
## За сколько секунд ПОД ДАВЛЕНИЕМ (время в комнате) кривая идёт start → peak.
@export var director_ramp_time: float = 75.0
## Как часто директор проверяет добор (с) и сколько доливает за раз. Долив КУЧЕЙ,
## а не по одному: толпа читается, фокус-огонь имеет смысл.
@export var director_drip_interval: float = 0.9
@export var director_drip_max: int = 3
## Бюджет комнаты: сколько скелетов она выдаёт ВСЕГО, потом затихает и после
## добивания последних → «Волны отбиты ✓». Замена room_wave_limit в этом режиме
## (старое = 5 волн по 4+2N ≈ 40 суммарно).
@export var director_room_budget: int = 55
## ФРОНТ: направление от центра комнаты, ОТКУДА лезут. −Z = из глубины анфилады,
## навстречу ходу игрока → у группы есть «перед» и «спина», отход осмыслен.
## Старый спавн раскидывал по случайной из 4 стен: пятиться некуда, фокус-огонь
## бессмыслен, twin-stick не работает.
@export var director_front_dir: Vector3 = Vector3(0.0, 0.0, -1.0)
## Полуугол фронтового сектора (°): 0 = строго одна точка, 180 = снова кругом.
@export var director_front_arc_deg: float = 55.0
## Дистанция долива от центра комнаты и разброс кучи внутри сектора (°).
@export var director_spawn_radius: float = 19.0
@export var director_cluster_spread_deg: float = 8.0
## КЛЮЧ-ЦЕЛИ (2026-07-28, замена колчану/стамине): что заставляет переключать
## фокус 1↔2↔3 — не счётчик патронов, а ВРАГ НА ЭКРАНЕ, которого текущий
## инструмент не берёт. Драйвер «тянуть», а не «толкать»: причина видна, темп
## нигде не проваливается. Типы подаются КУЧЕЙ (идёт группа щитовиков — это
## читается), доли ниже. Гейт по времени = DK `minRunWeight`: первые секунды
## чистый полив, ключ-цели входят, когда игрок освоился.
## Щитовики: стрелы звенят и гаснут (Enemy.arrow_proof) → только панч [1].
@export var director_shieldman_share: float = 0.3
@export var director_shieldman_after: float = 12.0
## Бегуны: вдвое быстрее, хилые, лезут В СПИНУ (сектор фронт+180°) → щит [3]
## или разворот группы. Дают дальнему бою цену за «стоять и лить вперёд».
@export var director_runner_share: float = 0.25
@export var director_runner_after: float = 20.0

@export_group("Комната и камера")
## Центр комнаты НАМЕРЕННО сдвинут от мирового origin: в сцене нет навмеша,
## пустая нав-карта снапит цели в точный (0,0,0), а zero-guard в
## Gnome._resolve_path_step распознаёт этот баг только для целей дальше 1м
## от origin. Комната вокруг (0,0,0) давала «кучу-залипание» гномов в центре.
## Должен совпадать с расстановкой Floor/стен/столбов в .tscn.
@export var room_center: Vector3 = Vector3(40.0, 0.0, 40.0)
## Полуразмер комнаты (стены на room_center ± room_half). Курсор клампится по X
## сюда (комнаты одной ширины). По Z — отдельный диапазон ниже (много комнат).
@export var room_half: float = 25.0
## Z-диапазон клампа курсора: покрывает ВСЕ комнаты + коридоры анфилады, чтобы
## отряд можно было вести из Room1 через коридоры в дальние комнаты. Стены
## сами держат в коридорах по X. Дефолт под 1 комнату; .tscn многокомнатной
## сцены выставляет полный диапазон (напр. -104..64 на 3 комнаты вдоль −Z).
@export var cursor_z_min: float = 15.0
@export var cursor_z_max: float = 65.0
## Смещение камеры от точки взгляда (высота/отступ = ракурс).
@export var camera_offset: Vector3 = Vector3(0.0, 21.0, 11.0)
## Насколько точка взгляда камеры тянется от центра отряда к курсору (0..1).
## Чуть видно «куда веду», но отряд не уезжает из кадра. Фидбек 2026-07-23:
## 0.25 укачивало, полное отключение — скучно; «небольшие совсем» → 0.1,
## потом «ещё чуть тише» → 0.06.
@export var camera_cursor_bias: float = 0.06
## Доля вращательной качки (0..1): 0 = ракурс намертво фиксирован (чистый
## пан), 1 = камера каждый кадр целится точно в догоняющую точку (как было
## при «укачивает»). Малые значения дают живое микро-подруливание взгляда.
## 0.3 → 0.15 → 0.08 по фидбекам «уменьши повороты/ещё чуть тише».
@export_range(0.0, 1.0) var camera_sway: float = 0.08
## Скорость догона камеры (экспоненциальное сглаживание).
@export var camera_follow_speed: float = 5.0

@export_group("Superhot — пошаговый шаг")
## ПОШАГОВАЯ модель (юзер 2026-07-24, «как Superhot, но пошагово»): мир по
## умолчанию ЗАМЕР, целишься поводком (всегда виден от отряда к курсору, обрезан
## по superhot_reach), КЛИК ЛКМ = один шаг в ту точку. Пока отряд идёт — время
## течёт (Superhot), доехал → снова замер. Стреляют только в пределах reach и по
## курсу (attack_range приравнен к reach; между шагами time_scale≈0 глушит огонь
## сам). Реализовано ОДНИМ Engine.time_scale — скрипты врагов/снарядов не тронуты.
## Копия сцены dungeon_superhot включает флагом; обычная песочница = false
## (непрерывная «тачка»).
@export var superhot_mode: bool = false
## Макс. длина ШАГА = радиус ВЫСТРЕЛА (единая «длина действия»). Поводок обрезан
## по нему; attack_range лучников в step-режиме равен ему.
@export var superhot_reach: float = 9.0
## Груз укорачивает «длину действия»: минус столько метров поводка на единицу
## веса несомого груза (meta "need" 1/3/5). 0 = вес не влияет. Тяжелее → короче
## шаг И радиус выстрела разом.
@export var superhot_reach_weight_penalty: float = 1.0
## Нижний предел поводка под грузом — короче не станет, как ни нагружай.
@export var superhot_reach_min: float = 2.5
## Радиус прилипания ПРИЦЕЛА к врагу (метров от конца поводка): цель захвачена,
## только когда сам прицел НА враге. Прицел = точка, не сектор — окружённый отряд
## не красит поводок, пока ты не навёл его на конкретного скелета.
@export var superhot_aim_snap: float = 1.6
## Насколько близко к точке шага = «дошёл» (шаг завершён, мир замирает).
@export var superhot_arrive_dist: float = 0.8
## Клик по врагу в досягаемости = ЗАЛП С МЕСТА (не бежим в мили): столько
## world-секунд отряд стоит и палит, потом мир замирает. Больше = длиннее очередь
## за клик (но враги дольше подходят на этом «ходу времени»).
@export var superhot_shoot_beat: float = 0.7
## Тайм-скейл мира МЕЖДУ шагами (прицеливание). 0.02 ≈ стоп-кадр; держи >0, чтобы
## физика тикала и клик мог «разбудить» время.
@export_range(0.0, 1.0) var superhot_min_scale: float = 0.02
## Тайм-скейл на самом шаге (полный ход).
@export_range(0.1, 1.0) var superhot_max_scale: float = 1.0
## Скорость отряда (м/с) для полного хода — правит плавность въезда в заморозку
## на концах шага.
@export var superhot_ref_speed: float = 6.0
## Уровень времени ВО ВРЕМЯ шага: клик сразу поднимает мир до него, чтобы отряд
## шёл в нормальном темпе, а не «раскачивался» из стоп-кадра. 0.9 ≈ почти полный.
@export_range(0.0, 1.0) var superhot_intent_floor: float = 0.9
## Сглаживание тайм-скейла: быстрее вверх (резкий старт шага), вниз (застывание
## в конце). Экспоненциальное, в 1/сек.
@export var superhot_ramp_up: float = 14.0
@export var superhot_ramp_down: float = 8.0

@export_group("WASD-группа (twin-stick)")
## ТРЕТЬЯ модель контрола (2026-07-24, «вероятно вернёмся к VS-like»): плотная
## СМЕШАННАЯ группа едет WASD, курсор = направление выстрела, зажатый ЛКМ =
## полив стрелков в сторону курсора, ПКМ = артельщик выставляет щит-блок.
## Копейщики бьют вблизи автоматом (оборона контакта). Принцип «нет полоски
## HP — есть гномы, визуально отображающие возможности» сохраняется. Сцена
## dungeon_wasd включает флагом; drift и superhot не тронуты.
@export var wasd_mode: bool = false
## Состав группы: лучники (полив по ЛКМ) / копейщики (мили-автобой, передний
## ряд) / артельщики (щит по ПКМ; живых щитов не больше живых артельщиков).
@export var wasd_archers: int = 3
@export var wasd_spearmen: int = 2
@export var wasd_artel: int = 1
## Скорость движения точки строя по WASD (м/с). Чуть ВЫШЕ скорости юнитов —
## тогда они бегут за точкой на полном ходу, без «доехал-жду» вязкости.
@export var wasd_speed: float = 7.5
## Доля скорости при отходе ЗАДОМ (ход строго против прицела). Вбок — среднее
## между этим и 1.0. 1.0 = выключить. См. [_backpedal_scale].
@export var wasd_backpedal_speed: float = 0.55
## Скорость самих гномов группы (м/с, всем типам одинаково — группа = тело).
## Каталожные 1.6–2.2 для twin-stick вязкие.
@export var wasd_unit_speed: float = 6.0
## Сцепление руления юнитов (1/с, экспоненциальный догон скорости): выше =
## резче старт/стоп/повороты. Дефолт отряда 5.5 — «кисель» для twin-stick.
@export var wasd_grip: float = 12.0
## Полив: цель = скелет в дальности, ближайший к ЛУЧУ курсора; сектор захвата
## вокруг направления (дот-порог 0.5 ≈ ±60°) — курсор ведёт огонь как стик.
@export var wasd_aim_dot: float = 0.5
## Скорость удара-хлыста копейщиков (м/с, вылет И отскок). 28 ≈ щелчок:
## цикл клик→укол→в строю ~0.3-0.4с — «классический мили-замах», не пробежка.
@export var wasd_punch_speed: float = 28.0
## САМООБОРОНА лучников без фокуса (нерф «в защите разносят всех», 2026-07-24):
## стреляют только по подошедшим в этот радиус (симметрия с копейщиками — вся
## оборона бьёт КОНТАКТ) и с растянутым кулдауном. Фокус [2] возвращает полную
## дальность (gnome_attack_range) и штатный темп.
@export var wasd_defense_range: float = 4.0
@export var wasd_defense_cd_mult: float = 1.7
## Щит артельщика: HP (скелеты-мили грызут), размер плашки и дистанция
## выставления от центра группы в сторону курсора.
@export var wasd_shield_hp: float = 120.0
@export var wasd_shield_size: Vector3 = Vector3(4.0, 1.8, 0.6)
@export var wasd_shield_dist: float = 2.6
## КОЛЧАН-ОБОЙМА лучника (2026-07-27) — ВЫКЛЮЧЕН фидбеком 2026-07-28: конечный
## боезапас «очень сбивает теншен и темп». Причина в природе драйвера: сухой
## колчан не даёт РЕШЕНИЕ, он даёт ПРОСТОЙ — игрок стоит и ждёт, пока цифра
## натикает, а переключение фокуса становится повинностью, а не манёвром.
## Стрелы на спине остались как декор (wasd_quiver_decor). >0 = вернуть лимит.
@export var wasd_quiver_size: int = 0
## Сколько стрел рисовать на спине, когда лимит выключен (чистый визуал).
@export var wasd_quiver_decor: int = 6
## СУПЕР МИЛИ-КЛАССА (ПРОБЕЛ, пивот 2026-07-28). Переключение фокуса 1/2/3
## выпилено: дальний бой работает ВСЕГДА (по направлению курсора), мили-класс
## сжат в одну кнопку с делеем и кулдауном. Причина: фокус-группы существовали
## только чтобы выдавать приказы разным отрядам — когда приказ один, меню
## становится пустым интерфейсом («жму цифру, чтобы получить право нажать
## кнопку»). Один жест вместо режима. Гейт — САМ СОСТАВ ОТРЯДА: нет копейщиков
## → нет супера (билд решает возможности, без второго слоя карточек-абилок).
## Внутри — веер ШТАТНЫХ панчей (импакт-пакет punch_at) + ударная волна: не
## абстрактный круг урона, а «копейщики выстрелили наружу».
@export var wasd_super_radius: float = 6.5
## Замах-телеграф до удара (с): видно кольцо, толпа успевает подойти — «когда
## жать» становится решением.
@export var wasd_super_windup: float = 0.4
@export var wasd_super_cooldown: float = 6.0
@export var wasd_super_damage: float = 34.0
@export var wasd_super_knockback: float = 11.0
## Секунд на одну стрелу перезарядки (0.5 → 0.3 по фидбеку 2026-07-28 «увеличь
## скорость»: пустой→полный 2.4с вместо 3.8с).
@export var wasd_quiver_reload: float = 0.3
## Пауза тишины после последнего выстрела до старта перезарядки (с).
@export var wasd_quiver_delay: float = 0.6
## СТАМИНА КОПЕЙЩИКОВ (2026-07-28, зеркало колчана) — ВЫКЛЮЧЕНА тем же фидбеком:
## выдохшийся копейщик так же обнуляет темп (машешь мышью, а удара нет). Пипсы
## на спине не строятся при 0. >0 = вернуть запас ударов.
@export var wasd_stamina_hits: int = 0
## Секунд на восстановление одного удара.
@export var wasd_stamina_restore: float = 0.6
## Пауза без ударов до старта восстановления (с).
@export var wasd_stamina_delay: float = 0.9

var _squad: Squad = null
var _banner: Node3D = null
var _camera: Camera3D = null
var _wave_timer: float = 0.0
var _wave_number: int = 0
## Лимит волн: сколько волн выпустила каждая комната и разовый флаг «отбита»
## (индекс комнаты → int / bool). См. room_wave_limit.
var _room_waves: Dictionary = {}
var _room_cleared: Dictionary = {}
## Директор давления: таймер долива, выданный бюджет по комнатам и время,
## проведённое отрядом в комнате (аргумент кривой давления).
var _director_timer: float = 0.0
var _room_spawned: Dictionary = {}
var _room_time: Dictionary = {}
## Z-центры комнат анфилады (X у всех = room_center.x). Активная = та, в чьём
## полу стоит центроид отряда; в коридоре — -1 (волны на паузе).
var _room_z: Array = []
var _active_room: int = -1
var _kills: int = 0
var _look_target: Vector3 = Vector3.ZERO
var _game_over: bool = false
var _lmb_was_down: bool = false
## ПКМ-тормоз зажат (транслируется в SoldierGnome.brake_active).
var _braking: bool = false
## Несомый груз (Node3D с meta "need") и его носильщики. null = руки пусты.
var _cargo: Node3D = null
var _haulers: Array = []
## Пазл двери Room1→Room2: платформы [{mesh, need, pos, tol, on}] и дверь.
## Дверь открывается (уходит под пол), когда на КАЖДОЙ платформе покоится
## груз ПОДХОДЯЩЕГО размера (совпал meta "need").
var _platforms: Array = []
var _door: Node3D = null
var _door_open: bool = false
var _door_closed_y: float = 1.5
var _door_open_y: float = -2.0
## Средний разгон отряда в этом кадре (0..1) — питает все визуалы разгона.
var _ramp_now: float = 0.0
var _dust_timer: float = 0.0
## Отряд в дрифт-событии (вход/выход синхронные — «одна машинка»).
var _drifting: bool = false
## Маркеры приказа (caller-owned, живут всю сцену, видимость переключается).
var _cmd_line: MeshInstance3D = null
var _cmd_ring: MeshInstance3D = null
## Ловушки Room2: записи {body, push} гномов в зонах шипов (урон по таймеру),
## его тик, и список столбовых зон (для радиального отскока от столба).
var _spike_bodies: Array = []
var _spike_timer: float = 0.0
var _pillar_areas: Array = []
## Крафт бомбы: аппарат (позиция+радиус приёма), счётчик собранных правильных
## ингредиентов, готовая бомба и её фитиль, деревянная дверь-цель.
var _apparatus_pos: Vector3 = Vector3.INF
var _apparatus_mat: StandardMaterial3D = null
var _collected: int = 0
const INGREDIENTS_NEEDED := 3
var _bomb: RigidBody3D = null
var _bomb_fuse: float = -1.0
var _door_wood: Node3D = null
var _wood_broken: bool = false
## Фаза пульсации подсветки правильных ингредиентов (визуал «нужное светится»).
var _craft_pulse: float = 0.0
## Superhot: текущий сглаженный тайм-скейл мира. 1.0 = реальное время.
var _superhot_scale: float = 1.0
## Superhot-пошаг: отряд ИСПОЛНЯЕТ шаг (идёт к точке; на это время мир живёт).
## Между шагами false → мир замер. _aim_point — конец поводка-прицела.
var _step_moving: bool = false
## Идёт ЗАЛП С МЕСТА (клик по врагу): отряд стоит и палит _shoot_timer world-сек,
## время течёт. Клик по земле = ход (_step_moving). Взаимоисключающие.
var _shooting: bool = false
var _shoot_timer: float = 0.0
## КЛИКНУТАЯ цель залпа: отряд бьёт ИМЕННО её (фокус-огонь через alarm), а не
## «кого видят» лучники. Умерла/истёк beat → залп кончился.
var _shoot_target: Node3D = null
## Клик пришёл СОБЫТИЕМ (_unhandled_input) и ждёт разбора в _process. В заморозке
## time_scale роняет частоту физтиков до ~1.2 Гц — поллинг кнопки там жевал
## нажатия; событие не теряется никогда.
var _click_pending: bool = false
## Пад attack_range поверх поводка: клик-гейт меряет досягаемость от ЦЕНТРА
## отряда, а стреляет каждый гном от себя — задний ряд черепахи (~1.5м за
## центром) без пада молчал бы по цели на краю поводка.
const SH_RANGE_PAD := 2.0
## WASD: живые щиты артельщиков (ArtelShield). Ставить новый можно, пока
## щитов меньше живых артельщиков. ПКМ-событие ждёт разбора в физтике.
var _shields: Array = []
var _shield_pending: bool = false
## WASD: точка строя не отрывается от центра дальше этого (гномы упёрлись в
## стену → точка не уезжает в бесконечность, строй не «теряет якорь»).
const WASD_LEASH := 4.0
## WASD: фокус-группа (клавиши 1/2/3 — экшены спеллов, в данже свободны):
## 1=копейщики (штурм цели прицела по ЛКМ), 2=лучники (полив по ЛКМ),
## 3=артель (пока только ПКМ-щит; турели — следующий шаг). Выбранная группа
## подчиняется ЛКМ; невыбранные — в обороне (лучники: авто-огонь по близким,
## копейщики: строй + укол с места).
## Супер мили-класса (ПРОБЕЛ): остаток замаха, кулдаун и кольцо-телеграф.
var _super_windup: float = 0.0
var _super_cd: float = 0.0
var _super_ring: Node3D = null
var _super_armed_prev: bool = true
var _super_hud_acc: float = 0.0
var _focus_group: int = 2
## Карточки фокус-групп в HUD (стиль карточек отрядов основной игры): панели
## порядком групп 1..3 и их StyleBoxFlat для подсветки выбранной. Узлы живут
## в .tscn (двигаются в редакторе), код только красит и наполняет. Пусто в
## сценах без FocusCards (drift/superhot).
var _focus_cards: Array = []
var _focus_card_boxes: Array = []
const FOCUS_CARD_COLORS := [Color(0.85, 0.55, 0.25), Color(0.55, 0.35, 0.75), Color(0.7, 0.45, 0.25)]
## Эффективный поводок этого кадра = superhot_reach минус вес несомого груза
## (superhot_reach_weight_penalty). Правит шаг, прицел-детект и attack_range.
var _effective_reach: float = 9.0
var _aim_point: Vector3 = Vector3.INF
## Настенные микросекунды прошлого кадра (Time.get_ticks_usec иммунен к
## time_scale) — честный real_delta для сглаживания скейла и камеры.
var _sh_last_usec: int = 0


func _ready() -> void:
	# Свежий старт по времени: не унаследовать замедление от прошлого прогона.
	Engine.time_scale = 1.0
	_sh_last_usec = Time.get_ticks_usec()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_banner = $Banner
	_camera = $Camera3D
	_banner.global_position = room_center
	_look_target = room_center
	# Ракурс фиксируется ОДИН раз: дальше камера только скользит (пан без
	# вращения). look_at каждый кадр в догоняющую точку давал качку —
	# направление взгляда подруливало, пока позиция отстаёт («укачивает»).
	_camera.look_at_from_position(room_center + camera_offset, room_center, Vector3.UP)
	_cmd_line = AoeVisual.spawn_ground_line(self, room_center, room_center, CMD_COLOR, 0.16)
	_cmd_ring = AoeVisual.spawn_ground_ring(self, room_center, CMD_RING_RADIUS, 0.0, CMD_COLOR)
	_cmd_line.visible = false
	_cmd_ring.visible = false
	_wave_timer = first_wave_delay
	# Z-центры трёх комнат анфилады (Room1 старт, шаг −60 вдоль −Z).
	_room_z = [room_center.z, room_center.z - 60.0, room_center.z - 120.0]
	_active_room = 0  # старт в Room1 — первая волна через first_wave_delay
	_spawn_squad()
	# Тестовые грузы трёх классов: сколько гномов нужно, чтобы поднять.
	_spawn_cargo(room_center + Vector3(-6, 0, 5), 1)
	_spawn_cargo(room_center + Vector3(6, 0, 6), 3)
	_spawn_cargo(room_center + Vector3(0, 0, -7), 5)
	_setup_door_puzzle()
	_setup_traps()
	_setup_crafting()
	_setup_barricades()
	_update_labels()
	if wasd_mode:
		_setup_focus_cards()
		_refresh_hud_hint()  # постоянная раскладка в HUD
	if _director_active():
		# СТАРТОВАЯ ПАЧКА (после _spawn_squad — скелетам нужна живая цель):
		# бой начинается на первой секунде, а не на седьмой. Две кучи вместо
		# кольца — есть фронт и есть спина.
		_director_timer = director_drip_interval
		var pack_half: int = director_start_pack / 2
		_spawn_cluster(pack_half, director_start_radius)
		_spawn_cluster(director_start_pack - pack_half, director_start_radius)
	print("[DungeonSandbox] boot ok: gnomes=%d, skeleton_scene=%s"
			% [_alive_gnomes(), skeleton_scene != null])


func _spawn_squad() -> void:
	if wasd_mode:
		_spawn_wasd_squad()
		return
	var data: Dictionary = SoldierSystem.get_soldier_data(ARCHER_TYPE)
	if data.is_empty():
		push_error("[DungeonSandbox] нет %s в SOLDIER_CATALOG" % ARCHER_TYPE)
		return
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("[DungeonSandbox] у %s нет scene в каталоге" % ARCHER_TYPE)
		return
	# Статы из каталога + данж-оверрайды темпа (см. доки exports выше).
	var stats: Dictionary = (data.get("stats", {}) as Dictionary).duplicate()
	stats["move_speed"] = gnome_move_speed * gnome_speed_scale
	# 9.0 = дефолт Gnome.caravan_sprint_speed — крейсер ведомого отряда.
	stats["caravan_sprint_speed"] = 9.0 * gnome_speed_scale
	# Step-Superhot: дальность выстрела = длина поводка (единая «длина действия»).
	stats["attack_range"] = superhot_reach if superhot_mode else gnome_attack_range
	stats["attack_cooldown_min"] = gnome_cooldown_min
	stats["attack_cooldown_max"] = gnome_cooldown_max
	stats["attack_damage_min"] = gnome_damage_min
	stats["attack_damage_max"] = gnome_damage_max
	stats["steer_inertia"] = gnome_steer_inertia
	stats["steer_grip"] = gnome_steer_grip
	stats["drift_scrub"] = gnome_drift_scrub
	stats["drift_formation_pull"] = gnome_drift_formation_pull
	stats["run_ramp_time"] = gnome_run_ramp_time
	stats["run_speed_boost"] = gnome_run_boost
	_squad = Squad.new()
	_squad.id = 1
	_squad.soldier_type = ARCHER_TYPE
	_squad.icon_color = data.get("icon_color", Color.WHITE)
	_squad.charge_max = float(data.get("charge_max", 15.0))
	for i in range(squad_size):
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			continue
		# LOD ВЫКЛЮЧЕН (баг «разлёт за карту»): якорь LOD — родитель камеры,
		# в песочнице это корень сцены в мировом нуле, а комната сдвинута на
		# (40,40) → дальняя половина всегда считалась «FAR» = движение БЕЗ
		# коллизий/гравитации, на 15 м/с гномы улетали сквозь стены. Конус 90°
		# = полусфера (не срабатывает с камерой сверху). До add_child —
		# cos конуса кэшируется в _ready.
		soldier.lod_far_distance = 100000.0
		soldier.lod_offscreen_half_angle_deg = 90.0
		# ТЕЛЕСНОСТЬ (фидбек 2026-07-23): гном врезается в скелетов. В основной
		# игре выключено ради перфа толп (см. Layers.MASK_SKELETON) — тут
		# масштабы крошечные, включаем per-instance обоюдно (см. _spawn_wave).
		soldier.collision_mask |= Layers.ENEMIES
		add_child(soldier)
		var ang: float = TAU * float(i) / float(squad_size)
		var pos := room_center + Vector3(cos(ang) * 1.5, 0.5, sin(ang) * 1.5)
		soldier.setup_free(ARCHER_TYPE, stats, pos, _banner)
		_squad.add_member(soldier)
		soldier.destroyed.connect(_on_gnome_died)
	# strict=false: мягкий HOLD — стрельба всегда приоритетнее марша.
	# Стоячий строй — «черепаха»-блок вместо кольца (фидбек 2026-07-23).
	_squad.hold_grid = true
	_squad.command_hold(room_center, false)


## WASD-группа: СМЕШАННЫЙ состав из штатного каталога (копейщики первыми —
## передний ряд черепахи, оборона контакта; затем лучники; артельщик замыкает).
## Один Squad на всех: тип живёт на юните (soldier_type), юниты с разными
## возможностями = «полоска HP» из живых тел. Скорость ЕДИНАЯ — группа = тело.
func _spawn_wasd_squad() -> void:
	var mix: Array = []
	for i in range(wasd_spearmen):
		mix.append(&"pikeman")
	for i in range(wasd_archers):
		mix.append(ARCHER_TYPE)
	for i in range(wasd_artel):
		mix.append(&"worker")
	_squad = Squad.new()
	_squad.id = 1
	_squad.soldier_type = ARCHER_TYPE
	var idx: int = 0
	for t in mix:
		var data: Dictionary = SoldierSystem.get_soldier_data(t)
		var scene: PackedScene = data.get("scene", null)
		if scene == null:
			push_error("[DungeonSandbox] нет сцены для %s в SOLDIER_CATALOG" % t)
			continue
		var stats: Dictionary = (data.get("stats", {}) as Dictionary).duplicate()
		# Бодрый twin-stick: у слота юниты ходят на BASE move_speed (спринт
		# только вдали) — каталожные 1.6–2.2 давали «вязкую» группу. Единая
		# скорость всем + резкое сцепление руления.
		stats["move_speed"] = wasd_unit_speed
		stats["caravan_sprint_speed"] = wasd_unit_speed * 1.3
		stats["steer_grip"] = wasd_grip
		if t == ARCHER_TYPE:
			# Данж-баланс лучника + steer_inertia>0: выстрел НЕ стопит бег —
			# полив на ходу, ядро twin-stick-феела.
			stats["attack_range"] = gnome_attack_range
			stats["attack_cooldown_min"] = gnome_cooldown_min
			stats["attack_cooldown_max"] = gnome_cooldown_max
			stats["attack_damage_min"] = gnome_damage_min
			stats["attack_damage_max"] = gnome_damage_max
			stats["steer_inertia"] = gnome_steer_inertia
		elif t == &"pikeman":
			# Оборона КОНТАКТА (фидбек 2026-07-24): детект срезан почти до
			# длины копья — копейщик НЕ бегает по полю за врагами, держит
			# строй и колет только подошедших вплотную.
			stats["enemy_detect_radius"] = 3.2
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			continue
		# LOD выключен + телесность со скелетами — как у штатного спавна выше.
		soldier.lod_far_distance = 100000.0
		soldier.lod_offscreen_half_angle_deg = 90.0
		soldier.collision_mask |= Layers.ENEMIES
		add_child(soldier)
		var ang: float = TAU * float(idx) / float(mix.size())
		soldier.setup_free(t, stats,
				room_center + Vector3(cos(ang) * 1.5, 0.5, sin(ang) * 1.5), _banner)
		if t == ARCHER_TYPE:
			# С первого кадра под гейтом прицела (до первого тика _wasd_combat
			# дефолтный false давал 1-2 «левых» выстрела по видимым).
			soldier.fire_suppressed = true
			if soldier is ArcherSoldier:
				if wasd_quiver_size > 0:
					(soldier as ArcherSoldier).setup_quiver(
							wasd_quiver_size, wasd_quiver_reload, wasd_quiver_delay)
				else:
					# Лимит выключен, но стрелы на спине остаются (декор).
					(soldier as ArcherSoldier).setup_quiver_decor(wasd_quiver_decor)
		elif t == &"pikeman":
			# Оборона по умолчанию: укол с места, из строя не выходит; клик
			# при фокусе [1] — удар-хлыст (punch_at, скорость из инспектора).
			soldier.hold_ground = true
			soldier.punch_speed = wasd_punch_speed
			if wasd_stamina_hits > 0:
				soldier.setup_stamina(wasd_stamina_hits, wasd_stamina_restore, wasd_stamina_delay)
		elif t == &"worker":
			_skin_artel(soldier)
		_squad.add_member(soldier)
		soldier.destroyed.connect(_on_gnome_died)
		idx += 1
	_squad.hold_grid = true
	_squad.command_hold(room_center, false)


## Раскладка постоянная (выбирать больше нечего): подсказка вместо телеграфа
## фокуса. Лучники льют сами по курсору, мили — ПРОБЕЛ, артель — ПКМ.
func _refresh_hud_hint() -> void:
	var hint := get_node_or_null("HUD/Panel/Rows/HintLabel") as Label
	if hint != null:
		hint.text = "WASD — ход · курсор — огонь · ПРОБЕЛ — удар вокруг · ПКМ — щит"
	_refresh_focus_cards()


## Стили карточек (как _make_squad_card основной игры: тёмный фон, цветной
## бордер типа, скругление). Узлы — в .tscn, тут только StyleBox'ы и ссылки.
func _setup_focus_cards() -> void:
	_focus_cards.clear()
	_focus_card_boxes.clear()
	for i in range(3):
		var card := get_node_or_null("HUD/FocusCards/Card%d" % (i + 1)) as PanelContainer
		if card == null:
			return
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.09, 0.09, 0.13, 0.92)
		box.border_color = FOCUS_CARD_COLORS[i]
		box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		box.content_margin_left = 8
		box.content_margin_right = 8
		box.content_margin_top = 5
		box.content_margin_bottom = 5
		card.add_theme_stylebox_override("panel", box)
		_focus_cards.append(card)
		_focus_card_boxes.append(box)


## Карточки больше НЕ выбор, а дисплей состава: счётчик живых по типам (вся
## группа мертва → карточка гаснет, гномы = видимое HP) + готовность супера на
## карточке копейщиков. Подсветки выбранной нет — выбирать нечего.
func _refresh_focus_cards() -> void:
	if _focus_cards.size() < 3:
		return
	var keys := [&"pikeman", ARCHER_TYPE, &"worker"]
	var totals := [wasd_spearmen, wasd_archers, wasd_artel]
	var counts := {}
	if _squad != null:
		for m in _squad.members:
			if is_instance_valid(m):
				counts[m.soldier_type] = int(counts.get(m.soldier_type, 0)) + 1
	for i in range(3):
		var card: PanelContainer = _focus_cards[i]
		var box: StyleBoxFlat = _focus_card_boxes[i]
		var alive: int = int(counts.get(keys[i], 0))
		# Копейщики: бордер белеет, когда ПРОБЕЛ готов — телеграф способности
		# на самой карточке (кнопка вспыхивает, а не полоска кулдауна).
		var armed: bool = i == 0 and alive > 0 and _super_cd <= 0.0 and _super_windup <= 0.0
		box.border_color = Color(1, 1, 1, 0.95) if armed else FOCUS_CARD_COLORS[i]
		box.bg_color = Color(0.16, 0.15, 0.2, 0.95) if armed else Color(0.09, 0.09, 0.13, 0.92)
		card.modulate = Color(1, 1, 1, 1.0) if alive > 0 else Color(1, 1, 1, 0.35)
		var cnt := card.get_node_or_null("V/Count") as Label
		if cnt != null:
			var txt: String = "Живых: %d / %d" % [alive, totals[i]]
			if i == 0 and alive > 0:
				txt += "\n[ПРОБЕЛ] готов" if armed else "\n[ПРОБЕЛ] %.1fс" % _super_cd
			cnt.text = txt


## Блочная моделька артельщика — единый стиль с лучником/копейщиком (фидбек
## 2026-07-24): жёлтая роба строителя, молоток, заплечная доска. GLB-модель
## воркера скрываем ТОЛЬКО в данж-группе; в основной игре он как был.
func _skin_artel(w: SoldierGnome) -> void:
	var vis := w.get_node_or_null("Visual") as Node3D
	if vis != null:
		vis.visible = false
	var mesh_node := w.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_node != null:
		mesh_node.visible = false
	var holder := Node3D.new()
	holder.position = Vector3(0, -0.4, 0)
	w.add_child(holder)
	var cloth := _artel_mat(Color(0.85, 0.66, 0.2))
	var skin := _artel_mat(Color(0.85, 0.7, 0.55))
	var wood := _artel_mat(Color(0.3, 0.2, 0.12))
	var steel := _artel_mat(Color(0.72, 0.74, 0.8))
	_artel_box(holder, Vector3(0.34, 0.5, 0.26), Vector3(0, 0.45, 0), cloth)      # тело
	_artel_box(holder, Vector3(0.26, 0.26, 0.24), Vector3(0, 0.82, 0), skin)      # голова
	_artel_box(holder, Vector3(0.05, 0.55, 0.05), Vector3(0.24, 0.6, 0), wood)    # рукоять молотка
	_artel_box(holder, Vector3(0.16, 0.1, 0.1), Vector3(0.24, 0.92, 0), steel)    # боёк молотка
	_artel_box(holder, Vector3(0.3, 0.42, 0.06), Vector3(-0.2, 0.55, 0.14), wood) # заплечная доска


func _artel_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m


func _artel_box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)


func _process(_dt: float) -> void:
	# Superhot: контрол, прицел, тайм-скейл и камера — на РЕНДЕР-частоте.
	# _process идёт каждый отрисованный кадр независимо от Engine.time_scale
	# (в отличие от физтиков), поэтому в стоп-кадре прицел/камера плавные, а
	# клик разбирается мгновенно. real_delta — настенные часы (не scaled _dt).
	if not superhot_mode:
		return
	var now_us: int = Time.get_ticks_usec()
	var real_delta: float = clampf(float(now_us - _sh_last_usec) / 1_000_000.0, 0.0, 0.1)
	_sh_last_usec = now_us
	var cursor: Vector3 = _cursor_ground_point()
	_superhot_control(real_delta, cursor)
	_update_superhot(real_delta, _step_moving or _shooting)
	_update_camera(real_delta, cursor)


func _physics_process(delta: float) -> void:
	if wasd_mode:
		# ТРЕТЬЯ модель: WASD-тело + курсор-прицел + ЛКМ-полив + ПКМ-щит.
		# Мир в реальном темпе, без time_scale — обычный физтик.
		_wasd_physics(delta)
		return
	if superhot_mode:
		# Superhot: тут ТОЛЬКО мир (ловушки/крафт/волны) на scaled-темпе —
		# замерзает вместе со временем, как и должен. Контрол, прицел,
		# тайм-скейл и камера — в _process: в заморозке time_scale роняет
		# ЧАСТОТУ физтиков (~1.2 Гц при 0.02) — на физике клики жевались,
		# прицел и камера дёргались слайд-шоу.
		_superhot_world_tick(delta)
		return
	var cursor: Vector3 = _cursor_ground_point()
	# Движение по ЛКМ-«поводку»: пока держишь — точка приказа течёт за курсором;
	# отпустил — фиксируется, отряд доходит и встаёт (ёж на 360°). Постоянное
	# следование убрано по фидбеку 2026-07-23: стоять/идти — осознанный выбор.
	var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _game_over
	# ПКМ = ТОРМОЗ «как на тачке» (2026-07-23; пин-свинг отключён, его код в
	# SoldierGnome спит): ход гасится, руление живёт — тормоз в повороте и
	# ручник-дрифт работают. Точка приказа продолжает следовать за курсором.
	var brake: bool = lmb and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	_ramp_now = _avg_ramp()
	if lmb and not _lmb_was_down and _squad != null:
		# ЛКМ = педаль газа: нажатие МГНОВЕННО перебивает юз — руление
		# подхватывает юнита с текущей скоростью, не дожидаясь остановки.
		for m in _squad.members:
			if is_instance_valid(m):
				m.coast_active = false
	if lmb and cursor != Vector3.INF and _squad != null:
		# Поводок ограничен от центра отряда (куча идёт дугами, не хвостом) и
		# РАСТЁТ с разгоном: на скорости появляется запас на замах.
		var leash: float = lerpf(leash_max, leash_max_full, _ramp_now)
		var target: Vector3 = cursor
		var c: Vector3 = _squad.compute_center()
		if c != Vector3.INF:
			var to_cursor := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
			var d: float = to_cursor.length()
			if d > leash:
				target = Vector3(c.x, 0.0, c.z) + to_cursor * (leash / d)
		_squad.hold_position = target
		_banner.global_position = target
	if brake != _braking and _squad != null:
		_braking = brake
		for m in _squad.members:
			if is_instance_valid(m):
				m.brake_active = brake
	if _lmb_was_down and not lmb and _squad != null:
		# Отпустили — ЮЗ по инерции (модель «тачка», сменила ранний «резкий
		# стоп»): каждый гном докатывается с трением и встаёт сам; ёж
		# собирается там, где остановились (точка приказа едет за центроидом
		# ниже). Пульс — подтверждение «отпустил» на месте отпускания.
		for m in _squad.members:
			if is_instance_valid(m):
				m.start_coast()
		AoeVisual.spawn_ground_ring(self, _squad.hold_position, CMD_RING_RADIUS + 0.25, 0.5, CMD_COLOR)
	_lmb_was_down = lmb
	if not lmb and _squad != null:
		# Пока не ведём: точка приказа следует за центроидом — после юза
		# позиционирование паркует всех на месте остановки, а не тянет
		# назад к точке отпускания. МЁРТВАЯ ЗОНА 0.75м — асимметрия строя
		# (неполный ряд черепахи) иначе создаёт фидбек-луп «центроид смещён →
		# точка уехала → строй пополз» и отряд бесконечно пятится.
		var cc: Vector3 = _squad.compute_center()
		if cc != Vector3.INF:
			var dxh: float = cc.x - _squad.hold_position.x
			var dzh: float = cc.z - _squad.hold_position.z
			if dxh * dxh + dzh * dzh > 0.5625:
				_squad.hold_position = Vector3(cc.x, 0.0, cc.z)
				_banner.global_position = _squad.hold_position
	_update_drift(lmb)
	_update_tail(lmb, delta)
	_tick_dust(delta, lmb)
	_tick_cargo(delta)
	_tick_cargo_snap(delta)
	_tick_door_puzzle(delta)
	_tick_spikes(delta)
	_tick_apparatus(delta)
	_tick_bomb(delta)
	_tick_barricades()
	_update_cmd_visuals(lmb)
	if not _game_over:
		_update_active_room()
		# Волны спавнятся ТОЛЬКО пока отряд в комнате (в коридоре — пауза,
		# уже заспавненные скелеты доживают/преследуют). Точка спавна — стены
		# активной комнаты, так что при переходе Room1→Room2 волны сами
		# «переезжают» за отрядом.
		if _active_room >= 0:
			_wave_timer -= delta
			if _wave_timer <= 0.0:
				_wave_timer = wave_interval
				_spawn_wave()
	_update_camera(delta, cursor)


## Линия отряд→точка + кольцо на точке. Видимы, пока приказ «в исполнении»
## (держим ЛКМ или отряд ещё не дошёл); по прибытии гаснут. Линия наливается
## цветом с разгоном, при натянутой верёвке пина — вспышка до белого.
func _update_cmd_visuals(lmb: bool) -> void:
	if _squad == null or _cmd_line == null or _cmd_ring == null:
		return
	var hold: Vector3 = _squad.hold_position
	var center: Vector3 = _squad.compute_center()
	var dist: float = 0.0
	if center != Vector3.INF:
		dist = Vector2(center.x - hold.x, center.z - hold.z).length()
	var active: bool = center != Vector3.INF and (lmb or dist > CMD_ARRIVED_DIST)
	if not active:
		_cmd_line.visible = false
		_cmd_ring.visible = false
		return
	_cmd_ring.visible = true
	_cmd_ring.global_position = Vector3(hold.x, 0.05, hold.z)
	AoeVisual.update_ground_line(_cmd_line,
			Vector3(center.x, 0.0, center.z), Vector3(hold.x, 0.0, hold.z))
	# Линия «горит» в скольжении; вне него — тлеет по разгону (слабо:
	# разгон — второстепенный сигнал).
	var hot: float = _ramp_now * 0.45
	if _drifting:
		hot = 1.0
	var mat := _cmd_line.material_override as StandardMaterial3D
	if mat != null:
		var c: Color = CMD_COLOR.lerp(Color(0.92, 0.99, 1.0, 1.0), hot * 0.85)
		mat.albedo_color = c
		mat.emission = Color(c.r, c.g, c.b, 1.0)
		mat.emission_energy_multiplier = 2.5 + 4.5 * hot


## Детектор дрифт-события (уровень ОТРЯДА, вход/выход синхронные): на скорости
## резкий увод точки вбок (угол скорость↔направление > enter-порога) → все
## разом в скольжение + отдача (пыль-залп); дуга выровнялась (< exit-порога)
## или ход упал — все разом выходят. Гистерезис порогов держит состояние
## стабильным внутри дуги.
func _update_drift(lmb: bool) -> void:
	if _squad == null:
		return
	if not lmb:
		_set_drifting(false)
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		_set_drifting(false)
		return
	var avg_v := Vector3.ZERO
	var n: int = 0
	for m in _squad.members:
		if is_instance_valid(m):
			avg_v += Vector3(m.velocity.x, 0.0, m.velocity.z)
			n += 1
	if n == 0:
		_set_drifting(false)
		return
	avg_v /= float(n)
	var speed: float = avg_v.length()
	var desired := Vector3(_squad.hold_position.x - c.x, 0.0, _squad.hold_position.z - c.z)
	if speed < 0.5 or desired.length_squared() < 0.25:
		if _drifting and speed < 1.0:
			_set_drifting(false)
		return
	var ang: float = rad_to_deg(avg_v.angle_to(desired))
	if not _drifting:
		if speed >= drift_min_speed and ang >= drift_enter_angle_deg:
			_set_drifting(true)
	elif ang <= drift_exit_angle_deg or speed < 1.0:
		_set_drifting(false)


## Синхронный вход/выход скольжения для всего отряда. На входе — отдача:
## пых пыли из-под каждого гнома («сорвались») + сброс троттла пыли.
func _set_drifting(on: bool) -> void:
	if _drifting == on or _squad == null:
		return
	_drifting = on
	for m in _squad.members:
		if is_instance_valid(m):
			m.drift_active = on
			if on:
				_spawn_soft_dust(Vector3(m.global_position.x, 0.1, m.global_position.z))
	if on:
		_dust_timer = 0.0


const CARGO_GROUP := &"dungeon_cargo"

## Груз-куб (RigidBody3D): meta "need" = сколько гномов несут ОДНОВРЕМЕННО.
## Размер/теплота цвета растут с классом. В руках заморожен (freeze) и
## ведётся кодом; брошен/выпал — размораживается и летит по уровню физикой
## (слой ITEMS: пол/стены/скелеты его останавливают, гномы проходят).
func _spawn_cargo(pos: Vector3, need: int) -> void:
	var side: float = 0.35 + 0.22 * float(need)
	var body := RigidBody3D.new()
	body.collision_layer = Layers.ITEMS
	body.collision_mask = Layers.TERRAIN | Layers.ITEMS
	body.mass = 2.0 * float(need)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(side, side, side)
	shape.shape = box_shape
	body.add_child(shape)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(side, side, side)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.62 - 0.07 * float(need), 0.2, 1.0)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 0.6
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)
	body.set_meta(&"need", need)
	body.set_meta(&"kind", &"cube")  # пазл дверей ищет только kind=="cube"
	body.add_to_group(CARGO_GROUP)
	add_child(body)
	body.global_position = Vector3(pos.x, side * 0.5 + 0.05, pos.z)


## Общий носимый груз произвольного вида (ингредиент/бомба). Тот же RigidBody +
## груз-механика (E поднять/нести/бросить/физика), различие по meta "kind".
## Куб-сфера цвета `color`; `need`=1 (лёгкий, 1 гном). Возвращает узел.
func _spawn_item(pos: Vector3, kind: StringName, color: Color, sphere: bool = false,
		side: float = 0.7) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = Layers.ITEMS
	body.collision_mask = Layers.TERRAIN | Layers.ITEMS
	body.mass = 2.0
	var shape := CollisionShape3D.new()
	if sphere:
		var sph := SphereShape3D.new()
		sph.radius = side * 0.5
		shape.shape = sph
	else:
		var bs := BoxShape3D.new()
		bs.size = Vector3(side, side, side)
		shape.shape = bs
	body.add_child(shape)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.5
	var mi := MeshInstance3D.new()
	if sphere:
		var sm := SphereMesh.new()
		sm.radius = side * 0.5
		sm.height = side
		mi.mesh = sm
	else:
		var bm := BoxMesh.new()
		bm.size = Vector3(side, side, side)
		mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	body.set_meta(&"need", 1)
	body.set_meta(&"kind", kind)
	body.add_to_group(CARGO_GROUP)
	add_child(body)
	body.global_position = Vector3(pos.x, side * 0.5 + 0.05, pos.z)
	return body


## E: поднять ближайший груз (если хватает гномов) / бросить несомый.
func _toggle_cargo() -> void:
	if _squad == null:
		return
	if _cargo != null:
		_drop_cargo()
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	var item: Node3D = _nearest_cargo(c)
	if item == null:
		return
	var need: int = int(item.get_meta(&"need", 1))
	var alive: Array = []
	for m in _squad.members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.size() < need:
		# Не хватает рук — короткий красный пульс на грузе (язык «нельзя»).
		AoeVisual.spawn_ground_ring(self, item.global_position, 0.9, 0.4,
				Color(1.0, 0.25, 0.25, 0.9))
		return
	# Носильщики — ближайшие к грузу N (sticky до смерти/броска).
	_haulers.clear()
	while _haulers.size() < need and not alive.is_empty():
		var w: Node3D = _pop_nearest_unit(alive, item.global_position)
		w.hauling = true
		_haulers.append(w)
	_cargo = item
	var rb := item as RigidBody3D
	if rb != null:
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
	AoeVisual.spawn_ground_ring(self, item.global_position, 1.0, 0.4, CMD_COLOR)
	_update_labels()


## Бросок/выпадение: груз размораживается и летит физикой, наследуя средний
## ход носильщиков (+подброс) — на дрифте его красиво выносит по дуге.
func _drop_cargo() -> void:
	if _cargo == null:
		return
	var toss := Vector3.ZERO
	var n: int = 0
	for h in _haulers:
		if is_instance_valid(h):
			toss += Vector3(h.velocity.x, 0.0, h.velocity.z)
			n += 1
			h.hauling = false
	if n > 0:
		toss /= float(n)
	_haulers.clear()
	var rb := _cargo as RigidBody3D
	if rb != null:
		rb.freeze = false
		rb.linear_velocity = toss * 1.1 + Vector3.UP * 2.2
		rb.angular_velocity = Vector3(randf_range(-2, 2), randf_range(-3, 3), randf_range(-2, 2))
	_cargo = null
	_update_labels()


## Тик переноски: груз жёстко над центроидом носильщиков; павших сменяют
## свободные; рук меньше, чем нужно → груз падает сам.
func _tick_cargo(_delta: float) -> void:
	if _cargo == null or _squad == null:
		return
	var need: int = int(_cargo.get_meta(&"need", 1))
	var free: Array = []
	for i in range(_haulers.size() - 1, -1, -1):
		if not is_instance_valid(_haulers[i]):
			_haulers.remove_at(i)
	for m in _squad.members:
		if is_instance_valid(m) and not (m in _haulers):
			free.append(m)
	while _haulers.size() < need and not free.is_empty():
		var w: Node3D = _pop_nearest_unit(free, _cargo.global_position)
		w.hauling = true
		_haulers.append(w)
	if _haulers.size() < need:
		_drop_cargo()
		return
	# Груз висит над ЦЕНТРОИДОМ НОСИЛЬЩИКОВ (не всего отряда) — видно, кто
	# именно тащит, и куб мотается вместе с их группой.
	var c := Vector3.ZERO
	var cnt: int = 0
	for h in _haulers:
		if is_instance_valid(h):
			c += h.global_position
			cnt += 1
	if cnt == 0:
		_drop_cargo()
		return
	c /= float(cnt)
	# ЖЁСТКАЯ сцепка (фидбек 2026-07-23): без лерпа — сглаживание отставало
	# на ходу/дрифте («куб вылетает за группу»). Буквально несут в руках.
	_cargo.global_position = Vector3(c.x, cargo_carry_height, c.z)


func _nearest_cargo(near: Vector3) -> Node3D:
	var best: Node3D = null
	var best_sq: float = cargo_pickup_radius * cargo_pickup_radius
	for n in get_tree().get_nodes_in_group(CARGO_GROUP):
		var e := n as Node3D
		if e == null or not is_instance_valid(e) or e == _cargo:
			continue
		var dx: float = e.global_position.x - near.x
		var dz: float = e.global_position.z - near.z
		if dx * dx + dz * dz < best_sq:
			best_sq = dx * dx + dz * dz
			best = e
	return best


## Вынуть из массива юнита, ближайшего к point (XZ).
func _pop_nearest_unit(units: Array, point: Vector3) -> Node3D:
	var best_i: int = 0
	var best_d: float = INF
	for i in range(units.size()):
		var u: Node3D = units[i]
		var dx: float = u.global_position.x - point.x
		var dz: float = u.global_position.z - point.z
		var d: float = dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best_i = i
	var out: Node3D = units[best_i]
	units.remove_at(best_i)
	return out


# --- Ловушки Room2: ледяная арена (лёд по всему полу + шипы кругом) ---

## Room2 (центр по Z = room_center.z - 60) = каток: лёд на весь пол, шипы на
## всех стенах И на 4 столбах со всех сторон. Влетел на скорости, не вырулил
## занос → впечатался в шипы. Урон = следствие потери контроля.
func _setup_traps() -> void:
	var r2 := Vector3(room_center.x, 0.0, room_center.z - 60.0)  # (40,·,-20)
	# Лёд ОСТРОВАМИ (не весь пол): 4 пятна по углам с сухим «крестом» между
	# ними и сухим периметром у стен — есть куда встать и отстреляться, лёд =
	# опасный проезд, а не тотальная беспомощность (фидбек «жоско» 2026-07-24).
	# Каждое пятно накрывает свой столб → занос в него = лёд + столб-шипы.
	for corner in [Vector3(-12, 0, -12), Vector3(12, 0, -12), Vector3(-12, 0, 12), Vector3(12, 0, 12)]:
		_spawn_ice_zone(r2 + corner, Vector3(14, 0.2, 14))
	# Шипы на 4 стены (facing = внутрь комнаты). У S/N — проём коридора X[34,46].
	_spawn_spikes(Vector3(64.6, 0, r2.z), Vector3(0, 0, 1), Vector3(-1, 0, 0), 48.0)   # E
	_spawn_spikes(Vector3(15.4, 0, r2.z), Vector3(0, 0, 1), Vector3(1, 0, 0), 48.0)    # W
	_spawn_spikes(Vector3(r2.x, 0, 5.4), Vector3(1, 0, 0), Vector3(0, 0, -1), 48.0, 40.0, 13.0)   # S (проём)
	_spawn_spikes(Vector3(r2.x, 0, -45.4), Vector3(1, 0, 0), Vector3(0, 0, 1), 48.0, 40.0, 13.0)  # N (проём)
	# 4 столба (как Room1) + шипы со всех сторон каждого.
	for off in [Vector3(-9, 0, -9), Vector3(9, 0, -9), Vector3(-9, 0, 9), Vector3(9, 0, 9)]:
		_spawn_pillar_with_spikes(r2 + off)


## Зона льда: Area3D (ловит гномов слоя FRIENDLY_UNIT) + плоский голубой
## визуал. Вход/выход переключают ice_grip_override у гнома.
func _spawn_ice_zone(center: Vector3, size: Vector3) -> void:
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = Layers.FRIENDLY_UNIT
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	area.add_child(cs)
	add_child(area)
	area.global_position = Vector3(center.x, 0.3, center.z)
	area.body_entered.connect(_on_ice_entered)
	area.body_exited.connect(_on_ice_exited)
	# Визуал: тонкая полупрозрачная голубоватая наледь на полу.
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size.x, 0.08, size.z)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.85, 1.0, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.05
	mat.metallic = 0.3
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
	mi.global_position = Vector3(center.x, 0.06, center.z)


func _on_ice_entered(body: Node3D) -> void:
	if body is SoldierGnome:
		(body as SoldierGnome).ice_grip_override = ice_grip


func _on_ice_exited(body: Node3D) -> void:
	if body is SoldierGnome:
		(body as SoldierGnome).ice_grip_override = -1.0


## Euler-поворот конуса-шипа: cylinder растёт по +Y, крутим ось в `facing`.
func _spike_euler(f: Vector3) -> Vector3:
	if f.x < -0.5:
		return Vector3(0, 0, deg_to_rad(90))    # −X
	if f.x > 0.5:
		return Vector3(0, 0, deg_to_rad(-90))   # +X
	if f.z > 0.5:
		return Vector3(deg_to_rad(90), 0, 0)    # +Z
	return Vector3(deg_to_rad(-90), 0, 0)       # −Z


## Ряд шипов вдоль `along` длиной `length`, остриём в `facing` (внутрь). +
## damage-зона(ы) перед ними. gap_world/gap_w — проём (мировая координата вдоль
## along + ширина), где шипов и урона нет (коридорный проход). push=facing.
func _spawn_spikes(center: Vector3, along: Vector3, facing: Vector3, length: float,
		gap_world: float = 1e9, gap_w: float = 0.0) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.6, 1.0)
	mat.metallic = 0.7
	mat.roughness = 0.4
	var euler := _spike_euler(facing)
	var n: int = int(length / 1.4)
	var gap_off: float = gap_world - along.dot(center)  # проём в координатах off
	for i in range(n):
		var off: float = -length * 0.5 + (float(i) + 0.5) * (length / float(n))
		if gap_w > 0.0 and absf(off - gap_off) < gap_w * 0.5:
			continue
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.22
		cone.height = 0.8
		var mi := MeshInstance3D.new()
		mi.mesh = cone
		mi.material_override = mat
		mi.rotation = euler
		add_child(mi)
		mi.global_position = Vector3(center.x, 1.0, center.z) + along * off
	# Damage-зона(ы): тонкая по facing, длинная по along, смещена в комнату.
	var thin: float = 1.6
	var apos := Vector3(center.x, 1.5, center.z) + facing * 0.5
	if gap_w > 0.0:
		# Две секции по бокам проёма.
		var half: float = (length * 0.5 - (gap_off + gap_w * 0.5))
		var half2: float = ((gap_off - gap_w * 0.5) + length * 0.5)
		_spike_area(apos + along * (gap_off + gap_w * 0.5 + half * 0.5), along, facing, thin, half)
		_spike_area(apos + along * (-length * 0.5 + half2 * 0.5), along, facing, thin, half2)
	else:
		_spike_area(apos, along, facing, thin, length)


## Одна damage-зона шипов (box). push = facing (отскок от стены внутрь).
func _spike_area(pos: Vector3, along: Vector3, facing: Vector3, thin: float, length: float) -> void:
	if length <= 0.5:
		return
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = Layers.FRIENDLY_UNIT
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# По along — length, по facing — thin, Y=3.
	box.size = Vector3(absf(along.x) * length + absf(facing.x) * thin, 3.0,
			absf(along.z) * length + absf(facing.z) * thin)
	cs.shape = box
	area.add_child(cs)
	add_child(area)
	area.global_position = pos
	area.body_entered.connect(_on_spike_entered.bind(facing))
	area.body_exited.connect(_on_spike_exited)


## Столб (как в Room1) + шипы на 4 гранях наружу + damage-зона вокруг
## (отскок радиальный — от центра столба).
func _spawn_pillar_with_spikes(pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.TERRAIN
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(2, 2.6, 2)
	cs.shape = shp
	body.add_child(cs)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2, 2.6, 2)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.3, 0.26, 0.24, 1.0)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = pmat
	body.add_child(mi)
	add_child(body)
	body.global_position = Vector3(pos.x, 1.3, pos.z)
	# Шипы на 4 гранях (2×2 столб, грань на ±1 от центра), торчат наружу.
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.55, 0.55, 0.6, 1.0)
	smat.metallic = 0.7
	for face in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var side := Vector3(-face.z, 0, face.x)  # вдоль грани
		var euler := _spike_euler(face)
		for s in [-0.55, 0.55]:
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.18
			cone.height = 0.7
			var cmi := MeshInstance3D.new()
			cmi.mesh = cone
			cmi.material_override = smat
			cmi.rotation = euler
			add_child(cmi)
			cmi.global_position = Vector3(pos.x, 1.0, pos.z) + face * 1.15 + side * s
	# Damage-зона вокруг столба (радиальный отскок помечаем INF в push_dir).
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = Layers.FRIENDLY_UNIT
	var acs := CollisionShape3D.new()
	var abox := BoxShape3D.new()
	abox.size = Vector3(3.4, 3.0, 3.4)
	acs.shape = abox
	area.add_child(acs)
	add_child(area)
	area.global_position = Vector3(pos.x, 1.5, pos.z)
	area.body_entered.connect(_on_spike_entered.bind(Vector3.INF))
	area.body_exited.connect(_on_spike_exited)
	area.set_meta(&"pillar_center", Vector3(pos.x, 0.0, pos.z))
	_pillar_areas.append(area)


## Гном вошёл в зону шипов. push_dir = facing стены, или INF = радиальный от
## столба (направление считаем в тике по позиции гнома).
func _on_spike_entered(body: Node3D, push_dir: Vector3) -> void:
	if not (body is SoldierGnome):
		return
	for e in _spike_bodies:
		if e.body == body:
			return
	_spike_bodies.append({"body": body, "push": push_dir})


func _on_spike_exited(body: Node3D) -> void:
	for i in range(_spike_bodies.size() - 1, -1, -1):
		if _spike_bodies[i].body == body:
			_spike_bodies.remove_at(i)


## Пока гномы в зоне шипов — раз в spike_interval укол: урон + отскок. От стены
## push = facing; у столба (push=INF) — радиально от центра ближайшего столба.
func _tick_spikes(delta: float) -> void:
	if _spike_bodies.is_empty():
		return
	_spike_timer -= delta
	if _spike_timer > 0.0:
		return
	_spike_timer = spike_interval
	for i in range(_spike_bodies.size() - 1, -1, -1):
		var e = _spike_bodies[i]
		var g = e.body
		if not is_instance_valid(g):
			_spike_bodies.remove_at(i)
			continue
		g.take_damage(spike_damage)
		if g.has_method(&"apply_push"):
			var dir: Vector3 = e.push
			if dir == Vector3.INF:
				dir = _nearest_pillar_push(g.global_position)
			g.apply_push(dir * spike_knockback, 0.2)


## Радиальное направление отскока ОТ ближайшего столба к точке.
func _nearest_pillar_push(p: Vector3) -> Vector3:
	var best := Vector3(0, 0, 1)
	var best_d: float = INF
	for a in _pillar_areas:
		if not is_instance_valid(a):
			continue
		var c: Vector3 = a.get_meta(&"pillar_center", Vector3.ZERO)
		var d: float = Vector2(p.x - c.x, p.z - c.z).length_squared()
		if d < best_d:
			best_d = d
			var away := Vector3(p.x - c.x, 0, p.z - c.z)
			best = away.normalized() if away.length_squared() > 0.01 else Vector3(0, 0, 1)
	return best


# --- Крафт бомбы: аппарат + ингредиенты → бомба → взрыв деревянной двери ---

## Аппарат в Room2 + ингредиенты (3 правильных + 3 отвлекающих). Правильные
## = порох (сера/уголь/селитра, тёплые цвета); отвлекающие (яркие) аппарат
## отвергает. Собрал 3 правильных в аппарат → появляется бомба → неси к
## деревянной двери (Corr23) → фитиль → взрыв ломает дверь.
func _setup_crafting() -> void:
	_door_wood = get_node_or_null("Corr23/Door")
	var r2 := Vector3(room_center.x, 0.0, room_center.z - 60.0)
	_apparatus_pos = r2 + Vector3(-16, 0, 0)  # (24,·,-20) — западная часть Room2
	_spawn_apparatus(_apparatus_pos)
	# Ингредиенты: 3 правильных (correct=true) + 3 отвлекающих, разбросаны.
	var spots := [
		r2 + Vector3(16, 0, 12), r2 + Vector3(20, 0, -14), r2 + Vector3(11, 0, 18),
		r2 + Vector3(-14, 0, 16), r2 + Vector3(-18, 0, -14), r2 + Vector3(4, 0, -20),
	]
	var correct := [Color(0.9, 0.8, 0.2, 1), Color(0.2, 0.2, 0.22, 1), Color(0.92, 0.92, 0.95, 1)]
	var distract := [Color(0.2, 0.5, 0.95, 1), Color(0.3, 0.85, 0.4, 1), Color(0.95, 0.4, 0.75, 1)]
	var idx := 0
	for c in correct:
		var it := _spawn_item(spots[idx], &"ingredient", c, true, 0.6)
		it.set_meta(&"correct", true)
		idx += 1
	for c in distract:
		var it := _spawn_item(spots[idx], &"ingredient", c, true, 0.6)
		it.set_meta(&"correct", false)
		idx += 1


## Визуал аппарата: тёмный «котёл»-цилиндр со светящейся горловиной.
func _spawn_apparatus(pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Layers.TERRAIN
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 1.4
	cyl.height = 2.2
	cs.shape = cyl
	body.add_child(cs)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.5
	mesh.bottom_radius = 1.2
	mesh.height = 2.2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.22, 0.26, 1)
	mat.metallic = 0.6
	mat.roughness = 0.5
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)
	body.global_position = Vector3(pos.x, 1.1, pos.z)
	# Светящаяся горловина сверху (индикатор прогресса — теплеет со сбором).
	var rim := TorusMesh.new()
	rim.inner_radius = 1.0
	rim.outer_radius = 1.4
	_apparatus_mat = StandardMaterial3D.new()
	_apparatus_mat.albedo_color = Color(0.5, 0.6, 0.7, 1)
	_apparatus_mat.emission_enabled = true
	_apparatus_mat.emission = Color(0.4, 0.6, 0.9, 1)
	_apparatus_mat.emission_energy_multiplier = 1.0
	var rmi := MeshInstance3D.new()
	rmi.mesh = rim
	rmi.material_override = _apparatus_mat
	add_child(rmi)
	rmi.global_position = Vector3(pos.x, 2.3, pos.z)


## Каждый кадр: ингредиент (kind ingredient) в горловине аппарата, не несомый →
## правильный поглощается (+счёт, зелёный пых), отвергнутый выталкивается
## (красный пых). Собрал INGREDIENTS_NEEDED → спавн бомбы.
func _tick_apparatus(delta: float) -> void:
	if _apparatus_pos == Vector3.INF:
		return
	_craft_pulse += delta
	# Подсветка «нужное»: правильные ингредиенты пульсируют свечением (дышат),
	# отвлекающие статичны — видно, что кидать, без гадания.
	var glow: float = 1.4 + 1.6 * (0.5 + 0.5 * sin(_craft_pulse * 4.0))
	for n in get_tree().get_nodes_in_group(CARGO_GROUP):
		if n == _cargo or not is_instance_valid(n):
			continue
		if n.get_meta(&"kind", &"cube") != &"ingredient":
			continue
		if bool(n.get_meta(&"correct", false)):
			var m := (n.get_child(1) as MeshInstance3D).material_override as StandardMaterial3D
			if m != null:
				m.emission_energy_multiplier = glow
		var dx: float = n.global_position.x - _apparatus_pos.x
		var dz: float = n.global_position.z - _apparatus_pos.z
		if dx * dx + dz * dz > 2.2 * 2.2:
			continue
		if bool(n.get_meta(&"correct", false)):
			_collected += 1
			AoeVisual.spawn_ground_ring(self, _apparatus_pos + Vector3(0, 0.05, 0), 1.6, 0.4,
					Color(0.3, 1.0, 0.45, 0.9))
			if _apparatus_mat != null:
				var t: float = float(_collected) / float(INGREDIENTS_NEEDED)
				_apparatus_mat.emission = Color(0.4, 0.6, 0.9, 1).lerp(Color(1.0, 0.55, 0.15, 1), t)
			n.queue_free()
			_update_labels()
			if _collected >= INGREDIENTS_NEEDED and _bomb == null:
				_spawn_bomb(_apparatus_pos + Vector3(0, 0, 3.2))
		else:
			# Отвергнут: красный пых + импульс наружу от аппарата (выплюнуть).
			AoeVisual.spawn_ground_ring(self, n.global_position, 1.0, 0.35,
					Color(1.0, 0.25, 0.25, 0.9))
			var rb := n as RigidBody3D
			if rb != null:
				var away := Vector3(dx, 0, dz)
				away = away.normalized() if away.length_squared() > 0.01 else Vector3(0, 0, 1)
				rb.freeze = false
				rb.linear_velocity = away * 5.0 + Vector3.UP * 2.0


## Бомба (kind bomb) — тёмная сфера, берётся как груз. Появляется у аппарата.
func _spawn_bomb(pos: Vector3) -> void:
	_bomb = _spawn_item(pos, &"bomb", Color(0.12, 0.1, 0.12, 1), true, 0.8)
	AoeVisual.spawn_ground_ring(self, pos, 1.4, 0.6, Color(1.0, 0.55, 0.15, 0.9))
	print("[DungeonSandbox] БОМБА готова — неси к деревянной двери")
	_update_labels()


## Бомба у деревянной двери, не несомая → фитиль (мигает) → взрыв: ломает
## дверь + бьёт по площади (гномы/скелеты). Бьёт своих — отводи отряд.
func _tick_bomb(delta: float) -> void:
	if _bomb == null or not is_instance_valid(_bomb):
		return
	if _bomb == _cargo:
		return  # несут — фитиль не тикает
	if _bomb_fuse < 0.0 and _door_wood != null and is_instance_valid(_door_wood):
		var dx: float = _bomb.global_position.x - _door_wood.global_position.x
		var dz: float = _bomb.global_position.z - _door_wood.global_position.z
		if dx * dx + dz * dz <= 5.0 * 5.0:
			_bomb_fuse = 3.0
			print("[DungeonSandbox] фитиль пошёл (3с)")
	if _bomb_fuse >= 0.0:
		_bomb_fuse -= delta
		# Мигание частотой, растущей к взрыву.
		var blink: float = 0.5 + 0.5 * sin(_bomb_fuse * (12.0 - 3.0 * _bomb_fuse))
		var m := (_bomb.get_child(1) as MeshInstance3D).material_override as StandardMaterial3D
		if m != null:
			m.emission = Color(1.0, 0.2, 0.1, 1)
			m.emission_energy_multiplier = blink * 3.0
		if _bomb_fuse <= 0.0:
			_detonate_bomb()


func _detonate_bomb() -> void:
	var pos: Vector3 = _bomb.global_position
	AoeVisual.spawn_explosion(self, pos, 5.0)
	# Урон по площади: гномы (take_damage) + скелеты (Damageable). Радиус 5.
	for g in get_tree().get_nodes_in_group(&"soldier"):
		if is_instance_valid(g) and g.global_position.distance_to(pos) <= 5.0:
			g.take_damage(35.0)
	for s in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if is_instance_valid(s) and s.global_position.distance_to(pos) <= 5.0:
			Damageable.try_damage(s, 200.0, 0.0, s.global_position - pos)
	# Сломать деревянную дверь, если рядом.
	if _door_wood != null and is_instance_valid(_door_wood) and not _wood_broken:
		if _door_wood.global_position.distance_to(pos) <= 6.0:
			_wood_broken = true
			ShatterEffect.spawn(self, _door_wood.global_position, Color(0.4, 0.26, 0.13, 1),
					16, 1.6, Vector3(0, 0, -1), 1.6)
			_door_wood.queue_free()
			print("[DungeonSandbox] деревянная дверь ВЗОРВАНА")
	_bomb.queue_free()
	_bomb = null
	_bomb_fuse = -1.0
	_update_labels()


# --- Баррикады Room3: гномы носят блоки и перегораживают вход ---

## Room3 (тупик). 2 блока у входа, каждый длиной в половину проёма (проём
## X[34,46] шириной 12 → блок 6). Гномы носят (E, need=2) и ставят поперёк
## входа, чтобы отсечь скелетов из коридора. Лёг и покоится → freeze +
## выравнивание → держит проход (скелеты упираются в слой ITEMS).
func _setup_barricades() -> void:
	var r3 := Vector3(room_center.x, 0.0, room_center.z - 120.0)  # (40,·,-80)
	_spawn_barricade(r3 + Vector3(-14, 0, 22))  # у входа слева (Z≈-58)
	_spawn_barricade(r3 + Vector3(14, 0, 22))   # у входа справа


## Блок-баррикада: длинный груз (6×1.6×1), need=2. Берётся как груз; лёг —
## _tick_barricades его фиксирует.
func _spawn_barricade(pos: Vector3) -> void:
	var body := RigidBody3D.new()
	body.collision_layer = Layers.ITEMS
	body.collision_mask = Layers.TERRAIN | Layers.ITEMS
	body.mass = 8.0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(6, 1.6, 1)
	cs.shape = bs
	body.add_child(cs)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.4, 0.36, 1)
	mat.roughness = 0.85
	var bm := BoxMesh.new()
	bm.size = Vector3(6, 1.6, 1)
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	body.set_meta(&"need", 2)
	body.set_meta(&"kind", &"barricade")
	body.add_to_group(CARGO_GROUP)
	add_child(body)
	body.global_position = Vector3(pos.x, 0.8, pos.z)


## Лежащая баррикада (не несомая, покой, низко) → freeze + выравнивание ровно
## (rotation 0, на пол): стоит стеной, скелеты упираются. Поднятая (E) уходит
## из этой ветки (несётся кодом = _cargo).
func _tick_barricades() -> void:
	for n in get_tree().get_nodes_in_group(CARGO_GROUP):
		if n == _cargo or not is_instance_valid(n):
			continue
		if n.get_meta(&"kind", &"cube") != &"barricade":
			continue
		var rb := n as RigidBody3D
		if rb == null or rb.freeze:
			continue
		if rb.linear_velocity.length() < 0.6 and rb.global_position.y < 1.6:
			rb.freeze = true
			rb.global_rotation = Vector3.ZERO
			rb.global_position = Vector3(rb.global_position.x, 0.8, rb.global_position.z)


# --- Пазл двери: платформы под размер груза ---

## Три платформы перед дверью (в Room1, севернее центра — на пути к проёму),
## по классу груза. Дверь резолвим из сцены. Метка размера платформы = размер
## груза-ключа: игрок видит, какой куб сюда.
func _setup_door_puzzle() -> void:
	_door = get_node_or_null("Corr12/Door") as Node3D
	if _door != null:
		_door_closed_y = _door.position.y
	# Платформы в ряд по X перед проёмом (проём на севере Z≈14, ставим южнее).
	var base := Vector3(room_center.x, 0.0, room_center.z - 18.0)  # (40,·,22)
	var needs := [1, 3, 5]
	var xs := [-10.0, 0.0, 10.0]
	for i in range(needs.size()):
		var need: int = needs[i]
		var cargo_side: float = 0.35 + 0.22 * float(need)
		var side: float = cargo_side + 0.5
		var mesh := BoxMesh.new()
		mesh.size = Vector3(side, 0.15, side)
		var mat := StandardMaterial3D.new()
		var base_col := Color(0.85, 0.62 - 0.07 * float(need), 0.2, 1.0)  # = цвет груза
		mat.albedo_color = base_col.darkened(0.35)
		mat.emission_enabled = true
		mat.emission = base_col
		mat.emission_energy_multiplier = 0.15
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = mat
		add_child(node)
		node.global_position = Vector3(base.x + xs[i], 0.08, base.z)
		_platforms.append({
			"mesh": node, "mat": mat, "base_col": base_col,
			"need": need, "pos": node.global_position, "tol": side * 0.5 + 0.7, "on": false,
		})


## Каждый кадр: платформа «нажата», если на ней покоится груз подходящего
## размера (совпал need, XZ в допуске, груз не несут). Все нажаты → дверь вниз.
func _tick_door_puzzle(delta: float) -> void:
	if _platforms.is_empty():
		return
	var all_on: bool = true
	for p in _platforms:
		var on: bool = _platform_pressed(p)
		if on != p.on:
			p.on = on
			# Активная — яркая зелёная, ждущая — тусклый цвет своего груза.
			var m: StandardMaterial3D = p.mat
			if on:
				m.albedo_color = Color(0.3, 0.9, 0.4, 1.0)
				m.emission = Color(0.3, 1.0, 0.45, 1.0)
				m.emission_energy_multiplier = 1.2
				AoeVisual.spawn_ground_ring(self, p.pos, p.tol, 0.4, Color(0.3, 1.0, 0.45, 0.9))
			else:
				m.albedo_color = (p.base_col as Color).darkened(0.35)
				m.emission = p.base_col
				m.emission_energy_multiplier = 0.15
		all_on = all_on and on
	if all_on and not _door_open:
		_door_open = true
		print("[DungeonSandbox] ДВЕРЬ ОТКРЫТА (все платформы нажаты)")
		AoeVisual.spawn_ground_ring(self, Vector3(room_center.x, 0.05, room_center.z - 26.0),
				5.0, 0.7, Color(0.3, 1.0, 0.45, 0.9))
	elif not all_on and _door_open:
		_door_open = false
	# Дверь плавно скользит к целевой высоте (вниз открыта / вверх закрыта).
	if _door != null:
		var goal_y: float = _door_open_y if _door_open else _door_closed_y
		var k: float = 1.0 - exp(-6.0 * delta)
		_door.position.y = lerpf(_door.position.y, goal_y, k)


## СНАП к платформе: груз подходящего размера, приземлившийся в snap-зоне
## (шире tol активации), плавно защёлкивается ровно в центр платформы —
## ставить броском проще, не надо целиться идеально. Притягиваем только
## лежащий/катящийся (низкий Y, не быстро летящий) и не несомый груз.
func _tick_cargo_snap(delta: float) -> void:
	if _platforms.is_empty():
		return
	for p in _platforms:
		var need: int = int(p.need)
		var cargo_side: float = 0.35 + 0.22 * float(need)
		var snap_r: float = float(p.tol) * 2.3
		var target := Vector3((p.pos as Vector3).x, 0.16 + cargo_side * 0.5, (p.pos as Vector3).z)
		for n in get_tree().get_nodes_in_group(CARGO_GROUP):
			if n == _cargo or not is_instance_valid(n):
				continue
			if n.get_meta(&"kind", &"cube") != &"cube":
				continue  # ингредиенты/бомба платформы не активируют
			if int(n.get_meta(&"need", 1)) != need:
				continue
			var rb := n as RigidBody3D
			if rb == null:
				continue
			var dx: float = rb.global_position.x - (p.pos as Vector3).x
			var dz: float = rb.global_position.z - (p.pos as Vector3).z
			if dx * dx + dz * dz > snap_r * snap_r:
				continue
			# Ещё летит высоко/быстро (брошен по дуге) — дать приземлиться,
			# не дёргать в воздухе (иначе снап читается как телепорт).
			if not rb.freeze and (rb.global_position.y > 1.2 or rb.linear_velocity.length() > 4.5):
				continue
			rb.freeze = true
			var k: float = 1.0 - exp(-10.0 * delta)
			rb.global_position = rb.global_position.lerp(target, k)
			break  # платформа держит один груз


## True если на платформе покоится груз с подходящим need (не тот, что несут).
func _platform_pressed(p: Dictionary) -> bool:
	for n in get_tree().get_nodes_in_group(CARGO_GROUP):
		if n == _cargo or not is_instance_valid(n):
			continue
		if n.get_meta(&"kind", &"cube") != &"cube":
			continue  # только кубы жмут платформы
		if int(n.get_meta(&"need", 1)) != int(p.need):
			continue
		var dx: float = n.global_position.x - p.pos.x
		var dz: float = n.global_position.z - p.pos.z
		if dx * dx + dz * dz <= float(p.tol) * float(p.tol):
			return true
	return false


## Средний разгон живых членов отряда (0..1).
func _avg_ramp() -> float:
	if _squad == null:
		return 0.0
	var sum: float = 0.0
	var n: int = 0
	for m in _squad.members:
		if is_instance_valid(m):
			sum += m.run_ramp()
			n += 1
	return sum / float(n) if n > 0 else 0.0


## Хвост кометы: на бегу слоты вытягиваются за точкой (длина с разгоном),
## на стопе/пине — штатное кольцо-«ёж». Направление хвоста СГЛАЖЕНО:
## мгновенный флип на резкой смене курса телепортировал слоты на
## противоположную сторону (до 4.5м) — гномы лютовали за ними врассыпную.
func _update_tail(lmb: bool, delta: float) -> void:
	if _squad == null:
		return
	if not lmb or _ramp_now < 0.15:
		_squad.tail_length = 0.0
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		_squad.tail_length = 0.0
		return
	var dir := Vector3(_squad.hold_position.x - c.x, 0.0, _squad.hold_position.z - c.z)
	if dir.length_squared() < 1.0:
		_squad.tail_length = 0.0
		return
	dir = dir.normalized()
	var prev: Vector3 = _squad.tail_dir
	if prev != Vector3.ZERO and _squad.tail_length > 0.0:
		var k: float = 1.0 - exp(-4.0 * delta)
		var blended: Vector3 = prev.lerp(dir, k)
		# Разворот ~180°: лерп схлопывается в ноль — берём новый курс сразу.
		if blended.length_squared() > 0.04:
			dir = blended.normalized()
	_squad.tail_dir = dir
	_squad.tail_length = tail_length_full * _ramp_now


## Пыль из-под ног на высоком разгоне — «заряжен» читается боковым зрением.
func _tick_dust(delta: float, moving: bool) -> void:
	_dust_timer -= delta
	# Пыль = «визг шин»: сыпется в скольжении и на тормозе.
	if not moving or not (_drifting or _braking) or _dust_timer > 0.0 or _squad == null:
		return
	_dust_timer = 0.12
	var alive: Array = []
	for m in _squad.members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.is_empty():
		return
	var m2: Node3D = alive[randi() % alive.size()]
	_spawn_soft_dust(Vector3(m2.global_position.x, 0.1, m2.global_position.z))


## Деликатный пых пыли: AoeVisual.spawn_dust — это slam-взрыв (72 частицы,
## «непонятно, что за взрывы» — фидбек), тут те же ассеты, но 4 мелкие
## частицы с коротким веком — лёгкий след, не событие.
func _spawn_soft_dust(pos: Vector3) -> void:
	var process_mat := load(AoeVisual.DUST_PROCESS_PATH) as ParticleProcessMaterial
	var dust_mat := load(AoeVisual.DUST_MATERIAL_PATH) as StandardMaterial3D
	if process_mat == null or dust_mat == null:
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var particles := GPUParticles3D.new()
	particles.process_material = process_mat
	particles.draw_pass_1 = quad
	particles.material_override = dust_mat
	particles.amount = 4
	particles.lifetime = 0.45
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.finished.connect(particles.queue_free)
	add_child(particles)
	particles.global_position = pos
	particles.emitting = true


func _unhandled_input(event: InputEvent) -> void:
	# Superhot: ЛКМ ловим СОБЫТИЕМ (разбор в _process). Мышь-события приходят
	# каждый рендер-кадр независимо от time_scale — клик чёткий даже в стоп-кадре.
	if superhot_mode and not _game_over:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_click_pending = true
			return
	# WASD: ПКМ = щит артельщика; ПРОБЕЛ = супер мили-класса. ⛔ Фокус-группы
	# 1/2/3 и клик-панч выпилены (2026-07-28): дальний бой работает всегда,
	# мили сжат в одну кнопку — переключать стало нечего.
	if wasd_mode and not _game_over:
		var wb := event as InputEventMouseButton
		if wb != null and wb.pressed and wb.button_index == MOUSE_BUTTON_RIGHT:
			_shield_pending = true
			return
		var sk_key := event as InputEventKey
		if sk_key != null and sk_key.pressed and not sk_key.echo \
				and sk_key.keycode == KEY_SPACE:
			_request_spear_super()
			return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_R:
		get_tree().reload_current_scene()
	elif key.keycode == KEY_T and not _game_over:
		if _director_active():
			_director_burst()
		else:
			_wave_timer = wave_interval
			_spawn_wave(true)
	elif key.keycode == KEY_E and not _game_over:
		_toggle_cargo()


## Пересечение луча курсора с плоскостью пола (math, без физики) + кламп в комнату.
func _cursor_ground_point() -> Vector3:
	if _camera == null:
		return Vector3.INF
	var mp: Vector2 = get_viewport().get_mouse_position()
	var origin: Vector3 = _camera.project_ray_origin(mp)
	var dir: Vector3 = _camera.project_ray_normal(mp)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(origin, dir)
	if hit == null:
		return Vector3.INF
	var p: Vector3 = hit
	p.x = clampf(p.x, room_center.x - room_half + 2.0, room_center.x + room_half - 2.0)
	p.z = clampf(p.z, cursor_z_min, cursor_z_max)
	return p


func _update_camera(delta: float, cursor: Vector3) -> void:
	var center: Vector3 = room_center
	if _squad != null:
		var c: Vector3 = _squad.compute_center()
		if c != Vector3.INF:
			center = c
		elif cursor != Vector3.INF:
			center = cursor
	var goal: Vector3 = center
	if cursor != Vector3.INF:
		goal = center.lerp(Vector3(cursor.x, 0.0, cursor.z), camera_cursor_bias)
	var k: float = 1.0 - exp(-camera_follow_speed * delta)
	_look_target = _look_target.lerp(goal, k)
	_camera.global_position = _camera.global_position.lerp(_look_target + camera_offset, k)
	# Микро-качка взгляда: aim — смесь «нулевой» точки (позиция минус offset,
	# даёт неподвижный ракурс) и живой догоняющей точки. camera_sway дозирует
	# амплитуду вращения, не меняя характер движения.
	var aim: Vector3 = (_camera.global_position - camera_offset).lerp(_look_target, camera_sway)
	_camera.look_at(aim, Vector3.UP)


## Superhot: тайм-скейл мира. Мишень = бо́льшее из (скорость_отряда / ref) и
## «пола шага» intent_floor, пока active (идёт шаг) — клик СРАЗУ поднимает мир,
## чтобы отряд шёл в нормальном темпе, а не раскачивался из стоп-кадра. Скейл
## сглаживается на РЕАЛЬНОМ (настенном) delta и правит ТОЛЬКО Engine.time_scale —
## враги, снаряды, кулдауны, огонь гномов и волны замедляются сами, без единой
## правки их скриптов. Шаг закончился (active=false) и отряд встал → мир застыл.
func _update_superhot(real_delta: float, active: bool) -> void:
	var speed_ratio: float = 0.0
	if _squad != null:
		var avg_v := Vector3.ZERO
		var n: int = 0
		for m in _squad.members:
			if is_instance_valid(m):
				avg_v += Vector3(m.velocity.x, 0.0, m.velocity.z)
				n += 1
		if n > 0:
			var spd: float = (avg_v / float(n)).length()
			speed_ratio = clampf(spd / maxf(superhot_ref_speed, 0.01), 0.0, 1.0)
	# Пол шага: пока идёт шаг → мир живёт хотя бы на intent_floor (мгновенный старт).
	var intent: float = superhot_intent_floor if active else 0.0
	var drive: float = maxf(speed_ratio, intent)
	var target: float = lerpf(superhot_min_scale, superhot_max_scale, drive)
	var ramp: float = superhot_ramp_up if target > _superhot_scale else superhot_ramp_down
	var k: float = 1.0 - exp(-ramp * real_delta)
	_superhot_scale = lerpf(_superhot_scale, target, k)
	Engine.time_scale = _superhot_scale


## Пошаговый Superhot, физическая половина: ТОЛЬКО мировые тики (те же, что у
## drift-пути — хвост осознанно продублирован, чтобы «тачка» осталась нетронутой)
## на scaled-темпе — замерзают вместе со временем. Контрол/прицел/камера — в
## _process (_superhot_control): физтики в заморозке редкие, им тут не место.
func _superhot_world_tick(delta: float) -> void:
	_tick_cargo(delta)
	_tick_cargo_snap(delta)
	_tick_door_puzzle(delta)
	_tick_spikes(delta)
	_tick_apparatus(delta)
	_tick_bomb(delta)
	_tick_barricades()
	if not _game_over:
		_update_active_room()
		if _active_room >= 0:
			_wave_timer -= delta
			if _wave_timer <= 0.0:
				_wave_timer = wave_interval
				_spawn_wave()


## Прицел + клик-ДЕЙСТВИЕ (рендер-частота, зовётся из _process). Поводок всегда
## виден от центра к курсору (обрезан по _effective_reach). КЛИК (событие из
## _unhandled_input) разбирается по цели ПОД ПРИЦЕЛОМ: есть → ЗАЛП С МЕСТА по ней
## (стоим, фокус-огонь, НЕ бежим в мили); нет → ХОД (шаг к точке, молча). Оба
## «оживляют» время (шаг ИЛИ залп); доехал/отстрелялся → мир замирает.
func _superhot_control(real_delta: float, cursor: Vector3) -> void:
	if _squad == null:
		return
	var c: Vector3 = _squad.compute_center()
	# Эффективный поводок = базовый reach минус вес несомого груза (meta "need"
	# 1/3/5): тяжелее → короче шаг И радиус выстрела (единая «длина действия»).
	# Пусто в руках → полный reach. Пол superhot_reach_min.
	var load_w: int = int(_cargo.get_meta(&"need", 1)) if _cargo != null else 0
	_effective_reach = maxf(superhot_reach - superhot_reach_weight_penalty * float(load_w), superhot_reach_min)
	# attack_range = поводок + пад на глубину строя (SH_RANGE_PAD): красный
	# поводок должен означать «стреляет ВЕСЬ отряд», включая задний ряд.
	for m in _squad.members:
		if is_instance_valid(m):
			m.attack_range = _effective_reach + SH_RANGE_PAD
	# Конец поводка-прицела (обрезан по эфф. reach). По умолчанию — текущая точка.
	var aim: Vector3 = _squad.hold_position
	if c != Vector3.INF and cursor != Vector3.INF:
		var to := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
		var d: float = to.length()
		if d > _effective_reach:
			to *= _effective_reach / d
		aim = Vector3(c.x, 0.0, c.z) + to
	_aim_point = aim
	# Цель под прицелом — ОДИН расчёт на кадр, им живут и клик, и подсветка
	# (что горит красным, ровно то и будет обстреляно — никаких расхождений).
	var tgt: Node3D = _aim_target(c)
	# КЛИК = ДЕЙСТВИЕ (событие не теряется даже в стоп-кадре).
	if _click_pending and c != Vector3.INF and not _game_over:
		if tgt != null:
			# Залп с места по КЛИКНУТОЙ цели: НЕ двигаемся, обрубаем недоезд.
			_shooting = true
			_shoot_timer = superhot_shoot_beat
			_shoot_target = tgt
			_step_moving = false
			for m in _squad.members:
				if is_instance_valid(m):
					m.force_stop()
		else:
			# Ходовой шаг (молча): точка едет, отряд трогается (время проснётся).
			_squad.hold_position = aim
			_banner.global_position = aim
			_step_moving = true
			_shooting = false
			_shoot_target = null
	_click_pending = false
	# Ход дошёл → чёткий стоп на точке.
	if _step_moving and c != Vector3.INF:
		var rem: float = Vector2(c.x - _squad.hold_position.x, c.z - _squad.hold_position.z).length()
		if rem <= superhot_arrive_dist:
			_step_moving = false
			for m in _squad.members:
				if is_instance_valid(m):
					m.force_stop()
	# Залп: world-секунды на рендер-частоте (real × time_scale). Кончился =
	# beat истёк ИЛИ кликнутая цель умерла → тихо, мир замрёт сам.
	if _shooting:
		_shoot_timer -= real_delta * Engine.time_scale
		if _shoot_timer <= 0.0 or not is_instance_valid(_shoot_target):
			_shooting = false
			_shoot_target = null
	# Огонь ТОЛЬКО во время залпа И ТОЛЬКО по КЛИКНУТОЙ цели (фокус через alarm-
	# override — НЕ «по зрению»/360°). Ход / прицел / простой — тишина.
	var allow_fire: bool = _shooting and is_instance_valid(_shoot_target)
	for m in _squad.members:
		if not is_instance_valid(m):
			continue
		m.fire_suppressed = not allow_fire
		if allow_fire and m.has_method(&"focus_fire"):
			m.call(&"focus_fire", _shoot_target, 0.3)
	_update_step_visuals(c, tgt)


## Поводок-прицел ВСЕГДА виден (линия центр→конец + кольцо на конце). Краснеет,
## только когда ПОД прицелом есть цель (tgt — тот же расчёт, что решает клик:
## красный = «клик будет залпом ровно по нему», без расхождений).
func _update_step_visuals(c: Vector3, tgt: Node3D) -> void:
	if _cmd_line == null or _cmd_ring == null or c == Vector3.INF or _aim_point == Vector3.INF:
		if _cmd_line != null:
			_cmd_line.visible = false
		if _cmd_ring != null:
			_cmd_ring.visible = false
		return
	_cmd_ring.visible = true
	_cmd_line.visible = true
	_cmd_ring.global_position = Vector3(_aim_point.x, 0.05, _aim_point.z)
	AoeVisual.update_ground_line(_cmd_line,
			Vector3(c.x, 0.0, c.z), Vector3(_aim_point.x, 0.0, _aim_point.z))
	var hot: bool = tgt != null
	var col: Color = Color(1.0, 0.32, 0.28, 1.0) if hot else CMD_COLOR
	var mat := _cmd_line.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = col
		mat.emission = Color(col.r, col.g, col.b, 1.0)
		mat.emission_energy_multiplier = 3.5 if hot else 2.0
	var rmat := _cmd_ring.material_override as StandardMaterial3D
	if rmat != null:
		rmat.albedo_color = col
		rmat.emission = Color(col.r, col.g, col.b, 1.0)


## Скелет, на которого «наведён» прицел: в пределах _effective_reach от центра И
## по направлению прицела (dot > 0.3), из подходящих — БЛИЖАЙШИЙ К ТОЧКЕ ПРИЦЕЛА
## (кликнул рядом с врагом → берётся именно он). null = прицел в пустоту.
## Скелет ПОД ПРИЦЕЛОМ: не дальше superhot_aim_snap от КОНЦА поводка И в
## _effective_reach от центра (досягаем). Прицел = ТОЧКА, не сектор: старый
## конус-детект (dot>0.3 ≈ полуугол 72°) в окружении находил врага в любую
## сторону — поводок горел красным постоянно, юзер отверг. Курсор в пределах
## поводка совпадает с его концом, так что «навёл НА врага» — буквально.
func _aim_target(c: Vector3) -> Node3D:
	if _aim_point == Vector3.INF or c == Vector3.INF:
		return null
	var reach_sq: float = _effective_reach * _effective_reach
	var snap_sq: float = superhot_aim_snap * superhot_aim_snap
	var best: Node3D = null
	var best_d: float = INF
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or not (sk is Node3D):
			continue
		var p: Vector3 = (sk as Node3D).global_position
		var dxc: float = p.x - c.x
		var dzc: float = p.z - c.z
		if dxc * dxc + dzc * dzc > reach_sq:
			continue
		var dxa: float = p.x - _aim_point.x
		var dza: float = p.z - _aim_point.z
		var d: float = dxa * dxa + dza * dza
		if d <= snap_sq and d < best_d:
			best_d = d
			best = sk
	return best


## WASD-модель, весь кадр: движение тела, полив, щит, мировые тики, камера.
## Хвост тиков продублирован с drift/superhot осознанно — три модели остаются
## независимыми путями, ломать одну ради другой нельзя.
func _wasd_physics(delta: float) -> void:
	var cursor: Vector3 = _cursor_ground_point()
	_wasd_move(delta, cursor)
	_wasd_combat(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _game_over, cursor)
	if _shield_pending:
		_shield_pending = false
		_try_place_shield(cursor)
	_tick_spear_super(delta)
	_tick_cargo(delta)
	_tick_cargo_snap(delta)
	_tick_door_puzzle(delta)
	_tick_spikes(delta)
	_tick_apparatus(delta)
	_tick_bomb(delta)
	_tick_barricades()
	if not _game_over:
		_update_active_room()
		if _active_room >= 0:
			if _director_active():
				_tick_director(delta)
			else:
				_wave_timer -= delta
				if _wave_timer <= 0.0:
					_wave_timer = wave_interval
					_spawn_wave()
	_update_camera(delta, cursor)


## Тело группы: WASD двигает точку строя, гномы штатно едут за ней черепахой
## (W = вглубь анфилады, −Z). Поводок WASD_LEASH: упёрлись в стену — точка не
## уезжает от строя в бесконечность. Отпустил — точка паркуется на центроиде
## (мёртвая зона 0.75м, тот же анти-фидбек-луп, что у drift-пути).
func _wasd_move(delta: float, cursor: Vector3) -> void:
	if _squad == null:
		return
	var v: Vector2 = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var c: Vector3 = _squad.compute_center()
	if v.length_squared() > 0.0001:
		var speed: float = wasd_speed * _backpedal_scale(Vector3(v.x, 0.0, v.y), c, cursor)
		var hp2: Vector3 = _squad.hold_position + Vector3(v.x, 0.0, v.y) * speed * delta
		hp2.x = clampf(hp2.x, room_center.x - room_half + 2.0, room_center.x + room_half - 2.0)
		hp2.z = clampf(hp2.z, cursor_z_min, cursor_z_max)
		if c != Vector3.INF:
			var off := Vector3(hp2.x - c.x, 0.0, hp2.z - c.z)
			if off.length() > WASD_LEASH:
				off = off.normalized() * WASD_LEASH
				hp2 = Vector3(c.x + off.x, 0.0, c.z + off.z)
		_squad.hold_position = hp2
		_banner.global_position = hp2
	elif c != Vector3.INF:
		var dxh: float = c.x - _squad.hold_position.x
		var dzh: float = c.z - _squad.hold_position.z
		if dxh * dxh + dzh * dzh > 0.5625:
			_squad.hold_position = Vector3(c.x, 0.0, c.z)
			_banner.global_position = _squad.hold_position


## ПРОБЕЛ: заявка на супер мили-класса. Гейт — состав отряда: нет живых
## копейщиков → нет способности (билд решает возможности). Замах не стопит
## группу: она продолжает идти и стрелять, кольцо-телеграф едет с ней.
func _request_spear_super() -> void:
	if _squad == null or _super_windup > 0.0 or _super_cd > 0.0:
		return
	if _alive_pikemen() <= 0:
		EventBus.tutorial_hint.emit("Нет копейщиков — удар вокруг недоступен", 1.6)
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	_super_windup = wasd_super_windup
	_super_ring = AoeVisual.spawn_ground_ring(self, c, wasd_super_radius, 0.0,
			Color(1.0, 0.55, 0.2, 0.9))


## Тик замаха: кольцо следует за группой (взрыв идёт по АКТУАЛЬНОМУ центру —
## иначе на ходу волна отставала бы от отряда), по нулю — удар.
func _tick_spear_super(delta: float) -> void:
	if _super_cd > 0.0:
		_super_cd = maxf(_super_cd - delta, 0.0)
	if _super_windup > 0.0:
		var c: Vector3 = _squad.compute_center() if _squad != null else Vector3.INF
		if is_instance_valid(_super_ring) and c != Vector3.INF:
			_super_ring.global_position = c
		_super_windup -= delta
		if _super_windup <= 0.0:
			_super_windup = 0.0
			_super_cd = wasd_super_cooldown
			if is_instance_valid(_super_ring):
				_super_ring.queue_free()
			_super_ring = null
			if c != Vector3.INF:
				_spear_super_blast(c)
	# HUD: тикающий отсчёт на карточке (раз в 0.1с — строки не жжём каждый кадр)
	# + мгновенная вспышка бордера на переходе «готов».
	var armed: bool = _super_cd <= 0.0 and _super_windup <= 0.0 and _alive_pikemen() > 0
	_super_hud_acc += delta
	if armed != _super_armed_prev or (not armed and _super_hud_acc >= 0.1):
		_super_armed_prev = armed
		_super_hud_acc = 0.0
		_refresh_focus_cards()


## УДАР ВОКРУГ = веер штатных панчей + ударная волна. Каждый живой копейщик
## физически выстреливает в СВОЮ ближайшую цель (punch_at: замах-хлыст-хитстоп-
## искры-отскок в строй — импакт-пакет, который уже отлажен), а по всем
## остальным в радиусе идёт волна: урон + отброс наружу. Не абстрактный круг
## урона, а «копейщиков выбросило во все стороны».
func _spear_super_blast(c: Vector3) -> void:
	var targets: Array = []
	var r_sq: float = wasd_super_radius * wasd_super_radius
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or not (sk is Node3D) or (sk as Node).is_queued_for_deletion():
			continue
		var to := Vector3((sk as Node3D).global_position.x - c.x, 0.0,
				(sk as Node3D).global_position.z - c.z)
		if to.length_squared() <= r_sq:
			targets.append(sk)
	# Каждому копейщику — своя цель (по кругу, если целей меньше, чем бойцов):
	# веер, а не куча-мала в одну точку.
	var idx: int = 0
	for m in _squad.members:
		if not is_instance_valid(m) or m.soldier_type != &"pikeman":
			continue
		if targets.is_empty() or not m.has_method(&"punch_at"):
			continue
		m.call(&"punch_at", targets[idx % targets.size()])
		idx += 1
	# Волна: урон + отброс наружу. hit_dir = от центра группы → направленный
	# shatter на добивании (§6.1 F1), осколки летят «от нас».
	for sk in targets:
		var to := Vector3((sk as Node3D).global_position.x - c.x, 0.0,
				(sk as Node3D).global_position.z - c.z)
		var dir: Vector3 = to.normalized() if to.length_squared() > 0.0001 \
				else Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
		Damageable.try_damage(sk, wasd_super_damage, 0.0, dir)
		if is_instance_valid(sk) and sk.has_method(&"apply_knockback"):
			sk.call(&"apply_knockback", dir * wasd_super_knockback + Vector3.UP * 2.0, 0.25)
	AoeVisual.spawn_expanding_ring(self, c, wasd_super_radius, 0.25,
			Color(1.0, 0.6, 0.25, 0.9))
	AoeVisual.spawn_dust(self, c)
	EventBus.camera_shake.emit(0.3, c)


func _alive_pikemen() -> int:
	if _squad == null:
		return 0
	var n: int = 0
	for m in _squad.members:
		if is_instance_valid(m) and m.soldier_type == &"pikeman":
			n += 1
	return n


## ОТХОД СПИНОЙ СТОИТ ТЕМПА: группа всегда развёрнута к курсору, поэтому шаг
## против взгляда — это пятиться задом, а не бежать. Множитель по dot(ход,
## прицел): вперёд ×1, назад ×wasd_backpedal_speed, вбок ровно между ними.
## Тормозим ТОЧКУ СТРОЯ, а не юнитов — группа остаётся одним телом, строй не
## растягивается. Даёт цену за кайт и делает разворот осмысленным решением.
func _backpedal_scale(move_dir: Vector3, center: Vector3, cursor: Vector3) -> float:
	if wasd_backpedal_speed >= 1.0 or center == Vector3.INF or cursor == Vector3.INF:
		return 1.0
	var aim := Vector3(cursor.x - center.x, 0.0, cursor.z - center.z)
	if aim.length_squared() < 0.01 or move_dir.length_squared() < 0.0001:
		return 1.0
	var d: float = move_dir.normalized().dot(aim.normalized())
	return lerpf(wasd_backpedal_speed, 1.0, (d + 1.0) * 0.5)


## Полив: пока ЛКМ зажат — лучники стреляют В НАПРАВЛЕНИИ курсора своим темпом
## (try_suppressive_fire: баллистика в точку, цель-нода НЕ нужна — стрелы летят
## в пустоту и бьют что заденут). Скелет на луче лишь УТОЧНЯЕТ точку (стрелы
## сходятся в него) и красит прицел. Авто-конус лучника заглушен ВСЕГДА
## (fire_suppressed) — огонь строго по прицелу игрока, «сам увидел — сам палит»
## в этой модели выключено. Копейщики мили с детектом-вплотную — их гейт не
## касается; артельщик не воюет. Полив ограничен КОЛЧАНОМ (wasd_quiver_size):
## пустой колчан молчит и не перезаряжается, пока ЛКМ зажат — см. блок
## «КОЛЧАН-ОБОЙМА» в ArcherSoldier.
func _wasd_combat(lmb: bool, cursor: Vector3) -> void:
	if _squad == null:
		return
	var c: Vector3 = _squad.compute_center()
	var tgt: Node3D = null
	var aim: Vector3 = Vector3.INF
	var aim_dir: Vector3 = Vector3.ZERO
	if c != Vector3.INF and cursor != Vector3.INF:
		var to_cur := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
		if to_cur.length_squared() > 0.01:
			aim_dir = to_cur.normalized()
		tgt = _ray_target(c, cursor)
		if tgt != null:
			aim = (tgt as Node3D).global_position
		elif aim_dir != Vector3.ZERO:
			# Точка полива на луче курсора, не дальше дальности; чуть над
			# полом — плоская дуга баллистики, стрела метёт по направлению.
			aim = Vector3(c.x, 0.4, c.z) + aim_dir * minf(to_cur.length(), gnome_attack_range)
	# ВСЯ ГРУППА разворачивается к курсору: строй (черепаха передом — ряды
	# грида поперёк tail_dir, копейщики в ряду 0) и тела (face_override —
	# смотрят на прицел и стоя, и на бегу). Строй — со сглаживанием: резкий
	# флип tail_dir телепортирует слоты, гномы бегали бы кругами за курсором.
	if aim_dir != Vector3.ZERO:
		if _squad.tail_dir == Vector3.ZERO:
			_squad.tail_dir = aim_dir
		else:
			_squad.tail_dir = _squad.tail_dir.slerp(aim_dir, minf(1.0, get_physics_process_delta_time() * 3.5)).normalized()
	# ГРУППА СТРЕЛЯЕТ ВСЕГДА (пивот 2026-07-28): огонь больше не гейтится ни
	# фокусом, ни зажатым ЛКМ — лучники поливают непрерывно ТУДА, КУДА СМОТРИТ
	# КУРСОР. Это не отвергнутый автобой: автоматика тут в ТЕМПЕ, ручное — в
	# НАПРАВЛЕНИИ (за спиной группа не бьёт), поэтому позиция и разворот
	# остаются работой игрока каждую секунду.
	var archers_focused: bool = true
	for m in _squad.members:
		if not is_instance_valid(m):
			continue
		m.face_override = aim_dir
		if m is ArcherSoldier:
			# fire_suppressed глушит АВТО-КОНУС («сам увидел — сам палит» ⛔):
			# огонь идёт только через try_suppressive_fire по прицелу игрока —
			# полная дальность и штатный темп, но строго в сектор курсора.
			m.fire_suppressed = archers_focused
			m.attack_range = gnome_attack_range
			m.attack_cooldown_min = gnome_cooldown_min
			m.attack_cooldown_max = gnome_cooldown_max
			if aim != Vector3.INF and m.has_method(&"try_suppressive_fire"):
				m.call(&"try_suppressive_fire", aim)
		elif m.soldier_type == &"pikeman":
			# Копейщики молчать между суперами не должны — иначе передний ряд
			# станет декорацией, а он телом держит толпу. Автоукол вплотную
			# (hold_ground + срезанный detect) живёт всегда, ручного клика нет.
			m.hold_ground = true
	_click_pending = false
	_update_wasd_visuals(c, cursor, tgt != null)


## Цель полива: скелет в дальности лучника от центра, в секторе прицела
## (dot ≥ wasd_aim_dot ≈ ±60°), из подходящих — ближайший к ЛУЧУ курсора
## (перпендикуляр до линии). Курсор ведёт огонь как стик: точного наведения
## на тело не нужно, но направление решает.
func _ray_target(c: Vector3, cursor: Vector3) -> Node3D:
	var dir := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
	if dir.length_squared() < 0.01:
		return null
	dir = dir.normalized()
	var range_sq: float = gnome_attack_range * gnome_attack_range
	var best: Node3D = null
	var best_off: float = INF
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or not (sk is Node3D):
			continue
		var to := Vector3((sk as Node3D).global_position.x - c.x, 0.0,
				(sk as Node3D).global_position.z - c.z)
		var dsq: float = to.length_squared()
		if dsq > range_sq or dsq < 0.0001:
			continue
		if dir.dot(to / sqrt(dsq)) < wasd_aim_dot:
			continue
		var off: float = (to - dir * to.dot(dir)).length()
		if off < best_off:
			best_off = off
			best = sk
	return best


## ПКМ: артельщик выставляет щит-плашку между группой и курсором (поперёк
## направления). Живых щитов не больше живых артельщиков — сломали/умер мастер
## → слот меняется. Щит ломаем скелетами-мили (ArtelShield: TARGET_GROUP).
func _try_place_shield(cursor: Vector3) -> void:
	if _squad == null:
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF or cursor == Vector3.INF:
		return
	var artel: int = 0
	for m in _squad.members:
		if is_instance_valid(m) and m.soldier_type == &"worker":
			artel += 1
	_shields = _shields.filter(func(s): return is_instance_valid(s))
	if artel <= 0 or _shields.size() >= artel:
		return
	var dir := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var shield := ArtelShield.new()
	add_child(shield)
	shield.setup(wasd_shield_size, wasd_shield_hp)
	shield.global_position = Vector3(c.x, wasd_shield_size.y * 0.5, c.z) + dir * wasd_shield_dist
	shield.rotation.y = atan2(dir.x, dir.z)
	_shields.append(shield)
	AoeVisual.spawn_ground_ring(self,
			Vector3(shield.global_position.x, 0.0, shield.global_position.z),
			1.2, 0.4, Color(0.9, 0.7, 0.3, 0.9))


## Прицел WASD: линия от центра в сторону курсора (обрезана по дальности
## лучника), красная — полив реально бьёт (цель под лучом есть).
func _update_wasd_visuals(c: Vector3, cursor: Vector3, hot: bool) -> void:
	if _cmd_line == null or _cmd_ring == null or c == Vector3.INF or cursor == Vector3.INF:
		return
	var to := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
	var d: float = to.length()
	if d > gnome_attack_range and d > 0.001:
		to *= gnome_attack_range / d
	var tip := Vector3(c.x + to.x, 0.0, c.z + to.z)
	_cmd_line.visible = true
	_cmd_ring.visible = true
	_cmd_ring.global_position = Vector3(tip.x, 0.05, tip.z)
	AoeVisual.update_ground_line(_cmd_line, Vector3(c.x, 0.0, c.z), tip)
	var col: Color = Color(1.0, 0.32, 0.28, 1.0) if hot else CMD_COLOR
	var mat := _cmd_line.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = col
		mat.emission = Color(col.r, col.g, col.b, 1.0)
		mat.emission_energy_multiplier = 3.5 if hot else 2.0
	var rmat := _cmd_ring.material_override as StandardMaterial3D
	if rmat != null:
		rmat.albedo_color = col
		rmat.emission = Color(col.r, col.g, col.b, 1.0)


func _exit_tree() -> void:
	# Не утащить замедленное время в другие сцены/редактор.
	if superhot_mode:
		Engine.time_scale = 1.0


## Активная комната = та, в чьём полу (±26 по Z) стоит центроид отряда.
## В коридоре между комнатами — -1 (волны на паузе). Смена → сброс таймера
## (первая волна новой комнаты через wave_interval, не мгновенно).
func _update_active_room() -> void:
	if _squad == null:
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	var now: int = -1
	for i in range(_room_z.size()):
		if absf(c.z - float(_room_z[i])) <= 26.0:
			now = i
			break
	if now != _active_room:
		_active_room = now
		if now >= 0:
			_wave_timer = wave_interval
			print("[DungeonSandbox] активная комната → Room%d (волны здесь)" % (now + 1))
			# Новая комната встречает так же, как старт забега: пачка сразу, без
			# пустой паузы. Возврат в начатую/зачищенную — тихо (бюджет уже тронут).
			if _director_active() and int(_room_spawned.get(now, 0)) == 0:
				_director_timer = director_drip_interval
				var pack_half: int = director_start_pack / 2
				_spawn_cluster(pack_half, director_start_radius)
				_spawn_cluster(director_start_pack - pack_half, director_start_radius)


func _spawn_wave(force: bool = false) -> void:
	if skeleton_scene == null:
		push_warning("[DungeonSandbox] skeleton_scene не задан")
		return
	# Лимит волн на комнату: выдала свои — затихает навсегда (force = чит T).
	if not force and room_wave_limit > 0 and _active_room >= 0 \
			and int(_room_waves.get(_active_room, 0)) >= room_wave_limit:
		return
	if _active_room >= 0:
		_room_waves[_active_room] = int(_room_waves.get(_active_room, 0)) + 1
	_wave_number += 1
	var count: int = wave_base_count + wave_growth * (_wave_number - 1)
	var alive: int = _alive_skeletons()
	count = mini(count, maxi(max_alive_skeletons - alive, 0))
	for i in range(count):
		_spawn_skeleton_at(_edge_spawn_point())
	var c: Vector3 = _squad.compute_center() if _squad != null else Vector3.INF
	print("[DungeonSandbox] волна %d: +%d скелетов, отряд @ (%.1f, %.1f), цель @ (%.1f, %.1f)"
			% [_wave_number, count, c.x, c.z, _squad.hold_position.x, _squad.hold_position.z])
	_update_labels()


## Один скелет в точке — общее тело спавна для волн И директора (настройки
## LOD/телесности/цели/сигнала живут в ОДНОМ месте). `kind` = ключ-цель:
## параметризованный ШТАТНЫЙ Skeleton, не новый класс (ПЕРЕИСПОЛЬЗУЙ, не плоди).
func _spawn_skeleton_at(pos: Vector3, kind: StringName = &"grunt") -> void:
	var sk := skeleton_scene.instantiate() as Node3D
	if sk == null:
		return
	# LOD выключен по той же причине, что у гномов (см. _spawn_squad):
	# FAR-скелет отключает коллизии и ходит сквозь стены.
	sk.set(&"lod_far_distance", 100000.0)
	sk.set(&"lod_offscreen_half_angle_deg", 90.0)
	# Зеркало телесности: скелет упирается в гномов, а не проходит сквозь.
	# Через extra_collision_mask — простое `|=` затиралось бы
	# Skeleton._apply_lod_physics_mode на LOD-переходах.
	sk.set(&"extra_collision_mask", Layers.FRIENDLY_UNIT)
	if sk is CollisionObject3D:
		(sk as CollisionObject3D).collision_mask |= Layers.FRIENDLY_UNIT
	_apply_kind(sk, kind)
	add_child(sk)
	sk.global_position = pos
	var target: Node3D = _random_alive_gnome()
	if target != null and sk.has_method(&"set_forced_target"):
		sk.call(&"set_forced_target", target)
	if sk.has_signal(&"destroyed"):
		sk.connect(&"destroyed", _on_skeleton_died)


## Ключ-цель = статы + ОДНА читаемая деталь силуэта (декор-ребёнок, а не scale/
## перекраска корня: hit-flash, scale-punch и shatter скелета остаются как есть).
## Вызывать ДО add_child — Skeleton кэширует часть параметров в _ready.
func _apply_kind(sk: Node3D, kind: StringName) -> void:
	match kind:
		&"shieldman":
			# Медленный танк, которого не берут стрелы: ждёт панча копейщика.
			sk.set(&"arrow_proof", true)
			sk.set(&"hp", 45.0)
			sk.set(&"move_speed", 1.5)
			_add_kind_decor(sk, Vector3(1.15, 1.25, 0.16), Vector3(0.0, 0.95, -0.55),
					Color(0.22, 0.26, 0.34))
		&"runner":
			# Хилый спринтер в спину: цена за «стою и лью вперёд».
			sk.set(&"hp", 16.0)
			sk.set(&"move_speed", 4.6)
			_add_kind_decor(sk, Vector3(0.18, 0.5, 0.18), Vector3(0.0, 1.5, 0.0),
					Color(0.95, 0.45, 0.12))
		_:
			pass


## Деталь силуэта ключ-цели: unshaded-коробка на теле (щит спереди / гребень
## сверху). Локальный −Z = «вперёд» скелета (он делает look_at по ходу).
func _add_kind_decor(sk: Node3D, size: Vector3, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sk.add_child(mi)


## Живые скелеты. Через is_queued_for_deletion: destroyed.emit летит ДО
## queue_free, «мёртвый» кадр ещё числится в группе и раздувал бы давление.
func _alive_skeletons() -> int:
	var n: int = 0
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if is_instance_valid(sk) and not (sk as Node).is_queued_for_deletion():
			n += 1
	return n


func _director_active() -> bool:
	return wasd_mode and director_enabled and skeleton_scene != null


## Кривая давления: сколько живых держим прямо сейчас (линейно start → peak за
## director_ramp_time секунд ПОД ДАВЛЕНИЕМ в этой комнате).
func _director_target() -> float:
	if _active_room < 0:
		return 0.0
	var t: float = float(_room_time.get(_active_room, 0.0))
	return lerpf(director_pressure_start, director_pressure_peak,
			clampf(t / maxf(director_ramp_time, 0.001), 0.0, 1.0))


## Долив до кривой: не «пачка раз в N секунд», а «на арене всегда столько,
## сколько велит кривая». Бюджет комнаты кончился → тишина и «отбито ✓».
func _tick_director(delta: float) -> void:
	_room_time[_active_room] = float(_room_time.get(_active_room, 0.0)) + delta
	_director_timer -= delta
	if _director_timer > 0.0:
		return
	_director_timer = director_drip_interval
	var budget_left: int = director_room_budget - int(_room_spawned.get(_active_room, 0))
	if budget_left <= 0:
		return
	var alive: int = _alive_skeletons()
	var lack: int = int(ceilf(_director_target())) - alive
	if lack <= 0:
		return
	var n: int = mini(mini(lack, director_drip_max), budget_left)
	n = mini(n, maxi(max_alive_skeletons - alive, 0))
	_spawn_cluster(n, director_spawn_radius, _pick_kind())


## Чит T в режиме директора: внеплановая куча СВЕРХ бюджета (проверить пик).
func _director_burst() -> void:
	_spawn_cluster(maxi(director_drip_max * 2, 1), director_spawn_radius, _pick_kind(), false)


## Тип кучи по долям + гейт по времени в комнате (DK `minRunWeight`): ключ-цели
## входят не с первой секунды — сперва игрок осваивает полив.
func _pick_kind() -> StringName:
	var t: float = float(_room_time.get(_active_room, 0.0))
	var roll: float = randf()
	var acc: float = 0.0
	if t >= director_shieldman_after:
		acc += director_shieldman_share
		if roll < acc:
			return &"shieldman"
	if t >= director_runner_after:
		acc += director_runner_share
		if roll < acc:
			return &"runner"
	return &"grunt"


## Куча из n скелетов ОДНОГО типа: один угол на кучу + мелкий разброс → приходят
## узлом, а не поодиночке с четырёх сторон. Сектор — фронтовой; бегуны заходят
## С ТЫЛА (фронт + 180°), поэтому «стоять и лить вперёд» перестаёт быть даром.
func _spawn_cluster(n: int, radius: float, kind: StringName = &"grunt",
		count_budget: bool = true) -> void:
	if n <= 0 or skeleton_scene == null or _active_room < 0:
		return
	var front: Vector3 = director_front_dir
	if front.length_squared() < 0.0001:
		front = Vector3.FORWARD
	if kind == &"runner":
		front = -front
	var base_ang: float = atan2(front.z, front.x) \
			+ deg_to_rad(randf_range(-director_front_arc_deg, director_front_arc_deg))
	var cz: float = float(_room_z[_active_room])
	for i in range(n):
		var a: float = base_ang \
				+ deg_to_rad(randf_range(-director_cluster_spread_deg, director_cluster_spread_deg))
		var r: float = radius * randf_range(0.85, 1.0)
		var edge: float = room_half - 2.5
		var p := Vector3(
				clampf(room_center.x + cos(a) * r, room_center.x - edge, room_center.x + edge),
				0.6,
				clampf(cz + sin(a) * r, cz - edge, cz + edge))
		_spawn_skeleton_at(p, kind)
	if count_budget:
		_room_spawned[_active_room] = int(_room_spawned.get(_active_room, 0)) + n
	print("[Director] Room%d +%d %s (живых %d, кривая %.1f, выдано %d/%d)"
			% [_active_room + 1, n, kind, _alive_skeletons(), _director_target(),
			int(_room_spawned.get(_active_room, 0)), director_room_budget])
	_update_labels()


## Случайная точка у внутренней кромки случайной стены АКТИВНОЙ комнаты
## (наземный Y) — волны лезут из стен той комнаты, где сейчас отряд.
func _edge_spawn_point() -> Vector3:
	var rz: float = float(_room_z[_active_room]) if _active_room >= 0 else room_center.z
	var t: float = randf_range(-room_half + 3.0, room_half - 3.0)
	var edge: float = room_half - 2.5
	var local: Vector3
	match randi() % 4:
		0: local = Vector3(t, 0.6, -edge)
		1: local = Vector3(t, 0.6, edge)
		2: local = Vector3(-edge, 0.6, t)
		_: local = Vector3(edge, 0.6, t)
	return Vector3(room_center.x, 0.0, rz) + local


func _random_alive_gnome() -> Node3D:
	if _squad == null:
		return null
	var alive: Array = []
	for m in _squad.members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.is_empty():
		return null
	return alive[randi() % alive.size()]


func _alive_gnomes() -> int:
	return _squad.count_alive() if _squad != null else 0


func _on_gnome_died() -> void:
	print("[DungeonSandbox] гном пал, осталось %d" % _alive_gnomes())
	_update_labels()
	_refresh_focus_cards()
	if _alive_gnomes() <= 0 and not _game_over:
		_game_over = true
		print("[DungeonSandbox] отряд погиб (волна %d, убито %d)" % [_wave_number, _kills])
		($HUD/Center/GameOverLabel as Label).visible = true


func _on_skeleton_died() -> void:
	_kills += 1
	_update_labels()
	# Deferred: destroyed.emit летит ДО queue_free умирающего (Enemy.take_damage) —
	# синхронная проверка посчитала бы его живым и последний килл не закрывал бы
	# комнату. К концу кадра он уже помечен на удаление.
	call_deferred(&"_check_room_cleared")


## «Комната отбита»: лимит волн выпущен и живых скелетов не осталось → разовый
## флаг + салют в WaveLabel («путь свободен» — дальше игрок открывает дверь
## штатным пазлом). Волны следующей комнаты оживят лейбл обычным «Волна: N».
func _check_room_cleared() -> void:
	if _active_room < 0:
		return
	if _room_cleared.get(_active_room, false):
		return
	# Директор: комната отбита, когда ВЫДАН весь её бюджет (аналог лимита волн).
	if _director_active():
		if int(_room_spawned.get(_active_room, 0)) < director_room_budget:
			return
	else:
		if room_wave_limit <= 0:
			return
		if int(_room_waves.get(_active_room, 0)) < room_wave_limit:
			return
	if _alive_skeletons() > 0:
		return
	_room_cleared[_active_room] = true
	print("[DungeonSandbox] Room%d зачищена (выдано: %d, убито всего: %d)"
			% [_active_room + 1,
			int(_room_spawned.get(_active_room, 0)) if _director_active() else room_wave_limit,
			_kills])
	_update_labels()


func _update_labels() -> void:
	var wave_txt: String = "Волна: %d" % _wave_number
	if _director_active() and _active_room >= 0:
		# «Волна N» в режиме директора не значит ничего: показываем натиск
		# (живых / сколько велит кривая) и остаток бюджета комнаты.
		wave_txt = "Натиск: %d/%d · в запасе %d" % [
				_alive_skeletons(), int(ceilf(_director_target())),
				maxi(director_room_budget - int(_room_spawned.get(_active_room, 0)), 0)]
	if _active_room >= 0 and _room_cleared.get(_active_room, false):
		wave_txt = "Волны отбиты ✓ — путь свободен"
	($HUD/Panel/Rows/WaveLabel as Label).text = wave_txt
	($HUD/Panel/Rows/SquadLabel as Label).text = "Гномов: %d / %d" % [_alive_gnomes(), squad_size]
	($HUD/Panel/Rows/KillLabel as Label).text = "Убито: %d" % _kills
	var cargo_txt: String = "Груз: —"
	if _cargo != null:
		cargo_txt = "Груз: несут %d (стволов −%d)" % [_haulers.size(), _haulers.size()]
	($HUD/Panel/Rows/CargoLabel as Label).text = cargo_txt
	var craft_txt: String
	if _wood_broken:
		craft_txt = "Бомба: дверь взорвана ✓"
	elif _bomb != null:
		craft_txt = "Бомба готова — к деревянной двери!"
	else:
		craft_txt = "Ингредиенты: %d / %d" % [_collected, INGREDIENTS_NEEDED]
	var cl := $HUD/Panel/Rows.get_node_or_null("CraftLabel") as Label
	if cl != null:
		cl.text = craft_txt
