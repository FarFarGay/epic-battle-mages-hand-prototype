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
