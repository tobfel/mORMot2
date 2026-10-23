/// regression tests for the mormot.net.s3 client
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
// - by default, TS3Client is validated against a minimal in-process S3 server
// (TS3FakeServer), so no external service nor credential is needed: it checks
// the AWS Signature V4 of every request/presigned URL independently from the
// client, then serves PUT/GET/HEAD/DELETE/Copy/ListObjectsV2 from memory
// - to validate against a real server (e.g. MinIO), define the environment:
//   MORMOT_S3_ENDPOINT (e.g. http://127.0.0.1:18333), MORMOT_S3_ACCESS,
//   MORMOT_S3_SECRET and optionally MORMOT_S3_BUCKET (default 'mormot-test',
//   which should exist, or be auto-created) and MORMOT_S3_VHOST (a domain
//   name, e.g. localhost, for which {bucket}.domain reaches the server, to
//   enable the virtual-hosted style test); tests only use the
//   'mormot-s3-test/' key prefix of the bucket
// - the virtual-hosted style test connects to bucket.localhost: if your system
//   does not resolve it, add "127.0.0.1 bucket.localhost" to the hosts file
//   (and use MORMOT_S3_BUCKET=bucket with an external server); else it only
//   checks the connection name and the Host header offline
// - test/tools/start_seaweedfs_s3.cmd starts a temporary SeaweedFS (a single
//   weed.exe binary, native on Windows, not part of the repository) with the
//   very values above, and explains how to run the tests against it
// - a native Windows MinIO also works: set MINIO_ROOT_USER/MINIO_ROOT_PASSWORD,
//   run "minio.exe server <folder>" and create the bucket in its console
unit test.net.s3;

interface

{$I ..\src\mormot.defines.inc}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.datetime,
  mormot.core.fmt,
  mormot.core.test,
  mormot.crypt.core,
  mormot.net.sock,
  mormot.net.http,
  mormot.net.client,
  mormot.net.server,
  mormot.net.s3;

type
  /// minimal in-memory S3 server, verifying AWS Signature V4 on each request
  // - path-style (/bucket/key) and virtual-hosted (key only) addressing
  TS3FakeServer = class
  protected
    fServer: THttpServer;
    fLock: TLightLock;
    fBucket, fAccess, fSecret: RawUtf8;
    fKeys: TRawUtf8DynArray;
    fData, fTypes: TRawUtf8DynArray; // content and content-type of fKeys[]
    fCount: integer;
    fPageSize: integer;
    fRequests, fListPages, fSkewRejects: integer;
    fLastHost: RawUtf8;
    function Fail(Ctxt: THttpServerRequestAbstract; status: cardinal;
      const code, msg: RawUtf8): cardinal;
    function Verify(Ctxt: THttpServerRequestAbstract; const path, query: RawUtf8;
      var code, msg: RawUtf8): cardinal;
    function Find(const key: RawUtf8): integer;
    function DoList(Ctxt: THttpServerRequestAbstract; const query: RawUtf8): cardinal;
    function DoRequest(Ctxt: THttpServerRequestAbstract): cardinal;
  public
    constructor Create(const aPort, aBucket, aAccess, aSecret: RawUtf8);
    destructor Destroy; override;
    property Requests: integer
      read fRequests;
    property ListPages: integer
      read fListPages;
    property SkewRejects: integer
      read fSkewRejects;
    property LastHost: RawUtf8
      read fLastHost;
  end;

  /// expose the clock offset to simulate a client with a wrong clock
  TS3TestClient = class(TS3Client)
  public
    procedure ShiftClock(aOffset: TDateTime);
    /// the name the client connects to
    function ConnectHost: RawUtf8;
    /// the signed and sent Host: header value
    function HostHeader: RawUtf8;
  end;

  /// this test case will validate the mormot.net.s3 client
  TNetworkS3 = class(TSynTestCase)
  protected
    fFake: TS3FakeServer; // nil if testing an external server
    fEndpoint, fAccess, fSecret, fBucket, fVhostDomain: RawUtf8;
    function NewClient(aPathStyle: boolean = true): TS3TestClient;
    procedure StreamsOfSize(aSize: integer);
  public
    procedure Setup; override;
    procedure CleanUp; override;
  published
    /// Put/Get/Exists/GetInfo/Delete and the S3 error reporting
    procedure BasicOperations;
    /// object keys with spaces, '+', '&', '%' or UTF-8 characters
    procedure SpecialKeys;
    /// PutStream/GetStream/GetRange with a small body
    procedure StreamsAndRanges;
    /// the same with a 3MB body
    procedure LargeObject;
    /// server-side Copy/Move/Rename
    procedure CopyMove;
    /// ListObjectsV2 with prefix and continuation tokens
    procedure ListObjects;
    /// presigned GET URLs
    procedure PresignedUrls;
    /// a wrong local clock should be learned from the server Date header
    procedure ClockSkew;
    /// invalid credentials and unreachable server
    procedure Failures;
    /// virtual-hosted style addressing
    procedure VirtualHostedStyle;
    /// uploading a local file which does not exist should fail
    procedure MissingLocalFile;
  end;


