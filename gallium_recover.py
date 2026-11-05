#!/usr/bin/env python3
"""Gallium escrow recovery. gallium-recover.sh and gallium-recover.ps1 both run this file."""

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

if os.name != "nt":
    import termios
from decimal import Decimal
from pathlib import Path

SCRIPT_VERSION = "2.1.0"
CORE_VERSION = "27.1"
CORE_MAJOR = 27
BAR_WIDTH = 24
TOTAL_STEPS = 8
PASTE_ON = "\x1b[?2004h"
PASTE_OFF = "\x1b[?2004l"
PASTE_START = "\x1b[200~"
PASTE_END = "\x1b[201~"

CORE_ARCHIVES = {
    ("Linux", "x86_64"): (
        "bitcoin-27.1-x86_64-linux-gnu.tar.gz",
        "c9840607d230d65f6938b81deaec0b98fe9cb14c3a41a5b13b2c05d044a48422",
    ),
    ("Linux", "aarch64"): (
        "bitcoin-27.1-aarch64-linux-gnu.tar.gz",
        "bb878df4f8ff8fb8acfb94207c50f959c462c39e652f507c2a2db20acc6a1eee",
    ),
    ("Darwin", "arm64"): (
        "bitcoin-27.1-arm64-apple-darwin.tar.gz",
        "ad4a3fd484077224a82dd56d194efb6e614467f413ab1dfb8776da4d08a4c227",
    ),
    ("Darwin", "x86_64"): (
        "bitcoin-27.1-x86_64-apple-darwin.tar.gz",
        "6d94bde5541a18964c1c36b0f12334004e45e195f244e381fd459827b1fdc395",
    ),
    ("Windows", "AMD64"): (
        "bitcoin-27.1-win64.zip",
        "9719871a2c9a45c741e33d670d2319dcd3f8f52a6059e9c435a9a2841188b932",
    ),
    ("Windows", "x86_64"): (
        "bitcoin-27.1-win64.zip",
        "9719871a2c9a45c741e33d670d2319dcd3f8f52a6059e9c435a9a2841188b932",
    ),
}


class RecoveryError(Exception):
    pass


def die(message):
    raise RecoveryError(message)


def expect(condition, message):
    if not condition:
        die(message)


def render_bar(done, total, label):
    safe_total = total if total > 0 else 1
    filled = (BAR_WIDTH * done) // safe_total
    if filled > BAR_WIDTH:
        filled = BAR_WIDTH
    if filled < 0:
        filled = 0
    percent = (100 * done) // safe_total
    if percent > 100:
        percent = 100
    if percent < 0:
        percent = 0
    bar = "#" * filled + "-" * (BAR_WIDTH - filled)
    return f"[{bar}] {percent}%  {label}"


def show_progress(done, total, label, stay):
    line = render_bar(done, total, label)
    if stay:
        sys.stderr.write("\r" + line + "        ")
        sys.stderr.flush()
        return
    sys.stderr.write(line + "\n")
    sys.stderr.flush()


def console():
    if os.name == "nt":
        return sys.stdin, sys.stdout
    try:
        return open("/dev/tty", "r"), open("/dev/tty", "w")
    except OSError:
        die("A terminal is required.")


READER = None
WRITER = None
PASTE_ENABLED = False
SAVED_TTY = None


def streams():
    global READER, WRITER
    if READER is None or WRITER is None:
        READER, WRITER = console()
    return READER, WRITER


def begin_bracketed_paste():
    global PASTE_ENABLED, SAVED_TTY
    if os.name == "nt" or PASTE_ENABLED:
        return
    reader, writer = streams()
    fd = reader.fileno()
    saved = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = saved
    lflag = lflag & ~termios.ECHOCTL
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])
    SAVED_TTY = saved
    writer.write(PASTE_ON)
    writer.flush()
    PASTE_ENABLED = True


def end_bracketed_paste():
    global PASTE_ENABLED, SAVED_TTY
    if not PASTE_ENABLED:
        return
    PASTE_ENABLED = False
    try:
        reader, writer = streams()
        if SAVED_TTY is not None:
            termios.tcsetattr(reader.fileno(), termios.TCSANOW, SAVED_TTY)
            SAVED_TTY = None
        writer.write(PASTE_OFF)
        writer.flush()
    except OSError:
        return


def clean_answer(answer):
    answer = answer.replace(PASTE_START, "")
    answer = answer.replace(PASTE_END, "")
    return answer.strip()


def prompt_line(label):
    reader, writer = streams()
    answer = ""
    while answer == "":
        writer.write(f"{label}: ")
        writer.flush()
        answer = reader.readline()
        if answer == "":
            die(f"A terminal is required to enter {label}.")
        answer = clean_answer(answer)
    return answer


def prompt_optional(label):
    reader, writer = streams()
    writer.write(f"{label}: ")
    writer.flush()
    answer = reader.readline()
    if answer == "":
        die(f"A terminal is required to enter {label}.")
    return clean_answer(answer)


def confirm(prompt):
    reader, writer = streams()
    writer.write(f"{prompt} [y/N] ")
    writer.flush()
    answer = reader.readline()
    if answer == "":
        die(f"A terminal is required to confirm: {prompt}")
    answer = clean_answer(answer)
    return answer == "y" or answer == "Y"


def say(message):
    sys.stdout.write(message + "\n")
    sys.stdout.flush()


def field_value(path, label):
    prefix = label + ": "
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith(prefix):
                return line[len(prefix):].rstrip("\r\n")
    return ""


