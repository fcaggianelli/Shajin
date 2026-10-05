extends RefCounted
## Arma hitscan condivisa: raggio istantaneo contro i quadrati dei giocatori.

const Movement = preload("res://scripts/game/movement.gd")

const RANGE := 1200.0
const KNOCKBACK := 250.0  # spinta applicata dal server al bersaglio colpito


## Distanza lungo il raggio fino al quadrato centrato in `center`, o -1 se mancato
## (slab test raggio/AABB).
static func ray_vs_player(origin: Vector2, dir: Vector2, center: Vector2) -> float:
	var half := Movement.PLAYER_SIZE * 0.5
	var t_min := 0.0
	var t_max := RANGE
	for axis in 2:
		var o := origin[axis]
		var d := dir[axis]
		var lo := center[axis] - half
		var hi := center[axis] + half
		if absf(d) < 1e-8:
			if o < lo or o > hi:
				return -1.0
			continue
		var t1 := (lo - o) / d
		var t2 := (hi - o) / d
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
		if t_min > t_max:
			return -1.0
	return t_min


## Bersaglio più vicino colpito. `targets`: {id: Vector2}. Ritorna [id, distanza] o [0, RANGE].
static func trace(origin: Vector2, dir: Vector2, targets: Dictionary) -> Array:
	var best := [0, RANGE]
	for id in targets:
		var d := ray_vs_player(origin, dir, targets[id])
		if d >= 0.0 and d < best[1]:
			best = [id, d]
	return best
