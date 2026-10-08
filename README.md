# Prototipo netcode stile Quake III (Godot 4, GDScript)

Il progetto Godot è in `nuovo-progetto-di-gioco/` (Godot 4.7). Server autoritativo
ENet, client-side prediction, server reconciliation, interpolazione delle entità
remote, simulatore di rete, overlay di debug, hitscan con lag compensation,
preset di rete competitivi (CS2) e muri con fog of war per mostrare il
peeker's advantage. I giocatori sono quadrati colorati in un'arena 2D vista dall'alto.

## Comandi

Tutti i comandi vanno lanciati dalla cartella `nuovo-progetto-di-gioco/`.
Gli argomenti del gioco vanno dopo `--`; `--headless` è il flag di Godot.

```sh
# Client con menu: campi IP e porta, oppure "Ospita partita" (server + gioca)
godot --path .

# Server dedicato (headless), in ascolto su 0.0.0.0 (tutte le interfacce IPv4)
godot --headless --path . -- --server --port=27960

# Client (finestra); qui con 50 ms per direzione, 10 ms di jitter, 5% di perdita
godot --path . -- --client --host=127.0.0.1 --port=27960 --lag=50 --jitter=10 --loss=0.05

# Server con i valori di Quake III invece di CS2 (default)
godot --headless --path . -- --server --preset=q3

# Server senza lag compensation / senza culling anti-wallhack (per confronto)
godot --headless --path . -- --server --no-lagcomp
godot --headless --path . -- --server --no-cull

# Test (exit code 0 = PASS, 1 = FAIL)
godot --headless --path . res://tests/test_netcode.tscn
```

Senza argomenti: in headless parte il server, con finestra il menu di connessione.
Con `--host=...` il client si connette direttamente senza menu. `--bind=IP`
cambia l'indirizzo d'ascolto del server (default `0.0.0.0`).

## Giocare con un amico

1. Chi ospita apre il gioco e preme **Ospita partita**, oppure lancia il server
   dedicato. L'overlay (e la console del server) mostrano gli IP locali.
2. **Stessa rete (LAN)**: l'amico inserisce l'IP locale dell'host (es.
   `192.168.1.10`) e la porta, e preme **Connetti**.
3. **Via Internet**: sul router dell'host serve il port forwarding della porta
   **UDP** (default 27960) verso il PC dell'host; l'amico usa l'IP pubblico
   dell'host. Anche il firewall del PC deve lasciar passare la porta UDP
   (Windows lo chiede al primo avvio). In alternativa una VPN tipo
   Tailscale/ZeroTier evita il port forwarding: si usa l'IP della VPN.
4. Se il server non risponde entro 5 s il client torna al menu con l'errore.
   L'ultimo IP/porta usati vengono ricordati.

Controlli del client: WASD/frecce per muoversi, click sinistro per sparare.
F3 mostra/nasconde l'overlay (ping, input in buffer, errore predetto/server).
F4 prediction, F5 reconciliation, F6 ridondanza degli input, F7 fog of war.
Il contorno bianco attorno al proprio quadrato è l'ultima posizione autoritativa ricevuta dal server.

Per vedere la differenza: avvia un client con `--lag=100 --loss=0.05`, spegni la
ridondanza (F6), così il server perde degli input e la predizione sbaglia. Con
la reconciliation (F5) accesa vedi piccoli scatti di correzione; spenta, il
quadrato si allontana sempre di più dal contorno del server. Con la prediction
spenta (F4) il movimento risponde in ritardo di un RTT e scatta a 20 Hz.

## Preset di rete

Il server sceglie il preset (`--preset=` o il menu "Ospita") e lo scrive
nell'header di ogni snapshot; il client si adegua da solo.

| Preset | Tick | Snapshot | Interpolazione | Lag compensation max | Riferimento |
|---|---|---|---|---|---|
| `cs2` (default) | 64 Hz | 64 Hz (ogni tick) | 31.25 ms (2 tick) | 200 ms | server competitivi CS2/CS:GO: tick 64, `cl_updaterate 64`, `cl_interp_ratio 2`, `sv_maxunlag 0.2` |
| `q3` | 60 Hz | 20 Hz | 100 ms (2 snapshot) | 1 s | default di Quake III (`sv_fps 20`, `snaps 20`) |

