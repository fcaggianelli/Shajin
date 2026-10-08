extends Node
## Test headless del netcode:
##   godot --headless --path . res://tests/test_netcode.tscn
## 1 server + 2 client nello stesso processo (veri socket ENet su localhost),
## input scriptati, 100 ms di latenza per direzione (+jitter) e 5% di perdita
## per direzione sui client. Exit code 0 = PASS, 1 = FAIL.

const Server = preload("res://scripts/net/server.gd")
const Client = preload("res://scripts/net/client.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")
const NetConfig = preload("res://scripts/net/net_config.gd")
const Map = preload("res://scripts/game/map.gd")

const LAG_MS := 100.0
const JITTER_MS := 10.0
const LOSS := 0.05
const INPUT_TICKS := 600     # 10 s di input scriptati
const SETTLE_TICKS := 120    # 2 s fermi per far convergere tutto
const MAX_MEAN_ERROR := 0.5  # px: soglia sull'errore medio di predizione
const MAX_FINAL_ERROR := 0.01  # px: client e server devono coincidere alla fine
const MAX_INTERP_MEAN_ERROR := 5.0  # px: remoti interpolati vs verità del server
const MIN_LAG_COMP_HIT_RATE := 0.9  # fase 2: mirando dove si VEDE il bersaglio si deve colpire
const SHOOT_TICKS := 600
# Scenario E (peeker's advantage): connessione "da Internet" realistica.
const PEEK_LAG_MS := 30.0      # per direzione: ping ~60 ms + quantizzazione
const PEEK_JITTER_MS := 5.0
const PEEK_LOSS := 0.01
const PEEK_EPISODES := 8
const MAX_LATE_REVEAL := 0.02  # culling: al massimo il 2% dei tick visibili senza dati (snapshot persi)
const HOLD_POS := Vector2(120, 520)  # chi tiene l'angolo (vedi Map)
const PEEK_POS := Vector2(520, 520)  # chi sbuca da dietro il muro

const PATTERN := [  # client 0: [buttons, durata in tick]
	[InputCmd.RIGHT, 50], [InputCmd.DOWN, 40], [InputCmd.LEFT | InputCmd.UP, 60],
	[0, 20], [InputCmd.UP, 30], [InputCmd.RIGHT | InputCmd.DOWN, 70], [InputCmd.LEFT, 80],
]


