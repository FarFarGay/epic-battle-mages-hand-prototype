extends Node
## Procedural PCM: sub hit, cannon crack, stone, brass and reload machinery.
var bank: Dictionary = {}
var muted := false
var motor: AudioStreamPlayer
var voices: Array[AudioStreamPlayer] = []
var voice_cursor := 0
var last_crowd_sound := {}
var random := RandomNumberGenerator.new()
const RATE := 22050

func _ready() -> void:
	random.seed = 4107
	for kind in ["fire", "impact", "eject", "chamber", "lock", "ready", "servo", "step", "bow", "spell", "strike", "pickup", "dash", "dash_charge", "shatter", "repeater", "bolt_hit", "repeater_reload", "shield_hit", "shield_break"]:
		bank[kind] = _synthesize(kind)
	for i in 32:
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		voices.append(voice)
	motor = AudioStreamPlayer.new()
	add_child(motor)
	motor.stream = _synthesize("motor")
	motor.volume_db = -45
	motor.play()

func play(kind: String, volume: float = 0.0, pitch: float = 1.0) -> void:
	if muted or not bank.has(kind):
		return
	if kind in ["bow", "shatter", "shield_hit", "shield_break"]:
		var now := Time.get_ticks_msec()
		if now - int(last_crowd_sound.get(kind, -1000)) < 30: return
		last_crowd_sound[kind] = now
	var player: AudioStreamPlayer
	# Eight reserved voices keep the cannon/reload audible during crowded melee.
	var heavy := kind in ["fire", "impact", "eject", "chamber", "lock", "ready"]
	var first := 24 if heavy else 0
	var count := 8 if heavy else 24
	for i in count:
		var voice := voices[first + i]
		if not voice.playing:
			player = voice
			break
	if player == null:
		player = voices[first + voice_cursor % count]
		voice_cursor += 1
		player.stop()
	player.stream = bank[kind]
	player.volume_db = volume - 5.0
	player.pitch_scale = pitch * random.randf_range(0.96, 1.04)
	player.play()

func engine(throttle: float) -> void:
	if motor:
		motor.volume_db = -80.0 if muted else lerpf(-43.0, -29.0, throttle)
		motor.pitch_scale = lerpf(0.8, 1.55, throttle)

func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null

