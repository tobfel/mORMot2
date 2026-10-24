# duckdbproxy

DuckDB is only available as a 64-bit library. `duckdbproxy` is a small 64-bit
console wrapper which hosts `mormot.db.sql.duckdb` and publishes the database
with the standard `mormot.db.proxy` binary protocol, so that **32-bit** (or
remote) clients can use DuckDB through the usual `TSqlDBConnectionProperties`
API.

```
duckdbproxy <dbfile|:memory:> [options]
  -port 8092            TCP port
  -bind 127.0.0.1       listening interface (0.0.0.0 = all - beware)
  -name duckdb          database name, i.e. URI root of the proxy server
  -user duckdb          user name for authentication
  -pass <secret>        password - or DUCKDBPROXY_PASS environment variable
  -readonly             open the database file in READ_ONLY mode
  -config "a=b;c=d"     DuckDB configuration options
  -lib <path>           duckdb.dll / libduckdb.so to load
  -log <file>           write a TSynLog file for troubleshooting
  -parentpid <pid>      exit when this process ends
```

The process stops on [Enter], Ctrl+C, SIGTERM or (on Windows) a WM_QUIT
message, closing the DuckDB file properly.

Build it as a 64-bit executable with Delphi or FPC/Lazarus (`duckdbproxy.lpi`),
and ship it with `duckdb.dll`.

## Client side

```pascal
uses mormot.db.sql.duckdbproxy;

// connect to a running duckdbproxy
props := TSqlDBDuckDBProxyConnectionProperties.Create(
  '127.0.0.1:8092', 'duckdb', 'duckdb', 'secret');

// or (on Windows) launch duckdbproxy.exe with a random password: it is
// stopped, with a clean DuckDB checkpoint, when props is freed - and it
// exits by itself if the client process ends
props := TSqlDBDuckDBProxyConnectionProperties.CreateWithProcess(
  Executable.ProgramFilePath + 'duckdbproxy.exe', 'demo.duckdb');
```

See `../duckdb/DuckDBProxyDemo.dpr` for a complete example.

Note that `GetFields` / `GetIndexes` / `GetForeignKeys` between 32-bit and
64-bit processes need a `mormot.db.proxy` with `REMOTE_MAGIC = 2` on both sides.
