/// regression tests for mormot.core.tabular / mormot.core.csv / mormot.core.xlsx
program tabulartests;

{$I mormot.defines.inc}

{$ifdef MSWINDOWS}
  {$apptype console}
{$endif MSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.tabular,
  mormot.core.csv,
  mormot.core.xlsx;

var
  Passed, Failed: integer;
  Fixtures, OutDir: TFileName;

procedure Check(cond: boolean; const msg: RawUtf8);
begin
  if cond then
    inc(Passed)
  else
  begin
    inc(Failed);
    ConsoleWrite('  FAILED: %', [msg], ccLightRed);
  end;
end;

procedure CheckEqual(const a, b: RawUtf8; const msg: RawUtf8);
begin
  if a = b then
    inc(Passed)
  else
  begin
    inc(Failed);
    ConsoleWrite('  FAILED: %'#10'    got:      %'#10'    expected: %',
      [msg, a, b], ccLightRed);
  end;
end;

// compare raw bytes, with no RawByteString <-> RawUtf8 codepage conversion
procedure CheckBin(const a, b: RawByteString; const msg: RawUtf8);
begin
  if a = b then
    inc(Passed)
  else
  begin
    inc(Failed);
    ConsoleWrite('  FAILED: %'#10'    got:      %'#10'    expected: %',
      [msg, BinToHex(a), BinToHex(b)], ccLightRed);
  end;
end;

function DateVariant(dt: TDateTime): variant;
begin
  VarClear(result);
  TVarData(result).VType := varDate;
  TVarData(result).VDate := dt;
end;

function J(const v: variant): RawUtf8;
begin
  result := _Safe(v)^.ToJson;
end;

// normalize an ASCII-only JSON (with \uXXXX escapes) as J() would output it:
// the source is kept ASCII so that Delphi 7, Delphi 13 and FPC all agree
function JE(const json: RawUtf8): RawUtf8;
begin
  result := J(_JsonFast(json));
end;

// local test helpers, replacing the former one-liner API
function CsvToJson(const Csv: RawByteString; Options: TTabularOptions = TABULAR_DEFAULT;
  Delimiter: AnsiChar = ','): RawUtf8;
begin
  result := J(CsvToVariant(Csv, Options, Delimiter));
end;

function JsonToCsv(const Json: RawUtf8; Options: TTabularOptions = TABULAR_DEFAULT;
  Delimiter: AnsiChar = ','): RawUtf8;
begin
  result := VariantToCsv(_JsonFast(Json), Options, Delimiter);
end;

function LoadJ(Doc: TTabularDocument; const Data: RawByteString): RawUtf8;
var
  v: variant;
begin
  Doc.Load(Data, v);
  result := J(v);
end;

function SheetNames(Doc: TXlsxDocument; const Data: RawByteString): RawUtf8;
var
  s: TXlsxSheetDynArray;
  i: PtrInt;
begin
  s := Doc.GetSheets(Data);
  result := '';
  for i := 0 to length(s) - 1 do
    if i = 0 then
      result := s[i].Name
    else
      result := Make([result, ',', s[i].Name]);
end;

function ExpectError(c: TTabularDocument; const data: RawByteString): boolean;
var
  v: variant;
begin
  result := false;
  try
    c.Load(data, v);
  except
    on E: ETabularException do
      result := E.Message <> '';
  end;
end;

procedure TestCsvRead;
var
  c: TCsvDocument;
  v: variant;
begin
  writeln('CSV reading');
  // RFC 4180 section 2 examples
  CheckEqual(CsvToJson('aaa,bbb,ccc'#13#10'zzz,yyy,xxx'#13#10, []),
    '[["aaa","bbb","ccc"],["zzz","yyy","xxx"]]', 'rfc 2.1');
  CheckEqual(CsvToJson('aaa,bbb,ccc'#13#10'zzz,yyy,xxx', []),
    '[["aaa","bbb","ccc"],["zzz","yyy","xxx"]]', 'rfc 2.2 no final CRLF');
  CheckEqual(CsvToJson('field_name,field_name2'#13#10'aaa,bbb', [tboHeader]),
    '[{"field_name":"aaa","field_name2":"bbb"}]', 'rfc 2.3 header');
  CheckEqual(CsvToJson('"aaa","bbb","ccc"'#13#10, []),
    '[["aaa","bbb","ccc"]]', 'rfc 2.5 quoted');
  CheckEqual(CsvToJson('"aaa","b'#13#10'bb","ccc"'#13#10'zzz,yyy,xxx', []),
    '[["aaa","b\r\nbb","ccc"],["zzz","yyy","xxx"]]', 'rfc 2.6 CRLF in quotes');
  CheckEqual(CsvToJson('"aaa","b""bb","ccc"', []),
    '[["aaa","b\"bb","ccc"]]', 'rfc 2.7 escaped quote');
  // line endings and empty fields
  CheckEqual(CsvToJson('a,b'#10'1,2'#13'3,4', []),
    '[["a","b"],["1","2"],["3","4"]]', 'LF and CR line endings');
  CheckEqual(CsvToJson('a,,c,'#13#10',,,', []),
    '[["a","","c",""],["","","",""]]', 'empty fields');
  CheckEqual(CsvToJson('a,b'#13#10#13#10'c,d'#13#10, [tboSkipEmptyRows]),
    '[["a","b"],["c","d"]]', 'skip empty rows');
  CheckEqual(CsvToJson('a,b'#13#10#13#10'c,d'#13#10, []),
    '[["a","b"],[""],["c","d"]]', 'keep empty rows');
  CheckEqual(CsvToJson('', []), '[]', 'void input');
  // type guessing
  CheckEqual(CsvToJson('1,-2,3.5,1e3,007,"42",true,FALSE,1.2.3,12345678901234567890',
    [tboGuessTypes]),
    '[[1,-2,3.5,1000,"007","42",true,false,"1.2.3","12345678901234567890"]]',
    'guess types');
  CheckEqual(CsvToJson('a,b'#13#10',x', [tboHeader, tboEmptyAsNull]),
    '[{"a":null,"b":"x"}]', 'empty as null');
  CheckEqual(CsvToJson('a,b'#13#10'"",x', [tboHeader, tboEmptyAsNull]),
    '[{"a":"","b":"x"}]', 'quoted "" is not null');
  CheckEqual(CsvToJson(' a , b '#13#10' 1 ,  2', [tboHeader, tboTrimValues,
    tboGuessTypes]), '[{"a":1,"b":2}]', 'trim values');
  // header handling
  CheckEqual(CsvToJson('a,a,,b'#13#10'1,2,3,4,5'#13#10'6', [tboHeader]),
    '[{"a":"1","a_2":"2","Col3":"3","b":"4","Col5":"5"},' +
    '{"a":"6","a_2":"","Col3":"","b":""}]', 'ragged rows and unique names');
  // delimiters, BOM, encodings
  CheckEqual(CsvToJson(#$ef#$bb#$bf'x;y'#13#10'1;2', [tboHeader], ';'),
    '[{"x":"1","y":"2"}]', 'utf-8 bom + semicolon');
  CheckEqual(CsvToJson('x'#9'y'#13#10'1'#9'2', [tboHeader], #0),
    '[{"x":"1","y":"2"}]', 'auto-detect tab');
  CheckEqual(CsvToJson('"a;b";c;d'#13#10'1;2;3', [], #0),
    '[["a;b","c","d"],["1","2","3"]]', 'auto-detect semicolon');
  c := TCsvDocument.Create([tboHeader, tboGuessTypes]);
  try
    c.DecimalSeparator := ',';
    c.LoadFromFile(Fixtures + 'excel_de.csv', v);
    CheckEqual(J(v), JE('[{"Name":"M\u00fcller","Betrag":1.5,"Datum":"31.01.2024"},' +
      '{"Name":"Gr\u00fc\u00dfe","Betrag":-2.25,"Datum":"01.02.2024"}]'),
      'sep=; line + cp1252 + decimal comma');
    Check(c.UsedDelimiter = ';', 'UsedDelimiter');
    c.Delimiter := #0;
    c.LoadFromFile(Fixtures + 'utf16.csv', v);
    CheckEqual(J(v), JE('[{"a":"\u00c4","b":"\u20ac"}]'), 'utf-16 bom');
    c.Delimiter := ',';
    c.DecimalSeparator := '.';
    c.Options := [tboHeader];
    c.LoadFromFile(Fixtures + 'python.csv', v);
    CheckEqual(J(v), '[{"id":"1","text":"He said \"hi\"","num":"1.5"},' +
      '{"id":"2","text":"multi\r\nline","num":"-3"},' +
      '{"id":"3","text":"a,b;c","num":""},{"id":"4","text":"","num":"007"}]',
      'python csv module output');
    // MaxRows
    c.MaxRows := 2;
    c.LoadFromFile(Fixtures + 'python.csv', v);
    Check(_Safe(v)^.Count = 2, 'MaxRows');
    c.MaxRows := 0;
    // lenient vs strict
    c.Options := [];
    CheckEqual(LoadJ(c, 'a"b,"c"d,"e'), '[["a\"b","cd","e"]]', 'lenient');
    c.CsvOptions := [csoStrict];
    Check(ExpectError(c, 'a"b,c'), 'strict bare quote');
    Check(ExpectError(c, '"c"d,e'), 'strict char after quote');
    Check(ExpectError(c, '"abc'), 'strict unterminated');
    Check(ExpectError(c, 'a,b'#13#10'c'), 'strict field count');
    Check(not ExpectError(c, 'a,b'#13#10'c,d'#13#10), 'strict valid');
  finally
    c.Free;
  end;
end;

procedure TestCsvWrite;
var
  c: TCsvDocument;
  v: variant;
  s: RawByteString;
begin
  writeln('CSV writing');
  v := _JsonFast('[{"a":1,"b":"x,y","c":"say \"hi\""},{"b":"multi'#13#10'line",' +
    '"d":true},{"a":2.5,"c":null,"e":" pad "}]');
  CheckEqual(VariantToCsv(v),
    'a,b,c,d,e'#13#10'1,"x,y","say ""hi""",,'#13#10',"multi'#13#10'line",,true,'#13#10 +
    '2.5,,,," pad "'#13#10, 'union of columns + RFC quoting');
  CheckEqual(VariantToCsv(_JsonFast('[[1,"a"],["b"]]'), []),
    '1,a'#13#10'b'#13#10, 'array rows');
  CheckEqual(JsonToCsv('[{"x":1}]', [tboHeader], ';'), 'x'#13#10'1'#13#10, 'json');
  c := TCsvDocument.Create;
  try
    c.Columns := TRawUtf8DynArrayFrom(['c', 'a']);
    c.Delimiter := ';';
    c.DecimalSeparator := ',';
    c.Quoting := cqNonNumeric;
    c.CsvOptions := [csoNoFinalLineBreak, csoEscapeFormulas, csoWriteSepLine];
    c.LineBreak := #10;
    s := c.Save(_JsonFast('[{"a":1.25,"c":"=SUM(A1)","z":0},{"a":3}]'));
    CheckEqual(s, 'sep=;'#10'"c";"a"'#10'"''=SUM(A1)";1,25'#10';3',
      'columns, nonnumeric quoting, formula escape');
    c.Columns := nil;
    c.Delimiter := ',';
    c.DecimalSeparator := '.';
    c.Quoting := cqMinimal;
    c.CsvOptions := [csoWriteBom];
    c.LineBreak := #13#10;
    s := c.Save(_JsonFast('[{"n":"\u00c4"}]'));
    CheckBin(s, HexToBin('efbbbf6e0d0ac3840d0a'), 'bom');
    c.CsvOptions := [];
    c.CodePage := CP_WINANSI;
    s := c.Save(_JsonFast('[{"n":"\u00c4\u20ac"}]'));
    CheckBin(s, HexToBin('6e0d0ac4800d0a'), 'cp1252 output');
    c.CodePage := 0;
    // date/time and currency values
    v := _Arr([_ObjFast(['d', DateVariant(EncodeDate(2024, 12, 24) +
      EncodeTime(18, 30, 0, 0))])], JSON_FAST);
    CheckEqual(c.Save(v), 'd'#13#10'2024-12-24T18:30:00'#13#10, 'date');
    // round-trip with tboEmptyAsNull keeps "" vs null distinction
    c.Options := [tboHeader, tboEmptyAsNull, tboGuessTypes];
    s := c.Save(_JsonFast('[{"a":"","b":null,"c":"007","d":7}]'));
    CheckEqual(s, 'a,b,c,d'#13#10'"",,007,7'#13#10, 'null vs void string');
    c.Load(s, v);
    CheckEqual(J(v), '[{"a":"","b":null,"c":"007","d":7}]', 'csv round-trip');
  finally
    c.Free;
  end;
end;

procedure TestXlsxRead;
var
  x: TXlsxDocument;
  v: variant;
  dt: TDateTime;
begin
  writeln('XLSX reading');
  x := TXlsxDocument.Create([tboHeader, tboEmptyAsNull]);
  try
    CheckEqual(SheetNames(x, StringFromFile(Fixtures + 'openpyxl.xlsx')),
      'Data,Zweite Tabelle,Hidden', 'sheet names');
    x.LoadFromFile(Fixtures + 'openpyxl.xlsx', v);
    CheckEqual(J(v),
      '[{"id":1,"name":"Alice","amount":1234.5,"flag":true,"date":"2024-01-31",' +
      '"datetime":"2024-02-29T13:45:30","time":"T08:30:00","pct":0.25,' +
      '"formula":null},' + // formula with no cached value
      '{"id":2,"name":"Bob\nZeile 2","amount":-0.001,"flag":false,"date":' +
      '"1900-01-01","datetime":"1999-12-31T23:59:59","time":"T23:00:00",' +
      '"pct":1,"formula":null},' +
      '{"id":3,"name":"  spaces  ","amount":12345678901234,"flag":null,' +
      '"date":null,"datetime":null,"time":null,"pct":null,"formula":null},' +
      '{"id":null,"name":null,"amount":null,"flag":null,"date":null,' + // gap row
      '"datetime":null,"time":null,"pct":null,"formula":null},' +
      '{"id":6,"name":null,"amount":"sparse","flag":null,"date":null,' +
      '"datetime":null,"time":null,"pct":null,"formula":null}]',
      'openpyxl data sheet');
    Check(TabularIsDate(_Safe(_Safe(v)^.Values[0])^.Value['date'], dt) and
      (dt = EncodeDate(2024, 1, 31)), 'date is varDate');
    x.SheetName := 'zweite tabelle';
    x.LoadFromFile(Fixtures + 'openpyxl.xlsx', v);
    CheckEqual(J(v), '[{"a":"x","b":1.5}]', 'sheet by name');
    x.SheetName := '';
    x.LoadSheets(StringFromFile(Fixtures + 'openpyxl.xlsx'), v, {hidden=}false);
    CheckEqual(RawUtf8ArrayToCsv(_Safe(v)^.GetNames), 'Data,Zweite Tabelle',
      'LoadSheets without hidden');
    x.LoadFromFile(Fixtures + 'date1904.xlsx', v);
    CheckEqual(J(v), '[{"d":"2020-05-17"}]', '1904 date system');
    Check(x.Date1904, 'Date1904 property');
    // file written by our TXlsxDocument then re-saved by LibreOffice Calc
    x.LoadFromFile(Fixtures + 'libreoffice.xlsx', v);
    CheckEqual(J(v), JE(
      '[{"Name":"M\u00fcller","Age":42,"Price":3.25,"Ok":true,"When":"2024-02-29",' +
      '"Extra":null,"Big":null},{"Name":"a \"q\" <b> & _x0041_ \u0001ctl",' +
      '"Age":-7,"Price":0.001,"Ok":false,"When":"1900-01-01T12:00:00",' +
      '"Extra":"{\"nested\":[1,2]}","Big":null},{"Name":" lead","Age":null,' +
      '"Price":null,"Ok":null,"When":null,"Extra":null,"Big":1234567890123456}]'),
      'libreoffice re-saved file');
    x.Options := [tboHeader];
    x.LoadFromFile(Fixtures + 'handmade.xlsx', v);
    CheckEqual(J(v),
      '[{"col A":"","col B":"","col C":"","col A_2":""},' + // gap row 2
      '{"col A":"Bold and plain","col B":"line1\r\nline2 _x0041_ <tag>",' +
      '"col C":"","col A_2":"ab"},' +
      '{"col A":true,"col B":"#DIV/0!","col C":0.0015,"col A_2":-42,"Col5":7}]',
      'handmade: ns prefix, inlineStr, rich text, rPh, escapes, types');
    x.Options := [];
    x.LoadFromFile(Fixtures + 'handmade.xlsx', v);
    Check(_Safe(v)^.Count = 4, 'empty row 2 kept without tboSkipEmptyRows');
    Check(ExpectError(x, 'not a zip file at all, just text'), 'invalid input');
    x.SheetName := 'missing';
    Check(ExpectError(x, StringFromFile(Fixtures + 'openpyxl.xlsx')), 'missing sheet');
  finally
    x.Free;
  end;
end;

procedure TestXlsxWrite;
var
  x: TXlsxDocument;
  v, w: variant;
  bin: RawByteString;
begin
  writeln('XLSX writing');
  v := _JsonFast('[{"Name":"M\u00fcller","Age":42,"Price":3.25,"Ok":true},' +
    '{"Name":"a \"q\" <b> & _x0041_ '#1'ctl","Age":-7,"Price":1e-3,"Ok":false,' +
    '"Extra":{"nested":[1,2]}},{"Name":" lead","Big":1234567890123456}]');
  _Safe(v)^.Values[0].When := EncodeDate(2024, 2, 29);
  // TDateTime arithmetic is a plain float: DateVariant() keeps the varDate type
  _Safe(v)^.Values[1].When := DateVariant(EncodeDate(1900, 1, 1) +
    EncodeTime(12, 0, 0, 0));
  x := TXlsxDocument.Create([tboHeader, tboEmptyAsNull]);
  try
    x.XlsxOptions := [xoHeaderBold, xoFreezeHeader, xoAutoFilter, xoAutoWidth];
    bin := x.Save(v);
    FileFromString(bin, OutDir + 'written.xlsx');
    x.Load(bin, w);
    CheckEqual(J(w), JE(
      '[{"Name":"M\u00fcller","Age":42,"Price":3.25,"Ok":true,"When":"2024-02-29",' +
      '"Extra":null,"Big":null},' +
      '{"Name":"a \"q\" <b> & _x0041_ \u0001ctl","Age":-7,"Price":0.001,' +
      '"Ok":false,"When":"1900-01-01T12:00:00","Extra":"{\"nested\":[1,2]}",' +
      '"Big":null},' +
      '{"Name":" lead","Age":null,"Price":null,"Ok":null,"When":null,' +
      '"Extra":null,"Big":1234567890123456}]'), 'xlsx round-trip');
    // several sheets as a TDocVariant object, with sanitized names
    bin := x.Save(_JsonFast('{"Sales/2024":[{"a":1}],"Sales/2024 ":[[1,2],[3]],' +
      '"[]":[]}'));
    FileFromString(bin, OutDir + 'sheets.xlsx');
    CheckEqual(SheetNames(x, bin),
      'Sales_2024,Sales_2024 (2),__', 'sheet names sanitized');
    x.LoadSheets(bin, w);
    // [[1,2],[3]] with tboHeader: first row [1,2] are the column names
    CheckEqual(J(w), '{"Sales_2024":[{"a":1}],"Sales_2024 (2)":[{"1":3,' +
      '"2":null}],"__":[]}', 'LoadSheets');
    x.Options := [];
    x.SheetName := 'Matrix';
    bin := x.Save(_JsonFast('[[1,"two",3.5],[],[null,true]]'));
    FileFromString(bin, OutDir + 'matrix.xlsx');
    x.SheetName := '';
    x.Load(bin, w);
    CheckEqual(J(w), '[[1,"two",3.5],[""],["",true]]', 'array rows');
    CheckEqual(XlsxColumnName(0) + XlsxColumnName(25) + XlsxColumnName(26) +
      XlsxColumnName(701) + XlsxColumnName(702), 'AZAAZZAAA', 'column names');
    Check(XlsxColumnIndex('XFD1048576', 10) = 16383, 'column index');
    Check(XlsxIsDateFormat('dd/mm/yyyy') and XlsxIsDateFormat('[h]:mm') and
      not XlsxIsDateFormat('0.00E+00') and not XlsxIsDateFormat('"Day "0') and
      not XlsxIsDateFormat('[Red]#,##0') and not XlsxIsDateFormat('General'),
      'date formats');
  finally
    x.Free;
  end;
end;

procedure TestPerformance;
var
  c: TCsvDocument;
  x: TXlsxDocument;
  doc, v: TDocVariantData;
  row: variant;
  i: integer;
  csv: RawByteString;
  bin: RawByteString;
  t: Int64;
begin
  writeln('Performance');
  FillCharFast(v, SizeOf(v), 0); // local record: Load() clears it first
  doc.InitFast(100000, dvArray);
  for i := 1 to 100000 do
  begin
    row := _ObjFast(['id', i, 'name', Make(['name ', i]), 'value', i / 7,
      'flag', odd(i), 'text', 'some "quoted", text']);
    doc.AddItem(row);
  end;
  c := TCsvDocument.Create([tboHeader, tboGuessTypes]);
  try
    t := GetTickCount64;
    csv := c.SaveDoc(doc);
    writeln('  CSV write 100k rows: ', GetTickCount64 - t, ' ms, ',
      KB(length(csv)));
    t := GetTickCount64;
    c.Load(csv, variant(v));
    writeln('  CSV read 100k rows:  ', GetTickCount64 - t, ' ms');
    Check(v.Count = 100000, 'csv count');
  finally
    c.Free;
  end;
  x := TXlsxDocument.Create([tboHeader]);
  try
    t := GetTickCount64;
    bin := x.SaveDoc(doc);
    writeln('  XLSX write 100k rows: ', GetTickCount64 - t, ' ms, ',
      KB(length(bin)));
    FileFromString(bin, OutDir + 'big.xlsx');
    v.Clear;
    t := GetTickCount64;
    x.Load(bin, variant(v));
    writeln('  XLSX read 100k rows:  ', GetTickCount64 - t, ' ms');
    Check(v.Count = 100000, 'xlsx count');
    CheckEqual(VariantToUtf8(v.Values[99999].name), 'name 100000', 'xlsx last row');
    CheckEqual(_Safe(v.Values[99998])^.ToJson, _Safe(doc.Values[99998])^.ToJson,
      'xlsx row content');
  finally
    x.Free;
  end;
end;

begin
  Fixtures := ExtractFilePath(ParamStr(0)) + '../fixtures/';
  OutDir := ExtractFilePath(ParamStr(0));
  if ParamCount > 0 then
    Fixtures := IncludeTrailingPathDelimiter(ParamStr(1));
  TestCsvRead;
  TestCsvWrite;
  TestXlsxRead;
  TestXlsxWrite;
  TestPerformance;
  writeln;
  writeln('passed: ', Passed, '  failed: ', Failed);
  if Failed > 0 then
    ExitCode := 1;
end.
