/// Check and Enforce Windows File System ACL Policies Defined as YAML
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.app.aclpolicy;

{
  *****************************************************************************

   Windows NTFS ACL Policy Checker, Fixer and Watcher
    - TAclPolicyRule Definition of one Folder or File Policy Rule
    - TAclPolicy YAML Policy Loading, Checking and Enforcing
    - TAclPolicyWatcher Live Folder Watching and Enforcement

  *****************************************************************************

  Expected YAML layout (all names are case-insensitive):

  settings:
    server: ''              # optional server used to resolve account names
    takeOwnership: false    # take ownership if the DACL can't be written
  rules:
    - name: Projects        # optional, used in reports
      path: 'D:\Data\Projects'
      kind: folder          # folder (default if path is a directory) | file
      mode: enforce         # enforce (default) | audit | ignore
      owner: BA             # optional SID, SDDL alias or 'DOMAIN\Account'
      inheritance: false    # false = protected DACL, true (default) = inherit
      recurse: true         # check sub-items: they should only inherit
      strict: true          # explicit ACEs not listed are a violation
      ace:
        - allow: SY         # allow | deny + SID, SDDL alias or account name
          rights: full      # full|modify|readexecute|read|write or SDDL mask
          flags: OICI       # SDDL inheritance flags - default OICI on folders
        - allow: 'CORP\Project-Readers'
          rights: readexecute
        - '(A;OICI;FA;;;BA)' # or any raw SDDL ACE text
      exclude:              # exceptions, relative to path (glob patterns)
        - '*.tmp'           # a pattern without \ also matches any item name
        - 'Archive'         # an excluded folder is skipped with its content
    - path: 'D:\Data\Projects\secret.ini'   # the most specific rule wins
      kind: file
      inheritance: false
      ace:
        - allow: SY
          rights: full
        - allow: BA
          rights: full
    - path: 'D:\Data\Projects\Public'       # an exception sub-tree
      mode: ignore

  Paths should be written between single quotes in YAML, since backslashes
  are escape characters within double quotes.
  Use specific rights (e.g. FA) rather than generic rights (e.g. GA) for
  inheritable ACEs, since Windows splits generic rights into two ACEs.
}

interface

{$I ..\mormot.defines.inc}

uses
  {$ifdef OSWINDOWS}
  Windows, // for ReadDirectoryChangesW() and file API constants
  {$endif OSWINDOWS}
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.os.security,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.search,
  mormot.core.fmt,
  mormot.core.log;


{ ************ TAclPolicyRule Definition of one Folder or File Policy Rule }

type
  /// exception class raised by this unit
  EAclPolicy = class(ESynException);

  /// how a TAclPolicyRule should be applied
  // - apmEnforce will report and fix any violation (if requested)
  // - apmAudit will only report violations, but never fix them
  // - apmIgnore defines an exception: the path and its content are skipped
  TAclPolicyMode = (
    apmEnforce,
    apmAudit,
    apmIgnore);

  /// the kind of resource a TAclPolicyRule applies to
  TAclPolicyKind = (
    apkFolder,
    apkFile);

  /// define one rule of a TAclPolicy, as defined in the YAML "rules:" array
  TAclPolicyRule = class
  protected
    fName: RawUtf8;
    fPath: TFileName;
    fPathUpper: RawUtf8;
    fPathPrefix: RawUtf8;
    fKind: TAclPolicyKind;
    fMode: TAclPolicyMode;
    fRecurse: boolean;
    fInheritance: boolean;
    fStrict: boolean;
    fOwner: RawSid;
    fAces: TSecAcl;
    fExcludes: TRawUtf8DynArray; // owns the TMatch patterns memory
    fExcludeMatch: TMatchDynArray;
    fExcludeName: TBooleanDynArray; // pattern with no PathDelim
  public
    /// check if this rule applies to a given uppercase path
    // - returns true for the rule root itself, or any nested item if Recurse
    function Covers(const UpperPath: RawUtf8): boolean;
    /// check if a given uppercase path is excluded from this rule
    // - i.e. if the path or one of its parent folders match an exclusion
    // - this method is thread-safe and won't allocate any memory
    function IsExcluded(const UpperPath: RawUtf8): boolean;
    /// the rule name, or the path if no name was supplied
    property Name: RawUtf8
      read fName;
    /// the root folder or file of this rule
    property Path: TFileName
      read fPath;
    /// if this rule applies to a folder or a single file
    property Kind: TAclPolicyKind
      read fKind;
    /// how this rule is applied
    property Mode: TAclPolicyMode
      read fMode;
    /// if all nested files and folders are part of this rule
    // - those sub-items are expected to inherit their ACL with no explicit ACE
    property Recurse: boolean
      read fRecurse;
    /// false if the root DACL is expected to be protected from inheritance
    property Inheritance: boolean
      read fInheritance;
    /// if any explicit ACE not part of the rule should be reported
    // - if false, only missing ACEs (or protection state) are violations
    property Strict: boolean
      read fStrict;
    /// the expected owner SID of the root - '' if not checked
    property Owner: RawSid
      read fOwner;
    /// the expected explicit ACEs of the root
    property Aces: TSecAcl
      read fAces;
    /// the exception patterns, relative to Path, normalized as uppercase
    property Excludes: TRawUtf8DynArray
      read fExcludes;
  end;

  /// the TAclPolicyRule instances of a TAclPolicy
  TAclPolicyRuleObjArray = array of TAclPolicyRule;


{ ************ TAclPolicy YAML Policy Loading, Checking and Enforcing }

