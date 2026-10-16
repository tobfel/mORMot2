/// Tabular TDocVariant Rows Import/Export via mORMot SQL Database Access
// - extension unit for the mORMot 2 Open Source framework
// - licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.db.tabular;

{
  *****************************************************************************

   Bridge between TTabularDocument rows (CSV/XLSX) and mormot.db.sql
    - Column Layout Inference from TDocVariant Rows
    - Import Rows into a TSqlDBConnectionProperties Table
    - Export a SQL Query into TDocVariant Rows

   Typical use:
   ! rows := CsvToVariant(StringFromFile('kunden.csv'), [tboHeader, tboGuessTypes], ';');
   ! TabularToSqlDB(Props, 'kunden', rows, [tsoCreateTable]);
   ! ...
   ! FileFromString(VariantToXlsx(SqlDBToTabular(Props, 'select * from kunden', [])),
   !   'kunden.xlsx');

   Bulk insertion follows the mORMot ORM BatchSend() logic:
    - multi-VALUES INSERT via Props.OnBatchInsert (SQLite3, MySQL, MSSQL...)
    - PostgreSQL 'INSERT .. VALUES (unnest(?::type[]),..)' array binding
    - Oracle/FireDAC/ZEOS/IBX array DML binding
    - otherwise (or with tsoNoBatch) one prepared INSERT per row
   always within a single transaction by default

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.tabular,
  mormot.db.core,
  mormot.db.sql;


{ ************ Column Layout Inference from TDocVariant Rows }

type
  /// the column layout inferred from some TDocVariant rows
  TTabularColumn = record
    /// the field name in the TDocVariant object rows, or 'Col#' for array rows
    Name: RawUtf8;
    /// a valid SQL identifier computed from Name (only A-Z a-z 0-9 _ chars)
    SqlName: RawUtf8;
    /// the merged type of all non-null values of this column
    // - ftInt64 for integers and booleans, ftCurrency for up to 4 decimals,
    // ftDouble for other floats, ftDate for varDate, ftUtf8 for anything else
    // (including mixed types or nested TDocVariant stored as JSON)
    // - ftUtf8 if the column has only null/void values
    FieldType: TSqlDBFieldType;
    /// the maximum number of UTF-16 chars of the ftUtf8 values
    MaxLength: integer;
    /// true if at least one row has a null/void/missing value in this column
    HasNull: boolean;
  end;
  PTabularColumn = ^TTabularColumn;

  /// the column layout inferred from some TDocVariant rows
  TTabularColumns = array of TTabularColumn;

/// compute the column layout of some TDocVariant rows
// - rows may be objects (union of all field names, in order of appearance)
// or arrays (named 'Col1', 'Col2'...)
// - all rows are scanned to merge the types, e.g. 1 and 2.5 give ftDouble,
// 1 and 'abc' give ftUtf8
function TabularColumns(const Rows: TDocVariantData): TTabularColumns; overload;

/// compute the column layout of a TDocVariant array of rows
function TabularColumns(const Rows: variant): TTabularColumns; overload;

/// make a valid SQL identifier from any text
// - non A-Z a-z 0-9 _ chars (including accents) are replaced by '_', and
// a '_' is prepended if the name starts with a digit or is void
function TabularSqlName(const Name: RawUtf8): RawUtf8;

/// return a pointer to the cell of a given row matching a column
// - Row may be an object (lookup by Column^.Name) or an array (by ColIndex)
// - returns nil if the cell does not exist
function TabularCell(const Row: TDocVariantData; Column: PTabularColumn;
  ColIndex: integer): PVariant;

/// convert a cell value into the SQL text expected by TSqlDBStatement.Bind()
// - i.e. number, 'quoted string', 'YYYY-MM-DDThh:mm:ss' or null
// - returns false if the value can't be converted to the expected FieldType,
// e.g. 'abc' text into a ftInt64 column
function TabularValueToSql(const Value: variant; FieldType: TSqlDBFieldType;
  var Sql: RawUtf8): boolean;


{ ************ Import Rows into a TSqlDBConnectionProperties Table }

type
  /// options for TabularToSqlDB()
  // - tsoCreateTable: create the table (from TabularColumns) if it does not exist
  // - tsoDeleteFirst: execute 'DELETE FROM table' before inserting the rows
  // - tsoIgnoreUnknownColumns: when the table already exists, ignore the row
  // columns not found in the table - default is to raise an exception
  // - tsoNoTransaction: don't wrap the process in a transaction, e.g. if the
  // caller manages its own transaction on Props.ThreadSafeConnection
  // - tsoNoBatch: force one prepared INSERT per row, even if the database
  // supports multi-VALUES INSERT via Props.OnBatchInsert
  // - tsoTextAsClob: create ftUtf8 columns with no maximum length (CLOB/TEXT)
  TTabularSqlOption = (
    tsoCreateTable,
    tsoDeleteFirst,
    tsoIgnoreUnknownColumns,
    tsoNoTransaction,
    tsoNoBatch,
    tsoTextAsClob);

  /// set of options for TabularToSqlDB()
  TTabularSqlOptions = set of TTabularSqlOption;

  /// exception raised by TabularToSqlDB()
  ETabularSql = class(ETabularException);

/// insert TDocVariant rows (e.g. from CSV/XLSX) into a SQL table
// - Rows is a TDocVariant array of objects (or arrays, named 'Col1'...)
// - if the table exists, row fields are matched by name (case-insensitive)
// against the table columns, and values are converted to the column types
// - with tsoCreateTable, a missing table is created with the column types
// and widths inferred by TabularColumns()
// - BatchRows is the number of rows sent per multi-VALUES INSERT statement
// (mORMot may split it further following the DBMS parameters limit)
// - returns the number of inserted rows
// - raise an ETabularSql (or a database exception) on error, after rollback
function TabularToSqlDB(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Rows: variant;
  Options: TTabularSqlOptions = [tsoCreateTable];
  BatchRows: integer = 1000): integer; overload;

/// insert TDocVariantData rows (e.g. from CSV/XLSX) into a SQL table
function TabularToSqlDB(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Rows: TDocVariantData;
  Options: TTabularSqlOptions = [tsoCreateTable];
  BatchRows: integer = 1000): integer; overload;

/// compute the CREATE TABLE statement matching some TDocVariant rows
// - using the Props SQL dialect (via Props.SqlCreate), with the column names
// sanitized by TabularSqlName() and suffixed by '_' for SQL reserved words
function TabularSqlCreate(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Rows: TDocVariantData;
  TextAsClob: boolean = false): RawUtf8;


{ ************ Export a SQL Query into TDocVariant Rows }

/// execute a SQL query and return its rows as a TDocVariant array of objects
// - ready to be serialized by TCsvDocument/TXlsxDocument.Save()
// - date/time columns are returned as varDate, so are written as XLSX dates
function SqlDBToTabular(Props: TSqlDBConnectionProperties; const Sql: RawUtf8;
  const Params: array of const; MaxRows: cardinal = 0): variant;


implementation


{ ************ Column Layout Inference from TDocVariant Rows }

function FindRawUtf8Sql(const Cols: TTabularColumns; const Name: RawUtf8;
  Count: integer): integer;
begin
  for result := 0 to Count - 1 do
    if IdemPropNameU(Cols[result].SqlName, Name) then
      exit;
  result := -1;
end;

function TabularSqlName(const Name: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  result := Name;
  for i := 1 to length(result) do
    if not (result[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
    begin
      UniqueRawUtf8(result);
      result[i] := '_';
    end;
  if (result = '') or
     (result[1] in ['0'..'9']) then
    result := '_' + result;
end;

function TabularCell(const Row: TDocVariantData; Column: PTabularColumn;
  ColIndex: integer): PVariant;
var
  ndx: integer;
begin
  result := nil;
  if Row.IsObject then
  begin
    if (ColIndex < Row.Count) and
       (Row.Names[ColIndex] = Column^.Name) then
      ndx := ColIndex // fast path for rows with the same field order
    else
      ndx := Row.GetValueIndex(Column^.Name);
    if ndx >= 0 then
      result := @Row.Values[ndx];
  end
  else if Row.IsArray and
          (ColIndex < Row.Count) then
    result := @Row.Values[ColIndex];
end;

const
  NUMRANK: array[TSqlDBFieldType] of byte = (0, 0, 1, 3, 2, 0, 0, 0);

// merge the type of one value into the column type
procedure MergeType(Col: PTabularColumn; const Value: variant);
var
  vd: PVarData;
  t: TSqlDBFieldType;
  L: integer;
  s: RawUtf8;
  istext: boolean;
begin
  vd := @Value;
  while vd^.VType = varVariantByRef do
    vd := vd^.VPointer;
  case vd^.VType of
    varEmpty,
    varNull:
      begin
        Col^.HasNull := true;
        exit;
      end;
    varBoolean, varSmallint, varInteger, varShortInt, varByte, varWord,
    varLongWord, varInt64, varWord64:
      t := ftInt64;
    varCurrency:
      t := ftCurrency;
    varSingle,
    varDouble:
      t := ftDouble;
    varDate:
      t := ftDate;
  else
    begin
      t := ftUtf8;
      TabularValueToText(PVariant(vd)^, s, istext);
      if s = '' then
        Col^.HasNull := true; // a void string is stored as null by some DB
      L := Utf8ToUnicodeLength(pointer(s));
      if L > Col^.MaxLength then
        Col^.MaxLength := L;
    end;
  end;
  if Col^.FieldType = ftUnknown then
    Col^.FieldType := t
  else if Col^.FieldType <> t then
    if (Col^.FieldType in [ftInt64, ftCurrency, ftDouble]) and
       (t in [ftInt64, ftCurrency, ftDouble]) then
    begin
      // numbers: Int64 < Currency < Double
      if NUMRANK[t] > NUMRANK[Col^.FieldType] then
        Col^.FieldType := t;
    end
    else
      Col^.FieldType := ftUtf8; // mixed types are stored as text
  if (Col^.FieldType = ftUtf8) and
     (t <> ftUtf8) then
  begin
    // e.g. a number in a text column: include its text length
    TabularValueToText(PVariant(vd)^, s, istext);
    L := length(s);
    if L > Col^.MaxLength then
      Col^.MaxLength := L;
  end;
end;

function TabularColumns(const Rows: TDocVariantData): TTabularColumns;
var
  r, i, n, ndx: PtrInt;
  row: PDocVariantData;
  col: PTabularColumn;
  name: RawUtf8;
begin
  result := nil;
  n := 0;
  for r := 0 to Rows.Count - 1 do
    if _Safe(Rows.Values[r], row) then
      if row^.IsObject then
        for i := 0 to row^.Count - 1 do
        begin
          // locate (or add) the column - fast path for same field order
          if (i < n) and
             (result[i].Name = row^.Names[i]) then
            ndx := i
          else
          begin
            ndx := n - 1;
            while (ndx >= 0) and
                  not IdemPropNameU(result[ndx].Name, row^.Names[i]) do
              dec(ndx);
          end;
          if ndx < 0 then
          begin
            if n = length(result) then
              SetLength(result, NextGrow(n));
            ndx := n;
            result[ndx].Name := row^.Names[i];
            result[ndx].HasNull := r > 0; // previous rows did not have it
            inc(n);
          end;
          MergeType(@result[ndx], row^.Values[i]);
        end
      else
        for i := 0 to row^.Count - 1 do
        begin
          if i >= n then
          begin
            if n = length(result) then
              SetLength(result, NextGrow(n));
            result[n].Name := Make(['Col', n + 1]);
            result[n].HasNull := r > 0;
            inc(n);
          end;
          MergeType(@result[i], row^.Values[i]);
        end;
  SetLength(result, n);
  // detect missing fields in later rows, finalize types and SQL names
  for i := 0 to n - 1 do
  begin
    col := @result[i];
    if not col^.HasNull then
      for r := 0 to Rows.Count - 1 do
        if not _Safe(Rows.Values[r], row) or
           (TabularCell(row^, col, i) = nil) then
        begin
          col^.HasNull := true;
          break;
        end;
    if col^.FieldType = ftUnknown then
      col^.FieldType := ftUtf8; // only null values
    name := TabularSqlName(col^.Name);
    ndx := 2;
    col^.SqlName := name;
    while (i > 0) and
          (FindRawUtf8Sql(result, col^.SqlName, i) >= 0) do
    begin
      col^.SqlName := Make([name, '_', ndx]);
      inc(ndx);
    end;
  end;
end;

function TabularColumns(const Rows: variant): TTabularColumns;
var
  dv: PDocVariantData;
begin
  if _SafeArray(Rows, dv) then
    result := TabularColumns(dv^)
  else
    result := nil;
end;

function TabularValueToSql(const Value: variant; FieldType: TSqlDBFieldType;
  var Sql: RawUtf8): boolean;
var
  conv: TTabularConversion;
  i64: Int64;
  d: double;
  dt: TDateTime;
  istext: boolean;
begin
  case FieldType of
    ftInt64:
      begin
        conv := TabularToInt64(Value, i64);
        if conv = tcValue then
          Int64ToUtf8(i64, Sql);
      end;
    ftDouble,
    ftCurrency:
      begin
        conv := TabularToDouble(Value, d);
        if conv = tcValue then
          DoubleToStr(d, Sql);
      end;
    ftDate:
      begin
        conv := TabularToDateTime(Value, dt);
        if conv = tcValue then
          Sql := QuotedStr(DateTimeToIso8601Text(dt), '''');
      end;
  else
    if VarIsEmptyOrNull(Value) then
      conv := tcNull
    else
    begin
      // ftBlob as raw binary, ftUtf8 with nested TDocVariant as JSON
      conv := tcValue;
      TabularValueToText(Value, Sql, istext);
      if FieldType <> ftBlob then
        Sql := QuotedStr(Sql, '''');
    end;
  end;
  if conv = tcNull then
    Sql := 'null';
  result := conv <> tcInvalid;
end;


{ ************ Import Rows into a TSqlDBConnectionProperties Table }

// add a '_' suffix to SQL reserved words, and ensure still unique
procedure FixReservedNames(Props: TSqlDBConnectionProperties;
  var Cols: TTabularColumns);
var
  i: PtrInt;
begin
  for i := 0 to length(Cols) - 1 do
    while IsSqlReserved(Cols[i].SqlName) or
          Props.IsSqlKeyword(Cols[i].SqlName) or
          ((i > 0) and
           (FindRawUtf8Sql(Cols, Cols[i].SqlName, i) >= 0)) do
      Cols[i].SqlName := Cols[i].SqlName + '_';
end;

const
  // UNNEST(?::###[]) PostgreSQL array type, as in mormot.orm.base
  PG_FT: array[TSqlDBFieldType] of RawUtf8 = (
    'int4', 'text', 'int8', 'float8', 'numeric', 'timestamp', 'text', 'bytea');

function ColumnWidth(const Col: TTabularColumn; TextAsClob: boolean): cardinal;
begin
  if TextAsClob or
     (Col.FieldType <> ftUtf8) then
    result := 0
  else if Col.MaxLength <= 50 then
    result := 50
  else if Col.MaxLength <= 100 then
    result := 100
  else if Col.MaxLength <= 255 then
    result := 255
  else if Col.MaxLength <= 1000 then
    result := 1000
  else
    result := 0; // CLOB/TEXT with no maximum length
end;

function TabularSqlCreateFrom(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Cols: TTabularColumns;
  TextAsClob: boolean): RawUtf8;
var
  fields: TSqlDBColumnCreateDynArray;
  i: PtrInt;
begin
  SetLength(fields, length(Cols));
  for i := 0 to length(Cols) - 1 do
  begin
    fields[i].Name := Cols[i].SqlName;
    fields[i].DBType := Cols[i].FieldType;
    fields[i].Width := ColumnWidth(Cols[i], TextAsClob);
  end;
  result := Props.SqlCreate(TableName, fields, {addid=}false);
end;

function TabularSqlCreate(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Rows: TDocVariantData;
  TextAsClob: boolean): RawUtf8;
var
  cols: TTabularColumns;
begin
  cols := TabularColumns(Rows);
  if cols = nil then
    result := ''
  else
  begin
    FixReservedNames(Props, cols);
    result := TabularSqlCreateFrom(Props, TableName, cols, TextAsClob);
  end;
end;

function TabularToSqlDB(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Rows: variant;
  Options: TTabularSqlOptions; BatchRows: integer): integer;
var
  dv: PDocVariantData;
begin
  if not _Safe(Rows, dv) or
     not (dv^.IsArray or (dv^.Count = 0)) then
    raise ETabularSql.CreateUtf8('TabularToSqlDB(%): Rows should be a ' +
      'TDocVariant array', [TableName]);
  result := TabularToSqlDB(Props, TableName, dv^, Options, BatchRows);
end;

function TabularToSqlDB(Props: TSqlDBConnectionProperties;
  const TableName: RawUtf8; const Rows: TDocVariantData;
  Options: TTabularSqlOptions; BatchRows: integer): integer;
var
  cols: TTabularColumns;
  existing: TSqlDBColumnDefineDynArray;
  colndx: TIntegerDynArray;       // index in cols[] of each inserted field
  names: TRawUtf8DynArray;        // SQL names of each inserted field
  types: TSqlDBFieldTypeArray;    // DB types of each inserted field
  values: TRawUtf8DynArrayDynArray;
  conn: TSqlDBConnection;
  stmt: TSqlDBStatement;
  row: PDocVariantData;
  cell: PVariant;
  sql, v: RawUtf8;
  n, f, i, j, r, chunk, start: PtrInt;
  batch: boolean;

  procedure CellToSql(r, f: PtrInt; var Sql: RawUtf8);
  begin
    cell := nil;
    if _Safe(Rows.Values[r], row) then
      cell := TabularCell(row^, @cols[colndx[f]], colndx[f]);
    if cell = nil then
      Sql := 'null'
    else if not TabularValueToSql(cell^, types[f], Sql) then
      raise ETabularSql.CreateUtf8('TabularToSqlDB(%): row % column % ' +
        'value % is not a valid %', [TableName, r + 1, cols[colndx[f]].Name,
        cell^, ToText(types[f])^]);
  end;

begin
  result := 0;
  if (Props = nil) or
     (TableName = '') then
    raise ETabularSql.CreateUtf8('Invalid TabularToSqlDB(%,%) call',
      [Props, TableName]);
  cols := TabularColumns(Rows);
  if cols = nil then
    exit; // nothing to insert
  FillCharFast(types, SizeOf(types), 0);
  FixReservedNames(Props, cols);
  // resolve the destination table layout
  Props.GetFields(TableName, existing);
  if existing = nil then
  begin
    if not (tsoCreateTable in Options) then
      raise ETabularSql.CreateUtf8('TabularToSqlDB: table % does not exist',
        [TableName]);
    Props.ExecuteNoResult(TabularSqlCreateFrom(Props, TableName, cols,
      tsoTextAsClob in Options), []);
    n := length(cols);
    SetLength(colndx, n);
    SetLength(names, n);
    for f := 0 to n - 1 do
    begin
      colndx[f] := f;
      names[f] := cols[f].SqlName;
      if f < MAX_SQLFIELDS then
        types[f] := cols[f].FieldType;
    end;
  end
  else
  begin
    // match the row fields with the existing table columns
    n := 0;
    for i := 0 to length(cols) - 1 do
    begin
      j := length(existing) - 1;
      while (j >= 0) and
            not IdemPropNameU(existing[j].ColumnName, cols[i].Name) and
            not IdemPropNameU(existing[j].ColumnName, cols[i].SqlName) do
        dec(j);
      if j < 0 then
        if tsoIgnoreUnknownColumns in Options then
          continue
        else
          raise ETabularSql.CreateUtf8('TabularToSqlDB: no column % in table %',
            [cols[i].Name, TableName]);
      SetLength(colndx, n + 1);
      SetLength(names, n + 1);
      colndx[n] := i;
      names[n] := existing[j].ColumnName;
      if n < MAX_SQLFIELDS then
        if existing[j].ColumnType in [ftUnknown, ftNull] then
          types[n] := cols[i].FieldType
        else
          types[n] := existing[j].ColumnType;
      inc(n);
    end;
    if n = 0 then
      raise ETabularSql.CreateUtf8('TabularToSqlDB: no matching column in %',
        [TableName]);
  end;
  if n > MAX_SQLFIELDS then
    raise ETabularSql.CreateUtf8('TabularToSqlDB(%): too many columns (%>%)',
      [TableName, n, MAX_SQLFIELDS]);
  if BatchRows <= 0 then
    BatchRows := 1000;
  // execute the INSERT statements within a transaction
  conn := Props.ThreadSafeConnection;
  if not conn.Connected then
    conn.Connect;
  if not (tsoNoTransaction in Options) then
    conn.StartTransaction;
  try
    if tsoDeleteFirst in Options then
      Props.ExecuteNoResult('delete from ' + TableName, []);
    // same logic than the mORMot ORM TRestStorageExternal.InternalBatchStop
    batch := not (tsoNoBatch in Options) and
             (cCreate in Props.BatchSendingAbilities);
    if batch and
       not Assigned(Props.OnBatchInsert) and
       Props.NoBlobBindArray then
      for f := 0 to n - 1 do
        if types[f] = ftBlob then
          batch := false; // e.g. PostgreSQL has no BLOB array binding
    if batch then
    begin
      if not Assigned(Props.OnBatchInsert) then
      begin
        // array binding: PostgreSQL 'insert ... values (unnest(?::int8[]),..)'
        // or Oracle/FireDAC/ZEOS 'insert ... values (?,..)' array DML
        sql := 'insert into ' + TableName + ' (' +
          RawUtf8ArrayToCsv(names, ',') + ') values (';
        for f := 0 to n - 1 do
        begin
          if cPostgreBulkArray in Props.BatchSendingAbilities then
            sql := Make([sql, 'unnest(?::', PG_FT[types[f]], '[])'])
          else
            sql := sql + '?';
          if f = n - 1 then
            sql := sql + ')'
          else
            sql := sql + ',';
        end;
        if (Props.BatchMaxSentAtOnce > 0) and
           (BatchRows > Props.BatchMaxSentAtOnce) then
          BatchRows := Props.BatchMaxSentAtOnce;
      end;
      SetLength(values, n);
      start := 0;
      while start < Rows.Count do
      begin
        chunk := Rows.Count - start;
        if chunk > BatchRows then
          chunk := BatchRows;
        for f := 0 to n - 1 do
        begin
          SetLength(values[f], chunk);
          for r := 0 to chunk - 1 do
            CellToSql(start + r, f, values[f][r]);
        end;
        if Assigned(Props.OnBatchInsert) then
          // multi-VALUES INSERT (SQLite3, MySQL, MSSQL, Oracle, Firebird...)
          Props.OnBatchInsert(Props, TableName, names, types, chunk, values, [])
        else
        begin
          stmt := Props.NewThreadSafeStatement;
          try
            stmt.Prepare(sql, {expectresults=}false);
            for f := 0 to n - 1 do
              stmt.BindArray(f + 1, types[f], values[f], chunk);
            stmt.ExecutePrepared;
          finally
            stmt.Free;
          end;
        end;
        inc(start, chunk);
        inc(result, chunk);
      end;
    end
    else
    begin
      // one prepared INSERT statement per row
      sql := 'insert into ' + TableName + ' (' +
        RawUtf8ArrayToCsv(names, ',') + ') values (';
      for f := 1 to n do
        if f = n then
          sql := sql + '?)'
        else
          sql := sql + '?,';
      stmt := Props.NewThreadSafeStatement;
      try
        stmt.Prepare(sql, {expectresults=}false);
        for r := 0 to Rows.Count - 1 do
        begin
          for f := 0 to n - 1 do
          begin
            CellToSql(r, f, v);
            stmt.Bind(f + 1, types[f], v, {unquoted=}false);
          end;
          stmt.ExecutePrepared;
          stmt.Reset; // ready for the next row
          inc(result);
        end;
      finally
        stmt.Free;
      end;
    end;
    if not (tsoNoTransaction in Options) then
      conn.Commit;
  except
    if not (tsoNoTransaction in Options) then
      conn.Rollback;
    raise;
  end;
end;


{ ************ Export a SQL Query into TDocVariant Rows }

function SqlDBToTabular(Props: TSqlDBConnectionProperties; const Sql: RawUtf8;
  const Params: array of const; MaxRows: cardinal): variant;
var
  rows: ISqlDBRows;
begin
  rows := Props.Execute(Sql, Params);
  result := rows.FetchAllToDocVariantArray(MaxRows);
end;


end.
