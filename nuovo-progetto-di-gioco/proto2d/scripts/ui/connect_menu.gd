extends CenterContainer
## Schermata iniziale del client: IP e porta del server, oppure "Ospita"
## (server + client nello stesso processo). Ricorda l'ultimo indirizzo usato.

signal join_requested(host: String, port: int)
signal host_requested(port: int, preset: String)

const CONFIG_PATH := "user://connect.cfg"
const NetConfig = preload("res://proto2d/scripts/net/net_config.gd")

var _host := LineEdit.new()
var _port := LineEdit.new()
var _status := Label.new()
var _preset := OptionButton.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var title := Label.new()
	title.text = "Netcode Q3 Prototype"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	_host.placeholder_text = "IP del server (es. 192.168.1.10)"
	_host.text = cfg.get_value("last", "host", "127.0.0.1")
	_port.placeholder_text = "Porta"
	_port.text = str(cfg.get_value("last", "port", 27960))
	box.add_child(_labeled("IP / host", _host))
	box.add_child(_labeled("Porta", _port))
	_host.text_submitted.connect(func(_t): _on_join())
	_port.text_submitted.connect(func(_t): _on_join())

	var join := Button.new()
	join.text = "Connetti"
	join.pressed.connect(_on_join)
	box.add_child(join)

	for name in NetConfig.PRESETS:
		var p: Dictionary = NetConfig.PRESETS[name]
		_preset.add_item("%s  (tick %d, snapshot %d Hz, interp %.0f ms)" % [name, p.tick_rate, p.snapshot_rate, p.interp_ms])
		_preset.set_item_metadata(_preset.item_count - 1, name)
		if name == cfg.get_value("last", "preset", NetConfig.DEFAULT):
			_preset.select(_preset.item_count - 1)
	var preset_row := HBoxContainer.new()
	var preset_label := Label.new()
	preset_label.text = "Preset"
	preset_label.custom_minimum_size = Vector2(80, 0)
	_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(preset_label)
	preset_row.add_child(_preset)
	box.add_child(preset_row)

	var host := Button.new()
	host.text = "Ospita partita (server su 0.0.0.0 + gioca)"
	host.pressed.connect(_on_host)
	box.add_child(host)

	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_host.grab_focus()


func set_status(text: String) -> void:
	_status.text = text


func _labeled(text: String, field: LineEdit) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(80, 0)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	row.add_child(field)
	return row


func _read_port() -> int:
	var p := int(_port.text.strip_edges())
	if p < 1 or p > 65535:
		set_status("Porta non valida (1-65535).")
		return 0
	return p


func _save(host: String, port: int) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("last", "host", host)
	cfg.set_value("last", "port", port)
	cfg.set_value("last", "preset", _preset.get_selected_metadata())
	cfg.save(CONFIG_PATH)


func _on_join() -> void:
	var host := _host.text.strip_edges()
	var port := _read_port()
	if port == 0:
		return
	if host.is_empty():
		set_status("Inserisci l'IP del server.")
		return
	_save(host, port)
	join_requested.emit(host, port)


func _on_host() -> void:
	var port := _read_port()
	if port == 0:
		return
	_save(_host.text.strip_edges(), port)
	host_requested.emit(port, _preset.get_selected_metadata())
