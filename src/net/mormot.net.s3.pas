/// Simple S3 client based on the mORMot 2 framework
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
// - implements AWS Signature Version 4 with API key + secret authentication
// - provides simple file operations on a bucket (like WebDAV):
//   Put, Get, Delete, Head/Exists/GetInfo, List, Copy, Move
// - streaming variants for large files (PutStream / GetStream)
// - presigned URL generation (query-string SigV4)
// - parses S3 error XML for diagnostics
// - Delphi 7 compatible (no generics, no inline, no anonymous methods)
unit mormot.net.s3;

{
  *****************************************************************************

   Minimal S3 Client (AWS, MinIO, Ceph, SeaweedFS...)
    - TS3Client Class

  *****************************************************************************
}

interface

{$I mormot.defines.inc}

uses
  SysUtils,
  Classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.datetime,
  mormot.crypt.core,
  mormot.net.client,
  mormot.net.sock;

type
  /// describes one object entry returned by a bucket listing
  TS3Item = record
    Key: RawUtf8;
    Size: Int64;
    LastModified: RawUtf8;
    ETag: RawUtf8;
  end;
  TS3ItemDynArray = array of TS3Item;

  /// full object metadata as returned by a HEAD request
  TS3ObjectInfo = record
    Exists: boolean;
    Size: Int64;
    ContentType: RawUtf8;
    ETag: RawUtf8;
    LastModified: RawUtf8;
    /// raw x-amz-meta-* header lines (Name: value CRLF separated)
    UserMetadata: RawUtf8;
  end;

  /// a simple S3 client using AWS Signature V4
  // - only implements the subset needed for basic file operations
  // - a single instance is not thread-safe: use one TS3Client per thread
  // - the HTTP connection is kept alive between requests, and re-opened on
  // demand: set TimeoutMS and IgnoreTlsCertError before the first request
  TS3Client = class
  protected
    fHttp: THttpClientSocket;
    fAccessKey: RawUtf8;
    fSecretKey: RawUtf8;
    fSessionToken: RawUtf8;
    fRegion: RawUtf8;
    fHost: RawUtf8;       // the name to connect to (incl. bucket if virtual-hosted)
    fHostHeader: RawUtf8; // fHost with its port if not the default one
    fBucket: RawUtf8;
    fPort: integer;
    fTls: boolean;
    fIgnoreTlsCertError: boolean;
    fUsePathStyle: boolean;
    fLastStatus: integer;
    fLastErrorCode: RawUtf8;
    fLastErrorMsg: RawUtf8;
    fTimeoutMS: integer;
    // learned offset (server UTC - local UTC, in TDateTime day units) applied
    // to every signed x-amz-date, so a wrong local clock does not break SigV4
    // (see UpdateClockOffset / IsClockSkewError)
    fClockOffset: TDateTime;
    // the SigV4 signing key only depends on the day: compute it once
    fKeyDate: RawUtf8;
    fKeyValue: RawByteString;
    // parse the 'Date' response header and (re)compute fClockOffset from it;
    // returns true if a valid server date was found (works on 4xx replies too,
    // which still carry a Date header)
    function UpdateClockOffset(const aHeaders: RawUtf8): boolean;
    // true if the last request failed because our timestamp was too far from
    // the server's clock (AWS 'RequestTimeTooSkewed' and equivalents)
    function IsClockSkewError: boolean;
    function SigningKey(const aDateStamp: RawUtf8): RawByteString;
    function CredentialScope(const aDateStamp: RawUtf8): RawUtf8;
    // the hexadecimal SigV4 signature of a canonical request - as used by both
    // the Authorization header and the presigned URLs
    // - aCanonHeaders is made of 'name:value'#10 lines, aSignedHeaders of the
    //   names separated by ';'
    function Sign(const aMethod, aPath, aQuery, aCanonHeaders, aSignedHeaders,
      aPayloadHash, aAmzDate: RawUtf8): RawUtf8;
    function AmzDateNow: RawUtf8;
    // core signed request.
    // - aSignHeaders: additional 'name', 'value' pairs that must be BOTH signed
    //   and sent (e.g. content-type, x-amz-copy-source); order is irrelevant,
    //   they get merged with the mandatory host/date/content-sha256 and sorted.
    // - aUnsignedHeaders: extra 'Name: value'#13#10 lines sent but NOT signed
    //   (e.g. Range). Do not put Content-Length/Content-Type here.
    // - aPayloadHashOverride forces the x-amz-content-sha256 value.
    // - aInStream (optional) is sent as body; aOutStream (optional) receives
    //   the response body for streaming downloads, and is left untouched if
    //   the server returned an error.
    function SignedRequest(const aMethod, aObjectName, aQuery: RawUtf8;
      const aBody: RawByteString; const aSignHeaders: array of RawUtf8;
      const aUnsignedHeaders, aPayloadHashOverride: RawUtf8;
      aInStream, aOutStream: TStream; aOutHeaders: PRawUtf8;
      out aResult: RawByteString): integer;
    // simplified wrapper used by most operations
    function Request(const aMethod, aObjectName, aQuery: RawUtf8;
      const aBody: RawByteString; aOutHeaders: PRawUtf8;
      out aResult: RawByteString): integer;
    function BuildUrlPath(const aObjectName: RawUtf8): RawUtf8;
    // resolve the effective content-type: return aContentType if set, else
    // auto-detect from the buffer content (and optional file name extension)
    // via mORMot's GetMimeContentType (falls back to application/octet-stream)
    function ResolveContentType(const aContentType: RawUtf8;
      const aContent: RawByteString; const aFileName: RawUtf8): RawUtf8;
    // like ResolveContentType but auto-detects from the stream head (first 4KB,
    // stream position preserved) plus the optional file name extension
    function DetectStreamContentType(const aContentType: RawUtf8;
      aStream: TStream; const aFileName: RawUtf8): RawUtf8;
    // extract <Code>/<Message> from an S3 error XML body
    procedure ParseError(const aBody: RawByteString);
    procedure ClearError;
    // set LastErrorCode = 'LocalError' for a failure which did not reach the server
    procedure SetLocalError(const aMessage: RawUtf8);
  public
    /// initialize the client
    // - aEndpoint is e.g. 's3.amazonaws.com' or 'minio.local:9000'
    //   or 'https://s3.eu-central-1.amazonaws.com'
    // - aRegion e.g. 'us-east-1' (default), 'eu-central-1'
    // - set aUsePathStyle=true for MinIO / Ceph and other S3-compatible
    //   servers that do not support virtual-hosted-style buckets; with false,
    //   the client connects to 'bucket.endpoint' (which should resolve)
    constructor Create(const aEndpoint, aAccessKey, aSecretKey, aBucket: RawUtf8;
      const aRegion: RawUtf8 = 'us-east-1'; aUsePathStyle: boolean = true);
    /// finalize the client, and close its connection
    destructor Destroy; override;
    /// upload a memory buffer as an object
    // - if aContentType is '' (default), it is auto-detected from the content
    //   via mORMot's GetMimeContentType (else 'application/octet-stream')
    function Put(const aObjectName: RawUtf8; const aContent: RawByteString;
      const aContentType: RawUtf8 = ''): boolean;
    /// upload a local file as an object (loads it fully into memory)
    // - for very large files prefer PutStreamFile
    // - if aContentType is '' (default), it is auto-detected from the file name
    //   extension and the content
    // - returns false with LastErrorCode = 'LocalError' if the file is missing
    function PutFile(const aObjectName, aLocalFile: RawUtf8;
      const aContentType: RawUtf8 = ''): boolean;
    /// upload from a stream using UNSIGNED-PAYLOAD (no full-body hashing)
    // - the whole stream (from position 0) is sent; Content-Length is set
    //   automatically from the stream size by the underlying HTTP client
    // - pass aContentLength = -1 to skip the size cross-check, or the expected
    //   size to have it validated against the stream before sending
    // - if aContentType is '' (default), it is auto-detected by sniffing the
    //   first bytes of the stream (position is preserved)
    function PutStream(const aObjectName: RawUtf8; aStream: TStream;
      aContentLength: Int64;
      const aContentType: RawUtf8 = ''): boolean;
    /// upload a local file via streaming (constant memory usage)
    // - if aContentType is '' (default), it is auto-detected from the file name
    //   extension and the stream head
    // - returns false with LastErrorCode = 'LocalError' if the file is missing
    function PutStreamFile(const aObjectName, aLocalFile: RawUtf8;
      const aContentType: RawUtf8 = ''): boolean;
    /// download an object into memory
    function Get(const aObjectName: RawUtf8; out aContent: RawByteString): boolean;
    /// download an object into a local file (loads it fully into memory)
    function GetFile(const aObjectName, aLocalFile: RawUtf8): boolean;
    /// download an object directly into a stream (constant memory usage)
    // - the stream is left untouched if the request failed
    function GetStream(const aObjectName: RawUtf8; aStream: TStream): boolean;
    /// download a byte range of an object into memory (HTTP Range header)
    // - aLast = -1 means "until the end"
    function GetRange(const aObjectName: RawUtf8; aFirst, aLast: Int64;
      out aContent: RawByteString): boolean;
    /// delete an object
    function Delete(const aObjectName: RawUtf8): boolean;
    /// check whether an object exists (HEAD request)
    function Exists(const aObjectName: RawUtf8; aSize: PInt64 = nil): boolean;
    /// retrieve full metadata about an object (HEAD request)
    function GetInfo(const aObjectName: RawUtf8;
      out aInfo: TS3ObjectInfo): boolean;
    /// server-side copy of an object within the current bucket (no round-trip)
    // - both aSourceObject and aDestObject are keys within the current bucket
    //   (the key may contain '/' prefixes)
    function Copy(const aSourceObject, aDestObject: RawUtf8): boolean;
    /// server-side move (or rename): copy then delete the source
    function Move(const aSourceObject, aDestObject: RawUtf8): boolean;
    /// list the objects of the bucket, optionally under a given prefix
    function List(const aPrefix: RawUtf8; out aItems: TS3ItemDynArray): boolean;
    /// generate a presigned URL valid for aExpireSeconds seconds
    // - aMethod is typically 'GET' (download) or 'PUT' (upload)
    // - the returned URL carries the signature in the query string, so it can
    //   be handed to any HTTP client / browser without credentials
    function PresignedUrl(const aMethod, aObjectName: RawUtf8;
      aExpireSeconds: integer = 3600): RawUtf8;
    /// optional STS session token for temporary credentials
    property SessionToken: RawUtf8 read fSessionToken write fSessionToken;
    /// last HTTP status code returned by the server
    property LastStatus: integer read fLastStatus;
    /// S3 error code from the last failed request (e.g. 'NoSuchKey')
    // - 'ConnectionError' if the server could not be reached, or 'LocalError'
    // if the request was rejected before being sent
    property LastErrorCode: RawUtf8 read fLastErrorCode;
    /// S3 error message from the last failed request
    property LastErrorMsg: RawUtf8 read fLastErrorMsg;
    /// HTTP request timeout in milliseconds (default 30000)
    property TimeoutMS: integer read fTimeoutMS write fTimeoutMS;
    /// skip TLS certificate validation for the signed requests (default false)
    // - handy for MinIO/Ceph and other S3-compatible servers with a
    //   self-signed certificate, or when the CRL/OCSP revocation endpoint is
    //   unreachable (SChannel CRYPT_E_NO_REVOCATION_CHECK)
    // - INSECURE: disables all certificate checks - use only against trusted
    //   test servers, never in production against the public internet
    // - has no effect on plain-HTTP endpoints; PresignedUrl download is handled
    //   by the caller's own HTTP client
    property IgnoreTlsCertError: boolean
      read fIgnoreTlsCertError write fIgnoreTlsCertError;
    property Region: RawUtf8 read fRegion;
    property Bucket: RawUtf8 read fBucket;
  end;