type
  /// what TAclPolicy should do about a violation
  TAclPolicyAction = (
    apaCheck,
    apaFix);

  /// the state of one item, as reported by TAclPolicy
  // - apsOk: the item ACL matches its rule
  // - apsViolation: the item ACL does not match its rule (and was not fixed)
  // - apsFixed: the item ACL was not correct, but has been fixed
  // - apsFixFailed: the item ACL was not correct, and could not be fixed
  // - apsError: the item ACL could not be read
  // - apsExcluded: the item is an exception of its rule, so was skipped
  TAclPolicyStatus = (
    apsOk,
    apsViolation,
    apsFixed,
    apsFixFailed,
    apsError,
    apsExcluded);

  /// a set of item states
  TAclPolicyStatuses = set of TAclPolicyStatus;

  /// the information about one checked item, as reported by TAclPolicy
  TAclPolicyResult = record
    /// the file or folder name
    Path: TFileName;
    /// the rule which applied to this item
    Rule: TAclPolicyRule;
    /// the state of this item
    Status: TAclPolicyStatus;
    /// true if this item is the Rule root, false if it is a nested item
    IsRoot: boolean;
    /// the item security descriptor as SDDL text before any fix
    // - only set on violation
    Actual: RawUtf8;
    /// human-readable description of the differences, or of the error
    Message: RawUtf8;
  end;

  /// the counters of a TAclPolicy process, indexed by item state
  TAclPolicyStats = array[TAclPolicyStatus] of integer;

  TAclPolicy = class;

  /// event handler called by TAclPolicy for each reported item
  // - may be called from several TAclPolicyWatcher threads, but TAclPolicy
  // ensures that only one callback is executed at a time
  TOnAclPolicyResult = procedure(Sender: TAclPolicy;
    const Result: TAclPolicyResult) of object;

  /// load, check and enforce a Windows file system ACL policy
  // - the policy is defined as YAML - see this unit header for its layout
  // - the most specific rule (i.e. the longest path) applies to each item, so
  // you can define a folder rule, then a file rule with its own ACL, then
  // "mode: ignore" rules or "exclude:" patterns for exceptions
  // - checking and fixing are implemented on Windows only, using the
  // TSecurityDescriptor wrapper and privileges of mormot.core.os.security
  // - violations and fixes are also logged via the Log class
  TAclPolicy = class
  protected
    fRules: TAclPolicyRuleObjArray;
    fServer: RawUtf8;
    fTakeOwnership: boolean;
    fOnResult: TOnAclPolicyResult;
    fReport: TAclPolicyStatuses;
    fStats: TAclPolicyStats;
    fLog: TSynLogClass;
    fSafe: TOSLock;
    function ParseSid(const Text: RawUtf8; out Sid: RawSid): boolean;
    function ParseAce(const Value: variant; Kind: TAclPolicyKind): RawUtf8;
    function ParseRule(Doc: PDocVariantData; Index: PtrInt): TAclPolicyRule;
    function FindRuleUpper(const UpperPath: RawUtf8): TAclPolicyRule;
    procedure Notify(var Res: TAclPolicyResult);
    procedure NotifyExcluded(const Path: TFileName; Rule: TAclPolicyRule);
    procedure ProcessItem(const Path: TFileName; Rule: TAclPolicyRule;
      IsRoot, IsFolder: boolean; Action: TAclPolicyAction);
    procedure ProcessFolder(const Folder: TFileName; Rule: TAclPolicyRule;
      Action: TAclPolicyAction);
    procedure ProcessPath(const Path: TFileName; Action: TAclPolicyAction;
      WithContent: boolean);
    procedure ProcessRules(Action: TAclPolicyAction);
  public
    /// initialize an empty policy
    constructor Create; virtual;
    /// finalize this policy and its rules
    destructor Destroy; override;
    /// remove all rules
    procedure Clear;
    /// load the policy from its YAML text
    // - raise EAclPolicy on any invalid content
    procedure LoadFromYaml(const Yaml: RawUtf8);
    /// load the policy from a YAML file
    // - raise EAclPolicy on any invalid content
    procedure LoadFromYamlFile(const FileName: TFileName);
    /// find the rule applying to a given file or folder
    // - returns nil if no rule applies
    function FindRule(const Path: TFileName): TAclPolicyRule;
    /// check (and fix if Action=apaFix) all rules, with their nested items
    // - returns the counters of this process
    function Run(Action: TAclPolicyAction): TAclPolicyStats;
    /// check (and fix if Action=apaFix) a single file or folder
    // - if WithContent is true and Path is a folder, its content is processed
    // - returns the counters of this process
    function CheckPath(const Path: TFileName; Action: TAclPolicyAction;
      WithContent: boolean = false): TAclPolicyStats;
    /// reset the Stats counters
    procedure ResetStats;
    /// the rules of this policy, sorted by descending path length
    property Rules: TAclPolicyRuleObjArray
      read fRules;
    /// the server used to resolve account names into SID, as "settings: server:"
    property Server: RawUtf8
      read fServer write fServer;
    /// if ownership should be taken when the DACL cannot be written
    // - as "settings: takeOwnership:" in the YAML
    property TakeOwnership: boolean
      read fTakeOwnership write fTakeOwnership;
    /// the counters since the last ResetStats call
    property Stats: TAclPolicyStats
      read fStats;
    /// which item states should trigger OnResult and logging
    // - default is all states but apsOk and apsExcluded
    property Report: TAclPolicyStatuses
      read fReport write fReport;
    /// the event handler called for each reported item
    property OnResult: TOnAclPolicyResult
      read fOnResult write fOnResult;
    /// the logging class used for reported items - default is TSynLog
    property Log: TSynLogClass
      read fLog write fLog;
  end;


{ ************ TAclPolicyWatcher Live Folder Watching and Enforcement }

{$ifdef OSWINDOWS}

