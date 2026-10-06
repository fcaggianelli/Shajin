extends Node
## Punto d'ingresso. Stessa build per server e client:
##   godot --headless --path . -- --server [--port=27960] [--bind=0.0.0.0]
##   godot --path . -- --client --host=1.2.3.4 [--port=27960]   (connessione diretta)
##   godot --path .                                              (menu: IP e porta, oppure Ospita)
## Opzioni del simulatore di rete (per direzione): --lag=MS --jitter=MS --loss=0.05
## Server: --no-lagcomp disattiva la lag compensation dell'arma hitscan.

const Server = preload("res://scripts/net/server.gd")
const Client = preload("res://scripts/net/client.gd")
const ConnectMenu = preload("res://scripts/ui/connect_menu.gd")

var args := {}
var _menu: ConnectMenu
var _client: Client
var _server: Server


func _ready() -> void:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv: PackedStringArray = a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var port := int(args.get("port", "27960"))
	var headless := DisplayServer.get_name() == "headless" or args.has("headless")

	if args.has("server") or (headless and not args.has("client")):
		if _start_server(port) != OK:
			get_tree().quit(1)
	elif args.has("host") or headless:
		_start_client(args.get("host", "127.0.0.1"), port)
	else:
		_show_menu("")


func _sim_params() -> Array:
	return [float(args.get("lag", "0")), float(args.get("jitter", "0")), float(args.get("loss", "0"))]


func _start_server(port: int) -> Error:
	_server = Server.new()
	_server.bind_ip = args.get("bind", "0.0.0.0")
	_server.lag_comp_enabled = not args.has("no-lagcomp")
	add_child(_server)
	var p := _sim_params()
	var err := _server.start(port, p[0], p[1], p[2])
	if err != OK:
		push_error("impossibile avviare il server sulla porta %d (porta già in uso?)" % port)
		_server.queue_free()
		_server = null
	return err


func _start_client(host: String, port: int) -> void:
	_client = Client.new()
	add_child(_client)
	_client.disconnected.connect(_on_client_disconnected.bind(host, port))
	var p := _sim_params()
	if _client.start(host, port, p[0], p[1], p[2]) != OK:
		_on_client_disconnected(false, host, port)


func _on_client_disconnected(was_connected: bool, host: String, port: int) -> void:
	if _client:
		_client.queue_free()
		_client = null
	var msg := "Connessione con %s:%d persa." if was_connected else "Impossibile connettersi a %s:%d."
	push_warning(msg % [host, port])
	if DisplayServer.get_name() == "headless":
		get_tree().quit(1)
	else:
		_show_menu(msg % [host, port])


func _show_menu(status: String) -> void:
	if _server:  # tornando al menu chiudiamo anche un eventuale server ospitato
		_server.stop()
		_server.queue_free()
		_server = null
	var layer := CanvasLayer.new()
	add_child(layer)
	_menu = ConnectMenu.new()
	layer.add_child(_menu)
	_menu.set_status(status)
	_menu.join_requested.connect(func(host: String, port: int):
		layer.queue_free()
		_start_client(host, port))
	_menu.host_requested.connect(_on_host_requested.bind(layer))


## "Ospita partita": server su 0.0.0.0 e client locale nello stesso processo.
func _on_host_requested(port: int, layer: CanvasLayer) -> void:
	if _start_server(port) != OK:
		_menu.set_status("Impossibile aprire la porta %d (già in uso?)." % port)
		return
	layer.queue_free()
	_start_client("127.0.0.1", port)
	_client.info_text = "Ospiti sulla porta UDP %d\nIP LAN da dare all'amico: %s\nVia Internet: IP pubblico + port\nforwarding UDP %d sul router\n" % [
		port, ", ".join(Server.local_ipv4()), port]
