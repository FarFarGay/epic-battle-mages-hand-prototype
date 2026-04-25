extends Node
## Глобальный конфиг логирования. Регистрируется как autoload `LogConfig`.
##
## Каждый entity script с `debug_log: bool` гейтит print'ы как
##     if debug_log and LogConfig.master_enabled:
## Так per-entity флаги остаются (для тонкого мута одного шумного модуля),
## а master_enabled быстро глушит всё разом — удобно при сборе/демо.

## Глобальный мастер: false — все debug-логи в проекте отключены.
@export var master_enabled: bool = true
