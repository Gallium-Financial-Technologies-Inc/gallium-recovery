# gallium-recovery

Public recovery tool for a Gallium 2-of-3 Bitcoin escrow. One party creates a partially signed payment. The other party checks the amount, destination, and fee, then broadcasts it. Each person uses only their own key backup. Gallium does not need to be running, and this tool does not send private keys anywhere.

The Gallium app pins an exact commit and SHA-256 of `gallium-recover.sh`. It downloads that file and saves it only when the checksum matches. Do not run a copy taken from the moving `main` branch tip unless you have checked that same checksum.

## Run

Mac or Linux:

```bash
chmod +x gallium-recover.sh
./gallium-recover.sh
```

Windows, from the folder that contains this script and `gallium_recover.py`:

```bat
gallium-recover.cmd
```

Python 3 is used on every system. If it is already installed, the script uses that. If it is not, the script asks before downloading Python 3.13.17 into your home folder at `.gallium-recovery/python`. Both commands run the same program, so the questions and the progress bar are the same. Keep `gallium_recover.py` and `python-release.txt` next to the script you run.

The same key backup works for every loan belonging to that person. The escrow public keys file must be the one for the loan you are recovering, because it names the other party's key for that loan. The script first asks whether to `create` a payment or `complete` one.

To create a payment it asks for:

1. Path to your own key backup, for example `~/Downloads/gallium-bank-key-LN-1.txt`
2. The escrow public keys file for that loan, for example `~/Downloads/gallium-escrow-public-LN-1.txt`. It is always asked, and it replaces any other party's key found in the key backup.
3. The loan index shown on that loan
4. The Bitcoin address that should receive the funds
5. The amount in BTC
6. Whether the fee comes out of that amount. Type `with` to empty a wallet: the destination gets the amount minus the fee. Type `without` to send the amount exactly, with the fee paid on top.

It writes `gallium-recovery-<loan index>.psbt.txt` in the current folder. Send that file to the other party. It does not contain your private key.

To complete a payment, the other party enters their own key backup, that payment file, the loan index, and the destination, amount, and with or without fee they expect. The script rejects the payment unless every input belongs to this escrow and the destination and amount match. It then shows the fee and waits for a yes before broadcasting.

A progress bar shows the percent complete. While Bitcoin Core is syncing, or while it is being downloaded, the percent shows how far that step has got.

The script sets up Bitcoin Core 27 or newer on this computer. Before it downloads Core, signs binaries, edits your shell startup file, or starts a node, it prints the command and waits for a yes. On Windows it starts Bitcoin Core in the background because Windows does not support `-daemon`.

On regtest it asks for the address of the machine that already has the chain, then peers to port 18444. That port must accept connections from this computer. Leave the address blank to start an empty local regtest. Regtest uses a fee of 2 sat/vB. On mainnet, Bitcoin Core estimates the fee. After a completed payment on regtest, the script can mine one block so the other machine sees it.

The script finds the loan's coins with `scantxoutset`, which reads only the unspent coin set. That works on a pruned node, whatever the prune size and however old the deposit is. It never rescans old blocks. Finding the coins can take a few minutes on mainnet.

On mainnet it starts Bitcoin Core if needed and waits until the node has finished syncing. A first sync can take a long time. Stopping the script leaves the node running, and the next run continues.

The private keys stay on this computer. Leave `BITCOIN_RPC_HOST` unset.

## Verify the file you downloaded

```bash
shasum -a 256 gallium-recover.sh gallium_recover.py
```

On Windows:

```bat
certutil -hashfile gallium-recover.ps1 SHA256
certutil -hashfile gallium_recover.py SHA256
```

Compare the result with `SHA256SUMS` in this repository at the commit the Gallium app pinned. A mismatch means the file is not the pinned release. Do not run it.

## What it does

1. Reads your key backup and the escrow public keys file for the loan.
2. Builds the deposit and change descriptors for that loan index. Your key is the extended private key. Gallium's key and the other party's key stay public.
3. Imports those descriptors into a descriptor wallet named for the loan index, your role, and a hash of the escrow's public keys. A different escrow gets a different wallet. The wallet only signs. It does not rescan old blocks.
4. On create, finds the loan's coins in Bitcoin Core's unspent coin set, builds a partially signed payment from them for the amount you entered, signs it with your key, and writes it to a file.
5. On complete, checks the inputs, destination, and amount, shows the fee, and broadcasts only after you agree.

## Tests

```bash
./gallium-recover.sh --self-test
```

```bat
gallium-recover.cmd --self-test
```

The end-to-end test starts a private pruned regtest node, funds a real 2-of-3 escrow, deletes the block that holds the deposit, and drives `gallium-recover.sh` through create and complete. It does not mock Bitcoin Core or the script. Bitcoin Core 27 or newer must be on `PATH`, or `BITCOIND` must point at `bitcoind`. It uses the key libraries already installed for the Gallium app when they are next to this repo, and installs them if they are not.

```bash
python3 test/e2e_recover.py
```
