extends "res://tests/net_test_base.gd"
## Fase 3: sparo hitscan con lag compensation.
##   godot --headless --path . res://tests/test_phase3.tscn
## A. bersaglio a velocità costante (8 m/s), tiratore con 100 ms di ping che mira
##    al bersaglio come lo vede lui: deve colpirlo.
## B. bersaglio dietro il muro centrale, tiratore che mira alla sua capsula: il
##    raggio la attraverserebbe ma il muro è in mezzo, nessun colpo.
## C. client modificato che spara a ogni tick: il server accetta un colpo al
##    secondo e rifiuta gli altri.
## D. tiratore con ~300 ms di ping: la latenza supera il limite di rewind (200 ms),
##    il server riavvolge solo fino al limite e il colpo non va a segno (mentre con
##    rewind illimitato sarebbe andato a segno).
## Rete: jitter 10 ms e 5% di perdita per direzione su tutti i client.

const SHOOTER_POS := Vector3(0, 0.02, -9)
const LANE_START := Vector3(-16, 0.02, -18)   # il bersaglio corre lungo z = -18 verso +x
const BEHIND_WALL := Vector3(0, 0.02, -3)     # dall'altra parte del muro centrale
const SHOTS := 12
const MIN_HIT_RATE := 0.9


static func aim_at(eye: Vector3, point: Vector3) -> Dictionary:
	var d := (point - eye).normalized()
	return {yaw = atan2(-d.x, -d.z), pitch = asin(d.y)}


func run() -> void:
	print("\n=== Fase 3: sparo con lag compensation (rewind max %d ms, interp %d ms) ===" % [
		NetConfig.MAX_REWIND_MS, NetConfig.INTERP_MS])
	await _moving_target("A", 50.0, true)
	await _through_wall()
	await _cooldown_spam()
	await _moving_target("D", 150.0, false)


## A e D: il bersaglio corre a 8 m/s lungo la corsia; il tiratore spara quando lo
## vede a velocità piena nella parte centrale della corsia.
func _moving_target(name: String, lag: float, expect_hits: bool) -> void:
	print("\n--- %s. bersaglio a 8 m/s, tiratore con %d ms per direzione (ping ~%d ms) ---" % [name, lag, lag * 2])
	if not await start_match(2, [SHOOTER_POS, LANE_START], lag):
		return
	var shooter = clients[0]
	var target = clients[1]
	target.input_provider = func(_c, _s): return {buttons = InputCmd.RIGHT, yaw = 0.0, pitch = 0.0}
	shooter.input_provider = func(c, _s) -> Dictionary:
		var r = c.remote_states.get(target.my_id)
		if r == null or not r.alive:
			return {buttons = 0, yaw = 0.0, pitch = 0.0}
		var aim := aim_at(Movement.eye(c.state), r.pos + Movement.CENTER)
		aim.buttons = 0
		if c.state.cooldown == 0 and absf(r.vel.x) > 7.9 and absf(r.pos.x) < 10.0:
			aim.buttons = InputCmd.FIRE
		return aim
	var dead_for := {n = 0}
	await wait_until(func():
		var t: Dictionary = server.clients[target.my_id]
		if not t.state.alive:
			dead_for.n += 1
			if dead_for.n > 20:
				server.respawn_at(target.my_id, LANE_START)
				dead_for.n = 0
		elif t.state.pos.x > 15.0:
			server.respawn_at(target.my_id, LANE_START)
		return server.shot_log.size() >= SHOTS, 60 * 60)
	await ticks(60)  # lascia arrivare gli ultimi snapshot con le uccisioni

	var shots: Array = server.shot_log
	var hits := shots.filter(func(s): return s.hit == target.my_id).size()
	var unlimited := shots.filter(func(s): return s.hit_unlimited == target.my_id).size()
	var no_lc := shots.filter(func(s): return s.hit_no_lag_comp == target.my_id).size()
	var clamped := shots.filter(func(s): return s.clamped).size()
	var lat: Array = shots.map(func(s): return s.latency_ms)
	print("ping misurato dal tiratore %d ms | latenza compensata media %.0f ms (max %.0f) | oltre il limite: %d/%d" % [
		shooter.ping_ms, mean(lat), amax(lat), clamped, shots.size()])
	print("colpi a segno: %d/%d | con rewind illimitato sarebbero %d/%d | senza lag compensation %d/%d" % [
		hits, shots.size(), unlimited, shots.size(), no_lc, shots.size()])
	print("uccisioni decise dal server: %d | ricevute dal client del tiratore: %d | dal bersaglio: %d" % [
		server.next_kill_id - 1, shooter.kills_confirmed, target.kills_confirmed])
	check(shooter.kills_confirmed == hits and target.kills_confirmed == hits, "uccisioni non comunicate a tutti")
	check(shots.size() >= SHOTS, "troppi pochi spari")
	if expect_hits:
		check(hits >= shots.size() * MIN_HIT_RATE, "hit rate %d/%d < %.0f%%" % [hits, shots.size(), MIN_HIT_RATE * 100])
	else:
		check(clamped == shots.size(), "tutti i colpi dovrebbero superare il limite di rewind")
		check(hits <= shots.size() * 0.1, "oltre il limite di rewind il colpo non deve andare a segno (%d/%d)" % [hits, shots.size()])
		check(unlimited >= shots.size() * MIN_HIT_RATE, "controprova: con rewind illimitato avrebbe dovuto colpire (%d/%d)" % [unlimited, shots.size()])
	await stop_match()


