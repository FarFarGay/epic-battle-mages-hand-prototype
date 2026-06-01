class_name BallisticConfig
extends Resource
## Параметры баллистики снаряда (boost + homing) для заклинаний.
## Используется Fireball / FrostBolt / Firestorm-серией — все три летят
## одной и той же двухфазной траекторией («arc up → homing in»),
## отличаются только AOE-эффектом импакта.
##
## Дизайнерский флоу:
## - [code]resources/ballistic_default.tres[/code] — shared baseline для всех
##   трёх заклинаний. Изменение в инспекторе одного .tres-файла
##   автоматически меняет полёт всех заклинаний, ссылающихся на этот ресурс.
## - Хочешь per-spell override — создай дубль .tres'ки и подсунь в
##   `ballistics`-слот конкретного заклинания вместо общего.
##
## До 2026-06-01 эти параметры дублировались как 10 @export'ов в каждом из
## трёх HandSpell* координаторов (см. этап 53). Объединение через ресурс
## устраняет copy-paste и даёт live-tuning через .tres.

@export_group("Boost (стартовая дуга)")
## Длительность boost-фазы (баллистика снизу-вверх с slight forward + sway).
## После — HOMING.
@export var boost_duration: float = 0.18
## Стартовая вертикальная скорость boost'а.
@export var boost_velocity_up: float = 7.0
## Стартовая горизонтальная скорость boost'а в направлении цели.
@export var boost_velocity_forward: float = 3.0
## Гравитация boost-фазы.
@export var boost_gravity: float = 14.0
## Амплитуда случайного бокового sway'я. Каждый каст уходит вбок на
## ±[0; это значение].
@export var boost_drift_velocity: float = 2.8

@export_group("Homing (полёт в цель)")
## Стартовая скорость homing-фазы.
@export var homing_initial_speed: float = 8.0
## Линейное ускорение в homing-фазе.
@export var homing_acceleration: float = 100.0
## Cap скорости.
@export var homing_max_speed: float = 55.0
## Drift-угол на старте homing'а, градусы. Velocity отклоняется от
## desired-direction на random ±[0; это значение] вокруг UP.
@export_range(0.0, 80.0) var homing_drift_angle_deg: float = 45.0
## Скорость возврата к target-direction (exp-decay rate).
@export_range(1.0, 30.0) var homing_turn_rate: float = 3.5
