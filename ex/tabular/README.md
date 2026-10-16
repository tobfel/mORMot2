# mORMot 2 extension: CSV (RFC 4180) and XLSX over TDocVariant

Five units which use mORMot 2 features only (no third-party components):

| Unit | Folder | Content |
|---|---|---|
| `mormot.core.tabular.pas` | `src/core` | Abstract `TTabularDocument` base class: the complete TDocVariant conversion (header, types, empty cells, column detection), with template methods for reading/writing |
| `mormot.core.csv.pas` | `src/core` | `TCsvDocument`: RFC 4180 parser/writer |
| `mormot.core.xlsx.pas` | `src/core` | `TXlsxDocument`: XLSX reader/writer on the same base class |
| `mormot.db.tabular.pas` | `src/db` | Rows <-> mORMot SQL database (`TSqlDBConnectionProperties`): column type inference, CREATE TABLE, bulk insert, SELECT -> rows |
| `mormot.db.rad.tabular.pas` | `src/db` | Rows <-> `TDataSet`: virtual read-only dataset, copy into any editable dataset, dataset -> rows |

mORMot 2 building blocks in use: `TXmlParser` / `AddXmlEscape` (mormot.core.fmt) for XML, `TZipRead` / `TZipWrite` (mormot.core.zip), `TTextWriter`, `TDocVariantData`, `TDynArrayHashed` (shared strings de-duplication), `GetNumericVariantFromJson` (type detection), `TSynAnsiConvert` (code pages), `Iso8601` / `DateTimeToIso8601Text`.

> **Requirement:** the `TXmlParser` / `XmlToVariant` XML parser of `mormot.core.fmt` is recent in mORMot 2. Older mORMot 2 revisions without `TXmlParser` do not compile the XLSX unit - update mORMot 2 in that case.

## Installation

Copy the `mormot.core.*` units to `mORMot2/src/core/` and the `mormot.db.*` units to `mORMot2/src/db/`. Like all mORMot units, they include `{$I ..\mormot.defines.inc}` with a relative path. The CSV/XLSX units do not depend on the DB units; `mormot.db.rad.tabular` is the only unit depending on `DB.pas`.

## Data model (input/output = TDocVariant)

**Reading** always returns a TDocVariant array of rows:

- with `tboHeader`: `[{"Name":"Mueller","Amount":1.5}, ...]` - column names come from the first row; empty names become `Col3`, duplicates become `name_2`
- without `tboHeader`: `[["Name","Amount"],["Mueller",1.5], ...]`

**Writing** accepts:

- an array of objects -> columns = union of all field names in order of appearance (or explicitly via `Columns[]`, which then also acts as field selection/ordering)
- an array of arrays -> positional
- XLSX only: an object of arrays `{"Revenue":[...], "Costs":[...]}` -> several worksheets

## Options (shared, `TTabularOptions`)

| Option | Effect |
|---|---|
| `tboHeader` | first row = column names (default) |
| `tboSkipEmptyRows` | ignore empty rows (default) |
| `tboTrimValues` | trim leading/trailing spaces |
| `tboGuessTypes` | CSV: unquoted values -> integer/float/boolean following the JSON syntax. `"007"` and `007` stay text, 20-digit IDs too (no precision loss) |
| `tboEmptyAsNull` | empty cells -> `null`; in CSV, `""` stays an empty string so that `null`/`''` survive a round trip |
| `tboDateAsText` | XLSX date values as ISO 8601 text instead of `varDate` |

Plus: `DocOptions` (default `JSON_FAST_FLOAT`), `MaxRows`, `DecimalSeparator` (e.g. `','` for German Excel CSV), `Columns`.

## CSV example (Delphi 7 compatible)

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
    csv.Delimiter := #0;             // auto-detect (, ; TAB |)
    csv.DecimalSeparator := ',';     // "1,5" -> 1.5
    csv.LoadFromFile('export.csv', doc);  // UTF-8/UTF-16 BOM or ANSI (1252)
    rows := _Safe(doc);
    for i := 0 to rows^.Count - 1 do
      writeln(_Safe(rows^.Values[i])^.U['Name']);
    // write it back for German Excel
    csv.Delimiter := ';';
    csv.CsvOptions := [csoWriteBom, csoEscapeFormulas];
    csv.SaveToFile(doc, 'import.csv');
  finally
    csv.Free;
  end;