implementation

const
  KEEPALIVE_MS = 30000;
  UNSIGNED_PAYLOAD = 'UNSIGNED-PAYLOAD';
  EMPTY_SHA256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

{ helper routines }

// RFC 3986 URI encoding, as required by AWS SigV4
// - encodeSlash=false keeps '/' unescaped (used for the canonical path)
function AwsUriEncode(const s: RawUtf8; encodeSlash: boolean): RawUtf8;
const
  HEX: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  i, n: PtrInt;
  c: AnsiChar;
  p: PAnsiChar;
begin
  result := '';
  n := length(s);
  if n = 0 then
    exit;
  SetLength(result, n * 3); // worst case
  p := pointer(result);
  for i := 1 to n do
  begin
    c := s[i];
    if (c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']) or
       ((c = '/') and not encodeSlash) then
    begin
      p^ := c;
      inc(p);
    end
    else
    begin
      p^ := '%';
      inc(p);
      p^ := HEX[ord(c) shr 4];
      inc(p);
      p^ := HEX[ord(c) and 15];
      inc(p);
    end;
  end;
  SetLength(result, p - pointer(result));
end;

function HmacSha256Raw(const key, msg: RawByteString): RawByteString;
var
  dig: TSha256Digest;
begin
  HmacSha256(key, msg, dig);
  SetString(result, PAnsiChar(@dig), SizeOf(dig));
end;

// tiny XML value extractor: returns the text between <tag> and </tag>
function XmlTag(const xml: RawUtf8; var pos: PtrInt; const tag: RawUtf8;
  out value: RawUtf8): boolean;
var
  o, s, e: PtrInt;
  ot, ct: RawUtf8;
begin
  result := false;
  value := '';
  ot := '<' + tag + '>';
  ct := '</' + tag + '>';
  o := PosEx(ot, xml, pos);
  if o = 0 then
    exit;
  s := o + length(ot);
  e := PosEx(ct, xml, s);
  if e = 0 then
    exit;
  value := copy(xml, s, e - s);
  pos := e + length(ct);
  result := true;
end;

// decode the XML entities of a text value, as S3 escapes the keys and ETags
// - only &amp; &lt; &gt; &quot; &apos; and &#N; &#xN; ASCII entities are
// decoded, any other sequence is left untouched
function XmlUnescape(const s: RawUtf8): RawUtf8;
var
  i, n, semi, k: PtrInt;
  code: integer;
  c: AnsiChar;
  p: PAnsiChar;
begin
  if PosExChar('&', s) = 0 then
  begin
    result := s;
    exit;
  end;
  n := length(s);
  SetLength(result, n); // decoding never makes the text longer
  p := pointer(result);
  i := 1;
  while i <= n do
  begin
    c := s[i];
    code := -1;
    if c = '&' then
    begin
      semi := PosEx(';', s, i + 1);
      if (semi > 0) and (semi - i <= 8) then
      begin
        if copy(s, i, 5) = '&amp;' then
          code := ord('&')
        else if copy(s, i, 4) = '&lt;' then
          code := ord('<')
        else if copy(s, i, 4) = '&gt;' then
          code := ord('>')
        else if copy(s, i, 6) = '&quot;' then
          code := ord('"')
        else if copy(s, i, 6) = '&apos;' then
          code := ord('''')
        else if (s[i + 1] = '#') and (semi - i > 2) then
        begin
          code := 0;
          if (s[i + 2] = 'x') or (s[i + 2] = 'X') then
          begin
            for k := i + 3 to semi - 1 do
              if code >= 0 then
                case s[k] of
                  '0'..'9':
                    code := code * 16 + ord(s[k]) - ord('0');
                  'a'..'f':
                    code := code * 16 + ord(s[k]) - ord('a') + 10;
                  'A'..'F':
                    code := code * 16 + ord(s[k]) - ord('A') + 10;
                else
                  code := -1;
                end;
          end
          else
            for k := i + 2 to semi - 1 do
              if (code >= 0) and (s[k] in ['0'..'9']) then
                code := code * 10 + ord(s[k]) - ord('0')
              else
                code := -1;
          if (code < 0) or (code > 127) then
            code := -1; // keep non-ASCII numeric entities as they are
        end;
        if code >= 0 then
          i := semi; // skip the whole entity
      end;
    end;
    if code >= 0 then
      c := AnsiChar(code);
    p^ := c;
    inc(p);
    inc(i);
  end;
  SetLength(result, p - pointer(result));
end;

// collect all x-amz-meta-* lines from a raw header block
function ExtractUserMetadata(const headers: RawUtf8): RawUtf8;
var
  p, next: PUtf8Char;
  line: RawUtf8;
begin
  result := '';
  p := pointer(headers);
  while p <> nil do
  begin
    line := GetNextLine(p, next);
    if IdemPChar(pointer(line), 'X-AMZ-META-') then
      Append(result, [line, #13#10]);
    p := next;
  end;
end;

// sort the signed headers by lowercase name (few items, keeps D7 simple)
procedure SortHeaders(var names, values: TRawUtf8DynArray);
var
  i, j: PtrInt;
  n, v: RawUtf8;
begin
  for i := 1 to high(names) do
  begin
    n := names[i];
    v := values[i];
    j := i - 1;
    while (j >= 0) and (names[j] > n) do
    begin
      names[j + 1] := names[j];
      values[j + 1] := values[j];
      dec(j);
    end;
    names[j + 1] := n;
    values[j + 1] := v;
  end;
end;


{ TS3Client }

constructor TS3Client.Create(const aEndpoint, aAccessKey, aSecretKey,
  aBucket: RawUtf8; const aRegion: RawUtf8; aUsePathStyle: boolean);
var
  ep: RawUtf8;
  i: PtrInt;
begin
  inherited Create;
  fAccessKey := aAccessKey;
  fSecretKey := aSecretKey;
  fBucket := aBucket;
  fRegion := aRegion;
  fUsePathStyle := aUsePathStyle;
  fTimeoutMS := 30000;
  ep := aEndpoint;
  fTls := true; // https:// is the default
  if StartWith(ep, 'HTTPS://') then
    System.Delete(ep, 1, 8)
  else if StartWith(ep, 'HTTP://') then
  begin
    fTls := false;
    System.Delete(ep, 1, 7);
  end;
  while (ep <> '') and (ep[length(ep)] = '/') do
    SetLength(ep, length(ep) - 1);
  i := PosExChar(':', ep);
  if i > 0 then
  begin
    fPort := GetInteger(pointer(System.Copy(ep, i + 1, maxInt)));
    SetLength(ep, i - 1);
  end
  else if fTls then
    fPort := 443
  else
    fPort := 80;
  if aUsePathStyle then
    fHost := ep
  else
    fHost := aBucket + '.' + ep;
  fHostHeader := fHost;
  if (fTls and (fPort <> 443)) or (not fTls and (fPort <> 80)) then
    Append(fHostHeader, [':', fPort]);
end;

destructor TS3Client.Destroy;
begin
  fHttp.Free;
  inherited Destroy;
end;

procedure TS3Client.ClearError;
begin
  fLastErrorCode := '';
  fLastErrorMsg := '';
end;

procedure TS3Client.SetLocalError(const aMessage: RawUtf8);
begin
  fLastStatus := 0;
  fLastErrorCode := 'LocalError';
  fLastErrorMsg := aMessage;
end;

procedure TS3Client.ParseError(const aBody: RawByteString);
var
  xml, code, msg: RawUtf8;
  p: PtrInt;
begin
  ClearError;
  xml := aBody;
  if xml = '' then
    exit;
  p := 1;
  if XmlTag(xml, p, 'Code', code) then
    fLastErrorCode := XmlUnescape(code);
  p := 1;
  if XmlTag(xml, p, 'Message', msg) then
    fLastErrorMsg := XmlUnescape(msg);
end;

function TS3Client.UpdateClockOffset(const aHeaders: RawUtf8): boolean;
var
  d: RawUtf8;
  serverUtc: TDateTime;
begin
  result := false;
  // HttpDateToDateTime parses the RFC 7231 'Date' header as UTC
  if FindNameValue(aHeaders, 'DATE:', d) and
     HttpDateToDateTime(d, serverUtc, {tolocaltime=}false) then
  begin
    fClockOffset := serverUtc - NowUtc;
    result := true;
  end;
end;

function TS3Client.IsClockSkewError: boolean;
begin
  result := (fLastStatus = 403) and
    ((fLastErrorCode = 'RequestTimeTooSkewed') or
     (PosEx('RequestTimeTooSkewed', fLastErrorMsg) > 0) or
     (PosEx('request time', fLastErrorMsg) > 0));
end;

function TS3Client.SigningKey(const aDateStamp: RawUtf8): RawByteString;
begin
  if aDateStamp <> fKeyDate then
  begin
    fKeyValue := HmacSha256Raw('AWS4' + fSecretKey, aDateStamp);
    fKeyValue := HmacSha256Raw(fKeyValue, fRegion);
    fKeyValue := HmacSha256Raw(fKeyValue, 's3');
    fKeyValue := HmacSha256Raw(fKeyValue, 'aws4_request');
    fKeyDate := aDateStamp;
  end;
  result := fKeyValue;
end;

function TS3Client.CredentialScope(const aDateStamp: RawUtf8): RawUtf8;
begin
  FormatUtf8('%/%/s3/aws4_request', [aDateStamp, fRegion], result);
end;

function TS3Client.AmzDateNow: RawUtf8;
begin
  // apply any learned server clock offset
  result := DateTimeToIso8601(NowUtc + fClockOffset, {expanded=}false, 'T',
    {withms=}false) + 'Z';
end;

function TS3Client.Sign(const aMethod, aPath, aQuery, aCanonHeaders,
  aSignedHeaders, aPayloadHash, aAmzDate: RawUtf8): RawUtf8;
var
  datestamp, canonical, tosign: RawUtf8;
begin
  datestamp := System.Copy(aAmzDate, 1, 8);
  FormatUtf8('%'#10'%'#10'%'#10'%'#10'%'#10'%', [aMethod, aPath, aQuery,
    aCanonHeaders, aSignedHeaders, aPayloadHash], canonical);
  FormatUtf8('AWS4-HMAC-SHA256'#10'%'#10'%'#10'%', [aAmzDate,
    CredentialScope(datestamp), Sha256(canonical)], tosign);
  result := BinToHexLower(HmacSha256Raw(SigningKey(datestamp), tosign));
end;

function TS3Client.BuildUrlPath(const aObjectName: RawUtf8): RawUtf8;
var
  key: RawUtf8;
begin
  key := aObjectName;
  while (key <> '') and (key[1] = '/') do
    System.Delete(key, 1, 1);
  if fUsePathStyle then
    result := '/' + fBucket
  else
    result := '';
  if key <> '' then
    result := result + '/' + AwsUriEncode(key, {encodeSlash=}false)
  else if result = '' then
    result := '/';
end;

function TS3Client.SignedRequest(const aMethod, aObjectName, aQuery: RawUtf8;
  const aBody: RawByteString; const aSignHeaders: array of RawUtf8;
  const aUnsignedHeaders, aPayloadHashOverride: RawUtf8;
  aInStream, aOutStream: TStream; aOutHeaders: PRawUtf8;
  out aResult: RawByteString): integer;
var
  canonPath, payloadHash, amzDate, signedHeaders, canonHeaders, extraHeaders,
  url, respHeaders, errBody: RawUtf8;
  names, values: TRawUtf8DynArray;
  inStart, outStart, errSize: Int64;
  i, n, attempt: PtrInt;
  tls: TNetTlsContext;
  tlsp: PNetTlsContext;
begin
  aResult := '';
  ClearError;
  // path/payload hash do not depend on time - compute once
  canonPath := BuildUrlPath(aObjectName);
  if aPayloadHashOverride <> '' then
    payloadHash := aPayloadHashOverride
  else if aInStream <> nil then
    payloadHash := UNSIGNED_PAYLOAD
  else if aBody = '' then
    payloadHash := EMPTY_SHA256
  else
    payloadHash := Sha256(aBody);
  inStart := 0;
  outStart := 0;
  if aInStream <> nil then
    inStart := aInStream.Position;
  if aOutStream <> nil then
    outStart := aOutStream.Position;
  // attempt 0 signs with the current fClockOffset (initially 0); if the server
  // rejects us with a clock-skew error, fClockOffset is refreshed from the
  // server's 'Date' response header and attempt 1 re-signs with it (AWS-SDK
  // style). All later requests then already use the learned offset.
  for attempt := 0 to 1 do
  begin
    if attempt > 0 then
    begin
      // rewind the input stream and reset state before re-sending the request
      if aInStream <> nil then
        aInStream.Position := inStart;
      aResult := '';
      ClearError;
    end;
    amzDate := AmzDateNow;
    // collect all headers that must be signed, then sort them by name (AWS
    // SigV4 requires the canonical headers in strict lowercase order)
    n := length(aSignHeaders) shr 1;
    SetLength(names, n + 4);
    SetLength(values, n + 4);
    for i := 0 to n - 1 do
    begin
      names[i] := LowerCase(aSignHeaders[i * 2]);
      values[i] := TrimU(aSignHeaders[i * 2 + 1]);
    end;
    names[n] := 'host';
    values[n] := fHostHeader;
    names[n + 1] := 'x-amz-content-sha256';
    values[n + 1] := payloadHash;
    names[n + 2] := 'x-amz-date';
    values[n + 2] := amzDate;
    inc(n, 3);
    if fSessionToken <> '' then
    begin
      names[n] := 'x-amz-security-token';
      values[n] := fSessionToken;
      inc(n);
    end;
    SetLength(names, n);
    SetLength(values, n);
    SortHeaders(names, values);
    canonHeaders := '';
    signedHeaders := '';
    extraHeaders := '';
    for i := 0 to n - 1 do
    begin
      Append(canonHeaders, [names[i], ':', values[i], #10]);
      if i > 0 then
        Append(signedHeaders, ';');
      Append(signedHeaders, names[i]);
      // send every signed header except 'host' (the socket sets Host itself)
      if names[i] <> 'host' then
        Append(extraHeaders, [names[i], ': ', values[i], #13#10]);
    end;
    // then the unsigned extras, then Authorization
    Append(extraHeaders, [aUnsignedHeaders,
      'Authorization: AWS4-HMAC-SHA256 Credential=', fAccessKey, '/',
      CredentialScope(System.Copy(amzDate, 1, 8)), ', SignedHeaders=', signedHeaders,
      ', Signature=', Sign(aMethod, canonPath, aQuery, canonHeaders,
        signedHeaders, payloadHash, amzDate)]);
    if aQuery <> '' then
      url := canonPath + '?' + aQuery
    else
      url := canonPath;
    tlsp := nil;
    if fTls and fIgnoreTlsCertError then
    begin
      InitNetTlsContext(tls);
      tls.IgnoreCertificateErrors := true;
      tlsp := @tls;
    end;
    respHeaders := '';
    try
      // the connection is kept alive between requests, and re-opened on demand
      if fHttp = nil then
        fHttp := THttpClientSocket.Open(fHost, UInt32ToUtf8(fPort), nlTcp,
          fTimeoutMS, fTls, tlsp);
      result := fHttp.Request(url, aMethod, KEEPALIVE_MS, extraHeaders,
        aBody, '', {retry=}false, aInStream, aOutStream);
      respHeaders := fHttp.Headers;
      if aOutStream = nil then
        aResult := fHttp.Content;
      if aOutHeaders <> nil then
        aOutHeaders^ := respHeaders;
      // on failure, capture the S3 error body for diagnostics
      if result >= 400 then
        if aOutStream = nil then
          ParseError(fHttp.Content)
        else
        begin
          // the error XML has been written to the stream: read it back
          errSize := aOutStream.Size - outStart;
          if (errSize > 0) and (errSize <= 65536) then
          begin
            SetLength(errBody, errSize);
            aOutStream.Position := outStart;
            aOutStream.Read(pointer(errBody)^, errSize);
            ParseError(errBody);
          end;
        end;
      if result = HTTP_CLIENTERROR then
        FreeAndNil(fHttp); // e.g. timeout or truncated response
    except
      on E: ENetSock do
      begin
        // connection refused, DNS failure, TLS error, timeout, ...
        FreeAndNil(fHttp);
        result := 0;
        fLastErrorCode := 'ConnectionError';
        fLastErrorMsg := StringToUtf8(E.ClassName + ': ' + E.Message);
      end;
    end;
    if (aOutStream <> nil) and (result <> 200) and (result <> 206) then
    begin
      aOutStream.Position := outStart;
      aOutStream.Size := outStart; // never keep an error body in the stream
    end;
    fLastStatus := result;
    // refresh the server clock offset on a clock-skew error, and retry once
    if (attempt = 0) and IsClockSkewError and UpdateClockOffset(respHeaders) then
      continue;
    break;
  end;
end;

function TS3Client.Request(const aMethod, aObjectName, aQuery: RawUtf8;
  const aBody: RawByteString; aOutHeaders: PRawUtf8;
  out aResult: RawByteString): integer;
begin
  result := SignedRequest(aMethod, aObjectName, aQuery, aBody,
    [], '', '', nil, nil, aOutHeaders, aResult);
end;

function TS3Client.ResolveContentType(const aContentType: RawUtf8;
  const aContent: RawByteString; const aFileName: RawUtf8): RawUtf8;
begin
  if aContentType <> '' then
    result := aContentType
  else
    // GetMimeContentType checks the file-name extension first, then the binary
    // content, and falls back to 'application/octet-stream'
    result := GetMimeContentType(aContent, Utf8ToString(aFileName));
end;

function TS3Client.DetectStreamContentType(const aContentType: RawUtf8;
  aStream: TStream; const aFileName: RawUtf8): RawUtf8;
var
  head: RawByteString;
  savePos: Int64;
  n: integer;
begin
  if aContentType <> '' then
  begin
    result := aContentType;
    exit;
  end;
  // peek the first bytes for content-based sniffing, leaving the stream position
  // untouched so the subsequent upload sends the whole stream unchanged
  head := '';
  if aStream <> nil then
  begin
    savePos := aStream.Position;
    SetLength(head, 4096);
    n := aStream.Read(pointer(head)^, length(head));
    if n < 0 then
      n := 0;
    SetLength(head, n);
    aStream.Position := savePos;
  end;
  result := GetMimeContentType(head, Utf8ToString(aFileName));
end;

function TS3Client.Put(const aObjectName: RawUtf8;
  const aContent: RawByteString; const aContentType: RawUtf8): boolean;
var
  res: RawByteString;
  status: integer;
begin
  status := SignedRequest('PUT', aObjectName, '', aContent,
    ['content-type', ResolveContentType(aContentType, aContent, '')],
    '', '', nil, nil, nil, res);
  result := (status = 200) or (status = 204);
end;

function TS3Client.PutFile(const aObjectName, aLocalFile: RawUtf8;
  const aContentType: RawUtf8): boolean;
var
  content: RawByteString;
  fn: TFileName;
begin
  result := false;
  fn := Utf8ToString(aLocalFile);
  if not FileExists(fn) then
  begin
    SetLocalError('Local file not found: ' + aLocalFile);
    exit;
  end;
  content := StringFromFile(fn);
  // resolve here (with the local file name for extension-based detection) so the
  // Put() call receives an already-decided content-type
  result := Put(aObjectName, content,
    ResolveContentType(aContentType, content, aLocalFile));
end;

function TS3Client.PutStream(const aObjectName: RawUtf8; aStream: TStream;
  aContentLength: Int64; const aContentType: RawUtf8): boolean;
var
  res: RawByteString;
  status: integer;
begin
  // Note: mORMot's Request() sends Content-Length automatically from
  // InStream.Size, so we must NOT add it here (would duplicate the header).
  // aContentLength is kept in the signature for API clarity / validation.
  if (aContentLength >= 0) and (aStream.Size <> aContentLength) then
  begin
    SetLocalError('Stream size does not match aContentLength');
    result := false;
    exit;
  end;
  aStream.Position := 0;
  // UNSIGNED-PAYLOAD avoids hashing the whole body; stream sent as-is
  status := SignedRequest('PUT', aObjectName, '', '',
    ['content-type', DetectStreamContentType(aContentType, aStream, '')],
    '', UNSIGNED_PAYLOAD, aStream, nil, nil, res);
  result := (status = 200) or (status = 204);
end;

function TS3Client.PutStreamFile(const aObjectName, aLocalFile: RawUtf8;
  const aContentType: RawUtf8): boolean;
var
  fs: TFileStream;
  fn: TFileName;
begin
  result := false;
  fn := Utf8ToString(aLocalFile);
  if not FileExists(fn) then
  begin
    SetLocalError('Local file not found: ' + aLocalFile);
    exit;
  end;
  fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
  try
    // resolve with the local file name (extension) plus stream-head sniffing
    result := PutStream(aObjectName, fs, fs.Size,
      DetectStreamContentType(aContentType, fs, aLocalFile));
  finally
    fs.Free;
  end;
end;

function TS3Client.Get(const aObjectName: RawUtf8;
  out aContent: RawByteString): boolean;
var
  status: integer;
begin
  status := Request('GET', aObjectName, '', '', nil, aContent);
  result := status = 200;
  if not result then
    aContent := '';
end;

function TS3Client.GetFile(const aObjectName, aLocalFile: RawUtf8): boolean;
var
  content: RawByteString;
begin
  result := Get(aObjectName, content);
  if result then
    result := FileFromString(content, Utf8ToString(aLocalFile));
end;

function TS3Client.GetStream(const aObjectName: RawUtf8;
  aStream: TStream): boolean;
var
  res: RawByteString;
begin
  result := SignedRequest('GET', aObjectName, '', '',
    [], '', '', nil, aStream, nil, res) = 200;
end;

function TS3Client.GetRange(const aObjectName: RawUtf8; aFirst, aLast: Int64;
  out aContent: RawByteString): boolean;
var
  status: integer;
  range: RawUtf8;
begin
  if aLast >= 0 then
    FormatUtf8('Range: bytes=%-%'#13#10, [aFirst, aLast], range)
  else
    FormatUtf8('Range: bytes=%-'#13#10, [aFirst], range);
  // Range may be sent unsigned (AWS allows it)
  status := SignedRequest('GET', aObjectName, '', '',
    [], range, '', nil, nil, nil, aContent);
  // 206 Partial Content on success; 200 if server returned the whole object
  result := (status = 200) or (status = 206);
  if not result then
    aContent := '';
end;

function TS3Client.Delete(const aObjectName: RawUtf8): boolean;
var
  res: RawByteString;
  status: integer;
begin
  status := Request('DELETE', aObjectName, '', '', nil, res);
  result := (status = 200) or (status = 204);
end;

function TS3Client.Exists(const aObjectName: RawUtf8; aSize: PInt64): boolean;
var
  res: RawByteString;
  hdr, len: RawUtf8;
begin
  result := Request('HEAD', aObjectName, '', '', @hdr, res) = 200;
  if result and (aSize <> nil) then
  begin
    FindNameValue(hdr, 'CONTENT-LENGTH:', len);
    aSize^ := GetInt64(pointer(len));
  end;
end;

function TS3Client.GetInfo(const aObjectName: RawUtf8;
  out aInfo: TS3ObjectInfo): boolean;
var
  res: RawByteString;
  hdr, len: RawUtf8;
begin
  // the managed fields of an out record are already cleared by the compiler
  aInfo.Size := 0;
  result := Request('HEAD', aObjectName, '', '', @hdr, res) = 200;
  aInfo.Exists := result;
  if result then
  begin
    FindNameValue(hdr, 'CONTENT-LENGTH:', len);
    aInfo.Size := GetInt64(pointer(len));
    FindNameValue(hdr, 'CONTENT-TYPE:', aInfo.ContentType);
    FindNameValue(hdr, 'ETAG:', aInfo.ETag);
    FindNameValue(hdr, 'LAST-MODIFIED:', aInfo.LastModified);
    aInfo.UserMetadata := ExtractUserMetadata(hdr);
  end;
end;

function TS3Client.Copy(const aSourceObject, aDestObject: RawUtf8): boolean;
var
  res: RawByteString;
  status: integer;
  src: RawUtf8;
begin
  // build the copy-source value 'bucket/key' (key URL-encoded, slashes kept)
  // - aSourceObject is always a key within the current bucket; note that the
  //   key itself may legitimately contain '/' (prefixes), so we must NOT try to
  //   guess a bucket from its presence - the bucket is always prepended here
  // - NO leading '/': the plain 'bucket/key' form is accepted by AWS and, unlike
  //   the '/bucket/key' variant, also by S3-compatible servers (MinIO, Ceph,
  //   SeaweedFS) that otherwise reply 404 NoSuchBucket
  src := aSourceObject;
  while (src <> '') and (src[1] = '/') do
    System.Delete(src, 1, 1);
  src := fBucket + '/' + AwsUriEncode(src, {encodeSlash=}false);
  // x-amz-copy-source is signed; SignedRequest sorts it into the correct
  // canonical position automatically
  status := SignedRequest('PUT', aDestObject, '', '',
    ['x-amz-copy-source', src], '', '', nil, nil, nil, res);
  result := status = 200;
  // S3 can return HTTP 200 with an <Error> body for a failed copy
  if result and (PosEx('<Error', res, 1) > 0) then
  begin
    ParseError(res);
    result := false;
  end;
end;

function TS3Client.Move(const aSourceObject, aDestObject: RawUtf8): boolean;
begin
  result := Copy(aSourceObject, aDestObject);
  if result then
    result := Delete(aSourceObject);
end;

function TS3Client.List(const aPrefix: RawUtf8;
  out aItems: TS3ItemDynArray): boolean;
var
  query, xml, token, truncated, entry, value: RawUtf8;
  res: RawByteString;
  p, cp, n: PtrInt;
begin
  n := 0;
  aItems := nil;
  token := '';
  repeat
    // query parameters should be sorted by name
    query := '';
    if token <> '' then
      Append(query, ['continuation-token=', AwsUriEncode(token, true), '&']);
    Append(query, 'list-type=2');
    if aPrefix <> '' then
      Append(query, ['&prefix=', AwsUriEncode(aPrefix, true)]);
    if Request('GET', '', query, '', nil, res) <> 200 then
    begin
      result := false;
      exit;
    end;
    xml := res;
    p := 1;
    while XmlTag(xml, p, 'Contents', entry) do
    begin
      if n = length(aItems) then
        SetLength(aItems, NextGrow(n));
      cp := 1;
      XmlTag(entry, cp, 'Key', value);
      aItems[n].Key := XmlUnescape(value);
      cp := 1;
      XmlTag(entry, cp, 'Size', value);
      aItems[n].Size := GetInt64(pointer(value));
      cp := 1;
      XmlTag(entry, cp, 'LastModified', aItems[n].LastModified);
      cp := 1;
      XmlTag(entry, cp, 'ETag', value);
      aItems[n].ETag := XmlUnescape(value);
      inc(n);
    end;
    token := '';
    cp := 1;
    if XmlTag(xml, cp, 'IsTruncated', truncated) and
       (truncated = 'true') then
    begin
      cp := 1;
      if XmlTag(xml, cp, 'NextContinuationToken', token) then
        token := XmlUnescape(token);
    end;
  until token = '';
  SetLength(aItems, n);
  result := true;
end;

function TS3Client.PresignedUrl(const aMethod, aObjectName: RawUtf8;
  aExpireSeconds: integer): RawUtf8;
var
  amzDate, canonPath, canonQuery, scheme: RawUtf8;
begin
  amzDate := AmzDateNow;
  canonPath := BuildUrlPath(aObjectName);
  // query parameters in sorted order, with all values URI-encoded
  FormatUtf8('X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=%&' +
    'X-Amz-Date=%&X-Amz-Expires=%', [
    AwsUriEncode(fAccessKey + '/' + CredentialScope(System.Copy(amzDate, 1, 8)),
      true), amzDate, aExpireSeconds], canonQuery);
  if fSessionToken <> '' then
    Append(canonQuery, ['&X-Amz-Security-Token=',
      AwsUriEncode(fSessionToken, true)]);
  Append(canonQuery, '&X-Amz-SignedHeaders=host');
  if fTls then
    scheme := 'https://'
  else
    scheme := 'http://';
  FormatUtf8('%%%?%&X-Amz-Signature=%', [scheme, fHostHeader, canonPath,
    canonQuery, Sign(aMethod, canonPath, canonQuery,
      'host:' + fHostHeader + #10, 'host', UNSIGNED_PAYLOAD, amzDate)], result);
end;

end.
