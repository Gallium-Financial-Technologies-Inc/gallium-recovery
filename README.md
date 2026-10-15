# gallium-recovery

Public recovery tool for a Gallium 2-of-3 Bitcoin escrow. It spends the escrow in Bitcoin Core using the bank key backup and the borrower key backup. Those are the files downloaded when each key was created. Gallium does not need to be running, and this tool does not send the private keys anywhere.

The Gallium app pins an exact commit and SHA-256 of `gallium-recover.sh`. It downloads that file and saves it only when the checksum matches. Do not run a copy taken from the moving `main` branch tip unless you have checked that same checksum.

## Run

```bash
chmod +x gallium-recover.sh
./gallium-recover.sh
```

The same two key backups work for every loan. The script asks for four things:

1. Path to the bank key backup file, for example `~/Downloads/gallium-bank-key-LN-1.txt`
2. Path to the borrower key backup file
3. The loan index shown on that loan
4. The Bitcoin address that should receive the funds

Bitcoin Core 27 or newer must already be running on this computer, on the same network as the coins. If it is missing or older, the script asks before installing 27.1 from [bitcoincore.org](https://bitcoincore.org) into `~/.gallium-recovery/`.

### Hosted regtest

Do not SSH to the host, and do not point the script at the host's RPC port. That would send the private keys to another machine. Start your own regtest node and let it sync from the host over the peer port:

```bash
bitcoind -regtest -daemon -connect=HOST:18444 -fallbackfee=0.0002
bitcoin-cli -regtest getblockcount
```

`HOST` is the machine that already has the regtest chain. Port 18444 must be reachable from your computer. When the block count matches that host, run `./gallium-recover.sh` with no extra environment variables.

### Mainnet

Use the same command on the computer whose node is synced to mainnet.

When `bitcoin-cli` cannot use the node's default cookie file:

```bash
BITCOIN_RPC_USER=... BITCOIN_RPC_PASSWORD=... ./gallium-recover.sh
```

Optional: `BITCOIN_RPC_HOST`, `BITCOIN_RPC_PORT`. Leave these unset when the node is on this computer.

## Verify the file you downloaded

```bash
shasum -a 256 gallium-recover.sh
```

Compare the result with `SHA256SUMS` in this repository at the commit the Gallium app pinned. A mismatch means the file is not the pinned release. Do not run it.

## What it does

1. Checks that the two files are the bank key backup and the borrower key backup for the same network.
2. Builds the private deposit and change descriptors at the loan index you enter.
3. Asks Bitcoin Core for each descriptor checksum.
4. Imports them into a blank descriptor wallet.
5. Sends the full balance to the destination address.

## Tests

```bash
./gallium-recover.sh --self-test
```