implementation

const
  S3_PORT = '8997'; // outside of the 8888-8987 Windows dynamic reserved range
  S3_PFX = 'mormot-s3-test/';
  S3_UNSIGNED = 'UNSIGNED-PAYLOAD';

function Hmac(const key, msg: RawByteString): RawByteString;
var
  dig: TSha256Digest;
begin
  HmacSha256(key, msg, dig);
  SetString(result, PAnsiChar(@dig), SizeOf(dig));
end;

// extract and URL-decode the name=value item of a query string, or ''
function QueryParam(const query, name: RawUtf8): RawUtf8;
var
  q: RawUtf8;
  p, e: PtrInt;
begin
  result := '';
  q := '&' + query + '&';
  p := PosEx('&' + name + '=', q);
  if p = 0 then
    exit;
  inc(p, length(name) + 2);
  e := PosEx('&', q, p);
  result := UrlDecode(copy(q, p, e - p));
end;

// extract a "Name=value," item from an Authorization header
function AuthParam(const auth, name: RawUtf8): RawUtf8;
var
  p, e: PtrInt;
begin
  result := '';
  p := PosEx(name, auth);
  if p = 0 then
    exit;
  inc(p, length(name));
  e := PosEx(',', auth, p);
  if e = 0 then
    e := length(auth) + 1;
  result := copy(auth, p, e - p);
end;

// return the query string items sorted, as AWS expects it in canonical form
function CanonicalQuery(const query: RawUtf8; skipSignature: boolean): RawUtf8;
var
  items: TRawUtf8DynArray;
  n, p, e, i: PtrInt;
  item: RawUtf8;
begin
  result := '';
  n := 0;
  p := 1;
  while p <= length(query) do
  begin
    e := PosEx('&', query, p);
    if e = 0 then
      e := length(query) + 1;
    item := copy(query, p, e - p);
    p := e + 1;
    if skipSignature and IdemPChar(pointer(item), 'X-AMZ-SIGNATURE=') then
      continue;
    SetLength(items, n + 1);
    items[n] := item;
    inc(n);
  end;
  QuickSortRawUtf8(items, n);
  for i := 0 to n - 1 do
    if i = 0 then
      result := items[0]
    else
      result := result + '&' + items[i];
end;


{ TS3FakeServer }

constructor TS3FakeServer.Create(const aPort, aBucket, aAccess, aSecret: RawUtf8);
begin
  fBucket := aBucket;
  fAccess := aAccess;
  fSecret := aSecret;
  fPageSize := 3; // small, to exercise the continuation tokens
  fServer := THttpServer.Create(aPort, nil, nil, 's3fake', 2);
  fServer.OnRequest := DoRequest;
  fServer.WaitStarted(10);
end;

destructor TS3FakeServer.Destroy;
begin
  fServer.Free;
  inherited Destroy;
end;

function TS3FakeServer.Fail(Ctxt: THttpServerRequestAbstract; status: cardinal;
  const code, msg: RawUtf8): cardinal;
begin
  Ctxt.OutContentType := 'application/xml';
  Ctxt.OutContent := '<?xml version="1.0" encoding="UTF-8"?><Error><Code>' +
    code + '</Code><Message>' + XmlEscape(msg) + '</Message></Error>';
  result := status;
end;

function TS3FakeServer.Find(const key: RawUtf8): integer;
begin
  for result := 0 to fCount - 1 do
    if fKeys[result] = key then
      exit;
  result := -1;
end;

function TS3FakeServer.Verify(Ctxt: THttpServerRequestAbstract;
  const path, query: RawUtf8; var code, msg: RawUtf8): cardinal;
var
  presigned: boolean;
  auth, cred, signed, sig, amzdate, payload, ak, rest, rest2, datestamp, region,
  canonh, canonreq, sts, expected, name, value, up: RawUtf8;
  p, e: PtrInt;
  dt: TDateTime;
  expires: integer;
  key: RawByteString;
