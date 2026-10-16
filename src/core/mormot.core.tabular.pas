/// Framework Core Abstract Tabular Data Process over TDocVariant
// - extension unit for the mORMot 2 Open Source framework
// - licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.core.tabular;

{
  *****************************************************************************

   Abstract Tabular Data Reading/Writing as TDocVariant Arrays
    - Shared Definitions and Options
    - TTabularDocument Abstract Parent Class (Template Methods)
    - Shared Low-Level Helper Functions

   Conventions shared by all TTabularDocument descendants:
    - read: returns a TDocVariant array of rows, each row being either a
      TDocVariant object (tboHeader option: names from the first row) or a
      TDocVariant array of cell values (no tboHeader option)
    - write: expects a TDocVariant array of rows, each row being an object
      (columns are the union of all field names, in order of appearance, or
      the explicit Columns[] property) or an array of cell values

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
  mormot.core.json;


{ ************ Shared Definitions and Options }

type
  /// exception raised by TTabularDocument descendants
  ETabularException = class(ESynException);

  /// customize TTabularDocument reading and writing process
  // - tboHeader: the first row holds the column names, so each row is returned
  // as a TDocVariant object - otherwise each row is a TDocVariant array; when
  // writing, the column names are written as first row
  // - tboSkipEmptyRows: ignore rows with no (or only empty) cell when reading
  // - tboTrimValues: trim leading/trailing spaces of text values when reading
  // - tboGuessTypes: text values are converted into integer/float/boolean
  // variants when they match the JSON number or true/false syntax - quoted
  // CSV fields and XLSX text cells are never converted
  // - tboEmptyAsNull: empty cells are returned as null instead of ''
  // - tboDateAsText: date/time cells (e.g. from XLSX) are returned as
  // ISO-8601 text instead of varDate variants
  TTabularOption = (
    tboHeader,
    tboSkipEmptyRows,
    tboTrimValues,
    tboGuessTypes,
    tboEmptyAsNull,
    tboDateAsText);

  /// set of options to customize TTabularDocument process
  TTabularOptions = set of TTabularOption;

  /// pointers to the cells of a row, as supplied to TTabularDocument.WriteRow
  // - a nil pointer means that the cell does not exist (e.g. a missing field)
  TTabularCells = array of PVariant;

const
  /// default TTabularDocument options
  TABULAR_DEFAULT = [tboHeader, tboSkipEmptyRows];

  /// default TDocVariant options used for the returned documents
  // - per-reference, case-insensitive names, allowing double values
  TABULAR_DOCOPTIONS = JSON_FAST_FLOAT;


{ ************ TTabularDocument Abstract Parent Class }

type
  /// abstract parent class for any tabular format reader/writer
  // - implements the "template method" pattern: descendants only need to
  // override Parse() for reading, and WriteBegin/WriteHeader/WriteRow/WriteEnd
  // for writing - this class does all TDocVariant conversion
  // - a single instance is not thread-safe, but may be reused for several
  // Load/Save calls
  TTabularDocument = class
  protected
    fOptions: TTabularOptions;
    fDocOptions: TDocVariantOptions;
    fColumns: TRawUtf8DynArray;
    fMaxRows: integer;
    fDecimalSeparator: AnsiChar;
    fLastError: string;
    // reading context
    fRows: PDocVariantData;
    fHeader: TRawUtf8DynArray;
    fHeaderCount: integer;
    fHeaderPending: boolean;
    fCells: TVariantDynArray;
    fCellCount: integer;
    fCellNotEmpty: integer;
    fRowCount: integer;
    fSourceRow: integer;
    fMaxRowsReached: boolean;
    // writing context
    fW: TTextWriter;
    fWriteCells: TTabularCells;
    fWriteColumns: TRawUtf8DynArray;
    fWriteColumnCount: integer;
    fWriteRowIndex: integer;
    function NewCell: PVariant;
      {$ifdef HASINLINE} inline; {$endif}
    procedure SetHeaderFromCells;
    procedure ReadClear;
    // reading methods, to be called by the overriden Parse() method
    procedure ReadBegin(Rows: PDocVariantData);
    /// append a typed value to the current row (e.g. XLSX number/date/bool)
    procedure ReadCellValue(const Value: variant);
    /// append a date/time value, following tboDateAsText option
    procedure ReadCellDateTime(Value: TDateTime);
    /// append a number value parsed by TabularTextToNumber()
    // - returns false, and append nothing, if P^ is not a valid number
    function ReadCellNumber(P: PUtf8Char; Len: PtrInt;
      DecimalSeparator: AnsiChar): boolean;
    /// append a text value - type guess is done if GuessType and tboGuessTypes
    procedure ReadCellText(const Text: RawUtf8; GuessType: boolean);
    /// append an empty cell to the current row
    procedure ReadCellEmpty;
    /// pad the current row with empty cells until the 0-based Col position
    procedure ReadSetColumn(Col: integer);
    /// finalize the current row and add it to the result - returns false
    // if MaxRows was reached, so that the parsing could be aborted
    function ReadRowEnd: boolean;
    /// finalize the reading process
    procedure ReadEnd;
    /// the actual parsing of the input buffer - to be overriden
    // - should call ReadCell*() and ReadRowEnd methods
    procedure Parse(const Data: RawByteString); virtual; abstract;
    // writing methods
    procedure ComputeColumns(const Rows: TDocVariantData);
    /// write a TDocVariant array of rows using WriteHeader/WriteRow methods
    procedure WriteTable(const Rows: TDocVariantData);
    /// the overriden writing methods - called by Save() via DoSave()
    procedure WriteBegin; virtual; abstract;
    procedure WriteHeader(const Names: TRawUtf8DynArray; Count: integer); virtual; abstract;
    procedure WriteRow(const Cells: TTabularCells; Count: integer); virtual; abstract;
    function WriteEnd: RawByteString; virtual; abstract;
    /// main writing method - may be overriden e.g. for XLSX multi-sheets
    function DoSave(const Doc: TDocVariantData): RawByteString; virtual;
    procedure RaiseError(const Fmt: RawUtf8; const Args: array of const);
    /// initialize fW: TTextWriter over its own RawUtf8 buffer
    procedure WriterStart;
    /// finalize fW and return the generated text
    procedure WriterText(var Text: RawUtf8);
  public
    /// initialize this instance with the default options
    constructor Create(aOptions: TTabularOptions = TABULAR_DEFAULT); reintroduce; virtual;
    /// finalize this instance
    destructor Destroy; override;
    /// parse some tabular data into a TDocVariant array of rows
    // - raise an ETabularException (or a format-specific exception) on error
    procedure Load(const Data: RawByteString; var Doc: variant); virtual;
    /// parse some tabular data into a TDocVariant array of rows, with no exception
    // - returns false on error, with the error message in LastError
    function TryLoad(const Data: RawByteString; var Doc: variant): boolean;
    /// parse a tabular file into a TDocVariant array of rows
    procedure LoadFromFile(const FileName: TFileName; var Doc: variant);
    /// parse a tabular stream into a TDocVariant array of rows
    procedure LoadFromStream(Stream: TStream; var Doc: variant);
    /// parse some tabular data into a JSON array of rows
    function LoadToJson(const Data: RawByteString;
      Format: TTextWriterJsonFormat = jsonCompact): RawUtf8;
    /// serialize a TDocVariant array of rows into the tabular format
    // - raise an ETabularException if Doc is not a TDocVariant
    function Save(const Doc: variant): RawByteString;
    /// serialize a TDocVariantData array of rows into the tabular format
    function SaveDoc(const Doc: TDocVariantData): RawByteString;
    /// serialize a JSON array of rows into the tabular format
    function SaveJson(const Json: RawUtf8): RawByteString;
    /// serialize a TDocVariant array of rows into a file
    procedure SaveToFile(const Doc: variant; const FileName: TFileName);
    /// serialize a TDocVariant array of rows into a stream
    procedure SaveToStream(const Doc: variant; Stream: TStream);
    /// customize the reading and writing process
    property Options: TTabularOptions
      read fOptions write fOptions;
    /// the TDocVariant options used for the returned rows
    // - default TABULAR_DOCOPTIONS = JSON_FAST_FLOAT, i.e. per-reference
    // - include dvoNameCaseSensitive for case-sensitive column names lookup
    property DocOptions: TDocVariantOptions
      read fDocOptions write fDocOptions;
    /// optional explicit column names (and order) used when writing
    // - for object rows: only those fields are written, in this order
    // - for array rows: those names are written as header (if tboHeader)
    // - if not set, columns are computed from the union of all object fields
    property Columns: TRawUtf8DynArray
      read fColumns write fColumns;
    /// if > 0, the maximum number of data rows (excluding header) to read
    property MaxRows: integer
      read fMaxRows write fMaxRows;
    /// the decimal separator used when guessing numbers and writing floats
    // - default is '.' - set e.g. ',' for German Excel CSV exports
    property DecimalSeparator: AnsiChar
      read fDecimalSeparator write fDecimalSeparator;
    /// the error message of the last failed TryLoad() call
    property LastError: string
      read fLastError;
    /// the column names, as retrieved by the last Load() with tboHeader
    property Header: TRawUtf8DynArray
      read fHeader;
  end;

  /// meta-class of TTabularDocument descendants
  TTabularDocumentClass = class of TTabularDocument;


{ ************ Shared Low-Level Helper Functions }

/// decode a text buffer into UTF-8, detecting BOM and code page
// - UTF-8 BOM is removed, UTF-16 LE/BE (with BOM) are converted into UTF-8
// - if CodePage is CP_UTF8, the content is returned as-is
// - if CodePage is 0, valid UTF-8 is returned as-is, and other content
// is converted from CP_WINANSI (1252), i.e. the most common "ANSI" input
// - any other CodePage will use TSynAnsiConvert.Engine(CodePage)
procedure TabularDecodeText(const Data: RawByteString; CodePage: cardinal;
  var Text: RawUtf8);

/// ensure some column names are not void and unique
// - void names are replaced with 'Col#' (1-based), and duplicated names
// are suffixed with '_2', '_3'...
procedure TabularUniqueNames(var Names: TRawUtf8DynArray; Count: integer);

/// convert a variant cell value into its text representation
// - null/empty returns '' and IsText=false
// - varDate returns ISO-8601 text, nested TDocVariant returns JSON
// - floats are written with DecimalSeparator
// - IsText is set to true if the value was a string
procedure TabularValueToText(const Value: variant; var Text: RawUtf8;
  out IsText: boolean; DecimalSeparator: AnsiChar = '.');

/// returns true if a variant contains a date/time value
function TabularIsDate(const Value: variant; out DateTime: TDateTime): boolean;

/// parse a number text buffer into an Int64, currency or double variant
// - only the JSON number syntax is accepted, so e.g. '007', '1.2.3', '1e' or
// ' 1' are refused, as are integers too big for Int64 (they would loose
// precision as double, e.g. a 20 digits ID)
// - DecimalSeparator<>'.' is accepted instead of '.', unless both appear
// (e.g. '1.234,5' with a thousands separator is refused)
// - this is the single number parser used by all tabular formats and bridges
function TabularTextToNumber(P: PUtf8Char; Len: PtrInt; var Value: variant;
  AllowDouble: boolean = true; DecimalSeparator: AnsiChar = '.'): boolean;

type
  /// result of TabularToInt64/TabularToDouble/TabularToDateTime conversion
  // - tcNull: null/empty value or void text
  // - tcValue: the value was converted
  // - tcInvalid: the value could not be converted, e.g. 'abc' into a number
  TTabularConversion = (
    tcNull,
    tcValue,
    tcInvalid);

/// convert a cell value (number, boolean or number text) into an Int64
// - floats are accepted only if they have no fractional part
function TabularToInt64(const Value: variant; out Dest: Int64): TTabularConversion;

/// convert a cell value (number, boolean or number text) into a double
function TabularToDouble(const Value: variant; out Dest: double): TTabularConversion;

/// convert a cell value (varDate, number or ISO-8601 text) into a TDateTime
function TabularToDateTime(const Value: variant; out Dest: TDateTime): TTabularConversion;


implementation


{ ************ Shared Low-Level Helper Functions }

procedure TabularDecodeText(const Data: RawByteString; CodePage: cardinal;
  var Text: RawUtf8);
var
  P: pointer;
  L: PtrInt;
  tmp: RawByteString;
begin
  P := pointer(Data);
  L := length(Data);
  case BomFile(P, L) of
    bomUtf8:
      FastSetString(Text, P, L);
    bomUtf16LE:
      RawUnicodeToUtf8(P, L shr 1, Text);
    bomUtf16BE:
      begin
        FastSetRawByteString(tmp, P, L); // don't modify the const input
        bswap16array(pointer(tmp), L shr 1);
        RawUnicodeToUtf8(pointer(tmp), L shr 1, Text);
      end;
  else
    if (CodePage = CP_UTF8) or
       ((CodePage = 0) and
        IsValidUtf8(Data)) then
      Text := Data // no conversion needed (just a refcount)
    else
    begin
      if CodePage = 0 then
        CodePage := CP_WINANSI;
      TSynAnsiConvert.Engine(CodePage).AnsiToUtf8(Data, Text);
    end;
  end;
end;

procedure TabularUniqueNames(var Names: TRawUtf8DynArray; Count: integer);
var
  i, n: PtrInt;
  base, name: RawUtf8;
begin
  for i := 0 to Count - 1 do
  begin
    if Names[i] = '' then
      Names[i] := Make(['Col', i + 1]);
    if (i > 0) and
       (FindRawUtf8(pointer(Names), Names[i], i, {casesens=}false) >= 0) then
    begin
      base := Names[i];
      n := 2;
      repeat
        name := Make([base, '_', n]);
        inc(n);
      until FindRawUtf8(pointer(Names), name, Count, false) < 0;
      Names[i] := name;
    end;
  end;
end;

function TabularIsDate(const Value: variant; out DateTime: TDateTime): boolean;
var
  vd: PVarData;
begin
  vd := VarDataFromVariant(Value);
  result := vd^.VType = varDate;
  if result then
    DateTime := vd^.VDate;
end;

function TabularTextToNumber(P: PUtf8Char; Len: PtrInt; var Value: variant;
  AllowDouble: boolean; DecimalSeparator: AnsiChar): boolean;
var
  tmp: array[0..63] of AnsiChar; // numbers are short: no heap allocation
  i: PtrInt;
  c: AnsiChar;
  dot, sep, float: boolean;
  e: PUtf8Char;
begin
  result := false;
  if (P = nil) or
     (Len <= 0) or
     (Len > high(tmp)) or
     not (P^ in ['-', '0'..'9']) then
    exit;
  dot := false;
  sep := false;
  float := false;
  for i := 0 to Len - 1 do
  begin
    c := P[i];
    if c = '.' then
    begin
      dot := true;
      float := true;
    end
    else if c = DecimalSeparator then // only if DecimalSeparator <> '.'
    begin
      sep := true;
      float := true;
      c := '.';
    end
    else if c in ['e', 'E'] then
      float := true;
    tmp[i] := c;
  end;
  if dot and
     sep then
    exit; // e.g. '1.234,5' with a thousands separator
  tmp[Len] := #0;
  VarClear(Value);
  e := GetNumericVariantFromJson(@tmp, TVarData(Value), AllowDouble);
  if (e <> @tmp[Len]) or
     ((TVarData(Value).VType = varDouble) and
      not float) then // huge integer would loose precision as double
    VarClear(Value)
  else
    result := true;
end;

// resolve a cell value as a number variant, parsing its text if needed
function ToNumber(const Value: variant; var Temp: variant;
  out Number: PVarData): TTabularConversion;
var
  tmp: TTempUtf8;
begin
  Number := VarDataFromVariant(Value);
  case Number^.VType of
    varEmpty,
    varNull:
      result := tcNull;
    varString,
    {$ifdef HASVARUSTRING}
    varUString,
    {$endif HASVARUSTRING}
    varOleStr:
      begin
        VariantToTempUtf8(PVariant(Number)^, tmp);
        if tmp.Len = 0 then
          result := tcNull
        else if TabularTextToNumber(tmp.Text, tmp.Len, Temp) then
        begin
          Number := @Temp;
          result := tcValue;
        end
        else
          result := tcInvalid;
        TempUtf8Done(tmp);
      end;
  else
    result := tcValue;
  end;
end;

function TabularToInt64(const Value: variant; out Dest: Int64): TTabularConversion;
var
  temp: variant;
  n: PVarData;
  d: double;
begin
  result := ToNumber(Value, temp, n);
  if (result = tcValue) and
     not VariantToInt64(PVariant(n)^, Dest) then
    if VariantToDouble(PVariant(n)^, d) and
       (Frac(d) = 0) and
       (Abs(d) < 9.2E18) then
      Dest := Trunc(d)
    else
      result := tcInvalid;
end;

function TabularToDouble(const Value: variant; out Dest: double): TTabularConversion;
var
  temp: variant;
  n: PVarData;
begin
  result := ToNumber(Value, temp, n);
  if (result = tcValue) and
     not VariantToDouble(PVariant(n)^, Dest) then
    result := tcInvalid;
end;

function TabularToDateTime(const Value: variant; out Dest: TDateTime): TTabularConversion;
var
  vd: PVarData;
  d: double;
begin
  result := tcValue;
  vd := VarDataFromVariant(Value);
  case vd^.VType of
    varEmpty,
    varNull:
      result := tcNull;
    varString,
    {$ifdef HASVARUSTRING}
    varUString,
    {$endif HASVARUSTRING}
    varOleStr:
      if vd^.VAny = nil then
        result := tcNull
      else if not VariantToDateTime(PVariant(vd)^, Dest) then
        result := tcInvalid; // only ISO-8601 text is accepted
  else
    if VariantToDouble(PVariant(vd)^, d) then
      Dest := d // varDate or number
    else if not VariantToDateTime(PVariant(vd)^, Dest) then
      result := tcInvalid;
  end;
end;

procedure TabularValueToText(const Value: variant; var Text: RawUtf8;
  out IsText: boolean; DecimalSeparator: AnsiChar);
var
  vd: PVarData;
  i, L: PtrInt;
  isfloat: boolean;
begin
  IsText := false;
  isfloat := false;
  vd := VarDataFromVariant(Value);
  case vd^.VType of
    varEmpty,
    varNull:
      Text := '';
    varBoolean:
      if vd^.VBoolean then
        Text := 'true'
      else
        Text := 'false';
    varDate:
      Text := DateTimeToIso8601Text(vd^.VDate);
    varSingle:
      begin
        DoubleToStr(vd^.VSingle, Text);
        isfloat := true;
      end;
    varDouble:
      begin
        DoubleToStr(vd^.VDouble, Text);
        isfloat := true;
      end;
    varCurrency:
      begin
        Curr64ToStr(vd^.VInt64, Text);
        L := length(Text);
        if PosExChar('.', Text) > 0 then
        begin
          while Text[L] = '0' do
            dec(L); // Curr64ToStr() returns 2 or 4 decimals: trim zeros
          if Text[L] = '.' then
            dec(L);
          SetLength(Text, L);
        end;
        isfloat := true;
      end;
  else
    VariantToUtf8(PVariant(vd)^, Text, IsText); // string, integer or JSON
  end;
  if isfloat and
     (DecimalSeparator <> '.') then
  begin
    i := PosExChar('.', Text);
    if i > 0 then
    begin
      UniqueRawUtf8(Text);
      Text[i] := DecimalSeparator;
    end;
  end;
end;


{ ************ TTabularDocument Abstract Parent Class }

{ TTabularDocument }

constructor TTabularDocument.Create(aOptions: TTabularOptions);
begin
  inherited Create;
  fOptions := aOptions;
  fDocOptions := TABULAR_DOCOPTIONS;
  fDecimalSeparator := '.';
end;

destructor TTabularDocument.Destroy;
begin
  FreeAndNil(fW);
  inherited Destroy;
end;

procedure TTabularDocument.WriterStart;
begin
  FreeAndNil(fW);
  // big buffer = few TRawByteStringStream reallocs (2x faster on FPC RTL heap)
  fW := TTextWriter.CreateOwnedStream(1 shl 20);
end;

procedure TTabularDocument.WriterText(var Text: RawUtf8);
begin
  try
    fW.SetText(Text);
  finally
    FreeAndNil(fW);
  end;
end;

procedure TTabularDocument.RaiseError(const Fmt: RawUtf8;
  const Args: array of const);
var
  msg: RawUtf8;
begin
  FormatUtf8(Fmt, Args, msg);
  if fSourceRow > 0 then
    msg := Make([msg, ' (row ', fSourceRow, ')']);
  raise ETabularException.CreateUtf8('%: %', [self, msg]);
end;

function TTabularDocument.NewCell: PVariant;
begin
  if fCellCount = length(fCells) then
    SetLength(fCells, NextGrow(fCellCount));
  result := @fCells[fCellCount];
  inc(fCellCount);
end;

function TTabularDocument.ReadCellNumber(P: PUtf8Char; Len: PtrInt;
  DecimalSeparator: AnsiChar): boolean;
var
  v: PVariant;
begin
  v := NewCell;
  result := TabularTextToNumber(P, Len, v^, dvoAllowDoubleValue in fDocOptions,
    DecimalSeparator);
  if result then
    inc(fCellNotEmpty)
  else
    dec(fCellCount); // v^ is still varEmpty
end;

procedure TTabularDocument.ReadClear;
var
  i: PtrInt;
begin
  for i := 0 to fCellCount - 1 do
    VarClear(fCells[i]);
  fCellCount := 0;
  fCellNotEmpty := 0;
end;

procedure TTabularDocument.ReadBegin(Rows: PDocVariantData);
begin
  fRows := Rows;
  fHeader := nil;
  fHeaderCount := 0;
  fHeaderPending := tboHeader in fOptions;
  ReadClear;
  fRowCount := 0;
  fSourceRow := 0;
  fMaxRowsReached := false;
end;

procedure TTabularDocument.ReadCellValue(const Value: variant);
begin
  if VarIsEmptyOrNull(Value) then
    ReadCellEmpty
  else
  begin
    NewCell^ := Value;
    inc(fCellNotEmpty);
  end;
end;

procedure TTabularDocument.ReadCellDateTime(Value: TDateTime);
var
  v: PVariant;
begin
  v := NewCell;
  if tboDateAsText in fOptions then
    RawUtf8ToVariant(DateTimeToIso8601Text(Value), v^)
  else
  begin
    TVarData(v^).VType := varDate;
    TVarData(v^).VDate := Value;
  end;
  inc(fCellNotEmpty);
end;

procedure TTabularDocument.ReadCellText(const Text: RawUtf8; GuessType: boolean);
var
  v: PVariant;
  L: PtrInt;
  tmp: RawUtf8;
begin
  L := length(Text);
  if (L > 0) and
     (tboTrimValues in fOptions) and
     ((Text[1] <= ' ') or
      (Text[L] <= ' ')) then
  begin
    tmp := TrimU(Text);
    ReadCellText(tmp, GuessType); // recursive call with trimmed value
    exit;
  end;
  if L = 0 then
  begin
    ReadCellEmpty;
    exit;
  end;
  if GuessType and
     (tboGuessTypes in fOptions) then
    if ReadCellNumber(pointer(Text), L, fDecimalSeparator) then
      exit
    else if IdemPropNameU(Text, 'true') or
            IdemPropNameU(Text, 'false') then
    begin
      ReadCellValue(Text[1] in ['t', 'T']);
      exit;
    end;
  v := NewCell;
  inc(fCellNotEmpty);
  RawUtf8ToVariant(Text, v^);
end;

procedure TTabularDocument.ReadCellEmpty;
var
  v: PVariant;
begin
  v := NewCell;
  if tboEmptyAsNull in fOptions then
    SetVariantNull(v^)
  else
    RawUtf8ToVariant('', v^);
end;

procedure TTabularDocument.ReadSetColumn(Col: integer);
begin
  while fCellCount < Col do
    ReadCellEmpty;
end;

procedure TTabularDocument.SetHeaderFromCells;
var
  i: PtrInt;
  b: boolean;
begin
  fHeaderCount := fCellCount;
  SetLength(fHeader, fHeaderCount);
  for i := 0 to fHeaderCount - 1 do
  begin
    VariantToUtf8(fCells[i], fHeader[i], b);
    if not b then
      if VarIsEmptyOrNull(fCells[i]) then
        fHeader[i] := '';
    if tboTrimValues in fOptions then
      fHeader[i] := TrimU(fHeader[i]);
  end;
  TabularUniqueNames(fHeader, fHeaderCount);
end;

function TTabularDocument.ReadRowEnd: boolean;
var
  i, n: PtrInt;
  row: PDocVariantData;
  v: PVariant;
  extra: RawUtf8;
begin
  result := not fMaxRowsReached;
  inc(fSourceRow);
  if not result then
  begin
    ReadClear;
    exit;
  end;
  if (fCellNotEmpty = 0) and
     ((tboSkipEmptyRows in fOptions) or
      (fCellCount = 0)) then
  begin
    ReadClear; // ignore this empty row
    exit;
  end;
  if fHeaderPending then
  begin
    SetHeaderFromCells;
    fHeaderPending := false;
    ReadClear;
    exit;
  end;
  // add the new row to the result array
  row := pointer(fRows^.NewItem);
  if tboHeader in fOptions then
  begin
    n := fCellCount;
    if n < fHeaderCount then
      n := fHeaderCount;
    row^.Init(fDocOptions, dvObject);
    row^.Capacity := n;
    for i := 0 to n - 1 do
    begin
      if i < fHeaderCount then
        v := row^.NewItem(fHeader[i])
      else
      begin
        // more cells than header columns: create Col# extra names
        extra := Make(['Col', i + 1]);
        if FindRawUtf8(fHeader, extra) >= 0 then
          extra := Make([extra, '_', i + 1]);
        v := row^.NewItem(extra);
      end;
      if i < fCellCount then
      begin
        // move the cell variant content into the row (no refcount)
        PVarData(v)^ := PVarData(@fCells[i])^;
        TVarData(fCells[i]).VType := varEmpty;
      end
      else if tboEmptyAsNull in fOptions then
        SetVariantNull(v^)
      else
        RawUtf8ToVariant('', v^);
    end;
  end
  else
  begin
    row^.Init(fDocOptions, dvArray);
    row^.Capacity := fCellCount;
    for i := 0 to fCellCount - 1 do
    begin
      v := row^.NewItem;
      PVarData(v)^ := PVarData(@fCells[i])^;
      TVarData(fCells[i]).VType := varEmpty;
    end;
  end;
  fCellCount := 0;
  fCellNotEmpty := 0;
  inc(fRowCount);
  if (fMaxRows > 0) and
     (fRowCount >= fMaxRows) then
  begin
    fMaxRowsReached := true;
    result := false;
  end;
end;

procedure TTabularDocument.ReadEnd;
begin
  if fCellCount > 0 then
    ReadRowEnd; // flush any pending row
  ReadClear;
  fRows := nil;
end;

procedure TTabularDocument.Load(const Data: RawByteString; var Doc: variant);
begin
  VarClear(Doc);
  TDocVariantData(Doc).Init(fDocOptions, dvArray);
  ReadBegin(@Doc);
  try
    Parse(Data);
    ReadEnd;
  except
    ReadClear;
    fRows := nil;
    raise;
  end;
end;

function TTabularDocument.TryLoad(const Data: RawByteString;
  var Doc: variant): boolean;
begin
  fLastError := '';
  try
    Load(Data, Doc);
    result := true;
  except
    on E: Exception do
    begin
      fLastError := E.Message;
      VarClear(Doc);
      result := false;
    end;
  end;
end;

procedure TTabularDocument.LoadFromFile(const FileName: TFileName; var Doc: variant);
begin
  Load(StringFromFile(FileName), Doc);
end;

procedure TTabularDocument.LoadFromStream(Stream: TStream; var Doc: variant);
begin
  Load(StreamToRawByteString(Stream), Doc);
end;

function TTabularDocument.LoadToJson(const Data: RawByteString;
  Format: TTextWriterJsonFormat): RawUtf8;
var
  doc: variant;
begin
  Load(Data, doc);
  result := TDocVariantData(doc).ToJson('', '', Format);
end;

procedure TTabularDocument.ComputeColumns(const Rows: TDocVariantData);
var
  r, i: PtrInt;
  row: PDocVariantData;
  same: boolean;
begin
  fWriteColumns := fColumns;
  fWriteColumnCount := length(fColumns);
  if fWriteColumnCount > 0 then
    exit; // explicit columns
  for r := 0 to Rows.Count - 1 do
    if _Safe(Rows.Values[r], row) and
       row^.IsObject then
    begin
      // fast path: same field names in the same order as previous rows
      same := row^.Count <= fWriteColumnCount;
      if same then
        for i := 0 to row^.Count - 1 do
          if row^.Names[i] <> fWriteColumns[i] then
          begin
            same := false;
            break;
          end;
      if not same then
        for i := 0 to row^.Count - 1 do
          if FindRawUtf8(pointer(fWriteColumns), row^.Names[i],
               fWriteColumnCount, dvoNameCaseSensitive in row^.Options) < 0 then
            AddRawUtf8(fWriteColumns, fWriteColumnCount, row^.Names[i]);
    end;
end;

procedure TTabularDocument.WriteTable(const Rows: TDocVariantData);
var
  r, i, n, ndx: PtrInt;
  row: PDocVariantData;
  vd: PVarData;
begin
  if not Rows.IsArray and
     (Rows.Count > 0) then
    RaiseError('Save() expects a TDocVariant array of rows', []);
  ComputeColumns(Rows);
  if (tboHeader in fOptions) and
     (fWriteColumnCount > 0) then
    WriteHeader(fWriteColumns, fWriteColumnCount);
  for r := 0 to Rows.Count - 1 do
  begin
    fWriteRowIndex := r;
    vd := VarDataFromVariant(Rows.Values[r]);
    if _Safe(PVariant(vd)^, row) then
      if row^.IsObject then
      begin
        // object row: lookup each column by name
        n := fWriteColumnCount;
        if length(fWriteCells) < n then
          SetLength(fWriteCells, n);
        for i := 0 to n - 1 do
        begin
          if (i < row^.Count) and
             (row^.Names[i] = fWriteColumns[i]) then
            ndx := i // fast path: same order
          else
            ndx := row^.GetValueIndex(fWriteColumns[i]);
          if ndx >= 0 then
            fWriteCells[i] := @row^.Values[ndx]
          else
            fWriteCells[i] := nil;
        end;
      end
      else
      begin
        // array row: write cells by position
        n := row^.Count;
        if length(fWriteCells) < n then
          SetLength(fWriteCells, n);
        for i := 0 to n - 1 do
          fWriteCells[i] := @row^.Values[i];
      end
    else
    begin
      // simple value row: one single cell
      n := 1;
      if length(fWriteCells) < n then
        SetLength(fWriteCells, n);
      fWriteCells[0] := pointer(vd);
    end;
    WriteRow(fWriteCells, n);
  end;
end;

function TTabularDocument.DoSave(const Doc: TDocVariantData): RawByteString;
begin
  WriteBegin;
  WriteTable(Doc);
  result := WriteEnd;
end;

function TTabularDocument.SaveDoc(const Doc: TDocVariantData): RawByteString;
begin
  fSourceRow := 0;
  result := DoSave(Doc);
end;

function TTabularDocument.Save(const Doc: variant): RawByteString;
var
  dv: PDocVariantData;
begin
  if not _Safe(Doc, dv) then
    RaiseError('Save() expects a TDocVariant document', []);
  result := SaveDoc(dv^);
end;

function TTabularDocument.SaveJson(const Json: RawUtf8): RawByteString;
var
  doc: TDocVariantData;
begin
  if not doc.InitJson(Json, fDocOptions) then
    RaiseError('SaveJson() expects a valid JSON array', []);
  result := SaveDoc(doc);
end;

procedure TTabularDocument.SaveToFile(const Doc: variant; const FileName: TFileName);
begin
  if not FileFromString(Save(Doc), FileName) then
    RaiseError('SaveToFile(%) failed', [FileName]);
end;

procedure TTabularDocument.SaveToStream(const Doc: variant; Stream: TStream);
var
  tmp: RawByteString;
begin
  tmp := Save(Doc);
  if tmp <> '' then
    Stream.WriteBuffer(pointer(tmp)^, length(tmp));
end;


end.
