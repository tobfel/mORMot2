# mORMot2-Erweiterung: CSV (RFC 4180) und XLSX über TDocVariant

Fünf Units, die ausschließlich mORMot2-Funktionen nutzen (keine Fremdkomponenten):

| Unit | Ordner | Inhalt |
|---|---|---|
| `mormot.core.tabular.pas` | `src/core` | Abstrakte Basisklasse `TTabularDocument`: komplette TDocVariant-Konvertierung (Header, Typen, Leerzellen, Spaltenermittlung), Template-Methoden für Lesen/Schreiben |
| `mormot.core.csv.pas` | `src/core` | `TCsvDocument`: RFC-4180-Parser/Writer |
| `mormot.core.xlsx.pas` | `src/core` | `TXlsxDocument`: XLSX-Reader/Writer auf derselben Basis |
| `mormot.db.tabular.pas` | `src/db` | Zeilen ↔ mORMot-SQL-Datenbank (`TSqlDBConnectionProperties`): Spaltentypen ermitteln, CREATE TABLE, Bulk-Insert, SELECT → Zeilen |
| `mormot.db.rad.tabular.pas` | `src/db` | Zeilen ↔ `TDataSet`: virtuelles Read-only-DataSet, Kopieren in beliebige editierbare DataSets, DataSet → Zeilen |

Verwendete mORMot2-Bausteine: `TXmlParser` / `AddXmlEscape` (mormot.core.fmt) für XML, `TZipRead` / `TZipWrite` (mormot.core.zip), `TTextWriter`, `TDocVariantData`, `TDynArrayHashed` (Shared-Strings-Deduplizierung), `GetNumericVariantFromJson` (Typerkennung), `TSynAnsiConvert` (Codepages), `Iso8601`/`DateTimeToIso8601Text`.

> **Voraussetzung:** Der XML-Parser `TXmlParser`/`XmlToVariant` in `mormot.core.fmt` ist neu in mORMot2. Getestet gegen den aktuellen Commit `b9bdb62` (10.10.2026). Ältere mORMot2-Stände ohne `TXmlParser` kompilieren das XLSX-Unit nicht – dann mORMot2 aktualisieren.

## Installation

Die `mormot.core.*` nach `mORMot2/src/core/`, die `mormot.db.*` nach `mORMot2/src/db/` kopieren (alternativ alle in einen eigenen Ordner direkt unter `mORMot2/src/`, z. B. `src/ext/`). Die Units binden wie alle mORMot-Units `{$I ..\mormot.defines.inc}` relativ ein. Die CSV-/XLSX-Units hängen nicht von den DB-Units ab; `mormot.db.rad.tabular` ist die einzige Unit mit Abhängigkeit zu `DB.pas`.

## Datenmodell (Input/Output = TDocVariant)

**Lesen** liefert immer ein TDocVariant-Array von Zeilen:

- mit `tboHeader`: `[{"Name":"Müller","Betrag":1.5}, ...]` – Spaltennamen aus der ersten Zeile; leere Namen werden zu `Col3`, doppelte zu `name_2`
- ohne `tboHeader`: `[["Name","Betrag"],["Müller",1.5], ...]`

**Schreiben** akzeptiert:

- Array von Objekten → Spalten = Vereinigung aller Feldnamen in Reihenfolge des Auftretens (oder explizit über `Columns[]`, dann auch als Feldauswahl/Reihenfolge)
- Array von Arrays → positionsweise
- nur XLSX: Objekt von Arrays `{"Umsatz":[...], "Kosten":[...]}` → mehrere Tabellenblätter

## Optionen (gemeinsam, `TTabularOptions`)

| Option | Wirkung |
|---|---|
| `tboHeader` | erste Zeile = Spaltennamen (Default) |
| `tboSkipEmptyRows` | leere Zeilen ignorieren (Default) |
| `tboTrimValues` | Leerzeichen am Rand entfernen |
| `tboGuessTypes` | CSV: unquotierte Werte → Integer/Float/Boolean nach JSON-Syntax. `"007"` und `007` bleiben Text, 20-stellige IDs ebenfalls (kein Präzisionsverlust) |
| `tboEmptyAsNull` | leere Zellen → `null`; im CSV bleibt `""` ein leerer String, damit `null`/`''` den Roundtrip überleben |
| `tboDateAsText` | XLSX-Datumswerte als ISO-8601-Text statt `varDate` |

