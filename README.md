# Deathmatch 3D con netcode stile Quake III / CoD2 (Godot 4.7, GDScript)

Prototipo di deathmatch in prima persona, fino a 8 giocatori, con una sola arma
hitscan che uccide con un colpo. Grafica volutamente povera: capsule colorate in
una stanza con muri e coperture, nessun asset esterno. Il progetto è in
`nuovo-progetto-di-gioco/`. Il prototipo 2D precedente è in
`nuovo-progetto-di-gioco/proto2d/`.

## Architettura di rete

- **Server dedicato e autoritativo**: i client mandano solo input; il server
  simula, decide colpi, morti, respawn e punteggio.
- **Aggiornamenti frequenti ma non affidabili** per posizioni e orientamenti:
  **128 tick al secondo** su server e client, uno snapshot a ogni tick, come
  Valorant e CS2 a 128 tick. Gli input partono a ogni tick e ogni pacchetto
  contiene anche quelli non ancora confermati, così uno perso non costa nulla.
- **Canale affidabile e ordinato sopra UDP** (ENet) per gli eventi importanti:
  uccisioni, ingressi e uscite dei giocatori. Arrivano sempre, una volta sola,
  in ordine.
- **Predizione sul client** (i comandi hanno effetto subito), **interpolazione**
  degli altri giocatori con 2 tick di ritardo (15,6 ms) e **lag compensation**
  dei colpi, con rewind fino a 200 ms di latenza (come `sv_maxunlag 0.2`).
- **Traccia dei colpi degli avversari**: il server la manda subito a tutti gli
  altri (canale inaffidabile). Arancione = tua, rossa = avversario, con un suono
  diverso.
- **TCP/HTTPS per login, lobby e matchmaking: non implementato.** Il prototipo
  non ha login né lobby; quando ci saranno andranno su un servizio separato, non
  nel ciclo di gioco UDP.

| Parametro | Valore | Riferimento |
|---|---|---|
| tick di simulazione (server e client) | 128 Hz | Valorant, CS2 128 tick |
| snapshot server → client | 128 Hz (ogni tick) | `cl_updaterate 128` |
| input client → server | 128 Hz con ridondanza (fino a 32 comandi) | `cl_cmdrate 128`, `cl_packetdup` |
| interpolazione dei remoti | 15,6 ms (2 tick) | `cl_interp_ratio 2` |
| lag compensation | fino a 200 ms di latenza + interpolazione | `sv_maxunlag 0.2` |

## Ping: perché ora è vicino a quello di CoD2

Il ping mostrato è calcolato come in Q3/CoD2: dall'invio di un comando
all'arrivo dello snapshot che lo conferma, meno il tempo in cui il server lo ha
trattenuto. Due cose lo tenevano alto anche in locale:

1. **Il client leggeva la rete solo una volta per frame o tick** (16 ms a 60 Hz).
   Ora ha un thread di rete dedicato che serve ENet circa ogni 0,5 ms, sempre:
   i pacchetti partono appena creati e quelli in arrivo vengono letti subito.
2. **Il server dedicato in headless dormiva 6,9 ms a ogni frame** (risparmio
   energetico di Godot quando non c'è nulla da disegnare). Ora dorme 0,5 ms e
   gira a circa 1000 fps. Se lanciato con finestra non disegna nulla e non
   aspetta il vsync.

Misurato con server dedicato e client in due processi separati sulla stessa
macchina: **ping 1,8–1,9 ms, RTT di ENet 1–2 ms** (prima 17–20 ms), sia con il
client a 60 fps sia a 144 fps. In LAN aggiungi la latenza della rete locale
(< 1 ms via cavo). Su Internet, quella reale verso il PC del server.

## Rallentatore

Se il PC non riesce a eseguire 128 tick al secondo, Godot rallenta il tempo del
gioco: tutto va al rallentatore. L'overlay (F3) mostra `tick/s` (deve essere
128) e gli fps. Per ridurre il carico:
- il client rigioca gli input (riconciliazione) solo quando lo stato del server
  differisce da quello predetto: in pratica in circa l'1% degli snapshot
  invece che in tutti;
