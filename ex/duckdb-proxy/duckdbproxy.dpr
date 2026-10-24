/// duckdbproxy - 64-bit wrapper publishing a DuckDB database via mormot.db.proxy
// - compile as Win64 (Delphi 13.1 or FPC) and ship it with duckdb.dll
// - clients (e.g. 32-bit executables) use TSqlDBSocketConnectionProperties or
// TSqlDBDuckDBProxyConnectionProperties from mormot.db.sql.duckdbproxy
program duckdbproxy;

{
  usage: duckdbproxy <dbfile|:memory:> [options]
    -port 8092            TCP port
    -bind 127.0.0.1       listening interface (0.0.0.0 = all - beware)
    -name duckdb          database name, i.e. URI root of the proxy server
    -user duckdb          user name for authentication
    -pass <secret>        password - or DUCKDBPROXY_PASS environment variable
    -readonly             open the database file in READ_ONLY mode
    -config "a=b;c=d"     DuckDB configuration options
    -lib <path>           duckdb.dll / libduckdb.so to load
    -log <file>           write a TSynLog file for troubleshooting
    -parentpid <pid>      exit when this process ends

  stops on [Enter], Ctrl+C, SIGTERM or (on Windows) WM_QUIT message

  exit codes: 0 = clean stop, 1 = invalid arguments, 2 = startup failure
}

{$I mormot.defines.inc}

{$ifdef MSWINDOWS}
  {$APPTYPE CONSOLE}
{$endif MSWINDOWS}

uses
  {$I mormot.uses.inc}
  {$ifdef OSWINDOWS}
  Windows,
  {$else}
  baseunix,
  {$endif OSWINDOWS}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.rtti,
  mormot.core.log,
  mormot.db.core,
  mormot.db.sql,
  mormot.db.proxy,
  mormot.db.raw.duckdb,
  mormot.db.sql.duckdb,
  mormot.db.sql.duckdbproxy;

var
  DbFile, Bind, DbName, User, Pass, Config: RawUtf8;
  LibFile, LogFile: TFileName;
  Port: integer;
  ParentPid: cardinal;
  ReadOnly: boolean;

procedure Usage(const msg: RawUtf8);
begin
  ConsoleWrite('duckdbproxy: %', [msg], ccLightRed);
  ConsoleWrite('usage: duckdbproxy <dbfile|:memory:> [-port 8092] ' +
    '[-bind 127.0.0.1] [-name duckdb] [-user duckdb] [-pass <secret>] ' +
    '[-readonly] [-config "threads=4"] [-lib duckdb.dll] [-log file] ' +
    '[-parentpid pid]');
  Halt(1);
end;

procedure ParseCommandLine;
var
  i: integer;
  a: RawUtf8;

  function Next: RawUtf8;
  begin
    inc(i);
    if i > ParamCount then
      Usage('missing value after ' + a);
    result := StringToUtf8(ParamStr(i));
  end;

begin
  Port := DUCKDBPROXY_DEFAULT_PORT;
  Bind := '127.0.0.1';
  DbName := DUCKDBPROXY_DEFAULT_NAME;
  User := DUCKDBPROXY_DEFAULT_NAME;
  Pass := StringToUtf8(GetEnvironmentVariable(DUCKDBPROXY_PASSWORD_ENV));
  i := 1;
  while i <= ParamCount do
  begin
    a := StringToUtf8(ParamStr(i));
    if (a <> '') and (a[1] = '-') then
    begin
      a := LowerCase(a);
      if a = '-port' then
        Port := Utf8ToInteger(Next, 1, 65535, 0)
      else if a = '-bind' then
        Bind := Next
      else if a = '-name' then
        DbName := Next
      else if a = '-user' then
        User := Next
      else if a = '-pass' then
        Pass := Next
      else if a = '-readonly' then
        ReadOnly := true
      else if a = '-config' then
        Config := Next
      else if a = '-lib' then
        LibFile := Utf8ToString(Next)
      else if a = '-log' then
        LogFile := Utf8ToString(Next)
      else if a = '-parentpid' then
        ParentPid := Utf8ToInteger(Next, 0)
      else
        Usage('unknown option ' + a);
    end
    else if DbFile = '' then
      DbFile := a
    else
      Usage('unexpected argument ' + a);
    inc(i);
  end;
  if DbFile = '' then
    Usage('missing database file');
  if Port = 0 then
    Usage('invalid -port');
  if Pass = '' then
    Usage('-pass or ' + DUCKDBPROXY_PASSWORD_ENV + ' is mandatory');
end;

/// wait until the parent process ends, or a quit request is received
procedure WaitForStop;
{$ifdef OSWINDOWS}
const
  SYNCHRONIZE = $00100000;
var
  parent: THandle;
begin
  if ParentPid = 0 then
  begin
    ConsoleWaitForEnterKey; // interactive use: [Enter], Ctrl+C or WM_QUIT
    exit;
  end;
  parent := OpenProcess(SYNCHRONIZE, false, ParentPid);
  if parent = 0 then
    exit; // parent already gone
  // WM_QUIT is sent by QuitProcess() from TSqlDBDuckDBProxyConnectionProperties
  while WinWaitFor(500, parent) = wwfTimeout do
    ;
  CloseHandle(parent);
end;
{$else}
var
  isdirectchild: boolean;
begin
  SynDaemonIntercept; // SIGTERM/SIGINT/SIGQUIT -> SynDaemonTerminated <> 0
  isdirectchild := (ParentPid <> 0) and (cardinal(fpgetppid) = ParentPid);
  repeat
    SleepHiRes(200);
    if SynDaemonTerminated <> 0 then
      break;
    if ParentPid <> 0 then
      if isdirectchild then
      begin
        if cardinal(fpgetppid) <> ParentPid then
          break; // we have been re-parented: our parent process has gone
      end
      else if fpkill(ParentPid, 0) <> 0 then
        break; // parent process has gone
  until false;
end;
{$endif OSWINDOWS}

var
  props: TSqlDBDuckDBConnectionProperties;
  server: TSqlDBServerSockets;
begin
  ParseCommandLine;
  if LogFile <> '' then
    with TSynLog.Family do
    begin
      Level := LOG_VERBOSE;
      CustomFileName := ExtractFileName(LogFile);
      DestinationPath := ExtractFilePath(LogFile);
      PerThreadLog := ptIdentifiedInOneFile;
      SynDBLog := TSynLog;
    end;
  if LibFile <> '' then
    DuckDBLibraryName := LibFile;
  props := nil;
  server := nil;
  try
    try
      props := TSqlDBDuckDBConnectionProperties.Create(DbFile, '', '', '');
      props.ReadOnly := ReadOnly;
      props.Config := Config;
      props.MainConnection.Connect; // open the file now: fail fast
      // tmMainConnection (default): one DuckDB connection, all requests
      // serialized - required by mormot.db.proxy for remote transactions
      server := TSqlDBServerSockets.Create(props, DbName,
        Bind + ':' + Int32ToUtf8(Port), User, Pass);
    except
      on E: Exception do
      begin
        ConsoleWrite('duckdbproxy: startup failed - %: %',
          [E.ClassType, E.Message], ccLightRed);
        FreeAndNil(server);
        FreeAndNil(props);
        ExitCode := 2;
        exit;
      end;
    end;
    ConsoleWrite('duckdbproxy % on %:% /% - DuckDB %',
      [DbFile, Bind, Port, DbName, props.LibraryVersion]);
    WaitForStop;
  finally
    server.Free;  // stop listening first
    props.Free;   // then close the database file (checkpoint)
  end;
end.
