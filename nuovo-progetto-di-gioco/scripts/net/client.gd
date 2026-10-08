extends Node3D
## Client: client-side prediction + server reconciliation, vista in prima persona.

const Movement = preload("res://scripts/game/movement.gd")
const PlayerState = preload("res://scripts/game/player_state.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")
const Player = preload("res://scripts/game/player.gd")
const Protocol = preload("res://scripts/net/protocol.gd")
const NetSim = preload("res://scripts/net/net_sim.gd")
const NetConfig = preload("res://scripts/net/net_config.gd")
const Server = preload("res://scripts/net/server.gd")
const DebugOverlay = preload("res://scripts/net/debug_overlay.gd")

const CONNECT_TIMEOUT_MS := 5000
const MOUSE_SENSITIVITY := 0.0025

## Emesso quando la connessione fallisce o cade; was_connected distingue i casi.
signal disconnected(was_connected: bool)

var sim: NetSim
var my_id := 0

# --- Toggle di debug ---
var prediction_enabled := true
var reconciliation_enabled := true

## Sorgente input sostituibile (test): func(client, seq) -> {buttons, yaw, pitch}
var input_provider := Callable()
## false nei test con più client nello stesso processo: niente camera/HUD.
var local_view := true

# --- Prediction ---
var state: PlayerState            # stato predetto (o del server, se prediction off)
var server_state: PlayerState     # ultimo stato autoritativo ricevuto per noi
var seq := 0
var pending: Array = []           # InputCmd non ancora confermati
var last_ack := 0
var predicted := {}               # seq -> posizione predetta dopo quel comando
var _send_usec := {}              # seq -> istante di invio (ping)

# --- Snapshot ---
var last_snap_tick := -1
var snapshots: Array = []         # ultimi snapshot, ordinati per tick
var server_tick_est := 0.0        # stima del tick server corrente
var render_tick := 0.0            # istante (tick server) a cui mostriamo i remoti
var players_info := {}            # id -> {score, deaths, protected, respawn_ticks, alive}

# --- Statistiche ---
var ping_ms := 0.0
var err_last := 0.0
var err_max := 0.0
var err_sum := 0.0
var err_count := 0
var correction_max := 0.0         # salto visivo massimo causato da una riconciliazione
var errors: Array = []

# --- Vista ---
var view_yaw := 0.0
var view_pitch := 0.0
var _prev_pos := Vector3.ZERO     # per interpolare la camera tra due tick
var _camera: Camera3D
var _peer: ENetMultiplayerPeer
var _players := {}                # id -> Player (remoti)
var _connect_start_ms := 0


func start(host: String, port: int, lag := 0.0, jitter := 0.0, loss := 0.0, seed_value := 0) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(host, port)
	if err != OK:
		_peer = null
		return err
	_connect_start_ms = Time.get_ticks_msec()
	sim = NetSim.new(_peer, seed_value)
	sim.configure(lag, jitter, loss)
	if local_view:
		_camera = Camera3D.new()
		_camera.fov = 90
		add_child(_camera)
		_camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		var overlay := DebugOverlay.new()
		overlay.client = self
		add_child(overlay)
	return OK


func stop() -> void:
	if _peer:
		_peer.close()
		_peer = null


func is_ready() -> bool:
	return state != null


func _unhandled_input(event: InputEvent) -> void:
	if not local_view or input_provider.is_valid():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		view_yaw = wrapf(view_yaw - event.relative.x * MOUSE_SENSITIVITY, -PI, PI)
		view_pitch = clampf(view_pitch - event.relative.y * MOUSE_SENSITIVITY, -Movement.MAX_PITCH, Movement.MAX_PITCH)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		var opened := Protocol.open(pkt[1])
		if opened[0] == Protocol.TYPE_SNAPSHOT:
			_on_snapshot(Protocol.decode_snapshot(opened[1]))
	var timed_out := my_id == 0 and Time.get_ticks_msec() - _connect_start_ms > CONNECT_TIMEOUT_MS
	if timed_out or _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		stop()
		disconnected.emit(my_id != 0)
		return
	if my_id == 0 and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		my_id = _peer.get_unique_id()
	if state == null:
		return  # aspettiamo il primo snapshot per conoscere lo spawn

	server_tick_est += 1.0
	render_tick = server_tick_est - NetConfig.ms_to_ticks(NetConfig.INTERP_MS)
	_update_remotes()

	# 1. campiona l'input di questo tick
	seq += 1
	var cmd := InputCmd.new()
	cmd.seq = seq
	var input := _sample_input()
	cmd.buttons = input.buttons
	cmd.yaw = Protocol.f32(input.yaw)
	cmd.pitch = Protocol.f32(input.pitch)

	# 2. prediction: applicalo subito, senza aspettare il server
	_prev_pos = state.pos
	if prediction_enabled:
		Movement.simulate_move(state, cmd, Movement.DT)
		predicted[seq] = state.pos

	# 3. buffer + invio (con ridondanza degli input non confermati)
	pending.append(cmd)
	_send_usec[seq] = Time.get_ticks_usec()
	sim.send(1, Protocol.encode_input(pending))


