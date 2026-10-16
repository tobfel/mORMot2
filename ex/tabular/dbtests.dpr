/// regression tests for mormot.db.tabular / mormot.db.rad.tabular
// - uses SQLite3 via mormot.db.sql.sqlite3 and FPC TBufDataset / Delphi
// TClientDataSet as editable in-memory dataset
program dbtests;

{$I mormot.defines.inc}

{$ifdef MSWINDOWS}
  {$apptype console}
{$endif MSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  variants,
  {$ifdef FPC}
  db,
  bufdataset,
  {$else}
  DB,
  DBClient,
  MidasLib,
  {$endif FPC}
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.tabular,
  mormot.core.csv,
  mormot.core.xlsx,
  mormot.db.core,
  mormot.db.sql,
  mormot.db.raw.sqlite3,
  {$ifdef NOSQLITE3STATIC}
  {$else}
  mormot.db.raw.sqlite3.static,
  {$endif NOSQLITE3STATIC}
  mormot.db.sql.sqlite3,
  mormot.db.sql.postgres,
  mormot.db.tabular,
  mormot.db.rad.tabular;

var
  Passed, Failed: integer;

procedure Check(cond: boolean; const msg: RawUtf8);
begin
  if cond then
    inc(Passed)
  else
  begin
    inc(Failed);
    ConsoleWrite('  FAILED: %', [msg], ccLightRed);
  end;
end;

procedure CheckEqual(const a, b: RawUtf8; const msg: RawUtf8);
begin
  if a = b then
    inc(Passed)
  else
  begin
    inc(Failed);
    ConsoleWrite('  FAILED: %'#10'    got:      %'#10'    expected: %',
      [msg, a, b], ccLightRed);
  end;
end;

function J(const v: variant): RawUtf8;
begin
  result := _Safe(v)^.ToJson;
end;

// normalize some JSON (e.g. with \u escapes) as compact UTF-8 JSON
function JN(const Json: RawUtf8): RawUtf8;
begin
  result := J(_Json(Json, JSON_FAST_FLOAT));
end;

function SqlQuery(Props: TSqlDBConnectionProperties; const Sql: RawUtf8;
  const Params: array of const): variant;
begin
  result := Props.Execute(Sql, Params).FetchAllToDocVariantArray;
end;

function DateVariant(dt: TDateTime): variant;
begin
  VarClear(result);
  TVarData(result).VType := varDate;
  TVarData(result).VDate := dt;
end;

function SampleRows: variant;
var
  long: RawUtf8;
begin
  long := RawUtf8OfChar('x', 300);
  result := _Json('[' +
    '{"id":1,"first name":"M\u00fcller","amount":1,"ok":true,"order":null,' +
    '"1st":"a","when":null,"note":"short"},' +
    '{"id":2,"first name":"O''Brien","amount":2.5,"ok":false,"order":"x",' +
    '"1st":5,"when":null,"note":"' + long + '"},' +
    '{"id":3,"first name":null,"amount":3.14159,"ok":true,"order":"",' +
    '"1st":"c","when":null}]', JSON_FAST_FLOAT);
  _Safe(_Safe(result)^.Values[0])^.Values[6] :=
    DateVariant(EncodeDate(2024, 2, 29) + EncodeTime(13, 45, 30, 0));
  _Safe(_Safe(result)^.Values[1])^.Values[6] := DateVariant(EncodeDate(2025, 1, 1));
end;

procedure TestColumns;
var
  cols: TTabularColumns;
  s: RawUtf8;
  i: integer;
begin
  writeln('Column inference');
  cols := TabularColumns(SampleRows);
  s := '';
  for i := 0 to length(cols) - 1 do
    s := Make([s, cols[i].Name, '/', cols[i].SqlName, '=',
      ToText(cols[i].FieldType)^, ':', cols[i].MaxLength, ':',
      ord(cols[i].HasNull), ' ']);
  CheckEqual(s, 'id/id=ftInt64:0:0 first name/first_name=ftUtf8:7:1 ' +
    'amount/amount=ftDouble:0:0 ok/ok=ftInt64:0:0 order/order=ftUtf8:1:1 ' +
    '1st/_1st=ftUtf8:1:0 when/when=ftDate:0:1 note/note=ftUtf8:300:1 ',
    'TabularColumns');
  cols := TabularColumns(_JsonFast('[[1,"a"],[2.5],[3,"bb",true]]'));
  CheckEqual(Make([length(cols), cols[0].Name, ToText(cols[0].FieldType)^,
    cols[2].Name, ord(cols[1].HasNull), ord(cols[2].HasNull)]),
    '3Col1ftCurrencyCol311', 'array rows');
  CheckEqual(TabularSqlName(HexToBin('537472' + '61c39f65204e722e')), 'Stra__e_Nr_', 'sql name utf-8');
end;

procedure TestPostgres(const Server, Database, User, Pass: RawUtf8);
var
  props: TSqlDBPostgresConnectionProperties;
  rows, res: variant;
  big: TDocVariantData;
  i, n: integer;
  t: Int64;
begin
  writeln('SQL database (PostgreSQL ', Server, ')');
  props := TSqlDBPostgresConnectionProperties.Create(Server, Database, User, Pass);
  try
    props.ExecuteNoResult('drop table if exists tab_import', []);
    props.ExecuteNoResult('drop table if exists tab_big', []);
    rows := SampleRows;
    n := TabularToSqlDB(props, 'tab_import', rows);
    Check(n = 3, 'pg insert count');
    res := SqlQuery(props, 'select * from tab_import order by id', []);
    CheckEqual(J(res), JN('[' +
      '{"id":1,"first_name":"M\u00fcller","amount":1,"ok":1,"order_":null,' +
      '"_1st":"a","when_":"2024-02-29T13:45:30","note":"short"},' +
      '{"id":2,"first_name":"O''Brien","amount":2.5,"ok":0,"order_":"x",' +
      '"_1st":"5","when_":"2025-01-01","note":"' + RawUtf8OfChar('x', 300) +
      '"},' +
      '{"id":3,"first_name":null,"amount":3.14159,"ok":1,"order_":"",' +
      '"_1st":"c","when_":null,"note":null}]'), 'pg select back');
    n := TabularToSqlDB(props, 'tab_import', rows, [tsoDeleteFirst, tsoNoBatch]);
    Check(n = 3, 'pg no batch');
    CheckEqual(J(SqlQuery(props, 'select count(*) as n from tab_import', [])),
      '[{"n":3}]', 'pg delete first');
    big.InitFast(100000, dvArray);
    for i := 1 to 100000 do
      big.AddItem(_ObjFast(['id', i, 'name', Make(['name ', i]),
        'value', i / 7, 'flag', odd(i)]));
    t := GetTickCount64;
    n := TabularToSqlDB(props, 'tab_big', big, [tsoCreateTable], 10000);
    writeln('  unnest() array insert 100k rows: ', GetTickCount64 - t, ' ms');
    Check(n = 100000, 'pg big batch');
    t := GetTickCount64;
    n := TabularToSqlDB(props, 'tab_big', big, [tsoDeleteFirst, tsoNoBatch]);
    writeln('  per-row insert 100k rows: ', GetTickCount64 - t, ' ms');
    Check(n = 100000, 'pg big no batch');
    CheckEqual(J(SqlQuery(props,
      'select id,name,flag from tab_big where id=?', [99999])),
      '[{"id":99999,"name":"name 99999","flag":1}]', 'pg big content');
  finally
    props.Free;
  end;
end;

procedure TestSqlDB;
var
  props: TSqlDBSQLite3ConnectionProperties;
  rows, res: variant;
  n: integer;
  t: Int64;
  big: TDocVariantData;
  i: integer;
  ok: boolean;
begin
  writeln('SQL database (SQLite3)');
  props := TSqlDBSQLite3ConnectionProperties.Create(':memory:', '', '', '');
  try
    rows := SampleRows;
    CheckEqual(TabularSqlCreate(props, 'import', _Safe(rows)^),
      'CREATE TABLE import (id INTEGER,first_name TEXT COLLATE SYSTEMNOCASE,' +
      'amount FLOAT,ok INTEGER,order_ TEXT COLLATE SYSTEMNOCASE,' +
      '_1st TEXT COLLATE SYSTEMNOCASE,when_ TEXT COLLATE ISO8601,' +
      'note TEXT COLLATE SYSTEMNOCASE)', 'SqlCreate with reserved words');
    n := TabularToSqlDB(props, 'import', rows);
    Check(n = 3, 'insert count');
    res := SqlQuery(props, 'select * from import order by id', []);
    CheckEqual(J(res), JN('[' +
      '{"id":1,"first_name":"M\u00fcller","amount":1,"ok":1,"order_":null,' +
      '"_1st":"a","when_":"2024-02-29T13:45:30","note":"short"},' +
      '{"id":2,"first_name":"O''Brien","amount":2.5,"ok":0,"order_":"x",' +
      '"_1st":"5","when_":"2025-01-01","note":"' + RawUtf8OfChar('x', 300) +
      '"},' +
      '{"id":3,"first_name":null,"amount":3.14159,"ok":1,"order_":"",' +
      '"_1st":"c","when_":null,"note":null}]'), 'select back');
    // append into the existing table, matching by original or SQL names
    n := TabularToSqlDB(props, 'import',
      _JsonFast('[{"id":"4","amount":"7","first name":"x"}]'), []);
    Check(n = 1, 'existing table + text to number conversion');
    CheckEqual(J(SqlQuery(props,
      'select id,amount,first_name from import where id=?', [4])),
      '[{"id":4,"amount":7,"first_name":"x"}]', 'converted values');
    // unknown column
    ok := false;
    try
      TabularToSqlDB(props, 'import', _JsonFast('[{"id":5,"zzz":1}]'), []);
    except
      on ETabularSql do
        ok := true;
    end;
    Check(ok, 'unknown column raises');
    n := TabularToSqlDB(props, 'import', _JsonFast('[{"id":5,"zzz":1}]'),
      [tsoIgnoreUnknownColumns]);
    Check(n = 1, 'tsoIgnoreUnknownColumns');
    // conversion error rollbacks the whole import
    ok := false;
    try
      TabularToSqlDB(props, 'import',
        _JsonFast('[{"id":6},{"id":"seven"}]'), []);
    except
      on E: ETabularSql do
        ok := PosEx('row 2', E.Message) > 0;
    end;
    Check(ok, 'conversion error with row number');
    CheckEqual(J(SqlQuery(props, 'select count(*) as n from import', [])),
      '[{"n":5}]', 'rollback on error');
    // tsoDeleteFirst + per-row prepared INSERT path
    n := TabularToSqlDB(props, 'import', rows, [tsoDeleteFirst, tsoNoBatch]);
    Check(n = 3, 'no batch count');
    CheckEqual(J(SqlQuery(props,
      'select id,ok,when_ from import order by id', [])),
      '[{"id":1,"ok":1,"when_":"2024-02-29T13:45:30"},{"id":2,"ok":0,' +
      '"when_":"2025-01-01"},{"id":3,"ok":1,"when_":null}]', 'no batch data');
    // CSV -> SQL -> XLSX full chain
    rows := CsvToVariant('Art.Nr;Bezeichnung;Preis'#13#10'0815;Schraube;0,25'#13#10 +
      '4711;Mutter;1,5'#13#10, [tboHeader, tboGuessTypes], ';');
    // with ';' and no DecimalSeparator, "0,25" stays text: use the class
    with TCsvDocument.CreateDelimiter(';', [tboHeader, tboGuessTypes]) do
    try
      DecimalSeparator := ',';
      Load('Art.Nr;Bezeichnung;Preis'#13#10'0815;Schraube;0,25'#13#10 +
        '4711;Mutter;1,5'#13#10, rows);
    finally
      Free;
    end;
    TabularToSqlDB(props, 'artikel', rows);
    res := SqlQuery(props, 'select * from artikel', []);
    CheckEqual(J(res), '[{"Art_Nr":"0815","Bezeichnung":"Schraube",' +
      '"Preis":0.25},{"Art_Nr":"4711","Bezeichnung":"Mutter","Preis":1.5}]',
      'csv -> sql');
    CheckEqual(J(XlsxToVariant(VariantToXlsx(res))), J(res), 'sql -> xlsx');
    // performance
    big.InitFast(100000, dvArray);
    for i := 1 to 100000 do
      big.AddItem(_ObjFast(['id', i, 'name', Make(['name ', i]),
        'value', i / 7, 'flag', odd(i)]));
    t := GetTickCount64;
    n := TabularToSqlDB(props, 'big', big);
    writeln('  batch insert 100k rows: ', GetTickCount64 - t, ' ms');
    Check(n = 100000, 'big batch');
    t := GetTickCount64;
    n := TabularToSqlDB(props, 'big', big, [tsoDeleteFirst, tsoNoBatch]);
    writeln('  per-row insert 100k rows: ', GetTickCount64 - t, ' ms');
    Check(n = 100000, 'big no batch');
    t := GetTickCount64;
    res := SqlQuery(props, 'select * from big', []);
    writeln('  select 100k rows: ', GetTickCount64 - t, ' ms');
    Check(_Safe(res)^.Count = 100000, 'big select');
  finally
    props.Free;
  end;
end;

procedure TestDataSet;
var
  ds: TTabularDataSet;
  {$ifdef FPC}
  mem: TBufDataset;
  {$else}
  mem: TClientDataSet;
  {$endif FPC}
  rows, back: variant;
  s: RawUtf8;
  i, n: integer;
  ok: boolean;
begin
  writeln('TDataSet');
  rows := SampleRows;
  ds := TTabularDataSet.Create(nil, rows);
  try
    s := '';
    for i := 0 to ds.FieldCount - 1 do
      s := Make([s, ds.Fields[i].FieldName, ':',
        FieldTypeNames[ds.Fields[i].DataType], ':', ds.Fields[i].Size, ' ']);
    // FieldTypeNames spelling differs (LargeInt/Largeint): compare lowercase
    CheckEqual(LowerCaseU(s), 'id:largeint:0 first name:widestring:7 ' +
      'amount:float:0 ok:boolean:0 order:widestring:1 1st:widestring:1 ' +
      'when:datetime:0 note:widestring:300 ', 'virtual dataset fields');
    Check(ds.RecordCount = 3, 'record count');
    ds.First;
    ds.Next;
    CheckEqual(StringToUtf8(ds.FieldByName('first name').AsString), 'O''Brien',
      'string field');
    Check(ds.FieldByName('amount').AsFloat = 2.5, 'float field');
    Check(not ds.FieldByName('ok').AsBoolean, 'boolean field');
    Check(length(ds.FieldByName('note').AsString) = 300, 'long text not truncated');
    Check(ds.FieldByName('when').AsDateTime = EncodeDate(2025, 1, 1), 'date field');
    ds.Next;
    Check(ds.FieldByName('first name').IsNull, 'null field');
    back := DataSetToTabular(ds);
    CheckEqual(J(back), JN('[{"id":1,"first name":"M\u00fcller","amount":1,"ok":true,"order":null,' +
      '"1st":"a","when":"2024-02-29T13:45:30","note":"short"},{"id":2,' +
      '"first name":"O''Brien","amount":2.5,"ok":false,"order":"x","1st":"5",' +
      '"when":"2025-01-01","note":"' + RawUtf8OfChar('x', 300) + '"},{"id":3,' +
      '"first name":null,"amount":3.14159,"ok":true,"order":"","1st":"c",' +
      '"when":null,"note":null}]'),
      'DataSetToTabular(TTabularDataSet)');
  finally
    ds.Free;
  end;
  // array rows
  ds := TTabularDataSet.Create(nil, _JsonFast('[[1,"a"],[2,"bb"]]'));
  try
    CheckEqual(J(DataSetToTabular(ds)), '[{"Col1":1,"Col2":"a"},' +
      '{"Col1":2,"Col2":"bb"}]', 'array rows dataset');
  finally
    ds.Free;
  end;
  // editable in-memory dataset
  {$ifdef FPC}
  mem := TBufDataset.Create(nil);
  {$else}
  mem := TClientDataSet.Create(nil);
  {$endif FPC}
  try
    TabularFieldDefs(rows, mem.FieldDefs);
    mem.CreateDataset;
    n := TabularAppendToDataSet(rows, mem);
    Check(n = 3, 'append count');
    Check(mem.RecordCount = 3, 'mem record count');
    back := DataSetToTabular(mem);
    CheckEqual(J(back), JN('[{"id":1,"first name":"M\u00fcller","amount":1,"ok":true,"order":null,' +
      '"1st":"a","when":"2024-02-29T13:45:30","note":"short"},{"id":2,' +
      '"first name":"O''Brien","amount":2.5,"ok":false,"order":"x","1st":"5",' +
      '"when":"2025-01-01","note":"' + RawUtf8OfChar('x', 300) + '"},{"id":3,' +
      '"first name":null,"amount":3.14159,"ok":true,"order":"","1st":"c",' +
      '"when":null,"note":null}]'),
      'TBufDataset round-trip');
    // type conversion from CSV text values
    n := TabularAppendToDataSet(_JsonFast('[{"id":"10","amount":"1.25",' +
      '"ok":"true","when":"2023-12-24T18:00:00"}]'), mem);
    Check(n = 1, 'append text values');
    mem.Last;
    Check((mem.FieldByName('id').AsInteger = 10) and
      (mem.FieldByName('amount').AsFloat = 1.25) and
      mem.FieldByName('ok').AsBoolean and
      (mem.FieldByName('when').AsDateTime =
        EncodeDate(2023, 12, 24) + EncodeTime(18, 0, 0, 0)),
      'converted field values');
    ok := false;
    try
      TabularAppendToDataSet(_JsonFast('[{"id":"eleven"}]'), mem);
    except
      on E: ETabularDataSet do
        ok := PosEx('row 1', E.Message) > 0;
    end;
    Check(ok and (mem.RecordCount = 4), 'conversion error cancels record');
    ok := false;
    try
      TabularAppendToDataSet(_JsonFast('[{"unknown":1}]'), mem);
    except
      on ETabularDataSet do
        ok := true;
    end;
    Check(ok, 'unknown field raises');
    n := TabularAppendToDataSet(_JsonFast('[{"id":12,"unknown":1}]'), mem,
      [tdoIgnoreUnknownFields, tdoEmptyFirst]);
    Check((n = 1) and (mem.RecordCount = 1), 'ignore unknown + empty first');
  finally
    mem.Free;
  end;
end;

begin
  {$ifdef NOSQLITE3STATIC}
  sqlite3 := TSqlite3LibraryDynamic.Create;
  {$endif NOSQLITE3STATIC}
  TestColumns;
  TestSqlDB;
  // e.g. dbtests localhost:5432 tabtest tabular tabular
  if ParamCount >= 4 then
    TestPostgres(ParamStr(1), ParamStr(2), ParamStr(3), ParamStr(4));
  TestDataSet;
  writeln;
  writeln('passed: ', Passed, '  failed: ', Failed);
  if Failed > 0 then
    ExitCode := 1;
end.
