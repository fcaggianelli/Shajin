extends RefCounted
## Un comando utente (usercmd in Quake III): un tick di input del client.

const UP := 1
const DOWN := 2
const LEFT := 4
const RIGHT := 8
const FIRE := 16

var seq := 0          # numero di sequenza, crescente, uno per tick del client
var buttons := 0      # bitmask dei tasti sopra
var aim := 0.0        # angolo di mira in radianti (usato solo con FIRE)
var view_tick := 0.0  # tick server che il client stava visualizzando (lag compensation)