begin
  result := HTTP_FORBIDDEN;
  presigned := QueryParam(query, 'X-Amz-Signature') <> '';
  if presigned then
  begin
    cred := QueryParam(query, 'X-Amz-Credential');
    signed := QueryParam(query, 'X-Amz-SignedHeaders');
    sig := QueryParam(query, 'X-Amz-Signature');
    amzdate := QueryParam(query, 'X-Amz-Date');
    payload := S3_UNSIGNED;
  end
  else
  begin
    FindNameValue(Ctxt.InHeaders, 'AUTHORIZATION:', auth);
    if not StartWith(auth, 'AWS4-HMAC-SHA256 ') then
    begin
      code := 'AccessDenied';
      msg := 'Missing or invalid Authorization header';
      exit;
    end;
    cred := AuthParam(auth, 'Credential=');
    signed := AuthParam(auth, 'SignedHeaders=');
    sig := AuthParam(auth, 'Signature=');
    FindNameValue(Ctxt.InHeaders, 'X-AMZ-DATE:', amzdate);
    FindNameValue(Ctxt.InHeaders, 'X-AMZ-CONTENT-SHA256:', payload);
  end;
  Split(cred, '/', ak, rest);
  Split(rest, '/', datestamp, rest2);
  Split(rest2, '/', region, rest);
  if ak <> fAccess then
  begin
    code := 'InvalidAccessKeyId';
    msg := 'Unknown access key';
    exit;
  end;
  dt := Iso8601ToDateTime(copy(amzdate, 1, 15));
  if abs(dt - NowUtc) > 15 / (24 * 60) then
  begin
    inc(fSkewRejects);
    code := 'RequestTimeTooSkewed';
    msg := 'The difference between the request time and the server''s time ' +
      'is too large.';
    exit;
  end;
  if presigned then
  begin
    expires := GetInteger(pointer(QueryParam(query, 'X-Amz-Expires')));
    if NowUtc > dt + expires / SecsPerDay then
    begin
      code := 'AccessDenied';
      msg := 'Request has expired';
      exit;
    end;
  end;
  // canonical headers, from the headers actually received
  canonh := '';
  p := 1;
  while p <= length(signed) do
  begin
    e := PosEx(';', signed, p);
    if e = 0 then
      e := length(signed) + 1;
    name := copy(signed, p, e - p);
    p := e + 1;
    up := UpperCase(name) + ':';
    if not FindNameValue(Ctxt.InHeaders, pointer(up), value) and
       (name = 'host') then
      value := Ctxt.Host;
    canonh := canonh + name + ':' + value + #10;
  end;
  canonreq := Ctxt.Method + #10 + path + #10 +
    CanonicalQuery(query, presigned) + #10 + canonh + #10 + signed + #10 +
    payload;
  sts := 'AWS4-HMAC-SHA256'#10 + amzdate + #10 + datestamp + '/' + region +
    '/s3/aws4_request'#10 + Sha256(canonreq);
  key := Hmac('AWS4' + fSecret, datestamp);
  key := Hmac(key, region);
  key := Hmac(key, 's3');
  key := Hmac(key, 'aws4_request');
  expected := BinToHexLower(Hmac(key, sts));
  if expected <> sig then
  begin
    code := 'SignatureDoesNotMatch';
    msg := 'The request signature we calculated does not match: ' + canonreq;
    exit;
  end;
  if (payload <> S3_UNSIGNED) and (payload <> Sha256(Ctxt.InContent)) then
  begin
    result := HTTP_BADREQUEST;
    code := 'XAmzContentSHA256Mismatch';
    msg := 'The provided x-amz-content-sha256 header does not match the body';
    exit;
  end;
  result := HTTP_SUCCESS;
end;

function TS3FakeServer.DoList(Ctxt: THttpServerRequestAbstract;
  const query: RawUtf8): cardinal;
var
  prefix, token, xml: RawUtf8;
  match: TRawUtf8DynArray;
  n, i, first, last: integer;
  trunc: boolean;
