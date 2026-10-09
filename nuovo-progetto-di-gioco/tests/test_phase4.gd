extends "res://tests/net_test_base.gd"
## Fase 4: ciclo di partita.
##   godot --headless --path . res://tests/test_phase4.tscn
## 3 client (100 ms/direzione, jitter, 5% perdita): A spara a B fermo.
##  1. uccisione: B morto sul server e su tutti i client; punteggio di A +1
##  2. respawn dopo 3 s nello spawn più lontano dai giocatori vivi
##  3. protezione di 2 s: i colpi durante la protezione non uccidono, dopo sì
##  4. un nuovo giocatore entra a partita in corsa e vede gli altri (e viceversa)
##  5. un giocatore si disconnette: sparisce da tutti gli altri client
##  6. limite di 8 giocatori: il nono non entra

const A_POS := Vector3(0, 0.02, -9)
const B_POS := Vector3(0, 0.02, -17)
const C_POS := Vector3(15, 0.02, 15)

var _a
var _b
var _c


static func aim_at(eye: Vector3, point: Vector3) -> Dictionary:
	var d := (point - eye).normalized()
	return {yaw = atan2(-d.x, -d.z), pitch = asin(d.y)}


func run() -> void:
	print("\n=== Fase 4: ciclo di partita | lag %d ms/direzione, jitter %d ms, loss %d%%/direzione ===" % [
		LAG_MS, JITTER_MS, LOSS * 100])
	if not await start_match(3, [A_POS, B_POS, C_POS]):
		return
	_a = clients[0]
	_b = clients[1]
	_c = clients[2]
	var fire := {on = true}
	_a.input_provider = func(c, _s) -> Dictionary:
		var r = c.remote_states.get(_b.my_id)
		if r == null or not r.alive:
			return {buttons = 0, yaw = 0.0, pitch = 0.0}
		var aim := aim_at(Movement.eye(c.state), r.pos + Movement.CENTER)
		aim.buttons = InputCmd.FIRE if fire.on else 0
		return aim
	await _kill_and_respawn()
	fire.on = false
	await _join_and_leave()
	await stop_match()
	await _player_cap()


func _kill_and_respawn() -> void:
	print("\n--- 1-3. uccisione, respawn, protezione, punteggio ---")
	var sb: Dictionary = server.clients[_b.my_id]
	if not await wait_until(func(): return not sb.state.alive, 10 * S):
		check(false, "B non è stato ucciso")
		return
	var kill_tick: int = server.tick
	print("B ucciso al tick %d" % kill_tick)
	var seen := await wait_until(func():
		return clients.all(func(c): return c.players_info.has(_b.my_id) and not c.players_info[_b.my_id].alive), 2 * S)
	print("morte di B vista da tutti i client: %s | B vede la propria morte: %s" % [seen, not _b.state.alive])
	check(seen and not _b.state.alive, "la morte non è arrivata a tutti")
	check(server.clients[_a.my_id].score == 1 and sb.deaths == 1, "punteggio sbagliato")

	# Spawn atteso: il più lontano da A e C (vivi) al momento del respawn.
	var expected := Level.SPAWNS[0]
	var best := -1.0
	for sp in Level.SPAWNS:
		var d := minf(sp.distance_to(server.clients[_a.my_id].state.pos), sp.distance_to(server.clients[_c.my_id].state.pos))
		if d > best:
			best = d
			expected = sp
	await wait_until(func(): return sb.state.alive, 4 * S)
	var respawn_tick: int = server.tick
	print("respawn dopo %d tick (%.2f s) in %s | spawn atteso (più lontano dai vivi) %s | protetto fino al tick %d" % [
		respawn_tick - kill_tick, (respawn_tick - kill_tick) / float(S), sb.state.pos, expected, sb.protect_until])
	check(absi(respawn_tick - kill_tick - server.RESPAWN_TICKS) <= 1, "respawn non dopo 3 s")
	check(sb.state.pos.distance_to(expected) < 0.2, "spawn non è il più lontano dai giocatori vivi")

	# A si sposta (teletrasporto di test) in vista del punto di respawn e continua a sparare.
	var toward_center := Vector3(-sb.state.pos.x, 0, -sb.state.pos.z).normalized()
	server.respawn_at(_a.my_id, sb.state.pos + toward_center * 6.0)
	var shots_before: int = server.shot_log.size()
	var protected_seen := await wait_until(func():
		return _a.players_info.get(_b.my_id, {}).get("protected", false), 60)
	await wait_until(func(): return not sb.state.alive, 6 * S)
	var shots: Array = server.shot_log.slice(shots_before)
	var during := shots.filter(func(s): return s.tick < sb.protect_until)
	var kill_shot = shots.filter(func(s): return s.hit == _b.my_id)
	print("protezione vista dal client di A: %s | spari durante la protezione: %d (a segno %d) | uccisione al tick %s (protezione fino a %d)" % [
		protected_seen, during.size(), during.filter(func(s): return s.hit != 0).size(),
		kill_shot[0].tick if not kill_shot.is_empty() else "-", sb.protect_until])
	check(protected_seen, "i client non vedono la protezione")
	check(during.size() >= 1 and during.all(func(s): return s.hit == 0), "un colpo durante la protezione è andato a segno")
	check(not kill_shot.is_empty() and kill_shot[0].tick >= sb.protect_until, "dopo la protezione il colpo deve uccidere")
	await ticks(S / 2)
	var scores: Array = clients.map(func(c): return c.players_info.get(_a.my_id, {}).get("score", -1))
	print("punteggio di A sul server %d, visto dai client %s" % [server.clients[_a.my_id].score, scores])
	check(server.clients[_a.my_id].score == 2 and scores.all(func(s): return s == 2), "punteggio non aggiornato ovunque")


