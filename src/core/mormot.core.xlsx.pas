/// Framework Core Office Open XML Spreadsheet (XLSX) Reader/Writer
// - extension unit for the mORMot 2 Open Source framework
// - licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.core.xlsx;

{
  *****************************************************************************

   XLSX (ECMA-376 / ISO 29500 SpreadsheetML) Reading/Writing as TDocVariant
    - TXlsxDocument Class Implementing TTabularDocument for XLSX
    - Low-Level XLSX Helper Functions
    - High-Level XLSX Wrapper Functions

   Pure mORMot implementation, with no external dependency:
    - .zip container via mormot.core.zip TZipRead/TZipWrite
    - XML parsing via mormot.core.fmt TXmlParser (pull/SAX and Consume API)
    - XML writing via TTextWriter and AddXmlEscape()

   Reading features:
    - shared strings, inline strings, rich text runs (phonetic runs ignored)
    - numbers as Int64 or double, booleans, errors as text (e.g. '#DIV/0!')
    - date/time detection from built-in and custom number formats, and
      1900/1904 date systems - returned as varDate (or text if tboDateAsText)
    - cached formula results (formulas themselves are not evaluated)
    - sparse rows/columns are padded, single sheet or all sheets at once
   Writing features:
    - one or several sheets, shared strings table (deduplicated via hashing)
    - typed cells: number, boolean, date/time (with date format), text
    - optional bold header, frozen header row, auto-filter, column widths

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  classes,
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.buffers,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.fmt,
  mormot.core.zip,
  mormot.core.tabular;


{ ************ TXlsxDocument Class Implementing TTabularDocument for XLSX }

type
  /// exception raised by TXlsxDocument on invalid or unsupported input
  EXlsxException = class(ETabularException);

  /// XLSX-specific writing options for TXlsxDocument
  // - xoHeaderBold: write the header row (tboHeader) with a bold font
  // - xoFreezeHeader: freeze the header row, so that it stays visible
  // - xoAutoFilter: enable the auto-filter drop-downs on the header row
  // - xoAutoWidth: compute the column widths from their text content
  TXlsxOption = (
    xoHeaderBold,
    xoFreezeHeader,
    xoAutoFilter,
    xoAutoWidth);

  /// set of XLSX-specific options for TXlsxDocument
  TXlsxOptions = set of TXlsxOption;

  /// information about one sheet of a XLSX workbook
  TXlsxSheet = record
    /// the sheet name, as displayed in the tab
    Name: RawUtf8;
    /// the path of the sheet XML part within the .zip container
    Path: RawUtf8;
    /// true if this sheet is hidden or veryHidden
    Hidden: boolean;
  end;

  /// information about the sheets of a XLSX workbook
  TXlsxSheetDynArray = array of TXlsxSheet;

  /// the cell types as stored in a XLSX sheet 't' attribute
  TXlsxCellType = (
    xctNumber,
    xctShared,
    xctInline,
    xctFormulaString,
    xctBoolean,
    xctError,
    xctIsoDate);

const
  /// default TXlsxDocument writing options
  XLSX_DEFAULT = [xoHeaderBold, xoFreezeHeader, xoAutoWidth];

type
  /// XLSX reader/writer over TDocVariant arrays, using only mORMot units
  // - reading returns the first sheet (or SheetName/SheetIndex) as a
  // TDocVariant array of rows, or all sheets via LoadSheets() as a TDocVariant
  // object of {"sheetname": [rows...]}
  // - writing expects a TDocVariant array of rows (one sheet named SheetName),
  // or a TDocVariant object of {"sheetname": [rows...]} for several sheets
  // ! var x: TXlsxDocument;
  // !     doc: variant;
  // ! begin
  // !   x := TXlsxDocument.Create([tboHeader, tboSkipEmptyRows]);
  // !   try
  // !     x.LoadFromFile('input.xlsx', doc);       // first sheet
  // !     x.XlsxOptions := [xoHeaderBold, xoAutoFilter];
  // !     x.SaveToFile(doc, 'output.xlsx');
  // !   finally
  // !     x.Free;
  // !   end;
  TXlsxDocument = class(TTabularDocument)
  protected
    // reading context
    fZip: TZipRead;
    fZipData: RawByteString;
    fWorkbookPath: RawUtf8;
    fSheets: TXlsxSheetDynArray;
    fSharedPath, fStylesPath: RawUtf8;
    fShared: TRawUtf8DynArray;
    fSharedCount: integer;
    fDateStyle: TBooleanDynArray;
    fDate1904: boolean;
    fSheetName: RawUtf8;
    fSheetIndex: integer;
    // writing context
    fXlsxOptions: TXlsxOptions;
    fMaxColumnWidth: integer;
    fSst: TRawUtf8DynArray;
    fSstCount, fSstTotal: integer;
    fSstHash: TDynArrayHashed;
    fSheetXml, fSheetNames, fSheetFilter: TRawUtf8DynArray;
    fSheetCount: integer;
    fRowNum, fColMax: integer;
    fWidths: TIntegerDynArray;
    fHasHeader: boolean;
    // reading methods
    procedure OpenZip(const Data: RawByteString);
    procedure CloseZip;
    function ZipText(const Path: RawUtf8; Mandatory: boolean): RawUtf8;
    procedure ReadWorkbook;
    procedure ReadSharedStrings;
    procedure ReadStyles;
    procedure ReadSheet(const Xml: RawUtf8);
    function SheetToRead: integer;
    procedure Parse(const Data: RawByteString); override;
    // writing methods
    function SharedString(const Text: RawUtf8): integer;
    procedure WriteCellRef(Col: integer);
    procedure WriteCell(Col: integer; const Value: variant; Style: integer);
    procedure WriteSheetBegin(const Name: RawUtf8);
    procedure WriteSheetEnd;
    procedure WriteSheet(const Name: RawUtf8; const Rows: TDocVariantData);
    procedure WriteBegin; override;
    procedure WriteHeader(const Names: TRawUtf8DynArray; Count: integer); override;
    procedure WriteRow(const Cells: TTabularCells; Count: integer); override;
    function WriteEnd: RawByteString; override;
    function DoSave(const Doc: TDocVariantData): RawByteString; override;
  public
    /// initialize this instance with the default options
    constructor Create(aOptions: TTabularOptions = TABULAR_DEFAULT); override;
    /// finalize this instance
    destructor Destroy; override;
    /// retrieve the sheets information of a XLSX content
    function GetSheets(const Data: RawByteString): TXlsxSheetDynArray;
    /// retrieve the sheet names of a XLSX content
    function GetSheetNames(const Data: RawByteString): TRawUtf8DynArray;
    /// parse all sheets of a XLSX content as a TDocVariant object
    // - returns {"sheet1name": [rows...], "sheet2name": [rows...], ...}
    // - IncludeHidden=false would ignore hidden sheets
    procedure LoadSheets(const Data: RawByteString; var Doc: variant;
      IncludeHidden: boolean = true);
    /// parse all sheets of a XLSX file as a TDocVariant object
    procedure LoadSheetsFromFile(const FileName: TFileName; var Doc: variant;
      IncludeHidden: boolean = true);
    /// the sheet name to be read by Load(), or written by Save() of an array
    // - if not set, Load() will use SheetIndex, and Save() will use 'Sheet1'
    property SheetName: RawUtf8
      read fSheetName write fSheetName;
    /// the 0-based sheet index to be read by Load(), if SheetName is not set
    property SheetIndex: integer
      read fSheetIndex write fSheetIndex;
    /// XLSX-specific writing options - default is XLSX_DEFAULT
    property XlsxOptions: TXlsxOptions
      read fXlsxOptions write fXlsxOptions;
    /// the maximum column width (in characters) computed by xoAutoWidth
    // - default is 60
    property MaxColumnWidth: integer
      read fMaxColumnWidth write fMaxColumnWidth;
    /// if the last parsed workbook uses the 1904 date system (old Mac Excel)
    property Date1904: boolean
      read fDate1904;
  end;


{ ************ Low-Level XLSX Helper Functions }

/// convert a 0-based column index into its XLSX letters, e.g. 0='A', 27='AB'
function XlsxColumnName(Col: integer): RawUtf8;

/// convert a XLSX cell reference into its 0-based column index
// - e.g. 'A1' = 0, 'AB12' = 27 - returns -1 if no letter was found
function XlsxColumnIndex(Ref: PUtf8Char; RefLen: PtrInt): integer;

/// convert a XLSX serial date number into a TDateTime
// - handles the 1900 leap year bug, and the 1904 date system
function XlsxSerialToDateTime(Serial: double; Date1904: boolean = false): TDateTime;

/// convert a TDateTime into a XLSX serial date number (1900 date system)
function DateTimeToXlsxSerial(Value: TDateTime): double;

/// returns true if a XLSX number format code is a date/time format
// - e.g. 'yyyy-mm-dd', 'dd/mm/yy hh:mm' or '[h]:mm:ss' but not '0.00' nor
// '"Total "0' (quoted text and [..] sections are ignored)
function XlsxIsDateFormat(const Code: RawUtf8): boolean;

/// returns true if a XLSX built-in number format ID is a date/time format
function XlsxIsBuiltinDateFormat(NumFmtId: integer): boolean;

/// decode the XLSX _xHHHH_ escaped characters of some text
function XlsxUnescape(const Text: RawUtf8): RawUtf8;

/// encode some text with XLSX _xHHHH_ escapes for invalid XML characters
// - control chars (excluding TAB/CR/LF) are encoded, and any existing
// _xHHHH_ pattern is protected as _x005F_xHHHH_
function XlsxEscape(const Text: RawUtf8): RawUtf8;

/// make a valid XLSX sheet name: no []:*?/\ chars, not void, max 31 chars
function XlsxSheetName(const Name: RawUtf8; Index: integer): RawUtf8;


{ ************ High-Level XLSX Wrapper Functions }

/// parse a XLSX content sheet into a TDocVariant array of rows
// - if SheetName is '', the first sheet is returned
function XlsxToVariant(const Xlsx: RawByteString;
  Options: TTabularOptions = TABULAR_DEFAULT; const SheetName: RawUtf8 = ''): variant;

/// parse all sheets of a XLSX content as {"sheetname": [rows...], ...}
function XlsxSheetsToVariant(const Xlsx: RawByteString;
  Options: TTabularOptions = TABULAR_DEFAULT): variant;

/// parse a XLSX content sheet into a JSON array of rows
function XlsxToJson(const Xlsx: RawByteString;
  Options: TTabularOptions = TABULAR_DEFAULT; const SheetName: RawUtf8 = '';
  Format: TTextWriterJsonFormat = jsonCompact): RawUtf8;

/// serialize a TDocVariant array of rows (or object of sheets) as XLSX
function VariantToXlsx(const Doc: variant;
  Options: TTabularOptions = TABULAR_DEFAULT;
  XlsxOptions: TXlsxOptions = XLSX_DEFAULT): RawByteString;

/// serialize a JSON array of rows (or object of sheets) as XLSX
function JsonToXlsx(const Json: RawUtf8;
  Options: TTabularOptions = TABULAR_DEFAULT;
  XlsxOptions: TXlsxOptions = XLSX_DEFAULT): RawByteString;


implementation


{ ************ Low-Level XLSX Helper Functions }

function XlsxColumnName(Col: integer): RawUtf8;
var
  tmp: array[0..7] of AnsiChar;
  i: PtrInt;
begin
  i := high(tmp);
  repeat
    tmp[i] := AnsiChar(ord('A') + Col mod 26);
    dec(i);
    Col := Col div 26 - 1;
  until Col < 0;
  FastSetString(result, @tmp[i + 1], high(tmp) - i);
end;

function XlsxColumnIndex(Ref: PUtf8Char; RefLen: PtrInt): integer;
var
  c: AnsiChar;
begin
  result := 0;
  while RefLen > 0 do
  begin
    c := Ref^;
    if c in ['a'..'z'] then
      dec(c, 32);
    if not (c in ['A'..'Z']) then
      break;
    result := result * 26 + (ord(c) - ord('A') + 1);
    inc(Ref);
    dec(RefLen);
  end;
  dec(result); // returns -1 if no letter
end;

function XlsxSerialToDateTime(Serial: double; Date1904: boolean): TDateTime;
begin
  if Date1904 then
    result := Serial + 1462
  else if (Serial >= 1) and
          (Serial < 61) then
    // Excel considers 1900 as a leap year (Lotus 1-2-3 compatibility):
    // serial 1 = 1900-01-01 but TDateTime 1 = 1899-12-31
    result := Serial + 1
  else
    result := Serial; // TDateTime and Excel share the 1899-12-30 epoch
end;

function DateTimeToXlsxSerial(Value: TDateTime): double;
begin
  if (Value >= 2) and
     (Value < 61) then
    result := Value - 1
  else
    result := Value;
end;

function XlsxIsBuiltinDateFormat(NumFmtId: integer): boolean;
begin
  case NumFmtId of
    14..22, 27..36, 45..47, 50..58, 71..81:
      result := true;
  else
    result := false;
  end;
end;

function XlsxIsDateFormat(const Code: RawUtf8): boolean;
var
  P: PUtf8Char;
begin
  result := false;
  P := pointer(Code);
  if P = nil then
    exit;
  while P^ <> #0 do
  begin
    case P^ of
      '"':
        begin
          // skip "quoted text"
          repeat
            inc(P);
          until (P^ = #0) or
                (P^ = '"');
          if P^ = #0 then
            exit;
        end;
      '\', '_', '*':
        begin
          // skip \escaped char, _ spacing and * fill chars
          inc(P);
          if P^ = #0 then
            exit;
        end;
      '[':
        begin
          // [h] [mm] [ss] elapsed time is a date/time - [Red] [$-409] are not
          inc(P);
          if P^ in ['h', 'H', 'm', 'M', 's', 'S'] then
          begin
            result := true;
            exit;
          end;
          while (P^ <> #0) and
                (P^ <> ']') do
            inc(P);
          if P^ = #0 then
            exit;
        end;
      'd', 'D', 'm', 'M', 'y', 'Y', 'h', 'H', 's', 'S', 'e':
        if (P^ = 'e') and
           (P <> pointer(Code)) and
           (P[-1] in ['0'..'9', '#', '?', '.']) then
          // 0.00e+00 scientific notation is not a date
        else if P^ <> 'e' then
        begin
          result := true;
          exit;
        end;
      'G', 'g':
        if IdemPChar(P, 'GENERAL') then
          inc(P, 6);
    end;
    inc(P);
  end;
end;

function XlsxUnescape(const Text: RawUtf8): RawUtf8;
var
  P, PEnd, S: PUtf8Char;
  code: cardinal;
  i: PtrInt;
  tmp: array[0..7] of AnsiChar;
  ok: boolean;
begin
  result := Text;
  P := pointer(Text);
  if (P = nil) or
     (PosEx('_x', Text) = 0) then
    exit; // fast path
  result := '';
  PEnd := P + length(Text);
  S := P;
  while P < PEnd do
  begin
    if (P^ = '_') and
       (PEnd - P >= 7) and
       (P[1] = 'x') and
       (P[6] = '_') then
    begin
      code := 0;
      ok := true;
      for i := 2 to 5 do
        case P[i] of
          '0'..'9':
            code := code shl 4 + cardinal(ord(P[i]) - ord('0'));
          'a'..'f':
            code := code shl 4 + cardinal(ord(P[i]) - (ord('a') - 10));
          'A'..'F':
            code := code shl 4 + cardinal(ord(P[i]) - (ord('A') - 10));
        else
          begin
            ok := false;
            break;
          end;
        end;
      if ok then
      begin
        Append(result, S, P - S);
        Append(result, @tmp, Ucs4ToUtf8(code, @tmp));
        inc(P, 7);
        S := P;
        continue;
      end;
    end;
    inc(P);
  end;
  Append(result, S, P - S);
end;

function XlsxEscape(const Text: RawUtf8): RawUtf8;
const
  XHEX: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  P, PEnd, S: PUtf8Char;
  needed: boolean;
begin
  result := Text;
  P := pointer(Text);
  if P = nil then
    exit;
  PEnd := P + length(Text);
  needed := false;
  while P < PEnd do
  begin
    if ((P^ < ' ') and
        not (P^ in [#9, #10, #13])) or
       ((P^ = '_') and
        (P[1] = 'x')) then
    begin
      needed := true;
      break;
    end;
    inc(P);
  end;
  if not needed then
    exit; // fast path
  result := '';
  P := pointer(Text);
  S := P;
  while P < PEnd do
  begin
    if (P^ < ' ') and
       not (P^ in [#9, #10, #13]) then
    begin
      Append(result, S, P - S);
      Append(result, ['_x00', XHEX[ord(P^) shr 4], XHEX[ord(P^) and 15], '_']);
      S := P + 1;
    end
    else if (P^ = '_') and
            (PEnd - P >= 7) and
            (P[1] = 'x') and
            (P[6] = '_') and
            (P[2] in ['0'..'9', 'a'..'f', 'A'..'F']) and
            (P[3] in ['0'..'9', 'a'..'f', 'A'..'F']) and
            (P[4] in ['0'..'9', 'a'..'f', 'A'..'F']) and
            (P[5] in ['0'..'9', 'a'..'f', 'A'..'F']) then
    begin
      Append(result, S, P - S);
      Append(result, '_x005F_'); // escape the '_' of an existing _xHHHH_
      S := P + 1;
    end;
    inc(P);
  end;
  Append(result, S, P - S);
end;

function XlsxSheetName(const Name: RawUtf8; Index: integer): RawUtf8;
var
  i: PtrInt;
begin
  result := TrimU(Name);
  for i := 1 to length(result) do
    if result[i] in ['[', ']', ':', '*', '?', '/', '\'] then
    begin
      UniqueRawUtf8(result);
      result[i] := '_';
    end;
  while (result <> '') and
        (result[1] = '''') do
    delete(result, 1, 1);
  while (result <> '') and
        (result[length(result)] = '''') do
    SetLength(result, length(result) - 1);
  Utf8TruncateToUnicodeLength(result, 31);
  if result = '' then
    result := Make(['Sheet', Index + 1]);
end;


{ ************ TXlsxDocument Class Implementing TTabularDocument for XLSX }

const
  XLSX_MAIN = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  XLSX_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  XLSX_PKGREL = 'http://schemas.openxmlformats.org/package/2006/relationships';
  XLSX_HEADER = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'#13#10;

  // our styles.xml cellXfs indexes
  STYLE_DEFAULT = 0;
  STYLE_DATE = 1;
  STYLE_DATETIME = 2;
  STYLE_HEADER = 3;

  // sheet XML elements as recognized by ReadSheet() via their Name.Len
type
  TXlsxAttr = (
    xaNone,
    xaRow,
    xaCell);

function NameIs(const x: TXmlParser; const Value: RawUtf8): boolean;
  {$ifdef HASINLINE} inline; {$endif}
begin
  result := (x.Name.Len = length(Value)) and
            CompareMemSmall(x.Name.Text, pointer(Value), x.Name.Len);
end;

function ValueToCardinal(const x: TXmlParser): cardinal;
var
  P: PUtf8Char;
  L: PtrInt;
begin
  result := 0;
  P := x.Value.Buffer;
  L := x.Value.Len;
  while (L > 0) and
        (P^ in ['0'..'9']) do
  begin
    result := result * 10 + cardinal(ord(P^) - ord('0'));
    inc(P);
    dec(L);
  end;
end;

function ValueIs(const x: TXmlParser; const Value: RawUtf8): boolean;
  {$ifdef HASINLINE} inline; {$endif}
begin
  result := (x.Value.Len = length(Value)) and
            CompareMemSmall(x.Value.Buffer, pointer(Value), x.Value.Len);
end;

// resolve a relationship Target from the folder of its source part
function ResolvePath(const SourcePart, Target: RawUtf8): RawUtf8;
var
  i, j: PtrInt;
begin
  if (Target <> '') and
     (Target[1] = '/') then
  begin
    result := copy(Target, 2, maxInt); // absolute path within the package
    exit;
  end;
  i := length(SourcePart);
  while (i > 0) and
        (SourcePart[i] <> '/') do
    dec(i);
  result := copy(SourcePart, 1, i) + Target; // relative to the source folder
  repeat // normalize any 'folder/../' segment
    i := PosEx('/../', result);
    if i = 0 then
      break;
    j := i - 1;
    while (j > 0) and
          (result[j] <> '/') do
      dec(j);
    delete(result, j + 1, i + 3 - j);
  until false;
  if copy(result, 1, 3) = '../' then
    delete(result, 1, 3);
end;

// return the .rels part path of a given part, e.g. 'xl/_rels/workbook.xml.rels'
function RelsPath(const Part: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  i := length(Part);
  while (i > 0) and
        (Part[i] <> '/') do
    dec(i);
  result := Make([copy(Part, 1, i), '_rels/', copy(Part, i + 1, maxInt), '.rels']);
end;

function EndsWith(const Text, Suffix: RawUtf8): boolean;
var
  L: PtrInt;
begin
  L := length(Suffix);
  result := (length(Text) >= L) and
            CompareMemSmall(PAnsiChar(pointer(Text)) + length(Text) - L,
              pointer(Suffix), L);
end;

constructor TXlsxDocument.Create(aOptions: TTabularOptions);
begin
  inherited Create(aOptions);
  fXlsxOptions := XLSX_DEFAULT;
  fMaxColumnWidth := 60;
end;

destructor TXlsxDocument.Destroy;
begin
  CloseZip;
  inherited Destroy;
end;

procedure TXlsxDocument.OpenZip(const Data: RawByteString);
begin
  CloseZip;
  if (length(Data) < 22) or
     (PCardinal(pointer(Data))^ <> $04034b50) then // 'PK'#3#4
    raise EXlsxException.CreateUtf8('%: input is not a XLSX/zip content', [self]);
  fZipData := Data; // TZipRead expects the buffer to remain available
  fZip := TZipRead.Create(PByteArray(pointer(fZipData)), length(fZipData));
  fWorkbookPath := '';
  fSheets := nil;
  fShared := nil;
  fSharedCount := 0;
  fDateStyle := nil;
  fDate1904 := false;
  fSharedPath := '';
  fStylesPath := '';
end;

procedure TXlsxDocument.CloseZip;
begin
  FreeAndNil(fZip);
  fZipData := '';
end;

function TXlsxDocument.ZipText(const Path: RawUtf8; Mandatory: boolean): RawUtf8;
var
  i: integer;
  tmp: RawByteString;
begin
  result := '';
  i := -1;
  if Path <> '' then
    i := fZip.NameToIndex(Utf8ToString(Path));
  if i < 0 then
    if Mandatory then
      raise EXlsxException.CreateUtf8('%: missing % part', [self, Path])
    else
      exit;
  tmp := fZip.UnZip(i); // with 256MB size limit, against zip bombs
  if tmp = '' then
    if Mandatory then
      raise EXlsxException.CreateUtf8('%: invalid % part', [self, Path])
    else
      exit;
  TabularDecodeText(tmp, CP_UTF8, result); // remove any UTF-8 BOM
end;

procedure TXlsxDocument.ReadWorkbook;
var
  x: TXmlParser;
  d: TDocVariantData;
  xml, rels: RawUtf8;
  ids, targets: TRawUtf8DynArray;
  n: integer;
  i, j: PtrInt;
  typ, target: RawUtf8;
begin
  // locate the main workbook part from the package relationships
  fWorkbookPath := 'xl/workbook.xml';
  rels := ZipText('_rels/.rels', false);
  if rels <> '' then
  begin
    x.Init(rels, [xpoStripNamespacePrefix]);
    if x.Find('/Relationships') then
      while x.Consume('Relationship', d) do
        if EndsWith(d.U['@Type'], '/officeDocument') then
        begin
          fWorkbookPath := ResolvePath('', d.U['@Target']);
          break;
        end;
  end;
  // parse the workbook relationships
  rels := ZipText(RelsPath(fWorkbookPath), true);
  x.Init(rels, [xpoStripNamespacePrefix]);
  n := 0;
  if x.Find('/Relationships') then
    while x.Consume('Relationship', d) do
    begin
      typ := d.U['@Type'];
      target := ResolvePath(fWorkbookPath, d.U['@Target']);
      if EndsWith(typ, '/sharedStrings') then
        fSharedPath := target
      else if EndsWith(typ, '/styles') then
        fStylesPath := target
      else if EndsWith(typ, '/worksheet') then
      begin
        AddRawUtf8(ids, n, d.U['@Id']);
        SetLength(targets, n);
        targets[n - 1] := target;
      end;
    end;
  // parse the workbook sheets list (in display order) and properties
  xml := ZipText(fWorkbookPath, true);
  x.Init(xml, [xpoStripNamespacePrefix]);
  if x.Find('/workbook/workbookPr') and
     x.Consume(d) then
    fDate1904 := d.B['@date1904'] or
                 (d.U['@date1904'] = '1');
  if not x.Find('/workbook/sheets') then
    raise EXlsxException.CreateUtf8('%: no sheet in %', [self, fWorkbookPath]);
  i := 0;
  while x.Consume('sheet', d) do
  begin
    SetLength(fSheets, i + 1);
    fSheets[i].Name := d.U['@name'];
    fSheets[i].Hidden := IdemPChar(pointer(d.U['@state']), 'HIDDEN') or
                         IdemPChar(pointer(d.U['@state']), 'VERYHIDDEN');
    j := FindRawUtf8(pointer(ids), d.U['@id'], n, true); // r:id stripped
    if j >= 0 then
      fSheets[i].Path := targets[j];
    inc(i);
  end;
end;

procedure TXlsxDocument.ReadSharedStrings;
var
  x: TXmlParser;
  xml, s: RawUtf8;
  insi, int, inrph: boolean;
begin
  fShared := nil;
  fSharedCount := 0;
  xml := ZipText(fSharedPath, false);
  if xml = '' then
    exit;
  x.Init(xml, [xpoStripNamespacePrefix, xpoKeepWhiteSpace]);
  insi := false;
  int := false;
  inrph := false;
  repeat
    case x.ParseNext of
      xtEof:
        break;
      xtElementStart:
        if NameIs(x, 'si') then
        begin
          insi := true;
          s := '';
        end
        else if insi then
          if NameIs(x, 't') then
            int := not inrph
          else if NameIs(x, 'rPh') then
            inrph := true; // phonetic run: ignore its <t> text
      xtElementEnd:
        if NameIs(x, 'si') then
        begin
          insi := false;
          AddRawUtf8(fShared, fSharedCount, XlsxUnescape(s));
        end
        else if NameIs(x, 't') then
          int := false
        else if NameIs(x, 'rPh') then
          inrph := false;
      xtText,
      xtCData:
        if int then
          x.ValueAppendToUtf8(s);
    end;
  until false;
end;

procedure TXlsxDocument.ReadStyles;
var
  x: TXmlParser;
  d: TDocVariantData;
  xml: RawUtf8;
  fmtids: TIntegerDynArray;
  fmtdate: TBooleanDynArray;
  fmtcount, xfcount, id, i: PtrInt;
  isdate: boolean;
begin
  fDateStyle := nil;
  xml := ZipText(fStylesPath, false);
  if xml = '' then
    exit;
  x.Init(xml, [xpoStripNamespacePrefix]);
  // custom number formats
  fmtcount := 0;
  if x.Find('/styleSheet/numFmts') then
    while x.Consume('numFmt', d) do
    begin
      SetLength(fmtids, fmtcount + 1);
      SetLength(fmtdate, fmtcount + 1);
      fmtids[fmtcount] := d.I['@numFmtId'];
      fmtdate[fmtcount] := XlsxIsDateFormat(d.U['@formatCode']);
      inc(fmtcount);
    end;
  // cell formats, as referenced by the c/@s attribute
  xfcount := 0;
  if x.Find('/styleSheet/cellXfs') then
    while x.Consume('xf', d) do
    begin
      id := d.I['@numFmtId'];
      isdate := XlsxIsBuiltinDateFormat(id);
      for i := 0 to fmtcount - 1 do
        if fmtids[i] = id then
        begin
          isdate := fmtdate[i]; // custom format overrides built-in
          break;
        end;
      SetLength(fDateStyle, xfcount + 1);
      fDateStyle[xfcount] := isdate;
      inc(xfcount);
    end;
end;

procedure TXlsxDocument.ReadSheet(const Xml: RawUtf8);
var
  x: TXmlParser;
  text: RawUtf8;
  attr: TXlsxAttr;
  celltype: TXlsxCellType;
  insheetdata, incell, invalue, inis, int, inrph, rowpending: boolean;
  rownum, nextrow, col, lastcol, style, idx: integer;
  dbl: double;
  err: integer;

  procedure FlushRowGap;
  begin
    rowpending := false;
    if not (tboSkipEmptyRows in fOptions) then
      while nextrow < rownum do
      begin
        ReadCellEmpty; // emit [""] for each missing row
        ReadRowEnd;
        inc(nextrow);
      end;
    nextrow := rownum + 1;
  end;

begin
  x.Init(Xml, [xpoStripNamespacePrefix, xpoKeepWhiteSpace]);
  insheetdata := false;
  incell := false;
  invalue := false;
  inis := false;
  int := false;
  inrph := false;
  rowpending := false;
  attr := xaNone;
  nextrow := 1;
  rownum := 1;
  col := 0;
  lastcol := -1;
  style := 0;
  celltype := xctNumber;
  repeat
    x.ParseNext;
    if rowpending and
       (x.Kind <> xtAttribute) then
      FlushRowGap;
    case x.Kind of
      xtEof:
        break;
      xtElementStart:
        begin
          attr := xaNone;
          if not insheetdata then
          begin
            insheetdata := NameIs(x, 'sheetData');
            continue;
          end;
          case x.Name.Len of
            1:
              case x.Name.Text^ of
                'c':
                  begin
                    incell := true;
                    celltype := xctNumber;
                    style := 0;
                    col := lastcol + 1;
                    text := '';
                    attr := xaCell;
                  end;
                'v':
                  invalue := incell;
                't':
                  int := inis and
                         not inrph;
              end;
            2:
              if NameIs(x, 'is') then
                inis := incell;
            3:
              if NameIs(x, 'row') then
              begin
                rownum := nextrow;
                lastcol := -1;
                attr := xaRow;
                rowpending := true;
              end
              else if NameIs(x, 'rPh') then
                inrph := true;
          end;
        end;
      xtAttribute:
        case attr of
          xaRow:
            if NameIs(x, 'r') then
            begin
              rownum := ValueToCardinal(x);
              if rownum < nextrow then
                rownum := nextrow; // ignore any unordered row
            end;
          xaCell:
            if x.Name.Len = 1 then
              case x.Name.Text^ of
                'r':
                  begin
                    col := XlsxColumnIndex(x.Value.Buffer, x.Value.Len);
                    if col <= lastcol then
                      col := lastcol + 1; // ignore any unordered cell
                  end;
                's':
                  style := ValueToCardinal(x);
                't':
                  if ValueIs(x, 's') then
                    celltype := xctShared
                  else if ValueIs(x, 'inlineStr') then
                    celltype := xctInline
                  else if ValueIs(x, 'str') then
                    celltype := xctFormulaString
                  else if ValueIs(x, 'b') then
                    celltype := xctBoolean
                  else if ValueIs(x, 'e') then
                    celltype := xctError
                  else if ValueIs(x, 'd') then
                    celltype := xctIsoDate;
              end;
        end;
      xtText,
      xtCData:
        if invalue or
           int then
          x.ValueAppendToUtf8(text);
      xtElementEnd:
        if insheetdata then
          case x.Name.Len of
            1:
              case x.Name.Text^ of
                'v':
                  invalue := false;
                't':
                  int := false;
                'c':
                  if incell then
                  begin
                    incell := false;
                    inis := false;
                    ReadSetColumn(col);
                    lastcol := col;
                    if text = '' then
                      ReadCellEmpty
                    else
                      case celltype of
                        xctShared:
                          begin
                            idx := GetInteger(pointer(text));
                            if (idx >= 0) and
                               (idx < fSharedCount) then
                              ReadCellText(fShared[idx], false)
                            else
                              ReadCellEmpty;
                          end;
                        xctInline,
                        xctFormulaString,
                        xctError:
                          ReadCellText(XlsxUnescape(text), false);
                        xctBoolean:
                          ReadCellValue((text = '1') or
                                        IdemPropNameU(text, 'true'));
                        xctIsoDate:
                          ReadCellDateTime(Iso8601ToDateTime(text));
                      else
                        // xctNumber: date/time from its style, or a number
                        if (style >= 0) and
                           (style < length(fDateStyle)) and
                           fDateStyle[style] then
                        begin
                          dbl := GetExtended(pointer(text), err);
                          if err = 0 then
                            ReadCellDateTime(XlsxSerialToDateTime(dbl, fDate1904))
                          else
                            ReadCellText(text, false);
                        end
                        else if not ReadCellNumber(pointer(text), length(text), '.') then
                          ReadCellText(text, false);
                      end;
                  end;
              end;
            2:
              if NameIs(x, 'is') then
                inis := false;
            3:
              if NameIs(x, 'row') then
              begin
                if (fCellCount = 0) and
                   not (tboSkipEmptyRows in fOptions) then
                  ReadCellEmpty; // emit [""] for an explicit void row
                if not ReadRowEnd then
                  break; // MaxRows reached
              end
              else if NameIs(x, 'rPh') then
                inrph := false;
            9:
              if NameIs(x, 'sheetData') then
                break; // ignore anything after the cells
          end;
    end;
  until false;
end;

function TXlsxDocument.SheetToRead: integer;
begin
  if fSheetName <> '' then
  begin
    for result := 0 to length(fSheets) - 1 do
      if IdemPropNameU(fSheets[result].Name, fSheetName) then
        exit;
    raise EXlsxException.CreateUtf8('%: unknown sheet "%"', [self, fSheetName]);
  end;
  result := fSheetIndex;
  if (result < 0) or
     (result >= length(fSheets)) then
    raise EXlsxException.CreateUtf8('%: no sheet #% (count=%)',
      [self, fSheetIndex, length(fSheets)]);
end;

procedure TXlsxDocument.Parse(const Data: RawByteString);
var
  s: integer;
begin
  OpenZip(Data);
  try
    ReadWorkbook;
    s := SheetToRead;
    ReadSharedStrings;
    ReadStyles;
    ReadSheet(ZipText(fSheets[s].Path, true));
  finally
    CloseZip;
  end;
end;

function TXlsxDocument.GetSheets(const Data: RawByteString): TXlsxSheetDynArray;
begin
  OpenZip(Data);
  try
    ReadWorkbook;
    result := fSheets;
  finally
    CloseZip;
  end;
end;

function TXlsxDocument.GetSheetNames(const Data: RawByteString): TRawUtf8DynArray;
var
  s: TXlsxSheetDynArray;
  i: PtrInt;
begin
  s := GetSheets(Data);
  SetLength(result, length(s));
  for i := 0 to length(s) - 1 do
    result[i] := s[i].Name;
end;

procedure TXlsxDocument.LoadSheets(const Data: RawByteString; var Doc: variant;
  IncludeHidden: boolean);
var
  s: PtrInt;
  rows: PDocVariantData;
begin
  VarClear(Doc);
  TDocVariantData(Doc).Init(fDocOptions, dvObject);
  OpenZip(Data);
  try
    ReadWorkbook;
    ReadSharedStrings;
    ReadStyles;
    for s := 0 to length(fSheets) - 1 do
      if IncludeHidden or
         not fSheets[s].Hidden then
      begin
        rows := pointer(TDocVariantData(Doc).NewItem(fSheets[s].Name));
        rows^.Init(fDocOptions, dvArray);
        ReadBegin(rows);
        ReadSheet(ZipText(fSheets[s].Path, true));
        ReadEnd;
      end;
  finally
    ReadClear;
    fRows := nil;
    CloseZip;
  end;
end;

procedure TXlsxDocument.LoadSheetsFromFile(const FileName: TFileName;
  var Doc: variant; IncludeHidden: boolean);
begin
  LoadSheets(StringFromFile(FileName), Doc, IncludeHidden);
end;

function TXlsxDocument.SharedString(const Text: RawUtf8): integer;
var
  added: boolean;
begin
  result := fSstHash.FindHashedForAdding(Text, added);
  if added then
    fSst[result] := Text;
  inc(fSstTotal);
end;

procedure TXlsxDocument.WriteCellRef(Col: integer);
var
  tmp: array[0..7] of AnsiChar;
  i: PtrInt;
begin
  i := high(tmp);
  repeat
    tmp[i] := AnsiChar(ord('A') + Col mod 26);
    dec(i);
    Col := Col div 26 - 1;
  until Col < 0;
  fW.AddNoJsonEscape(@tmp[i + 1], high(tmp) - i);
  fW.Add(fRowNum);
end;

procedure TXlsxDocument.WriteCell(Col: integer; const Value: variant;
  Style: integer);
var
  vd: PVarData;
  text: RawUtf8;
  istext: boolean;
  dt: TDateTime;
  w: integer;
begin
  vd := @Value;
  while vd^.VType = varVariantByRef do
    vd := vd^.VPointer;
  case vd^.VType of
    varEmpty,
    varNull:
      exit; // no <c> element for a void cell
    varBoolean:
      begin
        fW.AddShort('<c r="');
        WriteCellRef(Col);
        fW.AddShort('" t="b"><v>');
        if vd^.VBoolean then // WordBool true = -1
          fW.Add('1')
        else
          fW.Add('0');
        fW.AddShort('</v></c>');
        w := 5;
      end;
    varDate:
      begin
        dt := vd^.VDate;
        fW.AddShort('<c r="');
        WriteCellRef(Col);
        fW.AddShort('" s="');
        if Frac(dt) = 0 then
        begin
          fW.Add(AnsiChar(ord('0') + STYLE_DATE));
          w := 10;
        end
        else
        begin
          fW.Add(AnsiChar(ord('0') + STYLE_DATETIME));
          w := 19;
        end;
        fW.AddShort('"><v>');
        fW.AddDouble(DateTimeToXlsxSerial(dt), {noexp=}true);
        fW.AddShort('</v></c>');
      end;
    varSmallint, varInteger, varShortInt, varByte, varWord, varLongWord,
    varInt64, varWord64, varSingle, varDouble, varCurrency:
      begin
        TabularValueToText(PVariant(vd)^, text, istext, '.');
        if (text = '') or
           not (text[length(text)] in ['0'..'9']) then
        begin
          // NaN or Infinity are not valid XLSX numbers: store as text
          WriteCell(Col, RawUtf8ToVariant(text), Style);
          exit;
        end;
        fW.AddShort('<c r="');
        WriteCellRef(Col);
        fW.AddShort('"><v>');
        fW.AddString(text);
        fW.AddShort('</v></c>');
        w := length(text);
      end;
  else
    begin
      // string or nested TDocVariant (as JSON) stored as shared string
      VariantToUtf8(PVariant(vd)^, text, istext);
      fW.AddShort('<c r="');
      WriteCellRef(Col);
      if Style <> STYLE_DEFAULT then
      begin
        fW.AddShort('" s="');
        fW.Add(PtrInt(Style));
      end;
      fW.AddShort('" t="s"><v>');
      fW.Add(PtrInt(SharedString(text)));
      fW.AddShort('</v></c>');
      if xoAutoWidth in fXlsxOptions then
        w := Utf8ToUnicodeLength(pointer(text))
      else
        w := 0;
    end;
  end;
  if Col > fColMax then
    fColMax := Col;
  if xoAutoWidth in fXlsxOptions then
  begin
    if Col >= length(fWidths) then
      SetLength(fWidths, NextGrow(Col + 1));
    if w > fWidths[Col] then
      fWidths[Col] := w;
  end;
end;

procedure TXlsxDocument.WriteBegin;
begin
  fSst := nil;
  fSstCount := 0;
  fSstTotal := 0;
  fSstHash.Init(TypeInfo(TRawUtf8DynArray), fSst, nil, nil, nil, @fSstCount);
  fSheetXml := nil;
  fSheetNames := nil;
  fSheetFilter := nil;
  fSheetCount := 0;
end;

procedure TXlsxDocument.WriteSheetBegin(const Name: RawUtf8);
var
  n: RawUtf8;
  i: integer;
begin
  n := XlsxSheetName(Name, fSheetCount);
  i := 2;
  while FindRawUtf8(pointer(fSheetNames), n, fSheetCount, false) >= 0 do
  begin
    n := XlsxSheetName(Make([XlsxSheetName(Name, fSheetCount), ' (', i, ')']),
      fSheetCount);
    inc(i);
  end;
  AddRawUtf8(fSheetNames, fSheetCount, n);
  WriterStart;
  fRowNum := 0;
  fColMax := -1;
  fWidths := nil;
  fHasHeader := false;
end;

procedure TXlsxDocument.WriteHeader(const Names: TRawUtf8DynArray; Count: integer);
var
  i, style: PtrInt;
begin
  fHasHeader := true;
  inc(fRowNum);
  fW.AddShort('<row r="1">');
  if xoHeaderBold in fXlsxOptions then
    style := STYLE_HEADER
  else
    style := STYLE_DEFAULT;
  for i := 0 to Count - 1 do
    WriteCell(i, RawUtf8ToVariant(Names[i]), style);
  fW.AddShort('</row>');
  if (xoAutoWidth in fXlsxOptions) and
     (xoAutoFilter in fXlsxOptions) then
    for i := 0 to Count - 1 do
      if i < length(fWidths) then
        inc(fWidths[i], 2); // room for the drop-down button
end;

procedure TXlsxDocument.WriteRow(const Cells: TTabularCells; Count: integer);
var
  i: PtrInt;
begin
  inc(fRowNum);
  fW.AddShort('<row r="');
  fW.Add(fRowNum);
  fW.AddDirect('"', '>');
  for i := 0 to Count - 1 do
    if Cells[i] <> nil then
      WriteCell(i, Cells[i]^, STYLE_DEFAULT);
  fW.AddShort('</row>');
end;

procedure TXlsxDocument.WriteSheetEnd;
var
  w: TTextWriter;
  i, width: PtrInt;
  last, filter: RawUtf8;
  data: RawUtf8;
begin
  WriterText(data);
  w := TTextWriter.CreateOwnedStream(length(data) + 1024);
  try
    w.AddShort(XLSX_HEADER);
    w.AddString('<worksheet xmlns="' + XLSX_MAIN + '" xmlns:r="' + XLSX_REL + '">');
    if (fRowNum > 0) and
       (fColMax >= 0) then
    begin
      last := Make([XlsxColumnName(fColMax), fRowNum]);
      w.AddShort('<dimension ref="A1:');
      w.AddString(last);
      w.AddShort('"/>');
    end;
    w.AddShort('<sheetViews><sheetView workbookViewId="0"');
    if fSheetCount = 1 then
      w.AddShort(' tabSelected="1"');
    if fHasHeader and
       (xoFreezeHeader in fXlsxOptions) then
      w.AddString('><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" ' +
        'state="frozen"/><selection pane="bottomLeft" activeCell="A2" ' +
        'sqref="A2"/></sheetView></sheetViews>')
    else
      w.AddShort('/></sheetViews>');
    w.AddShort('<sheetFormatPr defaultRowHeight="15"/>');
    if (xoAutoWidth in fXlsxOptions) and
       (fColMax >= 0) then
    begin
      w.AddShort('<cols>');
      for i := 0 to fColMax do
      begin
        if i < length(fWidths) then
          width := fWidths[i] + 2
        else
          width := 0;
        if width < 8 then
          width := 8;
        if width > fMaxColumnWidth then
          width := fMaxColumnWidth;
        w.AddShort('<col min="');
        w.Add(i + 1);
        w.AddShort('" max="');
        w.Add(i + 1);
        w.AddShort('" width="');
        w.Add(width);
        w.AddShort('" customWidth="1"/>');
      end;
      w.AddShort('</cols>');
    end;
    if data = '' then
      w.AddShort('<sheetData/>')
    else
    begin
      w.AddShort('<sheetData>');
      w.AddString(data);
      w.AddShort('</sheetData>');
    end;
    filter := '';
    if fHasHeader and
       (xoAutoFilter in fXlsxOptions) and
       (fColMax >= 0) then
    begin
      filter := Make(['A1:', XlsxColumnName(fColMax), fRowNum]);
      w.AddShort('<autoFilter ref="');
      w.AddString(filter);
      w.AddShort('"/>');
    end;
    w.AddString('<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" ' +
      'header="0.3" footer="0.3"/></worksheet>');
    SetLength(fSheetXml, fSheetCount);
    w.SetText(fSheetXml[fSheetCount - 1]);
    SetLength(fSheetFilter, fSheetCount);
    fSheetFilter[fSheetCount - 1] := filter;
  finally
    w.Free;
  end;
end;

procedure TXlsxDocument.WriteSheet(const Name: RawUtf8; const Rows: TDocVariantData);
begin
  WriteSheetBegin(Name);
  WriteTable(Rows);
  WriteSheetEnd;
end;

function TXlsxDocument.WriteEnd: RawByteString;
var
  dest: TTabularOutputStream;
  zip: TZipWrite;
  bin: RawUtf8;
  w: TTextWriter;
  i: PtrInt;
  xml: RawUtf8;
  hasfilter: boolean;

  procedure Add(const Name: TFileName; const Content: RawUtf8);
  begin
    zip.AddDeflated(Name, pointer(Content), length(Content));
  end;

  function SheetPath(i: PtrInt): RawUtf8;
  begin
    result := Make(['worksheets/sheet', i + 1, '.xml']);
  end;

begin
  if fSheetCount = 0 then
  begin
    WriteSheetBegin(fSheetName); // always at least one (void) sheet
    WriteSheetEnd;
  end;
  w := TTextWriter.CreateOwnedStream(65536);
  dest := TTabularOutputStream.Create;
  try
    zip := TZipWrite.Create(dest);
    try
      // [Content_Types].xml
      w.AddShort(XLSX_HEADER);
      w.AddString('<Types xmlns="http://schemas.openxmlformats.org/package/' +
        '2006/content-types"><Default Extension="rels" ContentType="' +
        'application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>');
      w.AddString('<Override PartName="/xl/workbook.xml" ContentType="' +
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.' +
        'main+xml"/>');
      for i := 0 to fSheetCount - 1 do
      begin
        w.AddShort('<Override PartName="/xl/');
        w.AddString(SheetPath(i));
        w.AddString('" ContentType="application/vnd.openxmlformats-' +
          'officedocument.spreadsheetml.worksheet+xml"/>');
      end;
      w.AddString('<Override PartName="/xl/styles.xml" ContentType="' +
        'application/vnd.openxmlformats-officedocument.spreadsheetml.' +
        'styles+xml"/><Override PartName="/xl/sharedStrings.xml" ' +
        'ContentType="application/vnd.openxmlformats-officedocument.' +
        'spreadsheetml.sharedStrings+xml"/></Types>');
      w.SetText(xml);
      Add('[Content_Types].xml', xml);
      // _rels/.rels
      Add('_rels/.rels', XLSX_HEADER + '<Relationships xmlns="' + XLSX_PKGREL +
        '"><Relationship Id="rId1" Type="' + XLSX_REL + '/officeDocument" ' +
        'Target="xl/workbook.xml"/></Relationships>');
      // xl/workbook.xml
      w.CancelAll;
      w.AddShort(XLSX_HEADER);
      w.AddString('<workbook xmlns="' + XLSX_MAIN + '" xmlns:r="' + XLSX_REL +
        '"><bookViews><workbookView/></bookViews><sheets>');
      hasfilter := false;
      for i := 0 to fSheetCount - 1 do
      begin
        w.AddShort('<sheet name="');
        AddXmlEscape(w, pointer(fSheetNames[i]));
        w.AddShort('" sheetId="');
        w.Add(i + 1);
        w.AddShort('" r:id="rId');
        w.Add(i + 1);
        w.AddShort('"/>');
        if fSheetFilter[i] <> '' then
          hasfilter := true;
      end;
      w.AddShort('</sheets>');
      if hasfilter then
      begin
        // Excel expects a hidden _FilterDatabase name for each auto-filter
        w.AddShort('<definedNames>');
        for i := 0 to fSheetCount - 1 do
          if fSheetFilter[i] <> '' then
          begin
            w.AddShort('<definedName name="_xlnm._FilterDatabase" localSheetId="');
            w.Add(i);
            w.AddShort('" hidden="1">');
            AddXmlEscape(w, pointer(Make(['''',
              StringReplaceAll(fSheetNames[i], '''', ''''''), '''!$',
              StringReplaceAll(fSheetFilter[i], ':', ':$')])));
            w.AddShort('</definedName>');
          end;
        w.AddShort('</definedNames>');
      end;
      w.AddShort('</workbook>');
      w.SetText(xml);
      Add('xl/workbook.xml', xml);
      // xl/_rels/workbook.xml.rels
      w.CancelAll;
      w.AddShort(XLSX_HEADER);
      w.AddString('<Relationships xmlns="' + XLSX_PKGREL + '">');
      for i := 0 to fSheetCount - 1 do
      begin
        w.AddShort('<Relationship Id="rId');
        w.Add(i + 1);
        w.AddString('" Type="' + XLSX_REL + '/worksheet" Target="');
        w.AddString(SheetPath(i));
        w.AddShort('"/>');
      end;
      w.AddShort('<Relationship Id="rId');
      w.Add(fSheetCount + 1);
      w.AddString('" Type="' + XLSX_REL + '/styles" Target="styles.xml"/>' +
        '<Relationship Id="rId');
      w.Add(fSheetCount + 2);
      w.AddString('" Type="' + XLSX_REL + '/sharedStrings" ' +
        'Target="sharedStrings.xml"/></Relationships>');
      w.SetText(xml);
      Add('xl/_rels/workbook.xml.rels', xml);
      // xl/styles.xml with our 4 cell formats: default, date, datetime, header
      Add('xl/styles.xml', XLSX_HEADER + '<styleSheet xmlns="' + XLSX_MAIN + '">' +
        '<numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy\-mm\-dd"/>' +
        '<numFmt numFmtId="165" formatCode="yyyy\-mm\-dd\ hh:mm:ss"/></numFmts>' +
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/>' +
        '<family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/>' +
        '<family val="2"/></font></fonts><fills count="2"><fill><patternFill ' +
        'patternType="none"/></fill><fill><patternFill patternType="gray125"/>' +
        '</fill></fills><borders count="1"><border><left/><right/><top/>' +
        '<bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf ' +
        'numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" ' +
        'borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" ' +
        'borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" ' +
        'fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" ' +
        'applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle ' +
        'name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>');
      // xl/sharedStrings.xml
      WriterStart; // may be huge: use our TTabularOutputStream
      fW.AddShort(XLSX_HEADER);
      fW.AddString('<sst xmlns="' + XLSX_MAIN + '" count="');
      fW.Add(fSstTotal);
      fW.AddShort('" uniqueCount="');
      fW.Add(fSstCount);
      fW.AddDirect('"', '>');
      for i := 0 to fSstCount - 1 do
      begin
        xml := XlsxEscape(fSst[i]);
        if (xml <> '') and
           ((xml[1] <= ' ') or
            (xml[length(xml)] <= ' ') or
            (PosExChar(#10, xml) > 0)) then
          fW.AddShort('<si><t xml:space="preserve">')
        else
          fW.AddShort('<si><t>');
        AddXmlEscape(fW, pointer(xml));
        fW.AddShort('</t></si>');
      end;
      fW.AddShort('</sst>');
      WriterText(xml);
      Add('xl/sharedStrings.xml', xml);
      // xl/worksheets/sheet#.xml
      for i := 0 to fSheetCount - 1 do
      begin
        Add(Utf8ToString('xl/' + SheetPath(i)), fSheetXml[i]);
        fSheetXml[i] := ''; // release memory ASAP
      end;
    finally
      zip.Free; // write the .zip central directory
    end;
    dest.GetText(bin);
    result := bin;
  finally
    dest.Free;
    w.Free;
    fSst := nil;
    fSstCount := 0;
  end;
end;

function TXlsxDocument.DoSave(const Doc: TDocVariantData): RawByteString;
var
  i: PtrInt;
  sheets: boolean;
  rows: PDocVariantData;
begin
  WriteBegin;
  // a TDocVariant object of arrays is a set of {"sheetname": [rows...]}
  sheets := Doc.IsObject and
            (Doc.Count > 0);
  if sheets then
    for i := 0 to Doc.Count - 1 do
      if not _Safe(Doc.Values[i], rows) or
         not rows^.IsArray then
      begin
        sheets := false;
        break;
      end;
  if sheets then
    for i := 0 to Doc.Count - 1 do
      WriteSheet(Doc.Names[i], _Safe(Doc.Values[i])^)
  else
    WriteSheet(fSheetName, Doc);
  result := WriteEnd;
end;


{ ************ High-Level XLSX Wrapper Functions }

function XlsxToVariant(const Xlsx: RawByteString; Options: TTabularOptions;
  const SheetName: RawUtf8): variant;
var
  x: TXlsxDocument;
begin
  x := TXlsxDocument.Create(Options);
  try
    x.SheetName := SheetName;
    x.Load(Xlsx, result);
  finally
    x.Free;
  end;
end;

function XlsxSheetsToVariant(const Xlsx: RawByteString;
  Options: TTabularOptions): variant;
var
  x: TXlsxDocument;
begin
  x := TXlsxDocument.Create(Options);
  try
    x.LoadSheets(Xlsx, result);
  finally
    x.Free;
  end;
end;

function XlsxToJson(const Xlsx: RawByteString; Options: TTabularOptions;
  const SheetName: RawUtf8; Format: TTextWriterJsonFormat): RawUtf8;
var
  x: TXlsxDocument;
begin
  x := TXlsxDocument.Create(Options);
  try
    x.SheetName := SheetName;
    result := x.LoadToJson(Xlsx, Format);
  finally
    x.Free;
  end;
end;

function VariantToXlsx(const Doc: variant; Options: TTabularOptions;
  XlsxOptions: TXlsxOptions): RawByteString;
var
  x: TXlsxDocument;
begin
  x := TXlsxDocument.Create(Options);
  try
    x.XlsxOptions := XlsxOptions;
    result := x.Save(Doc);
  finally
    x.Free;
  end;
end;

function JsonToXlsx(const Json: RawUtf8; Options: TTabularOptions;
  XlsxOptions: TXlsxOptions): RawByteString;
var
  x: TXlsxDocument;
begin
  x := TXlsxDocument.Create(Options);
  try
    x.XlsxOptions := XlsxOptions;
    result := x.SaveJson(Json);
  finally
    x.Free;
  end;
end;


end.