begin
  inc(fListPages);
  prefix := QueryParam(query, 'prefix');
  token := QueryParam(query, 'continuation-token');
  n := 0;
  SetLength(match, fCount);
  for i := 0 to fCount - 1 do
    if copy(fKeys[i], 1, length(prefix)) = prefix then
    begin
      match[n] := fKeys[i];
      inc(n);
    end;
  QuickSortRawUtf8(match, n);
  first := GetInteger(pointer(token));
  last := first + fPageSize;
  trunc := last < n;
  if not trunc then
    last := n;
  xml := '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>' +
    fBucket + '</Name><Prefix>' + XmlEscape(prefix) + '</Prefix><KeyCount>' +
    Int32ToUtf8(last - first) + '</KeyCount><IsTruncated>';
  if trunc then
    xml := xml + 'true</IsTruncated><NextContinuationToken>' +
      Int32ToUtf8(last) + '</NextContinuationToken>'
  else
    xml := xml + 'false</IsTruncated>';
  for i := first to last - 1 do
    xml := xml + '<Contents><Key>' + XmlEscape(match[i]) + '</Key>' +
      '<LastModified>2026-01-02T03:04:05.000Z</LastModified>' +
      '<ETag>&quot;' + Md5(fData[Find(match[i])]) + '&quot;</ETag><Size>' +
      Int32ToUtf8(length(fData[Find(match[i])])) + '</Size></Contents>';
  Ctxt.OutContentType := 'application/xml';
  Ctxt.OutContent := xml + '</ListBucketResult>';
  result := HTTP_SUCCESS;
end;

function TS3FakeServer.DoRequest(Ctxt: THttpServerRequestAbstract): cardinal;
var
  path, query, key, src, code, msg, data: RawUtf8;
  q, i: PtrInt;
  bucketlevel: boolean;
begin
  fLock.Lock;
  try
    inc(fRequests);
    fLastHost := Ctxt.Host;
    Ctxt.OutCustomHeaders := 'Date: ' + DateTimeToHttpDate(NowUtc);
    q := PosExChar('?', Ctxt.Url);
    if q = 0 then
      path := Ctxt.Url
    else
    begin
      path := copy(Ctxt.Url, 1, q - 1);
      query := copy(Ctxt.Url, q + 1, maxInt);
    end;
    result := Verify(Ctxt, path, query, code, msg);
    if result <> HTTP_SUCCESS then
    begin
      result := Fail(Ctxt, result, code, msg);
      exit;
    end;
    // path-style: /bucket/key - virtual-hosted style: /key
    if (path = '/' + fBucket) or (path = '/' + fBucket + '/') or (path = '/') then
      key := ''
    else if copy(path, 1, length(fBucket) + 2) = '/' + fBucket + '/' then
      key := UrlDecode(copy(path, length(fBucket) + 3, maxInt))
    else
      key := UrlDecode(copy(path, 2, maxInt));
    bucketlevel := key = '';
    i := Find(key);
    if bucketlevel then
      if Ctxt.Method = 'GET' then
        result := DoList(Ctxt, query)
      else
        result := Fail(Ctxt, HTTP_BADREQUEST, 'InvalidRequest', 'bucket level')
    else if Ctxt.Method = 'PUT' then
    begin
      FindNameValue(Ctxt.InHeaders, 'X-AMZ-COPY-SOURCE:', src);
      if src <> '' then
      begin
        src := UrlDecode(src);
        if copy(src, 1, length(fBucket) + 1) <> fBucket + '/' then
        begin
          result := Fail(Ctxt, HTTP_NOTFOUND, 'NoSuchBucket', src);
          exit;
        end;
        src := copy(src, length(fBucket) + 2, maxInt);
        q := Find(src);
        if q < 0 then
        begin
          result := Fail(Ctxt, HTTP_NOTFOUND, 'NoSuchKey', src);
          exit;
        end;
        data := fData[q];
        msg := fTypes[q];
      end
      else
      begin
        data := Ctxt.InContent;
        msg := Ctxt.InContentType;
      end;
      if i < 0 then
      begin
        i := fCount;
        inc(fCount);
        SetLength(fKeys, fCount);
        SetLength(fData, fCount);
        SetLength(fTypes, fCount);
        fKeys[i] := key;
      end;
      fData[i] := data;
      fTypes[i] := msg;
      Ctxt.OutContentType := 'application/xml';
      Ctxt.OutCustomHeaders := Ctxt.OutCustomHeaders + #13#10'ETag: "' +
        Md5(data) + '"';
      if src <> '' then
        Ctxt.OutContent := '<CopyObjectResult><ETag>"' + Md5(data) +
          '"</ETag></CopyObjectResult>';
      result := HTTP_SUCCESS;
    end
    else if Ctxt.Method = 'DELETE' then
    begin
      if i >= 0 then
      begin
        fKeys[i] := fKeys[fCount - 1];
        fData[i] := fData[fCount - 1];
        fTypes[i] := fTypes[fCount - 1];
        dec(fCount);
      end;
      result := HTTP_NOCONTENT;
    end
    else if (Ctxt.Method = 'GET') or (Ctxt.Method = 'HEAD') then
    begin
      if i < 0 then
      begin
        result := Fail(Ctxt, HTTP_NOTFOUND, 'NoSuchKey',
          'The specified key does not exist.');
        exit;
      end;
      data := fData[i];
      Ctxt.OutContentType := fTypes[i];
      Ctxt.OutCustomHeaders := Ctxt.OutCustomHeaders + #13#10'ETag: "' +
        Md5(data) + '"'#13#10'Last-Modified: Fri, 02 Jan 2026 03:04:05 GMT' +
        #13#10'x-amz-meta-origin: fake';
      // THttpServer handles the Range: header by itself over OutContent
      Ctxt.OutContent := data;
      result := HTTP_SUCCESS;
    end
    else
      result := Fail(Ctxt, HTTP_NOTALLOWED, 'MethodNotAllowed', Ctxt.Method);
  finally
    fLock.UnLock;
  end;