func _join_and_leave() -> void:
	print("\n--- 4-5. ingresso e uscita a partita in corso ---")
	server.ordered_join_spawns = false  # da qui in poi lo spawn della partita vera
	var expected: Vector3 = server.farthest_spawn(0)
	var d = await add_client(port, LAG_MS, JITTER_MS, LOSS, 777)
	if d == null:
		return
	var others_seen := await wait_until(func():
		return [_a, _b, _c].all(func(c): return c.remote_states.has(d.my_id)) \
			and [_a, _b, _c].all(func(c): return d.remote_states.has(c.my_id) or not server.clients[c.my_id].state.alive), 2 * S)
	print("D entra: vede gli altri e gli altri vedono D: %s | punteggio di D %d | spawn di D %s (atteso il più lontano: %s)" % [
		others_seen, server.clients[d.my_id].score, server.clients[d.my_id].state.pos, expected])
	check(others_seen, "il nuovo giocatore non è sincronizzato")
	check(server.clients[d.my_id].state.pos.distance_to(expected) < 0.5, "spawn d'ingresso non è il più lontano")
	var c_id: int = _c.my_id
	_c.stop()
	var gone := await wait_until(func():
		return not server.clients.has(c_id) and [_a, _b, d].all(func(c): return not c.remote_states.has(c_id) and not c.players_info.has(c_id)), 5 * S)
	print("C si disconnette: rimosso dal server e da tutti i client: %s (%d giocatori rimasti)" % [gone, server.clients.size()])
	check(gone, "il giocatore disconnesso non è stato rimosso ovunque")
	# La partita continua: A riprende a sparare a B.
	var kills_before: int = server.next_kill_id
	_a.input_provider = func(c, _s) -> Dictionary:
		var r = c.remote_states.get(_b.my_id)
		if r == null or not r.alive:
			return {buttons = 0, yaw = 0.0, pitch = 0.0}
		var aim := aim_at(Movement.eye(c.state), r.pos + Movement.CENTER)
		aim.buttons = InputCmd.FIRE
		return aim
	var continued := await wait_until(func(): return server.next_kill_id > kills_before, 8 * S)
	print("la partita continua dopo l'uscita (nuova uccisione): %s" % continued)
	check(continued, "la partita non continua dopo una disconnessione")


func _player_cap() -> void:
	print("\n--- 6. massimo 8 giocatori ---")
	if not await start_match(8, [], 0.0, 0.0, 0.0):
		return
	var ninth := Client.new()
	ninth.local_view = false
	add_child(ninth)
	var refused := {v = false}
	ninth.disconnected.connect(func(_w): refused.v = true)
	ninth.start("127.0.0.1", port)
	await wait_until(func(): return refused.v or ninth.is_ready(), 7 * S)
	print("8 giocatori connessi: %d sul server | il nono rifiutato: %s" % [server.clients.size(), refused.v and not ninth.is_ready()])
	check(server.clients.size() == 8 and refused.v and not ninth.is_ready(), "il limite di 8 giocatori non funziona")
	ninth.queue_free()
	await stop_match()
