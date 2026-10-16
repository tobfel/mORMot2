/// Framework Core RFC 4180 CSV Reader/Writer over TDocVariant
// - extension unit for the mORMot 2 Open Source framework
// - licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.core.csv;

{
  *****************************************************************************

   RFC 4180 Compliant CSV Reading/Writing as TDocVariant Arrays
    - TCsvDocument Class Implementing TTabularDocument for CSV
    - High-Level CSV Wrapper Functions

   RFC 4180 features:
    - fields separated by a delimiter (',' by default, ';' or TAB also common)
    - records separated by CRLF (LF or CR alone are also accepted on read)
    - fields with delimiter, quote, CR or LF are enclosed in double quotes
    - a double quote within a quoted field is escaped as two double quotes
    - optional final line break, optional header line
   Extensions:
    - UTF-8 BOM, UTF-16 BOM and ANSI code page input detection/conversion
    - delimiter auto-detection, and Excel "sep=;" first line hint
    - optional strict mode raising ECsvException on any RFC violation
    - optional formula injection protection when writing (CWE-1236)

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
  mormot.core.data,
  mormot.core.variants,
  mormot.core.tabular;


{ ************ TCsvDocument Class Implementing TTabularDocument for CSV }

type
  /// exception raised by TCsvDocument on invalid input in strict mode
  ECsvException = class(ETabularException);

  /// how TCsvDocument writes quotes around fields
  // - cqMinimal: only fields containing delimiter, quote, CR, LF, or leading/
  // trailing spaces are quoted - as RFC 4180 expects (default)
  // - cqAll: all fields are quoted
  // - cqNonNumeric: all text fields are quoted, numbers/booleans are not
  TCsvQuoting = (
    cqMinimal,
    cqAll,
    cqNonNumeric);

  /// CSV-specific options for TCsvDocument
  // - csoStrict: raise ECsvException on RFC 4180 violations when reading, i.e.
  // a quote within an unquoted field, characters after a closing quote, an
  // unterminated quoted field, or a varying number of fields per record
  // - csoWriteBom: prepend an UTF-8 BOM when writing (helps Excel on Windows)
  // - csoWriteSepLine: write an Excel "sep=;" first line hint
  // - csoNoFinalLineBreak: don't write a line break after the last record
  // - csoEscapeFormulas: prefix text values starting with = + - @ TAB CR by
  // a single quote, to prevent CSV/formula injection in spreadsheets
  TCsvOption = (
    csoStrict,
    csoWriteBom,
    csoWriteSepLine,
    csoNoFinalLineBreak,
    csoEscapeFormulas);

  /// set of CSV-specific options for TCsvDocument
  TCsvOptions = set of TCsvOption;

  /// RFC 4180 compliant CSV reader/writer over TDocVariant arrays
  // - e.g. to read a CSV file with a header line into an array of objects:
  // !var csv: TCsvDocument;
  // !    doc: variant;
  // !begin
  // !  csv := TCsvDocument.Create([tboHeader, tboGuessTypes]);
  // !  try
  // !    csv.Delimiter := ';';
  // !    csv.LoadFromFile('data.csv', doc);
  // !    writeln(doc._(0).Name); // late binding, or use _Safe(doc)^
  // !    FileFromString(csv.Save(doc), 'copy.csv');
  // !  finally
  // !    csv.Free;
  // !  end;
  TCsvDocument = class(TTabularDocument)
  protected
    fDelimiter: AnsiChar;
    fQuote: AnsiChar;
    fUsedDelimiter: AnsiChar;
    fQuoting: TCsvQuoting;
    fCsvOptions: TCsvOptions;
    fCodePage: cardinal;
    fLineBreak: RawUtf8;
    fLine: integer;
    fStop: array[AnsiChar] of boolean;
    fNeedQuote: array[AnsiChar] of boolean;
    fWriteRows: integer;
    procedure RaiseCsv(const Msg: RawUtf8);
    procedure Parse(const Data: RawByteString); override;
    procedure WriteBegin; override;
    procedure WriteHeader(const Names: TRawUtf8DynArray; Count: integer); override;
    procedure WriteRow(const Cells: TTabularCells; Count: integer); override;
    function WriteEnd: RawByteString; override;
    procedure WriteNewRecord;
    procedure WriteField(P: PUtf8Char; L: PtrInt; IsText: boolean);
  public
    /// initialize this instance with the default options
    // - Delimiter=',', Quote='"', LineBreak=CRLF, Quoting=cqMinimal
    constructor Create(aOptions: TTabularOptions = TABULAR_DEFAULT); override;
    /// initialize this instance with a given delimiter
    constructor CreateDelimiter(aDelimiter: AnsiChar;
      aOptions: TTabularOptions = TABULAR_DEFAULT);
    /// guess the delimiter from the first record of some CSV content
    // - counts ',' ';' TAB and '|' outside quotes, and returns the most used
    // - returns ',' if none was found
    class function DetectDelimiter(P: PUtf8Char; Len: PtrInt;
      Quote: AnsiChar = '"'): AnsiChar;
    /// the field delimiter, ',' by default
    // - set #0 to auto-detect the delimiter when reading (DetectDelimiter)
    // - an Excel "sep=X" first line will always override this value on read
    property Delimiter: AnsiChar
      read fDelimiter write fDelimiter;
    /// the delimiter actually used during the last Load()
    property UsedDelimiter: AnsiChar
      read fUsedDelimiter;
    /// the quote character, '"' by default - #0 disables quoting on read
    property Quote: AnsiChar
      read fQuote write fQuote;
    /// how fields are quoted when writing
    property Quoting: TCsvQuoting
      read fQuoting write fQuoting;
    /// CSV-specific options
    property CsvOptions: TCsvOptions
      read fCsvOptions write fCsvOptions;
    /// the line break used when writing - CRLF by default, as RFC 4180 states
    property LineBreak: RawUtf8
      read fLineBreak write fLineBreak;
    /// the code page of the CSV content
    // - reading: 0 (default) detects UTF-8 or fallbacks to CP_WINANSI (1252),
    // and UTF-8/UTF-16 BOM are always recognized
    // - writing: 0 or CP_UTF8 (65001) write UTF-8, otherwise text is
    // converted into this code page (e.g. 1252 for legacy consumers)
    property CodePage: cardinal
      read fCodePage write fCodePage;
  end;


{ ************ High-Level CSV Wrapper Functions }

/// parse CSV content into a TDocVariant array of rows
// - with tboHeader, returns an array of objects, otherwise an array of arrays
function CsvToVariant(const Csv: RawByteString;
  Options: TTabularOptions = TABULAR_DEFAULT; Delimiter: AnsiChar = ','): variant;

/// parse CSV content into a JSON array of rows
function CsvToJson(const Csv: RawByteString;
  Options: TTabularOptions = TABULAR_DEFAULT; Delimiter: AnsiChar = ',';
  Format: TTextWriterJsonFormat = jsonCompact): RawUtf8;

/// serialize a TDocVariant array of rows as RFC 4180 CSV
function VariantToCsv(const Doc: variant;
  Options: TTabularOptions = TABULAR_DEFAULT; Delimiter: AnsiChar = ','): RawUtf8;

/// serialize a JSON array of rows as RFC 4180 CSV
function JsonToCsv(const Json: RawUtf8;
  Options: TTabularOptions = TABULAR_DEFAULT; Delimiter: AnsiChar = ','): RawUtf8;


implementation


{ ************ TCsvDocument Class Implementing TTabularDocument for CSV }

constructor TCsvDocument.Create(aOptions: TTabularOptions);
begin
  inherited Create(aOptions);
  fDelimiter := ',';
  fQuote := '"';
  fLineBreak := #13#10;
end;

constructor TCsvDocument.CreateDelimiter(aDelimiter: AnsiChar;
  aOptions: TTabularOptions);
begin
  Create(aOptions);
  fDelimiter := aDelimiter;
end;

class function TCsvDocument.DetectDelimiter(P: PUtf8Char; Len: PtrInt;
  Quote: AnsiChar): AnsiChar;
const
  CANDIDATES: array[0..3] of AnsiChar = (',', ';', #9, '|');
var
  count: array[0..3] of integer;
  PEnd: PUtf8Char;
  inquote: boolean;
  i, best: PtrInt;
begin
  FillCharFast(count, SizeOf(count), 0);
  if Len > 65536 then
    Len := 65536; // first record should be enough
  PEnd := P + Len;
  inquote := false;
  while P < PEnd do
  begin
    if (Quote <> #0) and
       (P^ = Quote) then
      inquote := not inquote // "" escapes are toggled twice: no problem
    else if not inquote then
      case P^ of
        #13, #10:
          break; // end of the first record
        ',':
          inc(count[0]);
        ';':
          inc(count[1]);
        #9:
          inc(count[2]);
        '|':
          inc(count[3]);
      end;
    inc(P);
  end;
  best := 0;
  for i := 1 to high(count) do
    if count[i] > count[best] then
      best := i;
  result := CANDIDATES[best];
end;

procedure TCsvDocument.RaiseCsv(const Msg: RawUtf8);
begin
  raise ECsvException.CreateUtf8('%: % at line %', [self, Msg, fLine]);
end;

procedure TCsvDocument.Parse(const Data: RawByteString);
var
  text, field: RawUtf8;
  P, PEnd, S, D, E, T: PUtf8Char;
  q, delim: AnsiChar;
  quotes, fields, expected: PtrInt;
  strict: boolean;

  procedure ReadQuoted(P: PUtf8Char; L: PtrInt; Source: PRawUtf8);
  begin
    if (L = 0) and
       (tboEmptyAsNull in fOptions) then
    begin
      RawUtf8ToVariant('', NewCell^); // "" is a void string, not null
      inc(fCellNotEmpty);
    end
    else
      ReadCellBuffer(P, L, {guess=}false, Source); // quoted = always text
  end;

begin
  TabularDecodeText(Data, fCodePage, text);
  P := pointer(text);
  PEnd := P + length(text);
  fLine := 1;
  q := fQuote;
  strict := csoStrict in fCsvOptions;
  // detect the delimiter
  if (PEnd - P >= 5) and
     IdemPChar(P, 'SEP=') and
     ((PEnd - P = 5) or
      (P[5] in [#13, #10])) then
  begin
    // Excel "sep=;" hint line
    delim := P[4];
    inc(P, 5);
    if (P < PEnd) and
       (P^ = #13) then
      inc(P);
    if (P < PEnd) and
       (P^ = #10) then
      inc(P);
    inc(fLine);
  end
  else if fDelimiter = #0 then
    delim := DetectDelimiter(P, PEnd - P, q)
  else
    delim := fDelimiter;
  fUsedDelimiter := delim;
  FillCharFast(fStop, SizeOf(fStop), 0);
  fStop[delim] := true;
  fStop[#13] := true;
  fStop[#10] := true;
  if strict and
     (q <> #0) then
    fStop[q] := true; // to detect any bare quote in unquoted fields
  expected := -1;
  // main parsing loop
  while P < PEnd do
  begin
    fields := 0;
    repeat
      // parse one field
      inc(fields);
      if (q <> #0) and
         (P^ = q) then
      begin
        // quoted field: first pass to find the closing quote
        inc(P);
        S := P;
        quotes := 0;
        repeat
          if P >= PEnd then
          begin
            if strict then
              RaiseCsv('unterminated quoted field');
            break;
          end;
          if P^ = q then
            if (P + 1 < PEnd) and
               (P[1] = q) then
            begin
              inc(quotes); // "" escaped quote
              inc(P, 2);
              continue;
            end
            else
              break; // closing quote
          if P^ = #10 then
            inc(fLine);
          inc(P);
        until false;
        E := P; // closing quote position
        if P < PEnd then
          inc(P); // skip closing quote
        T := P;
        while (P < PEnd) and
              (P^ <> delim) and
              (P^ <> #13) and
              (P^ <> #10) do
          inc(P); // lenient mode: keep trailing chars as-is, e.g. "a"b -> ab
        if strict and
           (P <> T) then
          RaiseCsv('unexpected character after closing quote');
        if (quotes = 0) and
           (P = T) then
          ReadQuoted(S, E - S, nil) // most common case: no temporary string
        else
        begin
          // unescape "" and append any trailing chars
          D := FastSetString(field, (E - S) - quotes + (P - T));
          while S < E do
          begin
            D^ := S^;
            inc(D);
            if S^ = q then
              inc(S, 2)
            else
              inc(S);
          end;
          MoveFast(T^, D^, P - T);
          ReadQuoted(pointer(field), length(field), @field);
        end;
      end
      else
      begin
        // unquoted field
        S := P;
        while (P < PEnd) and
              not fStop[P^] do
          inc(P);
        if (P < PEnd) and
           (P^ = q) then // only if strict
          RaiseCsv('unexpected quote in unquoted field');
        ReadCellBuffer(S, P - S, {guess=}true);
      end;
      // end of field: delimiter, end of record, or end of input
      if P >= PEnd then
        break;
      if P^ = delim then
      begin
        inc(P);
        if P >= PEnd then
        begin
          inc(fields);
          ReadCellEmpty; // trailing delimiter at end of input
          break;
        end;
        continue;
      end;
      // CRLF, LF or CR end of record
      if P^ = #13 then
      begin
        inc(P);
        if (P < PEnd) and
           (P^ = #10) then
          inc(P);
      end
      else
        inc(P);
      inc(fLine);
      break;
    until false;
    if strict and
       ((fields > 1) or
        (fCellNotEmpty > 0)) then // ignore void lines
      if expected < 0 then
        expected := fields
      else if fields <> expected then
        RaiseCsv(Make(['expected ', expected, ' fields but found ', fields]));
    if not ReadRowEnd then
      break; // MaxRows reached
  end;
end;

procedure TCsvDocument.WriteBegin;
begin
  WriterStart;
  fWriteRows := 0;
  FillCharFast(fNeedQuote, SizeOf(fNeedQuote), 0);
  if fDelimiter = #0 then
    fUsedDelimiter := ','
  else
    fUsedDelimiter := fDelimiter;
  fNeedQuote[fUsedDelimiter] := true;
  fNeedQuote['"'] := true;
  if fQuote <> #0 then
    fNeedQuote[fQuote] := true;
  fNeedQuote[#13] := true;
  fNeedQuote[#10] := true;
  if csoWriteSepLine in fCsvOptions then
  begin
    fW.AddShorter('sep=');
    fW.Add(fUsedDelimiter);
    fW.AddString(fLineBreak);
  end;
end;

procedure TCsvDocument.WriteNewRecord;
begin
  if fWriteRows > 0 then
    fW.AddString(fLineBreak);
  inc(fWriteRows);
end;

procedure TCsvDocument.WriteField(P: PUtf8Char; L: PtrInt; IsText: boolean);
var
  PEnd, S: PUtf8Char;
  q: AnsiChar;
  needquote, formula: boolean;
begin
  q := fQuote;
  if q = #0 then
    q := '"';
  // CWE-1236: prefix = + - @ TAB CR with a single quote
  formula := IsText and
             (csoEscapeFormulas in fCsvOptions) and
             (L > 0) and
             (P^ in ['=', '+', '-', '@', #9, #13]);
  case fQuoting of
    cqAll:
      needquote := true;
    cqNonNumeric:
      needquote := IsText;
  else
    needquote := false;
  end;
  if not needquote then
    if L = 0 then
      // distinguish '' from null if needed for a round-trip
      needquote := IsText and
                   (tboEmptyAsNull in fOptions)
    else if ((P[0] = ' ') and
             not formula) or
            (P[L - 1] = ' ') or
            (formula and
             fNeedQuote['''']) then
      needquote := true // preserve leading/trailing spaces
    else
    begin
      PEnd := P + L;
      S := P;
      repeat
        if fNeedQuote[S^] then
        begin
          needquote := true;
          break;
        end;
        inc(S);
      until S = PEnd;
    end;
  if not needquote then
  begin
    if formula then
      fW.Add('''');
    fW.AddNoJsonEscape(P, L);
    exit;
  end;
  // RFC 4180 quoted field, with "" escaping
  fW.Add(q);
  if formula then
  begin
    fW.Add('''');
    if q = '''' then
      fW.Add(q);
  end;
  PEnd := P + L;
  S := P;
  while P < PEnd do
  begin
    if P^ = q then
    begin
      fW.AddNoJsonEscape(S, P - S + 1); // include the quote
      fW.Add(q); // and double it
      S := P + 1;
    end;
    inc(P);
  end;
  fW.AddNoJsonEscape(S, P - S);
  fW.Add(q);
end;

procedure TCsvDocument.WriteHeader(const Names: TRawUtf8DynArray; Count: integer);
var
  i: PtrInt;
begin
  WriteNewRecord;
  for i := 0 to Count - 1 do
  begin
    if i > 0 then
      fW.Add(fUsedDelimiter);
    WriteField(pointer(Names[i]), length(Names[i]), true);
  end;
end;

procedure TCsvDocument.WriteRow(const Cells: TTabularCells; Count: integer);
var
  i, n: PtrInt;
  vd: PVarData;
  tmp: TTempUtf8;
  q: AnsiChar;
  quoted: boolean;
begin
  WriteNewRecord;
  q := fQuote;
  if q = #0 then
    q := '"';
  n := Count;
  if n < fWriteColumnCount then
    n := fWriteColumnCount; // RFC: each record should have the same fields
  for i := 0 to n - 1 do
  begin
    if i > 0 then
      fW.Add(fUsedDelimiter);
    if (i >= Count) or
       (Cells[i] = nil) then
      continue; // missing field
    vd := VarDataFromVariant(Cells[i]^);
    if vd^.VType in [varEmpty, varNull] then
      WriteField(nil, 0, false)
    else if TabularIsNumber(vd) or
            (vd^.VType = varBoolean) or
            (vd^.VType = varDate) then
    begin
      // write number/boolean/date directly, with no temporary string
      quoted := (fQuoting = cqAll) or
                ((vd^.VType in [varSingle, varDouble, varCurrency]) and
                 fNeedQuote[fDecimalSeparator]);
      if quoted then
        fW.Add(q);
      if vd^.VType = varBoolean then
        fW.Add(vd^.VBoolean)
      else if vd^.VType = varDate then
        fW.AddDateTime(vd^.VDate)
      else
        WriteNumber(vd, fDecimalSeparator);
      if quoted then
        fW.Add(q);
    end
    else
    begin
      // text (with no copy), NaN/Inf or nested TDocVariant as JSON
      quoted := VariantToTempUtf8(PVariant(vd)^, tmp); // = IsText
      WriteField(tmp.Text, tmp.Len, quoted);
      TempUtf8Done(tmp);
    end;
  end;
end;

function TCsvDocument.WriteEnd: RawByteString;
var
  u: RawUtf8;
begin
  if (fWriteRows > 0) and
     not (csoNoFinalLineBreak in fCsvOptions) then
    fW.AddString(fLineBreak);
  WriterText(u);
  if (fCodePage <> 0) and
     (fCodePage <> CP_UTF8) then
    result := TSynAnsiConvert.Engine(fCodePage).Utf8ToAnsi(u)
  else if csoWriteBom in fCsvOptions then
  begin
    // raw bytes: a #$ef#$bb#$bf literal would be UTF-8 encoded on Unicode Delphi
    FastSetRawByteString(result, nil, length(u) + 3);
    PWord(result)^ := BOM_UTF8 and $ffff;
    PByteArray(result)[2] := BOM_UTF8 shr 16;
    MoveFast(pointer(u)^, PByteArray(result)[3], length(u));
  end
  else
    result := u;
end;


{ ************ High-Level CSV Wrapper Functions }

function CsvToVariant(const Csv: RawByteString; Options: TTabularOptions;
  Delimiter: AnsiChar): variant;
var
  c: TCsvDocument;
begin
  c := TCsvDocument.CreateDelimiter(Delimiter, Options);
  try
    c.Load(Csv, result);
  finally
    c.Free;
  end;
end;

function CsvToJson(const Csv: RawByteString; Options: TTabularOptions;
  Delimiter: AnsiChar; Format: TTextWriterJsonFormat): RawUtf8;
var
  c: TCsvDocument;
begin
  c := TCsvDocument.CreateDelimiter(Delimiter, Options);
  try
    result := c.LoadToJson(Csv, Format);
  finally
    c.Free;
  end;
end;

function VariantToCsv(const Doc: variant; Options: TTabularOptions;
  Delimiter: AnsiChar): RawUtf8;
var
  c: TCsvDocument;
begin
  c := TCsvDocument.CreateDelimiter(Delimiter, Options);
  try
    result := c.Save(Doc);
  finally
    c.Free;
  end;
end;

function JsonToCsv(const Json: RawUtf8; Options: TTabularOptions;
  Delimiter: AnsiChar): RawUtf8;
var
  c: TCsvDocument;
begin
  c := TCsvDocument.CreateDelimiter(Delimiter, Options);
  try
    result := c.SaveJson(Json);
  finally
    c.Free;
  end;
end;


end.