end;


{ TS3TestClient }

procedure TS3TestClient.ShiftClock(aOffset: TDateTime);
begin
  fClockOffset := aOffset;
end;

function TS3TestClient.ConnectHost: RawUtf8;
begin
  result := fHost;
end;

function TS3TestClient.HostHeader: RawUtf8;
begin
  result := fHostHeader;
end;


{ TNetworkS3 }

procedure TNetworkS3.Setup;
begin
  fEndpoint := StringToUtf8(GetEnvironmentVariable('MORMOT_S3_ENDPOINT'));
  if fEndpoint <> '' then
  begin
    fAccess := StringToUtf8(GetEnvironmentVariable('MORMOT_S3_ACCESS'));
    fSecret := StringToUtf8(GetEnvironmentVariable('MORMOT_S3_SECRET'));
    fBucket := StringToUtf8(GetEnvironmentVariable('MORMOT_S3_BUCKET'));
    if fBucket = '' then
      fBucket := 'mormot-test';
    fVhostDomain := StringToUtf8(GetEnvironmentVariable('MORMOT_S3_VHOST'));
  end
  else
  begin
    fAccess := 'AKIDTESTFAKE';
    fSecret := 'secret/with+special=chars';
    fBucket := 'bucket'; // bucket.localhost may be set in the hosts file
    fFake := TS3FakeServer.Create(S3_PORT, fBucket, fAccess, fSecret);
    fEndpoint := 'http://127.0.0.1:' + S3_PORT;
    fVhostDomain := 'localhost';
  end;
end;

procedure TNetworkS3.CleanUp;
begin
  FreeAndNil(fFake);
end;

function TNetworkS3.NewClient(aPathStyle: boolean): TS3TestClient;
begin
  result := TS3TestClient.Create(fEndpoint, fAccess, fSecret, fBucket,
    'us-east-1', aPathStyle);
  result.TimeoutMS := 5000;
end;

procedure TNetworkS3.BasicOperations;
var
  c: TS3TestClient;
  got: RawByteString;
  size: Int64;
  info: TS3ObjectInfo;
  k: RawUtf8;
begin
  c := NewClient;
  try
    k := S3_PFX + 'basic.txt';
    Check(c.Put(k, 'hello', 'text/plain'), 'put');
    CheckEqual(c.LastStatus, 200, 'put status');
    Check(c.Exists(k, @size), 'exists');
    CheckEqual(size, 5, 'exists size');
    Check(c.Get(k, got), 'get');
    Check(got = 'hello', 'get content');
    Check(c.GetInfo(k, info), 'info');
    Check(info.Exists, 'info exists');
    CheckEqual(info.Size, 5, 'info size');
    CheckEqual(info.ContentType, 'text/plain', 'info type');
    Check(info.ETag <> '', 'info etag');
    Check(info.LastModified <> '', 'info date');
    if fFake <> nil then
      Check(PosEx('x-amz-meta-origin', LowerCase(info.UserMetadata)) > 0,
        'user metadata');
    // overwrite with an auto-detected content type, and an empty object
    Check(c.Put(k, '', ''), 'put empty');
    Check(c.Exists(k, @size), 'exists empty');
    CheckEqual(size, 0, 'empty size');
    Check(c.Get(k, got), 'get empty');
    Check(got = '', 'get empty content');
    Check(c.Delete(k), 'delete');
    Check(not c.Exists(k), 'deleted');
    CheckEqual(c.LastStatus, 404, 'head status');
    Check(c.Delete(k), 'delete is idempotent');
    // S3 error reporting
    Check(not c.Get(k, got), 'get missing');
    Check(got = '', 'get missing content');
    CheckEqual(c.LastStatus, 404, 'missing status');
    CheckEqual(c.LastErrorCode, 'NoSuchKey', 'missing code');
    Check(c.LastErrorMsg <> '', 'missing message');
    Check(c.Put(k, 'x', 'text/plain'), 'put again clears the error');
    CheckEqual(c.LastErrorCode, '', 'error cleared');
    Check(c.Delete(k), 'cleanup');
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.SpecialKeys;
const
  KEYS: array[0..4] of RawUtf8 = (
    'dir/sp ace.txt',
    'dir/plus+x.txt',
    'dir/utf8-'#$C3#$A4#$C3#$B6#$C3#$BC'.txt',
    'dir/q?=&%25.txt',
    'dir/sub/~tilde_dot.-x');
