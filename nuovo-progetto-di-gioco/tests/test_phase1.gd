extends "res://tests/net_test_base.gd"
## Fase 1: movimento condiviso, prediction e reconciliation.
##   godot --headless --path . res://tests/test_phase1.tscn
## 1 server + 2 client con input scriptati (corsa, strafe, rotazione, salti,
## urti contro muri e coperture), 100 ms/direzione + 10 ms jitter + 5% perdita.
## Misura l'errore tra la posizione predetta dopo il comando `ack` e quella del
## server per lo stesso comando, a ogni snapshot che conferma nuovi input.

const INPUT_TICKS := 900        # 15 s di input
const SETTLE_TICKS := 120       # 2 s fermi per far convergere tutto
## Soglia: 1 cm di errore medio. Con simulazione deterministica e stato in float32
## l'atteso è 0; 1 cm lascia margine a eventuali divergenze rare (perdita oltre la
## ridondanza) senza nascondere un errore sistematico (un tick di movimento a
## 8 m/s vale 13 cm).
const MAX_MEAN_ERROR := 0.01
const MAX_FINAL_ERROR := 0.001


func _script(index: int) -> Callable:
	return func(_c, seq: int) -> Dictionary:
		if seq > INPUT_TICKS:
			return {buttons = 0, yaw = 0.0, pitch = 0.0}
		var t := float(seq)
		if index == 0:
			# corre in avanti girando lentamente, strafe alternato, salto ogni 1.5 s
			var b := InputCmd.FORWARD
			b |= InputCmd.LEFT if (seq / 120) % 2 == 0 else InputCmd.RIGHT
			if seq % 90 == 0: b |= InputCmd.JUMP
			return {buttons = b, yaw = t * 0.012, pitch = sin(t * 0.02) * 0.5}
		# direzioni pseudo-casuali ogni 20 tick, yaw a scatti, salti
		var h := hash(seq / 20 * 7919)
		return {buttons = h & 31, yaw = (h % 628) / 100.0, pitch = 0.0}


func run() -> void:
	print("\n=== Fase 1: prediction + reconciliation | lag %d ms/direzione, jitter %d ms, loss %d%%/direzione ===" % [
		LAG_MS, JITTER_MS, LOSS * 100])
	if not await start_match(2, [Level.SPAWNS[0], Level.SPAWNS[5]]):
		return
	for i in clients.size():
		clients[i].input_provider = _script(i)
	var start := {}
	var stats := {disp = 0.0, height = 0.0}  # dizionario: le lambda catturano le variabili per valore
	for c in clients:
		start[c.my_id] = c.state.pos
	await wait_until(func():
		for c in clients:
			stats.disp = maxf(stats.disp, c.state.pos.distance_to(start[c.my_id]))
			stats.height = maxf(stats.height, c.state.pos.y)
		return clients.all(func(c): return c.seq >= INPUT_TICKS + SETTLE_TICKS), 3000)

	var all_errors: Array = []
	for c in clients:
		all_errors.append_array(c.errors)
		var final_err: float = c.state.pos.distance_to(server.clients[c.my_id].state.pos)
		print("client %d: ping %3d ms | conferme %d | errore medio %.6f m, max %.6f m | correzione visiva max %.6f m | errore finale %.6f m | persi out %d in %d" % [
			c.my_id, c.ping_ms, c.err_count, c.err_sum / maxf(c.err_count, 1), c.err_max, c.correction_max,
			final_err, c.sim.dropped_out, c.sim.dropped_in])
		check(final_err <= MAX_FINAL_ERROR, "client %d non converge col server (%.6f m)" % [c.my_id, final_err])
	var m := mean(all_errors)
	print("TOTALE errore predetto vs server: medio %.6f m, max %.6f m su %d misure (soglia media %.3f m)" % [
		m, amax(all_errors), all_errors.size(), MAX_MEAN_ERROR])
	print("spostamento massimo %.1f m, altezza massima %.2f m" % [stats.disp, stats.height])
	check(m <= MAX_MEAN_ERROR, "errore medio %.6f > %.3f m" % [m, MAX_MEAN_ERROR])
	check(all_errors.size() > 300, "troppe poche misure")
	check(stats.disp > 5.0, "i giocatori non si sono mossi")
	check(stats.height > 0.5, "nessun salto eseguito")
	await stop_match()
	await _control_unpredictable_push()


## Controprova: un evento che il client non può predire (spinta lato server) deve
## comparire come errore > 0 e la riconciliazione deve riportarlo a zero.
func _control_unpredictable_push() -> void:
	print("\n--- Controprova: spinta lato server non predicibile ---")
	if not await start_match(1, [Level.SPAWNS[6]]):
		return
	var c = clients[0]
	c.input_provider = func(_c, seq: int) -> Dictionary:
		return {buttons = InputCmd.FORWARD if seq < 240 else 0, yaw = PI / 2, pitch = 0.0}
	await ticks(60)
	server.clients[c.my_id].state.vel += Vector3(0, 0, 6)  # solo il server lo sa
	await wait_until(func(): return c.seq >= 400, 1000)
	var final_err: float = c.state.pos.distance_to(server.clients[c.my_id].state.pos)
	print("errore massimo dopo la spinta %.3f m | correzione visiva max %.3f m | errore finale %.6f m" % [
		c.err_max, c.correction_max, final_err])
	check(c.err_max > 0.05, "la misura non ha visto la divergenza")
	check(final_err <= MAX_FINAL_ERROR, "la riconciliazione non ha corretto la divergenza")
	await stop_match()
