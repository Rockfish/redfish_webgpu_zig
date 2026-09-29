# Note: parallel work for bullets (2026-09-29)

Not needed yet. This records what was looked at, so the next time bullet counts (or
another per-frame workload) grow, the starting point is here.

Sources:

- `/Users/john/Dev/Dev_Roc/repos/roc/src/base/parallel.zig` (Roc's thread helper)
- `/Users/john/Dev/Dev_Rust/angry_wgpu_rust/src/bullets_parallel.rs` (a rayon experiment)
- `temp/Parallelization_Results.md` (its measurements; `temp/` is not in the repo, so the
  key numbers are repeated below)

## Summary

Nothing in angrybot needs parallelism now. Neither Roc's `parallel.zig` nor the rayon
pattern fits per-frame game work as-is. If it's ever needed, Zig 0.16's `std.Io.Group` is
the closer fit, with work handed out in chunks. Before any threads: measure in
ReleaseFast, then try SIMD. For tens of thousands of bullets, a compute shader is the
WebGPU way.

## Roc's `parallel.zig`

A one-shot fork-join. Each `process()` call:

1. starts up to `max_threads` OS threads (`std.Thread.spawn`),
2. hands out work items one index at a time through a shared atomic counter
   (`fetchAdd(1, .monotonic)`),
3. optionally gives each thread an arena that is reset before each item,
4. joins all threads before returning.

It was built for coarse work: its comments say a work item "can compile a complete Roc
program", and it is only used in Roc's snapshot tool. At that size, thread start-up and
one atomic per item are negligible.

For per-frame game work it has two costs:

- **Threads per call.** It spawns and joins OS threads on every call: tens of microseconds
  per thread, every frame.
- **One atomic per item.** Moving a bullet is a few nanoseconds of math, so contention on
  the shared counter would cost more than the work. Items would have to be chunks of
  hundreds of bullets, not single bullets.

It isn't drop-in either: it imports Roc's own `stack_overflow` and `SingleThreadArena`
modules and uses Zig 0.15-era `std.array_list.Managed`.

## Zig 0.16: `std.Io.Group`

The standard library now has the pieces. `std.Io.Group` is a fork-join:
`group.async(io, function, args)` per task, then `group.await(io)`. With the threaded `Io`
implementation, tasks run on a pool whose threads are kept and reused (`Io/Threaded.zig`:
"a new thread to be spawned and permanently added to the pool"). The apps already receive
`init.io`, so a chunked fork-join needs no new infrastructure. Its per-frame overhead
hasn't been measured.

## The Rust measurements, re-read

From `Parallelization_Results.md`:

| Test | Parallel (rayon) | Serial |
|---|---|---|
| Spread rotation setup, 20 values ("Array" vs "Vector") | 394-444 µs | 15-16 µs |
| Bullet creation, 400 bullets (spread 20) | 300 µs - 1.1 ms | 100-167 µs |
| 2,500 bullets (spread 50) | 320 µs - 1.3 ms | 505-627 µs |
| 10,000 bullets (spread 100) | 5 µs - 1 ms | 1.4-1.7 ms |
| 40,000 bullets (spread 200) | 1.5-2.5 ms | 5-7 ms |

The note concluded that parallel breaks even around 2,500 bullets. Four things change how
to read that:

- **"Array vs Vector" is really parallel vs serial.** The array version used `par_iter`,
  the vector version a plain loop. It also runs once at startup, when rayon creates its
  global thread pool on first use, so the 394 µs likely includes thread creation. It
  doesn't measure arrays against vectors.
- **The serial numbers look like a debug build.** 400 bullets in 100-167 µs is about
  250-400 ns per bullet for two quaternion multiplies and a rotate. An optimized build
  should be one to two orders of magnitude faster, which would move the break-even point
  far above 2,500. `Cargo.toml`'s release profile is `opt-level = 'z'` (optimize for size),
  not speed; re-run with `opt-level = 3` before drawing conclusions.
- **The timed code is bullet creation** (once per shot), not the per-frame work, which is
  `update_bullets`: moving every live bullet and testing it against enemies.
- **The parallel spread is a warning.** 5 µs to 1 ms for the same work is thread wake-up
  and scheduling jitter. Even when the average wins, jitter hurts frame pacing.

## This project's bullets

`games/angrybot`: `SPREAD_AMOUNT` 20, so 400 bullets per shot; `FIRE_INTERVAL` 0.5 s;
`BULLET_LIFETIME` 10 s. At most about 8,000 live bullets. The per-frame update
(`BulletSystem.updateBullets`) is one subtract per bullet plus collision tests culled by
per-subgroup AABBs. Expected to be well under a millisecond serially in ReleaseFast; not
measured yet.

## If bullets ever need it, in this order

1. **Measure in ReleaseFast** (`zig build angrybot -Doptimize=ReleaseFast`), timing
   `updateBullets`. Debug Zig is also many times slower than release.
2. **SIMD.** `@Vector` over positions and directions: several times faster, no threads,
   no jitter.
3. **Chunked fork-join with `std.Io.Group`.** One task per chunk of a few hundred bullets,
   once per frame, awaited before drawing. Collision needs care: bullets in different
   chunks can hit the same enemy and write `enemy.is_alive` at the same time, a data
   race. Either split the work by enemy, or collect hits per chunk and apply them after
   `await`.
4. **A GPU compute shader** for tens of thousands. Positions live in a storage buffer the
   instanced draw reads directly, which also removes the per-frame upload through
   `vertex_ring`. Collision moves to the GPU too, with hits read back a frame later.
