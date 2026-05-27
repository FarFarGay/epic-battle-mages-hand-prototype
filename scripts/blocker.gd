class_name Blocker
extends StaticBody3D
## Greybox-блокер для прототипирования уровней. Заглушка под будущий
## ассет: холм, скала, обломок крепости, поваленное дерево — всё, что
## нужно дизайнеру для проработки путей, укрытий и силуэтов карты до
## того, как появится финальная геометрия.
##
## **Дизайнерская роль:** drag-n-drop из FileSystem-дока в main.tscn.
## Кит из 4 типов с одним материалом-серышом — отличаются формой,
## не цветом (классика greybox'а: читается через объём, не через окрас).
## Сетка 1м, pivot у основания (y=0 → блокер «стоит на земле»).
##
## **Физика:** на слоях `CAMP_OBSTACLE | PALISADE_OBSTACLE` — скелеты
## упираются (MASK_SKELETON включает CAMP_OBSTACLE), вражеские стрелы
## блокируются (MASK_HOSTILE_PROJECTILE включает PALISADE_OBSTACLE) —
## блокер сразу даёт укрытие. Hand-actions (slam/flick/grab) игнорируют
## его через [HAND_IMMUNE_GROUP] — greybox не должен ломаться/уноситься.
##
## **NavMesh:** в группе `navmesh_source` — Wall/Pillar/Block/Hill
## вырезают кусок навмеша, агенты их огибают. Hill (плато 6×1.5×6) сам
## по себе непроходим (боковые грани 1.5м > agent_max_climb=0.5). Чтобы
## агенты залезли наверх — пристыковай **Ramp** (пандус 4×1.5×4, тот же
## уровень высоты) одной из коротких сторон к холму. Уклон 1.5/4 = 21°,
## ~8 voxel-ячеек по длине, шаг ~0.19м — навмеш связывается. Несколько
## пандусов с разных сторон → подъём с любого направления.
##
## **Стыковка Hill + Ramp:** Hill вершиной на y=1.5, Ramp той же высоты.
## Ставь Ramp короткой стороной (по Z) вплотную к Hill, низкая сторона
## пандуса направлена «наружу» (поворачивай scene по Y хоткеем `E` чтобы
## развернуть пандус в нужную сторону).
##
## **Сетка в редакторе:** включи `View → Use Snap` (Y) и поставь
## `Translate Snap = 1.0` в `Configure Snap` — все блокеры лягут на
## целочисленные координаты, легко выравнивать в ряды/сетки.

const HAND_IMMUNE_GROUP := &"hand_immune"
const SLAM_DAMAGE_IMMUNE_GROUP := &"slam_damage_immune"
const NAVMESH_SOURCE_GROUP := &"navmesh_source"


func _ready() -> void:
	add_to_group(HAND_IMMUNE_GROUP)
	add_to_group(SLAM_DAMAGE_IMMUNE_GROUP)
	add_to_group(NAVMESH_SOURCE_GROUP)
