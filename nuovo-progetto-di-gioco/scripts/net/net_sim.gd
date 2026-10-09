extends RefCounted
## Simulatore di rete: si mette tra il codice di gioco e l'ENetMultiplayerPeer.
## Ogni pacchetto, in uscita e in entrata, può essere scartato (loss) oppure
## trattenuto per lag_ms + [0, jitter_ms] prima di essere davvero
## inviato/consegnato. Il jitter può riordinare i pacchetti, come su Internet.
## I valori valgono PER DIREZIONE: con lag_ms=50 su un solo nodo il ping sale di ~100 ms.

var lag_ms := 0.0
var jitter_ms := 0.0
var loss := 0.0  # 0..1, applicata separatamente a entrata e uscita

var peer: ENetMultiplayerPeer
var rng := RandomNumberGenerator.new()

var dropped_out := 0
var dropped_in := 0

var _out: Array = []  # [deliver_usec, target_peer, bytes]
var _in: Array = []   # [deliver_usec, from_peer, bytes]


func _init(p: ENetMultiplayerPeer, seed_value: int = 0) -> void:
	peer = p
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()


func configure(lag: float, jitter: float, loss_ratio: float) -> void:
	lag_ms = lag
	jitter_ms = jitter
	loss = loss_ratio


func _deliver_time() -> int:
	return Time.get_ticks_usec() + int((lag_ms + rng.randf() * jitter_ms) * 1000.0)


func send(target: int, data: PackedByteArray) -> void:
	if rng.randf() < loss:
		dropped_out += 1
		return
	_out.append([_deliver_time(), target, data])


## Scarta i pacchetti ancora in coda verso un peer che si è disconnesso.
func forget_peer(id: int) -> void:
	_out = _out.filter(func(item): return item[1] != id)


## Fa il poll di ENet, invia ciò che è "partito" e ritorna i pacchetti in
## entrata che sono "arrivati": Array di [from_peer, bytes] in ordine di arrivo.
func poll() -> Array:
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var data := peer.get_packet()
		if rng.randf() < loss:
			dropped_in += 1
			continue
		_in.append([_deliver_time(), from, data])

	_send_due()
	var now := Time.get_ticks_usec()
	var result := []
	for item in _take_due(_in, now):
		result.append([item[1], item[2]])
	return result


## Da chiamare a fine tick, dopo aver accodato i pacchetti del tick: consegna a
## ENet quelli già "partiti" e li spedisce subito. Senza, un pacchetto aspettava
## il poll del tick successivo per entrare in ENet e un altro poll per uscire
## (~2 tick = 33 ms in più per direzione anche senza latenza simulata).
func flush() -> void:
	_send_due()
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED and peer.host != null:
		peer.host.flush()


func _send_due() -> void:
	for item in _take_due(_out, Time.get_ticks_usec()):
		if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			continue
		peer.set_target_peer(item[1])
		peer.put_packet(item[2])


static func _take_due(queue: Array, now: int) -> Array:
	var due := []
	var i := 0
	while i < queue.size():
		if queue[i][0] <= now:
			due.append(queue[i])
			queue.remove_at(i)
		else:
			i += 1
	due.sort_custom(func(a, b): return a[0] < b[0])
	return due
