extends RefCounted
## Pacchetti impacchettati a mano (niente MultiplayerSynchronizer). Float a 32
## bit: gli stessi dei Vector3, quindi lo stato ricevuto è bit-identico.
##
## INPUT (client -> server, ogni tick, inaffidabile)
##   u8 type=1, u8 count, count x cmd
##   cmd: u32 seq, u8 buttons, f32 yaw, f32 pitch
##        se FIRE: f32 shot_time, 3 x f32 shot_origin, 3 x f32 shot_dir
##   Ogni pacchetto contiene tutti gli input non confermati (ridondanza alla Q3).
## SNAPSHOT (server -> client, a ogni tick, inaffidabile)
##   u8 type=2, u32 tick, u32 ack_seq, u16 hold_ms, u8 count, count x player
##   player: u32 id, 3 x f32 pos, 3 x f32 vel, f32 yaw, f32 pitch,
##           u8 flags (1 vivo, 2 a terra, 4 protetto), u8 cooldown,
##           u16 score, u16 deaths, u16 respawn_ticks
##   ack_seq = ultimo input di QUESTO client applicato dal server.
## SHOT (server -> altri client, inaffidabile): u8 type=3, u32 shooter, 3 x f32 da, 3 x f32 a
##   per disegnare il colpo degli avversari.
## EVENT (server -> client, AFFIDABILE e ordinato):
##   u8 type=4, u8 kind, poi: KILL u16 kill_id, u32 killer, u32 victim
##                            JOIN/LEAVE u32 id

const InputCmd = preload("res://scripts/game/input_cmd.gd")
const PlayerState = preload("res://scripts/game/player_state.gd")

const TYPE_INPUT := 1
const TYPE_SNAPSHOT := 2
const TYPE_SHOT := 3
const TYPE_EVENT := 4
const EVENT_KILL := 1
const EVENT_JOIN := 2
const EVENT_LEAVE := 3
const MAX_INPUTS_PER_PACKET := 32
const FLAG_ALIVE := 1
const FLAG_GROUND := 2
const FLAG_PROTECTED := 4


## Arrotonda a float32 come farà il pacchetto: il client deve simulare con gli
## STESSI valori che riceverà il server, altrimenti la predizione diverge di µm.
static func f32(x: float) -> float:
	return PackedFloat32Array([x])[0]


static func _put_v3(b: StreamPeerBuffer, v: Vector3) -> void:
	b.put_float(v.x)
	b.put_float(v.y)
	b.put_float(v.z)


static func _get_v3(b: StreamPeerBuffer) -> Vector3:
	return Vector3(b.get_float(), b.get_float(), b.get_float())


static func encode_input(cmds: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	var first := maxi(cmds.size() - MAX_INPUTS_PER_PACKET, 0)
	b.put_u8(TYPE_INPUT)
	b.put_u8(cmds.size() - first)
	for i in range(first, cmds.size()):
		var c: InputCmd = cmds[i]
		b.put_u32(c.seq)
		b.put_u8(c.buttons)
		b.put_float(c.yaw)
		b.put_float(c.pitch)
		if c.buttons & InputCmd.FIRE:
			b.put_float(c.shot_time)
			_put_v3(b, c.shot_origin)
			_put_v3(b, c.shot_dir)
	return b.data_array


static func decode_input(b: StreamPeerBuffer) -> Array:
	var cmds := []
	var n := b.get_u8()
	for i in n:
		var c := InputCmd.new()
		c.seq = b.get_u32()
		c.buttons = b.get_u8()
		c.yaw = b.get_float()
		c.pitch = b.get_float()
		if c.buttons & InputCmd.FIRE:
			c.shot_time = b.get_float()
			c.shot_origin = _get_v3(b)
			c.shot_dir = _get_v3(b)
		cmds.append(c)
	return cmds


## players: Array di Dictionary {id, state, score, deaths, protected, respawn_ticks}
static func encode_snapshot(tick: int, ack_seq: int, hold_ms: int, players: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(TYPE_SNAPSHOT)
	b.put_u32(tick)
	b.put_u32(ack_seq)
	b.put_u16(clampi(hold_ms, 0, 65535))
	b.put_u8(players.size())
	for p in players:
		var s: PlayerState = p.state
		b.put_u32(p.id)
		_put_v3(b, s.pos)
		_put_v3(b, s.vel)
		b.put_float(s.yaw)
		b.put_float(s.pitch)
		var flags := (FLAG_ALIVE if s.alive else 0) | (FLAG_GROUND if s.on_ground else 0) | (FLAG_PROTECTED if p.protected else 0)
		b.put_u8(flags)
		b.put_u8(s.cooldown)
		b.put_u16(p.score)
		b.put_u16(p.deaths)
		b.put_u16(p.respawn_ticks)
	return b.data_array


static func decode_snapshot(b: StreamPeerBuffer) -> Dictionary:
	var snap := {tick = b.get_u32(), ack = b.get_u32(), hold_ms = b.get_u16(), players = {}}
	var n := b.get_u8()
	for i in n:
		var id := b.get_u32()
		var s := PlayerState.new()
		s.pos = _get_v3(b)
		s.vel = _get_v3(b)
		s.yaw = b.get_float()
		s.pitch = b.get_float()
		var flags := b.get_u8()
		s.alive = flags & FLAG_ALIVE != 0
		s.on_ground = flags & FLAG_GROUND != 0
		s.cooldown = b.get_u8()
		snap.players[id] = {state = s, protected = flags & FLAG_PROTECTED != 0,
			score = b.get_u16(), deaths = b.get_u16(), respawn_ticks = b.get_u16()}
	return snap


static func encode_shot(shooter: int, from: Vector3, to: Vector3) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(TYPE_SHOT)
	b.put_u32(shooter)
	_put_v3(b, from)
	_put_v3(b, to)
	return b.data_array


static func decode_shot(b: StreamPeerBuffer) -> Dictionary:
	return {shooter = b.get_u32(), from = _get_v3(b), to = _get_v3(b)}


static func encode_kill(kill_id: int, killer: int, victim: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(TYPE_EVENT)
	b.put_u8(EVENT_KILL)
	b.put_u16(kill_id)
	b.put_u32(killer)
	b.put_u32(victim)
	return b.data_array


static func encode_presence(kind: int, id: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(TYPE_EVENT)
	b.put_u8(kind)
	b.put_u32(id)
	return b.data_array


static func decode_event(b: StreamPeerBuffer) -> Dictionary:
	var kind := b.get_u8()
	if kind == EVENT_KILL:
		return {kind = kind, kill_id = b.get_u16(), killer = b.get_u32(), victim = b.get_u32()}
	return {kind = kind, id = b.get_u32()}


## [tipo, StreamPeerBuffer posizionato dopo il byte di tipo]
static func open(data: PackedByteArray) -> Array:
	var b := StreamPeerBuffer.new()
	b.data_array = data
	if data.is_empty():
		return [0, b]
	return [b.get_u8(), b]
