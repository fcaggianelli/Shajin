extends CanvasLayer
## Overlay di debug del client. F3 mostra/nasconde, F4 prediction,
## F5 reconciliation, F6 ridondanza degli input.

var client  # scripts/net/client.gd
var _label := Label.new()


func _ready() -> void:
	_label.position = Vector2(836, 20)
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F3: visible = not visible
		KEY_F4: client.prediction_enabled = not client.prediction_enabled
		KEY_F5: client.reconciliation_enabled = not client.reconciliation_enabled
		KEY_F6: client.redundancy_enabled = not client.redundancy_enabled


func _process(_delta: float) -> void:
	if not visible or client == null:
		return
	var c = client
	var on := func(b: bool) -> String: return "ON" if b else "OFF"
	var avg: float = c.err_sum / c.err_count if c.err_count > 0 else 0.0
	var lines := [c.info_text] if c.info_text != "" else []
	_label.text = "\n".join(lines + [
		"id %d   ping %d ms" % [c.my_id, c.ping_ms],
		"input in buffer: %d   (seq %d, ack %d)" % [c.pending.size(), c.seq, c.last_ack],
		"errore predetto/server: %.2f px" % c.err_last,
		"  medio %.2f   max %.2f   (%d misure)" % [avg, c.err_max, c.err_count],
		"correzione visiva max: %.2f px" % c.correction_max,
		"render tick %.1f   (ritardo %d ms)" % [c.render_tick, c.INTERP_DELAY_TICKS * 1000 / 60],
		"rete sim: lag %d ms  jitter %d ms  loss %d%%" % [c.sim.lag_ms, c.sim.jitter_ms, c.sim.loss * 100],
		"persi: out %d  in %d" % [c.sim.dropped_out, c.sim.dropped_in],
		"colpi messi a segno %d   subiti %d" % [c.my_hits, c.my_deaths],
		"",
		"[F4] prediction:      %s" % on.call(c.prediction_enabled),
		"[F5] reconciliation:  %s" % on.call(c.reconciliation_enabled),
		"[F6] ridondanza input: %s" % on.call(c.redundancy_enabled),
		"[F3] nascondi overlay",
	])
