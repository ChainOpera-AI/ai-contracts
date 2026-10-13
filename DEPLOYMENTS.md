# Deployments

## BSC mainnet (chain 56)

### Subscription — deployed 2026-09-30

| | |
|---|---|
| **Proxy (use this one)** | [`0x6098162CE974Ca09814c93a2F31192a921B6e97c`](https://bscscan.com/address/0x6098162CE974Ca09814c93a2F31192a921B6e97c) |
| Implementation | [`0x9bC2A45c1816385036dD7C212742fb3d106139dE`](https://bscscan.com/address/0x9bC2A45c1816385036dD7C212742fb3d106139dE) |
| Owner (TimelockController) | `0xF08CC96a7877e7E9AD1A087F18fc9d222448B84c` |
| Receiver | `0x466B045700DC241828787adAd35cD868EC041898` |
| Fee collector | `0x979e3f3f387680c86EbEA3AB562E8b859bb2C2C1` |
| Terminator | `0x466B045700DC241828787adAd35cD868EC041898` |
| Importer | `0x466B045700DC241828787adAd35cD868EC041898` |

UUPS behind an ERC1967 proxy. Everything — backend, frontend, timelock proposals — talks to the
proxy; the implementation address only ever appears in an upgrade.

Upgraded 2026-10-13, from `0xBdb74EB6091d6ca40D46394076D98736a90AB7C5`. That version refused to
let an account in arrears cancel, and wrote whatever `importAccounts` was handed straight into
storage. Storage layout was compared slot by slot against the old one before the upgrade, and the
deployed code matches a local build byte for byte apart from UUPSUpgradeable's `__self`.

### Test deployment

`0x9Bd03E7B6790990CCD27A0078945D2cB0a3693F6`, owned by the same timelock, with every role on
`0x561097298c7BD8385Aa1a462b44d894106449fB1`. It runs
`0x7d414acFabA10acC0027Db0Da9ec4C00F1c9BfE4` — one version behind production, so the two are not
interchangeable. Check `getImplementation()` before reading anything into a test against it.

The timelock is the one that already owned the previous deployment. Its four roles are held
solely by `0x466B0457…1898`, and `minDelay` is 0 — which still means `schedule()` then
`execute()`, two transactions, for every owner call. `schedule()` on its own does nothing.

Deployed in two transactions because the deployer is an EIP-7702 delegated account and BSC
refuses gapped-nonce transactions from those; see `script/Deploy.s.sol` on `--slow`.

### Superseded

| | |
|---|---|
| Subscription (old, not upgradeable) | `0x781C4C14a60aff6db1daFE425C2529F28941544b` |
| TopUp | `0xE5fA05EF0cd9c35818B5bF305B31C1e375B48366` |

Account state was **not** migrated, so anyone subscribed on the old contract is still billed
there. Turn its switch off before pointing the backend at the new proxy, or both will take new
subscriptions. TopUp is unchanged and still in service.
