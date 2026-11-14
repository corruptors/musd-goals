# MUSD Goals — goal-based savings jars in MUSD on Mezo

**Mezo Buildathon (Wave 2) entry.** MUSD Goals turns "I should save" into a
concrete, on-chain habit: create a named savings goal denominated in MUSD,
deposit MUSD into its jar over time, watch progress toward the target, and
withdraw any amount back to yourself whenever you want. Your jar, your
funds, your keys — the contract can never move anyone else's money.

- **Track fit:** Track 2 (Access & Distribution) — a simpler interface for
  using and saving MUSD — with a Track 1 angle: savings jars are an on-ramp
  to productive MUSD capital (see Roadmap: sMUSD yield routing).
- **Chain:** Mezo Testnet, chain ID **31611**
- **Token:** official testnet **MUSD** `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503`

---

## The problem

MUSD is Bitcoin-backed money on Mezo, but holding a stablecoin in a wallet
doesn't help anyone build a savings habit. There is no simple, goal-shaped
way to say "this 250 MUSD is my emergency fund, that 100 MUSD is for a
laptop" — and generic wallet UIs give no progress feedback, no separation
between "spending money" and "saving money", and no commitment device.

## The solution

MUSD Goals is a single, auditable contract plus a lightweight web UI:

1. **Create a goal** — a name, a target amount in MUSD, an optional deadline.
2. **Deposit** MUSD into the jar (standard ERC-20 approve → deposit flow).
3. **Track progress** — the UI shows saved vs. target per goal; the contract
   emits `GoalAchieved` the moment a deposit first reaches the target.
4. **Withdraw freely** — any amount, any time, back to your own wallet only.
   Reaching a target never locks funds; this is a jar, not a vault trap.

## Architecture

```
                ┌────────────────────────────────────────────┐
                │              Web frontend                  │
                │  index.html / app.js / style.css           │
                │  config.js  (window.APP_CONFIG)            │
                └───────┬───────────────────────┬────────────┘
                        │ Real MUSD mode        │ Demo MUSD mode
                        ▼                       ▼
              ┌──────────────────┐    ┌──────────────────┐
              │  MUSDGoals       │    │  MUSDGoals       │
              │  (real instance) │    │  (demo instance) │
              └────────┬─────────┘    └────────┬─────────┘
                       │ token()               │ token()
                       ▼                       ▼
              ┌──────────────────┐    ┌──────────────────┐
              │ Official MUSD    │    │ DemoMUSD (dMUSD) │
              │ 0x1189…3Ac503    │    │ faucet ERC-20    │
              └──────────────────┘    └──────────────────┘
                     Mezo Testnet (chain 31611), gas in BTC
```

Contracts (`contracts/`, Solidity 0.8.28, **zero external dependencies** —
they build fully offline):

| Contract | What it does |
|---|---|
| `MUSDGoals.sol` | Per-user goal jars for any ERC-20 passed to its constructor. `createGoal`, `deposit`, `withdraw`, `getGoals`, `goalCount`. Goals are stored in a per-user array (`mapping(address => Goal[])`), so a goalId is only ever an index into the *caller's own* list. |
| `DemoMUSD.sol` | Clearly-labelled demo ERC-20 ("Demo MUSD (Testnet Demo Token)", `dMUSD`) with a public `faucet()` minting 1,000 dMUSD. **This is not MUSD** — see below. |

## How the MUSD / Mezo integration works

`MUSDGoals` is token-parameterised: the token address is an immutable set
at deployment. We deploy it **twice** on Mezo Testnet:

1. **Real MUSD instance** — wired to the official Mezo testnet MUSD
   contract `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503`. This is the real
   integration: anyone holding testnet MUSD (obtained by borrowing against
   test BTC in the Mezo testnet dApp) can create goals and deposit real
   MUSD today.
2. **Demo MUSD instance** — wired to `DemoMUSD (dMUSD)`, a mock token with
   a one-click faucet. Judges and new users can run the complete flow —
   faucet → create goal → deposit → GoalAchieved → withdraw — in under a
   minute, without first sourcing testnet MUSD.

The frontend has a **Real / Demo toggle** that switches between the two
instances. The demo token is labelled honestly everywhere (contract name,
UI badges, this README): dMUSD has no value, is not issued by Mezo, and is
never presented as MUSD.

