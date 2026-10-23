@echo off
rem Start a temporary SeaweedFS S3 server, to run test.net.s3.pas against a
rem real S3 implementation (see the header of test.net.s3.pas).
rem
rem - needs weed.exe (single binary from https://github.com/seaweedfs/seaweedfs/releases)
rem   in %~dp0seaweedfs\weed.exe, or its full path in the WEED environment
rem   variable. The binary is not part of the repository.
rem - data is kept in %MORMOT_S3_DATA%, default %TEMP%\mormot-seaweedfs, and is
rem   deleted at each start, so the server is always empty
rem - uses ports 19333/18080/18888/18333, outside of the 8888-8987 range which
rem   Windows may reserve: S3 endpoint is http://127.0.0.1:18333
rem - stop it with Ctrl+C
rem
rem Then, in another console:
rem   set MORMOT_S3_ENDPOINT=http://127.0.0.1:18333
rem   set MORMOT_S3_ACCESS=AKIDTESTSEAWEED
rem   set MORMOT_S3_SECRET=seaweed-test-secret
rem   set MORMOT_S3_BUCKET=bucket
rem   set MORMOT_S3_VHOST=localhost
rem   mormot2tests.exe /test TNetworkS3
rem (the bucket is created on its first upload by this admin identity;
rem  MORMOT_S3_VHOST enables the virtual-hosted style test, since this script
rem  starts weed with -s3.domainName=localhost; it needs a hosts file entry
rem  "127.0.0.1 bucket.localhost")
setlocal EnableExtensions
if "%WEED%"=="" set "WEED=%~dp0seaweedfs\weed.exe"
if not exist "%WEED%" (
  echo weed.exe not found: %WEED%
  exit /b 2
)
if "%MORMOT_S3_DATA%"=="" set "MORMOT_S3_DATA=%TEMP%\mormot-seaweedfs"
if exist "%MORMOT_S3_DATA%" rmdir /s /q "%MORMOT_S3_DATA%"
mkdir "%MORMOT_S3_DATA%"
> "%MORMOT_S3_DATA%\s3.json" echo {"identities":[{"name":"mormot","credentials":[{"accessKey":"AKIDTESTSEAWEED","secretKey":"seaweed-test-secret"}],"actions":["Admin","Read","Write","List","Tagging"]}]}
"%WEED%" server -dir="%MORMOT_S3_DATA%" -ip=127.0.0.1 -master.port=19333 -volume.port=18080 -filer.port=18888 -master.volumeSizeLimitMB=64 -volume.max=8 -s3 -s3.port=18333 -s3.config="%MORMOT_S3_DATA%\s3.json" -s3.domainName=localhost -s3.port.iceberg=0 -s3.port.lance=0