var
  c: TS3TestClient;
  i: integer;
  got: RawByteString;
  k: RawUtf8;
  ctx: string;
begin
  c := NewClient;
  try
    for i := 0 to high(KEYS) do
    begin
      k := S3_PFX + KEYS[i];
      ctx := Utf8ToString(KEYS[i]);
      Check(c.Put(k, KEYS[i], 'text/plain'), 'put ' + ctx);
      Check(c.Exists(k), 'exists ' + ctx);
      Check(c.Get(k, got), 'get ' + ctx);
      Check(got = KEYS[i], 'content ' + ctx);
      Check(c.Delete(k), 'delete ' + ctx);
    end;
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.StreamsAndRanges;
begin
  StreamsOfSize(64 shl 10);
end;

procedure TNetworkS3.LargeObject;
begin
  StreamsOfSize(3 shl 20);
end;

procedure TNetworkS3.StreamsOfSize(aSize: integer);
var
  c: TS3TestClient;
  data, got: RawByteString;
  ms, dest: TMemoryStream;
  i: integer;
  size: Int64;
  k: RawUtf8;
begin
  SetLength(data, aSize);
  for i := 1 to length(data) do
    data[i] := AnsiChar(i * 7 + i shr 9);
  c := NewClient;
  ms := TMemoryStream.Create;
  dest := TMemoryStream.Create;
  try
    k := S3_PFX + 'stream.bin';
    ms.Write(pointer(data)^, length(data));
    ms.Position := 0;
    Check(c.PutStream(k, ms, length(data), 'application/octet-stream'),
      'putstream');
    Check(c.Exists(k, @size), 'exists after putstream');
    CheckEqual(size, length(data), 'stored size after putstream');
    Check(c.GetRange(k, 0, 15, got), 'first bytes');
    Check(got = copy(data, 1, 16), 'first bytes content');
    Check(c.Get(k, got), 'get');
    Check(got = data, 'stream content');
    Check(c.GetStream(k, dest), 'getstream');
    CheckEqual(dest.Size, length(data), 'getstream size');
    if dest.Size = length(data) then
      Check(CompareMem(dest.Memory, pointer(data), length(data)),
        'getstream data');
    // ranges
    Check(c.GetRange(k, 100, 199, got), 'range');
    Check(got = copy(data, 101, 100), 'range content');
    Check(c.GetRange(k, length(data) - 10, length(data) - 1, got), 'end range');
    CheckEqual(length(got), 10, 'end range length');
    // open-ended ranges: THttpServer returns an empty 206 body for them when the
    // content is set from memory (OutContent) - so the in-process fake can't
    // validate them, but real servers do
    if fFake = nil then
    begin
      Check(c.GetRange(k, 100, -1, got), 'open range from 100');
      CheckEqual(length(got), length(data) - 100, 'open range from 100 length');
      Check(c.GetRange(k, length(data) - 10, -1, got), 'open range');
      CheckEqual(length(got), 10, 'open range length');
      Check(got = copy(data, length(data) - 9, 10), 'open range content');
    end;
    // size cross-check
    ms.Position := 0;
    Check(not c.PutStream(k, ms, 12345), 'size mismatch');
    CheckEqual(c.LastErrorCode, 'LocalError', 'size mismatch code');
    Check(c.Delete(k), 'cleanup');
  finally
    dest.Free;
    ms.Free;
    c.Free;
  end;
end;

procedure TNetworkS3.CopyMove;
var
  c: TS3TestClient;
  got: RawByteString;
  a, b, d: RawUtf8;
