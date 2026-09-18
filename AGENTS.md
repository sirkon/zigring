# AGENTS.md

## Project

`zigring` is a small, libc-backed Zig wrapper around Linux `io_uring`. It is a
**library**, not an executable: downstream projects add it as a package and
`@import("zigring")`. The public surface is `src/root.zig`; everything else in
`src/` is a private implementation detail.

- Toolchain: **Zig 0.16.0** (`build.zig.zon` pins `minimum_zig_version`).
- Target: **Linux only**, **libc required**. The build sets `link_libc = true`
  because the pthread wrappers call real `pthread_*` symbols and the ring uses
  raw syscalls. Do not remove it.
- Uses Zig 0.16 std APIs (`std.Io.sleep(io, ...)`, `std.testing.io`); older
  std-before-async snippets will not compile.

## Commands

```sh
zig build test          # unit + integration tests (the only meaningful build step)
zig fmt src/ build.zig  # formatting (source is already fmt-clean)
```

- There is no separate lint step; `zig build` (default `install`) produces no
  useful artifact, so use `zig build test`.
- `zig build test` compiles **three** test binaries (see `build.zig`): the
  module root `src/root.zig` (unit tests of every private module), plus two
  standalone integration roots `src/iouringtest.zig` and `src/sendzc_test.zig`.
  Adding a new standalone test root requires registering it in `build.zig`.
- Integration tests bind **hardcoded loopback ports** (`60006`, `60011`) and the
  file test writes `/tmp/file.txt`. A leftover process on those ports or an
  existing file can make tests flaky.
- Tests print via `std.debug.print`; the runner reports `N/N tests passed`.

## Source layout

| File | Responsibility |
|------|----------------|
| `src/root.zig` | Public entry point. Re-exports every type/value consumers need and pulls each private module's `test` blocks in via `_ = module;`. Add new public API here or it is unreachable. |
| `src/iouring.zig` | The core (~1800 lines). `Ring`, `CQE`, `TaskFlags`, `BufferSizeClass`, `BatchSQ`, `BatchCQ`, `ReorderBuffer`. |
| `src/provided_buffer.zig` | `ProvidedBufferPool`: kernel-provided buffer rings (huge-page mmap, `IORING_REGISTER_PBUF_RING`). |
| `src/ring_factory.zig` | `Factory`: thread-safe ring allocator that spreads rings over at most `maxPollerThreads` kernel pollers using `IORING_SETUP_ATTACH_WQ`. (Renamed from `ring_manager.zig`.) |
| `src/slotter.zig` | `Slots(T)` and `BufferSlots`: dense index allocators with lazy child tables. |
| `src/pthread.zig` | Hand-declared `extern "c"` pthread mutex/cond/thread wrappers. |
| `src/time.zig` | vDSO `clock_gettime` helpers (`nowNs`, `monotonicNs`). |
| `src/sockets.zig` | `createTCPServerSocket` / `createTCPClientSocket`. |
| `src/iouringtest.zig`, `src/sendzc_test.zig` | Integration suites (standalone roots, not part of the library module). |

Control flow is completion-driven: `Ring.push*` writes an SQE and (usually
without a syscall, thanks to SQPOLL) wakes the poller; results arrive as `CQE`s
drained by `popCQE` / `batchedCQ`, with `park` as the cold-path blocking wait.
The integration tests model application logic as explicit FSMs (`echoServerFSM`,
`echoClientFSM`) that call `do()` in a loop until `done()`.

## Conventions

- Style: `camelCase` functions/fields, `PascalCase` types, `Self = @This()`.
- Hot-path push methods are `inline fn`; cold branches use `@branchHint(.cold)`.
- Every public declaration gets a `///` doc comment, modules get `//!`. Match
  this density when editing.
- Types are allocated and passed by pointer (`*Self`) with explicit `init`/
  `deinit` pairs; allocator must outlive the object.
- **Do not "fix" the public API spelling/typos.** `regiterSizeClassReceiveBuffer`
  (missing `s`) and `ProvidedBufferPool.notInitalized` are load-bearing public
  names. Renaming them breaks downstream code; only change names the user asks for.

