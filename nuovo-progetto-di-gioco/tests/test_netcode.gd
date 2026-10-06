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


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()
