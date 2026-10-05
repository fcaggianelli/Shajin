extends Node
## Server autoritativo. Tick fisso a 60 Hz (_physics_process), snapshot a 20 Hz.
## Come in Quake III, i comandi di un client vengono eseguiti appena arrivano
## (ognuno vale esattamente un tick, Movement.DT): il server non aspetta e non
## bufferizza, e il risultato è identico a quello predetto dal client.

const Movement = preload("res://scripts/game/movement.gd")
const PlayerState = preload("res://scripts/game/player_state.gd")
const Protocol = preload("res://scripts/net/protocol.gd")
const NetSim = preload("res://scripts/net/net_sim.gd")

const SNAPSHOT_EVERY := Movement.TICK_RATE / 20  # 60 Hz / 20 Hz = 3 tick
const HISTORY_SECONDS := 1.0
const SPAWNS := [Vector2(150, 300), Vector2(650, 300), Vector2(400, 150), Vector2(400, 450)]

var sim: NetSim
var tick := 0
var clients := {}  # peer_id -> {id, state, last_seq, applied_usec, hits, deaths}
## Cronologia degli snapshot inviati: [{tick, pos: {id: Vector2}}], ~1 s.
var history: Array = []

var _peer: ENetMultiplayerPeer
var _spawn_index := 0


func start(port: int, lag := 0.0, jitter := 0.0, loss := 0.0, seed_value := 0) -> Error:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, 32)
	if err != OK:
		return err
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	sim = NetSim.new(_peer, seed_value)
	sim.configure(lag, jitter, loss)
	print("[server] in ascolto sulla porta %d (lag %d ms, jitter %d ms, loss %d%%)" % [port, lag, jitter, loss * 100])
	return OK


func stop() -> void:
	if _peer:
		_peer.close()
		_peer = null


func _on_peer_connected(id: int) -> void:
	var s := PlayerState.new()
	s.pos = SPAWNS[_spawn_index % SPAWNS.size()]
	_spawn_index += 1
	clients[id] = {id = id, state = s, last_seq = 0, applied_usec = 0, hits = 0, deaths = 0}
	print("[server] client %d connesso" % id)


func _on_peer_disconnected(id: int) -> void:
	clients.erase(id)
	print("[server] client %d disconnesso" % id)


func _physics_process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		_handle_packet(pkt[0], pkt[1])
	tick += 1
	if tick % SNAPSHOT_EVERY == 0:
		_record_history()
		_send_snapshots()


func _handle_packet(from: int, data: PackedByteArray) -> void:
	var opened := Protocol.open(data)
	if opened[0] != Protocol.TYPE_INPUT or not clients.has(from):
		return
	var c: Dictionary = clients[from]
	for cmd in Protocol.decode_input(opened[1]):
		if cmd.seq <= c.last_seq:
			continue  # duplicato (ridondanza) o vecchio
		var fired := Movement.simulate_move(c.state, cmd, Movement.DT)
		if fired:
			_on_fire(c, cmd)
		c.last_seq = cmd.seq
		c.applied_usec = Time.get_ticks_usec()


func _on_fire(_shooter: Dictionary, _cmd) -> void:
	pass  # fase 2: hitscan con lag compensation


func _record_history() -> void:
	var pos := {}
	for id in clients:
		pos[id] = clients[id].state.pos
	history.append({tick = tick, pos = pos})
	var max_entries := int(HISTORY_SECONDS * Movement.TICK_RATE / SNAPSHOT_EVERY) + 1
	while history.size() > max_entries:
		history.pop_front()


func _send_snapshots() -> void:
	var players := clients.values()
	var now := Time.get_ticks_usec()
	for id in clients:
		var c: Dictionary = clients[id]
		var hold_ms := int((now - c.applied_usec) / 1000) if c.last_seq > 0 else 0
		sim.send(id, Protocol.encode_snapshot(tick, c.last_seq, hold_ms, players))
