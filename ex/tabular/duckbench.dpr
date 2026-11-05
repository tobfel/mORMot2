/// benchmark of mormot.core.csv/xlsx against the DuckDB file methods
// - compares reading, importing, exporting and converting CSV/XLSX files
// - needs duckdb.dll / libduckdb.so with the excel extension installed
// (e.g. run "INSTALL excel" once in the duckdb CLI)
// - usage: duckbench [rows] [threads] - files are created in the exe folder
program duckbench;

{$I mormot.defines.inc}

{$ifdef MSWINDOWS}
  {$apptype console}
{$endif MSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.tabular,
  mormot.core.csv,
  mormot.core.xlsx,
  mormot.db.sql,
  mormot.db.tabular,
  mormot.db.raw.duckdb,
  mormot.db.sql.duckdb;

const
  RUNS = 3;

type
  TBenchProc = procedure;

var
  Dir: TFileName;
  Props: TSqlDBDuckDBConnectionProperties;
  Csv: TCsvDocument;
  Xlsx: TXlsxDocument;
  Doc: variant;

procedure Bench(const Name: RawUtf8; Proc: TBenchProc);
var
  r: integer;
  start, stop, best: Int64;
begin
  best := high(Int64);
  for r := 1 to RUNS do
  begin
    QueryPerformanceMicroSeconds(start);
    Proc;
    QueryPerformanceMicroSeconds(stop);
    if stop - start < best then
      best := stop - start;
  end;
  ConsoleWrite(FormatUtf8('%%%.%ms', [Name, RawUtf8OfChar(' ', 48 - length(Name)),
    best div 1000, (best mod 1000) div 100]));
end;

// ---- mormot.core.tabular

procedure TabCsvRead;
begin
  VarClear(Doc);
  Csv.LoadFromFile(Dir + 'src.csv', Doc);
end;

procedure TabXlsxRead;
begin
  VarClear(Doc);
  Xlsx.LoadFromFile(Dir + 'src.xlsx', Doc);
end;

procedure TabCsvImport;
var
  d: variant;
begin
  Csv.LoadFromFile(Dir + 'src.csv', d);
  TabularToSqlDB(Props, 'tabimp', d, [tsoCreateTable, tsoDeleteFirst]);
end;

procedure TabCsvWrite;
begin
  FileFromString(Csv.Save(Doc), Dir + 'tab.csv');
end;

procedure TabXlsxWrite;
begin
  FileFromString(Xlsx.Save(Doc), Dir + 'tab.xlsx');
end;

procedure TabCsvToXlsx;
var
  d: variant;
begin
  Csv.LoadFromFile(Dir + 'src.csv', d);
  FileFromString(Xlsx.Save(d), Dir + 'tab.xlsx');
end;

procedure TabXlsxToCsv;
var
  d: variant;
begin
  Xlsx.LoadFromFile(Dir + 'src.xlsx', d);
  FileFromString(Csv.Save(d), Dir + 'tab.csv');
end;

// ---- TSqlDBDuckDBConnectionProperties file methods

procedure DuckCsvRead;
begin
  VarClear(Doc);
  Doc := Props.FileToDocVariant(Dir + 'src.csv');
end;

procedure DuckXlsxRead;
begin
  VarClear(Doc);
  Doc := Props.FileToDocVariant(Dir + 'src.xlsx');
end;

procedure DuckCsvImport;
begin
  Props.ExecuteNoResult('drop table if exists duckimp', []);
  Props.ImportFile('duckimp', Dir + 'src.csv');
end;

procedure DuckXlsxImport;
begin
  Props.ExecuteNoResult('drop table if exists duckimp', []);
  Props.ImportFile('duckimp', Dir + 'src.xlsx');
end;

procedure DuckTableToCsv;
begin
  Props.ExportSql('from src', Dir + 'duck.csv');
end;

procedure DuckTableToXlsx;
begin
  Props.ExportSql('from src', Dir + 'duck.xlsx');
end;

procedure DuckTableToParquet;
begin
  Props.ExportSql('from src', Dir + 'duck.parquet');
end;

procedure DuckCsvToXlsx;
begin
  Props.ConvertFile(Dir + 'src.csv', Dir + 'duck.xlsx');
end;

procedure DuckXlsxToCsv;
begin
  Props.ConvertFile(Dir + 'src.xlsx', Dir + 'duck.csv');
end;

procedure DuckCsvToParquet;
begin
  Props.ConvertFile(Dir + 'src.csv', Dir + 'duck.parquet');
end;

var
  rows: integer;
  threads: RawUtf8;
begin
  rows := GetInteger(pointer(StringToUtf8(ParamStr(1))));
  if rows <= 0 then
    rows := 100000;
  threads := StringToUtf8(ParamStr(2));
  Dir := Executable.ProgramFilePath;
  Props := TSqlDBDuckDBConnectionProperties.Create('', '', '', '');
  Csv := TCsvDocument.Create([tboHeader, tboGuessTypes, tboSkipEmptyRows]);
  Xlsx := TXlsxDocument.Create([tboHeader, tboSkipEmptyRows]);
  try
    if threads <> '' then
      Props.Config := 'threads=' + threads;
    // generate the source table and files with DuckDB itself
    Props.ExecuteNoResult('create table src as select i as id, ' +
      '''Kunde '' || (i % 5000) as name, ' +
      '[''Berlin'', ''Hamburg'', ''Muenchen'', ''Frankfurt, Main''][1 + i % 4] as city, ' +
      'round(((i * 7919) % 100000) / 100.0, 2)::DOUBLE as amount, ' +
      '(i * 31) % 1000 as qty, ' +
      'date ''2020-01-01'' + (i % 2000)::INTEGER as created, ' +
      'i % 3 = 0 as active, ' +
      'case when i % 10 = 0 then ''Text with "quotes", comma'' ' +
      'else ''Text '' || i end as note from range(1, ? + 1) t(i)', [rows]);
    Props.ExportSql('from src', Dir + 'src.csv');
    Props.ExportSql('from src', Dir + 'src.xlsx');
    ConsoleWrite(FormatUtf8('DuckDB % - % rows, threads=% - best of % runs',
      [Props.LibraryVersion, rows, threads, RUNS]));
    ConsoleWrite(#10'--- read into TDocVariant');
    Bench('tabular  CSV  -> TDocVariant', TabCsvRead);
    Bench('duckdb   CSV  -> TDocVariant', DuckCsvRead);
    Bench('tabular  XLSX -> TDocVariant', TabXlsxRead);
    Bench('duckdb   XLSX -> TDocVariant', DuckXlsxRead);
    ConsoleWrite(#10'--- import into a DuckDB table');
    Bench('tabular  CSV  -> TabularToSqlDB', TabCsvImport);
    Bench('duckdb   CSV  -> ImportFile', DuckCsvImport);
    Bench('duckdb   XLSX -> ImportFile', DuckXlsxImport);
    ConsoleWrite(#10'--- export');
    TabCsvRead;
    Bench('tabular  TDocVariant -> CSV', TabCsvWrite);
    Bench('tabular  TDocVariant -> XLSX', TabXlsxWrite);
    Bench('duckdb   table -> CSV (ExportSql)', DuckTableToCsv);
    Bench('duckdb   table -> XLSX (ExportSql)', DuckTableToXlsx);
    Bench('duckdb   table -> Parquet (ExportSql)', DuckTableToParquet);
    ConsoleWrite(#10'--- file to file conversion');
    Bench('tabular  CSV  -> XLSX', TabCsvToXlsx);
    Bench('duckdb   CSV  -> XLSX (ConvertFile)', DuckCsvToXlsx);
    Bench('tabular  XLSX -> CSV', TabXlsxToCsv);
    Bench('duckdb   XLSX -> CSV (ConvertFile)', DuckXlsxToCsv);
    Bench('duckdb   CSV  -> Parquet (ConvertFile)', DuckCsvToParquet);
  finally
    Csv.Free;
    Xlsx.Free;
    Props.Free;
  end;
end.
