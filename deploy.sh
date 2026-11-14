#!/usr/bin/env bash
# deploy.sh — deploy MUSD Goals to Mezo Testnet (chain 31611).
#
# Safety properties:
#   * The deployer private key is read from the key file into a shell
#     variable only. It is NEVER printed, echoed, logged, or written to
#     any file by this script. Do not add `set -x` here.
#   * If the deployer holds 0 test BTC, the script exits non-zero BEFORE
#     sending anything and prints the faucet instructions.
#   * Testnet only. No other wallet or funds are ever used.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

RPC_URL="https://rpc.test.mezo.org"
EXPLORER="https://explorer.test.mezo.org"
CHAIN_ID=31611
REAL_MUSD="0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503"
FAUCET_URL="https://faucet.test.mezo.org"
DEPLOYED_TXT="$REPO_ROOT/../DEPLOYED.txt"

KEY_FILE="${DEPLOYER_KEY_FILE:-$REPO_ROOT/../keys/deployer.txt}"
if [[ ! -f "$KEY_FILE" ]]; then
  echo "ERROR: deployer key file not found: $KEY_FILE" >&2
  echo "Set DEPLOYER_KEY_FILE to its path and re-run." >&2
  exit 1
fi

# Extract the private key without ever printing it.
PRIVATE_KEY="$(grep -oE '0x[0-9a-fA-F]{64}' "$KEY_FILE" | head -n 1 || true)"
if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: no private key found in key file (format changed?)." >&2
  exit 1
fi
# Make sure the variable is cleaned up on exit.
trap 'unset PRIVATE_KEY' EXIT

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "Deployer: $DEPLOYER"
echo "Network:  Mezo Testnet (chain $CHAIN_ID) via $RPC_URL"

# ------------------------------------------------------------------
# Balance gate — stop cleanly if unfunded. Nothing is sent.
# ------------------------------------------------------------------
BALANCE_WEI="$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")"
echo "Deployer BTC balance: $BALANCE_WEI wei"

if [[ "$BALANCE_WEI" == "0" ]]; then
  cat <<EOF

====================================================================
BLOCKED: deployer has 0 test BTC — cannot pay gas, nothing was sent.
====================================================================
1. Open the Mezo testnet faucet:  $FAUCET_URL
2. Drip test BTC to the deployer: $DEPLOYER
3. Re-run:                        ./deploy.sh
====================================================================
EOF
  exit 2
fi

# ------------------------------------------------------------------
# Deploy: DemoMUSD, MUSDGoals(real MUSD), MUSDGoals(DemoMUSD)
# ------------------------------------------------------------------
echo "Building contracts..."
forge build

echo "Deploying (forge script --broadcast)..."
PRIVATE_KEY="$PRIVATE_KEY" forge script script/Deploy.s.sol:Deploy \
  --broadcast \
  --rpc-url mezo_testnet

BROADCAST_JSON="$REPO_ROOT/broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"
if [[ ! -f "$BROADCAST_JSON" ]]; then
  echo "ERROR: broadcast artefact not found at $BROADCAST_JSON" >&2
  exit 1
fi

# Extract addresses + tx hashes from the broadcast artefact.
eval "$(python3 - "$BROADCAST_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
demo = None
goals = []
txmap = {}
for tx in data.get("transactions", []):
    name = tx.get("contractName")
    addr = tx.get("contractAddress")
    if not addr:
        continue
    txmap[addr] = tx.get("hash", "")
    if name == "DemoMUSD" and demo is None:
        demo = addr
    elif name == "MUSDGoals":
        goals.append(addr)
assert demo and len(goals) >= 2, "expected DemoMUSD + 2x MUSDGoals deployments"
print(f"DEMO_MUSD_ADDR={demo}")
print(f"GOALS_REAL_ADDR={goals[0]}")
print(f"GOALS_DEMO_ADDR={goals[1]}")
print(f"DEMO_MUSD_TX={txmap.get(demo,'')}")
print(f"GOALS_REAL_TX={txmap.get(goals[0],'')}")
print(f"GOALS_DEMO_TX={txmap.get(goals[1],'')}")
PY
)"

