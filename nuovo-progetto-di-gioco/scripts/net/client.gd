extends Node2D
## Client: client-side prediction + server reconciliation.

const Movement = preload("res://scripts/game/movement.gd")
const PlayerState = preload("res://scripts/game/player_state.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")
const Player = preload("res://scripts/game/player.gd")
const Protocol = preload("res://scripts/net/protocol.gd")
const NetSim = preload("res://scripts/net/net_sim.gd")
const DebugOverlay = preload("res://scripts/net/debug_overlay.gd")

const ARENA_OFFSET := Vector2(20, 20)

var sim: NetSim
var my_id := 0

# --- Toggle di debug ---
var prediction_enabled := true
var reconciliation_enabled := true
var redundancy_enabled := true  # off = ogni pacchetto porta solo l'ultimo input

## Sorgente input sostituibile (test): func(client, seq) -> {buttons: int, aim: float}
var input_provider := Callable()

# --- Prediction ---
var state: PlayerState            # stato predetto (o del server, se prediction off)
var server_state: PlayerState     # ultimo stato autoritativo ricevuto per noi
var seq := 0
var pending: Array = []           # InputCmd non ancora confermati dal server
var last_ack := 0
var predicted := {}               # seq -> posizione predetta dopo quel comando
var _send_usec := {}              # seq -> istante di invio (per il ping)

# --- Snapshot ---
var last_snap_tick := -1
var snapshots: Array = []         # ultimi snapshot, ordinati per tick
var remote_positions := {}        # id -> Vector2 come visualizzato

# --- Interpolazione delle entità remote ---
const INTERP_DELAY_TICKS := 6     # 100 ms a 60 Hz = 2 intervalli di snapshot
var server_tick_est := 0.0        # stima del tick server "attuale" (avanza di 1 per tick)
var render_tick := 0.0            # istante (in tick server) in cui mostriamo i remoti

# --- Statistiche ---
var ping_ms := 0.0
var err_last := 0.0
var err_max := 0.0
var err_sum := 0.0
var err_count := 0
var correction_max := 0.0         # salto visivo massimo causato da una riconciliazione
var errors: Array = []            # tutti gli errori di predizione misurati

var _peer: ENetMultiplayerPeer
var _players := {}                # id -> Player node
var _prev_mouse := false


func start(host: String, port: int, lag := 0.0, jitter := 0.0, loss := 0.0, seed_value := 0) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(host, port)
	if err != OK:
		return err
	sim = NetSim.new(_peer, seed_value)
	sim.configure(lag, jitter, loss)
	position = ARENA_OFFSET
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


func _physics_process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		var opened := Protocol.open(pkt[1])
		if opened[0] == Protocol.TYPE_SNAPSHOT:
			_on_snapshot(Protocol.decode_snapshot(opened[1]))
	if my_id == 0 and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		my_id = _peer.get_unique_id()
	if state == null:
		return  # aspettiamo il primo snapshot per conoscere lo spawn

	server_tick_est += 1.0
	render_tick = server_tick_est - INTERP_DELAY_TICKS
	_update_remotes()

	# 1. campiona l'input di questo tick
	seq += 1
	var cmd := InputCmd.new()
	cmd.seq = seq
	var input := _sample_input()
	cmd.buttons = input.buttons
	cmd.aim = input.aim
	cmd.view_tick = render_tick

	# 2. prediction: applicalo subito, senza aspettare il server
	if prediction_enabled:
		Movement.simulate_move(state, cmd, Movement.DT)
		predicted[seq] = state.pos

	# 3. buffer + invio (con ridondanza degli input non confermati)
	pending.append(cmd)
	_send_usec[seq] = Time.get_ticks_usec()
	sim.send(1, Protocol.encode_input(pending if redundancy_enabled else [cmd]))
	queue_redraw()


func _sample_input() -> Dictionary:
	if input_provider.is_valid():
		return input_provider.call(self, seq)
	var b := 0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): b |= InputCmd.UP
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): b |= InputCmd.DOWN
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): b |= InputCmd.LEFT
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): b |= InputCmd.RIGHT
	var mouse := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if mouse and not _prev_mouse:
		b |= InputCmd.FIRE
	_prev_mouse = mouse
	return {buttons = b, aim = (get_local_mouse_position() - state.pos).angle()}


func _on_snapshot(snap: Dictionary) -> void:
	if snap.tick <= last_snap_tick:
		return  # vecchio o fuori ordine
	last_snap_tick = snap.tick
	snapshots.append(snap)
	# Orologio: inseguiamo dolcemente il tick degli snapshot ricevuti.
	var drift: float = snap.tick - server_tick_est
	if absf(drift) > 30.0:
		server_tick_est = snap.tick
	else:
		server_tick_est += drift * 0.1
	while snapshots.size() > 32:
		snapshots.pop_front()

	if not snap.players.has(my_id):
		return
	server_state = snap.players[my_id].state

	if state == null:
		state = server_state.copy()
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
			_send_usec.erase(done.seq)
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


## Gli altri giocatori sono mostrati a render_tick (~100 ms nel passato),
## interpolando linearmente tra i due snapshot che lo racchiudono.
func _update_remotes() -> void:
	remote_positions.clear()
	if snapshots.is_empty():
		return
	var a: Dictionary = snapshots[0]
	var b: Dictionary = snapshots[0]
	for snap in snapshots:
		b = snap
		if snap.tick >= render_tick:
			break
		a = snap
	var t := 0.0
	if b.tick > a.tick:
		t = clampf((render_tick - a.tick) / float(b.tick - a.tick), 0.0, 1.0)
	for id in b.players:
		if id == my_id:
			continue
		var to: Vector2 = b.players[id].state.pos
		var from: Vector2 = a.players[id].state.pos if a.players.has(id) else to
		remote_positions[id] = from.lerp(to, t)


func _process(_delta: float) -> void:
	if state == null:
		return
	var seen := {}
	_place(my_id, state.pos)
	seen[my_id] = true
	for id in remote_positions:
		_place(id, remote_positions[id])
		seen[id] = true
	for id in _players.keys():
		if not seen.has(id):
			_players[id].queue_free()
			_players.erase(id)


func _place(id: int, pos: Vector2) -> void:
	if not _players.has(id):
		var p := Player.new()
		p.color = Player.color_for(id)
		add_child(p)
		_players[id] = p
	_players[id].position = pos


func _draw() -> void:
	draw_rect(Movement.ARENA, Color(0.3, 0.3, 0.35), false, 2.0)
	if server_state and prediction_enabled:
		# fantasma: ultima posizione autoritativa del giocatore locale
		var s := Movement.PLAYER_SIZE
		draw_rect(Rect2(server_state.pos - Vector2(s, s) / 2, Vector2(s, s)), Color(1, 1, 1, 0.5), false, 1.0)
