extends Node2D
## Rappresentazione visiva di un giocatore: un quadrato colorato.

const Movement = preload("res://scripts/game/movement.gd")

var color := Color.WHITE
var flash := 0.0  # >0 subito dopo essere stato colpito


static func color_for(id: int) -> Color:
	return Color.from_hsv(fmod(id * 0.618034, 1.0), 0.65, 0.95)


func _process(delta: float) -> void:
	if flash > 0.0:
		flash = maxf(flash - delta, 0.0)
		queue_redraw()


func _draw() -> void:
	var s := Movement.PLAYER_SIZE
	var c := color.lerp(Color.WHITE, clampf(flash * 4.0, 0.0, 1.0))
	draw_rect(Rect2(-s / 2, -s / 2, s, s), c)
