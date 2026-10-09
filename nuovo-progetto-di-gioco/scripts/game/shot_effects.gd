extends Node3D
## Effetti dello sparo: traccia che svanisce e un "bip" placeholder generato in
## codice (nessun asset esterno). Arancione = nostro, rosso = avversario.

const TRACER_TIME := 0.12

var _tracers: Array = []  # [MeshInstance3D, tempo rimasto]
var _audio := AudioStreamPlayer.new()
var _enemy_audio := AudioStreamPlayer.new()


func _ready() -> void:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var data := PackedByteArray()
	var n := 2205  # 0.1 s
	data.resize(n * 2)
	for i in n:
		var env := 1.0 - float(i) / n
		var v := sin(i * TAU * lerpf(900.0, 300.0, float(i) / n) / 22050.0) * env * 0.5
		data.encode_s16(i * 2, int(v * 32767))
	wav.data = data
	_audio.stream = wav
	add_child(_audio)
	_enemy_audio.stream = wav
	_enemy_audio.pitch_scale = 0.6
	_enemy_audio.volume_db = -6.0
	add_child(_enemy_audio)


## Traccia come barra sottile da `from` (l'arma, in basso a destra) a `to`.
func shot(from: Vector3, to: Vector3, enemy := false) -> void:
	var length := from.distance_to(to)
	if length < 0.01:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 0.1, 0.1) if enemy else Color(1, 0.45, 0.05)
	var box := BoxMesh.new()
	box.size = Vector3(0.04, 0.04, length)
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = mat
	mi.top_level = true
	add_child(mi)
	mi.global_position = (from + to) / 2
	mi.look_at_from_position(mi.global_position, to, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT)
	_tracers.append([mi, TRACER_TIME * (2.0 if enemy else 1.0), mat])
	(_enemy_audio if enemy else _audio).play()


func _process(delta: float) -> void:
	for t in _tracers:
		t[1] -= delta
		t[2].albedo_color.a = maxf(t[1] / TRACER_TIME, 0.0)
		if t[1] <= 0.0:
			t[0].queue_free()
	_tracers = _tracers.filter(func(t): return t[1] > 0.0)