## Gotchas (read before touching `iouring.zig`)

- **ABI-exact structs.** `CQE` is an `extern struct` that overlays the kernel
  `io_uring_cqe` byte-for-byte, and `io_uring_buf_ring`/`linux.io_uring_buf`
  layouts are asserted in `provided_buffer.zig` `comptime` blocks. Do not
  reorder/repack fields or change sizes.
- **Async pointer lifetime.** The kernel reads SQE arguments (buffers, paths,
  `timespec`s, sockaddrs) asynchronously. Every pointer passed to a `push*` must
  stay valid and unmodified until its matching `CQE` is consumed.
- **Provided-buffer protocol.** Buffer-select ops (`pushReadZC`, `pushRecvZC`,
  `pushRecvMultishotZC`) require `regiterSizeClassReceiveBuffer(size, entries)`
  first (else `error.BufferPoolNotInitialized`); `entries` must be a power of
  two, and only one pool per size class. Each CQE with `hasBuffer()` carries a
  borrowed `bid()` that must be returned **exactly once** with `releaseBuffer`;
  failing to do so drains the pool and multishot recv starts returning `-ENOBUFS`.
- **`pushSendZC` produces two CQEs**: the first sets `hasMore()` (bytes queued,
  buffer still pinned), the second sets `hasNotif()` (buffer reusable). Requires
  a buffer registered via `registerBuffers`, and the caller owns that mmap
  (release with `posix.munmap`, not `deinit`).
- **Multishot ops** (`pushRecvMultishotZC`, `pushAcceptMultishot`) keep emitting
  CQEs while `hasMore()` is set; one multishot per fd.
- **Linked timeouts.** `pushTimeoutForOp` must be pushed in the *same*
  `batchedSQ` batch as the operation it guards, otherwise the kernel rejects it
  with `-EINVAL`. See the "never happen" test.
- **`Ring` is not thread-safe.** Use one ring per thread (the `Factory` is the
  thread-safe way to hand out rings). `BatchSQ`/`BatchCQ` snapshots head/tail at
  open and only publish on `commit`.
- **Hot path first.** Call `popCQE`/`batchedCQ` before `park`; `park` costs a
  syscall and should only run when the CQ is empty.
- **Validation errors to remember:** `Ring.init` requires a power-of-two
  `queueDepth` (`error.ZigRingRequiresDepthPowOf2`); `Slots`/`BufferSlots`
  require capacity a power of two and `>= 4096`; `ReorderBuffer` requires size a
  power of two and `<= 0xFFFF`.
- **Huge-page mmaps** fall back to regular 4 KiB pages when the OS has none, and
  the returned slice length is rounded up to the mapping page size; the *whole*
  returned slice is what gets `munmap`ed.
- **`IORING_REGISTER_PBUF_RING = 22` is hardcoded on purpose** because the
  `IORING_REGISTER` enum ordering is not stable across kernels.
- `ring_factory.acquireRing(queueDepth, weight)` uses weight to pick the poller
  with the least load and refuses to build a new poller past `maxPollerThreads`.

## Testing patterns

- Unit tests live in the private module files (`slotter.zig`, `pthread.zig`,
  `time.zig`) and are surfaced through `root.zig`.
- Integration tests are separate roots: they create real rings and drive real
  loopback TCP. `iouringtest.zig` has a large `echo server and client` soak
  (~100k multiplexed round-trips) with per-side FSMs that assert sequence
  ordering, payload contents, and monotonic time.
- Test helpers in `iouringtest.zig`: `wait` (blocks via `park`), `waitNoMatterWhat`,
  `waitPeacefully`, `getAcceptedConn`. A `must(comptime msg, expr)` helper turns
  errors into panics with context.
- Use `std.heap.ArenaAllocator` over `std.heap.page_allocator` in tests, and
  `std.testing.expectEqualStrings` / `expectEqualSlices` for payload checks.

## Dependencies

`build.zig.zon` has no external dependencies; `paths` lists exactly
`build.zig`, `build.zig.zon`, `src`, `LICENSE`, `README.md`. If you add files
that must ship with the package, update `paths`, and bump/keep the `fingerprint`
consistent.
