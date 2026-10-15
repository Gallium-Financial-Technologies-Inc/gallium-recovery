# gallium-recovery

Public recovery tool for a Gallium 2-of-3 Bitcoin escrow. It spends the escrow in Bitcoin Core with the bank recovery package and the borrower recovery package. Gallium does not need to be running, and this tool does not send the private keys anywhere.

The Gallium app pins an exact commit and SHA-256 of `gallium-recover.sh`. It downloads that file and saves it only when the checksum matches. Do not run a copy taken from the moving `main` branch tip unless you have checked that same checksum.

## Run

```bash
chmod +x gallium-recover.sh
./gallium-recover.sh
```

The script asks for the bank package path, the borrower package path, and the address that should receive the funds. The escrow deposit address is already inside the packages.

For a hosted regtest, SSH to the machine that runs that Bitcoin Core node, then run the same command. On mainnet, run it on the computer whose node has the chain.

When `bitcoin-cli` cannot use the node's default cookie file:

```bash
BITCOIN_RPC_USER=... BITCOIN_RPC_PASSWORD=... ./gallium-recover.sh
```

Optional: `BITCOIN_RPC_HOST`, `BITCOIN_RPC_PORT`.

The script requires Bitcoin Core 27 or newer. If the program is missing or older, it asks before installing 27.1 from [bitcoincore.org](https://bitcoincore.org) into `~/.gallium-recovery/`.

## Verify the file you downloaded

```bash
shasum -a 256 gallium-recover.sh
```

Compare the result with `SHA256SUMS` in this repository at the commit the Gallium app pinned. A mismatch means the file is not the pinned release. Do not run it.

## What it does

1. Checks that the two files are the bank package and the borrower package for the same loan.
2. Builds the private deposit and change descriptors.
3. Asks Bitcoin Core for each descriptor checksum.
4. Imports them into a blank descriptor wallet.
5. Sends the full balance to the destination address.

## Tests

```bash
./gallium-recover.sh --self-test
```
