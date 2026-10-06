extends RefCounted
## Mappa condivisa: muri, spawn, linea di vista. Usata identica da server e client
## (collisioni nella simulazione, hitscan, fog of war).
##
## Il muro in basso al centro forma l'angolo per il peeker's advantage: chi sta a
## sinistra (120,520) e chi sta a destra (520,520) non si vedono finché uno dei
## due non esce verso l'alto oltre lo spigolo (400..460, 380).

const WALLS := [
	Rect2(400, 380, 60, 220),  # angolo del peek
	Rect2(140, 400, 120, 30),  # copertura bassa a sinistra
	Rect2(600, 330, 40, 130),  # copertura a destra
	Rect2(360, 40, 40, 70),    # pilastro in alto
]
const SPAWNS := [Vector2(150, 150), Vector2(700, 150), Vector2(120, 520), Vector2(520, 520)]


## Distanza lungo il raggio (dir normalizzata) fino al rettangolo, o -1 se non lo
## tocca entro max_t. Slab test; se origin è dentro il rettangolo ritorna 0.
static func ray_vs_rect(origin: Vector2, dir: Vector2, rect: Rect2, max_t: float) -> float:
	var t_min := 0.0
	var t_max := max_t
	for axis in 2:
		var o := origin[axis]
		var d := dir[axis]
		var lo := rect.position[axis]
		var hi := rect.end[axis]
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


## Distanza dal primo muro lungo il raggio (max_t se nessuno).
static func ray_to_walls(origin: Vector2, dir: Vector2, max_t: float) -> float:
	var best := max_t
	for w in WALLS:
		var t := ray_vs_rect(origin, dir, w, best)
		if t >= 0.0 and t < best:
			best = t
	return best


## Linea di vista centro-centro: simmetrica (se A vede B, B vede A).
static func line_of_sight(a: Vector2, b: Vector2) -> bool:
	var d := b - a
	var length := d.length()
	if length < 0.001:
		return true
	return ray_to_walls(a, d / length, length) >= length


## Collisione su un asse dopo che pos si è mossa lungo quell'asse: se il quadrato
## (lato `size`) entra in un muro viene riportato sul bordo e la velocità su
## quell'asse azzerata. Deterministica: stessi input, stesso risultato.
static func collide_axis(state, axis: int, size: float) -> void:
	var half := size * 0.5
	for w in WALLS:
		var r: Rect2 = w.grow(half)
		if state.pos.x > r.position.x and state.pos.x < r.end.x and state.pos.y > r.position.y and state.pos.y < r.end.y:
			var v: float = state.vel[axis]
			var lo: float = r.position[axis]
			var hi: float = r.end[axis]
			var p: float = state.pos[axis]
			if v > 0.0 or (v == 0.0 and p - lo < hi - p):
				state.pos[axis] = lo
			else:
				state.pos[axis] = hi
			state.vel[axis] = 0.0
