extends RefCounted
## Stato simulato di un giocatore: tutto ciò che simulate_move legge/scrive ed
## esattamente ciò che lo snapshot trasporta (float32, quindi bit-identico).

var pos := Vector3.ZERO   # piedi
var vel := Vector3.ZERO
var yaw := 0.0            # radianti, rotazione attorno a Y
var pitch := 0.0          # radianti, positivo = guarda in alto
var on_ground := false
var alive := true
var cooldown := 0         # tick prima del prossimo sparo consentito


func copy():
	var s = get_script().new()
	s.pos = pos
	s.vel = vel
	s.yaw = yaw
	s.pitch = pitch
	s.on_ground = on_ground
	s.alive = alive
	s.cooldown = cooldown
	return s
