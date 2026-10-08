extends Node
## Server autoritativo. Tick e frequenza degli snapshot dal preset (NetConfig).
## Come in Quake III, i comandi di un client vengono eseguiti appena arrivano
## (ognuno vale esattamente un tick, Movement.dt()): il server non aspetta e non
## bufferizza, e il risultato è identico a quello predetto dal client.

const Movement = preload("res://proto2d/scripts/game/movement.gd")
const PlayerState = preload("res://proto2d/scripts/game/player_state.gd")
const Protocol = preload("res://proto2d/scripts/net/protocol.gd")
const NetSim = preload("res://proto2d/scripts/net/net_sim.gd")
const Weapon = preload("res://proto2d/scripts/game/weapon.gd")
const Map = preload("res://proto2d/scripts/game/map.gd")

const NetConfig = preload("res://proto2d/scripts/net/net_config.gd")
const HISTORY_SECONDS := 1.0

var sim: NetSim
var spawns: Array = Map.SPAWNS  # i test possono sostituirli
var bind_ip := "0.0.0.0"  # tutte le interfacce IPv4: raggiungibile anche da altri PC
var tick := 0
var clients := {}  # peer_id -> {id, state, last_seq, applied_usec, hits, deaths}
## Cronologia degli snapshot inviati: [{tick, pos: {id: Vector2}}], ~1 s.
var history: Array = []

## Lag compensation: se attiva, i colpi sono verificati contro le posizioni che
## il tiratore vedeva (view_tick del suo comando), non contro quelle attuali.
var lag_comp_enabled := true
var shots := 0
var hits_with_lag_comp := 0     # colpi che sarebbero andati a segno riavvolgendo
var hits_without_lag_comp := 0  # colpi che sarebbero andati a segno senza riavvolgere
var knockback := Weapon.KNOCKBACK
var hit_log: Array = []  # [usec, shooter_id, target_id] per ogni colpo a segno

## Culling anti-wallhack: ogni client riceve solo i giocatori che potrebbe vedere.
## Senza, un client modificato potrebbe mostrare tutti attraverso i muri.
var cull_enabled := true
const CULL_MARGIN := 8.0  # px di tolleranza extra attorno alle scatole

var _peer: ENetMultiplayerPeer
var _spawn_index := 0


func start(port: int, lag := 0.0, jitter := 0.0, loss := 0.0, seed_value := 0) -> Error:
	_peer = ENetMultiplayerPeer.new()
	_peer.set_bind_ip(bind_ip)
	var err := _peer.create_server(port, 32)
	if err != OK:
		_peer = null
		return err
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	sim = NetSim.new(_peer, seed_value)
	sim.configure(lag, jitter, loss)
	print("[server] in ascolto su %s:%d (lag %d ms, jitter %d ms, loss %d%%)" % [bind_ip, port, lag, jitter, loss * 100])
	print("[server] preset %s: tick %d Hz, snapshot %.0f Hz, interp %.2f ms, unlag max %d ms" % [
		NetConfig.preset_name, NetConfig.tick_rate, NetConfig.snapshot_rate(), NetConfig.interp_ms, NetConfig.max_unlag_ms])
	print("[server] IP locali: %s" % ", ".join(local_ipv4()))
	return OK


## Indirizzi IPv4 di questa macchina (esclusi loopback/link-local), da comunicare ai client in LAN.
static func local_ipv4() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.is_valid_ip_address() and not ":" in a and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


func stop() -> void:
	if _peer:
		_peer.close()
		_peer = null


func _on_peer_connected(id: int) -> void:
	var s := PlayerState.new()
	s.pos = spawns[_spawn_index % spawns.size()]
	_spawn_index += 1
	clients[id] = {id = id, state = s, last_seq = 0, applied_usec = 0, hits = 0, deaths = 0, delay_ticks = 0.0}
	print("[server] client %d connesso" % id)


func _on_peer_disconnected(id: int) -> void:
	clients.erase(id)
	sim.forget_peer(id)
	print("[server] client %d disconnesso" % id)


func _physics_process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		_handle_packet(pkt[0], pkt[1])
	tick += 1
	if tick % NetConfig.snapshot_every == 0:
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
		var fired := Movement.simulate_move(c.state, cmd, Movement.dt())
		if fired:
			_on_fire(c, cmd)
		c.last_seq = cmd.seq
		c.applied_usec = Time.get_ticks_usec()
		# Quanto è "indietro" ciò che vede questo client: ~RTT + interpolazione.
		# È la stessa quantità che la lag compensation riavvolge; qui serve al culling.
		var max_delay := NetConfig.tick_rate * HISTORY_SECONDS
		var delay := clampf(tick - cmd.view_tick, 0.0, max_delay)
		c.delay_ticks = delay if c.delay_ticks == 0.0 else lerpf(c.delay_ticks, delay, 0.1)