def next_line(path, label):
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.rstrip("\r\n") == label:
                return handle.readline().rstrip("\r\n")
    return ""


def valid_amount(value):
    if re.fullmatch(r"[0-9]+(\.[0-9]{1,8})?", value) is None:
        return False
    return Decimal(value) > 0


def valid_destination(value):
    return re.fullmatch(r"[A-Za-z0-9]+", value) is not None


def valid_host(value):
    return value != "" and re.fullmatch(r"[A-Za-z0-9.:-]+", value) is not None


def peer_address(host):
    if ":" in host:
        return host
    return host + ":18444"


def require_key_token(label, value):
    if re.fullmatch(r"[A-Za-z0-9]+", value) is None:
        die(f"{label} is not a single key.")


def key_token(value):
    return re.fullmatch(r"[A-Za-z0-9]+", value) is not None


def expand_path(value):
    return str(Path(value).expanduser())


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        chunk = handle.read(1024 * 1024)
        while chunk:
            digest.update(chunk)
            chunk = handle.read(1024 * 1024)
    return digest.hexdigest()


def core_archive(system, machine):
    archive = CORE_ARCHIVES.get((system, machine))
    if archive is None:
        die(
            f"Automatic Bitcoin Core install is not available for {system} {machine}.\n"
            f"Install Bitcoin Core {CORE_VERSION} or newer, then run this script again."
        )
    return archive


def cli_name():
    if os.name == "nt":
        return "bitcoin-cli.exe"
    return "bitcoin-cli"


def daemon_name():
    if os.name == "nt":
        return "bitcoind.exe"
    return "bitcoind"


def install_root():
    return Path.home() / ".gallium-recovery" / f"bitcoin-core-{CORE_VERSION}"


def run_command(command):
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return completed.returncode, completed.stdout


def read_core_version(cli):
    code, output = run_command([cli, "-version"])
    if code != 0 or output == "":
        return ""
    first = output.splitlines()[0]
    matched = re.search(r" v([0-9]+)\.", first)
    if matched is None:
        return ""
    return matched.group(1)


def sign_dir(directory):
    for name in ("bitcoind", "bitcoin-cli", "bitcoin-tx", "bitcoin-wallet"):
        path = Path(directory) / name
        if path.is_file() and os.access(path, os.X_OK):
            subprocess.run(["codesign", "--force", "-s", "-", str(path)], check=False)


