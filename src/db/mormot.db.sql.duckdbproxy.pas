/// DuckDB access from any process bitness through a 64-bit proxy executable
// - the duckdbproxy(.exe) wrapper hosts mormot.db.sql.duckdb (duckdb.dll) and
// publishes it via the standard mormot.db.proxy binary protocol
// - the client side is plain TSqlDBSocketConnectionProperties: works from
// 32-bit executables, since DuckDB itself is only available as 64-bit library
unit mormot.db.sql.duckdbproxy;

{
  *****************************************************************************

   DuckDB via the duckdbproxy Wrapper Executable
    - TSqlDBDuckDBProxyConnectionProperties: mormot.db.proxy client, which
      may launch and own its local duckdbproxy.exe process on Windows

  *****************************************************************************

}

interface

{$I mormot.defines.inc}

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.crypt.core,
  mormot.db.core,
  mormot.db.sql,
  mormot.db.proxy,
  mormot.net.sock;

const
  /// default TCP port of duckdbproxy
  DUCKDBPROXY_DEFAULT_PORT = 8092;
  /// default database name (i.e. URI root) and user name of duckdbproxy
  DUCKDBPROXY_DEFAULT_NAME = 'duckdb';
  /// environment variable used by duckdbproxy if no -pass option is supplied
  // - so that the password does not appear on the process command line
  DUCKDBPROXY_PASSWORD_ENV = 'DUCKDBPROXY_PASS';

type
  /// client connection properties to a duckdbproxy wrapper
  // - is a TSqlDBSocketConnectionProperties, i.e. standard mormot.db.proxy
  // client, which may optionally launch and own its duckdbproxy.exe process
  TSqlDBDuckDBProxyConnectionProperties = class(TSqlDBSocketConnectionProperties)
  protected
    fProcessID: cardinal;
  public
    /// initialize the client properties for an existing duckdbproxy server
    constructor Create(const aServerName, aDatabaseName, aUserID,
      aPassWord: RawUtf8); override;
    {$ifdef OSWINDOWS}
    /// launch duckdbproxy.exe on a 127.0.0.1 port, then connect to it
    // - a random password is generated and transmitted via the environment
    // - aOptions are appended to the command line, e.g. '-readonly' or
    // '-config threads=4' - see ex/duckdb-proxy/README.md
    // - the process exits by itself when this (parent) process ends, and is
    // gracefully stopped (with a DuckDB checkpoint) when this instance is freed
    // - only implemented on Windows, since DuckDB has no 32-bit POSIX library
    // - raise ESqlDBRemote (and kill the process) if it could not start
    class function CreateWithProcess(const aProxyExe, aDatabaseFile: TFileName;
      aPort: integer = DUCKDBPROXY_DEFAULT_PORT; const aOptions: RawUtf8 = '';
      aStartTimeoutMS: integer = 30000): TSqlDBDuckDBProxyConnectionProperties;
    /// release the connections, then stop the owned duckdbproxy.exe process
    destructor Destroy; override;
    /// the duckdbproxy.exe process ID, if launched via CreateWithProcess
    property ProcessID: cardinal
      read fProcessID;
    {$endif OSWINDOWS}
  end;


implementation


{ TSqlDBDuckDBProxyConnectionProperties }

constructor TSqlDBDuckDBProxyConnectionProperties.Create(
  const aServerName, aDatabaseName, aUserID, aPassWord: RawUtf8);
begin
  inherited Create(aServerName, aDatabaseName, aUserID, aPassWord);
  ForcedSchemaName := 'main'; // DuckDB default schema, for GetFields()
  // BindArray() is executed server-side in one round-trip
  fBatchSendingAbilities := fBatchSendingAbilities + [cCreate, cUpdate, cDelete];
end;

{$ifdef OSWINDOWS}

class function TSqlDBDuckDBProxyConnectionProperties.CreateWithProcess(
  const aProxyExe, aDatabaseFile: TFileName; aPort: integer;
  const aOptions: RawUtf8; aStartTimeoutMS: integer): TSqlDBDuckDBProxyConnectionProperties;
var
  key: TAesBlock;
  pass, port, db: RawUtf8;
  pi: TWinProcessInfo;
  sock: TNetSocket;
  endtix: Int64;
begin
  Random128(@key); // cryptographic random password, for this launch only
  pass := BinToHexLower(@key, SizeOf(key));
  FillZero(key);
  port := Int32ToUtf8(aPort);
  if aDatabaseFile = '' then
    db := ':memory:'
  else
    db := StringToUtf8(aDatabaseFile);
  // RunProcess-like options = DETACHED_PROCESS: no console, even from a GUI
  if RunCommandWin(Utf8ToString(FormatUtf8('"%" "%" -port % -parentpid % %',
       [aProxyExe, db, port, GetCurrentProcessId, aOptions])), {waitfor=}false,
       pi, Utf8ToString(DUCKDBPROXY_PASSWORD_ENV + '=' + pass + #0),
       [roEnvAddExisting]) <> 0 then
    ESqlDBRemote.RaiseUtf8('%.CreateWithProcess: cannot execute %',
      [self, aProxyExe]);
  try
    // wait until the proxy accepts TCP connections - with no exception
    endtix := GetTickCount64 + aStartTimeoutMS;
    repeat
      if NewSocket('127.0.0.1', port, nlTcp, {bind=}false, 200, 0, 0, 0,
           sock) = nrOk then
      begin
        sock.ShutdownAndClose(false);
        break;
      end;
      if EnumProcessName(pi.dwProcessId) = '' then
        ESqlDBRemote.RaiseUtf8('%.CreateWithProcess: % terminated early',
          [self, aProxyExe]);
      if GetTickCount64 > endtix then
        ESqlDBRemote.RaiseUtf8('%.CreateWithProcess: no answer on port % after %ms',
          [self, port, aStartTimeoutMS]);
      SleepHiRes(100);
    until false;
    result := Create('127.0.0.1:' + port, DUCKDBPROXY_DEFAULT_NAME,
      DUCKDBPROXY_DEFAULT_NAME, pass);
  except
    KillProcess(pi.dwProcessId, 5);
    raise;
  end;
  result.fProcessID := pi.dwProcessId;
end;

destructor TSqlDBDuckDBProxyConnectionProperties.Destroy;
begin
  try
    inherited Destroy; // send cQuit and close the socket first
  finally
    if fProcessID <> 0 then
      // WM_QUIT is handled by duckdbproxy to checkpoint and close the file
      if not QuitProcess(fProcessID, {waitseconds=}10) then
        KillProcess(fProcessID, 5);
  end;
end;

{$endif OSWINDOWS}


end.
