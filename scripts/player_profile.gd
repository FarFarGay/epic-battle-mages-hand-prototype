extends Node
## Профиль игрока: имя из Торговой Хартии + МЕЖМАТЧЕВАЯ прогрессия башни
## (пивот 2026-07-12 «прогрессия к самой башне»):
##   - СВИТКИ: выученные заклинания (свиток огня из пещеры → фаербол НАВСЕГДА,
##     со следующего матча открыт со старта);
##   - ЧЕРТЕЖИ: карты зданий, добавленные в колоду стройки НАСОВСЕМ (чертёж
##     Кафедры огня из храма → карта в DECK_RECIPE каждого заезда).
## Свитки/чертежи сохраняются на диск (user://tower_profile.cfg) и переживают
## рестарт. Остальные флаги (знание строек, камнеметатель) — на сессию:
## это туториал-прогресс заезда, не башни.
##
## Узел в сцене, ищется через группу GROUP.

const GROUP := &"player_profile"
const SAVE_PATH := "user://tower_profile.cfg"

var player_name: String = ""

## Прогресс-флаги гномов-строителей (Room6). Живут здесь — это singleton'-узел
## прогресса игрока, до которого диалоги/HUD уже дотягиваются через GROUP.
## - building_unlocked: запущен станок в Room11 → меню стен/башен открыто.
## - stone_thrower_defeated: убит камнеметатель → у гномов Room6 доступен найм лучников.
var building_unlocked: bool = false
var stone_thrower_defeated: bool = false

## СВИТКИ башни: spell id (String) → true. Заклинание выучено навсегда —
## применяется в _ready через SpellSystem.unlock и никогда не лочится кафедрами
## (гейт в PadBuilding.refresh_lab_spells).
var scrolls: Dictionary = {}
## ЧЕРТЕЖИ башни: building id (String, ключ RoomBuildings.CATALOG) с повторами —
## каждый чертёж = одна карта в колоде заезда (HUD читает в _deck_init).
var blueprints: Array = []


func _ready() -> void:
	add_to_group(GROUP)
	_load()
	# Выученные свитки — в SpellSystem сразу (autoload готов раньше сцены).
	for id in scrolls:
		SpellSystem.unlock(StringName(String(id)))


## Свиток выучен: заклинание открыто НАВСЕГДА (в профиль + SpellSystem + сейв).
## Идемпотентно.
func learn_scroll(spell_id: StringName) -> void:
	if scrolls.has(String(spell_id)):
		return
	scrolls[String(spell_id)] = true
	SpellSystem.unlock(spell_id)
	_save()


## Заклинание выучено свитком (кафедры-бафы такое не лочат при сносе).
func has_scroll(spell_id: StringName) -> bool:
	return scrolls.has(String(spell_id))


## Чертёж найден: карта здания уходит в колоду НАСОВСЕМ. Дубликаты допустимы
## (второй чертёж = вторая карта). Эмитит blueprint_granted — живая колода
## текущего заезда вставляет карту сразу.
func grant_blueprint(building_id: StringName) -> void:
	blueprints.append(String(building_id))
	_save()
	EventBus.blueprint_granted.emit(building_id)


## Список building id чертежей (String, с повторами) — для сборки колоды.
func blueprint_ids() -> Array:
	return blueprints


## Открыть знание о постройках (idempotent). Зовёт BlueprintMachine на запуске
## станка. HUD/диалоги читают флаг поллингом (prof.get(&"building_unlocked")).
func unlock_building() -> void:
	building_unlocked = true


## Отметить победу над камнеметателем (idempotent) — открывает найм лучников Room6.
func mark_stone_thrower_defeated() -> void:
	stone_thrower_defeated = true


func is_signed() -> bool:
	return not player_name.strip_edges().is_empty()


func sign_name(n: String) -> void:
	player_name = n.strip_edges()


## Имя если подписано, иначе default (для {name} до подписи Хартии).
func display_name(default_name: String) -> String:
	return player_name if is_signed() else default_name


# --- Сейв/лоад (только межматчевое: свитки + чертежи) ---

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("tower", "scrolls", scrolls.keys())
	cfg.set_value("tower", "blueprints", blueprints)
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		push_warning("[PlayerProfile] не удалось сохранить профиль (%d)" % err)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return  # первого запуска сейва нет — норма
	scrolls.clear()
	for id in cfg.get_value("tower", "scrolls", []):
		scrolls[String(id)] = true
	blueprints = []
	for id in cfg.get_value("tower", "blueprints", []):
		blueprints.append(String(id))
