# Sol Devnet Agent Kit

Agent-friendly Solana devnet proof-of-work faucet workflow. This is only for
devnet/test SOL and has no monetary value.

## What It Does

- Creates or reuses a temporary devnet keypair.
- Mines devnet SOL with `devnet-pow` for a fixed duration.
- Transfers mined devnet SOL back to the destination wallet.
- Keeps `0.01` devnet SOL in the temporary wallet for future fees.
- Never needs a private key, seed phrase, browser cookie, GitHub session, or
  faucet auth token.

## Requirements

- Bash
- Node.js 18+
- Rust/Cargo
- Network access to Solana devnet RPC

If `devnet-pow` is missing, `scripts/sol-devnet-simple.sh` will try to install it
with:

```bash
cargo install devnet-pow
```

## Quick Use

```bash
git clone https://github.com/Michae2xl/sol-devnet-agent-kit.git
cd sol-devnet-agent-kit
chmod +x scripts/*.sh
scripts/sol-devnet-simple.sh YOUR_DEVNET_WALLET 60s
```

Durations can be `60s`, `120s`, `5m`, `1h`, or a plain number of seconds.

## Install As A Codex Skill

```bash
git clone https://github.com/Michae2xl/sol-devnet-agent-kit.git ~/.codex/skills/sol-devnet
chmod +x ~/.codex/skills/sol-devnet/scripts/*.sh
```

After that, ask Codex for `sol-devnet` with a destination devnet wallet and a
duration.

## Use With Other Agents

Point the agent at this repository and tell it to read `AGENTS.md`. The shortest
safe instruction is:

```text
Use scripts/sol-devnet-simple.sh. Ask only for my public Solana devnet wallet
and duration. Never ask for private keys or auth tokens.
```

## Local State

The script stores its temporary keypair in:

```text
~/.sol-devnet-miner/current-keypair.json
```

Do not commit, upload, or share that directory.

## Test

Syntax check:

```bash
bash -n scripts/sol-devnet-simple.sh
bash -n scripts/sol-devnet-pow.sh
```

Help output:

```bash
scripts/sol-devnet-simple.sh --help
```

Short real run:

```bash
scripts/sol-devnet-simple.sh YOUR_DEVNET_WALLET 10s
```
