#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sol-devnet-simple.sh <DEST_DEVNET_WALLET> <DURATION>

Examples:
  sol-devnet-simple.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 60s
  sol-devnet-simple.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 5m
  sol-devnet-simple.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 120

What this script does:
  - Creates or reuses a temporary devnet keypair.
  - Installs devnet-pow with cargo if devnet-pow is missing.
  - Mines devnet SOL for the requested time.
  - Sends the mined balance back to DEST_DEVNET_WALLET.
  - Keeps 0.01 devnet SOL in the temporary keypair for future fees.

Do not use a mainnet wallet private key with this script. It only needs your
public devnet wallet address.
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

DEST_WALLET="${1:-}"
DURATION="${2:-}"

if [[ "${DEST_WALLET:-}" == "-h" || "${DEST_WALLET:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ -n "$DEST_WALLET" ]] || { usage; exit 1; }
[[ -n "$DURATION" ]] || { usage; exit 1; }

if [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  DURATION="${DURATION}s"
fi
if ! [[ "$DURATION" =~ ^[0-9]+[smh]$ ]]; then
  fail "Duration must look like 60s, 5m, 1h, or a plain number of seconds."
fi

DIFFICULTY="${SOL_DEVNET_DIFFICULTY:-3}"
REWARD="${SOL_DEVNET_REWARD:-0.02}"
TARGET_LAMPORTS="${SOL_DEVNET_TARGET_LAMPORTS:-5000000000}"
RESERVE_LAMPORTS="${SOL_DEVNET_RESERVE_LAMPORTS:-10000000}"
AIRDROP_LAMPORTS="${SOL_DEVNET_AIRDROP_LAMPORTS:-11000000}"
TRANSFER_FEE_LAMPORTS="${SOL_DEVNET_TRANSFER_FEE_LAMPORTS:-5000}"
RPC_URL="${SOL_DEVNET_RPC_URL:-https://api.devnet.solana.com}"
STATE_DIR="${SOL_DEVNET_STATE_DIR:-$HOME/.sol-devnet-miner}"
KEYPAIR_PATH="$STATE_DIR/current-keypair.json"
LATEST_FILE="$STATE_DIR/latest-keypair"

need_cmd node
need_cmd sleep

node_eval() {
  node - "$@"
}

validate_pubkey() {
  node_eval "$1" <<'NODE'
const key = process.argv[2];
const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function b58decode(str) {
  let n = 0n;
  for (const ch of str) {
    const val = alphabet.indexOf(ch);
    if (val < 0) throw new Error('invalid base58 character');
    n = n * 58n + BigInt(val);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  const body = n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex');
  let leading = 0;
  for (const ch of str) {
    if (ch === alphabet[0]) leading++;
    else break;
  }
  return Buffer.concat([Buffer.alloc(leading), body]);
}
try {
  const decoded = b58decode(key);
  if (decoded.length !== 32) {
    throw new Error(`decoded public key has ${decoded.length} bytes`);
  }
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
NODE
}

validate_pubkey "$DEST_WALLET" || fail "Destination wallet is not a valid Solana public key."

install_devnet_pow_if_needed() {
  DEVNET_POW_BIN="${DEVNET_POW_BIN:-$(command -v devnet-pow || true)}"
  if [[ -z "$DEVNET_POW_BIN" && -x "$HOME/.cargo/bin/devnet-pow" ]]; then
    DEVNET_POW_BIN="$HOME/.cargo/bin/devnet-pow"
  fi
  if [[ -n "$DEVNET_POW_BIN" ]]; then
    return
  fi

  need_cmd cargo
  echo "devnet-pow not found. Installing with: cargo install devnet-pow"
  cargo install devnet-pow

  DEVNET_POW_BIN="$(command -v devnet-pow || true)"
  if [[ -z "$DEVNET_POW_BIN" && -x "$HOME/.cargo/bin/devnet-pow" ]]; then
    DEVNET_POW_BIN="$HOME/.cargo/bin/devnet-pow"
  fi
  [[ -n "$DEVNET_POW_BIN" ]] || fail "devnet-pow install finished, but the binary was not found."
}

create_keypair() {
  local path="$1"
  node_eval "$path" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = process.argv[2];
const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function b58(buffer) {
  let n = BigInt('0x' + Buffer.from(buffer).toString('hex'));
  let out = '';
  while (n > 0n) {
    out = alphabet[Number(n % 58n)] + out;
    n /= 58n;
  }
  for (const byte of buffer) {
    if (byte === 0) out = alphabet[0] + out;
    else break;
  }
  return out || alphabet[0];
}
const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const seed = privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(-32);
const pub = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
fs.writeFileSync(path, JSON.stringify([...seed, ...pub]));
fs.chmodSync(path, 0o600);
console.log(b58(pub));
NODE
}

pubkey_from_keypair() {
  node_eval "$1" <<'NODE'
const fs = require('fs');
const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function b58(buffer) {
  let n = BigInt('0x' + Buffer.from(buffer).toString('hex'));
  let out = '';
  while (n > 0n) {
    out = alphabet[Number(n % 58n)] + out;
    n /= 58n;
  }
  for (const byte of buffer) {
    if (byte === 0) out = alphabet[0] + out;
    else break;
  }
  return out || alphabet[0];
}
const secret = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
console.log(b58(Buffer.from(secret.slice(32, 64))));
NODE
}

get_balance_lamports() {
  node_eval "$1" "$RPC_URL" <<'NODE'
const wallet = process.argv[2];
const rpcUrl = process.argv[3];
async function rpc(method, params) {
  const res = await fetch(rpcUrl, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params})
  });
  const json = await res.json();
  if (json.error) throw new Error(JSON.stringify(json.error));
  return json.result;
}
(async () => {
  const balance = await rpc('getBalance', [wallet, {commitment: 'confirmed'}]);
  console.log(balance.value);
})().catch(err => {
  console.error(err.message);
  process.exit(1);
});
NODE
}

try_airdrop_fee_float() {
  node_eval "$1" "$RPC_URL" "$AIRDROP_LAMPORTS" <<'NODE'
const wallet = process.argv[2];
const rpcUrl = process.argv[3];
const lamports = Number(process.argv[4]);
async function rpc(method, params) {
  const res = await fetch(rpcUrl, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params})
  });
  const json = await res.json();
  if (json.error) throw new Error(JSON.stringify(json.error));
  return json.result;
}
(async () => {
  const sig = await rpc('requestAirdrop', [wallet, lamports, {commitment: 'confirmed'}]);
  console.log(sig);
})().catch(err => {
  console.error(err.message);
  process.exit(1);
});
NODE
}

