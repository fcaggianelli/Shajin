extends RefCounted
## Parametri di rete, sui valori dei server competitivi di Valorant / CS2 a 128 tick.

const TICK_RATE := 128          # simulazione su server e client (Valorant, CS2 "128 tick")
const SNAPSHOT_EVERY := 1       # uno snapshot a ogni tick: 128 al secondo
const INTERP_MS := 2000.0 / TICK_RATE  # 15.625 ms = 2 tick (cl_interp_ratio 2)
const MAX_REWIND_MS := 200.0    # lag compensation: latenza massima compensata (sv_maxunlag 0.2)
const HISTORY_SECONDS := 1.0    # cronologia per il rewind


static func ms_to_ticks(ms: float) -> float:
	return ms * TICK_RATE / 1000.0