class Recovery:
    def __init__(self):
        self.role = ""
        self.network = ""
        self.gallium = ""
        self.origin = ""
        self.gallium_xpub = ""
        self.xprv = ""
        self.bank_xpub = ""
        self.borrower_xpub = ""
        self.own_xpub = ""
        self.loan_index = ""
        self.destination = ""
        self.amount = ""
        self.external = ""
        self.change = ""
        self.external_sum = ""
        self.change_sum = ""
        self.wallet = ""
        self.psbt_body = ""
        self.bitcoin_cli = ""
        self.bitcoind = ""
        self.started_node = False
        self.regtest_peer = ""
        self.probe_output = ""

    def load_key_file(self, path):
        role = field_value(path, "Role")
        network = field_value(path, "Network")
        gallium = next_line(path, "Gallium account key:")
        xprv = next_line(path, "Account extended private key:")
        if role == "" or network == "" or gallium == "" or xprv == "":
            die(
                f"Could not read a Gallium key backup: {path}\n"
                "The file must contain Role, Network, Gallium account key, and Account extended private key."
            )
        if not key_token(xprv):
            die(f"Account extended private key is not a single key in {path}.")
        if not gallium.startswith("[") or "]" not in gallium:
            die(f"Gallium account key is not an account key in {path}.")
        origin, xpub = gallium.split("]", 1)
        if origin == "" or xpub == "" or "/" in xpub:
            die(f"Gallium account key is not an account key in {path}.")
        self.role = role
        self.network = network
        self.gallium = gallium
        self.origin = origin
        self.gallium_xpub = xpub
        self.xprv = xprv
        self.own_xpub = next_line(path, "Account public key (xpub):")
        self.bank_xpub = next_line(path, "Bank account key:")
        self.borrower_xpub = next_line(path, "Borrower account key:")

    def fill_public_keys(self, path):
        network = field_value(path, "Network")
        gallium = next_line(path, "Gallium account key:")
        bank = next_line(path, "Bank account key:")
        borrower = next_line(path, "Borrower account key:")
        if network == "" or gallium == "" or bank == "" or borrower == "":
            die(f"Could not read the escrow public keys: {path}")
        if network != self.network or gallium != self.gallium:
            die("Those public keys are not for this key backup's network and Gallium key.")
        if self.bank_xpub == "":
            self.bank_xpub = bank
        if self.borrower_xpub == "":
            self.borrower_xpub = borrower

    def use_key_file(self, path):
        self.load_key_file(path)
        if self.role == "Bank" and self.bank_xpub == "":
            self.bank_xpub = self.own_xpub
        if self.role == "Borrower" and self.borrower_xpub == "":
            self.borrower_xpub = self.own_xpub
        if self.bank_xpub == "" or self.borrower_xpub == "":
            say("This key file does not include the other party's public key.")
            public_file = expand_path(prompt_line("Full path to the escrow public keys file (example: ~/Downloads/gallium-escrow-public-LN-1.txt)"))
            if not os.path.isfile(public_file):
                die("No file was found at that path.")
            self.fill_public_keys(public_file)
        if self.bank_xpub == "" or self.borrower_xpub == "":
            die("The bank and borrower public keys are required.")
        require_key_token("Bank account key", self.bank_xpub)
        require_key_token("Borrower account key", self.borrower_xpub)
        if self.role == "Bank" and self.own_xpub != "" and self.bank_xpub != self.own_xpub:
            die("The bank public key in this file does not match Account public key (xpub).")
        if self.role == "Borrower" and self.own_xpub != "" and self.borrower_xpub != self.own_xpub:
            die("The borrower public key in this file does not match Account public key (xpub).")
        if self.bank_xpub == self.borrower_xpub:
            die("The bank and borrower public keys are the same.")
        if self.role != "Bank" and self.role != "Borrower":
            die(f"Unrecognized key backup role: {self.role}")
        if self.network not in ("mainnet", "testnet", "signet", "regtest"):
            die(f"Unsupported Bitcoin network: {self.network}")

    def signing_key(self, which):
        if which == "Bank":
            xpub = self.bank_xpub
        else:
            xpub = self.borrower_xpub
        if self.role == which:
            return self.xprv
        return xpub

    def prepare_descriptor(self):
        bank = self.signing_key("Bank")
        borrower = self.signing_key("Borrower")
        descriptor = (
            f"wsh(sortedmulti(2,{self.origin}/{self.loan_index}]{self.gallium_xpub}/{self.loan_index}/<0;1>/*,"
            f"{bank}/{self.loan_index}/<0;1>/*,{borrower}/{self.loan_index}/<0;1>/*))"
        )
        self.external = descriptor.replace("/<0;1>/*", "/0/*")
        self.change = descriptor.replace("/<0;1>/*", "/1/*")

    def bitcoin(self, args):
        command = [self.bitcoin_cli]
        if self.network != "mainnet":
            command.append("-" + self.network)
        rpc_flags = (
            ("BITCOIN_RPC_HOST", "rpcconnect"),
            ("BITCOIN_RPC_PORT", "rpcport"),
            ("BITCOIN_RPC_USER", "rpcuser"),
            ("BITCOIN_RPC_PASSWORD", "rpcpassword"),
        )
        for env_name, flag in rpc_flags:
            value = os.environ.get(env_name, "")
            if value != "":
                command.append(f"-{flag}={value}")
        for arg in args:
            command.append(arg)
        return run_command(command)

    def bitcoin_json(self, args):
        code, output = self.bitcoin(args)
        if code != 0:
            die(output.rstrip("\n"))
        return json.loads(output, parse_float=Decimal)

    def accept_cli(self, cli):
        directory = str(Path(cli).parent)
        daemon = str(Path(directory) / daemon_name())
        if not (os.path.isfile(cli) and os.path.isfile(daemon)):
            return False
        major = read_core_version(cli)
        if major == "":
            if os.name == "nt" or sys.platform != "darwin":
                return False
            say(f"macOS is blocking {cli}.")
            say("The script will run:")
            say(f"  codesign --force -s - {directory}/{daemon_name()} {directory}/{cli_name()}")
            if not confirm("Sign these Bitcoin Core binaries?"):
                return False
            sign_dir(directory)
            major = read_core_version(cli)
            if major == "":
                return False
        if int(major) < CORE_MAJOR:
            return False
        self.bitcoin_cli = cli
        self.bitcoind = daemon
        return True

    def locate_core(self):
        chosen = os.environ.get("BITCOIN_CLI", "")
        if chosen != "":
            if not self.accept_cli(chosen):
                die(f"BITCOIN_CLI is set but is not usable Bitcoin Core {CORE_MAJOR} or newer.")
            return True
        found = shutil.which(cli_name())
        if found and self.accept_cli(found):
            return True
        bundled = install_root() / "bin" / cli_name()
        if bundled.is_file() and self.accept_cli(str(bundled)):
            return True
        patterns = (
            str(Path.home() / "Downloads" / "bitcoin-*" / "bin"),
            str(Path.home() / ".gallium-recovery" / "bitcoin-core-*" / "bin"),
        )
        for pattern in patterns:
            for directory in glob.glob(pattern):
                candidate = str(Path(directory) / cli_name())
                if os.path.isfile(candidate) and self.accept_cli(candidate):
                    return True
        fixed = ("/usr/local/bin/bitcoin-cli", "/opt/homebrew/bin/bitcoin-cli")
        for candidate in fixed:
            if os.path.isfile(candidate) and self.accept_cli(candidate):
                return True
        if os.name == "nt":
            program_dirs = (
                os.environ.get("ProgramFiles", ""),
                os.environ.get("ProgramFiles(x86)", ""),
            )
            for program_dir in program_dirs:
                if program_dir == "":
                    continue
                candidate = str(Path(program_dir) / "Bitcoin" / "daemon" / cli_name())
                if os.path.isfile(candidate) and self.accept_cli(candidate):
                    return True
        return False

    def maybe_persist_path(self):
        directory = str(Path(self.bitcoin_cli).parent)
        found = shutil.which(cli_name())
        if found is not None and os.path.normcase(found) == os.path.normcase(self.bitcoin_cli):
            return
        if os.name == "nt":
            say("New terminals cannot see bitcoin-cli yet.")
            say(f"The script will add this directory to your user PATH:\n  {directory}")
            if confirm(f"Add Bitcoin Core to your user PATH?"):
                add_windows_path(directory)
                say(f"Added. This run already uses {self.bitcoin_cli}.")
            return
        shell = os.environ.get("SHELL", "")
        if shell.endswith("zsh"):
            profile = Path.home() / ".zshrc"
        elif shell.endswith("bash"):
            profile = Path.home() / ".bashrc"
        else:
            profile = Path.home() / ".profile"
        if profile.is_file() and directory in profile.read_text(encoding="utf-8"):
            return
        line = f'export PATH="{directory}:$PATH"'
        say("New terminals cannot see bitcoin-cli yet.")
        say(f"The script will add this line to {profile}:")
        say(f"  {line}")
        if confirm(f"Add Bitcoin Core to {profile}?"):
            with open(profile, "a", encoding="utf-8") as handle:
                handle.write("\n" + line + "\n")
            say(f"Added. This run already uses {self.bitcoin_cli}.")

    def install_core(self):
        archive, digest = core_archive(platform_system(), platform_machine())
        work = Path(tempfile.mkdtemp())
        url = f"https://bitcoincore.org/bin/bitcoin-core-{CORE_VERSION}/{archive}"
        destination = work / archive
        say(f"Downloading Bitcoin Core {CORE_VERSION}...")

        def report(copied, block, total):
            if total > 0:
                show_progress(copied * block, total, f"Downloading Bitcoin Core {CORE_VERSION}", True)

        urllib.request.urlretrieve(url, destination, reporthook=report)
        sys.stderr.write("\n")
        if sha256_file(destination) != digest:
            shutil.rmtree(work, ignore_errors=True)
            die("Bitcoin Core download did not match the published checksum.")
        if archive.endswith(".zip"):
            with zipfile.ZipFile(destination) as packed:
                packed.extractall(work)
        else:
            shutil.unpack_archive(str(destination), str(work))
        bin_dir = find_bin_dir(work)
        if bin_dir is None:
            shutil.rmtree(work, ignore_errors=True)
            die("The Bitcoin Core download did not contain bitcoin-cli.")
        root = install_root()
        root.mkdir(parents=True, exist_ok=True)
        target = root / "bin"
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(bin_dir), str(target))
        shutil.rmtree(work, ignore_errors=True)
        self.bitcoin_cli = str(target / cli_name())
        say(f"Installed Bitcoin Core {CORE_VERSION} at {root}.")

    def prepare_node(self):
        if not self.locate_core():
            root = install_root()
            say(f"The script will download Bitcoin Core {CORE_VERSION} from bitcoincore.org into {root}.")
            if not confirm(f"Install Bitcoin Core {CORE_VERSION}?"):
                raise SystemExit(1)
            self.install_core()
            if sys.platform == "darwin":
                say("Signing Bitcoin Core so macOS will run it.")
                sign_dir(str(Path(self.bitcoin_cli).parent))
            major = read_core_version(self.bitcoin_cli)
            if major == "" or int(major) < CORE_MAJOR:
                die(f"Bitcoin Core {CORE_VERSION} is still not available.")
            self.bitcoind = str(Path(self.bitcoin_cli).parent / daemon_name())
        self.maybe_persist_path()
        if self.node_responds() or self.node_is_starting():
            self.wait_until_ready()
            return
        if self.node_is_down():
            self.start_node()
            self.wait_until_ready()
            return
        die(self.probe_output.rstrip("\n") + "\nBitcoin Core is not accepting local commands. The keys stay on this computer.")

    def node_responds(self):
        code, output = self.bitcoin(["getblockcount"])
        self.probe_output = output
        return code == 0

    def node_is_down(self):
        return "Could not connect" in self.probe_output or "Connection refused" in self.probe_output

    def node_is_starting(self):
        text = self.probe_output
        return "Loading" in text or "Starting" in text or "Verifying" in text or "-28" in text

    def wait_until_ready(self):
        started = time.time()
        told = False
        show_progress(5, TOTAL_STEPS, "Wait until Bitcoin Core is ready", False)
        say("Waiting for Bitcoin Core...")
        while True:
            code, output = self.bitcoin(["getblockchaininfo"])
            if code == 0:
                info = json.loads(output)
                blocks = int(info["blocks"])
                headers = int(info["headers"])
                ibd = info["initialblockdownload"]
                if self.network == "regtest" and self.regtest_peer == "" and blocks == headers:
                    show_progress(5, TOTAL_STEPS, "Bitcoin Core is ready", False)
                    say(f"Bitcoin Core is ready. Block height {blocks}.")
                    return
                if self.network == "regtest" and self.regtest_peer != "":
                    peers_code, peers_output = self.bitcoin(["getconnectioncount"])
                    peers = 0
                    if peers_code == 0:
                        peers = int(peers_output.strip())
                    show_progress(blocks, headers, f"Waiting for {self.regtest_peer}. Height {blocks}, peers {peers}.", True)
                    if peers >= 1 and blocks > 0 and blocks == headers:
                        sys.stderr.write("\n")
                        show_progress(5, TOTAL_STEPS, "Bitcoin Core is ready", False)
                        say(f"Connected to {self.regtest_peer}. Block height {blocks}.")
                        return
                    if peers == 0 and time.time() - started > 90:
                        die(
                            f"Could not connect to {self.regtest_peer}.\n"
                            "Port 18444 on that host must accept connections from this computer."
                        )
                elif ibd is False and blocks == headers:
                    show_progress(5, TOTAL_STEPS, "Bitcoin Core is ready", False)
                    say(f"Bitcoin Core is ready. Block height {blocks}.")
                    return
                else:
                    show_progress(blocks, headers, f"Syncing {blocks} of {headers} blocks", True)
                    if not told:
                        sys.stderr.write("\n")
                        say("Sync can take a long time. Stop this script and run it again later; the node keeps syncing.")
                        told = True
            elif self.network == "regtest" and self.regtest_peer != "":
                if time.time() - started > 90:
                    die(
                        f"Could not connect to {self.regtest_peer}.\n"
                        "Port 18444 on that host must accept connections from this computer."
                    )
            time.sleep(2)

    def start_node(self):
        if self.network == "mainnet":
            args = []
        elif self.network == "testnet":
            args = ["-testnet"]
        elif self.network == "signet":
            args = ["-signet"]
        elif self.network == "regtest":
            say("No regtest node is running on this computer.")
            say("If the coins are on another machine, enter that machine's address.")
            say("Its peer port 18444 must accept connections from this computer.")
            say("Leave the address blank to start an empty regtest node on this computer.")
            host = prompt_optional("Address of the machine that already has the chain, or leave this blank (example: 203.0.113.10)")
            args = ["-regtest", "-fallbackfee=0.0002"]
            if host != "":
                if not valid_host(host):
                    die("That host address is not valid. Enter an IP address or a hostname.")
                self.regtest_peer = peer_address(host)
                args.append("-connect=" + self.regtest_peer)
        else:
            die(f"Unsupported Bitcoin network: {self.network}")
        if os.name != "nt":
            args.append("-daemon")
        command = [self.bitcoind]
        for arg in args:
            command.append(arg)
        shown = " ".join(command)
        say("The script will run:")
        say(f"  {shown}")
        if not confirm("Start Bitcoin Core?"):
            raise SystemExit(1)
        if os.name == "nt":
            flags = 0x00000008 | 0x00000200
            process = subprocess.Popen(
                command,
                creationflags=flags,
                close_fds=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            time.sleep(1)
            if process.poll() is not None:
                die("Could not start Bitcoin Core.")
        else:
            completed = subprocess.run(command)
            if completed.returncode != 0:
                die("Could not start Bitcoin Core.")
        self.started_node = True

    def descriptor_info(self, descriptor):
        code, output = self.bitcoin(["getdescriptorinfo", descriptor])
        if code != 0:
            die(output.rstrip("\n") + "\nBitcoin Core on this computer did not accept the descriptor.")
        return json.loads(output)

    def checksum_for(self, descriptor):
        checksum = self.descriptor_info(descriptor).get("checksum", "")
        if checksum == "":
            die("Bitcoin Core did not return a descriptor checksum.")
        return checksum

    def find_coins(self):
        """List this loan's unspent coins from Bitcoin Core's UTXO set. A pruned node keeps the whole set, so this works with any amount of pruning."""
        scan = []
        for descriptor in (self.external, self.change):
            scan.append({"desc": self.descriptor_info(descriptor)["descriptor"], "range": [0, 20]})
        say("Looking for this loan's coins. This can take a few minutes.")
        scanned = self.bitcoin_json(["scantxoutset", "start", json.dumps(scan, separators=(",", ":"))])
        if scanned.get("success") is not True:
            die("The search for this loan's coins did not finish. Run this again.")
        coins = scanned.get("unspents", [])
        if len(coins) == 0:
            die(
                f"No coins were found for loan index {self.loan_index} in this escrow.\n"
                "Check the loan index. A deposit needs one confirmation before it can be found."
            )
        return coins

    def open_wallet(self):
        slug = self.role.lower()
        self.wallet = f"gallium-recovery-{self.loan_index}-{slug}"
        code, _output = self.bitcoin([
            "-named",
            "createwallet",
            f"wallet_name={self.wallet}",
            "blank=true",
            "descriptors=true",
        ])
        if code != 0:
            load_code, load_output = self.bitcoin(["loadwallet", self.wallet])
            if load_code != 0 and "already loaded" not in load_output:
                die(load_output.rstrip("\n"))
        existing = self.bitcoin_json([f"-rpcwallet={self.wallet}", "listdescriptors"])
        if len(existing.get("descriptors", [])) >= 2:
            return
        self.external_sum = self.checksum_for(self.external)
        self.change_sum = self.checksum_for(self.change)
        # "now" skips the block rescan. A rescan needs every old block, which a pruned node has deleted.
        # The wallet only signs. The coins come from find_coins.
        payload = [
            {
                "desc": f"{self.external}#{self.external_sum}",
                "active": True,
                "internal": False,
                "range": [0, 20],
                "timestamp": "now",
            },
            {
                "desc": f"{self.change}#{self.change_sum}",
                "active": True,
                "internal": True,
                "range": [0, 20],
                "timestamp": "now",
            },
        ]
        imported = self.bitcoin_json([
            f"-rpcwallet={self.wallet}",
            "importdescriptors",
            json.dumps(payload, separators=(",", ":")),
        ])
        success_count = 0
        for row in imported:
            if row.get("success") is True:
                success_count += 1
        if success_count != 2:
            die("Bitcoin Core rejected the recovery descriptors.\n" + json.dumps(imported))

    def derived_addresses(self):
        if self.external_sum == "":
            self.external_sum = self.checksum_for(self.external)
            self.change_sum = self.checksum_for(self.change)
        receive = self.bitcoin_json(["deriveaddresses", f"{self.external}#{self.external_sum}", "[0,20]"])
        change = self.bitcoin_json(["deriveaddresses", f"{self.change}#{self.change_sum}", "[0,20]"])
        return receive, change

    def check_psbt(self):
        decoded = self.bitcoin_json(["decodepsbt", self.psbt_body])
        receive, change = self.derived_addresses()
        allowed = set(receive)
        for address in change:
            allowed.add(address)
        scale = Decimal("100000000")
        payment = None
        for output in decoded["tx"]["vout"]:
            script = output.get("scriptPubKey") or {}
            address = script.get("address")
            value = output.get("value")
            if not address or value is None:
                die("The payment has an output Bitcoin Core could not identify.")
            if address in allowed:
                continue
            if payment is not None:
                die("The payment has more than one destination.")
            payment = (address, value)
        if payment is None:
            die("The payment does not pay the destination from this escrow.")
        paid_sats = (payment[1] * scale).to_integral_value()
        expect_sats = (Decimal(self.amount) * scale).to_integral_value()
        if payment[0] != self.destination or paid_sats != expect_sats:
            die(
                "The payment destination or amount does not match what you entered.\n"
                f"PSBT pays {payment[1]} BTC to {payment[0]}."
            )
        for item in decoded.get("inputs", []):
            witness = item.get("witness_utxo") or {}
            script = witness.get("scriptPubKey") or {}
            address = script.get("address")
            if address not in allowed:
                die("The payment spends a coin that is not in this escrow.")
        fee = decoded.get("fee")
        if fee is None:
            die("Bitcoin Core did not report a fee for this payment.")
        return str(fee)

    def build_psbt(self):
        coins = self.find_coins()
        inputs = []
        descriptors = []
        for coin in coins:
            inputs.append({"txid": coin["txid"], "vout": coin["vout"]})
            descriptors.append(coin["desc"])
        options = {
            "psbt": True,
            "inputs": inputs,
            "add_inputs": False,
            "solving_data": {"descriptors": descriptors},
        }
        if self.network == "regtest":
            options["fee_rate"] = 2
        result = self.bitcoin_json([
            f"-rpcwallet={self.wallet}",
            "-named",
            "send",
            f'outputs={{"{self.destination}":{self.amount}}}',
            "options=" + json.dumps(options, separators=(",", ":")),
        ])
        psbt = result.get("psbt")
        if not isinstance(psbt, str) or psbt == "":
            die("Bitcoin Core did not return the payment.")
        code, updated = self.bitcoin(["utxoupdatepsbt", psbt, json.dumps(descriptors, separators=(",", ":"))])
        if code != 0:
            die(updated.rstrip("\n"))
        signed = self.bitcoin_json([f"-rpcwallet={self.wallet}", "walletprocesspsbt", updated.strip()])
        body = signed.get("psbt")
        if not isinstance(body, str) or body == "":
            die("Bitcoin Core did not return the payment.")
        self.psbt_body = body

    def write_psbt_file(self, path, fee):
        if os.path.exists(path):
            die(f"A file named {path} already exists in this folder. Move it, then run this again.")
        lines = [
            "Gallium recovery payment",
            f"Network: {self.network}",
            f"Loan index: {self.loan_index}",
            f"Amount: {self.amount} BTC",
            f"Destination: {self.destination}",
            f"Fee: {fee} BTC",
            "PSBT:",
            self.psbt_body,
            "",
        ]
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(lines))

    def read_psbt_bundle(self, path):
        seen = False
        body = ""
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                text = line.rstrip("\r\n")
                if seen:
                    body += text
                if text == "PSBT:":
                    seen = True
        if body == "":
            die("That file does not contain a Gallium recovery PSBT.")
        self.psbt_body = body

    def broadcast(self):
        processed = self.bitcoin_json([f"-rpcwallet={self.wallet}", "walletprocesspsbt", self.psbt_body])
        signed = processed.get("psbt")
        if not isinstance(signed, str) or signed == "":
            die("Bitcoin Core did not return the payment.")
        final = self.bitcoin_json(["finalizepsbt", signed])
        if final.get("complete") is not True:
            die("The payment still needs another signature.")
        raw = final.get("hex")
        if not isinstance(raw, str) or raw == "":
            die("Bitcoin Core did not return a signed transaction.")
        code, output = self.bitcoin(["sendrawtransaction", raw])
        if code != 0:
            die(output.rstrip("\n"))
        return output.strip()

    def finish_regtest(self):
        if self.network != "regtest":
            return
        say("The script can mine 1 block so other machines see this payment.")
        say(f"It will run: {self.bitcoin_cli} -regtest -rpcwallet=mine generatetoaddress 1 <new address>")
        if confirm("Mine 1 block now?"):
            code, _output = self.bitcoin(["createwallet", "mine"])
            if code != 0:
                load_code, load_output = self.bitcoin(["loadwallet", "mine"])
                if load_code != 0 and "already loaded" not in load_output:
                    die(load_output.rstrip("\n"))
            code, output = self.bitcoin(["-rpcwallet=mine", "getnewaddress"])
            if code != 0:
                die(output.rstrip("\n"))
            address = output.strip()
            if address == "":
                die("Bitcoin Core did not return a mining address.")
            self.bitcoin_json(["-rpcwallet=mine", "generatetoaddress", "1", address])
        if self.started_node:
            say(f"The script will run: {self.bitcoin_cli} -regtest stop")
            if confirm("Stop the local regtest node?"):
                self.bitcoin(["stop"])
                say("Stopped Bitcoin Core.")


