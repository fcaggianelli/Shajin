extends Node3D
## Rappresentazione visiva di un giocatore: una capsula colorata con un "naso"
## che indica dove guarda. Origine ai piedi.

const Movement = preload("res://scripts/game/movement.gd")

var _mat := StandardMaterial3D.new()
var _base_color := Color.WHITE


static func color_for(id: int) -> Color:
	return Color.from_hsv(fmod(id * 0.618034, 1.0), 0.7, 0.95)


func setup(id: int) -> void:
	_base_color = color_for(id)
	_mat.albedo_color = _base_color
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = Movement.RADIUS
	cap.height = Movement.HEIGHT
	body.mesh = cap
	body.position = Movement.CENTER
	body.material_override = _mat
	add_child(body)
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.15, 0.15, 0.35)
	nose.mesh = box
	nose.position = Vector3(0, Movement.EYE_HEIGHT, -Movement.RADIUS)
	nose.material_override = _mat
	add_child(nose)


## yaw ruota il corpo; protected = semitrasparente (protezione allo spawn).
func show_state(pos: Vector3, yaw: float, alive: bool, protected: bool) -> void:
	position = pos
	rotation = Vector3(0, yaw, 0)
	visible = alive
	if protected:
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.albedo_color = Color(_base_color, 0.35)
	else:
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		_mat.albedo_color = _base_color