Dazu: `DocOptions` (Default `JSON_FAST_FLOAT`), `MaxRows`, `DecimalSeparator` (z. B. `','` für deutsche Excel-CSV), `Columns`.

## CSV-Beispiel (Delphi 7 kompatibel)

```pascal
uses
  mormot.core.base, mormot.core.os, mormot.core.variants,
  mormot.core.tabular, mormot.core.csv;

var
  csv: TCsvDocument;
  doc: variant;
  rows: PDocVariantData;
  i: integer;
begin
  csv := TCsvDocument.Create([tboHeader, tboGuessTypes, tboSkipEmptyRows]);
  try
    csv.Delimiter := #0;             // automatisch erkennen (, ; TAB |)
    csv.DecimalSeparator := ',';     // "1,5" -> 1.5
    csv.LoadFromFile('export.csv', doc);  // UTF-8/UTF-16-BOM oder ANSI (1252)
    rows := _Safe(doc);
    for i := 0 to rows^.Count - 1 do
      writeln(_Safe(rows^.Values[i])^.U['Name']);
    // zurückschreiben für Excel DE
    csv.Delimiter := ';';
    csv.CsvOptions := [csoWriteBom, csoEscapeFormulas];
    csv.SaveToFile(doc, 'import.csv');
  finally
    csv.Free;
  end;
end;
```

Einzeiler: `CsvToVariant`, `CsvToJson`, `VariantToCsv`, `JsonToCsv`.

### CSV-spezifisch

- RFC 4180 vollständig: Quotes, `""`-Escaping, Zeilenumbrüche in Feldern, optionaler letzter Zeilenumbruch; schreibt standardmäßig CRLF
- tolerant beim Lesen (LF/CR allein, Text nach schließendem Quote); `csoStrict` wirft `ECsvException` mit Zeilennummer bei jeder RFC-Verletzung inkl. abweichender Feldanzahl
- Excel-Hinweiszeile `sep=;` wird erkannt (`csoWriteSepLine` schreibt sie)
- `Quoting`: `cqMinimal` (RFC, Default), `cqAll`, `cqNonNumeric`
- `CodePage` beim Schreiben, z. B. `CP_WINANSI` für Altsysteme
- `csoEscapeFormulas`: Schutz vor CSV-/Formel-Injection (Werte mit `= + - @` bekommen ein `'` vorangestellt)

## XLSX-Beispiel

```pascal
uses
  mormot.core.base, mormot.core.os, mormot.core.variants,
  mormot.core.tabular, mormot.core.xlsx;

var
  x: TXlsxDocument;
  doc, all: variant;
begin
  x := TXlsxDocument.Create([tboHeader, tboEmptyAsNull]);
  try
    x.SheetName := 'Daten';                  // sonst SheetIndex (Default 0)
    x.LoadFromFile('eingang.xlsx', doc);     // Zahlen, Bool, Datum typisiert
    x.LoadSheetsFromFile('eingang.xlsx', all); // {"Blatt1":[...],"Blatt2":[...]}

    x.XlsxOptions := [xoHeaderBold, xoFreezeHeader, xoAutoFilter, xoAutoWidth];
    x.SheetName := 'Export';
    x.SaveToFile(doc, 'ausgang.xlsx');       // ein Blatt
    x.SaveToFile(all, 'alle.xlsx');          // mehrere Blätter
  finally
    x.Free;
  end;
end;
```

Einzeiler: `XlsxToVariant`, `XlsxSheetsToVariant`, `XlsxToJson`, `VariantToXlsx`, `JsonToXlsx`.

### XLSX lesen

