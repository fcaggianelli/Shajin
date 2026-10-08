extends RefCounted
## Stato simulato di un giocatore. È tutto ciò che simulate_move legge/scrive,
## ed è esattamente ciò che il server mette nello snapshot per la riconciliazione.

var pos := Vector2.ZERO
var vel := Vector2.ZERO
var cooldown := 0  # tick rimanenti prima di poter sparare di nuovo


func copy():
	var s = get_script().new()
	s.pos = pos
	s.vel = vel
	s.cooldown = cooldown
	return s
