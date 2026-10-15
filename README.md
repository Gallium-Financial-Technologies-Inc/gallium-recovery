# gallium-recovery

Public recovery tool for a Gallium 2-of-3 Bitcoin escrow. It spends the escrow in Bitcoin Core using the bank key backup and the borrower key backup. Those are the files downloaded when each key was created. Gallium does not need to be running, and this tool does not send the private keys anywhere.

The Gallium app pins an exact commit and SHA-256 of `gallium-recover.sh`. It downloads that file and saves it only when the checksum matches. Do not run a copy taken from the moving `main` branch tip unless you have checked that same checksum.

## Run

```bash
chmod +x gallium-recover.sh
./gallium-recover.sh
```

The same two key backups work for every loan. The script asks for:

1. Path to the bank key backup file, for example `~/Downloads/gallium-bank-key-LN-1.txt`
2. Path to the borrower key backup file
3. The loan index shown on that loan
4. The Bitcoin address that should receive the funds

It then sets up Bitcoin Core 27 or newer on this computer. Before it downloads Core, signs binaries, edits your shell startup file, or starts a node, it prints the command and waits for a yes.

On regtest it asks for the address of the machine that already has the chain, then peers to port 18444. That port must accept connections from this computer. Leave the address blank to start an empty local regtest. After the payment is sent, it can mine one block so the other machine sees it.

On mainnet it starts Bitcoin Core if needed and waits until the node has finished syncing. A first sync can take a long time. Stopping the script leaves the node running, and the next run continues.

The private keys stay on this computer. Leave `BITCOIN_RPC_HOST` unset.

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