end;
```

One-liners: `CsvToVariant`, `CsvToJson`, `VariantToCsv`, `JsonToCsv`.

### CSV specifics

- Full RFC 4180: quotes, `""` escaping, line breaks inside fields, optional final line break; writes CRLF by default
- Tolerant when reading (lone LF/CR, text after a closing quote); `csoStrict` raises `ECsvException` with the line number on any RFC violation, including a differing field count
- The Excel hint line `sep=;` is recognized (`csoWriteSepLine` writes it)
- `Quoting`: `cqMinimal` (RFC, default), `cqAll`, `cqNonNumeric`
- `CodePage` when writing, e.g. `CP_WINANSI` for legacy systems
- `csoEscapeFormulas`: protection against CSV/formula injection (values starting with `= + - @` get a leading `'`)

## XLSX example

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
    x.SheetName := 'Data';                   // otherwise SheetIndex (default 0)
    x.LoadFromFile('input.xlsx', doc);       // numbers, booleans, dates typed
    x.LoadSheetsFromFile('input.xlsx', all); // {"Sheet1":[...],"Sheet2":[...]}

    x.XlsxOptions := [xoHeaderBold, xoFreezeHeader, xoAutoFilter, xoAutoWidth];
    x.SheetName := 'Export';
    x.SaveToFile(doc, 'output.xlsx');        // one sheet
    x.SaveToFile(all, 'all.xlsx');           // several sheets
  finally
    x.Free;
  end;
end;
```

One-liners: `XlsxToVariant`, `XlsxSheetsToVariant`, `XlsxToJson`, `VariantToXlsx`, `JsonToXlsx`.

### Reading XLSX

- Shared strings, inline strings, rich text runs (`rPh` phonetic runs are ignored), `_xHHHH_` escapes
- Numbers as Int64 or Double, booleans, error values as text (`#DIV/0!`), `t="d"` ISO dates
- Date detection via built-in (14-22, 45-47 ...) and custom number formats; the Excel 1900 leap year bug and the 1904 date system are handled
- Formulas: the cached value is read, formulas are not evaluated
- Gaps in rows/columns are filled; namespace prefixes (`x:`) and non-default paths from the relationships are resolved
- `GetSheetNames`, `GetSheets` (including the hidden flag)
- Protection: the unpacked size per part is limited to 256 MB (mORMot `UnZip`), and the XML parser handles no DTD/entities

### Writing XLSX

