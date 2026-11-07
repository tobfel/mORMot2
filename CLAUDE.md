# CLAUDE.md - mORMot 2

Guidance for every Claude Code session in this repository. Folder-specific notes live in
`src/*/CLAUDE.md` (e.g. `src/db/CLAUDE.md` for the database layer and the DuckDB TODOs).

## Code quality: mORMot intent, not only mORMot style

From Arnaud Bouchez's review of the AI-written DuckDB PR #666
(https://github.com/synopse/mORMot2/issues/423#issuecomment-6218806358, 2026-10-16):
the code was correct and well tested and *looked* like mORMot, but on closer look it was
"correct but sloppy". Upstream expects performance-minded, non-redundant code. Rules:

- **Parse once, reuse.** Never query/parse the same metadata repeatedly (e.g. a column's
  logical type). Compute it once at prepare/first-step time and cache it.
- **No duplicated code paths.** Factor shared logic into one function instead of
  near-identical copies per call site or per type.
- **Reuse existing framework code** instead of re-implementing it. Before writing any
  converter, search the core units: date/time via `mormot.core.datetime.pas`
  (`TSynSystemTime`, ISO-8601 helpers), GUID/UUID via the existing `TGuid` functions,
  number/text via `mormot.core.base` / `mormot.core.text` / `mormot.core.unicode`.
- **Avoid transient `RawUtf8`** (and other temporary managed strings) in hot paths such as
  per-row / per-column loops: write directly to a `TJsonWriter`/`TTextWriter`, use a stack
  buffer (`ShortString`, `TTemp*`), or pass `PUtf8Char` + length. Favor explicit
  `PUtf8Char` when talking to C APIs.
- **Specialized fast conversions** for hot types (e.g. 128-bit HugeInt to text with an
  internal scale parameter) instead of generic, slow arithmetic.
- **No `packed record`** for C API struct mirrors unless the C side is packed: it is much
  slower on arm32/aarch64 and can break alignment.
- **Fix compiler limitations at the type, not at every call site.** From ab's Delphi 7 fix
  of `TDuckDBTypeInfo` (d7cabac66, 2026-11-03): a record cannot hold `array of itself` on
  Delphi 7. Our fix (`Child: pointer` + `TDuckDBTypeInfoDynArray(...)` casts in every unit)
  was rejected in favor of a forward-declared typed pointer
  `PDuckDBTypeInfoArray = ^array[word] of TDuckDBTypeInfo` + explicit `ChildCount` +
  `AllocMem`/`FreeMem`: callers keep `T^.Child[i]`, no casts, no dynarray-header hacks.
  With manual memory, finalize managed fields yourself (`Names := nil` for nested levels).
- **Records with methods, Delphi 7 style:** `{$ifdef USERECORDWITHMETHODS} record {$else}
  object {$endif}` with `Init`/`Done`/accessor methods instead of global
  `XxxInit(var Info)`/`XxxDone(var Info)` functions.
- **Delphi 7 idioms:** no `PByte` arithmetic - write `@PByteArray(p)^[1]`; reuse
  `THash128Rec` (`L`/`H`/`c[]`) for 128-bit math instead of a private limb type.
- **Benchmark against the naive path** before keeping an "optimization" or a convenience
  feature. Example: DuckDB `BindArray` still executed one statement per row and was slower
  than plain inserts - pure bloat. Prefer the mechanisms the ORM already uses
  (e.g. `TSqlDBConnectionProperties.OnBatchInsert`).
- **Keep the footprint small.** Do not add API surface, options or helper classes that the
  framework does not need; less code that reuses the core beats more "complete" code.
- **Tests:** no exception should be logged during a normal test run; skip tests cleanly when
  an optional library is missing (and on unsupported bitness).

## Code quality: lessons from Arnaud's rework (2026-11-02)

After merging the DuckDB units, Arnaud rewrote them himself (`caf708c0d`, `e6ce529bb`,
`eb1f9937d`, fixes up to `c3f4abb0d`). Read these diffs before similar work: they show
concretely what "mORMot intent" means. Rules derived from them:

**Strings and memory**
- Helpers called per value return text as a `var result: RawUtf8` parameter (procedure),
  not as a function result: the caller can reuse its buffer and no hidden temporary is
  created (e.g. `DuckDBEnumValue`, `DuckUuidToText`).
- Never convert a value to `RawUtf8` just to parse it again (`GetInt64(ColumnUtf8(..))`):
  write it into a stack `TTemp47` and parse the `PUtf8Char` (`GetInt64`, `GetExtended`,
  `StrToCurr64`, `Iso8601ToDateTimePUtf8CharVar`).
- A `PUtf8Char` into a network or C buffer is **not #0-terminated**: copy short values into
  a `TTemp47` and add the #0 before calling a #0-based parser.
- Concatenate with `Join([...], result)`, `Append(s, ...)` or `Make([...])`, not `a + b + c`.
- Compute invariant values once and store them in a field (e.g. the library version text
  set in the constructor, not converted at each call).
- `AllocMem()` instead of `GetMem()` + `FillCharFast()`.

**Data structures**
- Per-column boolean flags as a bit array (`TBytes` + `SetBitPtr`/`GetBitPtr`), not
  `TBooleanDynArray` (the one place where `TBytes` is the right type). `SetBitPtr` writes
  32-bit words: allocate `(n + 31) shr 3` bytes.
- Keep per-execution state in fields of the object, instead of returning dynamic arrays
  from one method to the next.
- Iterate arrays of records with a typed pointer (`p := pointer(arr)` ... `inc(p)`), not
  with `arr[i]` and never with `with`.
- Logic depending on one record/object only becomes a method of that type (e.g.
  `TQuackType.EnumIndexAt`), not a free function taking it as parameter.
- No wrapper function whose body is a single pointer cast: write `PInteger(P)^` inline.

**Hot paths**
- Specialize the frequent cases of a `case` dispatch (e.g. write INTEGER/BIGINT columns
  directly with `W.Add(PInteger(p)^)`), keep the generic reader for the rare types.
- Small per-value helpers get `{$ifdef HASINLINE} inline; {$endif}`.
- Early `exit` instead of nested `if`/`else`; a `const` table (`array[boolean] of ...`)
  instead of `if`/`else` choosing between two formats or values.
- A shared tail may use `goto` (as in mORMot core) rather than duplicating a block. Avoid
  an implicit `try..finally` in a hot loop with `pointer` + `RawUtf8(p)` +
  `FastAssignNew(p)` only where it is measurably hot.

**Correctness**
- Read binary values with their real signedness (a DuckDB DATE is a *signed* 32-bit day
  count: `PInteger`, not `PCardinal` - dates before 1970 are negative).
- Text returned by a C API (e.g. `duckdb_result_error`) dies with its owner: create the
  exception first (`E := ESql...CreateUtf8(...)`), then release the C resource, then
  `raise E`. Our original code read the message after `destroy_result()`.
- Use the core constants (`MicroSecsPerSec`, `MicroSecsPerHour`, `UnixDelta`...) instead of
  local copies; mind the 64-bit typing for Delphi (warning W1073).

**Core, layout and documentation**
- When a generic primitive is missing, add it to the core unit in its own commit
  ("core: new X function") instead of a private helper: Arnaud added
  `TFastReader.Peek2/4/8`, `SetBitPtr(.., aSet)`, `TSynLibrary.LibraryName`,
  `MicroSecsPerHour` for this rework.
- The unit header lists the sections exactly as the `{ ************ Title }` markers, and
  the implementation has the same sections in the same order, each only once.
- One value per line in multi-value `case` labels and in long set constants.
- New units or classes get a short entry in `src/<folder>/README.md`; a reused generic field
  (e.g. `ColumnAttr`) documents its meaning for the new provider.

**Tests**
- Linear test steps: no `for pass := 0 to 1` loop with per-pass branches.
- Parameterized SQL (`?`) in tests too, no literal values formatted into the SQL text.
- The test identification shows the library name and version.
- Each test must also run alone (`/test <class>`): guard state from previous methods.

**Interface lifetime vs. owner release** (ab, `24ca88796`, `e15e6c13d`, `5df7dc803`,
2026-11-04/05: "the properties should be released once all transient statement interfaces
are released!")
- Every `ISqlDBRows` / `ISqlDBStatement` (and any other interface whose implementation
  refers to its owner) must be released **before** the owning `TSqlDBConnectionProperties`
  / connection / server is freed. Otherwise the interface is finalized at the very end of
  the method, after `props.Free`, and accesses freed memory: a *random* GPF, often only on
  some platforms or test orders.
- Delphi also creates **hidden temporaries** for interface results: `with props.Execute(..)
  do`, `props.Execute(..).Step`, or an interface passed directly as a parameter. They live
  until the end of the enclosing routine and cannot be set to `nil` - a manual
  `rows := nil` is not enough.
- Pattern: put all interface locals and the test body into a **local sub-procedure**
  (`procedure DoTests;` declared inside the test method), and keep only the creation of the
  owner and its `try..finally Free` in the outer method. The compiler finalizes every
  interface (named or hidden) when `DoTests` returns; comment the call
  (`// local sub-procedure to ensure all local interfaces are cleared`). Checks that need
  all statements gone (e.g. `props.ClearConnectionPool` + disconnect counter) come after
  `DoTests`.
- Test methods run in the background (`Run(Method, self, 'Name', true, false)`) expose
  this race much more often: never use `with props.Execute(..)` there, always an explicit
  local released before the owner.
- Review every test that frees a provider/server in the same routine that holds an
  `ISqlDB*` local or uses `with ...Execute(...)` - this was the root cause of all three
  "random GPF" fixes above.

**Self-check:** even Arnaud's rework needed six follow-up fix commits (bit array size, signedness,
#0 termination, Delphi compilation). After each refactoring pass, compile with Delphi and
FPC and run the tests of the unit before the next pass.

## Code quality: lessons from ab's hardening pass (2026-11-06/07)

From `31689eed5`, `23b709e4b`, `77c73fe68`, `013da880b`, `02bdc1671` (buffer overflows),
`610a95a23` (YAML), `8dae860bc` (Quack mock rewrite), `73ba52a40`/`282c8626a`/`42fd010b8`
(refactoring of contributor DHCP PRs), `b520475df`, `bc82aa795`, `da3cc68e4`, `6b5fac715`.

**TTextWriter buffer safety**
- `AddShort(P, Len)` only when `Len <= 255` is guaranteed by construction (literal tokens,
  numbers formatted into a local `ShortString`). Any length coming from input - JSON
  tokens/numbers, property or column names, DB values (PostgreSQL numeric/JSONB), HTTP
  headers (an IP from an nginx header), separators, macro expansions - uses
  `AddNoJsonEscape(P, Len)`. ab fixed 10+ such call sites in one pass.
- `AddDirect()` writes without a capacity check: only right after something that
  reserved room. For data-driven single chars write `Add(c)`.
- Never peek `W.B^` to test the last written char (dereferences an empty buffer): use
  `W.LastChar`.
- Document honest limits on validators (`IsValidJson` "is not a full RFC 8259 validation").

**Parsers of untrusted input**
- Count recursion depth on *every* recursive path (also compact `- - x` sequences and
  implicit `- key: v` mappings), not only on the main one; raise a clear error at the max.
- A quoted token must be consumed completely: reject trailing text after the closing
  quote instead of emitting it verbatim as JSON.
- Do not mix a relative pointer and 1-based string indexes (`p[cut - 1]` vs `S[cut]`).

**Binary encoding (protocols, test mocks)**
- Generate binary with a `TBufferWriter` (subclass it for a protocol: `Write1/2/4`,
  `WriteVarUInt64` = unsigned LEB128, `WriteVarLeb64` = signed LEB128, `FlushTo`), never
  with `RawByteString` concatenation of helper results: codepage handling differs between
  Delphi and FPC, and it is slower. Do not hand-roll varint encoders that exist already.

**Small idioms**
- Shrinking a string in place: `FakeLength(s, newlen)`, not `SetLength`.
- Growing a pointer/object array with a separate count: `PtrArrayAdd(arr, item, count)`
  instead of manual capacity arithmetic.
- In tests, build a binary buffer with `p := FastNewRawByteString(s, len)` and move `p`
  (`inc(p, $80)`, `PCardinal(p + $98)^`), not repeated `PByteArray(s)[$80 + ofs]`.

**Platform conditionals**
- Express a *capability*, not an OS: add `{$define HAS_xxx}` in `mormot.defines.inc`
  (e.g. `HAS_IP_PKTINFO`) and, if needed, a unit-local define (`DHCP_IFINDEX`) with a
  comment listing per-OS behavior, instead of scattered `{$ifdef OSLINUX}`.
- Compile out fields, types and methods that a platform does not need; keep both
  branches compiling and tested (ab's own refactor shipped `if p = nil then p^.x`,
  fixed in the next commit `8ddfa2777`).
- Missing POSIX constants for Delphi go to `mormot.core.os.delphi.pas`, not a local
  `const` in a net unit.

**Locking and threads**
- Under a read lock, look up and return a *pointer* into the array (caller holds the
  lock; check the first entry as the common fast path) instead of copying a record out
  in a `try..finally` per frame.
- A rejection from the remote side in a background/WebSocket thread must not raise there
  (caused an infinite reconnect loop): wake the waiting caller, log `sllWarning`, and
  call an optional `OnXxxError` event.

**Exceptions and tests**
- Raise the exception class of the unit's own scope (`ESynCrypto` in mormot.crypt.secure,
  not the catalog's `ECrypt`), and keep `///` comments naming it in sync.
- Expected exceptions in tests: set `TSynLog.Family.ExceptionIgnoreCurrentThread := true`
  or `ExceptionIgnore.Add(E)` *before* the code that raises, and `Remove(E)` afterwards;
  comment when the caller already did it. Fetch per-thread state (`ThreadRandom`) right
  where it is used.

## mORMot defaults (details: `docs/mORMot2-SAD-Recommended-Patterns.md`, Part A.1/A.2)

- Use the framework types on every path it serializes: `RawUtf8` (not `string`),
  `RawByteString` (not `TBytes`), `TDynArray`/`TDynArrayHashed` over `array of T`,
  `TRawUtf8List` (not `TStringList`), `TDocVariant`/`IDocDict` for schema-less JSON.
  `string` only at the UI/RTL boundary.
- Build text/JSON/SQL with `TTextWriter`/`TJsonWriter` or `FormatUtf8`, never by repeated
  concatenation or `Format`.
- Respect the unit layering in `src/FOLDER-DEPENDENCIES.md` (core -> lib/crypt -> net -> db ->
  orm/rest/soa -> app/ui/...). Conditional defines come only from `src/mormot.defines.inc`.
- Diagnostics via `TSynLog`, never `WriteLn`. No swallowed exceptions / bare `except`.
- Match the neighbouring code: `///` documentation comments on public API, existing
  naming, existing helper functions. Read recent upstream commits on the same unit to see
  how Arnaud refactors - that is the target style.

## Verification before a PR

- Compile with Delphi 7 (Win32), a recent Delphi (Win32 + Win64) and FPC when possible.
- Run `test/mormot2tests` (`/tests` lists classes, `/test <class>` restricts). New code
  needs a `TSynTestCase` that fails without it.
- Sources (`.pas`, `.inc`, `.dpr`) are ANSI / Windows-1252: keep new comments and strings
  pure ASCII and check `git diff` shows no line outside the intended change.

## References

- Architecture docs: `docs/mORMot2-SAD-Index.md` (chapter per topic), folder notes in
  `src/*/CLAUDE.md`.
- mormot2-superpowers Claude Code plugin (https://github.com/flydev-fr/mormot2-superpowers):
  skills `mormot2-core`, `mormot2-db`, `mormot2-orm`, `mormot2-net`, ... and its
  `code-reviewer` agent checklist.