func _ready() -> void:
	var ok := true
	var scenarios := [
		{name = "A  prediction+reconciliation, ridondanza ON", assert_error = true},
		{name = "B  ridondanza OFF (il server perde input)", redundancy = false, only = "cs2"},
		{name = "C  ridondanza OFF + reconciliation OFF", redundancy = false, reconciliation = false, expect_drift = true, only = "cs2"},
	]
	var peek := {}
	for preset in ["cs2", "q3"]:
		NetConfig.apply_preset(preset)
		print("\n=== Preset %s (tick %d Hz, snapshot %.0f Hz, interp %.2f ms, unlag %d ms) | lag %d ms/direzione, jitter %d ms, loss %d%%/direzione ===" % [
			preset, NetConfig.tick_rate, NetConfig.snapshot_rate(), NetConfig.interp_ms, NetConfig.max_unlag_ms, LAG_MS, JITTER_MS, LOSS * 100])
		for sc in scenarios:
			if sc.get("only", preset) == preset:
				ok = (await _run_movement(sc)) and ok
		# La rewind richiesta è circa RTT + interp. Con 100 ms/direzione (ping ~255 ms)
		# supera i 200 ms di sv_maxunlag del preset cs2: lì il colpo non è più del
		# tutto compensato, come in CS2. Si verifica quindi a 50 ms/direzione e si
		# riporta il caso a 100 ms come informativo.
		var within := NetConfig.max_unlag_ms >= 1000.0
		ok = (await _run_lag_comp(LAG_MS, within)) and ok
		if not within:
			ok = (await _run_lag_comp(50.0, true)) and ok
		var r: Dictionary = await _run_peek(true)
		ok = r.ok and ok
		peek[preset] = r.adv
		if preset == "cs2":
			var off: Dictionary = await _run_peek(false)  # informativo: cosa succede senza culling
			print("Culling cs2: vantaggio del peeker %.0f ms con culling, %.0f ms senza | fughe %d/%d tick con culling, %d/%d senza" % [
				r.adv, off.adv, r.leak, r.hide_ticks, off.leak, off.hide_ticks])

	# Il peeker deve avere un vantaggio, e il preset competitivo deve ridurlo.
	print("\nPeeker's advantage medio: cs2 %.0f ms, q3 %.0f ms" % [peek.cs2, peek.q3])
	if not (peek.cs2 > 0.0 and peek.q3 > peek.cs2):
		print("  FAIL: atteso 0 < vantaggio cs2 < vantaggio q3")
		ok = false
	print("\nRISULTATO: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _scripted_input(index: int) -> Callable:
	return func(_client, seq: int) -> Dictionary:
		if seq > INPUT_TICKS:
			return {buttons = 0, aim = 0.0}
		if index == 0:
			var t := seq % 350
			for step in PATTERN:
				if t < step[1]:
					return {buttons = step[0], aim = 0.0}
				t -= step[1]
			return {buttons = 0, aim = 0.0}
		# client 1: direzione pseudo-casuale (deterministica) ogni 15 tick
		return {buttons = hash(seq / 15 * 7919) & 15, aim = 0.0}


func _run_movement(sc: Dictionary) -> bool:
	print("\n--- Scenario %s ---" % sc.name)
	var port := 30000 + randi() % 20000
	var server := Server.new()
	add_child(server)
	if server.start(port) != OK:
		print("FAIL: server non avviato")
		return false
	var clients: Array = []
	for i in 2:
		var c := Client.new()
		add_child(c)
		c.start("127.0.0.1", port, LAG_MS, JITTER_MS, LOSS, 1234 + i)
		c.input_provider = _scripted_input(i)
		c.redundancy_enabled = sc.get("redundancy", true)
		c.reconciliation_enabled = sc.get("reconciliation", true)
		clients.append(c)

	var interp_errors: Array = []
	var waited := 0
	while not clients.all(func(c): return c.is_ready()):
		await get_tree().physics_frame
		waited += 1
		if waited > 600:
			print("FAIL: i client non si sono connessi")
			return false
	var spawn := {}
	var max_disp := 0.0
	for c in clients:
		spawn[c.my_id] = c.state.pos

	while clients.any(func(c): return c.seq < INPUT_TICKS + SETTLE_TICKS):
		await get_tree().physics_frame
		for c in clients:
			max_disp = maxf(max_disp, c.state.pos.distance_to(spawn[c.my_id]))
			for id in c.remote_positions:
				var truth = server.position_at(id, c.render_tick)
				if truth != null:
					interp_errors.append(c.remote_positions[id].distance_to(truth))

	var ok := true
	var all_errors: Array = []
	for c in clients:
		all_errors.append_array(c.errors)
		var final_err: float = c.state.pos.distance_to(server.clients[c.my_id].state.pos)
		var mean: float = c.err_sum / maxf(c.err_count, 1)
		print("client %d: ping %3d ms | riconciliazioni %d | errore predizione medio %.4f px, max %.4f px | correzione visiva max %.4f px | errore finale %.4f px | pacchetti persi out %d in %d" % [
			c.my_id, c.ping_ms, c.err_count, mean, c.err_max, c.correction_max, final_err, c.sim.dropped_out, c.sim.dropped_in])
		if sc.get("expect_drift", false):
			continue
		if final_err > MAX_FINAL_ERROR:
			print("  FAIL: client e server non convergono (%.4f > %.4f px)" % [final_err, MAX_FINAL_ERROR])
			ok = false
	var mean_all := _mean(all_errors)
	var max_all: float = all_errors.max() if not all_errors.is_empty() else 0.0
	var interp_mean := _mean(interp_errors)
	var interp_max: float = interp_errors.max() if not interp_errors.is_empty() else 0.0
	print("TOTALE errore predetto vs server: medio %.4f px, max %.4f px su %d misure" % [mean_all, max_all, all_errors.size()])
	print("TOTALE interpolazione remoti vs server: medio %.4f px, max %.4f px su %d campioni" % [interp_mean, interp_max, interp_errors.size()])
	print("spostamento massimo dallo spawn: %.1f px" % max_disp)

	if max_disp < 100.0:
		print("  FAIL: i giocatori non si sono mossi")
		ok = false
	if all_errors.size() < 100:
		print("  FAIL: troppe poche riconciliazioni misurate")
		ok = false
	if sc.get("assert_error", false):
		if mean_all > MAX_MEAN_ERROR:
			print("  FAIL: errore medio %.4f > soglia %.4f px" % [mean_all, MAX_MEAN_ERROR])
			ok = false
		if interp_mean > MAX_INTERP_MEAN_ERROR:
			print("  FAIL: errore medio di interpolazione %.4f > soglia %.4f px" % [interp_mean, MAX_INTERP_MEAN_ERROR])
			ok = false
	print("Scenario: %s" % ("OK" if ok else "FAIL"))

	for c in clients:
		c.stop()
		c.queue_free()
	server.stop()
	server.queue_free()
	for i in 10:
		await get_tree().physics_frame
	return ok


## Fase 2: il client 0 sta fermo e spara ogni 12 tick esattamente al centro del
## client 1 COME LO VEDE (posizione interpolata, ~100 ms + latenza nel passato).
## Il client 1 corre su e giù a velocità massima. Il server conta sia i colpi
## validi riavvolgendo (lag compensation) sia quelli che varrebbero senza.
func _run_lag_comp(lag_ms: float, check_hit_rate: bool) -> bool:
	print("\n--- Scenario D  hitscan con lag compensation (lag %d ms/direzione%s) ---" % [
		lag_ms, "" if check_hit_rate else ", oltre sv_maxunlag: solo informativo"])
	var port := 30000 + randi() % 20000
	var server := Server.new()
	server.spawns = [Vector2(150, 200), Vector2(720, 200)]  # linea di tiro libera dai muri
	add_child(server)
	if server.start(port) != OK:
		print("FAIL: server non avviato")
		return false
	var shooter := Client.new()
	var runner := Client.new()
	for c in [shooter, runner]:
		add_child(c)
		c.start("127.0.0.1", port, lag_ms, JITTER_MS, LOSS, 99 + c.get_index())
	shooter.input_provider = func(c, seq: int) -> Dictionary:
		if seq > SHOOT_TICKS or seq % 12 != 0 or not c.remote_positions.has(runner.my_id):
			return {buttons = 0, aim = 0.0}
		var target: Vector2 = c.remote_positions[runner.my_id]
		if not Map.line_of_sight(c.state.pos, target):
			return {buttons = 0, aim = 0.0}  # spara solo se lo vede (le spinte possono mandarlo dietro un muro)
		return {buttons = InputCmd.FIRE, aim = (target - c.state.pos).angle()}
	runner.input_provider = func(_c, seq: int) -> Dictionary:
		if seq > SHOOT_TICKS:
			return {buttons = 0, aim = 0.0}  # si ferma, per poter confrontare con il server
		return {buttons = InputCmd.DOWN if (seq / 30) % 2 == 0 else InputCmd.UP, aim = 0.0}

	var waited := 0
	while not (shooter.is_ready() and runner.is_ready()):
		await get_tree().physics_frame
		waited += 1
		if waited > 600:
			print("FAIL: i client non si sono connessi")
			return false
	while shooter.seq < SHOOT_TICKS + SETTLE_TICKS or runner.seq < SHOOT_TICKS + SETTLE_TICKS:
		await get_tree().physics_frame

	var rate_lc := server.hits_with_lag_comp / maxf(server.shots, 1)
	var rate_no := server.hits_without_lag_comp / maxf(server.shots, 1)
	var final_err: float = runner.state.pos.distance_to(server.clients[runner.my_id].state.pos)
	print("colpi sparati %d | a segno CON lag compensation %d (%.0f%%) | SENZA %d (%.0f%%)" % [
		server.shots, server.hits_with_lag_comp, rate_lc * 100, server.hits_without_lag_comp, rate_no * 100])
	print("bersaglio: colpi subiti (dal suo snapshot) %d | errore predizione medio %.4f px, max %.4f px (spinte non predicibili) | errore finale %.4f px" % [
		runner.my_deaths, runner.err_sum / maxf(runner.err_count, 1), runner.err_max, final_err])
	var ok := true
	if server.shots < 30:
		print("  FAIL: troppi pochi colpi sparati")
		ok = false
	if check_hit_rate and rate_lc < MIN_LAG_COMP_HIT_RATE:
		print("  FAIL: hit rate con lag compensation %.2f < %.2f" % [rate_lc, MIN_LAG_COMP_HIT_RATE])
		ok = false
	if final_err > MAX_FINAL_ERROR:
		print("  FAIL: il bersaglio spinto non converge col server (%.4f px)" % final_err)
		ok = false
	print("Scenario: %s" % ("OK" if ok else "FAIL"))
	for c in [shooter, runner]:
		c.stop()
		c.queue_free()
	server.stop()
	server.queue_free()
	return ok


## Scenario E: peeker's advantage. H sta fermo a HOLD_POS e tiene l'angolo; P è
## nascosto dietro il muro a PEEK_POS, sbuca verso l'alto, spara appena vede H e
## rientra. Entrambi i bot reagiscono in 0 ms (sparano al primo frame in cui
## vedono l'altro). Per ogni peek misuriamo, in tempo reale:
##   - quando il SERVER ha per la prima volta linea di vista tra i due
##   - quando P vede H sul suo schermo (posizione predetta vs H interpolato)
##   - quando H vede P sul suo schermo (posizione propria vs P interpolato)
##   - chi dei due va a segno per primo sul server.
## Ritorna il vantaggio medio in ms (tH - tP), o -1 se lo scenario fallisce.
##
## Con il culling lato server misura anche:
##   - fughe: tick in cui il peeker è fermo e nascosto dietro il muro ma il client
##     di chi tiene l'angolo riceve comunque la sua posizione (wallhack possibile)
##   - comparse in ritardo: tick in cui un avversario sarebbe visibile sullo schermo
##     (linea di vista verso dove dovrebbe essere disegnato) ma non è nello snapshot.
func _run_peek(cull: bool) -> Dictionary:
	print("\n--- Scenario E  peeker's advantage, culling lato server %s (lag %d ms/direzione, jitter %d ms, loss %d%%) ---" % [
		"ON" if cull else "OFF (solo informativo)", PEEK_LAG_MS, PEEK_JITTER_MS, PEEK_LOSS * 100])
	var fail := {ok = false, adv = -1.0, leak = 0, hide_ticks = 0, late = 0, vis_ticks = 0}
	var port := 30000 + randi() % 20000
	var server := Server.new()
	server.spawns = [HOLD_POS, PEEK_POS]
	server.knockback = 0.0  # niente spinte: le posizioni restano quelle del copione
	server.cull_enabled = cull
	add_child(server)
	if server.start(port) != OK:
		print("FAIL: server non avviato")
		return fail
	var holder := Client.new()
	var peeker := Client.new()
	# Connessione in ordine, così holder prende HOLD_POS e peeker PEEK_POS.
	for c in [holder, peeker]:
		add_child(c)
		c.start("127.0.0.1", port, PEEK_LAG_MS, PEEK_JITTER_MS, PEEK_LOSS, 7 + c.get_index())
		c.input_provider = func(_c, _s): return {buttons = 0, aim = 0.0}
		var waited := 0
		while not c.is_ready():
			await get_tree().physics_frame
			waited += 1
			if waited > 600:
				print("FAIL: i client non si sono connessi")
				return fail

	holder.input_provider = func(c, _seq: int) -> Dictionary:
		if c.can_see(peeker.my_id):
			return {buttons = InputCmd.FIRE, aim = (c.remote_positions[peeker.my_id] - c.state.pos).angle()}
		return {buttons = 0, aim = 0.0}

	var p := {phase = "hide", t = 0, episode = 0}
	peeker.input_provider = func(c, _seq: int) -> Dictionary:
		p.t += 1
		var sees: bool = c.can_see(holder.my_id)
		match p.phase:
			"hide":
				if p.t > 40 and p.episode < PEEK_EPISODES:
					p.phase = "peek"
					p.t = 0
					p.episode += 1
				return {buttons = 0, aim = 0.0}
			"peek":
				if sees:
					p.phase = "shoot"
					p.t = 0
					return {buttons = InputCmd.FIRE, aim = (c.remote_positions[holder.my_id] - c.state.pos).angle()}
				return {buttons = InputCmd.UP, aim = 0.0}
			"shoot":
				if p.t > 8:
					p.phase = "retreat"
				return {buttons = 0, aim = 0.0}
			_:  # retreat
				if c.state.pos.y >= PEEK_POS.y - 1.0:
					p.phase = "hide"
					p.t = 0
				return {buttons = InputCmd.DOWN, aim = 0.0}

	var episodes: Array = []
	var cur := {}
	var leak := 0
	var hide_ticks := 0
	var late := 0
	var vis_ticks := 0
	while p.episode < PEEK_EPISODES or p.phase != "hide" or p.t < 40:
		await get_tree().physics_frame
		var now := Time.get_ticks_msec()
		# Fughe: peeker fermo e nascosto (fase hide, già fermo da 20 tick).
		if p.phase == "hide" and p.t > 20:
			hide_ticks += 1
			if holder.remote_positions.has(peeker.my_id):
				leak += 1
		# Comparse in ritardo, per entrambi i punti di vista.
		for pair in [[holder, peeker], [peeker, holder]]:
			var v: Client = pair[0]
			var truth = server.position_at(pair[1].my_id, v.render_tick)
			if truth != null and Map.line_of_sight(v.state.pos, truth):
				vis_ticks += 1
				if not v.remote_positions.has(pair[1].my_id):
					late += 1
		if p.phase == "peek" and cur.get("n", 0) != p.episode:
			cur = {n = p.episode, start_usec = Time.get_ticks_usec()}
			episodes.append(cur)
		if cur.is_empty():
			continue
		var h_srv: Vector2 = server.clients[holder.my_id].state.pos
		var p_srv: Vector2 = server.clients[peeker.my_id].state.pos
		if not cur.has("server") and Map.line_of_sight(h_srv, p_srv):
			cur.server = now
		if not cur.has("peeker") and peeker.can_see(holder.my_id):
			cur.peeker = now
		if not cur.has("holder") and holder.can_see(peeker.my_id):
			cur.holder = now

	var advantages: Array = []
	var peeker_first := 0
	for e in episodes:
		var first := "nessuno"
		for h in server.hit_log:
			if h[0] >= e.start_usec:
				first = "PEEKER" if h[1] == peeker.my_id else "holder"
				break
		if first == "PEEKER":
			peeker_first += 1
		if e.has("server") and e.has("peeker") and e.has("holder"):
			advantages.append(float(e.holder - e.peeker))
			print("peek %d: P vede H a %+4d ms, H vede P a %+4d ms (rispetto al server) -> vantaggio %3d ms | primo colpo: %s" % [
				e.n, e.peeker - e.server, e.holder - e.server, e.holder - e.peeker, first])
		else:
			print("peek %d: incompleto %s" % [e.n, e])
	var adv := _mean(advantages)
	print("vantaggio medio del peeker: %.0f ms su %d peek | il peeker colpisce per primo in %d/%d" % [
		adv, advantages.size(), peeker_first, episodes.size()])
	print("fughe (peeker nascosto ma inviato): %d/%d tick | comparse in ritardo: %d/%d tick visibili" % [
		leak, hide_ticks, late, vis_ticks])
	for c in [holder, peeker]:
		c.stop()
		c.queue_free()
	server.stop()
	server.queue_free()
	for i in 10:
		await get_tree().physics_frame
	var result := {ok = true, adv = adv, leak = leak, hide_ticks = hide_ticks, late = late, vis_ticks = vis_ticks}
	if advantages.size() < PEEK_EPISODES - 1:
		print("  FAIL: troppi peek non misurati")
		result.ok = false
	if cull and leak > 0:
		print("  FAIL: con il culling il client ha ricevuto un giocatore nascosto")
		result.ok = false
	if cull and late > vis_ticks * MAX_LATE_REVEAL:
		print("  FAIL: troppe comparse in ritardo (%d > %.0f%% di %d)" % [late, MAX_LATE_REVEAL * 100, vis_ticks])
		result.ok = false
	print("Scenario: %s" % ("OK" if result.ok else "FAIL"))
	return result


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()
