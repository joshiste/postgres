# TOAST

The Oversized-Attribute Storage Technique: how variable-length values are compressed and
moved out of line so a heap tuple fits in a page. Authoritative user-facing description is
the "TOAST" section of `doc/src/sgml/storage.sgml`.

## Files

- `src/include/varatt.h`: varlena header layouts and every accessor. The accessors
  (`VARSIZE`, `VARDATA`, `VARATT_IS_EXTERNAL`, `VARATT_IS_COMPRESSED`, `VARATT_IS_SHORT`,
  `VARATT_IS_EXTENDED`, `VARSIZE_ANY`, `VARDATA_ANY`, `SET_VARSIZE`, ...) are now
  `static inline` functions taking `const void *`, not macros.
- `src/include/access/heaptoast.h`, `src/backend/access/heap/heaptoast.c`: the heap AM's
  strategy driver (`heap_toast_insert_or_update`, `heap_toast_delete`) and chunk fetch
  (`heap_fetch_toast_slice`), plus the size thresholds.
- `src/include/access/toast_helper.h`, `src/backend/access/table/toast_helper.c`:
  AM-agnostic per-attribute bookkeeping (`ToastTupleContext`, `ToastAttrInfo`) and the pass
  primitives any table AM can reuse.
- `src/include/access/toast_internals.h`, `src/backend/access/common/toast_internals.c`:
  writing and deleting out-of-line values (`toast_save_datum`, `toast_delete_datum`), value
  id assignment, toast index handling, `toast_compress_datum`.
- `src/include/access/toast_compression.h`, `src/backend/access/common/toast_compression.c`:
  pglz and lz4 compress/decompress, including slice decompression.
- `src/include/access/detoast.h`, `src/backend/access/common/detoast.c`: reading
  (`detoast_attr`, `detoast_attr_slice`, `detoast_external_attr`, size queries).
- `src/backend/catalog/toasting.c`: creating toast tables and their index.
- `src/include/utils/expandeddatum.h`, `src/backend/utils/adt/expandeddatum.c`: in-memory
  expanded objects, which piggyback on the TOAST pointer mechanism.
- `src/backend/access/common/indextuple.c`: `index_form_tuple` guarantees indexes never
  contain TOAST pointers.

## Varlena representations

A varlena datum has one of four shapes, distinguished by the first byte(s):

- 4-byte header, uncompressed (`varattrib_4b.va_4byte`). The only "plain" form.
- 4-byte header, compressed inline (`varattrib_4b.va_compressed`). `va_tcinfo` holds the raw
  size in its low 30 bits and the compression method id in the top 2 bits.
- 1-byte header, "short" (`varattrib_1b`): payload up to `VARATT_SHORT_MAX`, unaligned. Created
  by `heap_fill_tuple` for any small varlena regardless of TOAST; cheap to convert back.
