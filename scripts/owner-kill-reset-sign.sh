#!/usr/bin/env bash
# Owner kill-reset attestation signing. The owner runs this script directly.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <engagement_epoch> <nonce>" >&2
  exit 2
fi

EPOCH="$1"
NONCE="$2"
if ! [[ "$EPOCH" =~ ^[0-9]+$ && "$NONCE" =~ ^[0-9]+$ ]]; then
  echo "engagement_epoch and nonce must be unsigned decimal integers" >&2
  exit 2
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# This ceremony must not build. `cargo run` compiled base-kill-reset-bin on the spot,
# which had two problems on the node host. It wrote into the Cargo target tree, and
# $ROOT_DIR/target holds artifacts hardlinked to the running EL and CL binaries, so a
# stray build here can replace what the node is executing. And it meant the owner signed
# using a binary produced seconds earlier from whatever the working tree happened to
# contain, rather than one that had been built and inspected deliberately.
#
# Resolve an already-built binary instead, and fail closed with the exact isolated build
# command when there is none. Nothing below invokes Cargo.
KILL_RESET_BIN_NAME="base-mev-kill-reset"
ISOLATED_TARGET_ROOT="${ISOLATED_TARGET_ROOT:-/data/base-build/cargo-target}"

resolve_kill_reset_bin() {
  local candidate
  # An explicit override wins, so an owner can sign with a binary from anywhere they trust.
  if [ -n "${BASE_KILL_RESET_BIN:-}" ]; then
    printf '%s\n' "$BASE_KILL_RESET_BIN"
    return 0
  fi
  for candidate in \
    "${CARGO_TARGET_DIR:-}/maxperf/$KILL_RESET_BIN_NAME" \
    "${CARGO_TARGET_DIR:-}/ci/$KILL_RESET_BIN_NAME" \
    "$ISOLATED_TARGET_ROOT/maxperf/$KILL_RESET_BIN_NAME" \
    "$ISOLATED_TARGET_ROOT/ci/$KILL_RESET_BIN_NAME" \
    "$ROOT_DIR/target/maxperf/$KILL_RESET_BIN_NAME"
  do
    case "$candidate" in /maxperf/*|/ci/*) continue ;; esac
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! KILL_RESET_BIN="$(resolve_kill_reset_bin)"; then
  {
    echo "no $KILL_RESET_BIN_NAME binary found; refusing to build during a signing ceremony."
    echo "Build it first, into a target directory outside this checkout:"
    echo
    echo "  CARGO_TARGET_DIR=$ISOLATED_TARGET_ROOT \\"
    echo "    /home/ubuntu/.local/bin/cargo-isolated build --profile maxperf \\"
    echo "    --manifest-path $ROOT_DIR/Cargo.toml -p base-kill-reset-bin"
    echo
    echo "Then re-run this script, or point BASE_KILL_RESET_BIN at the binary you trust."
    echo "Never plain 'cargo build' here: $ROOT_DIR/target is hardlinked to the running node."
  } >&2
  exit 1
fi

echo "  binary : $KILL_RESET_BIN"
echo "  sha256 : $(sha256sum -- "$KILL_RESET_BIN" | cut -d' ' -f1)"
RESET_CONTEXT="$("$KILL_RESET_BIN" --prepare "$EPOCH" "$NONCE")"
mapfile -t RESET_LINES <<< "$RESET_CONTEXT"
if [ "${#RESET_LINES[@]}" -ne 2 ]; then
  echo "kill-reset binary returned an invalid preparation response" >&2
  exit 1
fi
MSG="${RESET_LINES[0]}"
EXPECT_ADDR="${RESET_LINES[1]}"
echo "  message: $MSG"

echo "== [1/3] derive and compare owner address =="
GOT_ADDR="$(cast wallet address --interactive)"
echo "  derived: $GOT_ADDR"
echo "  expect : $EXPECT_ADDR"
if [ "${GOT_ADDR,,}" != "${EXPECT_ADDR,,}" ]; then
  echo "  owner address mismatch; aborting" >&2
  exit 1
fi

echo "== [2/3] sign =="
SIG="$(cast wallet sign --interactive "$MSG")"

echo "== [3/3] verify =="
cast wallet verify --address "$EXPECT_ADDR" "$MSG" "$SIG"
SIG_HEX="${SIG#0x}"
if ! [[ "$SIG_HEX" =~ ^[0-9a-f]{130}$ ]]; then
  echo "cast returned a non-canonical signature; aborting" >&2
  exit 1
fi

echo ""
echo "================ KILL-RESET SIGNATURE ================"
echo "$SIG_HEX"
echo "======================================================"
