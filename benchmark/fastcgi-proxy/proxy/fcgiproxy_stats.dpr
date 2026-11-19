/// minimal THttpProxyServer relaying to php-fpm, for benchmarking only
// - usage: fcgiproxy <port> <fcgi://...> [threads] [verbose]
// - set FCGI_INDEX=index.php to enable the front controller (PR #810)
program fcgiproxy;

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.log,
  mormot.net.sock,
  mormot.net.async,
  mormot.net.proxy;

type // class crackers to access protected fields for statistics
  TUrlHack = class(THttpProxyUrl);
  TConnHack = class(TAsyncConnections);
  TPollHack = class(TPollAsyncConnection);

procedure WriteStats(proxy: THttpProxyServer);
var
  f: TConnHack;
  i, cap: PtrInt;
begin
  f := TConnHack(TUrlHack(proxy.Url[0]).fFastCgi);
  cap := 0;
  f.fGC1.Safe.Lock;
  for i := 0 to f.fGC1.Count - 1 do
    inc(cap, TPollHack(f.fGC1.Items[i]).fRd.Capacity + TPollHack(f.fGC1.Items[i]).fWr.Capacity);
  f.fGC1.Safe.UnLock;
  f.fGC2.Safe.Lock;
  for i := 0 to f.fGC2.Count - 1 do
    inc(cap, TPollHack(f.fGC2.Items[i]).fRd.Capacity + TPollHack(f.fGC2.Items[i]).fWr.Capacity);
  f.fGC2.Safe.UnLock;
  ConsoleWrite('fastcgi: active=% gc1=% gc2=% gcRdBufMB=%',
    [f.ConnectionCount, f.fGC1.Count, f.fGC2.Count, cap shr 20]);
end;

var
  settings: THttpProxyServerSettings;
  proxy: THttpProxyServer;
begin
  if ParamStr(4) <> '' then
    with TSynLog.Family do
    begin
      Level := LOG_VERBOSE;
      PerThreadLog := ptIdentifiedInOneFile;
    end;
  settings := THttpProxyServerSettings.Create;
  try
    settings.Server.Port := StringToUtf8(ParamStr(1));
    settings.Server.ThreadCount := StrToIntDef(ParamStr(3), 4);
    settings.Server.Options := [psoExcludeDateHeader, psoDisableGzip];
    {$ifdef HASFASTCGIINDEX}
    settings.AddFastCgi(StringToUtf8(ParamStr(2))).FastCgiIndex :=
      StringToUtf8(GetEnvironmentVariable('FCGI_INDEX'));
    {$else}
    settings.AddFastCgi(StringToUtf8(ParamStr(2)));
    {$endif HASFASTCGIINDEX}
    proxy := THttpProxyServer.Create(settings);
    try
      proxy.Start;
      ConsoleWrite('listening on % -> % (% threads)',
        [settings.Server.Port, ParamStr(2), settings.Server.ThreadCount]);
      if GetEnvironmentVariable('STATS') <> '' then
      begin
        SynDaemonIntercept;
        while SynDaemonTerminated = 0 do
        begin
          SleepHiRes(1000);
          WriteStats(proxy);
        end;
      end
      else
        ConsoleWaitForEnterKey; // also handles SIGTERM/SIGINT on POSIX
    finally
      proxy.Free;
    end;
  finally
    settings.Free;
  end;
end.
