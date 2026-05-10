#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sol-devnet-pow.sh <DEST_WALLET> [DURATION] [--keypair PATH] [--fresh] [--difficulty N] [--reward SOL]

Defaults:
  DURATION=60s
  --difficulty 3
  --reward 0.02
  --target-lamports 5000000000
  fee reserve kept in the temporary keypair: 0.01 devnet SOL

By default, the script reuses the latest temporary keypair so it does not need
to be funded again every run. Use --fresh only when you explicitly want a new
temporary keypair.

If the temporary keypair is unfunded and RPC airdrop is rate-limited, fund the printed
temporary address with a small amount of devnet SOL, then rerun the same command.
USAGE
}

DEST_WALLET=""
DURATION="60s"
KEYPAIR_PATH=""
FRESH_KEYPAIR="0"
DIFFICULTY="3"
REWARD="0.02"
TARGET_LAMPORTS="5000000000"
RESERVE_LAMPORTS="${SOL_DEVNET_RESERVE_LAMPORTS:-10000000}"
AIRDROP_LAMPORTS="${SOL_DEVNET_AIRDROP_LAMPORTS:-11000000}"
TRANSFER_FEE_LAMPORTS="${SOL_DEVNET_TRANSFER_FEE_LAMPORTS:-5000}"
RPC_URL="${SOL_DEVNET_RPC_URL:-https://api.devnet.solana.com}"
STATE_DIR="${SOL_DEVNET_STATE_DIR:-/root/agents/.sol-devnet}"
LATEST_FILE="$STATE_DIR/latest-keypair"
DEFAULT_KEYPAIR="$STATE_DIR/current-keypair.json"
LEGACY_LATEST_FILE="/tmp/sol-devnet-pow-latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --keypair)
      KEYPAIR_PATH="${2:-}"
      shift 2
      ;;
    --fresh)
      FRESH_KEYPAIR="1"
      shift
      ;;
    --difficulty)
      DIFFICULTY="${2:-}"
      shift 2
      ;;
    --reward)
      REWARD="${2:-}"
      shift 2
      ;;
    --target-lamports)
      TARGET_LAMPORTS="${2:-}"
      shift 2
      ;;
    --rpc)
      RPC_URL="${2:-}"
      shift 2
      ;;
    *)
      if [[ -z "$DEST_WALLET" ]]; then
        DEST_WALLET="$1"
      elif [[ "$DURATION" == "60s" ]]; then
        DURATION="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$DEST_WALLET" ]]; then
  echo "Missing destination wallet." >&2
  usage
  exit 1
fi

if [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  DURATION="${DURATION}s"
fi

DEVNET_POW_BIN="${DEVNET_POW_BIN:-$(command -v devnet-pow || true)}"
if [[ -z "$DEVNET_POW_BIN" && -x /root/.cargo/bin/devnet-pow ]]; then
  DEVNET_POW_BIN="/root/.cargo/bin/devnet-pow"
fi
if [[ -z "$DEVNET_POW_BIN" ]]; then
  echo "devnet-pow is not installed. Run: cargo install devnet-pow" >&2
  exit 1
fi

node_eval() {
  node - "$@"
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
  while (n > 0n) { out = alphabet[Number(n % 58n)] + out; n /= 58n; }
  for (const byte of buffer) { if (byte === 0) out = alphabet[0] + out; else break; }
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

latest_keypair_path() {
  local candidate=""
  if [[ -f "$LATEST_FILE" ]]; then
    read -r candidate < "$LATEST_FILE" || true
  fi
  if [[ -z "$candidate" && -f "$LEGACY_LATEST_FILE" ]]; then
    read -r candidate < "$LEGACY_LATEST_FILE" || true
  fi
  if [[ -z "$candidate" && -f "$DEFAULT_KEYPAIR" ]]; then
    candidate="$DEFAULT_KEYPAIR"
  fi
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
  fi
}

record_latest_keypair() {
  local path="$1"
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$path" > "$LATEST_FILE"
  chmod 600 "$path" 2>/dev/null || true
}

pubkey_from_keypair() {
  node_eval "$1" <<'NODE'
const fs = require('fs');
const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function b58(buffer) {
  let n = BigInt('0x' + Buffer.from(buffer).toString('hex'));
  let out = '';
  while (n > 0n) { out = alphabet[Number(n % 58n)] + out; n /= 58n; }
  for (const byte of buffer) { if (byte === 0) out = alphabet[0] + out; else break; }
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
    headers: {'content-type':'application/json'},
    body: JSON.stringify({jsonrpc:'2.0', id:1, method, params})
  });
  const json = await res.json();
  if (json.error) throw new Error(JSON.stringify(json.error));
  return json.result;
}
(async () => {
  const balance = await rpc('getBalance', [wallet, {commitment:'confirmed'}]);
  console.log(balance.value);
})().catch(err => { console.error(err.message); process.exit(1); });
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
    headers: {'content-type':'application/json'},
    body: JSON.stringify({jsonrpc:'2.0', id:1, method, params})
  });
  const json = await res.json();
  if (json.error) throw new Error(JSON.stringify(json.error));
  return json.result;
}
(async () => {
  const sig = await rpc('requestAirdrop', [wallet, lamports, {commitment:'confirmed'}]);
  console.log(sig);
})().catch(err => { console.error(err.message); process.exit(1); });
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
  while (n > 0n) { out = alphabet[Number(n % 58n)] + out; n /= 58n; }
  for (const byte of buffer) { if (byte === 0) out = alphabet[0] + out; else break; }
  return out || alphabet[0];
}
function b58decode(str) {
  let n = 0n;
  for (const ch of str) {
    const val = alphabet.indexOf(ch);
    if (val < 0) throw new Error('invalid base58 char');
    n = n * 58n + BigInt(val);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  const body = n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex');
  let leading = 0;
  for (const ch of str) { if (ch === alphabet[0]) leading++; else break; }
  return Buffer.concat([Buffer.alloc(leading), body]);
}
function shortvec(n) {
  const out = [];
  while (true) {
    let elem = n & 0x7f;
    n >>= 7;
    if (n === 0) { out.push(elem); break; }
    out.push(elem | 0x80);
  }
  return Buffer.from(out);
}
async function rpc(method, params) {
  const res = await fetch(rpcUrl, {
    method:'POST',
    headers:{'content-type':'application/json'},
    body: JSON.stringify({jsonrpc:'2.0', id:1, method, params})
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
  const beforeTemp = await rpc('getBalance', [from, {commitment:'confirmed'}]);
  const beforeDest = await rpc('getBalance', [dest, {commitment:'confirmed'}]);
  const lamports = beforeTemp.value - reserveLamports - transferFeeLamports;
  if (lamports <= 0) {
    console.log(JSON.stringify({
      from,
      transferredLamports: 0,
      tempBalance: beforeTemp.value,
      destBalance: beforeDest.value,
      reserveLamports
    }));
    return;
  }
  const latest = await rpc('getLatestBlockhash', [{commitment:'confirmed'}]);
  const message = makeTransferMessage(from, dest, lamports, latest.value.blockhash);
  const pkcs8Prefix = Buffer.from('302e020100300506032b657004220420', 'hex');
  const privateKey = crypto.createPrivateKey({ key: Buffer.concat([pkcs8Prefix, seed]), format: 'der', type: 'pkcs8' });
  const sig = crypto.sign(null, message, privateKey);
  const tx = Buffer.concat([shortvec(1), sig, message]).toString('base64');
  const signature = await rpc('sendTransaction', [tx, {encoding:'base64', skipPreflight:false, preflightCommitment:'confirmed', maxRetries:5}]);
  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 1000));
    const status = await rpc('getSignatureStatuses', [[signature], {searchTransactionHistory:true}]);
    const value = status.value?.[0];
    if (value?.confirmationStatus === 'confirmed' || value?.confirmationStatus === 'finalized') break;
  }
  const afterTemp = await rpc('getBalance', [from, {commitment:'confirmed'}]);
  const afterDest = await rpc('getBalance', [dest, {commitment:'confirmed'}]);
  console.log(JSON.stringify({
    from,
    destination: dest,
    transferSignature: signature,
    transferredLamports: lamports,
    tempBeforeLamports: beforeTemp.value,
    tempAfterLamports: afterTemp.value,
    destBeforeLamports: beforeDest.value,
    destAfterLamports: afterDest.value,
    reserveLamports
  }, null, 2));
})().catch(err => { console.error(err.message); process.exit(1); });
NODE
}