func _sample_input() -> Dictionary:
	if input_provider.is_valid():
		return input_provider.call(self, seq)
	var b := 0
	if Input.is_physical_key_pressed(KEY_W): b |= InputCmd.FORWARD
	if Input.is_physical_key_pressed(KEY_S): b |= InputCmd.BACK
	if Input.is_physical_key_pressed(KEY_A): b |= InputCmd.LEFT
	if Input.is_physical_key_pressed(KEY_D): b |= InputCmd.RIGHT
	if Input.is_physical_key_pressed(KEY_SPACE): b |= InputCmd.JUMP
	return {buttons = b, yaw = view_yaw, pitch = view_pitch}


func _on_snapshot(snap: Dictionary) -> void:
	if snap.tick <= last_snap_tick:
		return  # vecchio o fuori ordine
	last_snap_tick = snap.tick
	snapshots.append(snap)
	while snapshots.size() > 32:
		snapshots.pop_front()
	# Orologio: inseguiamo dolcemente il tick degli snapshot ricevuti.
	var drift: float = snap.tick - server_tick_est
	if absf(drift) > 30.0:
		server_tick_est = snap.tick
	else:
		server_tick_est += drift * 0.1
	players_info.clear()
	for id in snap.players:
		var p: Dictionary = snap.players[id]
		players_info[id] = {score = p.score, deaths = p.deaths, protected = p.protected,
			respawn_ticks = p.respawn_ticks, alive = p.state.alive}

	if not snap.players.has(my_id):
		return
	server_state = snap.players[my_id].state

	if state == null:
		state = server_state.copy()
		_prev_pos = state.pos
		view_yaw = state.yaw
		view_pitch = state.pitch
		return

	var ack: int = snap.ack
	if ack > last_ack:
		if _send_usec.has(ack):
			var rtt: float = (Time.get_ticks_usec() - _send_usec[ack]) / 1000.0 - snap.hold_ms
			ping_ms = rtt if ping_ms == 0.0 else lerpf(ping_ms, rtt, 0.1)
		# Errore di predizione: dove pensavamo di essere dopo `ack` vs dove dice il server.
		if predicted.has(ack):
			_record_error(predicted[ack].distance_to(server_state.pos))
		# Scarta gli input confermati.
		while not pending.is_empty() and pending[0].seq <= ack:
			var done = pending.pop_front()
			predicted.erase(done.seq)
		for s in _send_usec.keys():
			if s <= ack:
				_send_usec.erase(s)
		last_ack = ack

	if not prediction_enabled:
		state = server_state.copy()
	elif reconciliation_enabled:
		# Riconciliazione: riparti dallo stato autoritativo e rigioca gli input pendenti.
		var before := state.pos
		state = server_state.copy()
		for cmd in pending:
			Movement.simulate_move(state, cmd, Movement.DT)
			predicted[cmd.seq] = state.pos
		correction_max = maxf(correction_max, before.distance_to(state.pos))


func _record_error(e: float) -> void:
	err_last = e
	err_max = maxf(err_max, e)
	err_sum += e
	err_count += 1
	errors.append(e)


var remote_states := {}  # id -> PlayerState come visualizzato


## Gli altri giocatori sono mostrati a render_tick (~100 ms nel passato),
## interpolati tra i due snapshot che lo racchiudono.
func _update_remotes() -> void:
	remote_states.clear()
	if snapshots.is_empty():
		return
	var pair := Server.bracket(snapshots, render_tick)
	for id in pair[1].players:
		if id != my_id:
			remote_states[id] = Server.interpolate(pair[0], pair[1], id, render_tick)


func _process(_delta: float) -> void:
	if state == null or not local_view:
		return
	# Camera: posizione interpolata tra gli ultimi due tick, angoli dal mouse (subito).
	var f := Engine.get_physics_interpolation_fraction()
	_camera.position = _prev_pos.lerp(state.pos, f) + Vector3(0, Movement.EYE_HEIGHT, 0)
	_camera.rotation = Vector3(view_pitch, view_yaw, 0)
	var seen := {}
	for id in remote_states:
		if not _players.has(id):
			var p := Player.new()
			p.setup(id)
			add_child(p)
			_players[id] = p
		var s: PlayerState = remote_states[id]
		var info: Dictionary = players_info.get(id, {})
		_players[id].show_state(s.pos, s.yaw, s.alive, info.get("protected", false))
		seen[id] = true
	for id in _players.keys():
		if not seen.has(id):
			_players[id].queue_free()
			_players.erase(id)
