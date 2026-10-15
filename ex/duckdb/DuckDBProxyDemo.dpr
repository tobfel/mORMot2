/// 32-bit demo: DuckDB via the duckdbproxy.exe (Win64) wrapper
// - ship duckdbproxy.exe + duckdb.dll (both 64-bit) next to this executable
// - the 64-bit proxy offers real prepared statements, real transactions
// and binary results to 32-bit clients
program DuckDBProxyDemo;

{$I mormot.defines.inc}

{$APPTYPE CONSOLE}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.db.core,
  mormot.db.sql,
  mormot.db.sql.duckdbproxy;

procedure Demo(Props: TSqlDBConnectionProperties);
const
  N = 10000;
var
  conn: TSqlDBConnection;
  st: ISqlDBStatement;
  rows: ISqlDBRows;
  ids: array of Int64;
  regions: TRawUtf8DynArray;
  amounts: array of currency;
  i: integer;
begin
  conn := Props.ThreadSafeConnection;
  Props.ExecuteNoResult('create or replace table sales (' +
    'id INTEGER, region VARCHAR, amount DECIMAL(19,4))', []);
  // bulk insert: BindArray sends all rows in ONE round-trip to the wrapper
  SetLength(ids, N);
  SetLength(regions, N);
  SetLength(amounts, N);
  for i := 0 to N - 1 do
  begin
    ids[i] := i + 1;
    regions[i] := 'Region ' + Int32ToUtf8(i mod 5);
    amounts[i] := (i + 1) * 1.25;
  end;
  st := conn.NewStatementPrepared('insert into sales values (?,?,?)', false, true);
  st.BindArray(1, ids);
  st.BindArray(2, regions);
  st.BindArrayCurrency(3, amounts);
  st.ExecutePrepared; // executed server-side within one transaction
  ConsoleWrite('% rows inserted', [st.UpdateCount]);
  st := nil;
  // real transaction, executed on the server connection
  conn.StartTransaction;
  try
    Props.ExecuteNoResult('update sales set amount = amount * ? where region = ?',
      [2, 'Region 0']);
    conn.Commit;
  except
    conn.Rollback;
    raise;
  end;
  // analytical query with a bound parameter
  rows := Props.Execute('select region, count(*), sum(amount) from sales ' +
    'where amount > ? group by region order by region', [100]);
  while rows.Step do
    ConsoleWrite('% count=% sum=%', [rows.ColumnUtf8(0), rows.ColumnInt(1),
      rows.ColumnCurrency(2)]);
  rows := nil;
end;

var
  props: TSqlDBDuckDBProxyConnectionProperties;
begin
  // launches duckdbproxy.exe on 127.0.0.1 with a random password,
  // and stops it (cleanly: checkpoint of the file) when props is freed
  props := TSqlDBDuckDBProxyConnectionProperties.CreateWithProcess(
    Executable.ProgramFilePath + 'duckdbproxy.exe',
    Executable.ProgramFilePath + 'demo.duckdb');
  try
    Demo(props);
  finally
    props.Free;
  end;
end.