func _synthesize(kind: String) -> AudioStreamWAV:
	var duration := 0.5
	match kind:
		"fire": duration = 1.5
		"impact": duration = 1.15
		"eject": duration = 0.5
		"chamber": duration = 0.58
		"lock": duration = 0.35
		"ready": duration = 0.4
		"servo": duration = 0.8
		"motor": duration = 2.0
		"step": duration = 0.42
		"bow": duration = 0.18
		"spell": duration = 0.40
		"strike": duration = 0.30
		"pickup": duration = 0.22
		"dash": duration = 0.42
		"dash_charge": duration = 0.55
		"shatter": duration = 0.32
		"repeater": duration = 0.10
		"bolt_hit": duration = 0.12
		"shield_hit": duration = 0.18
		"shield_break": duration = 0.35
		"repeater_reload": duration = 0.90
	var count := int(duration * RATE)
	var data := PackedByteArray()
	data.resize(count * 2)
	var low := 0.0
	var phase := 0.0
	for i in count:
		var t := float(i) / RATE
		var noise := random.randf_range(-1.0, 1.0)
		low = lerpf(low, noise, 0.13)
		var s := 0.0
		match kind:
			"shield_hit":
				s = noise * exp(-t * 90.0) * 0.5 + (sin(TAU * 780.0 * t) + sin(TAU * 1237.0 * t) * 0.55 + sin(TAU * 1961.0 * t) * 0.3) * exp(-t * 24.0) * 0.4
			"shield_break":
				s = low * exp(-t * 16.0) * 1.6 + noise * exp(-t * 32.0) * 0.7 + (sin(TAU * 231.0 * t) + sin(TAU * 571.0 * t) * 0.6) * exp(-t * 15.0) * 0.45
			"repeater":
				phase += TAU * (170.0 + 680.0 * exp(-t * 65.0)) / RATE
				s = sin(phase) * exp(-t * 48.0) * 0.55 + noise * exp(-t * 90.0) * 0.65 + sin(TAU * 2450.0 * t) * exp(-t * 55.0) * 0.15
				if t > 0.035: s += low * exp(-(t - 0.035) * 85.0) * 0.9
			"bolt_hit":
				s = noise * exp(-t * 50.0) * 0.45 + sin(TAU * 920.0 * t) * exp(-t * 60.0) * 0.20
			"repeater_reload":
				s = (sin(TAU * 83.0 * t) * 0.5 + noise * 0.4) * exp(-t * 19.0)
				if t > 0.18: s += (low * 1.3 + sin(TAU * 160.0 * t) * 0.13) * sin(PI * clampf((t - 0.18) / 0.72, 0.0, 1.0))
			"dash":
				phase += TAU * (52.0 + 150.0 * exp(-t * 24.0)) / RATE
				s = sin(phase) * exp(-t * 11.0) * 0.65 + low * sin(PI * t / duration) * 1.5 + noise * exp(-t * 25.0) * 0.18
			"dash_charge":
				s = (sin(TAU * (110.0 * t + 350.0 * t * t)) * 0.2 + low * 0.4) * sin(PI * t / duration)
			"shatter":
				s = noise * exp(-t * 20.0) * 0.6 + low * exp(-t * 12.0) * 0.7
				s += sin(TAU * 1700.0 * t) * exp(-t * 30.0) * 0.15
			"bow":
				s = sin(TAU * (240.0 * t + 55.0 * (1.0 - exp(-18.0 * t)))) * exp(-t * 28.0) * 0.4 + noise * exp(-t * 42.0) * 0.3
			"spell":
				s = low * sin(PI * t / duration) * exp(-t * 3.0) * 1.2 + sin(TAU * (180.0 * t + 180.0 * t * t)) * exp(-t * 12.0) * 0.2
			"strike":
				s = sin(TAU * 78.0 * t) * exp(-t * 21.0) * 0.7 + noise * exp(-t * 35.0) * 0.3
			"pickup":
				s = (sin(TAU * 1320.0 * t) + sin(TAU * 1980.0 * t) * 0.4) * exp(-t * 24.0) * 0.25
			"fire":
				phase += TAU * (42.0 + 95.0 * exp(-t * 28.0)) / RATE
				s = sin(phase) * exp(-t * 5.5) * 0.78 + noise * exp(-t * 60.0) * 0.73 + low * exp(-t * 3.8) * 1.4
				if t > 0.11:
					s += low * exp(-(t - 0.11) * 8.0) * 0.45
			"impact":
				s = sin(TAU * (55.0 * t + 4.0 * (1.0 - exp(-t * 15.0)))) * exp(-t * 9.0) * 0.6 + low * exp(-t * 4.5) * 1.5 + noise * exp(-t * 45.0) * 0.3
			"step":
				phase += TAU * (48.0 + 70.0 * exp(-t * 40.0)) / RATE
				s = sin(phase) * exp(-t * 16.0) * 0.72 + low * exp(-t * 13.0) * 1.25 + noise * exp(-t * 85.0) * 0.26
				s += sin(TAU * 430.0 * t) * exp(-t * 26.0) * 0.08
			"eject":
				s = (sin(TAU * 1400.0 * t) + sin(TAU * 2197.0 * t) * 0.5) * exp(-t * 19.0) * 0.19 + noise * exp(-t * 70.0) * 0.4
				if t > 0.25:
					s += sin(TAU * 1800.0 * t) * exp(-(t - 0.25) * 45.0) * 0.13
			"chamber":
				var gate := pow(sin(PI * minf(t / duration, 1.0)), 2.0)
				s = (low * 1.5 + sin(TAU * (95.0 * t + 110.0 * t * t)) * 0.12) * gate
				if t > 0.38:
					s += sin(TAU * 78.0 * t) * exp(-(t - 0.38) * 30.0) * 0.65
			"lock":
				s = (sin(TAU * 115.0 * t) * 0.58 + noise * 0.38 + sin(TAU * 710.0 * t) * 0.18) * exp(-t * 30.0)
			"ready":
				s = (sin(TAU * 690.0 * t) + sin(TAU * 1035.0 * t) * 0.3) * 0.11 * sin(PI * minf(t / 0.02, 0.5)) * exp(-t * 11.0)
			"servo":
				s = (sin(TAU * (160.0 * t + 60.0 * t * t)) * 0.1 + low * 0.4) * sin(PI * t / duration)
			"motor":
				s = sin(TAU * 42.0 * t) * 0.3 + sin(TAU * 84.0 * t) * 0.1 + sin(TAU * 126.0 * t) * 0.05
		s *= minf(t * 1000.0, 1.0) * minf((duration - t) * 100.0, 1.0) if kind != "motor" else 1.0
		data.encode_s16(i * 2, int(clampf(s, -0.98, 0.98) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.data = data
	if kind == "motor":
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = count
	return stream