def platform_system():
    if os.name == "nt":
        return "Windows"
    return os.uname().sysname


def platform_machine():
    if os.name == "nt":
        wide = os.environ.get("PROCESSOR_ARCHITEW6432", "")
        if wide != "":
            return wide
        return os.environ.get("PROCESSOR_ARCHITECTURE", "")
    return os.uname().machine


def find_bin_dir(root):
    wanted = cli_name()
    for dirpath, _dirnames, filenames in os.walk(root):
        for filename in filenames:
            if filename == wanted:
                return Path(dirpath)
    return None


def add_windows_path(directory):
    import winreg
    key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_READ | winreg.KEY_SET_VALUE)
    try:
        current, value_type = winreg.QueryValueEx(key, "Path")
    except FileNotFoundError:
        current = ""
        value_type = winreg.REG_EXPAND_SZ
    parts = current.split(";")
    for part in parts:
        if os.path.normcase(part) == os.path.normcase(directory):
            return
    updated = current
    if updated != "" and not updated.endswith(";"):
        updated += ";"
    updated += directory
    winreg.SetValueEx(key, "Path", 0, value_type, updated)
    winreg.CloseKey(key)


def read_psbt_text(path):
    session = Recovery()
    session.read_psbt_bundle(path)
    return session.psbt_body


