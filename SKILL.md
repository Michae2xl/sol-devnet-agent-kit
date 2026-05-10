---
name: sol-devnet
description: Solana devnet research workflow for safely obtaining test SOL via the official proof-of-work faucet. Use when the user says "sol-devnet", asks to run Solana devnet PoW faucet mining, wants a temporary keypair funded/mined for a fixed time, or wants to send mined devnet SOL back to their wallet. Defaults to 60 seconds unless the user specifies another duration.
---

# Sol Devnet

## Purpose

Run Solana devnet proof-of-work faucet tests for authorized development/research. This is only for devnet/test SOL with no monetary value. Do not bypass faucet login, captcha, GitHub checks, or rate limits.

## Default Workflow

When the user says `sol-devnet`, parse:

- Destination wallet: required Solana devnet public key.
- Duration: default `60s`; accept `120s`, `5m`, or a plain number of seconds.
- Difficulty/reward: default `-d 3 --reward 0.02`, matching the learned working path.
- Temporary keypair: reuse the latest saved keypair by default. Create a new one only if the user explicitly asks.

Use the bundled script:

```bash
scripts/sol-devnet-pow.sh <DEST_WALLET> [DURATION]
```

For a shareable, beginner-friendly script where the user only passes their
devnet wallet and the mining duration, use:

```bash
scripts/sol-devnet-simple.sh <DEST_WALLET> <DURATION>
```

Example:

```bash
scripts/sol-devnet-simple.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 5m
```

Examples:

```bash
scripts/sol-devnet-pow.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8
scripts/sol-devnet-pow.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 180s
scripts/sol-devnet-pow.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 5m
scripts/sol-devnet-pow.sh 8HXNYtEzNwhGFjZbr5rSY6iDLVH6cUc2iKnvK3mf4df8 60s --fresh
```

## Operational Rules

1. Use a temporary keypair, not the user's private key.
2. Never ask for seed phrases, private keys, browser cookies, GitHub sessions, or faucet auth tokens.
3. Preserve and reuse the latest temporary keypair unless the user explicitly asks for a fresh keypair or deletion.
4. Keep `0.01` devnet SOL reserved in the temporary keypair for future fees; transfer only the excess back to the destination wallet.
5. If the temporary keypair has no devnet SOL, the script may try a small normal RPC airdrop. If rate-limited, ask the user to send at least `0.011` devnet SOL to the printed temporary address, then rerun the same command.
6. Run with a bounded duration using `timeout`; default is 60 seconds.
7. After mining, transfer the available temporary-wallet balance above the retained reserve back to the user's destination wallet.
8. Report the mined amount, transfer signature, final destination balance, retained temporary balance, and explorer links.

## Learned Working Path

The observed successful path was:

```bash
cargo install devnet-pow
devnet-pow -u dev -k /tmp/devnet-pow-payer.json mine -d 3 --reward 0.02 --no-infer -t 5000000000
```

During the test on a 4 vCPU AMD EPYC VM, 60 seconds produced about `0.58` devnet SOL gross and `0.55387448` net after fees/rent, then the temporary balance was transferred back to the destination wallet.

## Tooling

If `devnet-pow` is missing, install it with:

```bash
cargo install devnet-pow
```

Network access is required for crate installation and Solana devnet RPC. Request escalation if the sandbox blocks network access.
