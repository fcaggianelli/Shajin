extends Node2D
## Fog of war: ombre proiettate dai muri a partire dagli occhi del giocatore
## locale. Disegnata sopra i giocatori, così chi è in ombra resta coperto.
## (La visibilità logica dei remoti è Map.line_of_sight, centro-centro.)

const Map = preload("res://proto2d/scripts/game/map.gd")
const Movement = preload("res://proto2d/scripts/game/movement.gd")

const FAR := 3000.0
const SHADOW := Color(0.04, 0.04, 0.06, 0.93)

var eye := Vector2.ZERO


func _ready() -> void:
	z_index = 10


func _draw() -> void:
	for w in Map.WALLS:
		var r: Rect2 = w
		var pts := PackedVector2Array()
		for c in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
			pts.append(c)
			pts.append(c + (c - eye).normalized() * FAR)
		var hull := Geometry2D.convex_hull(pts)
		hull.remove_at(hull.size() - 1)  # convex_hull ripete il primo punto in fondo
		draw_colored_polygon(hull, SHADOW)
	for w in Map.WALLS:
		draw_rect(w, Color(0.45, 0.47, 0.55))
	# Copri le ombre che escono dall'arena.
	var a := Movement.ARENA
	var bg: Color = ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color")
	draw_rect(Rect2(a.position.x - FAR, a.position.y - FAR, FAR * 2 + a.size.x, FAR), bg)
	draw_rect(Rect2(a.position.x - FAR, a.end.y, FAR * 2 + a.size.x, FAR), bg)
	draw_rect(Rect2(a.position.x - FAR, a.position.y, FAR, a.size.y), bg)
	draw_rect(Rect2(a.end.x, a.position.y, FAR, a.size.y), bg)
	draw_rect(a, Color(0.55, 0.55, 0.6), false, 2.0)