type
  TAclPolicyWatcher = class;

  /// one thread watching a folder for TAclPolicyWatcher
  TAclPolicyWatcherThread = class(TThread)
  protected
    fOwner: TAclPolicyWatcher;
    fFolder: TFileName;
    fFolderPrefix: RawUtf8;
    fSubTree: boolean;
    fHandle: THandle;
    procedure Execute; override;
    procedure ProcessAll;
  public
    /// open the folder handle and start watching
    constructor Create(aOwner: TAclPolicyWatcher; const aFolder: TFileName;
      aSubTree: boolean);
    /// abort the pending ReadDirectoryChangesW() call and wait for the thread
    procedure Shutdown;
  end;

  /// watch the folders of a TAclPolicy, and check or fix any modified item
  // - use ReadDirectoryChangesW() so that new, renamed or moved items, and
  // any security change are processed as soon as they occur
  // - if some notifications were lost, the whole folder is processed again
  // - requires Windows Vista or later, for CancelIoEx()
  TAclPolicyWatcher = class
  protected
    fPolicy: TAclPolicy;
    fAction: TAclPolicyAction;
    fThreads: array of TAclPolicyWatcherThread;
  public
    /// initialize the watcher - call Start to actually watch the folders
    constructor Create(aPolicy: TAclPolicy; aAction: TAclPolicyAction);
    /// finalize the watcher, calling Stop if needed
    destructor Destroy; override;
    /// start one thread per folder to be watched
    procedure Start;
    /// stop all watching threads
    procedure Stop;
    /// the associated policy
    property Policy: TAclPolicy
      read fPolicy;
    /// the action applied to each modified item
    property Action: TAclPolicyAction
      read fAction;
  end;

{$endif OSWINDOWS}


implementation


{ ************ TAclPolicyRule Definition of one Folder or File Policy Rule }

const
  // ACE inheritance flags which make no sense on files
  SAF_INHERIT = [
    safObjectInherit,
    safContainerInherit,
    safNoPropagateInherit,
    safInheritOnly];
  // ACE types which should be stored first in a canonical ACL
  SAT_DENIED = [
    satAccessDenied,
    satObjectAccessDenied,
    satCallbackAccessDenied];

