# Changelog

## 0.5.2 (2024-12-06)

### Enhancements
- Clean up parent tmp code_sync artifacts on pool shutdown

## 0.5.1 (2024-09-19)

### Enhancements
- Add basic rate limiting retries to the FlyBackend to abide by Fly's rate limits of 1 request per second, with 3 requests per second burst.
- Add basic retries for `no capacity` errors in the FlyBackend

## 0.5.0 (2024-09-11)

### Enhancements
- Add `copy_apps` option to `code_sync` to copy all apps in the code path, which is
  set to true when `start_apps` is true.
- Support `copy_paths` for arbitrary paths unrelated to beams apps for copying arbitrary
  files on boot to the runner.

### Deprecations
- `copy_paths: true` has been deprecated in favor of `start_apps: true`, to copy
  all apps and start them. You can also pass `copy_paths: true` to copy all apps
  without starting them. Now `copy_paths` is reserved for copying arbitrary paths
  unrelated to beams apps.

## 0.4.4 (2024-09-03)

### Bug Fixes
- Fix idle shutdown running before code sync, causing long code syncs to shut runners down prematurely

## 0.4.3 (2024-09-02)

### Bug Fixes
- Fix `:compress` to `:code_sync` raise invalid option error

## 0.4.2 (2024-08-27)

### Enhancements
-  Support `:compress` option to `code_sync` to control compression of `:copy_paths` and `:sync_beams`.

## 0.4.1 (2024-08-27)

### Bug Fixes
- Fix beam files not being copied on first sync

## 0.4.0 (2024-08-27)

### Bug Fixes
- Forward `:boot_timeout` to backend options

### Enhancements
-  Optimize concurrent runner booting

## 0.3.0 (2024-07-26)

### Bug Fixes
- Copy sym links in `:copy_paths` and `:sync_beams`
- Fix function error caused by anonymous functions in `:copy_paths` and `:sync_beams`

### Enhancements
- Use OTP 27's `:json` if available
- Introduce `FLAME.Trackable` protocol for tracking resources
- Introduce `FLAME.track_resources/3` to recursively track resources
  on a given node

## 0.2.0 (2024-06-17)

### Backwards incompatible changes
- For backend implementations, the `FLAME.Parent` encoded format has changed to include more information about the parent and child. See `FLAME.Parent` moduledoc for more information.

### Enhancements
- Add `:code_sync` pool configuration for syncing beam files and code paths to flames

## 0.1.12 (2024-03-14)
- Support `link: false` on `FLAME.call/3`, `FLAME.cast/3`, and `FLAME.place_child/3` for opt-in allowance of long-running FLAME operations (up to `:shutdown_timeout`) regardless of what happens to the caller process or caller node.

## 0.1.11 (2024-02-22)
- Add ability to configure custom metadata for launch FlyBackend machine

## 0.1.10 (2024-02-21)
- Fix `FLAME.cast/2` defaulting to boot timeout for executions

## 0.1.9 (2024-02-20)
- Fix `FLAME.cast/2` allowing more than allowed max_concurrency operations
- Explicitly prefer local region in `FlyBackend`

## 0.1.8 (2024-01-02)
- Fix Pool supervisor name collisions

## 0.1.7 (2023-12-15)
- Fix error on concurrent calls when runners are pending

## 0.1.6 (2023-12-11)
- Fix references to incorrectly named FLAME_PARENT export

## 0.1.5 (2023-12-07)
- Allow passing fly guest options to configure cpus, cpu_kind, gpu_kind, and memory_mb

## 0.1.4 (2023-12-06)

Public release 🔥
