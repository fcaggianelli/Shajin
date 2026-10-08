extends RefCounted
## Movimento condiviso, deterministico: lo STESSO codice gira sul server
## (autoritativo) e sul client (prediction + replay). Niente move_and_slide():
## movimento cinematico alla Quake III (PM_Friction, PM_Accelerate, slide move)
## di una capsula contro la geometria statica, con query allo spazio fisico.
## Dipende solo da stato, input, delta e geometria statica.

const PlayerState = preload("res://scripts/game/player_state.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")
const NetConfig = preload("res://scripts/net/net_config.gd")

const DT := 1.0 / NetConfig.TICK_RATE
# Valori di Quake III scalati (1 unità Q3 ≈ 2.5 cm)
const MAX_SPEED := 8.0        # g_speed 320
const ACCELERATE := 10.0      # pm_accelerate
const AIR_ACCELERATE := 1.0   # pm_airaccelerate
const FRICTION := 6.0         # pm_friction
const STOP_SPEED := 2.5       # pm_stopspeed 100
const GRAVITY := 20.0         # g_gravity 800
const JUMP_SPEED := 6.75      # JUMP_VELOCITY 270
const MAX_PITCH := deg_to_rad(89.0)
const FIRE_COOLDOWN_TICKS := NetConfig.TICK_RATE  # 1.0 s

# Capsula del giocatore (anche hitbox dell'arma)
const RADIUS := 0.4
const HEIGHT := 1.8
const EYE_HEIGHT := 1.6
const CENTER := Vector3(0, HEIGHT / 2, 0)
const GROUND_PROBE := 0.1
## Distanza minima mantenuta dalla geometria: cast_motion ignora le forme che la
## capsula sta già toccando, quindi non bisogna mai arrivare a contatto esatto.
const SKIN := 0.02
const MIN_GROUND_NORMAL_Y := 0.7
const LEVEL_MASK := 1

## Spazio fisico con la geometria statica del livello (lo imposta Level).
static var space: PhysicsDirectSpaceState3D
static var _query: PhysicsShapeQueryParameters3D


static func eye(state: PlayerState) -> Vector3:
	return state.pos + Vector3(0, EYE_HEIGHT, 0)


static func aim_dir(yaw: float, pitch: float) -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


static func wish_dir(buttons: int, yaw: float) -> Vector3:
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var d := Vector3.ZERO
	if buttons & InputCmd.FORWARD: d += fwd
	if buttons & InputCmd.BACK: d -= fwd
	if buttons & InputCmd.RIGHT: d += right
	if buttons & InputCmd.LEFT: d -= right
	return d.normalized()


## Avanza `state` di un tick con `input`. Ritorna true se in questo tick il
## giocatore spara (cooldown rispettato, vivo): così anche lo sparo è predetto.
static func simulate_move(state: PlayerState, input: InputCmd, delta: float) -> bool:
	if not state.alive:
		return false
	state.yaw = wrapf(input.yaw, -PI, PI)
	state.pitch = clampf(input.pitch, -MAX_PITCH, MAX_PITCH)

	var wish := wish_dir(input.buttons, state.yaw)
	if state.on_ground and input.buttons & InputCmd.JUMP:
		state.vel.y = JUMP_SPEED
		state.on_ground = false

	if state.on_ground:
		_friction(state, delta)
		_accelerate(state, wish, ACCELERATE, delta)
		state.vel.y = 0.0
	else:
		_accelerate(state, wish, AIR_ACCELERATE, delta)
		state.vel.y -= GRAVITY * delta

	_slide_move(state, state.vel * delta)
	_depenetrate(state)
	_categorize_position(state)

	var fired := false
	if state.cooldown > 0:
		state.cooldown -= 1
	elif input.buttons & InputCmd.FIRE:
		state.cooldown = FIRE_COOLDOWN_TICKS
		fired = true
	return fired


