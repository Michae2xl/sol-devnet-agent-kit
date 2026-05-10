#!/usr/bin/env bash
# One-shot relay setup. Run from the relay/ directory after `npm install`.
#
#   bash setup.sh
#
# Requires: solana CLI keypair at ~/.config/solana/id.json (used as the relay
# hot wallet), wrangler in node_modules.
set -euo pipefail

cd "$(dirname "$0")"

KEYPAIR_PATH="${RELAY_KEYPAIR_PATH:-$HOME/.config/solana/id.json}"
WRANGLER_TOML="wrangler.toml"

[[ -f "$KEYPAIR_PATH" ]] || {
  echo "Keypair not found at $KEYPAIR_PATH" >&2
  echo "Set RELAY_KEYPAIR_PATH=/path/to/keypair.json or run solana-keygen new." >&2
  exit 1
}

echo "==> Logging into Cloudflare (browser will open if not already logged in)"
npx wrangler login

if grep -q 'REPLACE_ME_KV_ID' "$WRANGLER_TOML"; then
  echo "==> Creating KV namespace RELAY_KV"
  RAW="$(npx wrangler kv namespace create RELAY_KV 2>&1 | tee /dev/stderr)"
  KV_ID="$(printf '%s' "$RAW" | grep -oE 'id = "[^"]+"' | head -1 | sed 's/id = "\(.*\)"/\1/')"
  if [[ -z "$KV_ID" ]]; then
    echo "Could not auto-detect the KV id from wrangler output." >&2
    echo "Copy the id manually into $WRANGLER_TOML and rerun." >&2
    exit 1
  fi
  echo "==> Writing KV id $KV_ID into $WRANGLER_TOML"
  sed -i.bak "s/REPLACE_ME_KV_ID/$KV_ID/" "$WRANGLER_TOML"
  rm -f "$WRANGLER_TOML.bak"
else
  echo "==> KV id already set in $WRANGLER_TOML, skipping creation"
fi

echo "==> Uploading keypair as RELAY_KEYPAIR_JSON secret"
cat "$KEYPAIR_PATH" | npx wrangler secret put RELAY_KEYPAIR_JSON

echo "==> Deploying worker"
npx wrangler deploy

echo
echo "Done. Hit GET / on the worker URL to confirm. Example:"
echo "  curl -s https://sol-devnet-fee-relay.<your-subdomain>.workers.dev/"