- Types: integer/float -> number, boolean -> `t="b"`, `varDate` -> serial number with a date or date/time format, text -> de-duplicated shared strings, nested DocVariants -> JSON text
- Sheet names are sanitized (`[]:*?/\`, max 31 characters, unique)

## Database: `mormot.db.tabular`

Moves the rows into any mORMot SQL connection (`TSqlDBConnectionProperties`: SQLite3, PostgreSQL, Oracle, MSSQL/ODBC, MySQL, Firebird, ZEOS, FireDAC ...) and back.

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
    csv.LoadFromFile('articles.csv', rows);
    // create the table (if missing) and insert all rows in one transaction
    n := TabularToSqlDB(props, 'articles', rows, [tsoCreateTable, tsoDeleteFirst]);
    // way back: any query -> XLSX (date columns become real Excel dates)
    FileFromString(VariantToXlsx(SqlDBToTabular(props,
      'select * from articles where price > ?', [10])), 'expensive.xlsx');
  finally
    csv.Free;
    props.Free;
  end;
end;
```

| Function | Purpose |
|---|---|
| `TabularToSqlDB(Props, Table, Rows, Options, BatchRows)` | insert rows, returns the count. Optionally creates the table and empties it first; always inside one transaction (rollback on error) |
| `SqlDBToTabular(Props, Sql, Params, MaxRows)` | SELECT -> TDocVariant rows (ready for CSV/XLSX) |
| `TabularSqlCreate(Props, Table, Rows)` | only the matching `CREATE TABLE`, in the SQL dialect of the connection (via `Props.SqlCreate`) |
| `TabularColumns(Rows)` | column layout from **all** rows: type, max length, null values, valid SQL name |

`TTabularSqlOptions`: `tsoCreateTable` (default), `tsoDeleteFirst`, `tsoIgnoreUnknownColumns`, `tsoNoTransaction`, `tsoNoBatch`, `tsoTextAsClob`.

Behavior:

- **Types:** integers and booleans -> `ftInt64`, up to 4 decimals -> `ftCurrency`, otherwise `ftDouble`, `varDate` -> `ftDate`, anything else or mixed columns -> `ftUtf8`. The text width is rounded up to 50/100/255/1000, above that CLOB/TEXT is used.
- **Column names:** `Art.Nr` -> `Art_Nr`, `1st` -> `_1st`, SQL keywords (`order`, `when`, `value` ...) get a trailing `_`. With an existing table, columns are matched by original or SQL name (case-insensitive) and converted to the column type of the table (`"42"` -> integer column). Unknown columns raise an error unless `tsoIgnoreUnknownColumns` is set.
- **Bulk insert** like the mORMot ORM (`BatchSend`): multi-VALUES INSERT via `Props.OnBatchInsert` (SQLite3, MySQL, MSSQL ...), PostgreSQL `INSERT ... VALUES (unnest(?::int8[]), ...)` with array binding, array DML for Oracle/FireDAC/ZEOS/IBX; otherwise, or with `tsoNoBatch`, one prepared INSERT per row.
- **Errors:** values which cannot be converted raise `ETabularSql` with the row number and column name; the whole transaction is rolled back.

## TDataSet: `mormot.db.rad.tabular`

```pascal
// 1. without copy, read-only (e.g. for a DBGrid)
DataSource1.DataSet := TTabularDataSet.Create(self, rows);

// 2. into an editable dataset (TClientDataSet, TFDMemTable, TBufDataset, kbmMemTable,
//    or a query/table on a real database table)
TabularFieldDefs(rows, ClientDataSet1.FieldDefs);  // only needed for an empty memory dataset
ClientDataSet1.CreateDataSet;
TabularAppendToDataSet(rows, ClientDataSet1, [tdoEmptyFirst]);

// 3. any dataset -> CSV/XLSX
FileFromString(VariantToXlsx(DataSetToTabular(Query1)), 'export.xlsx');
```

| Function/class | Purpose |
|---|---|
| `TTabularDataSet` | read-only `TDataSet` directly on top of the rows (based on `TDocVariantArrayDataSet`), but with field types and string lengths taken from **all** rows; pure boolean columns as `TBooleanField`, array rows as `Col1`, `Col2` ..., texts > 4000 characters as memo |
| `TabularFieldDefs(Rows, Defs, StringAsAnsi)` | fill `FieldDefs` matching the rows (before `CreateDataSet`) |
| `TabularAppendToDataSet(Rows, Dest, Options)` | Append/Post per row, fields matched by name, values converted to the respective `TField.DataType`; on error `Cancel` + `ETabularDataSet` with row and field |
| `DataSetToTabular(Source, MaxRows)` | all records -> rows (Int64, Double, Currency for BCD, Boolean, `varDate`, UTF-8 text, BLOB as Base64 with magic, like `DataSetToJson`); the position is restored |
| `TabularValueToField` / `FieldToTabularValue` | single value conversion |

`TTabularDataSetOptions`: `tdoIgnoreUnknownFields`, `tdoEmptyFirst`, `tdoKeepControls`.

`StringAsAnsi = true` creates text columns as `ftString`/`ftMemo` instead of `ftWideString`/`ftWideMemo` - for older Delphi 7 components which do not cope well with `TWideStringField`.

## Tests

Two console programs are located in this folder, using the test files in `fixtures/` (regenerated by `make_fixtures.py`, which requires `openpyxl`). The CSV fixtures are byte-exact (CRLF, ANSI): `fixtures/.gitattributes` disables any line ending conversion.

`tabulartests.dpr` - 62 checks for `mormot.core.tabular/csv/xlsx`:

- RFC 4180 samples, edge cases, strict mode, encodings (UTF-8 BOM, UTF-16, CP1252), Python `csv` output
- XLSX from openpyxl (types, dates, gaps, several/hidden sheets, 1904), a hand-made file (prefixes, inlineStr, rich text, escapes) and a file re-saved by LibreOffice
- generated XLSX files open correctly with openpyxl and LibreOffice Calc

`dbtests.dpr` - 37 checks without PostgreSQL (44 with a PostgreSQL 16 server): column inference, SQLite3 (in-memory, batch and per-row paths, existing table, type conversion, rollback on error, reserved names, CSV -> SQL -> XLSX), `TTabularDataSet` and an editable in-memory dataset (FPC `TBufDataset`, Delphi `TClientDataSet`) including round trip. Pass `server:port db user pass` to also run the PostgreSQL tests.

Verified results (exit code 0, no failed check):

| Compiler | Target | `tabulartests` | `dbtests` |
|---|---|---|---|
| Delphi 7 | Win32 | 62/62 | 37/37 |
| Delphi 13 | Win32 | 62/62 | 37/37 |
| Delphi 13 | Win64 | 62/62 | 37/37 |
| FPC 3.2.3 | Win64 | 62/62 | 37/37 |

Build with Delphi, e.g. for Win64 (the mORMot 2 source folders must be in the unit search path, and the `static` folder with the mORMot static binaries is required for the 32-bit targets):

```
dcc64 tabulartests.dpr -B -Q -R<mORMot2>\src -I<mORMot2>\src;<mORMot2>\src\core -U<mORMot2>\src\core;<mORMot2>\src\lib;<mORMot2>\src\db;... -E<out> -N<out>
```

With FPC, use `fpc -Mdelphi -B -O2` with the same unit paths (`-Fu`) and `-Fi<mORMot2>\src`. Then run `tabulartests <path-to>\fixtures` (default: `..\fixtures\` relative to the executable) and `dbtests`.

Typical timings (100,000 rows, 4-5 columns, in-memory):

| | Write | Read |
|---|---|---|
| CSV (5.9 MB) | 31-62 ms | 63-79 ms |
| XLSX (2.6 MB) | 390-720 ms | 156-220 ms |
| SQLite3 in-memory | 63-141 ms (batch) / 109-188 ms (per row) | 32-79 ms |

(range over Delphi 13 Win64 and FPC 3.2.3 Win64 on the same machine). A PostgreSQL 16 server on localhost needed ~270 ms with the `unnest` array binding and ~8,200 ms with one INSERT per row.

## Notes and limits

- **Delphi 7:** the code is written in Delphi 7 style (no generics, no `Exit(x)`, no inline variables, `object`-compatible mORMot records). It compiles and passes all tests with Delphi 7, Delphi 13 and FPC.
- **Unicode Delphi and byte literals:** the UTF-8 BOM is written as raw bytes (`FastSetRawByteString`), because a `#$ef#$bb#$bf` string literal would be UTF-8 encoded on Unicode Delphi. The test sources are pure ASCII (`\uXXXX` JSON escapes, `HexToBin()` for byte-exact comparisons) for the same reason.
- Floating point numbers are written with mORMot `DoubleToStr` (15 significant digits), i.e. like mORMot JSON, not with the full 17 digits.
- LibreOffice displays dates before 1900-03-01 one day off (it does not reproduce the Excel leap year bug); Excel displays them correctly.
- Not included: cell formatting beyond the bold header row and date formats, merged cells (only the top-left cell holds the value), streaming for files larger than RAM.
- An instance is not thread-safe, but can be reused for several Load/Save calls.
- `TDocVariantArrayDataSet.GetRowFieldData` (mORMot, `mormot.db.rad.ui.pas`) reads `dv^.Names[f]` without checking `f < dv^.Count` - an out-of-bounds access for rows with missing fields. `TTabularDataSet` therefore normalizes the rows first (all columns in the same order); when using `DocVariantToDataSet` directly with uneven rows, the risk remains. Fixed in the separate branches `fix/docvariantarraydataset-field-bounds` (out-of-bounds `Names[]` read, commit `7e71b67`) and `fix/docvariantarraydataset` (additionally fixes the incomplete Int64/Float column check of the constructor, commit `d72e12d`) of `tobfel/mORMot2`.
- PostgreSQL creates the (unquoted) column names in lower case: `Art.Nr` becomes `art_nr`, and `SqlDBToTabular` returns them that way.
- Rows which should end up as a date in an `ftDate` column must be `varDate` or ISO 8601 text; `31.01.2024` is rejected.