echo "DemoMUSD:        $DEMO_MUSD_ADDR"
echo "MUSDGoals(real): $GOALS_REAL_ADDR"
echo "MUSDGoals(demo): $GOALS_DEMO_ADDR"

# ------------------------------------------------------------------
# Seed the demo instance so judges see a live example:
# faucet 1,000 dMUSD -> approve -> createGoal("Emergency fund", 1000)
# -> deposit 250 dMUSD, all from the deployer.
# ------------------------------------------------------------------
AMOUNT_TARGET="$(python3 -c 'print(1000 * 10**18)')"
AMOUNT_DEPOSIT="$(python3 -c 'print(250 * 10**18)')"

run_send() {
  # Prints only the transaction hash of a cast send.
  local to="$1"; shift
  cast send "$to" "$@" \
    --private-key "$PRIVATE_KEY" \
    --rpc-url "$RPC_URL" \
    --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])'
}

echo "Seeding demo instance..."
SEED_FAUCET_TX="$(run_send "$DEMO_MUSD_ADDR" 'faucet()')"
SEED_APPROVE_TX="$(run_send "$DEMO_MUSD_ADDR" 'approve(address,uint256)' "$GOALS_DEMO_ADDR" "$AMOUNT_TARGET")"
SEED_CREATE_TX="$(run_send "$GOALS_DEMO_ADDR" 'createGoal(string,uint256,uint256)' 'Emergency fund' "$AMOUNT_TARGET" 0)"
SEED_DEPOSIT_TX="$(run_send "$GOALS_DEMO_ADDR" 'deposit(uint256,uint256)' 0 "$AMOUNT_DEPOSIT")"
echo "Seeded: goal 0 'Emergency fund' with 250 dMUSD saved (target 1000)."

# ------------------------------------------------------------------
# Outputs: DEPLOYED.txt + frontend/config.js
# ------------------------------------------------------------------
cat > "$DEPLOYED_TXT" <<EOF
MUSD Goals — Mezo Testnet deployment
Chain ID: $CHAIN_ID
RPC: $RPC_URL
Explorer: $EXPLORER
Deployer: $DEPLOYER
Real MUSD (official): $REAL_MUSD
Explorer (token): $EXPLORER/address/$REAL_MUSD

DemoMUSD: $DEMO_MUSD_ADDR
  tx: $DEMO_MUSD_TX
  explorer: $EXPLORER/address/$DEMO_MUSD_ADDR

MUSDGoals (real MUSD): $GOALS_REAL_ADDR
  tx: $GOALS_REAL_TX
  explorer: $EXPLORER/address/$GOALS_REAL_ADDR

MUSDGoals (demo dMUSD): $GOALS_DEMO_ADDR
  tx: $GOALS_DEMO_TX
  explorer: $EXPLORER/address/$GOALS_DEMO_ADDR

Demo seed (on MUSDGoals demo instance, deployer account):
  faucet tx: $SEED_FAUCET_TX
  approve tx: $SEED_APPROVE_TX
  createGoal("Emergency fund", 1000 dMUSD, no deadline) tx: $SEED_CREATE_TX
  deposit(0, 250 dMUSD) tx: $SEED_DEPOSIT_TX
EOF

mkdir -p "$REPO_ROOT/frontend"
cat > "$REPO_ROOT/frontend/config.js" <<EOF
window.APP_CONFIG = { chainId: 31611, rpcUrl: "https://rpc.test.mezo.org", explorer: "https://explorer.test.mezo.org", realMusd: "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503", goalsReal: "$GOALS_REAL_ADDR", demoMusd: "$DEMO_MUSD_ADDR", goalsDemo: "$GOALS_DEMO_ADDR" };
EOF

echo ""
echo "Done. Wrote $DEPLOYED_TXT and frontend/config.js"
