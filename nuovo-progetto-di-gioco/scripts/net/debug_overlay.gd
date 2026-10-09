extends CanvasLayer
## Overlay di debug del client. F3 mostra/nasconde, F4 prediction, F5 reconciliation.

const NetConfig = preload("res://scripts/net/net_config.gd")

var client  # scripts/net/client.gd
var _label := Label.new()


func _ready() -> void:
	layer = 10
	_label.position = Vector2(12, 12)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F3: visible = not visible
		KEY_F4: client.prediction_enabled = not client.prediction_enabled
		KEY_F5: client.reconciliation_enabled = not client.reconciliation_enabled


func _process(_delta: float) -> void:
	if not visible or client == null:
		return
	var c = client
	var on := func(b: bool) -> String: return "ON" if b else "OFF"
	var avg: float = c.err_sum / c.err_count if c.err_count > 0 else 0.0
	_label.text = "\n".join([
		"ping rete %d ms   latenza di gioco %d ms   fps %d" % [c.net_rtt_ms(), c.ping_ms, Engine.get_frames_per_second()],
		"input in buffer: %d   (seq %d, ack %d)" % [c.pending.size(), c.seq, c.last_ack],
		"errore predetto/server: %.3f m" % c.err_last,
		"  medio %.4f   max %.4f m   (%d misure)" % [avg, c.err_max, c.err_count],
		"correzione visiva max: %.3f m" % c.correction_max,
		"tick %d Hz  snapshot %d Hz  interp %d ms" % [NetConfig.TICK_RATE, NetConfig.TICK_RATE / NetConfig.SNAPSHOT_EVERY, NetConfig.INTERP_MS],
		"rete sim: lag %d ms  jitter %d ms  loss %d%%   persi out %d in %d" % [
			c.sim.lag_ms, c.sim.jitter_ms, c.sim.loss * 100, c.sim.dropped_out, c.sim.dropped_in],
		"[F4] prediction: %s   [F5] reconciliation: %s   [F3] nascondi" % [
			on.call(c.prediction_enabled), on.call(c.reconciliation_enabled)],
	])
