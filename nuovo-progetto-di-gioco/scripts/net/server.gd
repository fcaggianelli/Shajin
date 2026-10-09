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
const Weapon = preload("res://scripts/game/weapon.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")

## Tolleranza tra l'origine del raggio dichiarata dal client e l'occhio calcolato
## dal server per lo stesso comando (identici se la predizione è esatta).
const MAX_ORIGIN_ERROR := 0.3

const MAX_PLAYERS := 8
const RESPAWN_TICKS := 3 * NetConfig.TICK_RATE      # 3 s da morto
const PROTECTION_TICKS := 2 * NetConfig.TICK_RATE   # 2 s di protezione dopo il respawn

var sim: NetSim
var bind_ip := "0.0.0.0"
var spawns: Array = Level.SPAWNS  # spawn all'ingresso: i test li fissano in ordine
var ordered_join_spawns := false  # true: all'ingresso spawns[0], spawns[1]... (test)
var tick := 0
## peer_id -> {id, state, last_seq, applied_usec, score, deaths, protect_until, respawn_tick}
var clients := {}
## Cronologia agli istanti degli snapshot (~1 s): [{tick, players: {id: PlayerState}}].
## È esattamente ciò che i client interpolano: serve al rewind della fase 3.
var history: Array = []

# --- Arma ---
var lag_comp_enabled := true
var next_kill_id := 1
var kills: Array = []           # [kill_id, killer, victim], le ultime vanno negli snapshot
var shot_log: Array = []        # un Dictionary per ogni sparo accettato (statistiche/test)
var rejected_cooldown := 0      # FIRE arrivati prima della fine del cooldown
var rejected_origin := 0        # origine o direzione del raggio non credibili
var rewind_clamped := 0         # colpi con latenza oltre MAX_REWIND_MS (rewind limitato)

var _peer: ENetMultiplayerPeer
var _spawn_index := 0
var _kill_pending := false


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
	if ordered_join_spawns:
		s.pos = spawns[_spawn_index % spawns.size()]
		_spawn_index += 1
	else:
		s.pos = farthest_spawn(id)
	clients[id] = {id = id, state = s, last_seq = 0, applied_usec = 0, score = 0, deaths = 0,
		protect_until = 0, respawn_tick = 0}
	print("[server] giocatore %d entrato (%d in partita)" % [id, clients.size()])


func _on_peer_disconnected(id: int) -> void:
	clients.erase(id)
	sim.forget_peer(id)
	print("[server] giocatore %d uscito (%d in partita)" % [id, clients.size()])


## Fuori dal tick il server legge la rete a ogni frame (un server dedicato
## headless gira a ~1000 fps) ed esegue subito i comandi arrivati, come Q3: un
## comando non aspetta il tick successivo (fino a 16.7 ms). Le uccisioni partono
## subito in uno snapshot. Le query fisiche sono sicure qui: la fisica gira nel
## thread principale e fuori dallo step.
func _process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		_handle_packet(pkt[0], pkt[1])
	if _kill_pending:
		_kill_pending = false
		_record_history()
		_send_snapshots()
	sim.flush()


func _physics_process(_delta: float) -> void:
	if _peer == null:
		return
	for pkt in sim.poll():
		_handle_packet(pkt[0], pkt[1])
	tick += 1
	_respawn_dead()
	# Snapshot a 20 Hz, più uno immediato quando c'è un'uccisione: così la morte
	# arriva ai client senza aspettare lo snapshot successivo (fino a 50 ms).
	if tick % NetConfig.SNAPSHOT_EVERY == 0 or _kill_pending:
		_kill_pending = false
		_record_history()
		_send_snapshots()
	sim.flush()


func _handle_packet(from: int, data: PackedByteArray) -> void:
	var opened := Protocol.open(data)
	if opened[0] != Protocol.TYPE_INPUT or not clients.has(from):
		return
	var c: Dictionary = clients[from]
	for cmd in Protocol.decode_input(opened[1]):
		if cmd.seq <= c.last_seq:
			continue  # duplicato (ridondanza) o vecchio
		var wants_fire: bool = cmd.buttons & InputCmd.FIRE != 0 and c.state.alive
		var fired := Movement.simulate_move(c.state, cmd, Movement.DT)
		if fired:
			_on_fire(c, cmd)
		elif wants_fire:
			rejected_cooldown += 1  # troppo presto: il cooldown (1 s) non è finito
		c.last_seq = cmd.seq
		c.applied_usec = Time.get_ticks_usec()


func _record_history() -> void:
	var players := {}
	for id in clients:
		players[id] = clients[id].state.copy()
	if not history.is_empty() and history[-1].tick == tick:
		history[-1] = {tick = tick, players = players}  # snapshot extra nello stesso tick
	else:
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


