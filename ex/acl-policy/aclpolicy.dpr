/// Check, Fix and Watch Windows NTFS ACLs from a YAML Policy
// - this program is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
program aclpolicy;

{
  *****************************************************************************

  Command-Line Tool using mormot.app.aclpolicy
  - e.g.   aclpolicy policy.yaml            check and report violations
           aclpolicy policy.yaml /fix       check and fix violations
           aclpolicy policy.yaml /fix /watch  then watch the folders
  - exit code is 0 if no violation remains, 1 otherwise, 2 on fatal error
  - should be run as Administrator to read and write any ACL
  - details are logged into a aclpolicy.log file next to the executable

  *****************************************************************************
}

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
  {$R ..\..\src\mormot.win.admin.manifest.res}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  classes,
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.log,
  mormot.app.aclpolicy;

type
  TAclPolicyConsole = class
  public
    procedure OnResult(Sender: TAclPolicy; const Result: TAclPolicyResult);
  end;

const
  STATUS_COLOR: array[TAclPolicyStatus] of TConsoleColor = (
    ccLightGreen, ccYellow, ccLightCyan, ccLightRed, ccLightRed, ccDarkGray);
  STATUS_TEXT: array[TAclPolicyStatus] of RawUtf8 = (
    'ok', 'violation', 'fixed', 'fix failed', 'error', 'excluded');

procedure TAclPolicyConsole.OnResult(Sender: TAclPolicy;
  const Result: TAclPolicyResult);
begin
  ConsoleWrite(['[', STATUS_TEXT[Result.Status], '] ', Result.Path, ' ',
    Result.Message], STATUS_COLOR[Result.Status]);
end;

var
  c: TExecutableCommandLine;
  source: TFileName;
  action: TAclPolicyAction;
  watch, verbose: boolean;
  policy: TAclPolicy;
  console: TAclPolicyConsole;
  stats: TAclPolicyStats;
  {$ifdef OSWINDOWS}
  watcher: TAclPolicyWatcher;
  {$endif OSWINDOWS}
begin
  // validate command line parameters
  c := Executable.Command;
  source := c.ArgFile(0, 'YAML #policy file name', {optional=}false);
  if c.Option('&fix', 'fix any violation (default is to only report)') then
    action := apaFix
  else
    action := apaCheck;
  watch := c.Option('&watch', 'watch the folders until [Enter] is pressed');
  verbose := c.Option('&verbose', 'report also valid and excluded items');
  if c.ConsoleHelpFailed('mORMot ' + SYNOPSE_FRAMEWORK_VERSION +
                         ' NTFS ACL Policy Tool') then
  begin
    ExitCode := 2;
    exit;
  end;
  with TSynLog.Family do
  begin
    Level := LOG_STACKTRACE + [sllInfo, sllWarning];
    if verbose then
      Level := Level + [sllDebug];
    PerThreadLog := ptIdentifiedInOneFile;
  end;
  console := TAclPolicyConsole.Create;
  policy := TAclPolicy.Create;
  try
    try
      policy.LoadFromYamlFile(source);
      policy.OnResult := console.OnResult;
      if verbose then
        policy.Report := [low(TAclPolicyStatus)..high(TAclPolicyStatus)];
      stats := policy.Run(action);
      ConsoleWrite('%: % checked, % ok, % violation(s), % fixed, ' +
        '% fix failed, % error(s), % excluded', [source,
        stats[apsOk] + stats[apsViolation] + stats[apsFixed] +
        stats[apsFixFailed] + stats[apsError], stats[apsOk],
        stats[apsViolation], stats[apsFixed], stats[apsFixFailed],
        stats[apsError], stats[apsExcluded]]);
      if stats[apsViolation] + stats[apsFixFailed] + stats[apsError] <> 0 then
        ExitCode := 1;
      {$ifdef OSWINDOWS}
      if watch then
      begin
        watcher := TAclPolicyWatcher.Create(policy, action);
        try
          watcher.Start;
          ConsoleWrite('Watching... press [Enter] to quit', ccWhite);
          ConsoleWaitForEnterKey;
        finally
          watcher.Free;
        end;
      end;
      {$else}
      if watch then
        ConsoleWrite('/watch is supported on Windows only', ccLightRed);
      {$endif OSWINDOWS}
    except
      on E: Exception do
      begin
        ConsoleShowFatalException(E, {waitforenterkey=}false);
        ExitCode := 2;
      end;
    end;
  finally
    policy.Free;
    console.Free;
  end;
end.
