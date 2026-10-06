extends RefCounted
## Arma hitscan condivisa: raggio istantaneo contro i quadrati dei giocatori.

const Movement = preload("res://scripts/game/movement.gd")
const Map = preload("res://scripts/game/map.gd")

const RANGE := 1200.0
const KNOCKBACK := 250.0  # spinta applicata dal server al bersaglio colpito


## Distanza lungo il raggio fino al quadrato centrato in `center`, o -1 se mancato.
static func ray_vs_player(origin: Vector2, dir: Vector2, center: Vector2) -> float:
	var s := Movement.PLAYER_SIZE
	return Map.ray_vs_rect(origin, dir, Rect2(center - Vector2(s, s) / 2, Vector2(s, s)), RANGE)


## Bersaglio più vicino colpito, fermandosi al primo muro.
## `targets`: {id: Vector2}. Ritorna [id, distanza] o [0, distanza dal muro/RANGE].
static func trace(origin: Vector2, dir: Vector2, targets: Dictionary) -> Array:
	var best := [0, Map.ray_to_walls(origin, dir, RANGE)]
	for id in targets:
		var d := ray_vs_player(origin, dir, targets[id])
		if d >= 0.0 and d < best[1]:
			best = [id, d]
	return best