## Sparo hitscan con lag compensation.
## Il comando porta shot_time = tick server che il client stimava di vivere; il
## client vedeva gli altri a shot_time - INTERP. La latenza compensata
## (tick - shot_time) è limitata a MAX_REWIND_MS: oltre, si usa il limite.
func _on_fire(shooter: Dictionary, cmd) -> void:
	var eye := Movement.eye(shooter.state)
	var dir: Vector3 = cmd.shot_dir
	if cmd.shot_origin.distance_to(eye) > MAX_ORIGIN_ERROR or absf(dir.length() - 1.0) > 0.01:
		rejected_origin += 1
		return
	dir = dir.normalized()
	var interp := NetConfig.ms_to_ticks(NetConfig.INTERP_MS)
	var max_latency := NetConfig.ms_to_ticks(NetConfig.MAX_REWIND_MS)
	var latency := maxf(tick - cmd.shot_time, 0.0)
	var clamped := latency > max_latency
	if clamped:
		rewind_clamped += 1
	var t := tick - minf(latency, max_latency) - interp

	var rewound := _targets_at(shooter.id, t)
	var result := Weapon.trace(cmd.shot_origin, dir, rewound if lag_comp_enabled else _targets_now(shooter.id))
	shot_log.append({
		shooter = shooter.id, tick = tick, seq = cmd.seq, latency_ms = latency * 1000.0 / NetConfig.TICK_RATE, clamped = clamped,
		hit = result.id, blocked = result.blocked_id,
		# solo per statistiche: cosa sarebbe successo senza limite / senza lag compensation
		hit_unlimited = Weapon.trace(cmd.shot_origin, dir, _targets_at(shooter.id, tick - latency - interp)).id,
		hit_no_lag_comp = Weapon.trace(cmd.shot_origin, dir, _targets_now(shooter.id)).id,
	})
	if result.id != 0:
		_kill(shooter, clients[result.id])


## Bersagli validi (vivi, non protetti) riavvolti al tick t: {id: piedi}.
func _targets_at(shooter_id: int, t: float) -> Dictionary:
	var out := {}
	for id in clients:
		if id == shooter_id or not _can_be_hit(clients[id]):
			continue
		var s = state_at(id, t)
		if s != null and s.alive:
			out[id] = s.pos
	return out


func _targets_now(shooter_id: int) -> Dictionary:
	var out := {}
	for id in clients:
		if id != shooter_id and _can_be_hit(clients[id]):
			out[id] = clients[id].state.pos
	return out


func _can_be_hit(c: Dictionary) -> bool:
	return c.state.alive and tick >= c.protect_until


## Il server decide l'uccisione; la comunica a tutti negli snapshot.
func _kill(killer: Dictionary, victim: Dictionary) -> void:
	victim.state.alive = false
	victim.state.vel = Vector3.ZERO
	victim.deaths += 1
	victim.respawn_tick = tick + RESPAWN_TICKS
	killer.score += 1
	kills.append([next_kill_id, killer.id, victim.id])
	next_kill_id = (next_kill_id % 65535) + 1
	_kill_pending = true
	while kills.size() > 8:
		kills.pop_front()
	print("[server] %d ha ucciso %d" % [killer.id, victim.id])


func _respawn_dead() -> void:
	for id in clients:
		var c: Dictionary = clients[id]
		if not c.state.alive and tick >= c.respawn_tick:
			respawn_at(id, farthest_spawn(id))
			c.protect_until = tick + PROTECTION_TICKS


## Lo spawn del livello più lontano dai giocatori vivi (massimizza la distanza
## dal più vicino). Senza altri giocatori vivi: il primo.
func farthest_spawn(exclude_id: int) -> Vector3:
	var best: Vector3 = Level.SPAWNS[0]
	var best_d := -1.0
	for sp in Level.SPAWNS:
		var nearest := INF
		for id in clients:
			if id != exclude_id and clients[id].state.alive:
				nearest = minf(nearest, sp.distance_to(clients[id].state.pos))
		if nearest > best_d:
			best_d = nearest
			best = sp
	return best


## Riporta in vita `id` in `pos` (usato dal ciclo di respawn e dai test).
func respawn_at(id: int, pos: Vector3) -> void:
	var s: PlayerState = clients[id].state
	s.pos = pos
	s.vel = Vector3.ZERO
	s.alive = true
	s.on_ground = false


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
		sim.send(id, Protocol.encode_snapshot(tick, c.last_seq, hold_ms, players, kills.slice(-4)))
