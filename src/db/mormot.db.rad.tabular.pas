/// Tabular TDocVariant Rows Import/Export via VCL/LCL/FMX TDataSet
// - extension unit for the mORMot 2 Open Source framework
// - licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.db.rad.tabular;

{
  *****************************************************************************

   Bridge between TTabularDocument rows (CSV/XLSX) and TDataSet
    - TTabularDataSet: Read-Only Virtual TDataSet over TDocVariant Rows
    - Copy Rows into any Editable TDataSet (TClientDataSet, TFDMemTable...)
    - Export any TDataSet into TDocVariant Rows

   Typical use:
   ! rows := XlsxToVariant(StringFromFile('artikel.xlsx'));
   ! DataSource1.DataSet := TTabularDataSet.Create(self, rows);  // read-only
   ! // or into an editable in-memory dataset:
   ! TabularFieldDefs(rows, ClientDataSet1.FieldDefs);
   ! ClientDataSet1.CreateDataSet;
   ! TabularAppendToDataSet(rows, ClientDataSet1);
   ! // and back to CSV/XLSX:
   ! FileFromString(VariantToCsv(DataSetToTabular(Query1)), 'export.csv');

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.buffers,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.tabular,
  mormot.db.core,
  mormot.db.rad,
  mormot.db.rad.ui,
  mormot.db.tabular,
  {$ifdef ISDELPHIXE2}
  Data.DB,
  Data.FMTBcd;
  {$else}
  DB,
  FMTBcd;
  {$endif ISDELPHIXE2}


{ ************ TTabularDataSet: Read-Only Virtual TDataSet over TDocVariant Rows }

const
  /// ftUtf8 columns longer than this number of chars are defined as memo
  TABULAR_MAXSTRINGFIELD = 4000;

type
  /// read-only virtual TDataSet over TDocVariant rows, with no data copy
  // - in contrast to TDocVariantArrayDataSet, the field types and string
  // widths are inferred from ALL rows via TabularColumns() - not only from
  // the first row - so that e.g. a column starting with null, or mixing
  // integers and floats, or with long text, is properly defined
  // - array rows (no tboHeader) are exposed with 'Col1', 'Col2'... fields
  // - all-boolean columns are defined as TBooleanField
  TTabularDataSet = class(TDocVariantArrayDataSet)
  protected
    fRows: variant;
    fTabularColumns: TTabularColumns;
    fStringAsAnsi: boolean;
    procedure InternalInitFieldDefs; override;
  public
    /// initialize and open the virtual TDataSet from a TDocVariant array
    // - StringAsAnsi=true defines text columns as ftString/ftMemo instead
    // of ftWideString/ftWideMemo, e.g. for some Delphi 7 UI components
    constructor Create(aOwner: TComponent; const Rows: variant;
      StringAsAnsi: boolean = false); reintroduce;
    /// the columns layout, as inferred from the rows
    property TabularColumns: TTabularColumns
      read fTabularColumns;
  end;

/// fill some TFieldDefs from the columns layout inferred from TDocVariant rows
// - to be called before e.g. TClientDataSet.CreateDataSet,
// TFDMemTable.CreateDataSet or TBufDataset.CreateDataset
// - ftInt64 = ftLargeint (or ftBoolean if all values are booleans),
// ftDouble/ftCurrency = ftFloat, ftDate = ftDateTime, ftUtf8 = ftWideString
// with the maximum width (or ftWideMemo if > TABULAR_MAXSTRINGFIELD chars)
procedure TabularFieldDefs(const Rows: variant; Defs: TFieldDefs;
  StringAsAnsi: boolean = false); overload;

/// fill some TFieldDefs from an already computed columns layout
procedure TabularFieldDefs(const Columns: TTabularColumns; Defs: TFieldDefs;
  StringAsAnsi: boolean = false); overload;


{ ************ Copy Rows into any Editable TDataSet }

type
  /// options for TabularAppendToDataSet()
  // - tdoIgnoreUnknownFields: ignore row fields with no matching TField -
  // default is to raise an ETabularDataSet exception
  // - tdoEmptyFirst: delete all existing records before appending the rows
  // - tdoKeepControls: don't call DisableControls/EnableControls
  TTabularDataSetOption = (
    tdoIgnoreUnknownFields,
    tdoEmptyFirst,
    tdoKeepControls);

  /// set of options for TabularAppendToDataSet()
  TTabularDataSetOptions = set of TTabularDataSetOption;

  /// exception raised by TabularAppendToDataSet()
  ETabularDataSet = class(ETabularException);

/// append TDocVariant rows (e.g. from CSV/XLSX) into an opened TDataSet
// - Dest can be any editable dataset: TClientDataSet, TFDMemTable, TBufDataset,
// kbmMemTable, or a query/table component bound to a database table
// - row fields are matched by name (case-insensitive) with Dest.Fields, and
// values converted to each TField.DataType (e.g. '42' into an integer field)
// - returns the number of appended records
// - on conversion error, the current record is cancelled and an
// ETabularDataSet exception is raised with the row number and field name
function TabularAppendToDataSet(const Rows: variant; Dest: TDataSet;
  Options: TTabularDataSetOptions = []): integer;

/// assign a variant cell value to a TField, with proper type conversion
// - null/empty values clear the field
// - returns false if the value could not be converted (e.g. 'abc' to integer)
function TabularValueToField(const Value: variant; Field: TField): boolean;


{ ************ Export any TDataSet into TDocVariant Rows }

/// convert all records of a TDataSet into a TDocVariant array of objects
// - ready to be serialized by TCsvDocument/TXlsxDocument.Save()
// - integers as Int64, floats as double, TBcdField as currency, booleans,
// dates as varDate (i.e. XLSX date cells), text as RawUtf8, BLOBs as Base64
// - the current position of the dataset is restored after the process
function DataSetToTabular(Source: TDataSet; MaxRows: integer = 0): variant;

/// convert the current record of a TDataSet into a TDocVariant object value
function FieldToTabularValue(Field: TField; var Value: variant): boolean;


implementation


{ ************ TTabularDataSet: Read-Only Virtual TDataSet over TDocVariant Rows }

function AllBooleans(const Rows: TDocVariantData; Col: PTabularColumn;
  ColIndex: integer): boolean;
var
  r: PtrInt;
  row: PDocVariantData;
  v: PVariant;
  vd: PVarData;
begin
  result := false;
  if Col^.FieldType <> ftInt64 then
    exit;
  for r := 0 to Rows.Count - 1 do
    if _Safe(Rows.Values[r], row) then
    begin
      v := TabularCell(row^, Col, ColIndex);
      if v = nil then
        continue;
      vd := pointer(v);
      while vd^.VType = varVariantByRef do
        vd := vd^.VPointer;
      if not (vd^.VType in [varEmpty, varNull, varBoolean]) then
        exit;
    end;
  result := true;
end;

procedure DefineFields(const Columns: TTabularColumns; Rows: PDocVariantData;
  Defs: TFieldDefs; StringAsAnsi: boolean);
var
  f: PtrInt;
  name: string;
  ft: TFieldType;
  size: integer;
begin
  Defs.Clear;
  for f := 0 to length(Columns) - 1 do
  begin
    size := 0;
    case Columns[f].FieldType of
      mormot.db.core.ftInt64:
        if (Rows <> nil) and
           AllBooleans(Rows^, @Columns[f], f) then
          ft := ftBoolean
        else
          ft := ftLargeint;
      mormot.db.core.ftDouble,
      mormot.db.core.ftCurrency:
        ft := ftFloat;
      mormot.db.core.ftDate:
        ft := ftDateTime;
      mormot.db.core.ftBlob:
        ft := ftBlob;
    else
      if Columns[f].MaxLength > TABULAR_MAXSTRINGFIELD then
        {$ifdef HASDBFTWIDE}
        if not StringAsAnsi then
          ft := ftWideMemo
        else
        {$endif HASDBFTWIDE}
          ft := ftMemo
      else
      begin
        if StringAsAnsi then
          ft := ftString
        else
          ft := ftWideString;
        size := Columns[f].MaxLength;
        if size < 1 then
          size := 1;
      end;
    end;
    Utf8ToStringVar(Columns[f].Name, name);
    Defs.Add(name, ft, size, false);
  end;
end;

procedure TabularFieldDefs(const Columns: TTabularColumns; Defs: TFieldDefs;
  StringAsAnsi: boolean);
begin
  DefineFields(Columns, nil, Defs, StringAsAnsi);
end;

procedure TabularFieldDefs(const Rows: variant; Defs: TFieldDefs;
  StringAsAnsi: boolean);
var
  dv: PDocVariantData;
begin
  if _SafeArray(Rows, dv) then
    DefineFields(TabularColumns(dv^), dv, Defs, StringAsAnsi)
  else
    Defs.Clear;
end;

// ensure all rows are objects with all columns in the same order
// - as expected by TDocVariantArrayDataSet, which only supports objects, and
// whose GetRowFieldData() reads Names[f] with no "f < Count" bound check
procedure RowsAsObjects(const Rows: variant; const Cols: TTabularColumns;
  var Dest: variant);
var
  src, row, obj: PDocVariantData;
  r, c: PtrInt;
  v: PVariant;
  uniform: boolean;
begin
  VarClear(Dest);
  if not _SafeArray(Rows, src) then
  begin
    TDocVariantData(Dest).Init(JSON_FAST, dvArray);
    exit;
  end;
  uniform := true;
  for r := 0 to src^.Count - 1 do
    if not _Safe(src^.Values[r], row) or
       not row^.IsObject or
       (row^.Count <> length(Cols)) then
    begin
      uniform := false;
      break;
    end
    else
      for c := 0 to length(Cols) - 1 do
        if row^.Names[c] <> Cols[c].Name then
        begin
          uniform := false;
          break;
        end;
  if uniform then
  begin
    Dest := Rows; // by reference with JSON_FAST
    exit;
  end;
  TDocVariantData(Dest).Init(JSON_FAST, dvArray);
  TDocVariantData(Dest).Capacity := src^.Count;
  for r := 0 to src^.Count - 1 do
  begin
    obj := pointer(TDocVariantData(Dest).NewItem);
    obj^.Init(JSON_FAST, dvObject);
    obj^.Capacity := length(Cols);
    if not _Safe(src^.Values[r], row) then
      row := nil;
    for c := 0 to length(Cols) - 1 do
    begin
      v := nil;
      if row <> nil then
        v := TabularCell(row^, @Cols[c], c);
      if v = nil then
        obj^.AddValue(Cols[c].Name, Null)
      else
        obj^.AddValue(Cols[c].Name, v^);
    end;
  end;
end;

constructor TTabularDataSet.Create(aOwner: TComponent; const Rows: variant;
  StringAsAnsi: boolean);
var
  names: TRawUtf8DynArray;
  types: array of TSqlDBFieldType;
  dv: PDocVariantData;
  i: PtrInt;
begin
  fTabularColumns := mormot.db.tabular.TabularColumns(Rows);
  fStringAsAnsi := StringAsAnsi;
  RowsAsObjects(Rows, fTabularColumns, fRows);
  SetLength(names, length(fTabularColumns));
  SetLength(types, length(fTabularColumns));
  for i := 0 to length(fTabularColumns) - 1 do
  begin
    names[i] := fTabularColumns[i].Name;
    types[i] := fTabularColumns[i].FieldType;
    if types[i] = mormot.db.core.ftCurrency then
      types[i] := mormot.db.core.ftDouble; // TCurrencyField is a TFloatField
  end;
  dv := _Safe(fRows);
  inherited Create(aOwner, dv^.Values, dv^.Count, names, types);
  Open;
end;

procedure TTabularDataSet.InternalInitFieldDefs;
begin
  DefineFields(fTabularColumns, _Safe(fRows), FieldDefs, fStringAsAnsi);
end;


{ ************ Copy Rows into any Editable TDataSet }

function TabularValueToField(const Value: variant; Field: TField): boolean;
var
  vd: PVarData;
  text: RawUtf8;
  istext: boolean;
  i64: Int64;
  d: double;
  dt: TDateTime;
  err: integer;
  bcd: TBcd;
  blob: TRawByteStringStream;
begin
  result := true;
  vd := @Value;
  while vd^.VType = varVariantByRef do
    vd := vd^.VPointer;
  if (vd^.VType = varEmpty) or
     (vd^.VType = varNull) then
  begin
    Field.Clear;
    exit;
  end;
  case Field.DataType of
    ftBoolean:
      if vd^.VType = varBoolean then
        Field.AsBoolean := vd^.VBoolean
      else if VariantToInt64(PVariant(vd)^, i64) then
        Field.AsBoolean := i64 <> 0
      else
      begin
        TabularValueToText(PVariant(vd)^, text, istext);
        if IdemPropNameU(text, 'true') or
           (text = '1') then
          Field.AsBoolean := true
        else if IdemPropNameU(text, 'false') or
                (text = '0') then
          Field.AsBoolean := false
        else if text = '' then
          Field.Clear
        else
          result := false;
      end;
    ftSmallint,
    ftInteger,
    ftWord,
    ftAutoInc,
    ftLargeint:
      begin
        if not VariantToInt64(PVariant(vd)^, i64) then
        begin
          TabularValueToText(PVariant(vd)^, text, istext);
          if text = '' then
          begin
            Field.Clear;
            exit;
          end;
          i64 := GetInt64(pointer(text), err);
          if err <> 0 then
          begin
            result := false;
            exit;
          end;
        end;
        if Field.DataType = ftLargeint then
          TLargeintField(Field).AsLargeInt := i64
        else
          Field.AsInteger := i64;
      end;
    ftFloat,
    ftCurrency,
    ftBCD:
      begin
        if not VariantToDouble(PVariant(vd)^, d) then
        begin
          TabularValueToText(PVariant(vd)^, text, istext);
          if text = '' then
          begin
            Field.Clear;
            exit;
          end;
          d := GetExtended(pointer(text), err);
          if err <> 0 then
          begin
            result := false;
            exit;
          end;
        end;
        if Field.DataType = ftBCD then
          Field.AsCurrency := d
        else
          Field.AsFloat := d;
      end;
    ftFMTBcd:
      begin
        TabularValueToText(PVariant(vd)^, text, istext, '.');
        if TryUtf8ToBcd(text, bcd) then
          Field.AsBCD := bcd
        else
          result := false;
      end;
    ftDate,
    ftTime,
    ftDateTime,
    ftTimeStamp:
      if TabularIsDate(PVariant(vd)^, dt) then
        Field.AsDateTime := dt
      else if VariantToDouble(PVariant(vd)^, d) then
        Field.AsDateTime := d
      else
      begin
        TabularValueToText(PVariant(vd)^, text, istext);
        dt := Iso8601ToDateTime(text);
        if dt <> 0 then
          Field.AsDateTime := dt
        else if text = '' then
          Field.Clear
        else
          result := false;
      end;
    ftBlob,
    ftGraphic,
    ftBytes,
    ftVarBytes:
      begin
        TabularValueToText(PVariant(vd)^, text, istext);
        blob := TRawByteStringStream.Create(text);
        try
          (Field as TBlobField).LoadFromStream(blob);
        finally
          blob.Free;
        end;
      end;
    ftVariant:
      Field.AsVariant := PVariant(vd)^;
    {$ifdef HASDBFTWIDE}
    ftWideMemo,
    ftFixedWideChar,
    {$endif HASDBFTWIDE}
    ftWideString:
      begin
        TabularValueToText(PVariant(vd)^, text, istext);
        {$ifdef UNICODE}
        Field.AsString := Utf8ToString(text);
        {$else}
        {$ifdef FPC}
        Field.AsWideString := Utf8ToWideString(text);
        {$else}
        // Delphi 7/2007: TField.AsWideString does not exist
        if Field is TWideStringField then
          TWideStringField(Field).Value := Utf8ToWideString(text)
        else
          Field.AsString := Utf8ToString(text);
        {$endif FPC}
        {$endif UNICODE}
      end;
  else
    begin
      // ftString, ftFixedChar, ftMemo, ftGuid and any other type
      TabularValueToText(PVariant(vd)^, text, istext);
      Field.AsString := Utf8ToString(text);
    end;
  end;
end;

function TabularAppendToDataSet(const Rows: variant; Dest: TDataSet;
  Options: TTabularDataSetOptions): integer;
var
  dv, row: PDocVariantData;
  cols: TTabularColumns;
  fields: array of TField;
  c, r: PtrInt;
  cell: PVariant;
begin
  result := 0;
  if Dest = nil then
    raise ETabularDataSet.Create('TabularAppendToDataSet(nil)');
  if not _SafeArray(Rows, dv) then
    exit;
  if not Dest.Active then
    Dest.Open;
  cols := mormot.db.tabular.TabularColumns(dv^);
  SetLength(fields, length(cols));
  for c := 0 to length(cols) - 1 do
  begin
    fields[c] := Dest.FindField(Utf8ToString(cols[c].Name));
    if fields[c] = nil then
      fields[c] := Dest.FindField(Utf8ToString(cols[c].SqlName));
    if (fields[c] = nil) and
       not (tdoIgnoreUnknownFields in Options) then
      raise ETabularDataSet.CreateUtf8('TabularAppendToDataSet: no % field in %',
        [cols[c].Name, Dest]);
  end;
  if not (tdoKeepControls in Options) then
    Dest.DisableControls;
  try
    if tdoEmptyFirst in Options then
    begin
      Dest.First;
      while not Dest.IsEmpty do
        Dest.Delete;
    end;
    for r := 0 to dv^.Count - 1 do
    begin
      if not _Safe(dv^.Values[r], row) then
        continue;
      Dest.Append;
      try
        for c := 0 to length(cols) - 1 do
          if fields[c] <> nil then
          begin
            cell := TabularCell(row^, @cols[c], c);
            if cell = nil then
              fields[c].Clear
            else if not TabularValueToField(cell^, fields[c]) then
              raise ETabularDataSet.CreateUtf8('TabularAppendToDataSet: row % ' +
                'field % value % is not a valid %', [r + 1, cols[c].Name, cell^,
                FieldTypeNames[fields[c].DataType]]);
          end;
        Dest.Post;
      except
        Dest.Cancel;
        raise;
      end;
      inc(result);
    end;
  finally
    if not (tdoKeepControls in Options) then
      Dest.EnableControls;
  end;
end;


{ ************ Export any TDataSet into TDocVariant Rows }

function FieldToTabularValue(Field: TField; var Value: variant): boolean;
var
  u: RawUtf8;
  blob: TRawByteStringStream;
begin
  result := true;
  VarClear(Value);
  if Field.IsNull then
  begin
    SetVariantNull(Value);
    exit;
  end;
  case Field.DataType of
    ftBoolean:
      Value := Field.AsBoolean;
    ftSmallint,
    ftInteger,
    ftWord,
    ftAutoInc:
      Value := Int64(Field.AsInteger);
    ftLargeint:
      Value := TLargeintField(Field).AsLargeInt;
    ftFloat,
    ftCurrency: // TCurrencyField is a TFloatField
      Value := Field.AsFloat;
    ftBCD:
      Value := Field.AsCurrency;
    ftFMTBcd:
      begin
        BcdToUtf8(Field.AsBcd, u);
        TextToVariant(u, {double=}true, Value); // currency, Int64 or double
      end;
    ftDate,
    ftTime,
    ftDateTime,
    ftTimeStamp:
      begin
        TVarData(Value).VType := varDate;
        TVarData(Value).VDate := Field.AsDateTime;
      end;
    {$ifdef HASDBFTWIDE}
    ftWideMemo,
    ftFixedWideChar,
    {$endif HASDBFTWIDE}
    ftWideString:
      begin
        {$ifdef UNICODE}
        StringToUtf8(Field.AsString, u);
        {$else}
        {$ifdef FPC}
        u := WideStringToUtf8(Field.AsWideString);
        {$else}
        if Field is TWideStringField then
          u := WideStringToUtf8(TWideStringField(Field).Value)
        else
          StringToUtf8(Field.AsString, u);
        {$endif FPC}
        {$endif UNICODE}
        RawUtf8ToVariant(u, Value);
      end;
    ftBlob,
    ftGraphic,
    ftBytes,
    ftVarBytes,
    ftOraBlob:
      begin
        blob := TRawByteStringStream.Create;
        try
          (Field as TBlobField).SaveToStream(blob);
          RawUtf8ToVariant(BinToBase64(blob.DataString), Value);
        finally
          blob.Free;
        end;
      end;
    ftVariant:
      Value := Field.AsVariant;
  else
    begin
      // ftString, ftFixedChar, ftMemo, ftGuid...
      StringToUtf8(Field.AsString, u);
      RawUtf8ToVariant(u, Value);
    end;
  end;
end;

function DataSetToTabular(Source: TDataSet; MaxRows: integer): variant;
var
  r: TDocVariantData absolute result;
  proto: TDocVariantData;
  v: PVariant;
  f, n: PtrInt;
  bm: TBookmark;
begin
  VarClear(result);
  r.Init(JSON_FAST_FLOAT, dvArray);
  if (Source = nil) or
     not Source.Active then
    exit;
  // object prototype with the field names
  proto.Init(JSON_FAST_FLOAT, dvObject);
  proto.Capacity := Source.FieldCount;
  for f := 0 to Source.FieldCount - 1 do
    proto.AddValue(StringToUtf8(Source.Fields[f].FieldName), Null);
  Source.DisableControls;
  bm := Source.GetBookmark;
  try
    n := 0;
    Source.First;
    while not Source.Eof do
    begin
      v := PDocVariantData(r.NewItem)^.InitFrom(proto, {values=}false);
      for f := 0 to Source.FieldCount - 1 do
      begin
        FieldToTabularValue(Source.Fields[f], v^);
        inc(v);
      end;
      inc(n);
      if (MaxRows > 0) and
         (n >= MaxRows) then
        break;
      Source.Next;
    end;
    if (bm <> nil) and
       Source.BookmarkValid(bm) then
      Source.GotoBookmark(bm);
  finally
    Source.FreeBookmark(bm);
    Source.EnableControls;
  end;
end;


end.
