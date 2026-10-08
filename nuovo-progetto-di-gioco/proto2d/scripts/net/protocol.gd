extends RefCounted
## Formato dei pacchetti, impacchettati a mano in byte (niente RPC, niente
## MultiplayerSynchronizer). Float a 32 bit: sono gli stessi float32 dei
## Vector2, quindi client e server vedono valori bit-identici.
##
## INPUT    (client -> server, ogni tick, inaffidabile)
##   u8 type=1, u8 count, count x [u32 seq, u8 buttons, f32 aim, f32 view_tick]
##   Contiene tutti gli input non ancora confermati (ridondanza alla Quake III:
##   se un pacchetto si perde, i comandi arrivano col successivo).
## SNAPSHOT (server -> client, 20 Hz, inaffidabile)
##   u8 type=2, u8 tick_rate, u8 snapshot_every, u16 interp_ms*100,
##   u32 server_tick, u32 ack_seq, u16 hold_ms, u8 count,
##   count x [u32 id, f32 px, f32 py, f32 vx, f32 vy, u8 cooldown, u16 hits, u16 deaths]
##   ack_seq = ultimo input di QUESTO client già applicato dal server;
##   hold_ms = da quanto il server ha applicato ack_seq (per un ping corretto).
##   tick_rate/snapshot_every/interp_ms: il preset del server (vedi NetConfig).

const InputCmd = preload("res://proto2d/scripts/game/input_cmd.gd")
const PlayerState = preload("res://proto2d/scripts/game/player_state.gd")

const TYPE_INPUT := 1
const TYPE_SNAPSHOT := 2
const MAX_INPUTS_PER_PACKET := 32


static func encode_input(cmds: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	var first := maxi(cmds.size() - MAX_INPUTS_PER_PACKET, 0)
	b.put_u8(TYPE_INPUT)
	b.put_u8(cmds.size() - first)
	for i in range(first, cmds.size()):
		var c: InputCmd = cmds[i]
		b.put_u32(c.seq)
		b.put_u8(c.buttons)
		b.put_float(c.aim)
		b.put_float(c.view_tick)
	return b.data_array


static func decode_input(b: StreamPeerBuffer) -> Array:
	var cmds := []
	var n := b.get_u8()
	for i in n:
		var c := InputCmd.new()
		c.seq = b.get_u32()
		c.buttons = b.get_u8()
		c.aim = b.get_float()
		c.view_tick = b.get_float()
		cmds.append(c)
	return cmds


## players: Array di Dictionary {id, state: PlayerState, hits, deaths}
static func encode_snapshot(config: Array, tick: int, ack_seq: int, hold_ms: int, players: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(TYPE_SNAPSHOT)
	b.put_u8(config[0])
	b.put_u8(config[1])
	b.put_u16(int(round(config[2] * 100.0)))
	b.put_u32(tick)
	b.put_u32(ack_seq)
	b.put_u16(clampi(hold_ms, 0, 65535))
	b.put_u8(players.size())
	for p in players:
		var s: PlayerState = p.state
		b.put_u32(p.id)
		b.put_float(s.pos.x)
		b.put_float(s.pos.y)
		b.put_float(s.vel.x)
		b.put_float(s.vel.y)
		b.put_u8(s.cooldown)
		b.put_u16(p.hits)
		b.put_u16(p.deaths)
	return b.data_array


static func decode_snapshot(b: StreamPeerBuffer) -> Dictionary:
	var config := [b.get_u8(), b.get_u8(), b.get_u16() / 100.0]
	var snap := {config = config, tick = b.get_u32(), ack = b.get_u32(), hold_ms = b.get_u16(), players = {}}
	var n := b.get_u8()
	for i in n:
		var id := b.get_u32()
		var s := PlayerState.new()
		s.pos = Vector2(b.get_float(), b.get_float())
		s.vel = Vector2(b.get_float(), b.get_float())
		s.cooldown = b.get_u8()
		snap.players[id] = {state = s, hits = b.get_u16(), deaths = b.get_u16()}
	return snap


## Ritorna uno StreamPeerBuffer posizionato dopo il byte di tipo, e il tipo.
static func open(data: PackedByteArray) -> Array:
	var b := StreamPeerBuffer.new()
	b.data_array = data
	if data.is_empty():
		return [0, b]
	return [b.get_u8(), b]
