# SECU-DAT Web UI

Browserfähiger Port des bisherigen Android-Prototyps für das SECUTEST-/PSI-Projekt.

## Ziel

- Bedienung am PC im Browser zum Debuggen und Austüfteln der Sequenzen
- Bedienung unterwegs direkt auf dem Android-Handy, ohne entfernten PC-Server
- Gleiche Weboberfläche auf beiden Geräten
- Gleiche TCP-/Sequenzlogik auf Windows und Android
- Kein separater Android-UI-Port mehr nötig

## Betriebsarten

### 1. PC-Modus für Entwicklung und Feintuning

```text
Windows-PC startet lokalen Server
Browser am PC öffnet http://127.0.0.1:8787
Server spricht TCP mit dem USR-W610 / SECUTEST
```

Wenn Handy und PC im selben Netz sind, kann die UI zusätzlich vom Handy über die PC-IP geöffnet werden.

### 2. Handy-lokal für den Außeneinsatz

```text
Android-Handy ist per WLAN mit dem USR-W610 verbunden
Termux startet den lokalen Python-Webserver direkt auf dem Handy
Browser desselben Handys öffnet http://127.0.0.1:8787
Server spricht lokal vom Handy aus TCP mit 10.10.100.254:8899
```

Das ist der für die mobile Prüfung relevante Modus. Es ist kein entfernter PC und kein Internet nötig.

## Warum Termux?

Für diese persönliche, portable Werkstattlösung ist Termux der pragmatische Weg:

- Python läuft direkt auf dem Android-Gerät
- derselbe Servercode läuft auf Windows und Android
- die Oberfläche bleibt eine normale Browser-Web-UI
- der TCP-Zugriff auf den USR-W610 bleibt serverseitig möglich

Für ein späteres „sauberes“ ausgeliefertes Android-Produkt wäre eher eine native Android-Hülle mit eingebettetem lokalen Server oder direkter TCP-Schicht sinnvoll. Für deinen aktuellen Workflow spart Termux aber sehr viel Doppelarbeit.

## Technische Entscheidung für Android-Kompatibilität

Der erste Web-Port basierte auf FastAPI/Pydantic. Für Termux ist das unnötig fehleranfällig, weil Pydantic v2 `pydantic-core` nutzt und auf Android/Termux schnell Rust-/Build-Probleme entstehen.

Diese Version nutzt deshalb:

- **Starlette** statt FastAPI
- **Uvicorn** als ASGI-Server
- **WebSockets** für Live-Logs
- manuelle, schlanke JSON-Validierung ohne Pydantic

Damit bleibt die App async-fähig, aber deutlich Termux-freundlicher.

## Enthalten

- Responsive Weboberfläche im Stil der bisherigen SECU-DAT-App
- Verbindung zur WLAN-/TCP-Bridge
- Live-TX/RX-Log per WebSocket
- Manuelle Befehle und Preset-Kommandos
- Eigene editierbare Sequenz-Buttons
- Sequenzbuttons:
  - Leitungen messen
  - SK I/II adaptiv
- Adaptive SK-I/II-Logik mit:
  - `STOP`
  - `EK;EK`
  - `RSLK` / `RSLAC`
  - `NTZON;NULL`
- PSI-Datensatz übernehmen (`WER?`)
- PSI-Speicher leeren (`MEM!`)
- Messung speichern mit Metadaten
- SQLite-Datenbank lokal auf dem Hostgerät
- Excel-Export und Excel-Import
- Serverseitiges Excel-Autosave nach jedem gespeicherten Datensatz
- Vorschläge für Geräteart, Hersteller und IDs
- Datensatzverlauf inkl. Filter, Sortierung und Bearbeiten

## Kommunikationsprinzip

Der Web-Port ist bewusst nicht delay-gesteuert gebaut:

1. Befehl senden
2. Antwort vollständig empfangen
3. Antwort prüfen
4. Erst dann nächsten Befehl senden

Query-Befehle wie `MES?`, `WER?`, `PRO?`, `ESR?` erwarten Datenantworten.  
Aktionsbefehle wie `TAS!4`, `MEM!`, `RST!0` erwarten ACK/NACK.

## Start unter Windows

1. Ordner entpacken
2. `run.bat` doppelklicken
3. Browser öffnen:
   - lokal: `http://127.0.0.1:8787`
   - vom Handy über den PC-Server: `http://<IP-DEINES-PCs>:8787`

Beispiel: `http://192.168.178.25:8787`

## Start unter Android mit Termux

### Empfohlenes Setup

Termux möglichst aus **F-Droid oder GitHub** installieren. Der Google-Play-Stand ist zwar wieder vorhanden, gilt aber weiterhin als experimenteller Zweig mit Einschränkungen gegenüber dem stabileren F-Droid-/GitHub-Weg.

