extends RefCounted
## Parametri di rete fissi del deathmatch.

const TICK_RATE := 60           # simulazione su server e client
const SNAPSHOT_EVERY := 3       # 60 / 3 = 20 snapshot al secondo
const INTERP_MS := 100.0        # i remoti sono mostrati 100 ms nel passato
const MAX_REWIND_MS := 200.0    # lag compensation: latenza massima compensata
const HISTORY_SECONDS := 1.0    # cronologia per il rewind


static func ms_to_ticks(ms: float) -> float:
	return ms * TICK_RATE / 1000.0
