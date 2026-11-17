/// minimal THttpProxyServer relaying to php-fpm, for benchmarking only
// - usage: fcgiproxy <port> <fcgi://...> [threads] [verbose]
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
  mormot.net.proxy;

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
    settings.AddFastCgi(StringToUtf8(ParamStr(2)));
    proxy := THttpProxyServer.Create(settings);
    try
      proxy.Start;
      ConsoleWrite('listening on % -> % (% threads)',
        [settings.Server.Port, ParamStr(2), settings.Server.ThreadCount]);
      ConsoleWaitForEnterKey; // also handles SIGTERM/SIGINT on POSIX
    finally
      proxy.Free;
    end;
  finally
    settings.Free;
  end;
end.
