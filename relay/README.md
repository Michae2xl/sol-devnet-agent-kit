# sol-devnet-fee-relay

Cloudflare Worker that sponsors a one-shot **0.011 devnet SOL** fee float to a
fresh wallet so `sol-devnet-simple.sh` can start mining without anyone having
to babysit the public Solana faucet.

This exists because the public devnet faucet is constantly rate-limited and
the kit needs a non-zero balance on its temporary wallet to pay tx fees.

## How it works

```
POST /sponsor  { "wallet": "<base58 pubkey>" }
```

Worker:

1. Validates the pubkey.
2. Refuses if the destination already has any balance (only fresh wallets).
3. Refuses if that wallet was already sponsored once (KV dedup).
4. Refuses if the caller IP already used its daily allowance.
5. Signs and sends a transfer of `SPONSOR_LAMPORTS` from the relay hot wallet.
6. Returns the signature.

`GET /` returns the relay's public wallet so anyone can top it up.

## Deploy

```bash
cd relay
npm install
npx wrangler login

# 1. Create KV namespace and paste the returned id into wrangler.toml
npx wrangler kv namespace create RELAY_KV

# 2. Generate (or reuse) a devnet keypair to act as the hot wallet
solana-keygen new --no-bip39-passphrase -o relay-keypair.json

# 3. Upload the keypair contents as a secret (do NOT commit the file)
cat relay-keypair.json | npx wrangler secret put RELAY_KEYPAIR_JSON

# 4. Deploy
npx wrangler deploy
```

Top up the relay wallet (address printed at `GET /`) with a few devnet SOL
from `https://faucet.solana.com`. Each sponsorship costs ~0.011 SOL plus the
network fee, so 1 SOL covers ~90 fresh wallets.

## Use from the kit

Set the relay URL once and re-run the script. The script will try the
public faucet first and fall back to the relay automatically.

```bash
export SOL_DEVNET_RELAY_URL="https://sol-devnet-fee-relay.<your-subdomain>.workers.dev"
scripts/sol-devnet-simple.sh <YOUR_WALLET> 60s
```

## Safety notes

- Devnet only. Never point this at mainnet — anyone can request funds.
- The hot wallet holds devnet SOL only; treat the secret as throwaway.
- KV caps are best-effort, not bulletproof — keep `DAILY_IP_LIMIT` low.

## Operating a public/central relay

If you want to host one relay for everyone (instead of asking each user to
deploy their own), harden it before sharing the URL:

- Put **Cloudflare Turnstile** in front of `/sponsor` to block headless
  sybil floods. The verification token can be passed in the request body
  and validated in the Worker.
- Lower `DAILY_IP_LIMIT` (e.g. `2`) — most legit users only need one
  sponsorship per fresh machine.
- Tighten `SPONSOR_LAMPORTS` to the bare minimum the kit needs (`11000000`
  is already that floor; do not raise it).
- Monitor the relay wallet balance and refill from
  https://faucet.solana.com when it gets low. 1 SOL ≈ 90 sponsorships.
- Consider rotating the hot keypair if you see abuse and re-deploying with
  a fresh secret.
- If the relay starts costing real time/effort, switch the README back to
  "deploy your own" and disable the central one.
