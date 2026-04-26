class_name HitFlash
extends RefCounted
## Кратковременная вспышка меша по факту получения урона.
## Подменяет material_override на общий flash-материал, по таймеру —
## возвращает оригинал. Целеустойчиво к перекрытию: токен в meta защищает
## от затирания свежей вспышки таймером старой.
##
## Использование:
##     HitFlash.flash(_mesh)
##
## Не зависит от конкретного класса цели — берёт MeshInstance3D и работает.
## Работает и с per-instance материалами (Item / Tower / CampPart), и с
## shared-материалами (Skeleton): на время вспышки слот material_override
## переключается на общий flash-материал, изначальная ссылка сохраняется
## в meta и восстанавливается на timeout.

const FLASH_DURATION: float = 0.12
const FLASH_ALBEDO: Color = Color(1.0, 0.85, 0.85, 1.0)
const FLASH_EMISSION: Color = Color(1.0, 0.25, 0.25)
const FLASH_EMISSION_INTENSITY: float = 2.5

const _ORIGINAL_KEY := &"_hitflash_original"
const _TOKEN_KEY := &"_hitflash_token"

static var _shared_material: StandardMaterial3D


static func _ensure_material() -> void:
	if _shared_material == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = FLASH_ALBEDO
		mat.emission_enabled = true
		mat.emission = FLASH_EMISSION
		mat.emission_energy_multiplier = FLASH_EMISSION_INTENSITY
		_shared_material = mat


## Запустить вспышку на меше. Безопасно вызывать повторно, в т.ч. до окончания
## предыдущей: оригинал сохраняется один раз, токен инкрементируется, и
## восстанавливать оригинал имеет право только последний таймер.
static func flash(mesh: MeshInstance3D, duration: float = FLASH_DURATION) -> void:
	if not is_instance_valid(mesh):
		return
	_ensure_material()
	# Оригинал сохраняем только на первой вспышке — иначе вторая флэш-в-флэше
	# затёрла бы его flash-материалом и реальный материал был бы потерян.
	if not mesh.has_meta(_ORIGINAL_KEY):
		mesh.set_meta(_ORIGINAL_KEY, mesh.material_override)
	var token := int(mesh.get_meta(_TOKEN_KEY, 0)) + 1
	mesh.set_meta(_TOKEN_KEY, token)
	mesh.material_override = _shared_material
	var tree := mesh.get_tree()
	if tree == null:
		return
	var timer := tree.create_timer(duration)
	timer.timeout.connect(func() -> void:
		if not is_instance_valid(mesh):
			return
		# Только последний таймер восстанавливает — иначе он стёр бы свежую
		# вспышку, инициированную позднее (за время duration пришёл новый удар).
		if int(mesh.get_meta(_TOKEN_KEY, 0)) != token:
			return
		mesh.material_override = mesh.get_meta(_ORIGINAL_KEY, null)
		mesh.remove_meta(_ORIGINAL_KEY)
		mesh.remove_meta(_TOKEN_KEY)
	)