begin
  c := NewClient;
  try
    a := S3_PFX + 'copy/src a.txt'; // with a space
    b := S3_PFX + 'copy/dest.txt';
    d := S3_PFX + 'copy/renamed.txt';
    Check(c.Put(a, 'copy me', 'text/plain'), 'put');
    Check(c.Copy(a, b), 'copy');
    Check(c.Exists(a) and c.Exists(b), 'both exist');
    Check(c.Get(b, got) and (got = 'copy me'), 'copied content');
    Check(c.Move(b, d), 'move');
    Check(not c.Exists(b), 'moved source gone');
    Check(c.Move(d, b), 'move back (rename)');
    Check(c.Exists(b) and not c.Exists(d), 'renamed');
    Check(not c.Copy(S3_PFX + 'copy/missing', d), 'copy missing');
    CheckEqual(c.LastStatus, 404, 'copy missing status');
    Check(c.Delete(a) and c.Delete(b), 'cleanup');
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.ListObjects;
const
  NAMES: array[0..6] of RawUtf8 = (
    'a1', 'a2', 'a3', 'b1', 'b2', 'c&d<e>.txt', 'sp ace+plus.txt');
var
  c: TS3TestClient;
  items: TS3ItemDynArray;
  i, pages: integer;
  found: boolean;
begin
  c := NewClient;
  try
    for i := 0 to high(NAMES) do
      Check(c.Put(S3_PFX + 'list/' + NAMES[i], NAMES[i], 'text/plain'), 'put');
    pages := 0;
    if fFake <> nil then
      pages := fFake.ListPages;
    Check(c.List(S3_PFX + 'list/', items), 'list all');
    CheckEqual(length(items), length(NAMES), 'list count');
    if fFake <> nil then
      Check(fFake.ListPages - pages >= 3, 'list was paged');
    found := false;
    for i := 0 to high(items) do
      if items[i].Key = S3_PFX + 'list/c&d<e>.txt' then
      begin
        found := true;
        CheckEqual(items[i].Size, length('c&d<e>.txt'), 'escaped key size');
      end;
    Check(found, 'XML-escaped key is decoded');
    Check(c.List(S3_PFX + 'list/a', items), 'list prefix');
    CheckEqual(length(items), 3, 'prefix count');
    for i := 0 to high(items) do
    begin
      Check(items[i].ETag <> '', 'etag');
      Check(items[i].LastModified <> '', 'date');
    end;
    Check(c.List(S3_PFX + 'list/zzz', items), 'list none');
    CheckEqual(length(items), 0, 'none count');
    for i := 0 to high(NAMES) do
      Check(c.Delete(S3_PFX + 'list/' + NAMES[i]), 'cleanup');
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.PresignedUrls;
var
  c: TS3TestClient;
  u: TUri;
  h: THttpClientSocket;
  url, k, content: RawUtf8;

  function Download(const aUrl: RawUtf8): integer;
  begin
    Check(u.From(aUrl), 'uri');
    h := THttpClientSocket.Open(u.Server, u.Port, nlTcp, 5000, u.Https);
    try
      // keep-alive: SeaweedFS may truncate "Connection: close" responses
      result := h.Get(u.Address, 30000);
      content := h.Content;
    finally
      h.Free;
    end;
  end;

begin
  c := NewClient;
  try
    k := S3_PFX + 'presigned file.txt';
    Check(c.Put(k, 'presigned content', 'text/plain'), 'put');
    url := c.PresignedUrl('GET', k, 60);
    CheckEqual(Download(url), 200, 'presigned get');
    CheckEqual(content, 'presigned content', 'presigned content');
    // a modified URL must be rejected
    CheckEqual(Download(StringReplaceAll(url, 'file.txt', 'other.txt')), 403,
      'tampered url');
    Check(c.Delete(k), 'cleanup');
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.ClockSkew;
const
  SKEW_CONTENT: RawUtf8 = 'stream skew';
var
  c: TS3TestClient;
  data: TMemoryStream;
  dest: TMemoryStream;
  got: RawByteString;
  rejects: integer;
  k: RawUtf8;
begin
  c := NewClient;
  data := TMemoryStream.Create;
  dest := TMemoryStream.Create;
  try
    k := S3_PFX + 'skew.txt';
    // a client two hours late should learn the offset and retry once
    c.ShiftClock(-2 / 24);
    rejects := 0;
    if fFake <> nil then
      rejects := fFake.SkewRejects;
    Check(c.Put(k, 'skew', 'text/plain'), 'put with a wrong clock');
    if fFake <> nil then
      CheckEqual(fFake.SkewRejects - rejects, 1, 'one skew reject');
    // streams are rewound on retry
    c.ShiftClock(3 / 24);
    data.Write(pointer(SKEW_CONTENT)^, length(SKEW_CONTENT));
    data.Position := 0;
    Check(c.PutStream(k, data, 11), 'putstream with a wrong clock');
    c.ShiftClock(-3 / 24);
    Check(c.GetStream(k, dest), 'getstream with a wrong clock');
    CheckEqual(dest.Size, 11, 'getstream size');
    Check(c.Get(k, got) and (got = 'stream skew'), 'content');
    Check(c.Delete(k), 'cleanup');
  finally
    dest.Free;
    data.Free;
    c.Free;
  end;
