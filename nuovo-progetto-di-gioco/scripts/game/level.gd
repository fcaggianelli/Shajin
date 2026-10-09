extends Node3D
## Livello di prova: una stanza con muri interni e coperture, costruita da una
## lista di box. Server e client costruiscono la stessa geometria statica, su
## cui lavorano le query allo spazio fisico del movimento e dell'arma.

const Movement = preload("res://scripts/game/movement.gd")

## [centro, dimensioni]
const BOXES := [
	[Vector3(0, -0.5, 0), Vector3(40, 1, 40)],        # pavimento
	[Vector3(0, 2, -20.5), Vector3(42, 4, 1)],        # muri perimetrali
	[Vector3(0, 2, 20.5), Vector3(42, 4, 1)],
	[Vector3(-20.5, 2, 0), Vector3(1, 4, 42)],
	[Vector3(20.5, 2, 0), Vector3(1, 4, 42)],
	[Vector3(0, 2, -6), Vector3(14, 4, 1)],           # muro centrale
	[Vector3(-10, 2, 7), Vector3(1, 4, 12)],          # muri laterali
	[Vector3(10, 2, 7), Vector3(1, 4, 12)],
	[Vector3(0, 0.6, 6), Vector3(3, 1.2, 1.5)],       # coperture basse (si saltano)
	[Vector3(-12, 0.6, -13), Vector3(2, 1.2, 2)],
	[Vector3(12, 0.6, -13), Vector3(2, 1.2, 2)],
]
## Spawn: piedi a SKIN sopra il pavimento.
const SPAWNS := [
	Vector3(-17, 0.02, -17), Vector3(17, 0.02, -17), Vector3(-17, 0.02, 17), Vector3(17, 0.02, 17),
	Vector3(0, 0.02, -16), Vector3(0, 0.02, 16), Vector3(-15, 0.02, 0), Vector3(15, 0.02, 0),
]
const COLLISION_LAYER := 1

## false sul server dedicato: solo collisioni, niente mesh/luci da disegnare.
var visuals := true


func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.57, 0.62)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.3, 0.32, 0.35)
	for i in BOXES.size():
		var b: Array = BOXES[i]
		var body := StaticBody3D.new()
		body.collision_layer = COLLISION_LAYER
		body.position = b[0]
		var shape := CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		shape.shape.size = b[1]
		body.add_child(shape)
		add_child(body)
		if not visuals:
			continue
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = b[1]
		mesh.material_override = floor_mat if i == 0 else mat
		body.add_child(mesh)
	Movement.space = get_world_3d().direct_space_state
	if not visuals:
		return
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.6, 0.75)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
