# Deployments

## BSC mainnet (chain 56)

### Subscription — deployed 2026-09-30

| | |
|---|---|
| **Proxy (use this one)** | [`0x6098162CE974Ca09814c93a2F31192a921B6e97c`](https://bscscan.com/address/0x6098162CE974Ca09814c93a2F31192a921B6e97c) |
| Implementation | [`0x8975B2f36BfB76D2EE2e47Dc85238a5B03249A6b`](https://bscscan.com/address/0x8975B2f36BfB76D2EE2e47Dc85238a5B03249A6b) |
| Owner (TimelockController) | `0xF08CC96a7877e7E9AD1A087F18fc9d222448B84c` |
| Receiver | `0x466B045700DC241828787adAd35cD868EC041898` |
| Fee collector | zero address — `renew` / `renewBatch` are open to any caller |
| Terminator | `0x466B045700DC241828787adAd35cD868EC041898` |
| Importer | `0x466B045700DC241828787adAd35cD868EC041898` |

UUPS behind an ERC1967 proxy. Everything — backend, frontend, timelock proposals — talks to the
proxy; the implementation address only ever appears in an upgrade.

Upgraded 2026-10-13, from `0xBdb74EB6091d6ca40D46394076D98736a90AB7C5`. That version refused to
let an account in arrears cancel, and wrote whatever `importAccounts` was handed straight into
storage. Storage layout was compared slot by slot against the old one before the upgrade, and the
deployed code matches a local build byte for byte apart from UUPSUpgradeable's `__self`.

Upgraded again 2026-11-19, from `0x9bC2A45c1816385036dD7C212742fb3d106139dE` to the
implementation the test contract already ran, `0x8975B2f3…9A6b` (deployed by the test upgrade in
tx `0x0256769b…`; an implementation holds no state, so both proxies share it). This version lets
`setFeeCollector` take the zero address, and while the collector is zero `renew` and
`renewBatch` accept any caller. The timelock then set the collector to zero (block 134442807),
so the former hot key `0x979e3f3f…C2C1` is no longer required for billing — any address, cron
or keeper can trigger it. Checked after the fact on mainnet: configuration unchanged apart from
the implementation and the collector, 59 sampled accounts identical across twelve getters, and
a stranger's `renew` passes the gate (it then fails only on the account's own allowance).

The COAI price pool has since been moved to `0x778121B464151FE5d931587c457E48FcAaA0dc7A`
(PancakeV3, observation cardinality grown to 8000 so the 30-minute TWAP has enough history).

The timelock is the one that already owned the previous deployment. Its four roles are held
solely by `0x466B0457…1898`, and `minDelay` is 0 — which still means `schedule()` then
`execute()`, two transactions, for every owner call. `schedule()` on its own does nothing.

Deployed in two transactions because the deployer is an EIP-7702 delegated account and BSC
refuses gapped-nonce transactions from those; see `script/Deploy.s.sol` on `--slow`.

### Test deployment

| | |
|---|---|
| Subscription proxy | `0x9Bd03E7B6790990CCD27A0078945D2cB0a3693F6` |
| Implementation | `0x8975B2f36BfB76D2EE2e47Dc85238a5B03249A6b` |
| TopUp | `0x1A4c39D815c56c5dAce5a2DDe4D3C7815c8618aa` |
| Owner of both (TimelockController) | `0xcF5d9bD4756cD8cD63cc31B1019E307E667AF3aB` |

The timelock is the test deployment's own: `minDelay` 0 and all four roles on
`0x561097298c7BD8385Aa1a462b44d894106449fB1`, which is also the receiver, fee collector,
terminator and importer, so one key drives everything and nothing here can reach production.
Prices and periods are set for debugging, not to match production (GO_MONTH costs 499 units
on a 60-second period), and are meant to stay that way.

Upgraded 2026-11-19 from `0x9bC2A45c1816385036dD7C212742fb3d106139dE` to
`0x8975B2f3…9A6b`, a few hours before production took the same implementation, so the two run
the same code again. The upgrade itself changed no state; the timelock then set the fee
collector to the zero address (block 134437104), so here too anyone may call `renew` and
`renewBatch` — checked with an `eth_call` from an unrelated address against the one account in
arrears. Done with `script/upgrade.sh`; the landed code matched the local build byte for byte
apart from UUPSUpgradeable's `__self`.

### Upgrading

```
PROXY=<proxy> TIMELOCK=<its owner> ACCOUNT=<cast keystore> script/upgrade.sh
```

deploys the implementation from the checkout, checks the runtime code that landed against the
local build, then schedules and executes `upgradeTo` through the timelock and reads the proxy
back. Nothing is sent until the proxy's owner and the signer's roles have been confirmed. `IMPL`
skips the deploy, which is how production runs it: the deployer puts the implementation up,
the timelock's proposer (`0x466B…1898`) runs the rest.

### Superseded

| | |
|---|---|
| Subscription (old, not upgradeable) | `0x781C4C14a60aff6db1daFE425C2529F28941544b` |
| TopUp | `0xE5fA05EF0cd9c35818B5bF305B31C1e375B48366` |

Account state was **not** migrated, so anyone subscribed on the old contract is still billed
there. Turn its switch off before pointing the backend at the new proxy, or both will take new
subscriptions. TopUp is unchanged and still in service.