if [[ -z "$KEYPAIR_PATH" && "$FRESH_KEYPAIR" == "0" ]]; then
  KEYPAIR_PATH="$(latest_keypair_path || true)"
fi

if [[ -z "$KEYPAIR_PATH" ]]; then
  mkdir -p "$STATE_DIR"
  if [[ "$FRESH_KEYPAIR" == "1" ]]; then
    KEYPAIR_PATH="$STATE_DIR/keypair-$(date +%Y%m%d-%H%M%S).json"
  else
    KEYPAIR_PATH="$DEFAULT_KEYPAIR"
  fi
  TEMP_WALLET="$(create_keypair "$KEYPAIR_PATH")"
  echo "Created new temporary keypair."
else
  TEMP_WALLET="$(pubkey_from_keypair "$KEYPAIR_PATH")"
  echo "Reusing temporary keypair."
fi
record_latest_keypair "$KEYPAIR_PATH"

echo "Destination wallet: $DEST_WALLET"
echo "Temporary keypair: $KEYPAIR_PATH"
echo "Temporary wallet:  $TEMP_WALLET"
echo "Duration:          $DURATION"
echo "Retained reserve:  $RESERVE_LAMPORTS lamports"

BALANCE="$(get_balance_lamports "$TEMP_WALLET")"
if [[ "$BALANCE" -lt 10000 ]]; then
  echo "Temporary wallet is under fee reserve. Trying a small official RPC airdrop..."
  if ! try_airdrop_fee_float "$TEMP_WALLET"; then
    echo
    echo "Could not auto-fund the temporary wallet, likely due RPC faucet rate limit."
    echo "Send at least 0.011 devnet SOL to:"
    echo "  $TEMP_WALLET"
    echo
    echo "Then rerun:"
    echo "  $0 $DEST_WALLET $DURATION --keypair $KEYPAIR_PATH --difficulty $DIFFICULTY --reward $REWARD"
    echo
    echo "This keypair was preserved and will be reused automatically by the next sol-devnet run."
    exit 2
  fi
fi

echo "Starting devnet-pow..."
set +e
timeout "$DURATION" "$DEVNET_POW_BIN" -u dev -k "$KEYPAIR_PATH" mine \
  -d "$DIFFICULTY" --reward "$REWARD" --no-infer -t "$TARGET_LAMPORTS"
POW_STATUS=$?
set -e
if [[ "$POW_STATUS" -ne 0 && "$POW_STATUS" -ne 124 ]]; then
  echo "devnet-pow exited with status $POW_STATUS" >&2
fi

echo "Transferring temporary wallet balance back to destination..."
transfer_all_back "$KEYPAIR_PATH" "$DEST_WALLET"