def self_test():
    expect(clean_answer("create") == "create", "typed answer was changed")
    expect(clean_answer("\x1b[200~create\x1b[201~") == "create", "pasted answer was not cleaned")
    expect(clean_answer("\x1b[200~/tmp/key.txt") == "/tmp/key.txt", "pasted path was not cleaned")
    expect(clean_answer("\x1b[201~7") == "7", "paste end marker was left on the next answer")
    expect(clean_answer("  \x1b[200~complete\x1b[201~  ") == "complete", "pasted answer kept surrounding space")
    expect(render_bar(0, 8, "Choose create or complete") == "[------------------------] 0%  Choose create or complete", "empty progress bar was wrong")
    expect(render_bar(1, 8, "Read your key file") == "[###---------------------] 12%  Read your key file", "progress bar was wrong")
    expect(render_bar(8, 8, "Finish") == "[########################] 100%  Finish", "full progress bar was wrong")
    archive, digest = core_archive("Windows", "AMD64")
    expect(archive == "bitcoin-27.1-win64.zip", "Windows archive name was wrong")
    expect(digest == "9719871a2c9a45c741e33d670d2319dcd3f8f52a6059e9c435a9a2841188b932", "Windows archive checksum was wrong")
    directory = tempfile.mkdtemp()
    try:
        bank_path = str(Path(directory) / "bank.txt")
        Path(bank_path).write_text(
            "Role: Bank\nLoan: LN-1\nNetwork: regtest\nGallium account key:\n[aa/48h/1h/0h/2h]tpubGallium\n"
            "Account extended private key:\ntprvBank\nAccount public key (xpub):\ntpubBank\nBorrower account key:\ntpubBorrower\n",
            encoding="utf-8",
        )
        session = Recovery()
        session.use_key_file(bank_path)
        session.loan_index = "7"
        session.prepare_descriptor()
        expect(session.external == "wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/0/*,tprvBank/7/0/*,tpubBorrower/7/0/*))", "bank descriptor was wrong")
        expect(session.change == "wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/1/*,tprvBank/7/1/*,tpubBorrower/7/1/*))", "bank change descriptor was wrong")
        expect(session.bank_xpub == "tpubBank", "bank public key was wrong")

        borrower_path = str(Path(directory) / "borrower.txt")
        Path(borrower_path).write_text(
            "Role: Borrower\nNetwork: regtest\nGallium account key:\n[aa/48h/1h/0h/2h]tpubGallium\n"
            "Account extended private key:\ntprvBorrower\nAccount public key (xpub):\ntpubBorrower\nBank account key:\ntpubBank\n",
            encoding="utf-8",
        )
        session.use_key_file(borrower_path)
        session.prepare_descriptor()
        expect(session.external == "wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/0/*,tpubBank/7/0/*,tprvBorrower/7/0/*))", "borrower descriptor was wrong")
        expect(session.change == "wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/1/*,tpubBank/7/1/*,tprvBorrower/7/1/*))", "borrower change descriptor was wrong")

        own_path = str(Path(directory) / "own-only.txt")
        Path(own_path).write_text(
            "Role: Bank\nNetwork: regtest\nGallium account key:\n[aa/48h/1h/0h/2h]tpubGallium\n"
            "Account extended private key:\ntprvBank\nAccount public key (xpub):\ntpubFromOwn\nBorrower account key:\ntpubBorrower\n",
            encoding="utf-8",
        )
        session.use_key_file(own_path)
        expect(session.bank_xpub == "tpubFromOwn", "own public key was not used")

        partial_path = str(Path(directory) / "partial.txt")
        Path(partial_path).write_text(
            "Role: Borrower\nNetwork: regtest\nGallium account key:\n[aa/48h/1h/0h/2h]tpubGallium\n"
            "Account extended private key:\ntprvBorrower\n",
            encoding="utf-8",
        )
        session.load_key_file(partial_path)
        session.borrower_xpub = "tpubKeep"
        public_path = str(Path(directory) / "public.txt")
        Path(public_path).write_text(
            "Network: regtest\nGallium account key:\n[aa/48h/1h/0h/2h]tpubGallium\n"
            "Bank account key:\ntpubBankPublic\nBorrower account key:\ntpubBorrowerPublic\n",
            encoding="utf-8",
        )
        session.fill_public_keys(public_path)
        expect(session.bank_xpub == "tpubBankPublic", "public bank key was not filled")
        expect(session.borrower_xpub == "tpubKeep", "existing borrower key was replaced")

        wrong_path = str(Path(directory) / "wrong-public.txt")
        Path(wrong_path).write_text(
            "Network: signet\nGallium account key:\n[aa/48h/1h/0h/2h]tpubGallium\n"
            "Bank account key:\ntpubBankPublic\nBorrower account key:\ntpubBorrowerPublic\n",
            encoding="utf-8",
        )
        rejected = False
        try:
            session.fill_public_keys(wrong_path)
        except RecoveryError:
            rejected = True
        expect(rejected, "expected a mismatched public key file to be rejected")

        payment_path = str(Path(directory) / "pay.txt")
        Path(payment_path).write_text("Gallium recovery payment\nPSBT:\ncHNidP8BAH\n", encoding="utf-8")
        expect(read_psbt_text(payment_path) == "cHNidP8BAH", "PSBT file was read wrong")
        expect(valid_amount("1.5") and valid_amount("0.00000001"), "a positive BTC amount was rejected")
        expect(not valid_amount("0") and not valid_amount("0.0") and not valid_amount("1.123456789") and not valid_amount("1 BTC"), "an invalid BTC amount was accepted")
        expect(valid_destination("bcrt1qexampleaddress"), "a destination address was rejected")
        expect(not valid_destination("not an address") and not valid_destination(""), "an invalid destination was accepted")
        expect(valid_host("203.0.113.10"), "a host was rejected")
        expect(not valid_host("not a host"), "an invalid host was accepted")
        expect(peer_address("203.0.113.10") == "203.0.113.10:18444", "peer port was wrong")
        expect(peer_address("127.0.0.1:18444") == "127.0.0.1:18444", "peer port was added twice")
    finally:
        shutil.rmtree(directory, ignore_errors=True)
    say("self-test ok")


