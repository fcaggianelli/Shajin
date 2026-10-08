extends RefCounted
## Comando utente (usercmd di Quake III): un tick di input del client.

const FORWARD := 1
const BACK := 2
const LEFT := 4
const RIGHT := 8
const JUMP := 16
const FIRE := 32

var seq := 0        # numero di sequenza, uno per tick del client
var buttons := 0
var yaw := 0.0      # angoli di vista assoluti (come in Q3)
var pitch := 0.0
# Solo con FIRE: il raggio come l'ha visto il tiratore e il suo tempo.
var shot_time := 0.0              # stima del tick server corrente sul client
var shot_origin := Vector3.ZERO
var shot_dir := Vector3.ZERO
