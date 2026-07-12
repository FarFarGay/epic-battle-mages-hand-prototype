class_name FireLabBlueprint
extends CastleBlueprint
## ЧЕРТЁЖ КАФЕДРЫ ОГНЯ (сюжет «Верхний Предел»; файл исторически
## keystone_element — раньше тут были Ключ-плита Врат и Аккумулятор звёздной
## энергии). Хранится в заброшенном храме на каньоне (комната «Разлом»):
## добыча = экзамен руки+гарпуна (стащить блок-мост через ущелье, переехать,
## забрать). ПИВОТ 2026-07-12 («прогрессия к самой башне»): это ЧЕРТЁЖ —
## рука кладёт его на ВЕРХ БАШНИ (язык [CastleBlueprint]) → карта «Кафедра
## огня» уходит в колоду стройки НАСОВСЕМ ([PlayerProfile.grant_blueprint],
## сейв). Сама кафедра — здание-БАФ огненной школы: пока стоит, открыт
## Огненный шквал и Искра работает Молнией (см. PadBuilding.refresh_lab_spells).
##
## Весь жизненный цикл (grab, снап к верху башни, растворение) — от
## [CastleBlueprint]; здесь только цвета огня и эффект изучения.


func _ready() -> void:
	sheet_color = Color(1.0, 0.5, 0.2)   # огненная «синька» — школа читается цветом
	model_color = Color(1.0, 0.72, 0.3)
	super()


## Башня изучила чертёж → карта Кафедры огня в колоде навсегда (профиль + сейв).
func _on_learned() -> void:
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	if prof != null and prof.has_method(&"grant_blueprint"):
		prof.call(&"grant_blueprint", RoomBuildings.PAD_FIRE_LAB)
	else:
		EventBus.blueprint_granted.emit(RoomBuildings.PAD_FIRE_LAB)  # без профиля — хотя бы на заезд
	EventBus.tutorial_hint.emit(
		"📐 Чертёж изучен! Карта «🔥 Кафедра огня» — в колоде башни НАВСЕГДА: строй её, пока стоит — Шквал и Молния", 8.0)
