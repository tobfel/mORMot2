/// regression tests for the mormot.app.aclpolicy unit
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit test.app.aclpolicy;

interface

{$I ..\src\mormot.defines.inc}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.os.security,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.test,
  mormot.app.aclpolicy;

type
  /// regression tests for TAclPolicy YAML parsing, rules and enforcement
  TTestAppAclPolicy = class(TSynTestCase)
  protected
    procedure LoadYaml(const Params: array of const);
  published
    /// validate the YAML policy parsing into TAclPolicyRule
    procedure ParsePolicy;
    /// validate the most specific rule lookup and exclusions
    procedure MatchRules;
    /// validate that invalid policies are rejected
    procedure InvalidPolicies;
    {$ifdef OSWINDOWS}
    /// validate actual NTFS ACL checking and fixing in a temporary folder
    procedure WindowsEnforce;
    {$endif OSWINDOWS}
  end;


implementation

const
  POLICY_YAML =
    'settings:'#10 +
    '  takeOwnership: false'#10 +
    'rules:'#10 +
    '  - name: Projects'#10 +
    '    path: ''C:\Data\Projects\'''#10 +
    '    kind: folder'#10 +
    '    inheritance: false'#10 +
    '    ace:'#10 +
    '      - allow: SY'#10 +
    '        rights: full'#10 +
    '      - deny: BG'#10 +
    '        rights: write'#10 +
    '        flags: OI CI'#10 +
    '      - ''(A;OICI;0x1200a9;;;BU)'''#10 +
    '    exclude:'#10 +
    '      - ''*.tmp'''#10 +
    '      - ''Archive'''#10 +
    '      - ''Sub\Data*'''#10 +
    '  - path: ''C:\Data\Projects\secret.ini'''#10 +
    '    kind: file'#10 +
    '    inheritance: false'#10 +
    '    owner: BA'#10 +
    '    ace:'#10 +
    '      - allow: BA'#10 +
    '        rights: full'#10 +
    '  - path: ''C:\Data\Projects\Public'''#10 +
    '    mode: ignore'#10 +
    '  - path: ''C:\Data\Projects\Flat'''#10 +
    '    kind: folder'#10 +
    '    mode: audit'#10 +
    '    recurse: false'#10 +
    '    strict: false'#10 +
    '    ace:'#10 +
    '      - allow: WD'#10 +
    '        rights: readexecute'#10;


{ TTestAppAclPolicy }

procedure TTestAppAclPolicy.LoadYaml(const Params: array of const);
var
  p: TAclPolicy;
  yaml: RawUtf8;
begin
  Check(VarRecToUtf8IsString(Params[0], yaml));
  p := TAclPolicy.Create;
  try
    p.LoadFromYaml(yaml);
  finally
    p.Free;
  end;
end;

