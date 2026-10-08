extends CanvasLayer
## HUD minimale: mirino, punteggi, ultime uccisioni, stato (morto/protetto).

const Player = preload("res://scripts/game/player.gd")
const NetConfig = preload("res://scripts/net/net_config.gd")

var client  # scripts/net/client.gd
var _crosshair := Label.new()
var _scores := Label.new()
var _feed := Label.new()
var _status := Label.new()


func _ready() -> void:
	for l in [_crosshair, _scores, _feed, _status]:
		l.add_theme_color_override("font_shadow_color", Color.BLACK)
		l.add_theme_constant_override("shadow_offset_x", 1)
		l.add_theme_constant_override("shadow_offset_y", 1)
		add_child(l)
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 22)
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scores.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_scores.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_scores.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_scores.position += Vector2(-12, 12)
	_feed.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_feed.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_feed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed.position += Vector2(-12, -12)
	_status.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_status.position += Vector2(0, 60)
	_status.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 24)


static func player_name(id: int) -> String:
	return "P%03d" % (id % 1000)


func _process(_delta: float) -> void:
	if client == null or client.state == null:
		return
	var c = client
	var rows := []
	var ids: Array = c.players_info.keys()
	ids.sort_custom(func(a, b): return c.players_info[a].score > c.players_info[b].score)
	for id in ids:
		var p: Dictionary = c.players_info[id]
		rows.append("%s%s   %d uccisioni  %d morti" % ["> " if id == c.my_id else "", player_name(id), p.score, p.deaths])
	_scores.text = "\n".join(rows)
	_feed.text = "\n".join(c.kill_feed.map(func(k): return "%s ha ucciso %s" % [player_name(k[0]), player_name(k[1])]))
	var me: Dictionary = c.players_info.get(c.my_id, {})
	_crosshair.visible = c.state.alive
	if not c.state.alive:
		_status.text = "Sei morto - respawn tra %.1f s" % (me.get("respawn_ticks", 0) / float(NetConfig.TICK_RATE))
	elif me.get("protected", false):
		_status.text = "Protetto"
	else:
		_status.text = ""
