extends Node
## Movimento condiviso, senza rete:
##   godot --headless --path . res://tests/test_movement.tscn
## 1. replay: rigiocando gli stessi input da uno stato intermedio copiato si
##    ottiene uno stato bit-identico (requisito della reconciliation);
## 2. 20 000 tick di input casuali (corsa, salti, rotazioni) da ogni spawn: la
##    capsula non deve mai entrare nella geometria né uscire dalla stanza.

const Level = preload("res://scripts/game/level.gd")
const Movement = preload("res://scripts/game/movement.gd")
const PlayerState = preload("res://scripts/game/player_state.gd")
const InputCmd = preload("res://scripts/game/input_cmd.gd")

## Jolt arrotonda gli spigoli dei box (raggio convesso ~5 cm): misurando contro
## spigoli vivi una capsula che "sfiora" lo spigolo sembra entrarci di ~2 cm.
const TOLERANCE := 0.025


func _ready() -> void:
	add_child(Level.new())
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var bad := 0
	var replay_mismatch := 0
	var max_height := 0.0
	for spawn in Level.SPAWNS:
		var s := PlayerState.new()
		s.pos = spawn
		var cmds := []
		var yaw := rng.randf() * TAU
		var buttons := 0
		var log := []
		for i in 2500:
			if i % 20 == 0:
				buttons = rng.randi() & 31
				yaw += rng.randf_range(-1.5, 1.5)
			var c := InputCmd.new()
			c.buttons = buttons
			c.yaw = yaw
			cmds.append(c)
			Movement.simulate_move(s, c, Movement.DT)
			log.append(s.copy())
			max_height = maxf(max_height, s.pos.y)
			if _penetrates(s.pos):
				bad += 1
		var r = log[1249].copy()
		for i in range(1250, 2500):
			Movement.simulate_move(r, cmds[i], Movement.DT)
		if r.pos != s.pos or r.vel != s.vel or r.on_ground != s.on_ground:
			replay_mismatch += 1
	print("tick dentro la geometria: %d / %d | replay non identici: %d / %d | altezza massima %.2f m" % [
		bad, 2500 * Level.SPAWNS.size(), replay_mismatch, Level.SPAWNS.size(), max_height])
	ok = bad == 0 and replay_mismatch == 0 and max_height > 0.5
	print("\nRISULTATO: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _penetrates(pos: Vector3) -> bool:
	var lim := 20.0 - Movement.RADIUS + 0.01
	if pos.y < -0.01 or absf(pos.x) > lim or absf(pos.z) > lim:
		return true
	for b in Level.BOXES.slice(1):
		var lo: Vector3 = b[0] - b[1] / 2
		var hi: Vector3 = b[0] + b[1] / 2
		for k in 21:
			var p := pos + Vector3(0, Movement.RADIUS + (Movement.HEIGHT - 2 * Movement.RADIUS) * k / 20.0, 0)
			if p.distance_to(p.clamp(lo, hi)) < Movement.RADIUS - TOLERANCE:
				return true
	return false