static func _friction(state: PlayerState, delta: float) -> void:
	var speed := Vector2(state.vel.x, state.vel.z).length()
	if speed < 0.001:
		state.vel.x = 0.0
		state.vel.z = 0.0
		return
	var control := maxf(speed, STOP_SPEED)
	var new_speed := maxf(speed - control * FRICTION * delta, 0.0)
	state.vel.x *= new_speed / speed
	state.vel.z *= new_speed / speed


static func _accelerate(state: PlayerState, wish: Vector3, accel: float, delta: float) -> void:
	if wish == Vector3.ZERO:
		return
	var add := MAX_SPEED - state.vel.dot(wish)
	if add > 0.0:
		state.vel += wish * minf(accel * delta * MAX_SPEED, add)


static func _shape_query() -> PhysicsShapeQueryParameters3D:
	if _query == null:
		var shape := CapsuleShape3D.new()
		shape.radius = RADIUS
		shape.height = HEIGHT
		_query = PhysicsShapeQueryParameters3D.new()
		_query.shape = shape
		_query.collision_mask = LEVEL_MASK
		_query.margin = 0.0
	return _query


## PM_SlideMove: muove la capsula; a ogni contatto toglie alla velocità e al
## moto residuo la componente lungo la normale e riprova (max 4 piani).
static func _slide_move(state: PlayerState, motion: Vector3) -> void:
	var q := _shape_query()
	for i in 4:
		if motion.length_squared() < 1e-10:
			return
		var start := state.pos
		q.transform = Transform3D(Basis.IDENTITY, start + CENTER)
		q.motion = motion
		var frac := space.cast_motion(q)
		if frac.is_empty():
			return
		if frac[0] >= 1.0:
			state.pos += motion
			return
		# Avanza fino al contatto meno SKIN.
		var length := motion.length()
		state.pos += motion / length * maxf(frac[0] * length - SKIN, 0.0)
		# Normale del contatto: la capsula nella posizione appena oltre il contatto.
		q.transform = Transform3D(Basis.IDENTITY, start + CENTER + motion * frac[1])
		q.motion = Vector3.ZERO
		var info := space.get_rest_info(q)
		if info.is_empty():
			return
		var n: Vector3 = info.normal
		motion = motion * (1.0 - frac[0])
		motion -= n * motion.dot(n)
		var into := state.vel.dot(n)
		if into < 0.0:
			state.vel -= n * into


## Se la capsula è finita (di pochi mm) dentro un box, ad esempio scivolando su
## uno spigolo, la spinge fuori lungo la normale. Serve perché cast_motion ignora
## le forme già toccate: senza, si potrebbe attraversare il muro.
static func _depenetrate(state: PlayerState) -> void:
	var q := _shape_query()
	q.motion = Vector3.ZERO
	for i in 4:
		q.transform = Transform3D(Basis.IDENTITY, state.pos + CENTER)
		var info := space.get_rest_info(q)
		if info.is_empty():
			return
		state.pos += info.normal * SKIN


## A terra se poco sotto i piedi c'è una superficie abbastanza orizzontale.
static func _categorize_position(state: PlayerState) -> void:
	if state.vel.y > 0.0:
		state.on_ground = false
		return
	var q := _shape_query()
	var probe := Vector3(0, -GROUND_PROBE, 0)
	q.transform = Transform3D(Basis.IDENTITY, state.pos + CENTER)
	q.motion = probe
	var frac := space.cast_motion(q)
	if frac.is_empty() or frac[0] >= 1.0:
		state.on_ground = false
		return
	q.transform = Transform3D(Basis.IDENTITY, state.pos + CENTER + probe * frac[1])
	q.motion = Vector3.ZERO
	var info := space.get_rest_info(q)
	state.on_ground = not info.is_empty() and info.normal.y >= MIN_GROUND_NORMAL_Y
	if state.on_ground:
		state.pos.y -= maxf(frac[0] * GROUND_PROBE - SKIN, 0.0)  # appoggiato, a SKIN dal pavimento
		state.vel.y = 0.0
