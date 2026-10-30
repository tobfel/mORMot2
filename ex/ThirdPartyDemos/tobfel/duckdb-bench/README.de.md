# dbbench - DuckDB vs. SQLite3 vs. PostgreSQL für Analysen

[English](README.md) | Deutsch

`dbbench` führt dieselben Analyse-Abfragen auf DuckDB, SQLite3 und PostgreSQL
aus, alle über die `mormot.db.sql`-Klassen. Die Zahlen entsprechen also dem, was
eine mORMot-Anwendung erreicht.

Es beantwortet zwei Fragen:
- Wann lohnt sich DuckDB gegenüber den üblichen Speicher-Engines von mORMot?
- Wie viel SQL braucht jede Engine für typische Auswertungen?

## Die Datensätze

Zwei Datensätze (Option `--dataset`): ein Standard-Benchmark und echte Open Data.

### `tpch`: der TPC-H-Benchmark

[TPC-H](https://www.tpc.org/tpch/) ist der Referenz-Benchmark für analytische
Datenbanken (Decision Support): 8 Tabellen eines Großhändlers (Bestellungen,
Positionen, Kunden, Teile, Lieferanten, Länder, Regionen) und 22 Abfragen.

- **Reproduzierbar:** DuckDB erzeugt die Daten selbst (`CALL dbgen(sf = 1)`),
  ohne Download und auf jedem Rechner identisch.
- **Skalierbar:** Scale Factor 1 sind 6 Millionen `lineitem`-Zeilen (etwa 1 GB
  CSV), 10 sind 60 Millionen und so weiter.
- **Vergleichbar:** DuckDB, PostgreSQL, ClickHouse und viele Fachartikel
  veröffentlichen TPC-H-Zahlen. Für einen breiteren Vergleich, auch mit SQLite
  und PostgreSQL, siehe [ClickBench](https://benchmark.clickhouse.com/)
  (100 Millionen Zeilen Web-Analytics).

### `rail`: die Open Data der niederländischen Bahn

[Rijden de Treinen](https://www.rijdendetreinen.nl/en/open-data) veröffentlicht
seit 2019 jede Zugfahrt in den Niederlanden mit jedem Halt, Verspätung, Ausfall
und Gleiswechsel (CC BY 4.0): etwa 22 Millionen Halte und 2,4 Millionen
Zugfahrten pro Jahr, als gzip-komprimierte CSV.

- **Echte Daten, echte Fragen:** Pünktlichkeit, Verspätungen pro Station und
  Uhrzeit, Ausfälle - die Art Bericht, die eine Anwendung liefern muss.
- **Normalisiert wie eine Anwendungsdatenbank:** `sql/rail/load.duckdb.sql`
  teilt die CSV in die Tabellen `stations`, `services` und `stops` auf, so wie
  ein ORM sie speichern würde. Die Abfragen joinen daher.
- **Skalierbar:** `--years 2023,2024` lädt mehrere Jahre (eine Datei pro Jahr).

### Laden

`dbbench --prepare` lädt die Daten mit DuckDB (`dbgen` für `tpch`, `read_csv`
über HTTPS für `rail`) und kopiert sie dann per DuckDB `ATTACH (TYPE sqlite)`
und `ATTACH (TYPE postgres)` nach SQLite3 und PostgreSQL. Alle Engines enthalten
damit exakt dieselben Zeilen.

## Die Abfragen

Alle Abfragen holen alle Ergebniszeilen ab. Die Zahlen jedes Ergebnisses werden
summiert und zwischen den Engines verglichen: ein `*` in den Ergebnissen
markiert ein abweichendes Ergebnis.

### `tpch`-Abfragen

| Datei | was | warum |
|---|---|---|
| `q01` | TPC-H Q1, 8 Aggregate über 98 % von `lineitem` | Full Scan |
| `q03`, `q10` | TPC-H-Joins über 3-4 Tabellen mit Top N | Join und Sortierung |
| `q05` | TPC-H-Join über 6 Tabellen und ein Jahr | Join-Reihenfolge |
| `q06` | TPC-H, selektiver Bereich, durch einen Index abgedeckt | indexfreundlich |
| `q12`, `q14` | TPC-H-Joins mit bedingten Aggregaten | |
| `q18` | TPC-H, Group By über ganz `lineitem` in einer Unterabfrage | großes Hash-Aggregat |
| `a1` | Monatsumsatz mit gleitendem 3-Monats-Durchschnitt | Window über ein Aggregat |
| `a2` | die 3 besten Kunden pro Land | Top N pro Gruppe |
| `a3` | Median und 90. Perzentil pro Priorität | Perzentile |
| `a4` | Umsatz pro Jahr und Versandart | Pivot-Tabelle |
| `a5` | Umsatz pro Region und Land mit Zwischensummen | Rollup |
| `a6` | teuerste Bestellung pro Priorität | Arg Max |
| `a7` | verschiedene Kunden pro Jahr und Segment | Count Distinct |
| `p1` | 10.000 Zugriffe per Primärschlüssel | OLTP |
| `p2` | 10.000 einzelne Inserts in einer Transaktion | OLTP |

### `rail`-Abfragen

| Datei | was | warum |
|---|---|---|
| `r1` | Pünktlichkeit (Ankünfte unter 3 Minuten Verspätung) pro Monat und Betreiber | Join aller Halte |
| `r2` | Stationen mit der höchsten durchschnittlichen Abfahrtsverspätung | erst aggregieren, dann joinen |
| `r3` | Verspätung und verspätete Abfahrten pro Uhrzeit und Zugtyp | Join, Zeitfunktionen |
| `r4` | Median und 95. Perzentil der Verspätung pro Zugtyp | Perzentile |
| `r5` | ausgefallene Zugfahrten pro Wochentag | Datumsfunktionen |
| `r6` | die 20 verspätetsten Zugfahrten mit Start- und Zielbahnhof | Arg Min / Max |
| `r7` | tägliche Abfahrten einer Station mit gleitendem 7-Tage-Durchschnitt | selektiv, Window |
| `r8` | Stationen mit den meisten Gleiswechseln | erst aggregieren, dann joinen |

`queries/<dataset>/xxx.sql` ist das DuckDB-SQL, `xxx.pg.sql` und `xxx.sqlite.sql`
überschreiben es, wenn sich der Dialekt unterscheidet. `p1` und `p2` nutzen
gecachte Prepared Statements, wie das mORMot-ORM.

## Die Engines

| Engine | was |
|---|---|
| `duckdb` | eingebettetes DuckDB, Datei schreibgeschützt geöffnet |
| `sqlite` | eingebettetes SQLite3 (von mORMot statisch gelinkt) |
| `postgres` | PostgreSQL-Server über libpq, auf demselben Rechner |
| `duckdb-sqlite` | DuckDB-Engine liest die **SQLite3-Datei** (`ATTACH ... (TYPE sqlite)`) |
| `duckdb-postgres` | DuckDB-Engine liest die **PostgreSQL-Tabellen** (`ATTACH ... (TYPE postgres)`) |
| `quack` | entfernter DuckDB-Server über das Quack-Protokoll (Option `--quack`) |

Die beiden `duckdb-*`-Engines zeigen den hybriden Ansatz: Die Anwendung behält
ihre SQLite3- (z. B. das mORMot-ORM) oder PostgreSQL-Datenbank für OLTP und
führt die Auswertungen mit der DuckDB-Engine auf denselben Daten aus, ohne
Migration.

## Indizes: Best Practice pro Engine

Die Dateien liegen in `sql/tpch` und `sql/rail`.

- **SQLite3** (`schema.sqlite.sql`, `index.sqlite.sql`): `INTEGER PRIMARY KEY`
  (die rowid), zusammengesetzter Schlüssel für `lineitem` und `partsupp`, ein
  Index pro Fremdschlüssel und pro gefiltertem Datum, abdeckende Indizes für
  `q06` und für die Aggregate pro Station bei `rail`, danach `ANALYZE`.
  Verbindungseinstellungen: 8-KB-Seiten, WAL, 2 GB Page Cache, 8 GB
  `mmap_size`, temporäre Daten im Speicher.
- **PostgreSQL** (`schema.pg.sql`, `index.pg.sql`): `NUMERIC(15,2)` wie in der
  TPC-H-Spezifikation, `VARCHAR` statt `CHAR(n)`, Primärschlüssel sowie dieselben
  Sekundär- und abdeckenden Indizes nach dem Laden angelegt, danach
  `VACUUM ANALYZE` für die Statistiken und die Index-Only Scans.
  Server-Einstellungen unter [PostgreSQL-Einstellungen](#postgresql-einstellungen).
- **DuckDB** (`sql/tpch/index.duckdb.sql`): kein Index für Analysen. DuckDB
  speichert Min/Max-Werte pro Row Group (Zonemaps) und überspringt damit Daten.
  Der Primärschlüssel auf `orders` dient nur den Zugriffen per Schlüssel (`p1`).

## Ausführen

```
# PostgreSQL-Benutzer, wie in den Vorgaben von dbbench
sudo -u postgres psql -c "create user bench password 'bench' superuser"

# dbbench.dpr mit Delphi oder FPC kompilieren (64 Bit für das eingebettete
# DuckDB), libduckdb.so / duckdb.dll daneben legen, dann:
./dbbench --prepare --sf 1 -d /data        # TPC-H erzeugen und laden (einmalig)
./dbbench --sf 1 -d /data --md sf1.md      # alle Abfragen, je 5 Läufe
./dbbench --sf 1 -d /data -o q01,a3 -e duckdb,sqlite   # eine Auswahl

./dbbench --prepare -s rail --years 2024 -d /data   # herunterladen und laden
./dbbench -s rail --years 2024 -d /data --md rail-2024.md
./dbbench --help
```

Jede Abfrage läuft einmal zum Aufwärmen der Caches und zur Prüfung des
Ergebnisses, dann `--runs`-mal (Vorgabe 5): die Tabelle zeigt den Median.
Dauert das Aufwärmen länger als `--maxseconds` (Vorgabe 30), wird nicht
wiederholt (`^` in der Tabelle).

`--prepare` installiert die DuckDB-Extensions `tpch`, `sqlite`, `postgres` (und
`httpfs`); mit `--extrepo https://extensions.duckdb.org`, falls einfaches HTTP
gesperrt ist. Für `rail` kann `--railurl` auf eine lokale Kopie der Dateien
`services/services-JJJJ.csv.gz` und `stations/stations-2023-09.csv` zeigen.

## PostgreSQL-Einstellungen

```
shared_buffers = 4GB
effective_cache_size = 10GB
work_mem = 256MB
maintenance_work_mem = 1GB
max_parallel_workers_per_gather = 4
max_parallel_workers = 4
random_page_cost = 1.1
max_wal_size = 8GB
```

## Ergebnisse: rail 2024

Dieselbe Ausführungsumgebung wie unten, Daten von 2024:
21.857.914 Halte, 2.395.636 Zugfahrten, 591 Stationen.

| | DuckDB | SQLite3 | PostgreSQL |
|---|---:|---:|---:|
| Datei- / Datenbankgröße | 307 MB | 1,9 GB | 2,7 GB |
| Laden | 31 s (aus der lokalen CSV.gz) | 40 s (Kopie aus DuckDB) | 38 s (Kopie aus DuckDB) |
| Indizes und Statistiken | - | 1 min 42 s | 1 min 13 s |

| Abfrage | Zeilen | duckdb | sqlite (mORMot statisch 3.51.2) | sqlite (libsqlite3 3.45.1) | postgres | duckdb-sqlite | duckdb-postgres |
|---|---:|---:|---:|---:|---:|---:|---:|
| r1-punctuality-month | 158 | **486.91ms** | 32.91s^ | 18.40s | 2.46s | 1.33s | 2.56s |
| r2-worst-stations | 10 | **41.79ms** | 8.13s | 1.44s | 435.73ms | 836.41ms | 1.64s |
| r3-delay-by-hour | 217 | **409.07ms** | 36.69s^ | 23.55s | 7.76s | 1.63s | 3.89s |
| r4-delay-percentiles | 18 | **770.11ms** | 2m25^ | 1m14^ | 9.88s | 1.45s | 2.15s |
| r5-cancellations-weekday | 7 | **10.74ms** | 2.47s | 1.12s | 165.83ms | 94.92ms | 173.21ms |
| r6-most-delayed-trips | 20 | **48.14ms** | 688.02ms | 134.14ms | 102.16ms | 1.68s | 2.22s |
| r7-station-daily-trend | 366 | **62.05ms** | 993.05ms | 670.88ms | 1.21s | 1.32s | 702.98ms |
| r8-platform-changes | 10 | **31.89ms** | 7.40s | 1.38s | 440.31ms | 818.82ms | 1.68s |

Alle Engines lieferten dieselben Ergebnisse; `^` ist ein einzelner Lauf (über 30 s).

- Mit echten Daten ergibt sich dasselbe Bild wie mit TPC-H: DuckDB ist 3- bis
  190-mal schneller als SQLite3 (je nach Bibliothek) und 2- bis 20-mal schneller
  als PostgreSQL. Am kleinsten ist der Abstand bei den selektiven `r6` / `r7`,
  die die Indizes von SQLite3 und PostgreSQL nutzen, am größten bei den Joins
  über alle 22 Millionen Halte (`r1`, `r3`, `r4`).
- Die DuckDB-Datei ist 6-mal kleiner als SQLite3 und 9-mal kleiner als
  PostgreSQL, Indizes eingerechnet.
- Das hybride `duckdb-sqlite` erstellt die großen Berichte `r1`, `r3` und `r4`
  aus der SQLite3-Datei 14- bis 100-mal schneller als SQLite3 selbst.

## Ergebnisse: TPC-H Scale Factor 1

### Ausführungsumgebung

- Cloud-VM: 4 vCPU Intel Xeon @ 2,10 GHz, 15 GB RAM, Ubuntu 24.04, Linux 6.18
- dbbench kompiliert mit FPC 3.2.2 (x86_64-linux, `-O2`), mORMot 2 `master`
  vom 30.10.2026
- DuckDB 2.0.0 (offizielle `libduckdb.so`), SQLite 3.51.2 (statische
  `sqlite3.o` von mORMot aus dem Release `2.4-stable`), PostgreSQL 16.15
  (Ubuntu-Paket, [Einstellungen](#postgresql-einstellungen)) auf derselben VM,
  verbunden über TCP/localhost
- alle Daten im Datei-Cache des Betriebssystems, nur warme Läufe

### Datenbankgröße und Ladezeit (Scale Factor 1: 6 Millionen `lineitem`-Zeilen)

| | DuckDB | SQLite3 | PostgreSQL |
|---|---:|---:|---:|
| Datei- / Datenbankgröße | 314 MB | 1,5 GB | 1,6 GB |
| Laden | 8,8 s (`dbgen`) | 33 s (Kopie aus DuckDB) | 26 s (Kopie aus DuckDB) |
| Indizes und Statistiken | - | 62 s | 31 s |

### Abfragezeiten (Median aus 5 Läufen, Schnellste fett)

| Abfrage | Zeilen | duckdb | sqlite (mORMot statisch 3.51.2) | sqlite (libsqlite3 3.45.1) | postgres | duckdb-sqlite | duckdb-postgres |
|---|---:|---:|---:|---:|---:|---:|---:|
| a1-monthly-trend | 80 | **16.36ms** | 3.13s | 2.31s | 142.49ms | 71.53ms | 156.65ms |
| a2-top3-per-nation | 75 | **56.51ms** | 4.15s | 3.29s | 2.92s | 148.18ms | 223.44ms |
| a3-median-price | 5 | **32.12ms** | 12s | 6.13s | 1.06s | 114.07ms | 199.42ms |
| a4-pivot-shipmode | 7 | **58.23ms** | 12.55s | 6.21s | 711.31ms | 473.83ms | 816.02ms |
| a5-rollup-region | 31 | **42.35ms** | 3.49s | 2.86s | 1.25s | 123.34ms | 185.86ms |
| a6-top-order-per-priority | 5 | **15.97ms** | 1.99s | 1.17s | 416.84ms | 80.12ms | 201.95ms |
| a7-distinct-customers | 35 | **47.92ms** | 4.61s | 3.91s | 2.02s | 189.27ms | 205.05ms |
| q01-pricing-summary | 4 | **33.90ms** | 17.05s | 7s | 1.24s | 587.57ms | 1.27s |
| q03-shipping-priority | 10 | **27.71ms** | 1.38s | 1.19s | 550.74ms | 477.13ms | 718.70ms |
| q05-local-supplier | 5 | **34.57ms** | 1.03s | 883.85ms | 322.13ms | 420.82ms | 903.50ms |
| q06-forecast-revenue | 1 | **10.36ms** | 260.68ms | 52ms | 70.84ms | 342.14ms | 198.47ms |
| q10-returned-item | 20 | **55.45ms** | 778.96ms | 589.13ms | 269.68ms | 492.32ms | 465.40ms |
| q12-shipping-modes | 2 | **22.25ms** | 1.81s | 843.61ms | 320.64ms | 525.69ms | 390.77ms |
| q14-promotion-effect | 1 | **21.95ms** | 256.61ms | 198.15ms | 178.94ms | 421.56ms | 220.53ms |
| q18-large-volume | 57 | **70.57ms** | 3.31s | 873.14ms | 4.53s | 388.01ms | 725.13ms |
| p1-point-lookups | 10000 | 6.43s | 18.44ms | **15.97ms** | 676.03ms | n/a | n/a |
| p2-single-inserts | 10000 | 8.64s | 8.25ms | **6.82ms** | 607.71ms | n/a | n/a |

Alle Engines lieferten dieselben Ergebnisse. Die Spalte `sqlite (libsqlite3
3.45.1)` ist dasselbe `dbbench.dpr`, kompiliert mit `-dNOSQLITE3STATIC`, also mit
der System-Bibliothek: Auf diesem Rechner ist die statische SQLite3 von mORMot
bei diesen lesenden Abfragen 1,1- bis 5-mal langsamer (Ursache noch nicht
untersucht).

### Anmerkungen

- **Analysen:** DuckDB ist 10- bis 500-mal schneller als SQLite3 und 5- bis
  65-mal schneller als PostgreSQL, auf 4 Kernen. SQLite3 arbeitet single-threaded
  und zeilenbasiert; PostgreSQL nutzt bis zu 4 parallele Worker, liest aber ganze
  Zeilen und rechnet mit `NUMERIC`-Werten.
- **Indizes helfen OLTP, nicht Analysen:** das selektive `q06` nutzt in SQLite3
  und PostgreSQL einen abdeckenden Index und ist trotzdem 5- bis 25-mal
  langsamer als ein DuckDB-Scan ohne Index.
- **Bei OLTP ist es umgekehrt:** Ein Zugriff per Schlüssel oder ein einzelnes
  Insert kostet mit SQLite3 1 bis 2 µs, mit PostgreSQL 60-70 µs (ein
  Netzwerk-Roundtrip) und mit DuckDB 0,6-0,9 ms. Das liegt an der DuckDB-Engine
  selbst: Das Python-Modul `duckdb` 2.0.0 zeigt dieselben Zeiten, der
  mORMot-Treiber ist also nicht der Engpass.
- **Hybrid:** DuckDB auf der SQLite3-Datei (`duckdb-sqlite`), ohne Migration und
  ohne zusätzliche Kopie, ist bei Scans, Aggregaten und Joins 2- bis 100-mal
  schneller als SQLite3 auf der eigenen Datei, aber langsamer bei den
  indexfreundlichen `q06` und `q14`: DuckDB nutzt die SQLite3-Indizes nicht.
  DuckDB auf PostgreSQL (`duckdb-postgres`) liest die Tabellen per binärem
  `COPY`: schneller als PostgreSQL bei den schweren Abfragen (`a2`, `a3`, `a5`,
  `a6`, `a7`, `q18`), langsamer bei den indexfreundlichen.
- **Abfrage-Tuning, wie es ein erfahrener Anwender tun würde** (siehe die
  Kommentare in den Dateien `queries/*/*.pg.sql` / `*.sqlite.sql`):
  - SQLite3 `q01`: Der Planer nutzte den `l_shipdate`-Index für 98 % der Zeilen
    (26 s). Das unäre `+l_shipdate` schaltet ihn ab: 17 s.
  - SQLite3 `q12`: `CROSS JOIN` erzwingt, zuerst `lineitem` zu lesen - doppelt
    so schnell.
  - PostgreSQL `a6`: `DISTINCT ON` sortiert alle Bestellungen (7,6 s); ein Join
    mit dem `max()` pro Gruppe braucht 0,4 s.
  - PostgreSQL `a7`: `count(DISTINCT)` sortiert immer; eine
    `DISTINCT`-Unterabfrage erlaubt ein paralleles Hash-Aggregat (5,4 s auf 2 s).
  - `rail` `r2` / `r8`: erst pro Station aggregieren, dann mit `stations` joinen
    (auf allen Engines dasselbe SQL) - SQLite3 von 10,7 s auf 1,7 s.
  - DuckDB brauchte kein Tuning.

## SQL für Analysen: DuckDB vs. PostgreSQL vs. SQLite3

Die `a*`- und `r*`-Abfragen tun auf jeder Engine dasselbe; ein Vergleich der
Dateien in `queries/tpch` und `queries/rail` zeigt die Unterschiede.

| Bedarf | DuckDB | PostgreSQL | SQLite3 |
|---|---|---|---|
| Gruppieren nach allen nicht aggregierten Spalten | `GROUP BY ALL` | Spalten wiederholen | Spalten wiederholen |
| Select-Alias wiederverwenden | auch im Window-`ORDER BY` (`a1`) | `GROUP BY`, `ORDER BY` | `GROUP BY`, `ORDER BY` |
| Top N pro Gruppe (`a2`) | `QUALIFY row_number() OVER (...) <= 3` | Unterabfrage + `WHERE rn <= 3` | Unterabfrage + `WHERE rn <= 3` |
| Median, Perzentile (`a3`, `r4`) | `median(x)`, `quantile_cont(x, 0.9)` | `percentile_cont(0.9) WITHIN GROUP (ORDER BY x)` | standardmäßig keine: 2 Windows + Interpolation |
| Pivot-Tabelle (`a4`) | `PIVOT ... ON col IN (...) USING sum(x)` | `sum(x) FILTER (WHERE col = ...)` pro Spalte | `sum(x) FILTER (WHERE col = ...)` pro Spalte |
| Zwischensummen (`a5`) | `GROUP BY ROLLUP / CUBE / GROUPING SETS` | `GROUP BY ROLLUP / CUBE / GROUPING SETS` | ein `UNION ALL` pro Ebene |
| Wert am Maximum (`a6`, `r6`) | `arg_max(key, value)` | `DISTINCT ON (...) ... ORDER BY` oder Join mit `max()` | Spalte neben `max()` |
| nächste vorherige Zeile in der Zeit | `ASOF JOIN` | `LATERAL (... ORDER BY ... LIMIT 1)` | korrelierte Unterabfrage |
| Spalten per Muster | `SELECT * EXCLUDE (a)`, `COLUMNS('price_.*')` | - | - |
| Tabelle profilieren | `SUMMARIZE orders` | - | - |
| Dateien direkt abfragen | `FROM 'data.parquet'`, `read_csv('https://...')` | Extension oder `COPY` | - |
| Export | `COPY (SELECT ...) TO 'out.parquet'` | `COPY ... TO` (CSV/binär) | - |

## Wann DuckDB das richtige Werkzeug ist

DuckDB ist ein Column Store mit einer vektorisierten, mehrkernigen Engine:

- **Für Analysen:** Aggregate, Joins und Window-Funktionen über Millionen
  Zeilen, Berichte, Dashboards, Datenexporte, Ad-hoc-Auswertungen,
  Parquet/CSV-Dateien und als schnelle, schreibgeschützte Kopie einer
  OLTP-Datenbank.
- **SQLite3 oder PostgreSQL für OLTP behalten:** Zugriffe per Schlüssel,
  einzelne Inserts und Updates, viele gleichzeitige Schreiber. Jedes
  DuckDB-Statement hat Fixkosten von einigen hundert Mikrosekunden (`p1`, `p2`),
  SQLite3 braucht wenige Mikrosekunden.
- **Beides kombinieren:** das mORMot-ORM auf SQLite3 oder PostgreSQL lassen und
  die Auswertungen mit DuckDB `ATTACH` auf denselben Daten ausführen
  (`duckdb-sqlite`, `duckdb-postgres`), oder die Daten ab und zu in eine
  DuckDB-Datei oder nach Parquet kopieren.
