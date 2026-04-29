extends CanvasLayer
## Игровой HUD. Слева — индикаторы способностей (1=хлоп, 2=щелк), справа —
## статус лагеря (гномы / лучники / уровень=число палаток). Под PerfHud,
## который сидит на (10, 10..70). Сцена самодостаточна, ссылка на Camp
## приходит через @export_node_path.
##
## Обновление по таймеру 0.25с — счётчики не нужно дёргать каждый кадр,
## а спам set_text на Label провоцирует ненужный re-layout. Heat у HUD'а
## пренебрежимый: 1 проход по _gnomes/_parts Camp'а раз в 0.25с.

const UPDATE_INTERVAL: float = 0.25

@export_node_path("Camp") var camp_path: NodePath

@onready var _gnome_count_label: Label = $RightPanel/Margin/VBox/GnomeRow/CountLabel
@onready var _defender_count_label: Label = $RightPanel/Margin/VBox/DefenderRow/CountLabel
@onready var _tent_count_label: Label = $RightPanel/Margin/VBox/TentRow/CountLabel

var _camp: Camp
var _update_timer: float = 0.0


func _ready() -> void:
	if not camp_path.is_empty():
		_camp = get_node_or_null(camp_path) as Camp
	_update_counts()


func _process(delta: float) -> void:
	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_counts()
		_update_timer = UPDATE_INTERVAL


func _update_counts() -> void:
	if _camp == null or not is_instance_valid(_camp):
		_gnome_count_label.text = "—"
		_defender_count_label.text = "—"
		_tent_count_label.text = "—"
		return
	_gnome_count_label.text = "%d" % _camp.gatherer_count()
	_defender_count_label.text = "%d" % _camp.defender_count()
	_tent_count_label.text = "%d" % _camp.tent_count_alive()
