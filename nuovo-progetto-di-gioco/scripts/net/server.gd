extends Node
## Server autoritativo. Tick fisso a 60 Hz (_physics_process), snapshot a 20 Hz.
## Come in Quake III i comandi di un client vengono eseguiti appena arrivano
## (ognuno vale esattamente un tick): il risultato è identico alla predizione.

const Movement = preload("res://scripts/game/movement.gd")
const PlayerState = preload("res://scripts/game/player_state.gd")
const Level = preload("res://scripts/game/level.gd")
const Protocol = preload("res://scripts/net/protocol.gd")
const NetSim = preload("res://scripts/net/net_sim.gd")
const NetConfig = preload("res://scripts/net/net_config.gd")

const MAX_PLAYERS := 8

var sim: NetSim
var bind_ip := "0.0.0.0"
var spawns: Array = Level.SPAWNS  # i test possono sostituirli
var tick := 0
## peer_id -> {id, state, last_seq, applied_usec, score, deaths, protect_until, respawn_tick}
var clients := {}
## Cronologia agli istanti degli snapshot (~1 s): [{tick, players: {id: PlayerState}}].
## È esattamente ciò che i client interpolano: serve al rewind della fase 3.
var history: Array = []

var _peer: ENetMultiplayerPeer
var _spawn_index := 0


func start(port: int, lag := 0.0, jitter := 0.0, loss := 0.0, seed_value := 0) -> Error:
	_peer = ENetMultiplayerPeer.new()
	_peer.set_bind_ip(bind_ip)
	var err := _peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		_peer = null
		return err
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	sim = NetSim.new(_peer, seed_value)
	sim.configure(lag, jitter, loss)
	print("[server] in ascolto su %s:%d (max %d giocatori; lag %d ms, jitter %d ms, loss %d%%)" % [
		bind_ip, port, MAX_PLAYERS, lag, jitter, loss * 100])
	return OK


func stop() -> void:
	if _peer:
		_peer.close()
		_peer = null


func _on_peer_connected(id: int) -> void:
	var s := PlayerState.new()
	s.pos = spawns[_spawn_index % spawns.size()]
	_spawn_index += 1
	clients[id] = {id = id, state = s, last_seq = 0, applied_usec = 0, score = 0, deaths = 0,
		protect_until = 0, respawn_tick = 0}
	print("[server] giocatore %d entrato (%d in partita)" % [id, clients.size()])


func _on_peer_disconnected(id: int) -> void:
	clients.erase(id)
	sim.forget_peer(id)
	print("[server] giocatore %d uscito (%d in partita)" % [id, clients.size()])


func _physics_process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		_handle_packet(pkt[0], pkt[1])
	tick += 1
	if tick % NetConfig.SNAPSHOT_EVERY == 0:
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
		Movement.simulate_move(c.state, cmd, Movement.DT)
		c.last_seq = cmd.seq
		c.applied_usec = Time.get_ticks_usec()


func _record_history() -> void:
	var players := {}
	for id in clients:
		players[id] = clients[id].state.copy()
	history.append({tick = tick, players = players})
	var max_entries := int(NetConfig.HISTORY_SECONDS * NetConfig.TICK_RATE / NetConfig.SNAPSHOT_EVERY) + 1
	while history.size() > max_entries:
		history.pop_front()


## Stato di `id` al tick frazionario `t`, interpolato dalla cronologia esattamente
## come lo interpola il client. null se `id` non c'è.
func state_at(id: int, t: float) -> Variant:
	if history.is_empty():
		return null
	var pair := bracket(history, t)
	return interpolate(pair[0], pair[1], id, t)


## I due elementi (con .tick) che racchiudono t; agli estremi lo stesso elemento due volte.
static func bracket(list: Array, t: float) -> Array:
	var a: Dictionary = list[0]
	var b: Dictionary = list[0]
	for e in list:
		b = e
		if e.tick >= t:
			break
		a = e
	return [a, b]


## Interpolazione condivisa da client (snapshot) e server (cronologia).
static func interpolate(a: Dictionary, b: Dictionary, id: int, t: float) -> Variant:
	if not b.players.has(id):
		return null
	var sb: PlayerState = b.players[id] if b.players[id] is PlayerState else b.players[id].state
	var sa: PlayerState = sb
	if a.players.has(id):
		sa = a.players[id] if a.players[id] is PlayerState else a.players[id].state
	if not sa.alive or not sb.alive:
		return sb.copy()  # morte/respawn: niente scivolamento attraverso la mappa
	var f := 0.0
	if b.tick > a.tick:
		f = clampf((t - a.tick) / float(b.tick - a.tick), 0.0, 1.0)
	var s: PlayerState = sb.copy()
	s.pos = sa.pos.lerp(sb.pos, f)
	s.yaw = lerp_angle(sa.yaw, sb.yaw, f)
	s.pitch = lerpf(sa.pitch, sb.pitch, f)
	return s


func _snapshot_players() -> Array:
	var out := []
	for id in clients:
		var c: Dictionary = clients[id]
		out.append({id = id, state = c.state, score = c.score, deaths = c.deaths,
			protected = tick < c.protect_until, respawn_ticks = maxi(c.respawn_tick - tick, 0) if not c.state.alive else 0})
	return out


func _send_snapshots() -> void:
	var players := _snapshot_players()
	var now := Time.get_ticks_usec()
	for id in clients:
		var c: Dictionary = clients[id]
		var hold_ms := int((now - c.applied_usec) / 1000) if c.last_seq > 0 else 0
		sim.send(id, Protocol.encode_snapshot(tick, c.last_seq, hold_ms, players, []))
