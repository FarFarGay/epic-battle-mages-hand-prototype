class_name CampCollectionPlan
extends RefCounted
## База приоритетов сбора ресурсов лагерем — нормализованные веса по 4 типам
## (WOOD/STONE/IRON/FOOD), без stock-балансировки. План задаётся игроком
## через JournalPanel («План сбора»), читается гномами при выборе цели.
##
## **Что НЕ здесь:** stock-балансировка (вес ÷ (1 + stock/scale)²) живёт в
## [Camp.get_collection_priority_weight] — она зависит от `Camp.economy` и
## концептуально это «эффективный вес», который меняется без участия игрока.
## План — это «чистая воля игрока».
##
## Базовый pattern для дальнейшего Camp split'а: вынесли изолированную
## подсистему как RefCounted, Camp делегирует методы и слушает `weights_changed`
## для re-emit'а на EventBus. Camp.gd уменьшился на ~80 строк.

const DEFAULT_KEYS: Array = [
	ResourcePile.ResourceType.WOOD,
	ResourcePile.ResourceType.STONE,
	ResourcePile.ResourceType.IRON,
	ResourcePile.ResourceType.FOOD,
]

signal weights_changed(weights: Dictionary)

var _weights: Dictionary = {}


## Назначает новые приоритеты сбора. weights — Dictionary[int, float] по
## типам ресурсов; будут нормализованы к сумме 1.0. Все ключи —
## ResourcePile.ResourceType.
##
## Если сумма весов ≤ 0 (всё нули) — fallback на равномерное распределение,
## иначе гномы вообще не смогут собирать. Это страховка от случайного preset'а
## «всё по 0».
func set_weights(weights: Dictionary) -> void:
	var total: float = 0.0
	for w in weights.values():
		total += maxf(float(w), 0.0)
	_weights.clear()
	if total <= 0.0:
		for k in DEFAULT_KEYS:
			_weights[k] = 0.25
	else:
		for k in weights:
			_weights[k] = maxf(float(weights[k]), 0.0) / total
	weights_changed.emit(_weights.duplicate())


## Базовый вес типа (без stock-балансировки). Незаданный тип → 0.
func get_weight(type: int) -> float:
	return float(_weights.get(type, 0.0))


## Копия всех весов — caller не может мутировать внутреннее состояние.
func get_weights() -> Dictionary:
	return _weights.duplicate()