- il server dedicato non costruisce mesh né luci;
- Godot recupera fino a 16 tick per frame (prima 8).

Su un PC Windows ARM (Snapdragon) esporta per `arm64` invece che `x86_64`:
l'eseguibile x86_64 gira emulato ed è molto più lento.

## Comandi

Da `nuovo-progetto-di-gioco/`. Gli argomenti del gioco vanno dopo `--`.

```sh
# Server dedicato (consigliato headless), in ascolto su 0.0.0.0:27960, statistiche ogni 2 s
godot --headless --path . -- --server --port=27960 --stats

# Client diretto, con statistiche in console (ping, RTT ENet, fps, tick/s)
godot --path . -- --client --host=192.168.1.10 --port=27960 --stats

# Menu (IP e porta, oppure "Ospita partita" = server + gioca nello stesso processo)
godot --path .

# Simulatore di rete per direzione, sul processo dove lo metti
godot --path . -- --client --host=127.0.0.1 --lag=50 --jitter=10 --loss=0.05

# Tutti i test
tests/run_all.sh
```

Con l'eseguibile esportato: `"Netcode Q3 Prototype.console.exe" --headless -- --server --stats`.
"Ospita partita" mette server e client nello stesso processo con finestra: per
avere il ping minimo usa il server dedicato.

