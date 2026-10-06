extends RefCounted
## Preset di rete. Il server sceglie il preset e lo comunica nell'header di ogni
## snapshot; il client si adegua al primo snapshot ricevuto.
##
## cs2: valori dei server competitivi di Counter-Strike 2 / CS:GO
##   - tick 64 Hz, snapshot a ogni tick (cl_updaterate 64)
##   - interpolazione 2 tick = 31.25 ms (cl_interp_ratio 2 di CS:GO; CS2 usa ~1-2 tick)
##   - lag compensation limitata a 200 ms (sv_maxunlag 0.2)
##   - CS2 ha anche il "sub-tick" (timestamp degli input dentro il tick): qui NON è implementato.
## q3: valori di default di Quake III (snapshot 20 Hz, sv_fps 20), con la nostra
##   simulazione a 60 Hz e 100 ms di interpolazione (2 snapshot); unlag fino a 1 s.

const Movement = preload("res://scripts/game/movement.gd")

const PRESETS := {
	"cs2": {tick_rate = 64, snapshot_rate = 64, interp_ms = 31.25, max_unlag_ms = 200.0},
	"q3": {tick_rate = 60, snapshot_rate = 20, interp_ms = 100.0, max_unlag_ms = 1000.0},
}
const DEFAULT := "cs2"

static var preset_name := DEFAULT
static var tick_rate := 64
static var snapshot_every := 1     # tick tra due snapshot
static var interp_ms := 31.25
static var max_unlag_ms := 200.0


static func apply_preset(name: String) -> bool:
	if not PRESETS.has(name):
		return false
	var p: Dictionary = PRESETS[name]
	preset_name = name
	max_unlag_ms = p.max_unlag_ms
	apply(p.tick_rate, maxi(p.tick_rate / p.snapshot_rate, 1), p.interp_ms)
	return true


## Usato anche dal client con i valori ricevuti dal server.
static func apply(rate: int, every: int, interp: float) -> void:
	tick_rate = rate
	snapshot_every = every
	interp_ms = interp
	Movement.tick_rate = rate
	Engine.physics_ticks_per_second = rate


static func snapshot_rate() -> float:
	return float(tick_rate) / snapshot_every


static func interp_ticks() -> float:
	return interp_ms * tick_rate / 1000.0


static func ms_to_ticks(ms: float) -> int:
	return int(round(ms * tick_rate / 1000.0))