Non implementato: il *sub-tick* di CS2 (timestamp degli input dentro il tick),
il buffer di interpolazione adattivo e la delta compression degli snapshot.

Conseguenza di `sv_maxunlag = 200 ms`: la rewind richiesta è circa RTT +
interpolazione. Oltre i ~170 ms di ping il colpo non è più del tutto
compensato (come in CS2): il test lo mostra a 100 ms per direzione.

## Muri, fog of war e peeker's advantage

- **Muri** (`scripts/game/map.gd`): fanno parte della simulazione condivisa
  (collisione per asse, deterministica, si scivola lungo il muro) e fermano
  l'hitscan. Il muro in basso al centro forma un angolo: da `(120,520)` e
  `(520,520)` i due giocatori non si vedono finché uno non esce verso l'alto.
- **Fog of war** (lato client): il giocatore locale vede un avversario solo se
  c'è linea di vista tra la sua posizione predetta e la posizione interpolata
  dell'avversario. Le ombre dei muri sono disegnate sopra i giocatori. F7 la spegne.
- **Peeker's advantage**: chi sbuca dall'angolo si vede subito sul proprio schermo
  (prediction), mentre chi tiene l'angolo lo vede solo dopo
  ½ RTT (input del peeker) + attesa dello snapshot + ½ RTT + interpolazione.
  Il test lo misura (scenario E): con ping ~60 ms il vantaggio è circa
  **120 ms con il preset cs2 e circa 200 ms con q3**. Il peeker colpisce per
  primo 8 volte su 8 con entrambi.
- **Culling lato server (anti-wallhack)**: la fog del client è solo grafica; per
  impedire il wallhack il server manda a ogni client **solo i giocatori che
  potrebbe vedere**. Un client modificato che spegne la fog (F7) non ha i dati
  di chi è dietro un muro. `--no-cull` lo disattiva.
  - Il test di visibilità è conservativo, come il "fog of war" di Valorant: se
    il server usasse la linea di vista attuale, l'avversario arriverebbe in
    ritardo (il client è avanti di ½ RTT con la prediction e mostra gli altri
    nel passato), comparendo all'improvviso già in vista.
  - Per questo il server confronta due "scatole": quella in cui il destinatario
    può trovarsi sul proprio schermo (posizione → posizione + velocità × ritardo)
    e quella in cui può vedere l'altro (posizione → posizione − velocità × ritardo).
    Le scatole includono il corpo del giocatore + 8 px. Si testano angoli e centro
    (25 raggi): basta una linea di vista libera per mandare il giocatore.
  - Il ritardo di ciascun client è misurato dal server (`tick − view_tick` dei
    suoi comandi, cioè RTT + interpolazione, limitato a 1 s): non serve fidarsi
    del ping dichiarato dal client.
  - Limite: chi è *quasi* visibile (vicino allo spigolo o in movimento verso
    lo spigolo) viene mandato un po' prima; un wallhack vede quindi qualche
    decina di ms in anticipo, ma mai chi è fermo al riparo.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/game/movement.gd` | `simulate_move(state, cmd, delta)`: movimento deterministico condiviso (attrito e accelerazione alla Q3, cooldown dell'arma) |
| `scripts/game/player_state.gd`, `input_cmd.gd` | stato simulato e comando utente (usercmd) |
| `scripts/game/weapon.gd` | raggio hitscan contro i quadrati, fermato dai muri |
| `scripts/game/map.gd` | muri, spawn, linea di vista, collisioni |
| `scripts/game/fog.gd` | ombre della fog of war |
| `scripts/game/player.gd` | il quadrato disegnato |
| `scripts/net/server.gd` | server autoritativo, snapshot, cronologia, lag compensation |
| `scripts/net/client.gd` | prediction, reconciliation, interpolazione, traccianti |
| `scripts/net/net_sim.gd` | simulatore di latenza, jitter e perdita |
| `scripts/net/protocol.gd` | formato dei pacchetti in byte |
| `scripts/net/net_config.gd` | preset di rete (cs2, q3) |
| `scripts/net/debug_overlay.gd` | overlay F3 |
| `scripts/ui/connect_menu.gd` | menu iniziale: IP, porta, Connetti / Ospita |
| `scenes/main.tscn`, `scripts/main.gd` | entry point, parsing della riga di comando |
| `tests/test_netcode.tscn` | test headless |

## Modello di rete

- **Tick**: fisso (`_physics_process`) su server e client: 64 Hz con snapshot a ogni tick (cs2), oppure 60 Hz con snapshot a 20 Hz (q3).
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
- **Interpolazione**: i remoti sono mostrati a `render_tick = tick_server_stimato - interp`
  (31.25 ms in cs2, 100 ms in q3), con lerp tra i due snapshot che lo racchiudono.
- **Lag compensation**: ogni comando porta il `view_tick` (il `render_tick` del
  client in quel momento). Quando un comando spara, il server riporta gli altri
  giocatori alla loro posizione a `view_tick` (al massimo `max_unlag` indietro),
  lancia il raggio dalla posizione attuale del tiratore e poi torna al presente.

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
- **I giocatori non collidono tra loro**, solo con muri e bordi: il movimento di un
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

`tests/test_netcode.tscn` avvia server e client nello stesso processo con veri
socket ENet su localhost e input scriptati, per **entrambi i preset**. Gli
scenari A–D usano **100 ms di latenza per direzione (RTT ≈ 200 ms), 10 ms di
jitter e 5% di perdita per direzione**. L'errore di predizione viene misurato a
ogni avanzamento di `ack_seq`: distanza tra la posizione predetta dopo quel
comando e quella del server.

| Scenario | Verifica |
|---|---|
| A: prediction+reconciliation | **errore medio ≤ 0.5 px** (soglia), convergenza finale ≤ 0.01 px, interpolazione remoti media ≤ 5 px |
| B: ridondanza OFF (solo cs2) | il server perde input, la predizione sbaglia; la reconciliation riporta a 0 |
| C: ridondanza e reconciliation OFF (solo cs2) | informativo: la deriva resta |
| D: hitscan | si mira al bersaglio interpolato (solo se visibile); hit rate con lag compensation ≥ 90% entro la finestra di unlag |
| E: peeker's advantage + culling | ping ~60 ms (30 ms/direzione, 5 ms jitter, 1% loss): vantaggio > 0 e minore con cs2 che con q3; con il culling **0 fughe** (il peeker fermo dietro il muro non viene mai mandato) e **comparse in ritardo ≤ 2%** dei tick in cui l'avversario è visibile. Con cs2 si ripete senza culling per confronto |

Risultati dell'ultima esecuzione (Godot 4.7.2, headless, `RISULTATO: PASS`):

```
cs2 (64/64 Hz, interp 31.25 ms, unlag 200 ms)
A  errore predetto vs server: medio 0.0000 px, max 0.0000 px su 1155 misure
   interpolazione remoti vs server: medio 0.08 px, max 8.7 px
