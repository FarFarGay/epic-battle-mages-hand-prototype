extends Node
## Глобальный event bus. Регистрируется как autoload в project.godot под именем `EventBus`.
## Сущности эмитят свои локальные сигналы И перенаправляют их сюда — UI / звук /
## статистика подписываются один раз на нужный глобальный сигнал, не зная про
## конкретные инстансы.
##
## Конвенция именования: <entity>_<event>(args).
## Локальные сигналы entity-классов остаются прежними — bus не их замена,
## а параллельный канал для cross-cutting слушателей.

# --- Item ---
signal item_damaged(item: Item, amount: float)
signal item_destroyed(item: Item)

# --- Enemy ---
signal enemy_damaged(enemy: Enemy, amount: float)
signal enemy_destroyed(enemy: Enemy)

# --- Tower ---
signal tower_damaged(amount: float)
signal tower_destroyed

# --- Hand: захват / бросок / способности ---
signal hand_grabbed(item: Item)
signal hand_released(item: Item, velocity: Vector3)
signal hand_slammed(position: Vector3, radius: float)
signal hand_flicked(target: Item, velocity: Vector3)