def validate_payment_fields(session):
    if re.fullmatch(r"[0-9]+", session.loan_index) is None:
        die("Loan index must be the number shown on the loan.")
    if not valid_destination(session.destination):
        die("Destination address is invalid.")
    if not valid_amount(session.amount):
        die("Amount must be a positive number of BTC with at most 8 decimal places.")


def run(argv):
    if len(argv) == 1 and argv[0] == "--self-test":
        self_test()
        return
    if len(argv) != 0:
        die("Usage: gallium-recover.sh or gallium-recover.ps1\nThe script asks whether to create a payment or complete one, then asks for your key file.")
    begin_bracketed_paste()
    say(f"gallium-recover {SCRIPT_VERSION}")
    say("One party creates a payment. The other party checks it and broadcasts it.")
    say("Each person uses their own key file. The private key stays on this computer.")
    show_progress(1, TOTAL_STEPS, "Choose create or complete", False)
    mode = prompt_line("Type create to make a payment file, or complete to finish and broadcast one (example: create)").lower()
    if mode != "create" and mode != "complete":
        die("Type create or complete.")

    show_progress(2, TOTAL_STEPS, "Read your key file", False)
    key_file = expand_path(prompt_line("Full path to your own key backup file (example: ~/Downloads/gallium-bank-key-LN-1.txt)"))
    if not os.path.isfile(key_file):
        die("No file was found at that path.")
    session = Recovery()
    session.use_key_file(key_file)
    psbt_file = ""
    if mode == "complete":
        psbt_file = expand_path(prompt_line("Full path to the payment file you were sent (example: gallium-recovery-7.psbt.txt)"))
        if not os.path.isfile(psbt_file):
            die("No file was found at that path.")

    show_progress(3, TOTAL_STEPS, "Enter the payment", False)
    session.loan_index = prompt_line("Loan index shown on the loan (example: 7)")
    session.destination = prompt_line("Bitcoin address that should receive the funds (example: bc1qexampleaddress)")
    session.amount = prompt_line("Amount that address should receive, in BTC. Do not include the fee (example: 0.01)")
    validate_payment_fields(session)
    session.prepare_descriptor()

    show_progress(4, TOTAL_STEPS, "Prepare Bitcoin Core", False)
    session.prepare_node()
    show_progress(6, TOTAL_STEPS, "Open the recovery wallet", False)
    session.open_wallet()

    if mode == "create":
        show_progress(7, TOTAL_STEPS, "Build the payment", False)
        session.build_psbt()
        fee = session.check_psbt()
        show_progress(8, TOTAL_STEPS, "Save the payment file", False)
        out_file = f"gallium-recovery-{session.loan_index}.psbt.txt"
        session.write_psbt_file(out_file, fee)
        say(f"Wrote {out_file}")
        say(f"Fee: {fee} BTC. Nothing has been broadcast.")
        say("Send that file to the other party. It contains a partially signed payment, not your private key.")
        return

    show_progress(7, TOTAL_STEPS, "Check the payment", False)
    session.read_psbt_bundle(psbt_file)
    fee = session.check_psbt()
    say(f"Loan index {session.loan_index} on {session.network}")
    say(f"Pay {session.amount} BTC to {session.destination}")
    say(f"Fee: {fee} BTC")
    show_progress(8, TOTAL_STEPS, "Broadcast the payment", False)
    if not confirm("Broadcast this payment"):
        say("Stopped. Nothing was broadcast.")
        return
    txid = session.broadcast()
    say(f"Broadcast transaction {txid}")
    session.finish_regtest()


def main(argv):
    try:
        run(argv)
    except RecoveryError as exc:
        sys.stderr.write(str(exc) + "\n")
        return 1
    finally:
        end_bracketed_paste()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