### Erste Einrichtung

1. ZIP-Datei auf das Handy kopieren und entpacken.
2. Termux öffnen.
3. In den entpackten Ordner wechseln.
4. Einmalig ausführen:

```bash
bash setup_termux.sh
```

5. Danach starten mit:

```bash
bash start_termux.sh
```

Alternativ einmalig Setup + Start zusammen:

```bash
bash run_termux_first_time.sh
```

### Auf dem Handy öffnen

Im Android-Browser:

```text
http://127.0.0.1:8787
```

Die UI läuft dann im Browser auf demselben Gerät, auf dem auch der Server läuft.

## USR-W610-Außeneinsatz

Für deinen mobilen Prüfmodus:

1. Android-Handy mit dem WLAN des USR-W610 verbinden
2. SECU-DAT-Webserver in Termux starten
3. Browser auf `http://127.0.0.1:8787` öffnen
4. In der Web-UI Verbindung zu:
   - Host: `10.10.100.254`
   - Port: `8899`

Damit läuft die komplette Kommunikation lokal auf dem Handy.

## Datenablage

- SQLite-Datenbank:
  - `data/secudata_web.db`
- Excel-Autosave standardmäßig:
  - `data/records_autosave.xlsx`

Pfad und Aktivierung lassen sich in den Einstellungen ändern.

## Einstellungen im UI

- Bridge-IP
- Port
- Pollintervall
- Command-Timeout
- Simulation an/aus
- Excel-Autosave an/aus
- Autosave-Dateipfad

## Tests

```bash
python -m unittest discover -v
```

Aktuell enthalten:

- Frame-/Checksum-Tests
- ACK/NACK-Erkennung inkl. `.Y1`-Variante
- WER-/PSI-Record-Parsing
- MES-Status-Parsing
- Parser-Schutz gegen falsche RPE-Zuordnung
- Parsing editierbarer Custom-Sequenzbuttons
- einfache JSON-/Setting-Validierung für boolesche Werte und Grenzbereiche

## Bewusst noch nicht umgesetzt

- Browser-Kamera-/QR-Scanner aus dem Android-Prototyp
  - Der wurde nicht halbgar eingebaut, weil Kamera-Zugriff auf Handy je nach Browser/Hostingkontext gesondert betrachtet werden muss.
  - Für `localhost` ist das später deutlich besser lösbar als beim Zugriff auf eine fremde PC-IP.

## Auffälligkeiten aus dem Android-Stand, die im Web-Port korrigiert wurden

- Der Checksum-Test `MES?;STOP;$A5` ist rechnerisch nicht mit der dokumentierten Summenbildung vereinbar. Im Web-Port wurde der korrekte Testwert verwendet.
- Der alte Messwertparser konnte bei `RPE;0,21;...;U;230` fälschlich `230` als RPE übernehmen. Das ist korrigiert.
- Zwei offensichtliche Wörterbuch-Tipper wurden korrigiert:
  - `Cornputer` → `Computer`
  - `mLüfter/Wentilator` → `Lüfter/Ventilator`

## Fix12 · 31.05.2026

- Nach erfolgreichem lokalen Speichern wird der PSI-Protokollspeicher per `MEM!` geleert.
- Danach wird der aktuelle Gerätemodus per `RST!0` neu gestartet und die Adressierung erneut geprüft/initialisiert: `IDN?` → `IDN!0` → `IDN?` → `IDN1!1` → `IDN1?`.
- Cleanup-Fehler werden geloggt und in der Save-Antwort gemeldet, erzeugen aber keinen fehlgeschlagenen lokalen Save, damit keine Dubletten durch Wiederholung entstehen.
- Mobile Ansicht: Messwerte stehen jetzt direkt nach den Vorschlägen, danach Ablaufstatus, darunter das Verbindungslog.
- Mobile Ansicht: Der Konsolen-Tab ist wieder erreichbar und kompakter gestaltet, inklusive Live-Log und letzter Frames.
- Datensatzübersicht: gespeicherte Messwerte werden je Datensatz kompakt angezeigt.


## fix14: adressierter Modus-Reset nach dem Speichern

Nach erfolgreichem Speichern wird der PSI-Protokollspeicher mit `MEM!` gelöscht. Danach wird zuerst die Adressierung geprüft/initialisiert, dann der zuletzt verwendete Prüfmodus mit einem direkt adressierten RST-Befehl zurückgesetzt und anschließend erneut adressiert. Live-Mapping: `RST1!3` für SK I/II und `RST1!4` für Leitungen. Die RST-Adresse ist in den Einstellungen konfigurierbar, Standard ist `1`.