end;

procedure TNetworkS3.Failures;
var
  c: TS3Client;
  got: RawByteString;
begin
  c := TS3Client.Create(fEndpoint, fAccess, 'wrong secret', fBucket);
  try
    c.TimeoutMS := 5000;
    Check(not c.Get(S3_PFX + 'x', got), 'wrong secret');
    CheckEqual(c.LastStatus, 403, 'wrong secret status');
    CheckEqual(c.LastErrorCode, 'SignatureDoesNotMatch', 'wrong secret code');
  finally
    c.Free;
  end;
  c := TS3Client.Create(fEndpoint, 'unknown access key', fSecret, fBucket);
  try
    c.TimeoutMS := 5000;
    Check(not c.Get(S3_PFX + 'x', got), 'wrong key');
    CheckEqual(c.LastStatus, 403, 'wrong key status');
  finally
    c.Free;
  end;
  // nothing is listening on this port
  c := TS3Client.Create('http://127.0.0.1:1', fAccess, fSecret, fBucket);
  try
    c.TimeoutMS := 1000;
    Check(not c.Put(S3_PFX + 'x', 'x'), 'no server');
    CheckEqual(c.LastStatus, 0, 'no server status');
    CheckEqual(c.LastErrorCode, 'ConnectionError', 'no server code');
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.VirtualHostedStyle;
var
  c: TS3TestClient;
  got: RawByteString;
  addr: TNetAddr;
begin
  // the name to connect to and the signed Host: header include the bucket,
  // whatever the network can resolve
  c := TS3TestClient.Create('http://example.com:8080', fAccess, fSecret,
    'mybucket', 'us-east-1', {pathstyle=}false);
  try
    CheckEqual(c.ConnectHost, 'mybucket.example.com', 'vhost connect');
    CheckEqual(c.HostHeader, 'mybucket.example.com:8080', 'vhost header');
  finally
    c.Free;
  end;
  c := TS3TestClient.Create('https://s3.example.com', fAccess, fSecret,
    'mybucket', 'us-east-1', {pathstyle=}true);
  try
    CheckEqual(c.ConnectHost, 's3.example.com', 'path connect');
    CheckEqual(c.HostHeader, 's3.example.com', 'path header');
  finally
    c.Free;
  end;
  if fVhostDomain = '' then
    exit; // an external server needs a domain name set up for its buckets
  // the *.localhost names should resolve to the loopback address (RFC 6761),
  // but some resolvers do not: then skip the network part of this test
  if addr.SetFrom(fBucket + '.' + fVhostDomain, '80', nlTcp) <> nrOk then
    exit;
  c := TS3TestClient.Create('http://' + fVhostDomain + ':' +
    SplitRight(fEndpoint, ':'), fAccess, fSecret, fBucket, 'us-east-1',
    {pathstyle=}false);
  try
    c.TimeoutMS := 5000;
    Check(c.Put(S3_PFX + 'vhost.txt', 'vhost', 'text/plain'), 'put');
    CheckEqual(c.LastStatus, 200, 'put status');
    Check(c.Get(S3_PFX + 'vhost.txt', got) and (got = 'vhost'), 'get');
    if fFake <> nil then
      CheckEqual(fFake.LastHost, fBucket + '.' + fVhostDomain + ':' + S3_PORT,
        'signed host header was sent');
    Check(c.Delete(S3_PFX + 'vhost.txt'), 'cleanup');
  finally
    c.Free;
  end;
end;

procedure TNetworkS3.MissingLocalFile;
var
  c: TS3TestClient;
  missing: RawUtf8;
  size: Int64;
begin
  c := NewClient;
  try
    missing := StringToUtf8(Executable.ProgramFilePath +
      'this-file-does-not-exist.bin');
    Check(not FileExists(Utf8ToString(missing)), 'precondition');
    Check(not c.PutFile(S3_PFX + 'missing.bin', missing), 'PutFile');
    Check(not c.Exists(S3_PFX + 'missing.bin', @size),
      'no empty object has been created');
    c.Delete(S3_PFX + 'missing.bin');
  finally
    c.Free;
  end;
end;

end.