func _on_fire(shooter: Dictionary, cmd) -> void:
	var origin: Vector2 = shooter.state.pos  # il tiratore è nel "presente", come nella sua predizione
	var dir := Vector2.from_angle(cmd.aim)
	# Riavvolgi: non più indietro di max_unlag (200 ms in cs2, come sv_maxunlag) né nel futuro.
	var t := clampf(cmd.view_tick, tick - NetConfig.max_unlag_ms * NetConfig.tick_rate / 1000.0, tick)
	var rewound := {}
	var current := {}
	for id in clients:
		if id == shooter.id:
			continue
		current[id] = clients[id].state.pos
		var p = position_at(id, t)
		rewound[id] = p if p != null else current[id]

	var hit_rewound: int = Weapon.trace(origin, dir, rewound)[0]
	var hit_current: int = Weapon.trace(origin, dir, current)[0]
	shots += 1
	if hit_rewound != 0: hits_with_lag_comp += 1
	if hit_current != 0: hits_without_lag_comp += 1

	var hit_id := hit_rewound if lag_comp_enabled else hit_current
	if hit_id != 0:
		var target: Dictionary = clients[hit_id]
		shooter.hits += 1
		target.deaths += 1
		target.state.vel += dir * knockback
		hit_log.append([Time.get_ticks_usec(), shooter.id, hit_id])  # il client colpito non può predirlo: lo corregge la riconciliazione


func _record_history() -> void:
	var pos := {}
	for id in clients:
		pos[id] = clients[id].state.pos
	history.append({tick = tick, pos = pos})
	var max_entries := int(HISTORY_SECONDS * NetConfig.snapshot_rate()) + 1
	while history.size() > max_entries:
		history.pop_front()


func _send_snapshots() -> void:
	var players := clients.values()
	var config := [NetConfig.tick_rate, NetConfig.snapshot_every, NetConfig.interp_ms]
	var now := Time.get_ticks_usec()
	for id in clients:
		var c: Dictionary = clients[id]
		var visible := players
		if cull_enabled:
			visible = players.filter(func(o): return o.id == id or _potentially_visible(c, o))
		var hold_ms := int((now - c.applied_usec) / 1000) if c.last_seq > 0 else 0
		sim.send(id, Protocol.encode_snapshot(config, tick, c.last_seq, hold_ms, visible))


## Culling conservativo: `other` viene mandato a `viewer` se esiste linea di vista
## tra un punto qualsiasi della "scatola" in cui viewer può trovarsi sul proprio
## schermo e un punto della scatola in cui viewer può vedere `other`.
##   - viewer è predetto in avanti: scatola tra pos e pos + vel * ritardo
##   - other è mostrato nel passato (interpolazione): scatola tra pos e pos - vel * ritardo
## Le scatole includono il corpo del giocatore + CULL_MARGIN e si testano angoli e
## centro (5 x 5 raggi). Così l'avversario arriva PRIMA di diventare visibile
## (nessuna comparsa in ritardo), ma resta nascosto finché è davvero dietro un muro.
## Il ritardo è misurato dal server (tick - view_tick), limitato a 1 s.
func _potentially_visible(viewer: Dictionary, other: Dictionary) -> bool:
	var dt: float = viewer.delay_ticks / NetConfig.tick_rate
	var a := _reach_points(viewer.state.pos, viewer.state.pos + viewer.state.vel * dt)
	var b := _reach_points(other.state.pos, other.state.pos - other.state.vel * dt)
	for p in a:
		for q in b:
			if Map.line_of_sight(p, q):
				return true
	return false


static func _reach_points(p0: Vector2, p1: Vector2) -> Array:
	var half := Movement.PLAYER_SIZE * 0.5 + CULL_MARGIN
	var box := Rect2(p0, Vector2.ZERO).expand(p1).grow(half)
	return [box.get_center(), box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]


## Posizione di `id` al tick (frazionario) `t`, ricostruita dalla cronologia
## esattamente come la interpola il client (lerp tra due snapshot).
## Ritorna null se `id` non compare nella cronologia.
func position_at(id: int, t: float) -> Variant:
	if history.is_empty():
		return null
	var a: Dictionary = history[0]
	var b: Dictionary = history[0]
	for h in history:
		b = h
		if h.tick >= t:
			break
		a = h
	if not b.pos.has(id):
		return a.pos.get(id)
	var to: Vector2 = b.pos[id]
	var from: Vector2 = a.pos.get(id, to)
	var f := 0.0
	if b.tick > a.tick:
		f = clampf((t - a.tick) / float(b.tick - a.tick), 0.0, 1.0)
	return from.lerp(to, f)
