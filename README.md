# Deathmatch 3D con netcode stile Quake III (Godot 4.7, GDScript)

Prototipo di deathmatch in prima persona, fino a 8 giocatori, con una sola arma
hitscan che uccide con un colpo. Server autoritativo ENet, client-side prediction,
server reconciliation, interpolazione dei remoti e lag compensation. Grafica
volutamente povera: capsule colorate in una stanza con muri e coperture, nessun
asset esterno. Il progetto è in `nuovo-progetto-di-gioco/`. Il prototipo 2D
precedente è in `nuovo-progetto-di-gioco/proto2d/` (vedi il suo README).

## Comandi

Da `nuovo-progetto-di-gioco/`. Gli argomenti del gioco vanno dopo `--`.

```sh
# Menu (IP e porta, oppure "Ospita partita" = server su 0.0.0.0 + gioca)
godot --path .

# Server dedicato headless, in ascolto su 0.0.0.0:27960
godot --headless --path . -- --server --port=27960

# Client diretto; qui con il simulatore di rete: 50 ms per direzione, 10 ms di jitter, 5% di perdita
godot --path . -- --client --host=127.0.0.1 --port=27960 --lag=50 --jitter=10 --loss=0.05

# Tutti i test (o uno: godot --headless --path . res://tests/test_phase3.tscn)
tests/run_all.sh
```

Senza argomenti: in headless parte il server, con finestra il menu. Con `--stats` il client stampa in console ping di rete e latenza di gioco ogni 2 s.
`--lag/--jitter/--loss` valgono per direzione (entrata e uscita) sul processo
dove li metti, server o client.