- 1-byte header with zero length bits, a TOAST pointer (`varattrib_1b_e`). The second byte
  is a `vartag_external`: `VARTAG_ONDISK` (18, for compatibility with the old "tag equals
  pointer size" convention), `VARTAG_INDIRECT`, `VARTAG_EXPANDED_RO`, `VARTAG_EXPANDED_RW`.

`VARATT_IS_EXTENDED` means "anything but the plain form". Code that does not need alignment
should use the `_ANY` / `_PACKED` accessors (`PG_DETOAST_DATUM_PACKED`, `PG_GETARG_TEXT_PP`)
to avoid needless copying of short-header values.

The on-disk pointer payload `varatt_external` has four fields: `va_rawsize` (uncompressed
size including header), `va_extinfo` (external size in the low 30 bits, compression method in
the top 2 bits; `VARATT_EXTERNAL_GET_EXTSIZE`, `VARATT_EXTERNAL_GET_COMPRESS_METHOD`),
`va_valueid` and `va_toastrelid`. Both ids are still `Oid`. Whether an external value is
compressed is derived, not flagged: `VARATT_EXTERNAL_IS_COMPRESSED` compares external size
with raw size. The struct is stored unaligned in tuples, so always copy it out with
`VARATT_EXTERNAL_GET_POINTER`. A complete on-disk pointer is `TOAST_POINTER_SIZE` (18) bytes.

## When and how a tuple gets toasted

`heap_prepare_insert` and `heap_update` call `heap_toast_insert_or_update` when the tuple has
any external value or is longer than `TOAST_TUPLE_THRESHOLD` (about 2 kB, from
`TOAST_TUPLES_PER_PAGE`). The goal is to shrink the tuple below the target, which is
`TOAST_TUPLE_TARGET` unless the `toast_tuple_target` reloption overrides it
(`RelationGetToastTupleTarget`). The reloption changes only the target, not the threshold.

`toast_tuple_init` classifies every attribute. Non-varlena, NULL and `TYPSTORAGE_PLAIN`
columns are ignored. On UPDATE, an out-of-line value that is byte-identical to the old
pointer is kept as is, which is why rewriting a row without touching a large column costs
nothing. Any other incoming external or expanded value is pulled inline first with
`detoast_external_attr`.

Then four passes run, each repeated while the tuple is still over target. Each pass picks
the largest eligible attribute with `toast_tuple_find_biggest_attribute`:

1. Compress the largest `TYPSTORAGE_EXTENDED` attribute (`toast_tuple_try_compression`).
   `TYPSTORAGE_EXTERNAL` attributes are marked incompressible instead. If that single
   attribute still exceeds the target on its own, externalize it right away.
2. Externalize the largest EXTENDED or EXTERNAL attribute (`toast_tuple_externalize`).
   Skipped entirely if the relation has no toast table.
3. Compress `TYPSTORAGE_MAIN` attributes.
4. Externalize MAIN attributes, but only against the relaxed `TOAST_TUPLE_TARGET_MAIN`
   (one tuple per page). MAIN therefore means "out of line only as a last resort".

If anything changed, a new tuple is formed and `toast_tuple_cleanup` deletes replaced
out-of-line values. `heap_toast_delete` removes chunks on DELETE. Table rewrites
(`rewriteheap.c`) run the same driver; toast tables themselves are never toasted (their
columns are forced to PLAIN storage).

## Compression

Two methods, identified by `ToastCompressionId` (`TOAST_PGLZ_COMPRESSION_ID`,
`TOAST_LZ4_COMPRESSION_ID`); the 2-bit field permits at most four. Per-column choice is
`pg_attribute.attcompression` (`'p'`, `'l'`, or `'\0'` meaning "use the GUC"). The
`default_toast_compression` GUC now defaults to lz4 when the build has LZ4, else pglz;
the enum option table is in `guc_tables.c` and the declaration in `guc_parameters.dat`.
`ALTER TABLE ... SET COMPRESSION` affects only future values, so a column can hold a mix
(visible via `pg_column_compression`).

`toast_compress_datum` refuses external or already-compressed input, dispatches to
`pglz_compress_datum` or `lz4_compress_datum`, and accepts the result only if it saves more
than two bytes; otherwise it returns a null Datum and the attribute is marked incompressible.
pglz additionally refuses inputs outside its strategy's min/max input size.

## Detoasting

- `detoast_attr` returns the plain 4-byte form for anything: fetches chunks and decompresses
  on-disk pointers, dereferences indirect pointers, flattens expanded objects, decompresses
  inline-compressed values, and widens short headers.
- `detoast_external_attr` fetches out of line but does not decompress.
- `detoast_attr_slice` is the partial read behind `substr` and friends. For an uncompressed
  external value it fetches only the needed chunks. For a compressed value it can only
  produce a prefix: with pglz it uses `pglz_maximum_compressed_size` to fetch a bounded prefix
  of chunks; with lz4 it must fetch every chunk (no liblz4 API bounds the input) and then
  decompresses partially with `lz4_decompress_datum_slice`. This is why `SET STORAGE EXTERNAL`
  is recommended for wide text/bytea columns that are sliced.
- `toast_raw_datum_size` (logical size) and `toast_datum_size` (physical size) answer size
  questions without fetching.
- Chunk fetching goes through the table AM callback `relation_fetch_toast_slice`
  (`heap_fetch_toast_slice`), which scans the toast index on `(chunk_id, chunk_seq)` with
  `get_toast_snapshot`. That function errors if no snapshot is registered or active, which is
  the guard against detoasting after a procedure has committed.

The fmgr wrappers are `pg_detoast_datum`, `pg_detoast_datum_copy`, `pg_detoast_datum_slice`,
`pg_detoast_datum_packed` behind the `PG_DETOAST_DATUM*` macros in `fmgr.h`.

## Toast tables

`create_toast_table` makes `pg_toast.pg_toast_<parent oid>` with columns `chunk_id` (oid),
`chunk_seq` (int4), `chunk_data` (bytea) and a unique btree on the first two, records the
oid in `pg_class.reltoastrelid`, and adds a dependency. `needs_toast_table` delegates to the
table AM (`heapam_relation_needs_toast_table`): at least one non-PLAIN varlena column whose
maximum tuple width could exceed the threshold. Partitioned tables, and shared or catalog
relations after initdb, never get one (`misc_sanity.sql` enforces the catalog exceptions).

`toast_save_datum` splits a value into `TOAST_MAX_CHUNK_SIZE` pieces (just under 2 kB, sized so
four chunk tuples fit a page; changing it needs initdb and pg_upgrade checks it), assigns
`va_valueid` with `GetNewOidWithIndex`, inserts the chunks, and manually inserts into every
toast index that is `indisready`. Readers use only the `indisvalid` one (`toast_open_indexes`
returns its position). This is how REINDEX CONCURRENTLY on a toast index works while writes
continue. During a rewrite that swaps toast tables by content, `rd_toastoid` on the new
relation makes `toast_save_datum` preserve the old value ids and skip values already copied
(`toastrel_valueid_exists`).

## Expanded objects and indirect pointers

`VARTAG_EXPANDED_RO/RW` point at an `ExpandedObjectHeader` living in its own memory context,
with methods `get_flat_size` and `flatten_into`. Arrays (`array_expanded.c`), records
(`expandedrecord.c`) and PL/pgSQL variables use them to avoid repeated deserialization. Every
detoast path flattens them, and `toast_tuple_init` guarantees none reach disk. Read-write
versus read-only distinguishes whether the callee may modify in place. `VARTAG_INDIRECT`
is a plain pointer to a varlena; its only current user is logical decoding
(`ReorderBufferToastReplace`), which reassembles chunks into an indirect datum to avoid
building physical tuples over 1 GB.

## Interactions to remember

- Indexes never hold TOAST pointers. `index_form_tuple` detoasts external values and may
  compress inline when a datum exceeds `TOAST_INDEX_TARGET`. There is no out-of-line storage
  for index tuples.
- Composite and array datums must not contain external pointers; `toast_flatten_tuple` and
  `toast_flatten_tuple_to_datum` in `heaptoast.c` enforce this when a row is stored as a datum.
- VACUUM processes the toast table after the main one (`VACOPT_PROCESS_TOAST`), never
  analyzes it, and merges `toast.`-prefixed reloptions.
- `ALTER TABLE ... SET STORAGE` (`ATExecSetStorage`) may create a toast table; storage and
  compression settings propagate to index columns.
- `pg_dump` emits per-column `SET COMPRESSION` unless `--no-toast-compression`; psql's
  `HIDE_TOAST_COMPRESSION` variable hides it in `\d+`.
- `contrib/amcheck` `verify_heapam(check_toast => true)` validates pointers against chunks.
- Large objects (`inv_api.c`, `LOBLKSIZE`) are a separate mechanism.

## Tests

`src/test/regress/sql/compression.sql` (build-independent), `compression_lz4.sql` (skips itself
when lz4 is absent), `compression_pglz.sql`, `indirect_toast.sql` (uses `make_tuple_indirect`
from `regress.c` and pins pglz so values are actually externalized), plus toast paths in
`strings.sql`, `alter_table.sql`, `misc_sanity.sql`, `cluster.sql`, `vacuum.sql`.
`src/test/modules/test_autovacuum/t/002_toast_relopts.pl` covers toast reloptions.