- Shared Strings, Inline Strings, Rich-Text-Runs (Phonetik `rPh` wird ignoriert), `_xHHHH_`-Escapes
- Zahlen als Int64 bzw. Double, Booleans, Fehlerwerte als Text (`#DIV/0!`), `t="d"` ISO-Datum
- Datumserkennung über eingebaute (14–22, 45–47 …) und eigene Zahlenformate; 1900-Schaltjahrfehler von Excel und 1904-Datumssystem berücksichtigt
- Formeln: es wird der zwischengespeicherte Wert gelesen, Formeln werden nicht berechnet
- Lücken in Zeilen/Spalten werden aufgefüllt; Namespace-Präfixe (`x:`) und abweichende Pfade aus den Relationships werden aufgelöst
- `GetSheetNames`, `GetSheets` (inkl. Hidden-Flag)
- Schutz: Entpackgröße pro Teil ist auf 256 MB begrenzt (mORMot `UnZip`), der XML-Parser verarbeitet keine DTD/Entities

### XLSX schreiben

- Typen: Integer/Float → Zahl, Boolean → `t="b"`, `varDate` → Seriennummer mit Datums- bzw. Datum/Zeit-Format, Text → deduplizierte Shared Strings, verschachtelte DocVariants → JSON-Text
- Blattnamen werden bereinigt (`[]:*?/\`, max. 31 Zeichen, eindeutig)

## Datenbank: `mormot.db.tabular`

Überführt die Zeilen in eine beliebige mORMot-SQL-Verbindung (`TSqlDBConnectionProperties`: SQLite3, PostgreSQL, Oracle, MSSQL/ODBC, MySQL, Firebird, ZEOS, FireDAC …) und zurück.

```pascal
uses
  mormot.core.base, mormot.core.os, mormot.core.variants,
  mormot.core.tabular, mormot.core.csv, mormot.core.xlsx,
  mormot.db.sql, mormot.db.sql.postgres, mormot.db.tabular;

var
  props: TSqlDBPostgresConnectionProperties;
  csv: TCsvDocument;
  rows: variant;
  n: integer;
begin
  props := TSqlDBPostgresConnectionProperties.Create('localhost:5432', 'db', 'user', 'pass');
  csv := TCsvDocument.CreateDelimiter(';', [tboHeader, tboGuessTypes]);
  try
    csv.DecimalSeparator := ',';
    csv.LoadFromFile('artikel.csv', rows);
    // Tabelle anlegen (falls nicht vorhanden) und alle Zeilen in einer Transaktion einfügen
    n := TabularToSqlDB(props, 'artikel', rows, [tsoCreateTable, tsoDeleteFirst]);
    // Rückweg: beliebige Abfrage -> XLSX (Datumsspalten werden echte Excel-Datumswerte)
    FileFromString(VariantToXlsx(SqlDBToTabular(props,
      'select * from artikel where preis > ?', [10])), 'teuer.xlsx');
  finally
    csv.Free;
    props.Free;
  end;
end;
```

| Funktion | Zweck |
|---|---|
| `TabularToSqlDB(Props, Table, Rows, Options, BatchRows)` | Zeilen einfügen, liefert Anzahl. Optional Tabelle anlegen, vorher leeren; immer in einer Transaktion (Rollback bei Fehler) |
| `SqlDBToTabular(Props, Sql, Params, MaxRows)` | SELECT → TDocVariant-Zeilen (bereit für CSV/XLSX) |
| `TabularSqlCreate(Props, Table, Rows)` | nur das passende `CREATE TABLE` im SQL-Dialekt der Verbindung (via `Props.SqlCreate`) |
| `TabularColumns(Rows)` | Spaltenlayout aus **allen** Zeilen: Typ, max. Länge, Null-Werte, gültiger SQL-Name |

Optionen `TTabularSqlOptions`: `tsoCreateTable` (Default), `tsoDeleteFirst`, `tsoIgnoreUnknownColumns`, `tsoNoTransaction`, `tsoNoBatch`, `tsoTextAsClob`.

Verhalten:

- **Typen:** Ganzzahlen und Booleans → `ftInt64`, bis 4 Nachkommastellen → `ftCurrency`, sonst `ftDouble`, `varDate` → `ftDate`, alles andere bzw. gemischte Spalten → `ftUtf8`. Textbreite wird auf 50/100/255/1000 aufgerundet, darüber CLOB/TEXT.
- **Spaltennamen:** `Art.Nr` → `Art_Nr`, `1st` → `_1st`, SQL-Schlüsselwörter (`order`, `when`, `value` …) bekommen ein `_` angehängt. Bei bestehender Tabelle wird per Original- oder SQL-Namen zugeordnet (Groß-/Kleinschreibung egal) und in den Spaltentyp der Tabelle konvertiert (`"42"` → Integer-Spalte). Unbekannte Spalten lösen einen Fehler aus, außer mit `tsoIgnoreUnknownColumns`.
- **Bulk-Insert** wie im mORMot-ORM (`BatchSend`): Multi-VALUES-INSERT über `Props.OnBatchInsert` (SQLite3, MySQL, MSSQL …), PostgreSQL `INSERT … VALUES (unnest(?::int8[]), …)` mit Array-Binding, Array-DML für Oracle/FireDAC/ZEOS/IBX; sonst bzw. mit `tsoNoBatch` ein vorbereitetes INSERT pro Zeile.
- **Fehler:** Nicht konvertierbare Werte lösen `ETabularSql` mit Zeilennummer und Spaltenname aus; die gesamte Transaktion wird zurückgerollt.

## TDataSet: `mormot.db.rad.tabular`

```pascal
// 1. ohne Kopie, read-only (z. B. für ein DBGrid)
DataSource1.DataSet := TTabularDataSet.Create(self, rows);

// 2. in ein editierbares DataSet (TClientDataSet, TFDMemTable, TBufDataset, kbmMemTable,
//    oder eine Query/Table auf einer echten DB-Tabelle)
TabularFieldDefs(rows, ClientDataSet1.FieldDefs);  // nur bei leerem Memory-DataSet nötig
ClientDataSet1.CreateDataSet;
TabularAppendToDataSet(rows, ClientDataSet1, [tdoEmptyFirst]);

// 3. beliebiges DataSet -> CSV/XLSX
FileFromString(VariantToXlsx(DataSetToTabular(Query1)), 'export.xlsx');
```

| Funktion/Klasse | Zweck |
|---|---|
| `TTabularDataSet` | Read-only `TDataSet` direkt über den Zeilen (Basis `TDocVariantArrayDataSet`), aber Feldtypen und Stringlängen aus **allen** Zeilen; reine Boolean-Spalten als `TBooleanField`, Array-Zeilen als `Col1`, `Col2` …, Texte > 4000 Zeichen als Memo |
| `TabularFieldDefs(Rows, Defs, StringAsAnsi)` | `FieldDefs` passend zu den Zeilen füllen (vor `CreateDataSet`) |
| `TabularAppendToDataSet(Rows, Dest, Options)` | Append/Post je Zeile, Felder per Name zugeordnet, Werte in den jeweiligen `TField.DataType` konvertiert; bei Fehler `Cancel` + `ETabularDataSet` mit Zeile und Feld |
| `DataSetToTabular(Source, MaxRows)` | alle Datensätze → Zeilen (Int64, Double, Currency für BCD, Boolean, `varDate`, UTF-8-Text, BLOB als Base64); Position wird wiederhergestellt |
| `TabularValueToField` / `FieldToTabularValue` | Einzelwert-Konvertierung |

Optionen `TTabularDataSetOptions`: `tdoIgnoreUnknownFields`, `tdoEmptyFirst`, `tdoKeepControls`.

`StringAsAnsi = true` legt Textspalten als `ftString`/`ftMemo` statt `ftWideString`/`ftWideMemo` an – für ältere Delphi-7-Komponenten, die mit `TWideStringField` nicht gut umgehen.

## Tests

`test/tabulartests.dpr` – 62 Prüfungen, kompiliert und getestet mit FPC 3.2.2 (Linux x64) gegen mORMot2 `b9bdb62`:

- RFC-4180-Beispiele, Kantenfälle, Strict-Modus, Encodings (UTF-8-BOM, UTF-16, CP1252), Python-`csv`-Ausgabe
- XLSX von openpyxl (Typen, Datum, Lücken, mehrere/versteckte Blätter, 1904), handgebaute Datei (Präfixe, inlineStr, Rich Text, Escapes) und eine von LibreOffice neu gespeicherte Datei
- erzeugte XLSX werden von openpyxl und LibreOffice Calc korrekt geöffnet
- keine Speicherlecks (heaptrc)

`test/dbtests.dpr` – 44 Prüfungen: Spaltenermittlung, SQLite3 (in-memory) und PostgreSQL 16 (Batch- und Einzelzeilen-Pfad, bestehende Tabelle, Typkonvertierung, Rollback bei Fehler, reservierte Namen, CSV → SQL → XLSX), `TTabularDataSet` und FPC-`TBufDataset` (unter Delphi `TClientDataSet`) inkl. Roundtrip; ebenfalls ohne Speicherlecks.

Performance (100 000 Zeilen, 4–5 Spalten):

| | Schreiben | Lesen |
|---|---|---|
| CSV (5,9 MB) | ~60 ms | ~80 ms |
| XLSX (2,6 MB) | ~420 ms | ~150 ms |
| SQLite3 in-memory | ~150 ms (Batch) / ~200 ms (pro Zeile) | ~100 ms |
| PostgreSQL 16 lokal | ~270 ms (`unnest`-Array-Binding) / ~8 200 ms (pro Zeile) | |

Ausführen: `test/make_fixtures.py` erzeugt die Testdateien (benötigt `openpyxl`), `test/build.sh tabulartests.dpr` baut mit FPC. Die DB-Tests: `test/build.sh -dNOSQLITE3STATIC -dNOASMBLOCK dbtests.dpr`, dann `out/dbtests [server:port db user pass]` – ohne Parameter wird PostgreSQL übersprungen. (`NOASMBLOCK`/`NOSQLITE3STATIC` nur, weil in der Testumgebung die mORMot-`static`-Dateien fehlten.)

## Hinweise und Grenzen

- **Delphi 7:** Der Code ist im Delphi-7-Stil geschrieben (keine Generics, kein `Exit(x)`, keine Inline-Variablen, `object`-kompatible mORMot-Records). Hier wurde nur mit FPC kompiliert, ein Delphi-7-/13.1-Lauf steht noch aus.
- Fließkommazahlen werden mit mORMot-`DoubleToStr` (15 signifikante Stellen) geschrieben, also wie in mORMot-JSON, nicht mit den vollen 17 Stellen.
- LibreOffice zeigt Datumswerte vor dem 01.03.1900 einen Tag versetzt an (es bildet den Excel-Schaltjahrfehler nicht nach); Excel zeigt sie korrekt.
- Nicht enthalten: Zellformatierung über Fett-Kopfzeile/Datumsformat hinaus, verbundene Zellen (nur die linke obere Zelle trägt den Wert), Streaming für Dateien > RAM.
- Eine Instanz ist nicht threadsicher, kann aber für mehrere Load/Save-Aufrufe wiederverwendet werden.
- `TDocVariantArrayDataSet.GetRowFieldData` (mORMot, `mormot.db.rad.ui.pas` Zeile 947) liest `dv^.Names[f]` ohne Prüfung `f < dv^.Count` – bei Zeilen mit fehlenden Feldern ein Zugriff außerhalb des Arrays. `TTabularDataSet` normalisiert die Zeilen deshalb vorher (alle Spalten in gleicher Reihenfolge); bei direkter Nutzung von `DocVariantToDataSet` mit ungleichmäßigen Zeilen bleibt das Risiko bestehen. Fix: Branch `fix/docvariantarraydataset` in `tobfel/mORMot2` (Commits `7e71b67` und `d72e12d`, letzterer behebt zusätzlich die unvollständige Int64/Float-Spaltenprüfung im Konstruktor).
- PostgreSQL legt die (nicht gequoteten) Spaltennamen kleingeschrieben an: `Art.Nr` wird zu `art_nr`, und so liefert `SqlDBToTabular` sie auch zurück.
- Zeilen, die als Datum in eine `ftDate`-Spalte sollen, müssen `varDate` oder ISO-8601-Text sein; `31.01.2024` wird abgelehnt.
