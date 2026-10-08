extends RefCounted
## Arma hitscan: raggio istantaneo dal centro della camera. Hit detection a mano:
## raggio contro la capsula (unico hitbox del giocatore) + raycast sulla geometria
## statica per verificare che nessun muro sia in mezzo.

const Movement = preload("res://scripts/game/movement.gd")

const RANGE := 100.0


## Distanza lungo il raggio (rd normalizzata) fino alla capsula del giocatore con
## i piedi in `foot`, o -1 se mancata. Capsula = segmento [pa, pb] con raggio r.
static func ray_vs_capsule(ro: Vector3, rd: Vector3, foot: Vector3) -> float:
	var r := Movement.RADIUS
	var pa := foot + Vector3(0, r, 0)
	var pb := foot + Vector3(0, Movement.HEIGHT - r, 0)
	var ba := pb - pa
	var oa := ro - pa
	var baba := ba.dot(ba)
	var bard := ba.dot(rd)
	var baoa := ba.dot(oa)
	var rdoa := rd.dot(oa)
	var oaoa := oa.dot(oa)
	var a := baba - bard * bard
	var b := baba * rdoa - baoa * bard
	var c := baba * oaoa - baoa * baoa - r * r * baba
	if a > 1e-9:
		var h := b * b - a * c
		if h >= 0.0:
			var t := (-b - sqrt(h)) / a
			var y := baoa + t * bard
			if y > 0.0 and y < baba and t >= 0.0:
				return t  # corpo cilindrico
	# Calotte sferiche
	var best := -1.0
	for center in [pa, pb]:
		var oc: Vector3 = ro - center
		var bb := rd.dot(oc)
		var cc := oc.dot(oc) - r * r
		var hh := bb * bb - cc
		if hh >= 0.0:
			var t := -bb - sqrt(hh)
			if t >= 0.0 and (best < 0.0 or t < best):
				best = t
	return best


## Distanza dal primo muro lungo il raggio (RANGE se nessuno).
static func wall_distance(ro: Vector3, rd: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(ro, ro + rd * RANGE, Movement.LEVEL_MASK)
	var hit := Movement.space.intersect_ray(q)
	return ro.distance_to(hit.position) if not hit.is_empty() else RANGE


## Primo giocatore colpito tra `targets` ({id: posizione dei piedi}).
## Ritorna {id (0 = nessuno), dist, blocked_id (capsula colpita ma dietro un muro)}.
static func trace(ro: Vector3, rd: Vector3, targets: Dictionary) -> Dictionary:
	var best_id := 0
	var best_t := RANGE
	for id in targets:
		var t := ray_vs_capsule(ro, rd, targets[id])
		if t >= 0.0 and t < best_t:
			best_id = id
			best_t = t
	var wall := wall_distance(ro, rd)
	if best_id != 0 and wall < best_t:
		return {id = 0, dist = wall, blocked_id = best_id}
	return {id = best_id, dist = best_t if best_id != 0 else wall, blocked_id = 0}
