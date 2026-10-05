# Prototipo netcode stile Quake III (Godot 4, GDScript)

Il progetto Godot è in `nuovo-progetto-di-gioco/` (Godot 4.7). Server autoritativo
ENet, client-side prediction, server reconciliation, interpolazione delle entità
remote, simulatore di rete, overlay di debug e hitscan con lag compensation.
I giocatori sono quadrati colorati in un'arena 2D vista dall'alto.

## Comandi

Tutti i comandi vanno lanciati dalla cartella `nuovo-progetto-di-gioco/`.
Gli argomenti del gioco vanno dopo `--`; `--headless` è il flag di Godot.

```sh
# Server dedicato (headless)
godot --headless --path . -- --server --port=27960

# Client (finestra); qui con 50 ms per direzione, 10 ms di jitter, 5% di perdita
godot --path . -- --client --host=127.0.0.1 --port=27960 --lag=50 --jitter=10 --loss=0.05

# Server senza lag compensation (per confronto)
godot --headless --path . -- --server --no-lagcomp

# Test (exit code 0 = PASS, 1 = FAIL)
godot --headless --path . res://tests/test_netcode.tscn
```

Senza argomenti: in headless parte il server, con finestra parte il client.

Controlli del client: WASD/frecce per muoversi, click sinistro per sparare.
F3 mostra/nasconde l'overlay (ping, input in buffer, errore predetto/server).
F4 prediction, F5 reconciliation, F6 ridondanza degli input.
Il contorno bianco attorno al proprio quadrato è l'ultima posizione autoritativa ricevuta dal server.

