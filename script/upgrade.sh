#!/usr/bin/env bash
# Upgrade a Subscription proxy to the implementation built from this checkout.
#
#   PROXY=0x... TIMELOCK=0x... ACCOUNT=deployer script/upgrade.sh
#
# Deploys the implementation, checks the code that landed against the local build byte for
# byte, then schedules and executes upgradeTo through the proxy's TimelockController, and
# reads the proxy back. Nothing is sent until the proxy's owner and the signer's roles have
# been checked. One password prompt: the password goes to a file only this process can read,
# never onto a command line.
#
#   PROXY     the ERC1967 proxy to upgrade
#   TIMELOCK  its owner; checked against getOwner() first
#   ACCOUNT   keystore name (cast wallet list) that deploys the implementation and holds
#             PROPOSER and EXECUTOR on the timelock
#   IMPL      optional: an implementation that already landed, to skip the deploy. This is
#             how the two halves run under different keys -- deploy with one, then rerun
#             with IMPL set and ACCOUNT the proposer.
#   RPC       optional, default bsc (the alias in foundry.toml)
#   SALT      optional timelock salt; default derives from the implementation address
#   FROM      anvil only: sign as this address with --unlocked instead of a keystore
#
# Transactions go out one at a time, so an EIP-7702 delegated signer is fine here.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${PROXY:?set PROXY}" "${TIMELOCK:?set TIMELOCK}"
RPC=${RPC:-bsc}
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
ART=out/subscription_fee_collector.sol/Subscription.json

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# forge prints lint notes for the whole repo on every build; keep them for a failure only.
quietly() { "$@" > "$TMP/out" 2> "$TMP/err" || { cat "$TMP/err" "$TMP/out" >&2; return 1; }; }

step() { printf '\n== %s\n' "$*"; }
addr() { cast to-check-sum-address "$1"; }
call() { cast call "$@" --rpc-url "$RPC"; }
# Prints "status txhash" from a cast send --json receipt and fails on a reverted transaction.
receipt() {
    python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
ok = int(r["status"], 16) == 1
print(("ok  " if ok else "REVERTED  ") + r["transactionHash"])
sys.exit(0 if ok else 1)'
}

if [[ -n "${FROM:-}" ]]; then
    SIGN=(--from "$FROM" --unlocked)
    SIGNER=$(addr "$FROM")
else
    : "${ACCOUNT:?set ACCOUNT (a cast keystore name) or FROM (anvil)}"
    read -rs -p "keystore password for $ACCOUNT: " PW; echo
    (umask 077; printf '%s' "$PW" > "$TMP/pw")
    unset PW
    SIGN=(--account "$ACCOUNT" --password-file "$TMP/pw")
    SIGNER=$(cast wallet address "${SIGN[@]}")
fi

step "preflight on $RPC"
owner=$(call "$PROXY" 'getOwner()(address)')
[[ $(addr "$owner") == $(addr "$TIMELOCK") ]] || { echo "proxy owner is $owner, not $TIMELOCK"; exit 1; }
for role in PROPOSER EXECUTOR; do
    hash=$(cast keccak "${role}_ROLE")
    if [[ $(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$hash" "$SIGNER") != true ]]; then
        # An executor of address(0) means anyone may execute.
        [[ $role == EXECUTOR && $(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$hash" 0x0000000000000000000000000000000000000000) == true ]] \
            || { echo "$SIGNER does not hold $role on $TIMELOCK"; exit 1; }
    fi
done
DELAY=$(call "$TIMELOCK" 'getMinDelay()(uint256)')
CURRENT=$(call "$PROXY" 'getImplementation()(address)')
echo "signer      $SIGNER"
echo "proxy       $PROXY  (implementation $CURRENT)"
echo "timelock    $TIMELOCK  (minDelay $DELAY)"

step "build"
quietly forge build
LOCAL_SIZE=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["deployedBytecode"]["object"][2:])//2)' "$ART")
echo "Subscription runtime $LOCAL_SIZE bytes"

if [[ -z "${IMPL:-}" ]]; then
    step "deploy the implementation"
    quietly forge create contracts/subscription_fee_collector.sol:Subscription --rpc-url "$RPC" "${SIGN[@]}" --broadcast --json
    IMPL=$(python3 -c '
import json, sys
s = open(sys.argv[1]).read()
d = json.loads(s[s.index("{"):])
print(d["deployedTo"], d["transactionHash"])' "$TMP/out")
    set -- $IMPL; IMPL=$1
    echo "ok  $2"
fi
IMPL=$(addr "$IMPL")
echo "implementation $IMPL"

step "compare the code that landed with the local build"
python3 - "$ART" "$(cast code "$IMPL" --rpc-url "$RPC")" <<'PY'
import json, sys
art = json.load(open(sys.argv[1]))["deployedBytecode"]
local = art["object"][2:].lower()
code = bytearray.fromhex(sys.argv[2][2:])
refs = [span for spans in art.get("immutableReferences", {}).values() for span in spans]
for s in refs:
    code[s["start"]:s["start"] + s["length"]] = bytes(s["length"])
if len(code) * 2 != len(local):
    sys.exit("on-chain code is %d bytes, local build %d" % (len(code), len(local) // 2))
if code.hex() != local:
    sys.exit("on-chain code differs from the local build")
print("identical apart from %d immutable slot(s) holding the contract's own address" % len(refs))
PY
[[ $(addr "$IMPL") != $(addr "$CURRENT") ]] || { echo "proxy already runs $IMPL"; exit 0; }

DATA=$(cast calldata 'upgradeTo(address)' "$IMPL")
SALT=${SALT:-$(cast keccak "upgradeTo $IMPL")}
ID=$(call "$TIMELOCK" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' "$PROXY" 0 "$DATA" "$ZERO" "$SALT")

step "schedule upgradeTo($IMPL) on the timelock"
echo "operation $ID"
if [[ $(call "$TIMELOCK" 'isOperation(bytes32)(bool)' "$ID") == true ]]; then
    echo "already scheduled"
else
    cast send "$TIMELOCK" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
        "$PROXY" 0 "$DATA" "$ZERO" "$SALT" "$DELAY" --rpc-url "$RPC" "${SIGN[@]}" --json | receipt
fi
echo "after schedule the proxy still runs $(call "$PROXY" 'getImplementation()(address)')"

step "execute"
until [[ $(call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$ID") == true ]]; do
    echo "waiting for the delay to pass..."; sleep 10
done
cast send "$TIMELOCK" 'execute(address,uint256,bytes,bytes32,bytes32)' \
    "$PROXY" 0 "$DATA" "$ZERO" "$SALT" --rpc-url "$RPC" "${SIGN[@]}" --json | receipt

step "verify"
NOW=$(call "$PROXY" 'getImplementation()(address)')
[[ $(addr "$NOW") == "$IMPL" ]] || { echo "proxy reports $NOW"; exit 1; }
echo "proxy $PROXY now runs $IMPL"
echo "owner $(call "$PROXY" 'getOwner()(address)')  feeCollector $(call "$PROXY" 'getFeeCollector()(address)')  switch $(call "$PROXY" 'getSwitch()(bool)')"
