extends Node
## Punto d'ingresso. Stessa build per server e client, scelta da riga di comando:
##   godot --headless --path . -- --server [--port=27960]
##   godot --path . -- --client [--host=127.0.0.1] [--port=27960]
## Opzioni del simulatore di rete (per direzione): --lag=MS --jitter=MS --loss=0.05
## Server: --no-lagcomp disattiva la lag compensation dell'arma hitscan.

const Server = preload("res://scripts/net/server.gd")
const Client = preload("res://scripts/net/client.gd")


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv: PackedStringArray = a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var port := int(args.get("port", "27960"))
	var lag := float(args.get("lag", "0"))
	var jitter := float(args.get("jitter", "0"))
	var loss := float(args.get("loss", "0"))
	var headless := DisplayServer.get_name() == "headless" or args.has("headless")

	if args.has("server") or (headless and not args.has("client")):
		var server := Server.new()
		server.lag_comp_enabled = not args.has("no-lagcomp")
		add_child(server)
		if server.start(port, lag, jitter, loss) != OK:
			push_error("impossibile avviare il server sulla porta %d" % port)
			get_tree().quit(1)
	else:
		var client := Client.new()
		add_child(client)
		if client.start(args.get("host", "127.0.0.1"), port, lag, jitter, loss) != OK:
			push_error("impossibile connettersi")
			get_tree().quit(1)