transfer_all_back() {
  node_eval "$1" "$2" "$RPC_URL" "$RESERVE_LAMPORTS" "$TRANSFER_FEE_LAMPORTS" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const keypairPath = process.argv[2];
const dest = process.argv[3];
const rpcUrl = process.argv[4];
const reserveLamports = Number(process.argv[5]);
const transferFeeLamports = Number(process.argv[6]);
const systemProgram = '11111111111111111111111111111111';
const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function b58encode(buffer) {
  let n = BigInt('0x' + Buffer.from(buffer).toString('hex'));
  let out = '';
  while (n > 0n) {
    out = alphabet[Number(n % 58n)] + out;
    n /= 58n;
  }
  for (const byte of buffer) {
    if (byte === 0) out = alphabet[0] + out;
    else break;
  }
  return out || alphabet[0];
}

function b58decode(str) {
  let n = 0n;
  for (const ch of str) {
    const val = alphabet.indexOf(ch);
    if (val < 0) throw new Error('invalid base58 character');
    n = n * 58n + BigInt(val);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  const body = n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex');
  let leading = 0;
  for (const ch of str) {
    if (ch === alphabet[0]) leading++;
    else break;
  }
  return Buffer.concat([Buffer.alloc(leading), body]);
}

function shortvec(n) {
  const out = [];
  while (true) {
    let elem = n & 0x7f;
    n >>= 7;
    if (n === 0) {
      out.push(elem);
      break;
    }
    out.push(elem | 0x80);
  }
  return Buffer.from(out);
}

function sol(lamports) {
  const value = (lamports / 1000000000).toFixed(9);
  return value.replace(/0+$/, '').replace(/\.$/, '.0');
}

async function rpc(method, params) {
  const res = await fetch(rpcUrl, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method, params})
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${JSON.stringify(json.error)}`);
  return json.result;
}

function makeTransferMessage(from, to, lamports, blockhash) {
  const fromKey = b58decode(from);
  const toKey = b58decode(to);
  const sysKey = b58decode(systemProgram);
  const blockhashKey = b58decode(blockhash);
  for (const [name, key] of [['from', fromKey], ['to', toKey], ['system', sysKey], ['blockhash', blockhashKey]]) {
    if (key.length !== 32) throw new Error(`${name} decoded to ${key.length} bytes`);
  }
  const data = Buffer.alloc(12);
  data.writeUInt32LE(2, 0);
  data.writeBigUInt64LE(BigInt(lamports), 4);
  return Buffer.concat([
    Buffer.from([1, 0, 1]),
    shortvec(3), fromKey, toKey, sysKey,
    blockhashKey,
    shortvec(1),
    Buffer.from([2]),
    shortvec(2), Buffer.from([0, 1]),
    shortvec(data.length), data,
  ]);
}

(async () => {
  const secret = JSON.parse(fs.readFileSync(keypairPath, 'utf8'));
  const seed = Buffer.from(secret.slice(0, 32));
  const pub = Buffer.from(secret.slice(32, 64));
  const from = b58encode(pub);
  const beforeTemp = await rpc('getBalance', [from, {commitment: 'confirmed'}]);
  const beforeDest = await rpc('getBalance', [dest, {commitment: 'confirmed'}]);
  const lamports = beforeTemp.value - reserveLamports - transferFeeLamports;

  if (lamports <= 0) {
    console.log(JSON.stringify({
      from,
      destination: dest,
      transferSignature: null,
      transferredLamports: 0,
      transferredSol: '0.0',
      tempBalanceLamports: beforeTemp.value,
      tempBalanceSol: sol(beforeTemp.value),
      destBalanceLamports: beforeDest.value,
      destBalanceSol: sol(beforeDest.value),
      reserveLamports,
      reserveSol: sol(reserveLamports)
    }, null, 2));
    return;
  }

  const latest = await rpc('getLatestBlockhash', [{commitment: 'confirmed'}]);
  const message = makeTransferMessage(from, dest, lamports, latest.value.blockhash);
  const pkcs8Prefix = Buffer.from('302e020100300506032b657004220420', 'hex');
  const privateKey = crypto.createPrivateKey({
    key: Buffer.concat([pkcs8Prefix, seed]),
    format: 'der',
    type: 'pkcs8'
  });
  const sig = crypto.sign(null, message, privateKey);
  const tx = Buffer.concat([shortvec(1), sig, message]).toString('base64');
  const signature = await rpc('sendTransaction', [tx, {
    encoding: 'base64',
    skipPreflight: false,
    preflightCommitment: 'confirmed',
    maxRetries: 5
  }]);

  for (let i = 0; i < 30; i++) {
    await new Promise(resolve => setTimeout(resolve, 1000));
    const status = await rpc('getSignatureStatuses', [[signature], {searchTransactionHistory: true}]);
    const value = status.value?.[0];
    if (value?.confirmationStatus === 'confirmed' || value?.confirmationStatus === 'finalized') break;
  }

  const afterTemp = await rpc('getBalance', [from, {commitment: 'confirmed'}]);
  const afterDest = await rpc('getBalance', [dest, {commitment: 'confirmed'}]);
  console.log(JSON.stringify({
    from,
    destination: dest,
    transferSignature: signature,
    transferredLamports: lamports,
    transferredSol: sol(lamports),
    tempBeforeLamports: beforeTemp.value,
    tempBeforeSol: sol(beforeTemp.value),
    tempAfterLamports: afterTemp.value,
    tempAfterSol: sol(afterTemp.value),
    destBeforeLamports: beforeDest.value,
    destBeforeSol: sol(beforeDest.value),
    destAfterLamports: afterDest.value,
    destAfterSol: sol(afterDest.value),
    reserveLamports,
    reserveSol: sol(reserveLamports),
    transferExplorer: `https://explorer.solana.com/tx/${signature}?cluster=devnet`,
    destinationExplorer: `https://explorer.solana.com/address/${dest}?cluster=devnet`
  }, null, 2));
})().catch(err => {
  console.error(err.message);
  process.exit(1);
});
NODE
}

