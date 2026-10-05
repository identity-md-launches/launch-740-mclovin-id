# McLovin.id (MCLOVIN)

A fixed-supply ERC-20 token for an IdentityMD custom token launch.

| Parameter | Value |
|-----------|-------|
| Contract | `McLovinId` (`src/McLovinId.sol`) |
| Name | `McLovin.id` |
| Symbol | `MCLOVIN` |
| Decimals | 18 |
| Supply (whole tokens) | 1,000,000,000 |
| Supply (minor units, `totalSupply()`) | `1000000000000000000000000000` (1e27) |
| Constructor arguments | none |
| Minted to | `msg.sender` of the creation, once, in the constructor |
| Compiler | solc 0.8.26, optimizer on (200 runs), EVM `cancun`, `bytecode_hash = "none"` |

## Behaviour

The token is OpenZeppelin v5.2.0 `ERC20` with a constructor that mints the whole supply to the
deployer. Nothing else is added:

- No owner, no roles, no `mint`, no `burn`, no `burnFrom`.
- No pause, blocklist, freeze, lock, or transfer toggle.
- No fee, tax, reflection, or burn on transfer. Every transfer and `transferFrom` moves exactly the
  amount requested and `totalSupply()` never changes after construction.
- No proxy, no `DELEGATECALL`, no `SELFDESTRUCT`, no `receive`/`fallback` (plain ether is rejected).
- No launch-address exemptions are needed because no transfer rule exists to exempt anyone from.

The supply therefore cannot grow after launch by anyone, including the deployer, and no privileged
hand can move or freeze a holder's balance. The only way a balance moves is `transfer` by the holder
or `transferFrom` within an allowance the holder granted.

## Layout

```
foundry.toml                    compiler pin, bytecode_hash = "none", remappings, ffi off
src/McLovinId.sol               the token
script/DeployMcLovinId.s.sol    deploy script; deploy() is the testable unit, run() wraps it in a broadcast
test/McLovinId.t.sol            token tests: metadata, supply, transfer/allowance success and failure, fuzz
test/DeployMcLovinId.t.sol      calls the script's deploy() directly
lib/forge-std                   forge-std v1.9.7, vendored as ordinary files (src/ and licences)
lib/openzeppelin-contracts      OpenZeppelin Contracts v5.2.0, only the ERC-20 subset the token imports
```

Dependencies are committed as plain files, not git submodules, so the project builds offline.

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables, use no `ffi` or filesystem access, and pass in any order and in
parallel. The fuzz tests cover supply conservation across arbitrary transfers, allowance enforcement,
and the impossibility of spending more than is held.

## Deployment

### Through the IdentityMD launch (expected path)

`ProjectFactory.launchCustom` deploys the token with CREATE2 and empty constructor arguments. The
factory is `msg.sender` of the creation, so it receives the full 1e27 minor units and then performs
the launch flows (swarm share to the MerkleDistributor, pool seed through the Uniswap v4 PoolManager,
remainder to `economics.remainderTo`). Because the token has no transfer rules, each flow arrives
exactly as sent and a trader can buy from and sell into the pool without restriction.

Manifest values for `token`:

- `contract`: `McLovinId`
- `name`: `McLovin.id`
- `symbol`: `MCLOVIN`
- `decimals`: `18`
- `constructorArgs`: `[]`
- `totalSupply`: `1000000000000000000000000000`

The pool, economics, and paired-currency entries come from the job and are not decided here.

### Direct deployment (not part of this assignment)

```
forge script script/DeployMcLovinId.s.sol:DeployMcLovinId --rpc-url <RPC> --broadcast <signer flags>
```

The signer of the broadcast receives the entire supply. This assignment does not hold keys, broadcast
transactions, or verify on an explorer; those are the deployer's responsibilities.

## Assumptions

- A single, fixed, pre-minted supply is the requested behaviour. No inflation, deflation, taxes, or
  governance hooks were asked for, so none were added.
- The deployer is trusted to hold and distribute the supply. For the launch that deployer is the
  factory, whose distribution rules are set by the launch, not by this token.
- OpenZeppelin v5 semantics apply: transfers to the zero address revert, `approve` to the zero address
  reverts, an allowance of `type(uint256).max` is not decremented, and errors are the custom
  ERC-6093 errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, and so on) rather than
  revert strings.
- The token has no ERC-2612 `permit`. Gasless approvals were not requested; adding them later would
  require a new deployment since the contract is not upgradeable.

## Operational responsibilities

- **Deployer / factory**: performs the creation, holds the supply until distribution, and is the
  only party whose actions matter for where the supply ends up. Nothing in the token can be changed
  after deployment, so there is no key to rotate and no admin to secure beyond the deployer's own
  account during the launch transaction.
- **Explorer verification**: `forge verify-contract` after deployment, with the same compiler
  settings as `foundry.toml`. Open item for the network's deployer.
- **Holders**: are responsible for the allowances they grant. The token does not cap or expire
  allowances. Grant exact amounts rather than `type(uint256).max` where practical.
- **Nobody** can pause, freeze, mint, or recover tokens. Tokens sent to the zero address are refused;
  tokens sent to a wrong non-zero address are unrecoverable.

## Security notes

Reviewed against the `eth-security` checklist. Applicable items:

- Access control: there are no privileged functions.
- Reentrancy: the token makes no external calls.
- Decimals: 18, fixed, and reported by `decimals()`.
- Integer math: only the OpenZeppelin ERC-20 arithmetic, under solc 0.8 checked math.
- Events: `Transfer` on the constructor mint and every transfer, `Approval` on every approval.
- Input validation: zero-address sender/receiver/spender revert via the OpenZeppelin implementation.
- Delegatecall / selfdestruct: absent from the runtime, checked by scanning the deployed bytecode.
- Proxies, oracles, swaps, EIP-712: not used.

Tools run: `forge build`, `forge test` (including 256-run fuzzing), `forge fmt --check`. Slither and
Mythril were not available in this task's environment and did not run. Tests passing is not an audit;
an independent adversarial review precedes release under the network's launch policy.