Comandi di gioco: mouse per guardare, WASD per muoversi, spazio per saltare,
click sinistro per sparare (cooldown 1 s), Esc per liberare il mouse.
F3 mostra o nasconde l'overlay (ping, RTT ENet, fps, tick/s, input in buffer,
errore predetto/server); F4 accende o spegne la prediction, F5 la reconciliation.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/game/movement.gd` | `simulate_move(state, input, delta)`: movimento cinematico condiviso (attrito, accelerazione e slide move di Q3) di una capsula, con query `cast_motion`/`get_rest_info` allo spazio fisico |
| `scripts/game/player_state.gd`, `input_cmd.gd` | stato simulato e usercmd |
| `scripts/game/weapon.gd` | hitscan: raggio contro capsula calcolato a mano, più raycast sulla geometria statica |
| `scripts/game/level.gd` | livello di prova (box), punti di spawn |
| `scripts/game/player.gd`, `shot_effects.gd` | capsula colorata; tracce e suoni dei colpi |
| `scripts/net/server.gd` | server autoritativo: comandi, snapshot, eventi affidabili, cronologia, lag compensation, partita |
| `scripts/net/client.gd` | prediction, reconciliation, interpolazione, sparo predetto, colpi nemici, camera |
| `scripts/net/net_sim.gd` | trasporto ENet: canale inaffidabile e affidabile, thread di rete del client, simulatore di latenza, jitter e perdita |
| `scripts/net/protocol.gd` | pacchetti a byte: input, snapshot, colpi, eventi |
| `scripts/net/net_config.gd` | 128 tick, snapshot a ogni tick, interpolazione, rewind |
| `scripts/net/debug_overlay.gd`, `scripts/ui/hud.gd`, `scripts/ui/connect_menu.gd` | overlay F3, HUD, menu |
| `scenes/main.tscn`, `scripts/main.gd` | entry point, riga di comando |
| `tests/` | test headless |

## Scelte di design non ovvie

- **Pacchetti a byte su `ENetMultiplayerPeer`** senza MultiplayerAPI/RPC; il
  canale affidabile è quello di ENet (ritrasmissione e ordine). Il simulatore di
  rete non perde mai i pacchetti affidabili: li ritarda soltanto.
- **Il server esegue i comandi appena arrivano** (come Q3), a ogni frame, non
  solo al tick.
- **Riconciliazione senza replay quando non serve**: se lo stato del server per
  l'ultimo comando confermato coincide bit per bit con quello predetto, la
  simulazione è deterministica e lo stato attuale è già corretto.
- **I giocatori non collidono tra loro**, solo con la geometria statica.
- **Float32**: il client arrotonda yaw/pitch a float32 prima di simulare, come
  li riceve il server.
- **Skin di 2 cm e depenetrazione** nel movimento: con Jolt `cast_motion` ignora
  le forme già toccate.
- **Sparo nel comando di input** (con ridondanza); il server riconvalida il
  cooldown con la stessa simulazione e l'origine del raggio (tolleranza 30 cm).
- **Interpolazione di 2 tick (15,6 ms)**: è il valore competitivo e dà il
  ritardo minimo. Con jitter o perdita oltre ~15 ms i remoti possono scattare per
  un attimo. È lo stesso compromesso di CS2 con `cl_interp_ratio` basso.

## Test e risultati

Ogni test di rete avvia 1 server e da 2 a 9 client nello stesso processo, con veri
socket ENet su localhost, input scriptati, **100 ms di latenza per direzione
(RTT ≈ 200 ms), 10 ms di jitter e 5% di perdita in entrata e in uscita**.
Eccezione: la fase 3, dove il tiratore ha 100 ms di ping, cioè 50 ms per
direzione. Le durate dei test sono in secondi, quindi valgono a ogni tick rate.

| Test | Cosa verifica | Soglia | Ultimo risultato (128 tick) |
|---|---|---|---|
| `test_movement` | replay bit-identico; 20 000 tick casuali senza entrare nei muri | 0 errori | 0/20 000, 0/8 |
| `test_phase1` | errore predetto vs server, 2 client (corsa, strafe, salti, urti) | media ≤ 1 cm, finale ≤ 1 mm | media **0.000000 m** su 2836 misure |
| ″ controprova | spostamento di 30 cm deciso dal server | errore > 1 cm, poi 0 | 0.300 m, finale 0.000000 m |
| `test_phase2` | remoti visualizzati vs cronologia del server, 3 client | media ≤ 5 cm, ritardo ≈ 2 tick | media **4 mm**, max 20 cm (snapshot persi/jitter oltre il buffer); ritardo 10 ms all'arrivo (+1 tick di misura) |
| `test_phase3` A | bersaglio a 8 m/s, tiratore con 100 ms di ping | ≥ 90% a segno | **12/12** (senza lag compensation 0/12); ping misurato 115 ms (prima 162); sparo → uccisione confermata 118 ms (prima 182); uccisioni ricevute da tutti sul canale affidabile 12/12; tracce nemiche ricevute 10/12 (canale inaffidabile, 5% di perdita) |
| ″ B | raggio verso un bersaglio dietro il muro | 0 a segno | **0/5** (capsula sulla traiettoria 5/5) |
| ″ C | client modificato che spara a ogni tick per 3 s | 3 accettati, distanza ≥ 1 s | **3 accettati**, **381 rifiutati** |
| ″ D | ping ~300 ms: latenza oltre 200 ms | tutti limitati, ≤ 10% a segno | **12/12 limitati, 0/12 a segno** (illimitato 12/12) |
| `test_phase4` | morte, respawn dopo 3 s nello spawn più lontano, protezione 2 s, punteggio, ingresso e uscita in corsa, massimo 8 giocatori | tutti veri | tutti veri (respawn dopo 2.99 s) |

## Cosa non ho potuto verificare

- **Feel e fluidità** con mouse e tastiera veri, su schermi reali.
- **Il rallentatore sul tuo PC**: non l'ho riprodotto qui (il server con finestra
  gira a 128 tick/s). L'overlay ora mostra `tick/s` e fps per capire se il PC
  non regge i 128 tick.
- **Il gioco su Internet tra due PC** (NAT, firewall, port forwarding UDP).
- **Determinismo tra macchine diverse** (CPU diverse, x86 emulato vs ARM nativo):
  se divergono, la riconciliazione corregge, ma con più replay.
- Il suono placeholder (in headless l'audio è disattivato).