Comandi di gioco: mouse per guardare, WASD per muoversi, spazio per saltare,
click sinistro per sparare (cooldown 1 s), Esc per liberare il mouse.
F3 mostra o nasconde l'overlay di debug (ping di rete, latenza di gioco, input
in buffer, errore predetto/server); F4 accende o spegne la prediction, F5 la reconciliation.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/game/movement.gd` | `simulate_move(state, input, delta)`: movimento cinematico condiviso (attrito, accelerazione e slide move di Q3) di una capsula, con query `cast_motion`/`get_rest_info` allo spazio fisico |
| `scripts/game/player_state.gd`, `input_cmd.gd` | stato simulato (posizione, velocità, yaw/pitch, a terra, vivo, cooldown) e usercmd |
| `scripts/game/weapon.gd` | hitscan: raggio contro capsula calcolato a mano, più raycast sulla geometria statica |
| `scripts/game/level.gd` | livello di prova costruito da una lista di box, punti di spawn |
| `scripts/game/player.gd`, `shot_effects.gd` | capsula colorata; traccia e "bip" dello sparo |
| `scripts/net/server.gd` | server autoritativo: comandi, snapshot, cronologia, lag compensation, morte/respawn/punteggio |
| `scripts/net/client.gd` | prediction, reconciliation, interpolazione, sparo predetto, camera |
| `scripts/net/net_sim.gd` | simulatore di latenza, jitter e perdita (in entrata e in uscita) |
| `scripts/net/protocol.gd` | pacchetti di input e snapshot impacchettati a mano in byte |
| `scripts/net/net_config.gd` | 60 Hz di tick, 20 Hz di snapshot, 100 ms di interpolazione, 200 ms di rewind massimo |
| `scripts/net/debug_overlay.gd`, `scripts/ui/hud.gd`, `scripts/ui/connect_menu.gd` | overlay F3, HUD, menu |
| `scenes/main.tscn`, `scripts/main.gd` | entry point, riga di comando |
| `tests/` | test headless (`net_test_base.gd` avvia server e client nello stesso processo) |

## Modello di rete

- **Tick 60 Hz** su server e client (`_physics_process`), **snapshot a 20 Hz**.
- **Input**: ogni tick il client crea un comando con numero di sequenza (tasti,
  yaw, pitch), lo applica subito (prediction) e invia tutti i comandi non ancora
  confermati (max 32) in un pacchetto inaffidabile: se uno si perde, arrivano
  col successivo.
- **Server**: esegue i comandi appena arrivano, in ordine di sequenza; ogni
  snapshot contiene, per il destinatario, l'ultimo comando applicato.
- **Reconciliation**: il client scarta i comandi confermati, riparte dallo stato
  del server e rigioca gli altri. Morte e respawn arrivano allo stesso modo.
- **Interpolazione**: gli altri sono mostrati a `tick stimato − 100 ms`, con lerp
  di posizione e yaw tra i due snapshot che racchiudono quell'istante.
- **Sparo**: il comando con FIRE porta il tempo del tiratore (la sua stima del tick
  server), l'origine e la direzione del raggio. Il server ricontrolla il cooldown
  con la stessa simulazione, verifica che l'origine coincida con l'occhio che
  calcola lui (tolleranza 30 cm), riavvolge gli altri giocatori, prova il raggio
  contro le capsule riavvolte e poi un raycast sui muri. L'uccisione viaggia
  negli snapshot (ultime 4, deduplicate per id). Quando c'è un'uccisione il
  server manda subito uno snapshot extra, senza aspettare il prossimo dei 20 Hz.
- **Invio immediato**: client e server consegnano a ENet i pacchetti del tick e
  li spediscono a fine tick (`NetSim.flush()`). Prima ogni pacchetto aspettava
  2 tick in più per direzione: circa 50 ms di ping anche in locale.
- **Lag compensation**: istante riavvolto = `tick − min(latenza, 200 ms) − 100 ms`,
  con `latenza = tick − tempo del tiratore`. Il limite di 200 ms vale per la
  latenza di rete; i 100 ms di interpolazione si aggiungono sempre. La
  cronologia (1 s) è salvata agli istanti degli snapshot e interpolata con la
  stessa funzione del client, così il server ricostruisce esattamente ciò che il
  tiratore vedeva.
- **Partita**: respawn dopo 3 s nello spawn più lontano dai giocatori vivi (che
  massimizza la distanza dal più vicino), 2 s di protezione (capsula
  semitrasparente, i colpi la attraversano), +1 per uccisione. Massimo 8 giocatori:
  il nono viene rifiutato da ENet. Chi entra a partita in corso nasce nello spawn
  più lontano; chi esce sparisce dagli snapshot.

## Scelte di design non ovvie (sempre la più semplice)

- **Pacchetti a byte su `ENetMultiplayerPeer` senza MultiplayerAPI/RPC**: così il
  simulatore di rete intercetta ogni pacchetto e i test mettono server e più
  client nello stesso processo.
- **I giocatori non collidono tra loro**, solo con la geometria statica: il
  movimento dipende solo dagli input del giocatore, quindi la predizione è
  esatta. Le capsule degli altri contano solo come hitbox.
- **Float32 ovunque**: il client arrotonda yaw/pitch a float32 *prima* di simulare,
  così usa gli stessi valori che riceve il server. Senza questo passaggio
  l'errore era di qualche µm invece di zero.
- **Skin di 2 cm e depenetrazione**: con Jolt `cast_motion` ignora le forme che la
  capsula sta già toccando, quindi la capsula resta sempre a 2 cm dalla
  geometria. Uno spawn a contatto esatto col pavimento ci faceva cadere attraverso.
- **Sparo nel comando di input** (con ridondanza), non in un messaggio a parte. Il
  client che rispetta il cooldown manda FIRE solo quando la sua predizione dice
  che spara; il server rifiuta gli altri. Il cooldown è contato in tick di
  comando, non al momento di arrivo, così il jitter non fa rifiutare colpi
  legittimi.
- **Protezione**: protegge chi è appena rinato, ma non gli impedisce di sparare.
- **Camera**: la posizione è interpolata tra gli ultimi due tick predetti, gli
  angoli vengono subito dal mouse. Senza questo, a più di 60 fps la vista
  scatterebbe a 60 Hz.

## Test e risultati

Ogni test di rete avvia 1 server e da 2 a 9 client nello stesso processo, con veri
socket ENet su localhost, input scriptati, **100 ms di latenza per direzione
(RTT ≈ 200 ms), 10 ms di jitter e 5% di perdita in entrata e in uscita**. Fa
eccezione la fase 3: chiede esplicitamente un tiratore con 100 ms di *ping*,
quindi lì si usano 50 ms per direzione.

**Ping e latenza di gioco.** L'overlay mostra due numeri:
- **ping rete**: il round-trip misurato da ENet, cioè il ping "puro" che
  mostrano anche Valorant o CS;
- **latenza di gioco**: dal momento in cui il comando viene creato a quello in
  cui il client ne riceve la conferma. È il ping più le attese del ciclo di
  gioco: il client crea comandi e legge gli snapshot una volta per tick (60 Hz,
  in media circa 8 ms di attesa).

Il server applica i comandi appena arrivano e manda subito gli snapshot con le
uccisioni: legge la rete a ogni frame, e da dedicato headless gira a 1000 fps.
Con "Ospita" il server legge la rete alla frequenza dei frame della finestra di
chi ospita. Con il simulatore acceso si aggiunge circa un tick per direzione,
perché il simulatore rilascia i pacchetti ritardati una volta per tick.

| Test | Cosa verifica | Soglia | Ultimo risultato |
|---|---|---|---|
| `test_movement` | replay bit-identico; 20 000 tick casuali senza entrare nei muri | 0 errori | 0/20 000 dentro la geometria, 0/8 replay diversi |
| `test_phase1` | errore predetto vs server dopo la reconciliation, 2 client (corsa, strafe, salti, urti) | **media ≤ 1 cm**, convergenza finale ≤ 1 mm | media **0.000000 m**, max 0.000000 m su 642 misure |
| ″ controprova | spinta lato server non predicibile: l'errore deve vedersi e sparire | errore > 5 cm, finale ≤ 1 mm | max 0.072 m, finale 0.000000 m |
| `test_phase2` | remoti visualizzati vs cronologia del server, 3 client | **media ≤ 5 cm**, ritardo 70–130 ms | media **0.0023 m**, max 0.19 m (snapshot persi), ritardo 87 ms + 1 tick di misura |
| `test_phase3` A | bersaglio a 8 m/s, tiratore con 100 ms di ping mira a ciò che vede | ≥ 90% a segno | **12/12** (senza lag compensation 0/12), uccisioni ricevute da tutti 12/12; dallo sparo all'uccisione confermata in media 148 ms (rete locale senza simulatore: 13–20 ms) |
| ″ B | raggio verso un bersaglio dietro il muro | 0 a segno | **0/5**: la capsula era sulla traiettoria 5/5, ma il muro è in mezzo |
| ″ C | client modificato che spara a ogni tick per 3 s | 3 accettati, distanza ≥ 1 s | **3 accettati** (seq 2, 63, 124), **177 rifiutati** |
| ″ D | ping ~300 ms: latenza oltre il limite di 200 ms | tutti limitati, ≤ 10% a segno | **12/12 limitati, 0/12 a segno** (con rewind illimitato 12/12) |
| `test_phase4` | morte vista da tutti; respawn dopo 3 s nello spawn più lontano; protezione 2 s; punteggio; ingresso e uscita a partita in corso; massimo 8 giocatori | tutti veri | respawn dopo 2.98 s nello spawn atteso; 2 colpi durante la protezione senza effetto, uccisione dopo; punteggio 2 su server e 3 client; D entra nello spawn più lontano; C esce e sparisce da tutti; il nono rifiutato |

La soglia di 1 cm della fase 1: con simulazione deterministica l'atteso è 0. Un
tick di corsa vale 13 cm, quindi 1 cm basta a far scattare il test con qualsiasi
divergenza sistematica. La soglia di 5 cm della fase 2: l'errore viene solo
dagli snapshot persi (5%), quando si interpola su 100 ms invece che su 50.

## Cosa non ho potuto verificare

Questo lo devi giudicare tu giocando. I test sono tutti headless con bot e input
scriptati.

- **Feel dei comandi**: sensibilità del mouse (0.0025 rad/pixel), accelerazione,
  attrito, salto (valori di Quake III scalati: 8 m/s, salto di circa 1.1 m) e
  cadenza di 1 s.
- **Fluidità percepita**: interpolazione della camera tra i tick, dei remoti a
  20 Hz, correzioni visibili con perdita di pacchetti. Gli screenshot li ho
  fatti con rendering software (circa 20 fps), quindi non dicono nulla sulla
  fluidità.
- **Gioco reale su Internet** tra due PC diversi (NAT, firewall, port forwarding UDP).
- **Determinismo tra macchine diverse**: client e server con CPU o sistemi
  operativi diversi potrebbero divergere di poco nei calcoli float di Jolt. La
  reconciliation corregge, ma nei test client e server girano sullo stesso
  binario.
- Il **suono** placeholder (in headless l'audio è disattivato).
- L'**export Windows** di `export_presets.cfg`: ora esporta il deathmatch 3D, che è la
  scena principale. Non l'ho provato.