// the rules paths are normalized with the native path delimiter
function NativePath(const Path: RawUtf8): RawUtf8;
begin
  result := StringReplaceChars(Path, '\', PathDelim);
end;

procedure TTestAppAclPolicy.ParsePolicy;
var
  p: TAclPolicy;
  r: TAclPolicyRule;
begin
  p := TAclPolicy.Create;
  try
    p.LoadFromYaml(POLICY_YAML);
    Check(not p.TakeOwnership);
    CheckEqual(length(p.Rules), 4);
    // rules are sorted by descending path length
    CheckEqual(p.Rules[0].Name, NativePath('C:\Data\Projects\secret.ini'));
    r := p.Rules[3];
    CheckEqual(r.Name, 'Projects');
    Check(r.Kind = apkFolder);
    Check(r.Mode = apmEnforce);
    Check(r.Recurse);
    Check(not r.Inheritance);
    Check(r.Strict);
    Check(r.Owner = '');
    CheckEqual(length(r.Aces), 3);
    Check(r.Aces[0].AceType = satAccessAllowed);
    Check(r.Aces[0].Flags = [safObjectInherit, safContainerInherit]);
    Check(PCardinal(@r.Aces[0].Mask)^ = SAR_FILE_ALL_ACCESS);
    Check(r.Aces[0].Sid = KnownRawSid(wksLocalSystem));
    Check(r.Aces[1].AceType = satAccessDenied);
    Check(r.Aces[1].Flags = [safObjectInherit, safContainerInherit]);
    Check(PCardinal(@r.Aces[1].Mask)^ = SAR_FILE_GENERIC_WRITE);
    Check(r.Aces[1].Sid = KnownRawSid(wksBuiltinGuests));
    Check(PCardinal(@r.Aces[2].Mask)^ = $1200a9);
    Check(r.Aces[2].Sid = KnownRawSid(wksBuiltinUsers));
    CheckEqual(length(r.Excludes), 3);
    // file rule: no default inheritance flags, owner
    r := p.Rules[0];
    Check(r.Kind = apkFile);
    Check(not r.Recurse);
    Check(r.Owner = KnownRawSid(wksBuiltinAdministrators));
    CheckEqual(length(r.Aces), 1);
    Check(r.Aces[0].Flags = []);
    // non-recursive and non-strict audit rule
    r := p.Rules[2];
    Check(r.Mode = apmAudit);
    Check(not r.Recurse);
    Check(not r.Strict);
    Check(r.Inheritance);
    Check(r.Aces[0].Sid = KnownRawSid(wksWorld));
    // ignore rule always covers its sub-tree
    r := p.Rules[1];
    Check(r.Mode = apmIgnore);
    Check(r.Recurse);
  finally
    p.Free;
  end;
end;

procedure TTestAppAclPolicy.MatchRules;
var
  p: TAclPolicy;

  function Find(const Path: RawUtf8): RawUtf8;
  var
    r: TAclPolicyRule;
  begin
    r := p.FindRule(Utf8ToString(NativePath(Path)));
    if r = nil then
      result := ''
    else
      result := r.Name;
  end;

  function Excluded(const Path: RawUtf8): boolean;
  begin
    // IsExcluded() expects a normalized uppercase path on Windows
    {$ifdef OSWINDOWS}
    result := p.Rules[3].IsExcluded(UpperCaseUnicode(Path));
    {$else}
    result := p.Rules[3].IsExcluded(NativePath(Path));
    {$endif OSWINDOWS}
  end;

begin
  p := TAclPolicy.Create;
  try
    p.LoadFromYaml(POLICY_YAML);
    // the most specific rule wins
    CheckEqual(Find('C:\Data\Projects'), 'Projects');
    CheckEqual(Find('C:\Data\Projects\'), 'Projects');
    CheckEqual(Find('C:\Data\Projects\a.txt'), 'Projects');
    CheckEqual(Find('C:\Data\Projects\Sub\b.txt'), 'Projects');
    CheckEqual(Find('C:\Data\Projects\secret.ini'),
      NativePath('C:\Data\Projects\secret.ini'));
    CheckEqual(Find('C:\Data\Projects\Public\x\y'),
      NativePath('C:\Data\Projects\Public'));
    CheckEqual(Find('C:\Data\Projects\Flat'), NativePath('C:\Data\Projects\Flat'));
    // a non-recursive rule does not apply to its content
    CheckEqual(Find('C:\Data\Projects\Flat\c.txt'), 'Projects');
    CheckEqual(Find('C:\Data\Projects2'), '');
    CheckEqual(Find('C:\Data'), '');
    {$ifdef OSWINDOWS}
    CheckEqual(Find('c:\data\projects\SUB\B.TXT'), 'Projects');
    CheckEqual(Find('c:\data\projects\Secret.INI'), 'C:\Data\Projects\secret.ini');
    {$endif OSWINDOWS}
    // exclusions are relative to the rule root
    Check(not Excluded('C:\Data\Projects'));
    Check(not Excluded('C:\Data\Projects\a.txt'));
    Check(not Excluded('C:\Data\Projects\Sub\b.txt'));
    Check(Excluded('C:\Data\Projects\a.tmp'));
    Check(Excluded('C:\Data\Projects\Sub\b.tmp'));
    Check(Excluded('C:\Data\Projects\Archive'));
    Check(Excluded('C:\Data\Projects\Archive\x\y.txt'));
    Check(Excluded('C:\Data\Projects\Sub\Data'));
    Check(Excluded('C:\Data\Projects\Sub\Database\z.txt'));
    Check(not Excluded('C:\Data\Projects\Data\z.txt'));
    Check(not Excluded('C:\Data\Projects\Archived.txt'));
  finally
    p.Free;
  end;
end;

procedure TTestAppAclPolicy.InvalidPolicies;
begin
  CheckRaised(LoadYaml, ['rules: ['], EAclPolicy, 'yaml');
  CheckRaised(LoadYaml, ['settings:'#10'  server: x'], EAclPolicy, 'norules');
  CheckRaised(LoadYaml, ['rules:'#10'  - kind: file'], EAclPolicy, 'nopath');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    mode: deny'],
    EAclPolicy, 'mode');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    kind: disk'],
    EAclPolicy, 'kind');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    ace:'#10 +
    '      - ''(X;;FA;;;SY)'''], EAclPolicy, 'sddl');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    ace:'#10 +
    '      - allow: SY'], EAclPolicy, 'rights');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    ace:'#10 +
    '      - allow: S-1-X'#10'        rights: full'], EAclPolicy, 'sid');
  // 'SYX' is no 'SY' alias, and no account name on any system
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    ace:'#10 +
    '      - allow: SYX'#10'        rights: full'], EAclPolicy, 'alias');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    owner: SYX'],
    EAclPolicy, 'owner');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'    inheritance: false'],
    EAclPolicy, 'denyall');
  CheckRaised(LoadYaml, ['rules:'#10'  - path: x'#10'  - path: x\'],
    EAclPolicy, 'duplicated');
end;

{$ifdef OSWINDOWS}

procedure TTestAppAclPolicy.WindowsEnforce;
var
  p: TAclPolicy;
  folder: TFileName;
  stats: TAclPolicyStats;
  sd: TSecurityDescriptor;
begin
  folder := TemporaryFileName;
  DeleteFile(folder);
  folder := EnsureDirectoryExists(folder, ESynException);
  try
    Check(FileFromString('a', folder + 'a.txt'));
    Check(FileFromString('b', folder + 'b.tmp'));
    Check(FileFromString('c', folder + 'secret.ini'));
    p := TAclPolicy.Create;
    try
      p.Log := nil;
      p.LoadFromYaml(FormatUtf8(
        'rules:'#10 +
        '  - path: ''%'''#10 +
        '    inheritance: false'#10 +
        '    ace:'#10 +
        '      - ''(A;OICI;FA;;;SY)'''#10 +
        '      - ''(A;OICI;FA;;;WD)'''#10 +
        '    exclude:'#10 +
        '      - ''*.tmp'''#10 +
        '  - path: ''%secret.ini'''#10 +
        '    inheritance: false'#10 +
        '    ace:'#10 +
        '      - ''(A;;FA;;;WD)'''#10, [folder, folder]));
      // the temporary folder inherits its ACL: the root is a violation
      stats := p.Run(apaCheck);
      CheckEqual(stats[apsError], 0, 'check error');
      Check(stats[apsViolation] >= 2, 'check violation');
      CheckEqual(stats[apsFixed], 0, 'check fixed');
      CheckEqual(stats[apsExcluded], 1, 'check excluded');
      // fix the ACLs
      stats := p.Run(apaFix);
      CheckEqual(stats[apsError], 0, 'fix error');
      CheckEqual(stats[apsFixFailed], 0, 'fix failed');
      Check(stats[apsFixed] >= 2, 'fixed');
      // now everything should match the policy
      stats := p.Run(apaCheck);
      CheckEqual(stats[apsViolation], 0, 'recheck violation');
      CheckEqual(stats[apsOk], 3, 'recheck ok');
      CheckEqual(stats[apsExcluded], 1, 'recheck excluded');
      // an explicit ACE on a nested file is a violation, e.g. after a move
      sd.Clear;
      Check(sd.Add(satAccessAllowed, 'BG', 'FR') <> nil, 'add');
      Check(SetSystemSecurityDescriptor(folder + 'a.txt', sd, [sdiDacl]), 'set');
      stats := p.CheckPath(folder + 'a.txt', apaCheck);
      CheckEqual(stats[apsViolation], 1, 'nested violation');
      stats := p.CheckPath(folder + 'a.txt', apaFix);
      CheckEqual(stats[apsFixed], 1, 'nested fixed');
      stats := p.CheckPath(folder + 'a.txt', apaCheck);
      CheckEqual(stats[apsOk], 1, 'nested ok');
    finally
      p.Free;
    end;
  finally
    DirectoryDelete(folder, FILES_ALL, {deletenested=}true);
    RemoveDir(folder);
  end;
end;

{$endif OSWINDOWS}


end.