wait_for_balance() {
  local wallet="$1"
  local min_lamports="$2"
  local balance="0"
  local i

  for ((i = 0; i < 30; i++)); do
    balance="$(get_balance_lamports "$wallet")"
    if [[ "$balance" -ge "$min_lamports" ]]; then
      printf '%s\n' "$balance"
      return 0
    fi
    sleep 1
  done

  printf '%s\n' "$balance"
  return 1
}

run_mining() {
  POW_STATUS=0
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout "$DURATION" "$DEVNET_POW_BIN" -u dev -k "$KEYPAIR_PATH" mine \
      -d "$DIFFICULTY" --reward "$REWARD" --no-infer -t "$TARGET_LAMPORTS"
    POW_STATUS=$?
  else
    "$DEVNET_POW_BIN" -u dev -k "$KEYPAIR_PATH" mine \
      -d "$DIFFICULTY" --reward "$REWARD" --no-infer -t "$TARGET_LAMPORTS" &
    local pow_pid=$!
    (
      sleep "$DURATION"
      kill "$pow_pid" 2>/dev/null
    ) &
    local timer_pid=$!
    wait "$pow_pid"
    POW_STATUS=$?
    kill "$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null
  fi
  set -e
}

install_devnet_pow_if_needed

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

if [[ -f "$KEYPAIR_PATH" ]]; then
  TEMP_WALLET="$(pubkey_from_keypair "$KEYPAIR_PATH")"
  echo "Reusing temporary keypair."
