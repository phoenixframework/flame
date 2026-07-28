# FLAME (NomixGroup fork)

Temporary fork of [phoenixframework/flame](https://github.com/phoenixframework/flame).

## Change

Increased TLS certificate chain depth from 2 to 5 in `lib/flame/fly_backend.ex`.

**Why:** Let's Encrypt moved `api.machines.dev` to their Generation Y hierarchy on
2026-07-26, which adds a cross-signed root making the chain 3 CAs deep.
FLAME's hardcoded `depth: 2` is one hop too shallow, causing all FLAME worker
boots to fail with `{bad_cert, max_path_length_reached}`.

See: https://github.com/phoenixframework/flame/issues/88

## Usage

In `mix.exs`:

    {:flame, github: "NomixGroup/flame", branch: "main", override: true}

## Revert

Once a fix ships on hex.pm, revert `mix.exs` to `{:flame, "~> 0.5"}` and
delete this fork.