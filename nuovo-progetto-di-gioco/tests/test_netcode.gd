extends Node
## Test headless del netcode:
##   godot --headless --path . res://tests/test_netcode.tscn
## 1 server + 2 client nello stesso processo (veri socket ENet su localhost),
## input scriptati, 100 ms di latenza per direzione (+jitter) e 5% di perdita
## per direzione sui client. Exit code 0 = PASS, 1 = FAIL.

const Server = preload("res://scripts/net/server.gd")
const Client = preload("res://scripts/net/client.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")

const LAG_MS := 100.0
const JITTER_MS := 10.0
const LOSS := 0.05
const INPUT_TICKS := 600     # 10 s di input scriptati
const SETTLE_TICKS := 120    # 2 s fermi per far convergere tutto
const MAX_MEAN_ERROR := 0.5  # px: soglia sull'errore medio di predizione
const MAX_FINAL_ERROR := 0.01  # px: client e server devono coincidere alla fine
const MAX_INTERP_MEAN_ERROR := 5.0  # px: remoti interpolati vs verità del server

const PATTERN := [  # client 0: [buttons, durata in tick]
	[InputCmd.RIGHT, 50], [InputCmd.DOWN, 40], [InputCmd.LEFT | InputCmd.UP, 60],
	[0, 20], [InputCmd.UP, 30], [InputCmd.RIGHT | InputCmd.DOWN, 70], [InputCmd.LEFT, 80],
]


func _ready() -> void:
	var ok := true
	var scenarios := [
		{name = "A  prediction+reconciliation, ridondanza ON", assert_error = true},
		{name = "B  ridondanza OFF (il server perde input)", redundancy = false},
		{name = "C  ridondanza OFF + reconciliation OFF", redundancy = false, reconciliation = false, expect_drift = true},
	]
	print("\n=== Netcode test: lag %d ms/direzione, jitter %d ms, loss %d%%/direzione ===" % [LAG_MS, JITTER_MS, LOSS * 100])
	for sc in scenarios:
		ok = (await _run_movement(sc)) and ok
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


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()