function NormalizePath(const Path: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  result := TrimU(Path);
  for i := 1 to length(result) do
    if result[i] in ['\', '/'] then
      result[i] := PathDelim;
  // remove any trailing delimiter, but not from a root like 'D:\' or '/'
  while (length(result) > 1) and
        (result[length(result)] = PathDelim) and
        not ((length(result) = 3) and
             (result[2] = ':')) do
    SetLength(result, length(result) - 1);
end;

function UpperPath(const Path: RawUtf8): RawUtf8;
begin
  {$ifdef OSWINDOWS}
  result := UpperCaseUnicode(Path); // Windows file names are case-insensitive
  {$else}
  result := Path; // allow cross-platform policy validation and tests
  {$endif OSWINDOWS}
end;

function AceIsEqual(const a, b: TSecAce; IsFolder: boolean): boolean;
var
  fa, fb: TSecAceFlags;
begin
  fa := a.Flags - [safInherited];
  fb := b.Flags - [safInherited];
  if not IsFolder then
  begin
    fa := fa - SAF_INHERIT;
    fb := fb - SAF_INHERIT;
  end;
  result := (a.AceType = b.AceType) and
            (fa = fb) and
            (a.Mask = b.Mask) and
            (a.Sid = b.Sid) and
            (a.Opaque = b.Opaque) and
            IsEqualGuid(a.ObjectType, b.ObjectType) and
            IsEqualGuid(a.InheritedObjectType, b.InheritedObjectType);
end;

// search an ACE, ignoring the inherited ACEs of acl[]
function AclHasExplicit(const acl: TSecAcl; const ace: TSecAce;
  IsFolder: boolean): boolean;
var
  i: PtrInt;
begin
  result := true;
  for i := 0 to length(acl) - 1 do
    if not (safInherited in acl[i].Flags) and
       AceIsEqual(acl[i], ace, IsFolder) then
      exit;
  result := false;
end;

procedure AclAdd(var acl: TSecAcl; const ace: TSecAce);
var
  n: PtrInt;
begin
  n := length(acl);
  SetLength(acl, n + 1);
  acl[n] := ace;
end;

procedure AppendAce(var Text: RawUtf8; const Prefix: RawUtf8; const ace: TSecAce);
var
  s: ShortString;
  tmp: TSynTempAdder;
  sddl: RawUtf8;
begin
  s[0] := #0;
  tmp.Init;
  ace.AppendAsText(s, tmp, nil, nil);
  tmp.Done(sddl);
  AppendLine(Text, [Prefix, sddl], '; ');
end;

// the binary ACL, with canonical order: explicit deny ACEs first
// - an empty ACL is a valid header with no ACE (no access), not a NULL DACL
function AclToBinary(const acl: TSecAcl; IsFolder: boolean): RawByteString;
var
  sorted: TSecAcl;
  denied: boolean;
  i: PtrInt;
  hdr: TRawAcl;
begin
  sorted := nil;
  for denied := true downto false do
    for i := 0 to length(acl) - 1 do
      if (acl[i].AceType in SAT_DENIED) = denied then
        if IsFolder then
          AclAdd(sorted, acl[i])
        else if not (safInheritOnly in acl[i].Flags) then
        begin
          AclAdd(sorted, acl[i]); // inheritance flags are useless on files
          with sorted[length(sorted) - 1] do
            Flags := Flags - SAF_INHERIT;
        end;
  if sorted <> nil then
  begin
    result := SecAclToBinary(sorted);
    exit;
  end;
  FillCharFast(hdr, SizeOf(hdr), 0);
  hdr.AclRevision := 2; // ACL_REVISION
  hdr.AclSize := SizeOf(hdr);
  FastSetRawByteString(result, @hdr, SizeOf(hdr));
end;


{ TAclPolicyRule }

function TAclPolicyRule.Covers(const UpperPath: RawUtf8): boolean;
begin
  result := (UpperPath = fPathUpper) or
            (fRecurse and
             StartWithExact(UpperPath, fPathPrefix));
end;

function TAclPolicyRule.IsExcluded(const UpperPath: RawUtf8): boolean;
var
  rel, name, p: PUtf8Char;
  i, len: PtrInt;
  m: TMatch;
begin
  result := false;
  len := length(UpperPath) - length(fPathPrefix);
  if (fExcludeMatch = nil) or
     (len <= 0) then
    exit; // the rule root itself is never excluded
  rel := PUtf8Char(pointer(UpperPath)) + length(fPathPrefix);
  name := rel;
  p := rel;
  // check each parent folder, then the item itself: 'A', 'A\B', 'A\B\C'
  repeat
    inc(p);
    if (p^ = PathDelim) or
       (p^ = #0) then
    begin
      for i := 0 to length(fExcludeMatch) - 1 do
      begin
        m := fExcludeMatch[i]; // local copy for thread-safety
        if fExcludeName[i] then
          result := m.Match(name, p - name) // 'NAME' or '*.TMP'
        else
          result := m.Match(rel, p - rel);  // 'SUB\NAME'
        if result then
          exit;
      end;
      if p^ = #0 then
        exit;
      name := p + 1;
    end;
  until false;
end;


{ ************ TAclPolicy YAML Policy Loading, Checking and Enforcing }

{ TAclPolicy }

constructor TAclPolicy.Create;
begin
  inherited Create;
  fSafe.Init;
  fLog := TSynLog;
  fReport := [low(TAclPolicyStatus)..high(TAclPolicyStatus)] -
             [apsOk, apsExcluded];
end;

destructor TAclPolicy.Destroy;
begin
  Clear;
  fSafe.Done;
  inherited Destroy;
end;

procedure TAclPolicy.Clear;
var
  i: PtrInt;
begin
  for i := 0 to length(fRules) - 1 do
    fRules[i].Free;
  fRules := nil;
end;

// SDDL parsing of the whole text: SddlNextSid() would accept 'BUILTIN\Users'
// as 'BU' since it only reads the first two chars of an alias
function SddlToSid(const Text: RawUtf8; out Sid: RawSid): boolean;
var
  p: PUtf8Char;
begin
  p := pointer(Text);
  result := (p <> nil) and
            SddlNextSid(p, Sid, nil) and
            (p^ = #0);
end;

function TAclPolicy.ParseSid(const Text: RawUtf8; out Sid: RawSid): boolean;
begin
  // SDDL alias like 'BA' or 'SY', or 'S-1-5-32-544' text
  result := SddlToSid(Text, Sid);
  {$ifdef OSWINDOWS}
  // account name like 'BUILTIN\Users', 'CORP\Readers' or 'user@corp.com'
  if not result then
    result := SddlToSid(LookupName(fServer, Text), Sid);
  {$endif OSWINDOWS}
end;

const
  // map some user-friendly rights to their file access SDDL masks
  RIGHTS_NAME: array[0..5] of RawUtf8 = (
    'FULL', 'MODIFY', 'READEXECUTE', 'RX', 'READ', 'WRITE');
  RIGHTS_SDDL: array[0..5] of RawUtf8 = (
    'FA', '0x1301bf', '0x1200a9', '0x1200a9', 'FR', 'FW');

function TAclPolicy.ParseAce(const Value: variant; Kind: TAclPolicyKind): RawUtf8;
var
  v: PDocVariantData;
  typ: AnsiChar;
  account, rights, flags: RawUtf8;
  sid: RawSid;
  i: PtrInt;
begin
  if not _SafeObject(Value, v) then
  begin
    VariantToUtf8(Value, result); // raw SDDL ACE text, e.g. '(A;OICI;FA;;;SY)'
    result := TrimU(result);
    exit;
  end;
  // structured ACE: allow/deny + rights + flags
  result := '';
  if v^.GetAsRawUtf8('allow', account) then
    typ := 'A'
  else if v^.GetAsRawUtf8('deny', account) then
    typ := 'D'
  else
    exit;
  if not ParseSid(TrimU(account), sid) then
    raise EAclPolicy.CreateUtf8('Unknown account %', [account]);
  rights := TrimU(v^.U['rights']);
  if rights = '' then
    exit;
  for i := 0 to high(RIGHTS_NAME) do
    if IdemPropNameU(rights, RIGHTS_NAME[i]) then
    begin
      rights := RIGHTS_SDDL[i];
      break;
    end;
  if not v^.GetAsRawUtf8('flags', flags) then
    if Kind = apkFolder then
      flags := 'OICI'
    else
      flags := '';
  flags := UpperCase(flags);
  for i := length(flags) downto 1 do
    if not (flags[i] in ['A'..'Z']) then // allow 'OI CI', 'OI,CI' or 'OI|CI'
      delete(flags, i, 1);
  if flags = 'NONE' then
    flags := '';
  result := FormatUtf8('(%;%;%;;;%)', [typ, flags, rights, RawSidToText(sid)]);
end;

function TAclPolicy.ParseRule(Doc: PDocVariantData; Index: PtrInt): TAclPolicyRule;
var
  s: RawUtf8;
  arr: PDocVariantData;
  sd: TSecurityDescriptor;
  i: PtrInt;
begin
  result := TAclPolicyRule.Create;
  try
    // path and kind
    s := NormalizePath(Doc^.U['path']);
    if s = '' then
      raise EAclPolicy.CreateUtf8('rules[%]: missing path', [Index]);
    result.fPath := Utf8ToString(s);
    result.fPathUpper := UpperPath(s);
    if result.fPathUpper[length(result.fPathUpper)] = PathDelim then
      result.fPathPrefix := result.fPathUpper // e.g. 'D:\'
    else
      result.fPathPrefix := result.fPathUpper + PathDelim;
    if not Doc^.GetAsRawUtf8('name', result.fName) then
      result.fName := s;
    s := Doc^.U['kind'];
    if s = '' then
      if FileExists(result.fPath) then
        result.fKind := apkFile
      else
        result.fKind := apkFolder // default even if not existing (yet)
    else if IdemPropNameU(s, 'file') then
      result.fKind := apkFile
    else if IdemPropNameU(s, 'folder') or
            IdemPropNameU(s, 'directory') then
      result.fKind := apkFolder
    else
      raise EAclPolicy.CreateUtf8('rules[%]: unknown kind=%', [Index, s]);
    // mode
    s := Doc^.U['mode'];
    if (s = '') or
       IdemPropNameU(s, 'enforce') then
      result.fMode := apmEnforce
    else if IdemPropNameU(s, 'audit') then
      result.fMode := apmAudit
    else if IdemPropNameU(s, 'ignore') then
      result.fMode := apmIgnore
    else
      raise EAclPolicy.CreateUtf8('rules[%]: unknown mode=%', [Index, s]);
    // boolean options - an ignore rule always applies to the whole folder
    if (result.fMode = apmIgnore) or
       not Doc^.GetAsBoolean('recurse', result.fRecurse) then
      result.fRecurse := true;
    result.fRecurse := result.fRecurse and
                       (result.fKind = apkFolder);
    if not Doc^.GetAsBoolean('inheritance', result.fInheritance) then
      result.fInheritance := true;
    if not Doc^.GetAsBoolean('strict', result.fStrict) then
      result.fStrict := true;
    // owner
    s := TrimU(Doc^.U['owner']);
    if (s <> '') and
       not ParseSid(s, result.fOwner) then
      raise EAclPolicy.CreateUtf8('rules[%]: unknown owner=%', [Index, s]);
    // explicit ACEs, validated and decoded by TSecurityDescriptor
    sd.Clear;
    if Doc^.GetAsArray('ace', arr) then
      for i := 0 to arr^.Count - 1 do
        if sd.Add(ParseAce(arr^.Values[i], result.fKind)) = nil then
          raise EAclPolicy.CreateUtf8('rules[%]: invalid ace[%] in %',
            [Index, i, result.fName]);
    result.fAces := sd.Dacl;
    if (result.fMode <> apmIgnore) and
       (result.fAces = nil) and
       not result.fInheritance then
      raise EAclPolicy.CreateUtf8('rules[%]: % would deny all access ' +
        '(no ace with inheritance=false)', [Index, result.fName]);
    // exceptions, prepared once as TMatch
    if Doc^.GetAsArray('exclude', arr) then
      for i := 0 to arr^.Count - 1 do
      begin
        VariantToUtf8(arr^.Values[i], s);
        s := NormalizePath(s);
        if s <> '' then
          AddRawUtf8(result.fExcludes, UpperPath(s));
      end;
    SetLength(result.fExcludeMatch, length(result.fExcludes));
    SetLength(result.fExcludeName, length(result.fExcludes));
    for i := 0 to length(result.fExcludes) - 1 do
    begin
      result.fExcludeMatch[i].Prepare(result.fExcludes[i],
        {caseinsensitive=}false, {reuse=}true);
      result.fExcludeName[i] := PosExChar(PathDelim, result.fExcludes[i]) = 0;
    end;
  except
    result.Free;
    raise;
  end;
end;

procedure TAclPolicy.LoadFromYaml(const Yaml: RawUtf8);
var
  doc: TDocVariantData;
  settings, rules, rule: PDocVariantData;
  i, j: PtrInt;
  r: TAclPolicyRule;
begin
  Clear;
  try
    YamlToVariant(Yaml, doc);
  except
    on E: EYamlException do
      raise EAclPolicy.CreateUtf8('Invalid YAML: %', [E.Message]);
  end;
  if doc.GetAsObject('settings', settings) then
  begin
    fServer := settings^.U['server'];
    fTakeOwnership := settings^.B['takeOwnership'];
  end;
  if not doc.GetAsArray('rules', rules) then
    raise EAclPolicy.Create('No rules: array in the YAML policy');
  try
    for i := 0 to rules^.Count - 1 do
    begin
      if not _SafeObject(rules^.Values[i], rule) then
        raise EAclPolicy.CreateUtf8('rules[%] is not an object', [i]);
      r := ParseRule(rule, i);
      // insert sorted by descending path length: the most specific rule first
      j := length(fRules);
      SetLength(fRules, j + 1);
      while (j > 0) and
            (length(fRules[j - 1].fPathUpper) < length(r.fPathUpper)) do
      begin
        fRules[j] := fRules[j - 1];
        dec(j);
      end;
      fRules[j] := r;
      while (j > 0) and
            (length(fRules[j - 1].fPathUpper) = length(r.fPathUpper)) do
      begin
        dec(j);
        if fRules[j].fPathUpper = r.fPathUpper then
          raise EAclPolicy.CreateUtf8('rules[%]: duplicated path %',
            [i, r.fPath]);
      end;
    end;
  except
    Clear;
    raise;
  end;
end;

procedure TAclPolicy.LoadFromYamlFile(const FileName: TFileName);
var
  yaml: RawUtf8;
begin
  yaml := StringFromFile(FileName);
  if yaml = '' then
    raise EAclPolicy.CreateUtf8('Missing or void file %', [FileName]);
  LoadFromYaml(yaml);
end;

function TAclPolicy.FindRuleUpper(const UpperPath: RawUtf8): TAclPolicyRule;
var
  i: PtrInt;
begin
  for i := 0 to length(fRules) - 1 do
  begin
    result := fRules[i];
    if result.Covers(UpperPath) then
      exit; // rules are sorted: the first is the most specific
  end;
  result := nil;
end;

function TAclPolicy.FindRule(const Path: TFileName): TAclPolicyRule;
begin
  result := FindRuleUpper(UpperPath(NormalizePath(StringToUtf8(Path))));
end;

procedure TAclPolicy.ResetStats;
begin
  fSafe.Lock;
  FillCharFast(fStats, SizeOf(fStats), 0);
  fSafe.UnLock;
end;

const
  STATUS_LOG: array[TAclPolicyStatus] of TSynLogLevel = (
    sllDebug,    // apsOk
    sllWarning,  // apsViolation
    sllInfo,     // apsFixed
    sllError,    // apsFixFailed
    sllError,    // apsError
    sllDebug);   // apsExcluded
  STATUS_TXT: array[TAclPolicyStatus] of RawUtf8 = (
    'Ok', 'Violation', 'Fixed', 'FixFailed', 'Error', 'Excluded');

procedure TAclPolicy.Notify(var Res: TAclPolicyResult);
begin
  fSafe.Lock;
  try
    inc(fStats[Res.Status]);
    if not (Res.Status in fReport) then
      exit;
    if fLog <> nil then
      fLog.Add.Log(STATUS_LOG[Res.Status], '% % [%] %',
        [STATUS_TXT[Res.Status], Res.Path, Res.Rule.fName, Res.Message], self);
    if Assigned(fOnResult) then
      fOnResult(self, Res);
  finally
    fSafe.UnLock;
  end;
end;

procedure TAclPolicy.NotifyExcluded(const Path: TFileName; Rule: TAclPolicyRule);
var
  res: TAclPolicyResult;
begin
  res.Path := Path;
  res.Rule := Rule;
  res.Status := apsExcluded;
  res.IsRoot := false;
  Notify(res);
end;

{$ifdef OSWINDOWS}

const
  SE_FILE_OBJECT = 1;
  OWNER_SECURITY_INFORMATION = $00000001;
  DACL_SECURITY_INFORMATION = $00000004;
  UNPROTECTED_DACL_SECURITY_INFORMATION = $20000000;
  PROTECTED_DACL_SECURITY_INFORMATION = $80000000;
  // privileges to read and write any ACL as administrator
  ACL_PRIVILEGES = [wspBackup, wspRestore, wspTakeOwnership, wspSecurity];

// GetSystemSecurityDescriptor() is used for reading, but its writing
// counterpart can't change the DACL protection state, so we call the API
function SetNamedSecurityInfoW(pObjectName: PWideChar; ObjectType,
  SecurityInfo: cardinal; psidOwner, psidGroup: pointer;
  pDacl, pSacl: pointer): DWord; stdcall; external advapi32;

function SetFileSecurity(const Path: TFileName; info: cardinal;
  const Owner: RawSid; const Dacl: RawByteString): cardinal;
var
  tmp: TW32Temp;
begin
  // note: on a folder, the API propagates inheritable ACEs to its content
  result := SetNamedSecurityInfoW(W32(Path, tmp), SE_FILE_OBJECT, info,
    pointer(Owner), nil, pointer(Dacl), nil);
end;

{$endif OSWINDOWS}

procedure TAclPolicy.ProcessItem(const Path: TFileName; Rule: TAclPolicyRule;
  IsRoot, IsFolder: boolean; Action: TAclPolicyAction);
var
  res: TAclPolicyResult;
  {$ifdef OSWINDOWS}
  sd: TSecurityDescriptor;
  expected, fixed: TSecAcl;
  dacl: RawByteString;
  owner: RawSid;
  info, err: cardinal;
  i: PtrInt;
  {$endif OSWINDOWS}
begin
  res.Path := Path;
  res.Rule := Rule;
  res.IsRoot := IsRoot;
  res.Status := apsError;
  {$ifdef OSWINDOWS}
  if not GetSystemSecurityDescriptor(Path, sd, [sdiOwner, sdiDacl],
           nrtFile, {privileges=}[]) then // enabled once by the caller
  begin
    res.Message := FormatUtf8('cannot read: %', [GetErrorText(GetLastError)]);
    Notify(res);
    exit;
  end;
  // nested items should have no explicit ACE and inherit from the root
  info := UNPROTECTED_DACL_SECURITY_INFORMATION;
  if IsRoot then
  begin
    expected := Rule.fAces;
    owner := Rule.fOwner;
    if not Rule.fInheritance then
      info := PROTECTED_DACL_SECURITY_INFORMATION;
  end;
  // compare the expected and actual state
  if not (scDaclPresent in sd.Flags) then
    AppendLine(res.Message, ['NULL DACL (everyone has full access)'], '; ')
  else if (scDaclProtected in sd.Flags) <>
          (info = PROTECTED_DACL_SECURITY_INFORMATION) then
    if scDaclProtected in sd.Flags then
      AppendLine(res.Message, ['inheritance disabled'], '; ')
    else
      AppendLine(res.Message, ['inheritance enabled'], '; ');
  for i := 0 to length(expected) - 1 do
    if not AclHasExplicit(sd.Dacl, expected[i], IsFolder) then
      AppendAce(res.Message, 'missing ', expected[i]);
  if Rule.fStrict then
    for i := 0 to length(sd.Dacl) - 1 do
      if not (safInherited in sd.Dacl[i].Flags) and
         not AclHasExplicit(expected, sd.Dacl[i], IsFolder) then
        AppendAce(res.Message, 'unexpected ', sd.Dacl[i]);
  if (owner <> '') and
     (sd.Owner = owner) then
    owner := '' // nothing to change
  else if owner <> '' then
    AppendLine(res.Message, ['owner ', RawSidToText(sd.Owner),
      ' instead of ', RawSidToText(owner)], '; ');
  if res.Message = '' then
  begin
    res.Status := apsOk;
    Notify(res);
    exit;
  end;
  res.Actual := sd.ToText;
  res.Status := apsViolation;
  if (Action = apaFix) and
     (Rule.fMode = apmEnforce) then
  begin
    // compute the new explicit DACL
    if Rule.fStrict then
      fixed := expected
    else
    begin
      fixed := nil;
      for i := 0 to length(sd.Dacl) - 1 do
        if not (safInherited in sd.Dacl[i].Flags) then
          AclAdd(fixed, sd.Dacl[i]);
      for i := 0 to length(expected) - 1 do
        if not AclHasExplicit(sd.Dacl, expected[i], IsFolder) then
          AclAdd(fixed, expected[i]);
    end;
    dacl := AclToBinary(fixed, IsFolder);
    info := info or DACL_SECURITY_INFORMATION;
    if owner <> '' then
      info := info or OWNER_SECURITY_INFORMATION;
    err := SetFileSecurity(Path, info, owner, dacl);
    if (err = ERROR_ACCESS_DENIED) and
       fTakeOwnership and
       (owner = '') then
    begin
      // as administrator, take ownership then write the DACL
      owner := KnownRawSid(wksBuiltinAdministrators);
      err := SetFileSecurity(Path, info or OWNER_SECURITY_INFORMATION, owner, dacl);
    end;
    if err = 0 then
      res.Status := apsFixed
    else
    begin
      res.Status := apsFixFailed;
      AppendLine(res.Message, ['fix failed: ', GetErrorText(err)], '; ');
    end;
  end;
  {$else}
  res.Message := 'ACL policy is supported on Windows only';
  {$endif OSWINDOWS}
  Notify(res);
end;

function IsLinkItem(const sr: TSearchRec): boolean;
begin
  {$ifdef OSWINDOWS}
  result := sr.FindData.dwFileAttributes and
              FILE_ATTRIBUTE_REPARSE_POINT <> 0;
  {$else}
  result := sr.Attr and faSymLink <> 0;
  {$endif OSWINDOWS}
end;

procedure TAclPolicy.ProcessFolder(const Folder: TFileName;
  Rule: TAclPolicyRule; Action: TAclPolicyAction);
var
  sr: TSearchRec;
  item: TFileName;
  up: RawUtf8;
  r: TAclPolicyRule;
  isfolder: boolean;
begin
  if FindFirst(Folder + PathDelim + '*', faAnyFile, sr) <> 0 then
    exit;
  try
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') or
         IsLinkItem(sr) then // never follow junctions or symbolic links
        continue;
      item := Folder + PathDelim + sr.Name;
      isfolder := sr.Attr and faDirectory <> 0;
      up := UpperPath(StringToUtf8(item));
      r := FindRuleUpper(up);
      if r = Rule then
        if Rule.IsExcluded(up) then
          NotifyExcluded(item, Rule) // skipped with all its content
        else
        begin
          if Rule.fMode <> apmIgnore then
            ProcessItem(item, Rule, {isroot=}false, isfolder, Action);
          if isfolder then
            ProcessFolder(item, Rule, Action);
        end
      else if isfolder and
              not r.fRecurse then
        // a nested non-recursive rule root: its content still belongs to Rule
        ProcessFolder(item, Rule, Action);
      // a nested recursive (or ignore) rule is processed on its own
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure TAclPolicy.ProcessPath(const Path: TFileName;
  Action: TAclPolicyAction; WithContent: boolean);
var
  r: TAclPolicyRule;
  up: RawUtf8;
  isfolder: boolean;
begin
  up := UpperPath(NormalizePath(StringToUtf8(Path)));
  r := FindRuleUpper(up);
  if (r = nil) or
     (r.fMode = apmIgnore) then
    exit;
  isfolder := DirectoryExists(Path);
  if not isfolder and
     not FileExists(Path) then
    exit // deleted in-between
  else if r.IsExcluded(up) then
    NotifyExcluded(Path, r)
  else
  begin
    ProcessItem(Path, r, up = r.fPathUpper, isfolder, Action);
    if WithContent and
       isfolder and
       r.fRecurse then
      ProcessFolder(ExcludeTrailingPathDelimiter(Path), r, Action);
  end;
end;

procedure TAclPolicy.ProcessRules(Action: TAclPolicyAction);
var
  i: PtrInt;
  r: TAclPolicyRule;
begin
  for i := length(fRules) - 1 downto 0 do // from less to most specific
  begin
    r := fRules[i];
    if r.fMode = apmIgnore then
      continue;
    if r.fKind = apkFolder then
      if DirectoryExists(r.fPath) then
      begin
        ProcessItem(r.fPath, r, {isroot=}true, {isfolder=}true, Action);
        if r.fRecurse then
          ProcessFolder(ExcludeTrailingPathDelimiter(r.fPath), r, Action);
      end
      else
        continue
    else if FileExists(r.fPath) then
      ProcessItem(r.fPath, r, {isroot=}true, {isfolder=}false, Action);
  end;
end;

function TAclPolicy.Run(Action: TAclPolicyAction): TAclPolicyStats;
begin
  result := CheckPath('', Action, true);
end;

function TAclPolicy.CheckPath(const Path: TFileName; Action: TAclPolicyAction;
  WithContent: boolean): TAclPolicyStats;
{$ifdef OSWINDOWS}
var
  priv: TSynWindowsPrivileges;
{$endif OSWINDOWS}
begin
  ResetStats;
  {$ifdef OSWINDOWS}
  priv.Init(wttThread);
  try
    priv.Enable(ACL_PRIVILEGES);
  {$endif OSWINDOWS}
    if Path = '' then
      ProcessRules(Action) // from Run()
    else
      ProcessPath(Path, Action, WithContent);
  {$ifdef OSWINDOWS}
  finally
    priv.Done;
  end;
  {$endif OSWINDOWS}
  result := fStats;
end;


{ ************ TAclPolicyWatcher Live Folder Watching and Enforcement }

{$ifdef OSWINDOWS}

const
  FILE_LIST_DIRECTORY = $0001;
  FILE_NOTIFY_FILTER =
    FILE_NOTIFY_CHANGE_FILE_NAME or
    FILE_NOTIFY_CHANGE_DIR_NAME or
    FILE_NOTIFY_CHANGE_SECURITY;
  FILE_ACTION_ADDED = 1;
  FILE_ACTION_MODIFIED = 3;
  FILE_ACTION_RENAMED_NEW_NAME = 5;

type
  // FILE_NOTIFY_INFORMATION - not packed, as in the Windows SDK
  TFileNotifyInformation = record
    NextEntryOffset: cardinal;
    Action: cardinal;
    FileNameLength: cardinal; // in bytes
    FileName: array[0..0] of WideChar;
  end;
  PFileNotifyInformation = ^TFileNotifyInformation;

// explicit definitions to be consistent between Delphi and FPC
function ReadDirectoryChangesW(hDirectory: THandle; lpBuffer: pointer;
  nBufferLength: cardinal; bWatchSubtree: BOOL; dwNotifyFilter: cardinal;
  lpBytesReturned: PCardinal; lpOverlapped, lpCompletionRoutine: pointer): BOOL;
  stdcall; external kernel32;

function CancelIoEx(hFile: THandle; lpOverlapped: pointer): BOOL;
  stdcall; external kernel32;


{ TAclPolicyWatcherThread }

constructor TAclPolicyWatcherThread.Create(aOwner: TAclPolicyWatcher;
  const aFolder: TFileName; aSubTree: boolean);
var
  tmp: TW32Temp;
begin
  fOwner := aOwner;
  fFolder := ExcludeTrailingPathDelimiter(aFolder);
  fFolderPrefix := UpperPath(StringToUtf8(IncludeTrailingPathDelimiter(aFolder)));
  fSubTree := aSubTree;
  fHandle := CreateFileW(W32(fFolder, tmp), FILE_LIST_DIRECTORY,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if fHandle = INVALID_HANDLE_VALUE then
    raise EAclPolicy.CreateUtf8('Cannot watch %: %',
      [fFolder, GetErrorText(GetLastError)]);
  inherited Create({suspended=}false);
end;

procedure TAclPolicyWatcherThread.Shutdown;
begin
  Terminate;
  CancelIoEx(fHandle, nil); // abort any blocking ReadDirectoryChangesW()
  WaitFor;
  CloseHandle(fHandle);
  fHandle := INVALID_HANDLE_VALUE;
end;

procedure TAclPolicyWatcherThread.ProcessAll;
var
  i: PtrInt;
  r: TAclPolicyRule;
begin
  // some notifications were lost: process the folder and the nested rules
  fOwner.fPolicy.ProcessPath(fFolder, fOwner.fAction, {content=}true);
  for i := 0 to length(fOwner.fPolicy.fRules) - 1 do
  begin
    r := fOwner.fPolicy.fRules[i];
    if StartWithExact(r.fPathUpper, fFolderPrefix) then
      fOwner.fPolicy.ProcessPath(r.fPath, fOwner.fAction, {content=}true);
  end;
end;

procedure TAclPolicyWatcherThread.Execute;
var
  buf: array[0..16383] of cardinal; // 64KB, DWORD-aligned as required
  len: cardinal;
  info: PFileNotifyInformation;
  priv: TSynWindowsPrivileges;
begin
  priv.Init(wttThread);
  try
    priv.Enable(ACL_PRIVILEGES);
    while not Terminated do
    begin
      len := 0;
      if not ReadDirectoryChangesW(fHandle, @buf, SizeOf(buf), fSubTree,
           FILE_NOTIFY_FILTER, @len, nil, nil) or
         Terminated then
        break; // e.g. ERROR_OPERATION_ABORTED from Shutdown
      if len = 0 then
      begin
        ProcessAll; // buffer overflow
        continue;
      end;
      info := @buf;
      repeat
        if info^.Action in [FILE_ACTION_ADDED, FILE_ACTION_MODIFIED,
                            FILE_ACTION_RENAMED_NEW_NAME] then
          // a new or moved folder may bring its own content with wrong ACLs
          fOwner.fPolicy.ProcessPath(fFolder + PathDelim + Utf8ToString(
            RawUnicodeToUtf8(@info^.FileName, info^.FileNameLength shr 1)),
            fOwner.fAction, {content=}info^.Action <> FILE_ACTION_MODIFIED);
        if info^.NextEntryOffset = 0 then
          break;
        info := pointer(PAnsiChar(info) + info^.NextEntryOffset);
      until Terminated;
    end;
  except
    on E: Exception do
      if fOwner.fPolicy.fLog <> nil then
        fOwner.fPolicy.fLog.Add.Log(sllError, 'Watching % aborted: %',
          [fFolder, E.Message], self);
  end;
  priv.Done;
end;


{ TAclPolicyWatcher }

constructor TAclPolicyWatcher.Create(aPolicy: TAclPolicy;
  aAction: TAclPolicyAction);
begin
  inherited Create;
  fPolicy := aPolicy;
  fAction := aAction;
end;

destructor TAclPolicyWatcher.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TAclPolicyWatcher.Start;
var
  i, j, n: PtrInt;
  r, o: TAclPolicyRule;
  folders: TFileNameDynArray;
  uppers: TRawUtf8DynArray;
  subtree: TBooleanDynArray;
begin
  Stop;
  // compute the folders to watch: one per rule root, or file rule parent
  n := 0;
  SetLength(folders, length(fPolicy.fRules));
  SetLength(uppers, length(fPolicy.fRules));
  SetLength(subtree, length(fPolicy.fRules));
  for i := 0 to length(fPolicy.fRules) - 1 do
  begin
    r := fPolicy.fRules[i];
    if r.fMode = apmIgnore then
      continue;
    if r.fKind = apkFile then
      folders[n] := ExtractFileDir(r.fPath)
    else
      folders[n] := r.fPath;
    uppers[n] := UpperPath(NormalizePath(StringToUtf8(folders[n])));
    subtree[n] := r.fRecurse;
    // a folder within a recursive rule is already watched by this rule
    for j := 0 to length(fPolicy.fRules) - 1 do
    begin
      o := fPolicy.fRules[j];
      if (o <> r) and
         (o.fMode <> apmIgnore) and
         o.fRecurse and
         o.Covers(uppers[n]) and
         ((o.fPathUpper <> uppers[n]) or
          not r.fRecurse) then
      begin
        uppers[n] := '';
        break;
      end;
    end;
    // a file rule may share its parent folder with another rule
    for j := 0 to n - 1 do
      if uppers[j] = uppers[n] then
      begin
        subtree[j] := subtree[j] or subtree[n];
        uppers[n] := '';
        break;
      end;
    if (uppers[n] <> '') and
       DirectoryExists(folders[n]) then
      inc(n);
  end;
  // start one thread per folder
  SetLength(fThreads, n);
  for i := 0 to n - 1 do
    fThreads[i] := TAclPolicyWatcherThread.Create(self, folders[i], subtree[i]);
end;

procedure TAclPolicyWatcher.Stop;
var
  i: PtrInt;
begin
  for i := 0 to length(fThreads) - 1 do
    if fThreads[i] <> nil then
    begin
      fThreads[i].Shutdown;
      FreeAndNil(fThreads[i]);
    end;
  fThreads := nil;
end;

{$endif OSWINDOWS}


end.