Gas on Mezo Testnet is paid in BTC (18 decimals), per Mezo's EVM design
(solc 0.8.28, `evm_version = london`, optimizer 200 runs — the configuration
recommended in Mezo's developer docs).

## How to run

Prerequisites: [Foundry](https://getfoundry.sh) (`forge` / `cast`).

```bash
# 1. Run the test suite (18 tests, uses DemoMUSD as the token)
forge test

# 2. Deploy to Mezo Testnet
#    - Needs a deployer key file (see deploy.sh header) and test BTC from
#      the faucet: https://faucet.test.mezo.org
#    - If the deployer balance is 0, deploy.sh stops with instructions
#      and sends nothing.
./deploy.sh

# 3. Serve the frontend (any static server)
cd frontend && python3 -m http.server 8000
#    then open http://localhost:8000 and connect a wallet on Mezo Testnet
```

`deploy.sh` deploys all three contracts, seeds the demo instance with a
live example (deployer creates an "Emergency fund" goal, target 1,000
dMUSD, and deposits 250 dMUSD), writes `../DEPLOYED.txt`, and regenerates
`frontend/config.js` with the deployed addresses.

## Deployed addresses (Mezo Testnet, chain 31611)

> **Deployed 2026-11-14** by the deployer
> (`0x75027D3AE85A578A0D8468d7BF6917258e239037`) via `./deploy.sh`.
> Full record incl. all tx hashes: `../DEPLOYED.txt`. The demo instance is
> seeded with a live example: goal "Emergency fund" (target 1,000 dMUSD,
> 250 dMUSD saved).

| Contract | Address | Explorer |
|---|---|---|
| MUSDGoals (real MUSD) | `0xcaC0E2652b0aAa9299317A0E2Ef7af341487e9F0` | [explorer](https://explorer.test.mezo.org/address/0xcaC0E2652b0aAa9299317A0E2Ef7af341487e9F0) |
| DemoMUSD (dMUSD) | `0x68001316B71c5eCf5356D6DD213CF2B32996B2C5` | [explorer](https://explorer.test.mezo.org/address/0x68001316B71c5eCf5356D6DD213CF2B32996B2C5) |
| MUSDGoals (demo dMUSD) | `0x62C7FA26c6b69EF32Da51B6eEDCcB52c75531Aa3` | [explorer](https://explorer.test.mezo.org/address/0x62C7FA26c6b69EF32Da51B6eEDCcB52c75531Aa3) |
| Official testnet MUSD | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` | [explorer](https://explorer.test.mezo.org/address/0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503) |

## Security notes

- **Per-user isolation by construction.** There is no global goal registry
  and no function that accepts a user address for state changes. `deposit`
  and `withdraw` only ever touch `msg.sender`'s own goal array — another
  user's goals are not addressable, let alone reachable.
- **Withdrawals go to `msg.sender` only.** The destination is hard-coded;
  there is no recipient parameter to abuse.
- **No owner, no admin, no fees, no pause, no upgrade path.** Nobody —
  including the deployer — can move, freeze, or skim jar funds.
- **Reentrancy & CEI.** `deposit`/`withdraw` are `nonReentrant`
  (inline guard), update state before any external call, and interact last.
- **Safe ERC-20 handling.** Transfers check the call result and accept
  either a `true` return or empty returndata (USDT-style tokens), reverting
  otherwise.
- **Input validation.** Target must be > 0, name non-empty, deposit /
  withdraw amounts must be > 0 and ≤ saved, deadline must fit `uint64`.
- **Tests:** 18 Foundry tests in `test/MUSDGoals.t.sol` cover the happy
  paths, `GoalAchieved` emission, partial/full withdraw (including after
  the target is reached), per-user isolation, and all revert cases.
  This is hackathon code — it has not had a professional audit.

## Roadmap

1. **sMUSD yield routing** — route idle jar balances into Mezo's sMUSD
   savings vault (`0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16` on testnet)
   so goals earn yield while they fill, with per-goal share accounting.
2. **Shared & family goals** — opt-in multi-contributor jars with
   contributor tracking.
3. **Reminders & streaks** — deadline nudges and deposit streaks in the UI.
4. **Mezo mainnet** — deploy the same contracts on Mezo mainnet
   (chain 31612) wired to real MUSD once the testnet flow is validated.

## License

MIT. Built for the Mezo Buildathon, Wave 2 (November 2026).
