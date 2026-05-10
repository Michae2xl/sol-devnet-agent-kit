import crypto from "node:crypto";

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const SYSTEM_PROGRAM = "11111111111111111111111111111111";

function b58encode(buffer) {
  let n = BigInt("0x" + Buffer.from(buffer).toString("hex"));
  let out = "";
  while (n > 0n) {
    out = ALPHABET[Number(n % 58n)] + out;
    n /= 58n;
  }
  for (const byte of buffer) {
    if (byte === 0) out = ALPHABET[0] + out;
    else break;
  }
  return out || ALPHABET[0];
}

function b58decode(str) {
  let n = 0n;
  for (const ch of str) {
    const val = ALPHABET.indexOf(ch);
    if (val < 0) throw new Error("invalid base58 character");
    n = n * 58n + BigInt(val);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = "0" + hex;
  const body = n === 0n ? Buffer.alloc(0) : Buffer.from(hex, "hex");
  let leading = 0;
  for (const ch of str) {
    if (ch === ALPHABET[0]) leading++;
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

function isValidPubkey(str) {
  try {
    return b58decode(str).length === 32;
  } catch {
    return false;
  }
}

async function rpc(rpcUrl, method, params) {
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${JSON.stringify(json.error)}`);
  return json.result;
}

function buildTransferTx({ fromPub, toPub, lamports, blockhash }) {
  const fromKey = b58decode(fromPub);
  const toKey = b58decode(toPub);
  const sysKey = b58decode(SYSTEM_PROGRAM);
  const blockhashKey = b58decode(blockhash);
  const data = Buffer.alloc(12);
  data.writeUInt32LE(2, 0);
  data.writeBigUInt64LE(BigInt(lamports), 4);
  return Buffer.concat([
    Buffer.from([1, 0, 1]),
    shortvec(3),
    fromKey,
    toKey,
    sysKey,
    blockhashKey,
    shortvec(1),
    Buffer.from([2]),
    shortvec(2),
    Buffer.from([0, 1]),
    shortvec(data.length),
    data,
  ]);
}

function loadRelayKeypair(env) {
  const raw = env.RELAY_KEYPAIR_JSON;
  if (!raw)
    throw new Error("relay not configured: missing RELAY_KEYPAIR_JSON secret");
  const arr = JSON.parse(raw);
  if (!Array.isArray(arr) || arr.length !== 64) {
    throw new Error("RELAY_KEYPAIR_JSON must be a 64-byte JSON array");
  }
  const seed = Buffer.from(arr.slice(0, 32));
  const pub = Buffer.from(arr.slice(32, 64));
  return { seed, pub, address: b58encode(pub) };
}

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
    },
  });
}

function todayKey() {
  return new Date().toISOString().slice(0, 10);
}

async function checkRateLimits(env, ip, wallet) {
  const ipKey = `ip:${ip}:${todayKey()}`;
  const walletKey = `wallet:${wallet}`;
  const dailyLimit = Number(env.DAILY_IP_LIMIT || 5);

  const alreadySponsored = await env.RELAY_KV.get(walletKey);
  if (alreadySponsored) {
    return { ok: false, reason: "wallet was already sponsored once" };
  }
  const ipCount = Number((await env.RELAY_KV.get(ipKey)) || 0);
  if (ipCount >= dailyLimit) {
    return {
      ok: false,
      reason: `daily limit of ${dailyLimit} sponsorships reached for this IP`,
    };
  }
  return { ok: true, ipKey, walletKey, ipCount };
}

async function sponsor({ env, dest, ipKey, walletKey, ipCount }) {
  const lamports = Number(env.SPONSOR_LAMPORTS || 11000000);
  const rpcUrl = env.RPC_URL || "https://api.devnet.solana.com";

  const balance = await rpc(rpcUrl, "getBalance", [
    dest,
    { commitment: "confirmed" },
  ]);
  const maxDestBalance = Number(env.MAX_DEST_BALANCE_LAMPORTS || 0);
  if (balance.value > maxDestBalance) {
    return jsonResponse(409, {
      error: "wallet already funded",
      balance: balance.value,
      hint: "relay only sponsors fresh wallets",
    });
  }

  const { seed, pub, address } = loadRelayKeypair(env);
  const latest = await rpc(rpcUrl, "getLatestBlockhash", [
    { commitment: "confirmed" },
  ]);
  const message = buildTransferTx({
    fromPub: address,
    toPub: dest,
    lamports,
    blockhash: latest.value.blockhash,
  });

  const pkcs8Prefix = Buffer.from("302e020100300506032b657004220420", "hex");
  const privateKey = crypto.createPrivateKey({
    key: Buffer.concat([pkcs8Prefix, seed]),
    format: "der",
    type: "pkcs8",
  });
  const signature = crypto.sign(null, message, privateKey);
  const tx = Buffer.concat([shortvec(1), signature, message]).toString(
    "base64",
  );
  const txid = await rpc(rpcUrl, "sendTransaction", [
    tx,
    {
      encoding: "base64",
      skipPreflight: false,
      preflightCommitment: "confirmed",
      maxRetries: 5,
    },
  ]);

  await env.RELAY_KV.put(walletKey, txid, { expirationTtl: 60 * 60 * 24 * 90 });
  await env.RELAY_KV.put(ipKey, String(ipCount + 1), {
    expirationTtl: 60 * 60 * 26,
  });

  return jsonResponse(200, {
    ok: true,
    sponsoredWallet: dest,
    lamports,
    sol: (lamports / 1e9).toString(),
    signature: txid,
    relay: address,
    explorer: `https://explorer.solana.com/tx/${txid}?cluster=devnet`,
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      let address = null;
      try {
        address = loadRelayKeypair(env).address;
      } catch {}
      return jsonResponse(200, {
        service: "sol-devnet-fee-relay",
        cluster: "devnet",
        relayWallet: address,
        sponsorLamports: Number(env.SPONSOR_LAMPORTS || 11000000),
        usage: 'POST /sponsor { "wallet": "<base58>" }',
      });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "POST, GET, OPTIONS",
          "access-control-allow-headers": "content-type",
        },
      });
    }

    if (request.method !== "POST" || url.pathname !== "/sponsor") {
      return jsonResponse(404, { error: "not found" });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse(400, { error: "body must be JSON" });
    }
    const dest = (body && body.wallet) || "";
    if (!isValidPubkey(dest)) {
      return jsonResponse(400, {
        error: "wallet is not a valid Solana pubkey",
      });
    }

    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const limits = await checkRateLimits(env, ip, dest);
    if (!limits.ok) {
      return jsonResponse(429, { error: limits.reason });
    }

    try {
      return await sponsor({
        env,
        dest,
        ipKey: limits.ipKey,
        walletKey: limits.walletKey,
        ipCount: limits.ipCount,
      });
    } catch (err) {
      return jsonResponse(500, { error: err.message });
    }
  },
};
