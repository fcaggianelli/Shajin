extends "res://tests/net_test_base.gd"
## Fase 2: interpolazione delle entità remote.
##   godot --headless --path . res://tests/test_phase2.tscn
## 1 server + 3 client che si muovono (100 ms/direzione, jitter, 5% perdita).
## Ogni client mostra gli altri a render_tick; confrontiamo la posizione
## visualizzata con quella vera del server a quell'istante (cronologia del server),
## e misuriamo di quanto i remoti sono nel passato rispetto all'ultimo snapshot.
## Si ricontrolla anche l'errore di predizione della fase 1.

const RUN_TICKS := 15 * S
## Soglia: 5 cm di errore medio. Con gli snapshot tutti ricevuti l'interpolazione
## coincide con la cronologia del server; l'errore nasce solo dagli snapshot persi
## (5%): tra due snapshot a 100 ms invece di 50 ms la traiettoria è approssimata.
const MAX_INTERP_MEAN := 0.05
const MAX_PRED_MEAN := 0.01


func _script(index: int) -> Callable:
	return func(_c, seq: int) -> Dictionary:
		if seq > RUN_TICKS:
			return {buttons = 0, yaw = 0.0, pitch = 0.0}
		var h := hash((seq * 60 / S / (15 + index * 7)) * 7919 + index)
		return {buttons = (h & 15) | (InputCmd.JUMP if (seq * 60 / S) % (70 + index * 13) == 0 and (seq * 60) % S < 60 else 0),
			yaw = (h % 628) / 100.0, pitch = ((h / 7) % 100) / 100.0 - 0.5}


func run() -> void:
	print("\n=== Fase 2: interpolazione | lag %d ms/direzione, jitter %d ms, loss %d%%/direzione ===" % [
		LAG_MS, JITTER_MS, LOSS * 100])
	if not await start_match(3, [Level.SPAWNS[0], Level.SPAWNS[3], Level.SPAWNS[6]]):
		return
	for i in clients.size():
		clients[i].input_provider = _script(i)
	var interp_err: Array = []
	var yaw_err: Array = []
	var delay_ms: Array = []
	var seen_snap := {}
	await wait_until(func():
		for c in clients:
			# Appena arriva uno snapshot: quanto indietro mostriamo i remoti rispetto ai dati più freschi.
			if c.last_snap_tick > 0 and seen_snap.get(c, -1) != c.last_snap_tick:
				seen_snap[c] = c.last_snap_tick
				delay_ms.append((c.last_snap_tick - c.render_tick) * 1000.0 / NetConfig.TICK_RATE)
			for id in c.remote_states:
				var truth = server.state_at(id, c.render_tick)
				if truth != null:
					interp_err.append(c.remote_states[id].pos.distance_to(truth.pos))
					yaw_err.append(absf(angle_difference(c.remote_states[id].yaw, truth.yaw)))
		return clients.all(func(c): return c.seq >= RUN_TICKS + S), 30 * S)

	var pred: Array = []
	for c in clients:
		pred.append_array(c.errors)
	var m := mean(interp_err)
	var d := mean(delay_ms)
	print("remoti visualizzati vs server: errore medio %.4f m, max %.4f m su %d campioni | yaw medio %.4f rad" % [
		m, amax(interp_err), interp_err.size(), mean(yaw_err)])
	print("ritardo dei remoti rispetto allo snapshot appena arrivato: medio %.0f ms (min %.0f, max %.0f)" % [d, delay_ms.min(), delay_ms.max()])
	print("predizione (fase 1): errore medio %.6f m, max %.6f m su %d misure" % [mean(pred), amax(pred), pred.size()])
	check(interp_err.size() > 1000, "troppi pochi campioni")
	check(m <= MAX_INTERP_MEAN, "errore medio di interpolazione %.4f > %.2f m" % [m, MAX_INTERP_MEAN])
	# Misurato all'arrivo dello snapshot, dopo l'avanzamento di un tick: atteso ~INTERP - 1 tick.
	var tick_ms := 1000.0 / NetConfig.TICK_RATE
	check(d > NetConfig.INTERP_MS - 2.5 * tick_ms and d < NetConfig.INTERP_MS + 2.5 * tick_ms,
		"ritardo di interpolazione %.1f ms lontano da %.1f ms" % [d, NetConfig.INTERP_MS])
	check(mean(pred) <= MAX_PRED_MEAN, "errore di predizione %.6f > %.2f m" % [mean(pred), MAX_PRED_MEAN])
	await stop_match()