func _through_wall() -> void:
	print("\n--- B. bersaglio dietro il muro centrale ---")
	if not await start_match(2, [SHOOTER_POS, BEHIND_WALL], 50.0):
		return
	var shooter = clients[0]
	var target = clients[1]
	shooter.input_provider = func(c, _s) -> Dictionary:
		var r = c.remote_states.get(target.my_id)
		if r == null:
			return {buttons = 0, yaw = 0.0, pitch = 0.0}
		var aim := aim_at(Movement.eye(c.state), r.pos + Movement.CENTER)
		aim.buttons = InputCmd.FIRE
		return aim
	await wait_until(func(): return server.shot_log.size() >= 5, 60 * 15)
	var shots: Array = server.shot_log
	var hits := shots.filter(func(s): return s.hit != 0).size()
	var blocked := shots.filter(func(s): return s.blocked == target.my_id).size()
	print("spari %d | a segno %d | capsula sulla traiettoria ma muro in mezzo: %d | bersaglio vivo: %s" % [
		shots.size(), hits, blocked, server.clients[target.my_id].state.alive])
	check(shots.size() >= 5, "troppi pochi spari")
	check(hits == 0, "un colpo è passato attraverso il muro")
	check(blocked == shots.size(), "controprova: senza il muro il raggio avrebbe colpito la capsula")
	await stop_match()


func _cooldown_spam() -> void:
	print("\n--- C. client modificato che spara a ogni tick (cooldown %d tick = 1 s) ---" % Movement.FIRE_COOLDOWN_TICKS)
	if not await start_match(1, [SHOOTER_POS], 50.0):
		return
	var cheater = clients[0]
	cheater.honor_cooldown = false
	var hold := 180
	var first: int = cheater.seq + 1
	cheater.input_provider = func(_c, seq: int) -> Dictionary:
		return {buttons = InputCmd.FIRE if seq >= first and seq < first + hold else 0, yaw = PI, pitch = 0.0}
	await wait_until(func(): return cheater.seq > first + hold + 60, 60 * 10)
	await ticks(30)
	var accepted: Array = server.shot_log.map(func(s): return s.seq)
	var gaps: Array = []
	for i in range(1, accepted.size()):
		gaps.append(accepted[i] - accepted[i - 1])
	print("FIRE inviati per %d tick | accettati %d (seq %s) | rifiutati per cooldown %d" % [
		hold, accepted.size(), accepted, server.rejected_cooldown])
	check(accepted.size() == ceili(hold / float(Movement.FIRE_COOLDOWN_TICKS)), "numero di colpi accettati sbagliato")
	check(gaps.all(func(g): return g >= Movement.FIRE_COOLDOWN_TICKS), "due colpi accettati a meno di 1 s")
	check(server.rejected_cooldown >= hold - accepted.size() - 5, "il server non ha rifiutato i colpi in cooldown")
	await stop_match()
