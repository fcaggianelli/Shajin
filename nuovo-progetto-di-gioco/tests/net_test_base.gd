extends Node
## Base comune dei test headless: livello, 1 server e N client nello stesso
## processo (veri socket ENet su localhost) con simulatore di rete sui client.

const Server = preload("res://scripts/net/server.gd")
const Client = preload("res://scripts/net/client.gd")
const Level = preload("res://scripts/game/level.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")
const Movement = preload("res://scripts/game/movement.gd")
const NetConfig = preload("res://scripts/net/net_config.gd")

## "100 ms di latenza" = 100 ms PER DIREZIONE sui client (RTT ~200 ms), più jitter
## e 5% di perdita in entrata e in uscita. È più severo di 100 ms di ping.
const LAG_MS := 100.0
const JITTER_MS := 10.0
const LOSS := 0.05

var server: Server
var clients: Array = []
var ok := true


func _ready() -> void:
	add_child(Level.new())
	await get_tree().physics_frame
	await get_tree().physics_frame  # la geometria statica entra nello spazio fisico
	await run()
	print("\nRISULTATO: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func run() -> void:
	pass


func check(cond: bool, msg: String) -> void:
	if not cond:
		ok = false
		print("  FAIL: " + msg)


## Avvia server e client (in ordine di connessione, per spawn prevedibili).
func start_match(n_clients: int, spawns: Array = [], lag := LAG_MS, jitter := JITTER_MS, loss := LOSS) -> bool:
	var port := 30000 + randi() % 20000
	server = Server.new()
	if not spawns.is_empty():
		server.spawns = spawns
	add_child(server)
	if server.start(port) != OK:
		check(false, "server non avviato")
		return false
	clients = []
	for i in n_clients:
		if not await add_client(port, lag, jitter, loss, 100 + i):
			return false
	return true


func add_client(port: int, lag := LAG_MS, jitter := JITTER_MS, loss := LOSS, seed_value := 0) -> Variant:
	var c := Client.new()
	c.local_view = false
	c.input_provider = func(_c, _s): return {buttons = 0, yaw = 0.0, pitch = 0.0}
	add_child(c)
	c.start("127.0.0.1", port, lag, jitter, loss, seed_value)
	clients.append(c)
	if not await wait_until(func(): return c.is_ready(), 600):
		check(false, "client non connesso")
		return null
	return c


func wait_until(cond: Callable, max_ticks: int) -> bool:
	for i in max_ticks:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()


func ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func stop_match() -> void:
	for c in clients:
		c.stop()
		c.queue_free()
	clients = []
	server.stop()
	server.queue_free()
	await ticks(10)


static func mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()


static func amax(a: Array) -> float:
	return a.max() if not a.is_empty() else 0.0
