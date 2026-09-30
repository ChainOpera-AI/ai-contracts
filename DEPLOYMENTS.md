# Deployments

## BSC mainnet (chain 56)

### Subscription — deployed 2026-09-30

| | |
|---|---|
| **Proxy (use this one)** | [`0x6098162CE974Ca09814c93a2F31192a921B6e97c`](https://bscscan.com/address/0x6098162CE974Ca09814c93a2F31192a921B6e97c) |
| Implementation | [`0xBdb74EB6091d6ca40D46394076D98736a90AB7C5`](https://bscscan.com/address/0xBdb74EB6091d6ca40D46394076D98736a90AB7C5) |
| Owner (TimelockController) | `0xF08CC96a7877e7E9AD1A087F18fc9d222448B84c` |
| Receiver | `0x466B045700DC241828787adAd35cD868EC041898` |
| Fee collector | `0x979e3f3f387680c86EbEA3AB562E8b859bb2C2C1` |
| Terminator | `0x466B045700DC241828787adAd35cD868EC041898` |
| Importer | `0x466B045700DC241828787adAd35cD868EC041898` |

UUPS behind an ERC1967 proxy. Everything — backend, frontend, timelock proposals — talks to the
proxy; the implementation address only ever appears in an upgrade.

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
