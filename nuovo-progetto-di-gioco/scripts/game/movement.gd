extends RefCounted
## Movimento condiviso: lo STESSO codice gira sul server (autoritativo) e sul
## client (prediction + replay). Deve essere deterministico: dipende solo da
## stato, input e delta, nessun accesso a tempo, rete o random.

const PlayerState = preload("res://scripts/game/player_state.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")

## Frequenza della simulazione: la imposta NetConfig (64 Hz per il preset cs2).
## Client e server devono usare lo stesso valore, altrimenti la predizione diverge.
static var tick_rate := 64
const ARENA := Rect2(0, 0, 800, 600)
const PLAYER_SIZE := 32.0
const MAX_SPEED := 300.0
const ACCELERATE := 10.0  # come pm_accelerate di Quake III
const FRICTION := 6.0     # come pm_friction
const STOP_SPEED := 100.0
const FIRE_COOLDOWN_MS := 160.0


static func dt() -> float:
	return 1.0 / tick_rate


static func fire_cooldown_ticks() -> int:
	return int(round(FIRE_COOLDOWN_MS * tick_rate / 1000.0))


static func wish_dir(buttons: int) -> Vector2:
	var d := Vector2.ZERO
	if buttons & InputCmd.UP: d.y -= 1
	if buttons & InputCmd.DOWN: d.y += 1
	if buttons & InputCmd.LEFT: d.x -= 1
	if buttons & InputCmd.RIGHT: d.x += 1
	return d.normalized()


## Avanza `state` di un tick applicando `cmd`. Ritorna true se in questo tick
## il giocatore ha sparato (cooldown gestito qui, così anche lo sparo è predetto).
static func simulate_move(state: PlayerState, cmd: InputCmd, delta: float) -> bool:
	# Attrito (PM_Friction semplificato)
	var speed := state.vel.length()
	if speed > 0.0:
		var control := maxf(speed, STOP_SPEED)
		var new_speed := maxf(speed - control * FRICTION * delta, 0.0)
		state.vel *= new_speed / speed

	# Accelerazione verso la direzione desiderata (PM_Accelerate)
	var wish := wish_dir(cmd.buttons)
	if wish != Vector2.ZERO:
		var current := state.vel.dot(wish)
		var add := MAX_SPEED - current
		if add > 0.0:
			state.vel += wish * minf(ACCELERATE * delta * MAX_SPEED, add)

	# Integrazione + collisione con i bordi dell'arena
	state.pos += state.vel * delta
	var half := PLAYER_SIZE * 0.5
	var lo := ARENA.position + Vector2(half, half)
	var hi := ARENA.end - Vector2(half, half)
	if state.pos.x < lo.x or state.pos.x > hi.x:
		state.pos.x = clampf(state.pos.x, lo.x, hi.x)
		state.vel.x = 0.0
	if state.pos.y < lo.y or state.pos.y > hi.y:
		state.pos.y = clampf(state.pos.y, lo.y, hi.y)
		state.vel.y = 0.0

	# Arma
	var fired := false
	if state.cooldown > 0:
		state.cooldown -= 1
	elif cmd.buttons & InputCmd.FIRE:
		state.cooldown = fire_cooldown_ticks()
		fired = true
	return fired