Per vedere la differenza: avvia un client con `--lag=100 --loss=0.05`, spegni la
ridondanza (F6), così il server perde degli input e la predizione sbaglia. Con
la reconciliation (F5) accesa vedi piccoli scatti di correzione; spenta, il
quadrato si allontana sempre di più dal contorno del server. Con la prediction
spenta (F4) il movimento risponde in ritardo di un RTT e scatta a 20 Hz.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/game/movement.gd` | `simulate_move(state, cmd, delta)`: movimento deterministico condiviso (attrito e accelerazione alla Q3, cooldown dell'arma) |
| `scripts/game/player_state.gd`, `input_cmd.gd` | stato simulato e comando utente (usercmd) |
| `scripts/game/weapon.gd` | raggio hitscan contro i quadrati |
| `scripts/game/player.gd` | il quadrato disegnato |
| `scripts/net/server.gd` | server autoritativo, snapshot, cronologia, lag compensation |
| `scripts/net/client.gd` | prediction, reconciliation, interpolazione, traccianti |
| `scripts/net/net_sim.gd` | simulatore di latenza, jitter e perdita |
| `scripts/net/protocol.gd` | formato dei pacchetti in byte |
| `scripts/net/debug_overlay.gd` | overlay F3 |
| `scenes/main.tscn`, `scripts/main.gd` | entry point, parsing della riga di comando |
| `tests/test_netcode.tscn` | test headless |

## Modello di rete

- **Tick**: 60 Hz fissi (`_physics_process`) su server e client; snapshot a 20 Hz (ogni 3 tick).
- **Input**: ogni tick il client crea un comando con numero di sequenza, lo
  applica subito (prediction), lo mette nel buffer dei pendenti e invia
  *tutti* i pendenti (max 32) in un pacchetto inaffidabile. Se un pacchetto si
  perde, i comandi arrivano col successivo.
- **Server**: esegue i comandi appena arrivano, in ordine di sequenza, scartando
  i duplicati. Ogni snapshot contiene lo stato di tutti e, per il destinatario,
  `ack_seq` (ultimo comando applicato).
- **Reconciliation**: il client scarta i comandi `<= ack_seq`, riparte dallo
  stato del server e rigioca i comandi rimasti. Se le simulazioni coincidono il
  risultato è identico alla predizione: nessuno scatto.
- **Interpolazione**: i remoti sono mostrati a `render_tick = tick_server_stimato - 6`
  (100 ms), con lerp tra i due snapshot che lo racchiudono.
- **Lag compensation**: ogni comando porta il `view_tick` (il `render_tick` del
  client in quel momento). Quando un comando spara, il server riporta gli altri
  giocatori alla loro posizione a `view_tick` (cronologia di 1 s), lancia il
  raggio dalla posizione attuale del tiratore e poi torna al presente.

## Scelte di design non ovvie (sempre la più semplice)

- **Niente RPC né MultiplayerSynchronizer**: si usa `ENetMultiplayerPeer`
  direttamente (`put_packet`/`get_packet`, canale inaffidabile), senza
  MultiplayerAPI. Così il simulatore di rete può intercettare ogni pacchetto, e
  il test può avere server e due client nello stesso processo.
- **Il simulatore vale per direzione**: `--lag=100` aggiunge 100 ms in uscita e
  100 ms in entrata sul nodo dove è configurato (RTT +200 ms). Si può
  applicare a server, client o entrambi.
- **Il server esegue i comandi all'arrivo** (come Q3) invece di bufferizzarli e
  consumarne uno per tick: niente buffer da dimensionare, nessuna attesa in più.
  Ogni comando vale esattamente un tick (`DT = 1/60`), sia sul server che nella
  predizione.
- **I giocatori non collidono tra loro**, solo con i bordi: il movimento di un
  giocatore dipende solo dai suoi input, quindi la predizione è esatta.
- **Float a 32 bit nei pacchetti**: sono gli stessi float32 dei `Vector2`, quindi
  lo stato ricevuto è bit-identico a quello del server e il replay riproduce
  esattamente la predizione (errore 0.0 px nel test).
- **Cronologia della lag compensation agli istanti degli snapshot** (20 Hz,
  ~1 s) interpolata come fa il client: il server ricostruisce esattamente ciò
  che il tiratore vedeva. Se il client ha perso uno snapshot, la sua
  interpolazione può differire leggermente.
- **Ping** = tempo tra l'invio del comando `ack_seq` e la ricezione dello snapshot
  che lo conferma, meno il tempo in cui il server lo ha trattenuto (`hold_ms`).
  Include la quantizzazione a 60 Hz di invio e ricezione (circa +30-50 ms).
- **Sparo predetto**: il cooldown è dentro `simulate_move`, quindi anche il
  client sa se ha sparato e disegna subito il tracciante. Se ha colpito lo decide
  solo il server. Il colpo dà una spinta al bersaglio, che il suo client non
  può predire: la reconciliation la corregge.
- Overlay visibile di default; F3 lo nasconde.

## Test

`tests/test_netcode.tscn` avvia 1 server e 2 client nello stesso processo con
veri socket ENet su localhost, input scriptati, **100 ms di latenza per direzione
(RTT ≈ 200 ms) + 10 ms di jitter e 5% di perdita per direzione**. L'errore viene
misurato a ogni avanzamento di `ack_seq`: distanza tra la posizione predetta
dopo quel comando e quella del server.

| Scenario | Verifica |
|---|---|
| A: prediction+reconciliation | **errore medio ≤ 0.5 px** (soglia del test), convergenza finale ≤ 0.01 px, interpolazione remoti media ≤ 5 px |
| B: ridondanza OFF | il server perde input, la predizione sbaglia; si verifica che la reconciliation riporti a 0 |
| C: ridondanza e reconciliation OFF | informativo: la deriva resta |
| D: hitscan | il tiratore mira al bersaglio interpolato; hit rate con lag compensation ≥ 90% |

Risultati dell'ultima esecuzione (Godot 4.7.2, headless):

```
A  errore predetto vs server: medio 0.0000 px, max 0.0000 px su 406 misure
   correzione visiva max 0.0000 px, errore finale 0.0000 px, ping ~258 ms
   interpolazione remoti vs server: medio 0.69 px, max 34.1 px (snapshot persi)
B  errore medio 0.53 px, max 15.02 px -> errore finale 0.0000 px
C  errore medio 15.02 px, max 36.69 px, errore finale ~14-15 px (deriva)
D  50 colpi: a segno CON lag compensation 50 (100%), SENZA 4 (8%)
RISULTATO: PASS
```
