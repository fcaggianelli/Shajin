extends CenterContainer
## Schermata iniziale del client: IP e porta del server, oppure "Ospita"
## (server + client nello stesso processo). Ricorda l'ultimo indirizzo usato.

signal join_requested(host: String, port: int)
signal host_requested(port: int)

const CONFIG_PATH := "user://connect.cfg"

var _host := LineEdit.new()
var _port := LineEdit.new()
var _status := Label.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var title := Label.new()
	title.text = "Deathmatch Q3 Prototype"
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
	host_requested.emit(port)
