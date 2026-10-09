extends RefCounted
## Strato di trasporto sopra ENetMultiplayerPeer, con simulatore di rete.
##
## Due canali:
##  - inaffidabile (posizioni, input, snapshot, traccianti): può perdersi, il
##    simulatore applica latenza, jitter e perdita;
##  - affidabile e ordinato (eventi: uccisioni, ingressi, uscite): ENet lo
##    ritrasmette finché arriva; il simulatore applica solo la latenza.
##
## Modalità thread (client): un thread dedicato fa girare ENet ogni ~0.5 ms,
## indipendentemente dagli fps e dal tick del gioco: i pacchetti partono appena
## accodati e quelli in arrivo vengono letti e marcati col loro istante reale di
## arrivo. Senza, ENet veniva servito solo una volta per frame/tick e ogni
## pacchetto aspettava fino a 16 ms (era il "ping" alto anche in locale).
## Tutti gli accessi a ENet passano dal mutex.
##
## I valori del simulatore valgono PER DIREZIONE.

var lag_ms := 0.0
var jitter_ms := 0.0
var loss := 0.0  # 0..1, applicata separatamente a entrata e uscita (solo inaffidabili)

var peer: ENetMultiplayerPeer
var rng := RandomNumberGenerator.new()

var dropped_out := 0
var dropped_in := 0

var _out: Array = []  # [deliver_usec, target_peer, bytes, reliable]
var _in: Array = []   # [deliver_usec, from_peer, bytes]
var _last_reliable_out := 0
var _last_reliable_in := 0
var _mutex := Mutex.new()
var _thread: Thread
var _running := false


func _init(p: ENetMultiplayerPeer, seed_value: int = 0) -> void:
	peer = p
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()


func configure(lag: float, jitter: float, loss_ratio: float) -> void:
	lag_ms = lag
	jitter_ms = jitter
	loss = loss_ratio


func start_thread() -> void:
	_running = true
	_thread = Thread.new()
	_thread.start(_thread_loop)


func close() -> void:
	if _running:
		_running = false
		_thread.wait_to_finish()
	_mutex.lock()
	peer.close()
	_mutex.unlock()


func _thread_loop() -> void:
	while _running:
		_mutex.lock()
		_service()
		_mutex.unlock()
		OS.delay_usec(500)


func _delay_usec() -> int:
	return int((lag_ms + rng.randf() * jitter_ms) * 1000.0)


## Accoda un pacchetto. reliable = canale affidabile e ordinato (mai perso).
func send(target: int, data: PackedByteArray, reliable := false) -> void:
	_mutex.lock()
	var t := Time.get_ticks_usec() + _delay_usec()
	if reliable:
		t = maxi(t, _last_reliable_out)  # il jitter non deve riordinare il canale affidabile
		_last_reliable_out = t
		_out.append([t, target, data, true])
	elif rng.randf() < loss:
		dropped_out += 1
	else:
		_out.append([t, target, data, false])
	_mutex.unlock()


## Scarta i pacchetti ancora in coda verso un peer che si è disconnesso.
func forget_peer(id: int) -> void:
	_mutex.lock()
	_out = _out.filter(func(item): return item[1] != id)
	_mutex.unlock()


## Pacchetti arrivati: Array di [from_peer, bytes, arrivo_usec] in ordine di arrivo.
## Senza thread fa anche girare ENet.
func poll() -> Array:
	_mutex.lock()
	if not _running:
		_service()
	var result := []
	for item in _take_due(_in, Time.get_ticks_usec()):
		result.append([item[1], item[2], item[0]])
	_mutex.unlock()
	return result


## Senza thread: da chiamare dopo aver accodato i pacchetti, li spedisce subito.
func flush() -> void:
	if _running:
		return
	_mutex.lock()
	_service()
	_mutex.unlock()


func connection_status() -> int:
	_mutex.lock()
	var s := peer.get_connection_status()
	_mutex.unlock()
	return s


func unique_id() -> int:
	_mutex.lock()
	var id := peer.get_unique_id() if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED else 0
	_mutex.unlock()
	return id


## Round-trip misurato da ENet verso `target` (ms).
func enet_rtt_ms(target: int) -> int:
	_mutex.lock()
	var ms := 0
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		var p := peer.get_peer(target)
		if p:
			ms = int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
	_mutex.unlock()
	return ms


## Chiamare col mutex preso.
func _service() -> void:
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	var now := Time.get_ticks_usec()
	# Uscita: consegna a ENet ciò che è "partito" e spedisci subito.
	for item in _take_due(_out, now):
		if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			continue
		peer.set_target_peer(item[1])
		peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE if item[3] else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		peer.put_packet(item[2])
	peer.poll()  # invia, riceve, ack (ENet)
	# Entrata
	while peer.get_available_packet_count() > 0:
		var reliable := peer.get_packet_mode() == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		var from := peer.get_packet_peer()
		var data := peer.get_packet()
		var t := Time.get_ticks_usec() + _delay_usec()
		if reliable:
			t = maxi(t, _last_reliable_in)
			_last_reliable_in = t
		elif rng.randf() < loss:
			dropped_in += 1
			continue
		_in.append([t, from, data])


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