B  errore medio 0.19 px, max 8.08 px -> errore finale 0.0000 px
C  errore medio 13.9 px, max 36.0 px (deriva)
D  100 ms/dir (oltre sv_maxunlag): 42/50 a segno (84%), senza lag comp 0%
D   50 ms/dir: 45/45 a segno (100%), senza lag comp 20%
E  culling ON : vantaggio del peeker 126 ms, 8/8 | fughe 0/180 tick | comparse in ritardo 0/368
E  culling OFF: vantaggio del peeker 126 ms, 8/8 | fughe 180/180 tick

q3 (60/20 Hz, interp 100 ms, unlag 1 s)
A  errore predetto vs server: medio 0.0000 px, max 0.0000 px su 447 misure
   interpolazione remoti vs server: medio 0.13 px, max 16.0 px
D  100 ms/dir: 47/47 a segno (100%), senza lag comp 21%
E  culling ON : vantaggio del peeker 187 ms, 8/8 | fughe 0/180 tick | comparse in ritardo 0/356
```

Nello scenario E il peeker vede l'altro circa 40–60 ms *prima* del server (la
sua predizione è avanti di ½ RTT). Chi tiene l'angolo lo vede circa 60–80 ms
*dopo* il server con cs2 e circa 130–170 ms dopo con q3: con snapshot a 20 Hz
e 100 ms di interpolazione l'avversario arriva più tardi sullo schermo.

Controprova del culling: con un culling "ingenuo" (linea di vista centro-centro
attuale, senza anticipo) il test fallisce, con 125–182 tick di comparse in
ritardo; il peeker perde anche il vantaggio (fino a −131 ms), perché riceve
l'avversario solo quando il server lo vede già.
