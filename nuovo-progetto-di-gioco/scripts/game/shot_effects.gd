extends Node3D
## Effetti locali dello sparo: traccia che svanisce e un "bip" placeholder
## generato in codice (nessun asset esterno).

const TRACER_TIME := 0.12

var _tracers: Array = []  # [MeshInstance3D, tempo rimasto]
var _audio := AudioStreamPlayer.new()


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


func shot(from: Vector3, to: Vector3) -> void:
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 0.9, 0.4)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	mesh.surface_add_vertex(from)
	mesh.surface_add_vertex(to)
	mesh.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.top_level = true
	add_child(mi)
	_tracers.append([mi, TRACER_TIME, mat])
	_audio.play()


func _process(delta: float) -> void:
	for t in _tracers:
		t[1] -= delta
		t[2].albedo_color.a = maxf(t[1] / TRACER_TIME, 0.0)
		if t[1] <= 0.0:
			t[0].queue_free()
	_tracers = _tracers.filter(func(t): return t[1] > 0.0)