else
  TEMP_WALLET="$(create_keypair "$KEYPAIR_PATH")"
  echo "Created new temporary keypair."
fi
printf '%s\n' "$KEYPAIR_PATH" > "$LATEST_FILE"
chmod 600 "$KEYPAIR_PATH" "$LATEST_FILE" 2>/dev/null || true

echo "Destination wallet: $DEST_WALLET"
echo "Temporary wallet:  $TEMP_WALLET"
echo "Temporary keypair: $KEYPAIR_PATH"
echo "Duration:          $DURATION"
echo "RPC:               $RPC_URL"

BALANCE="$(get_balance_lamports "$TEMP_WALLET")"
if [[ "$BALANCE" -lt 10000 ]]; then
  echo "Temporary wallet needs fee float. Trying a small devnet RPC airdrop..."
  if ! try_airdrop_fee_float "$TEMP_WALLET"; then
    echo
    echo "Could not auto-fund the temporary wallet, likely due devnet faucet rate limits."
    echo "Send at least 0.011 devnet SOL to this temporary wallet:"
    echo "  $TEMP_WALLET"
    echo
    echo "Then rerun the same command:"
    echo "  $0 $DEST_WALLET $DURATION"
    exit 2
  fi
  if ! BALANCE="$(wait_for_balance "$TEMP_WALLET" 10000)"; then
    echo
    echo "Airdrop was requested, but the temporary wallet balance did not confirm in time."
    echo "Current temporary balance: $BALANCE lamports"
    echo "Send at least 0.011 devnet SOL to this temporary wallet:"
    echo "  $TEMP_WALLET"
    echo
    echo "Then rerun the same command:"
    echo "  $0 $DEST_WALLET $DURATION"
    exit 2
  fi
fi

echo "Temporary balance before mining: $BALANCE lamports"
echo "Starting devnet-pow..."
run_mining

if [[ "$POW_STATUS" -ne 0 && "$POW_STATUS" -ne 124 && "$POW_STATUS" -ne 130 && "$POW_STATUS" -ne 143 ]]; then
  echo "Warning: devnet-pow exited with status $POW_STATUS" >&2
fi

echo "Transferring mined balance back to destination..."
transfer_all_back "$KEYPAIR_PATH" "$DEST_WALLET"
