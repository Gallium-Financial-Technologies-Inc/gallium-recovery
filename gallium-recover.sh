#!/usr/bin/env bash
# Spend a Gallium escrow with the bank and borrower recovery packages.
# Bitcoin Core 27 or newer must be able to see the chain that holds the funds.
#
#   ./gallium-recover.sh
#
# The script asks for the bank package, the borrower package, and the
# address that should receive the funds.
#
# For the hosted regtest, SSH to that machine first, then run this script.
# Mainnet uses the same command on the computer that runs your node.
#
# Optional, when bitcoin-cli cannot use the node's default cookie:
#   BITCOIN_RPC_HOST BITCOIN_RPC_PORT BITCOIN_RPC_USER BITCOIN_RPC_PASSWORD

set -euo pipefail

SCRIPT_VERSION="1.1.1"
CORE_VERSION="27.1"
CORE_MAJOR=27
INSTALL_ROOT="${HOME}/.gallium-recovery/bitcoin-core-${CORE_VERSION}"

usage() {
  echo "Usage: ./gallium-recover.sh" >&2
  echo "The script asks for the bank package, the borrower package, and the destination address." >&2
  exit 1
}

prompt_line() {
  local label="$1"
  local answer=""
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to enter ${label}." >&2
    exit 1
  fi
  while [[ -z "${answer}" ]]; do
    read -r -p "${label}: " answer </dev/tty
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
  done
  printf '%s' "${answer}"
}

confirm() {
  local prompt="$1"
  local answer
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to confirm: ${prompt}" >&2
    exit 1
  fi
  read -r -p "${prompt} [y/N] " answer </dev/tty
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

field_value() {
  local file="$1"
  local label="$2"
  sed -n "s/^${label}: //p" "${file}" | head -n 1
}

next_line() {
  local file="$1"
  local label="$2"
  awk -v label="${label}" '$0 == label { getline; print; exit }' "${file}"
}

extended_key() {
  local expression="$1"
  local rest="${expression#*]}"
  printf '%s' "${rest%%/*}"
}

replace_once() {
  local input="$1"
  local old="$2"
  local new="$3"
  local first after
  case "${input}" in
    *"${old}"*) ;;
    *)
      echo "Recovery descriptor is missing a party key." >&2
      exit 1
      ;;
  esac
  first="${input%%"${old}"*}"
  after="${input#*"${old}"}"
  case "${after}" in
    *"${old}"*)
      echo "Recovery descriptor contains a party key more than once." >&2
      exit 1
      ;;
  esac
  printf '%s%s%s' "${first}" "${new}" "${after}"
}

replace_all() {
  local input="$1"
  local old="$2"
  local new="$3"
  local out=""
  while [[ "${input}" == *"${old}"* ]]; do
    out="${out}${input%%"${old}"*}${new}"
    input="${input#*"${old}"}"
  done
  printf '%s%s' "${out}" "${input}"
}

load_package() {
  local file="$1"
  local prefix="$2"
  local role loan network address descriptor expression xprv xpub
  role="$(field_value "${file}" "Role")"
  loan="$(field_value "${file}" "Loan")"
  network="$(field_value "${file}" "Network")"
  address="$(field_value "${file}" "Deposit address")"
  descriptor="$(next_line "${file}" "Public descriptor:")"
  expression="$(next_line "${file}" "Your key expression:")"
  xprv="$(next_line "${file}" "Your loan extended private key:")"
  xpub="$(extended_key "${expression}")"
  if [[ -z "${role}" || -z "${loan}" || -z "${network}" || -z "${address}" || -z "${descriptor}" || -z "${xprv}" || -z "${xpub}" ]]; then
    echo "Could not read a Gallium recovery package: ${file}" >&2
    exit 1
  fi
  printf -v "${prefix}_role" '%s' "${role}"
  printf -v "${prefix}_loan" '%s' "${loan}"
  printf -v "${prefix}_network" '%s' "${network}"
  printf -v "${prefix}_address" '%s' "${address}"
  printf -v "${prefix}_descriptor" '%s' "${descriptor}"
  printf -v "${prefix}_xprv" '%s' "${xprv}"
  printf -v "${prefix}_xpub" '%s' "${xpub}"
}

core_archive() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Linux:x86_64)
      ARCHIVE="bitcoin-${CORE_VERSION}-x86_64-linux-gnu.tar.gz"
      SHA256="c9840607d230d65f6938b81deaec0b98fe9cb14c3a41a5b13b2c05d044a48422"
      ;;
    Linux:aarch64)
      ARCHIVE="bitcoin-${CORE_VERSION}-aarch64-linux-gnu.tar.gz"
      SHA256="bb878df4f8ff8fb8acfb94207c50f959c462c39e652f507c2a2db20acc6a1eee"
      ;;
    Darwin:arm64)
      ARCHIVE="bitcoin-${CORE_VERSION}-arm64-apple-darwin.tar.gz"
      SHA256="ad4a3fd484077224a82dd56d194efb6e614467f413ab1dfb8776da4d08a4c227"
      ;;
    Darwin:x86_64)
      ARCHIVE="bitcoin-${CORE_VERSION}-x86_64-apple-darwin.tar.gz"
      SHA256="6d94bde5541a18964c1c36b0f12334004e45e195f244e381fd459827b1fdc395"
      ;;
    *)
      echo "Automatic Bitcoin Core install is not available for ${os} ${arch}." >&2
      echo "Install Bitcoin Core ${CORE_VERSION} or newer, then run this script again." >&2
      exit 1
      ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

install_core() {
  local archive sha work url
  core_archive
  archive="${ARCHIVE}"
  sha="${SHA256}"
  work="$(mktemp -d)"
  url="https://bitcoincore.org/bin/bitcoin-core-${CORE_VERSION}/${archive}"
  echo "Downloading Bitcoin Core ${CORE_VERSION}..."
  curl -fsSL "${url}" -o "${work}/${archive}"
  if [[ "$(sha256_of "${work}/${archive}")" != "${sha}" ]]; then
    echo "Bitcoin Core download did not match the published checksum." >&2
    rm -rf "${work}"
    exit 1
  fi
  tar -xzf "${work}/${archive}" -C "${work}"
  mkdir -p "${INSTALL_ROOT}"
  rm -rf "${INSTALL_ROOT}/bin"
  mv "${work}/bitcoin-${CORE_VERSION}/bin" "${INSTALL_ROOT}/bin"
  rm -rf "${work}"
  BITCOIN_CLI="${INSTALL_ROOT}/bin/bitcoin-cli"
  echo "Installed Bitcoin Core ${CORE_VERSION} at ${INSTALL_ROOT}."
}

core_major() {
  local line
  line="$("${BITCOIN_CLI}" -version 2>/dev/null | head -n 1 || true)"
  sed -n 's/.* v\([0-9][0-9]*\)\..*/\1/p' <<<"${line}" | head -n 1
}

ensure_core() {
  local major=""
  if [[ -x "${BITCOIN_CLI}" ]]; then
    major="$(core_major)"
  elif command -v bitcoin-cli >/dev/null 2>&1; then
    BITCOIN_CLI="$(command -v bitcoin-cli)"
    major="$(core_major)"
  fi
  if [[ -n "${major}" && "${major}" -ge "${CORE_MAJOR}" ]]; then
    return
  fi
  if [[ -z "${major}" ]]; then
    confirm "Bitcoin Core is not installed. Install ${CORE_VERSION} from bitcoincore.org?" || exit 1
  else
    confirm "Bitcoin Core ${major} is older than ${CORE_MAJOR}. Install ${CORE_VERSION}?" || exit 1
  fi
  install_core
  major="$(core_major)"
  if [[ -z "${major}" || "${major}" -lt "${CORE_MAJOR}" ]]; then
    echo "Bitcoin Core ${CORE_VERSION} is still not available." >&2
    exit 1
  fi
}

bitcoin_cli() {
  local args=()
  if [[ "${NETWORK}" != "mainnet" ]]; then
    args+=("-${NETWORK}")
  fi
  if [[ -n "${BITCOIN_RPC_HOST:-}" ]]; then
    args+=("-rpcconnect=${BITCOIN_RPC_HOST}")
  fi
  if [[ -n "${BITCOIN_RPC_PORT:-}" ]]; then
    args+=("-rpcport=${BITCOIN_RPC_PORT}")
  fi
  if [[ -n "${BITCOIN_RPC_USER:-}" ]]; then
    args+=("-rpcuser=${BITCOIN_RPC_USER}")
  fi
  if [[ -n "${BITCOIN_RPC_PASSWORD:-}" ]]; then
    args+=("-rpcpassword=${BITCOIN_RPC_PASSWORD}")
  fi
  "${BITCOIN_CLI}" "${args[@]}" "$@"
}

checksum_for() {
  local info sum
  if ! info="$(bitcoin_cli getdescriptorinfo "$1" 2>&1)"; then
    echo "${info}" >&2
    echo "Start Bitcoin Core on the ${NETWORK} network, then run this script again." >&2
    if [[ "${NETWORK}" == "regtest" ]]; then
      echo "On the hosted regtest machine, set BITCOIN_RPC_USER and BITCOIN_RPC_PASSWORD for that node." >&2
    fi
    exit 1
  fi
  sum="$(sed -n 's/.*"checksum": "\([^"]*\)".*/\1/p' <<<"${info}" | head -n 1)"
  if [[ -z "${sum}" ]]; then
    echo "Bitcoin Core did not return a descriptor checksum." >&2
    echo "Start Bitcoin Core on the ${NETWORK} network, then run this script again." >&2
    if [[ "${NETWORK}" == "regtest" ]]; then
      echo "On the hosted regtest machine, set BITCOIN_RPC_USER and BITCOIN_RPC_PASSWORD for that node." >&2
    fi
    exit 1
  fi
  printf '%s' "${sum}"
}

prepare_descriptor() {
  local private_descriptor
  private_descriptor="$(replace_once "${LEFT_descriptor}" "${LEFT_xpub}" "${LEFT_xprv}")"
  private_descriptor="$(replace_once "${private_descriptor}" "${RIGHT_xpub}" "${RIGHT_xprv}")"
  case "${private_descriptor}" in
    *"/<0;1>/"*) ;;
    *)
      echo "Recovery descriptor is missing its receive and change branches." >&2
      exit 1
      ;;
  esac
  EXTERNAL="$(replace_all "${private_descriptor}" "/<0;1>/*" "/0/*")"
  CHANGE="$(replace_all "${private_descriptor}" "/<0;1>/*" "/1/*")"
}

self_test() {
  local dir left right descriptor
  dir="$(mktemp -d)"
  descriptor='wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/<0;1>/*,[bb/7]tpubBank/<0;1>/*,[cc/7]tpubBorrower/<0;1>/*))'
  cat >"${dir}/bank.txt" <<EOF
Role: Bank
Loan: LN-1
Network: regtest
Deposit address: bcrt1qexample
Your loan extended private key:
tprvBank
Your key expression:
[bb/7]tpubBank/<0;1>/*
Public descriptor:
${descriptor}
EOF
  cat >"${dir}/borrower.txt" <<EOF
Role: Borrower
Loan: LN-1
Network: regtest
Deposit address: bcrt1qexample
Your loan extended private key:
tprvBorrower
Your key expression:
[cc/7]tpubBorrower/<0;1>/*
Public descriptor:
${descriptor}
EOF
  load_package "${dir}/bank.txt" LEFT
  load_package "${dir}/borrower.txt" RIGHT
  prepare_descriptor
  [[ "${EXTERNAL}" == *tprvBank* ]]
  [[ "${EXTERNAL}" == *tprvBorrower* ]]
  [[ "${EXTERNAL}" == *tpubGallium* ]]
  [[ "${EXTERNAL}" != *tpubBank* ]]
  [[ "${EXTERNAL}" != *"/<0;1>/"* ]]
  [[ "${EXTERNAL}" == *"/0/"* ]]
  [[ "${CHANGE}" == *"/1/"* ]]
  rm -rf "${dir}"
  echo "self-test ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if [[ "$#" -ne 0 ]]; then
  usage
fi

echo "gallium-recover.sh ${SCRIPT_VERSION}"
echo "Enter the file path of each downloaded recovery package, then the address that should receive the funds."
echo "Example path: ~/Downloads/gallium-recovery-bank.txt"
LEFT_FILE="$(prompt_line "Path to the bank recovery package file")"
RIGHT_FILE="$(prompt_line "Path to the borrower recovery package file")"
DESTINATION="$(prompt_line "Bitcoin address to receive the funds")"
LEFT_FILE="${LEFT_FILE/#\~/${HOME}}"
RIGHT_FILE="${RIGHT_FILE/#\~/${HOME}}"
BITCOIN_CLI="${BITCOIN_CLI:-}"

if [[ ! -f "${LEFT_FILE}" || ! -f "${RIGHT_FILE}" ]]; then
  echo "No file was found at one of those paths. Enter the full path to each recovery package file." >&2
  usage
fi
if [[ "${DESTINATION}" == *" "* || "${DESTINATION}" == *'"'* || -z "${DESTINATION}" ]]; then
  echo "Destination address is invalid." >&2
  exit 1
fi

load_package "${LEFT_FILE}" LEFT
load_package "${RIGHT_FILE}" RIGHT

if [[ "${LEFT_role}" == "${RIGHT_role}" ]]; then
  echo "Provide one bank package and one borrower package." >&2
  exit 1
fi
if [[ "${LEFT_role}" != "Bank" && "${LEFT_role}" != "Borrower" ]]; then
  echo "Unrecognized package role: ${LEFT_role}" >&2
  exit 1
fi
if [[ "${RIGHT_role}" != "Bank" && "${RIGHT_role}" != "Borrower" ]]; then
  echo "Unrecognized package role: ${RIGHT_role}" >&2
  exit 1
fi
if [[ "${LEFT_loan}" != "${RIGHT_loan}" || "${LEFT_network}" != "${RIGHT_network}" || "${LEFT_descriptor}" != "${RIGHT_descriptor}" || "${LEFT_address}" != "${RIGHT_address}" ]]; then
  echo "These recovery packages are not for the same loan." >&2
  exit 1
fi

NETWORK="${LEFT_network}"
case "${NETWORK}" in
  mainnet | testnet | signet | regtest) ;;
  *)
    echo "Unsupported Bitcoin network: ${NETWORK}" >&2
    exit 1
    ;;
esac

prepare_descriptor
ensure_core

EXTERNAL_SUM="$(checksum_for "${EXTERNAL}")"
CHANGE_SUM="$(checksum_for "${CHANGE}")"
EXTERNAL_CHECKED="${EXTERNAL}#${EXTERNAL_SUM}"
CHANGE_CHECKED="${CHANGE}#${CHANGE_SUM}"

WALLET="gallium-recovery-$(printf '%s' "${LEFT_loan}" | tr -c 'A-Za-z0-9._-' '-')"
if ! bitcoin_cli -named createwallet "wallet_name=${WALLET}" blank=true descriptors=true >/dev/null 2>&1; then
  bitcoin_cli loadwallet "${WALLET}" >/dev/null
fi

IMPORT="$(bitcoin_cli -rpcwallet="${WALLET}" importdescriptors "[{\"desc\":\"${EXTERNAL_CHECKED}\",\"active\":false,\"internal\":false,\"range\":[0,0],\"timestamp\":0},{\"desc\":\"${CHANGE_CHECKED}\",\"active\":false,\"internal\":true,\"range\":[0,0],\"timestamp\":0}]")"
SUCCESS_COUNT="$(printf '%s' "${IMPORT}" | grep -o '"success": true\|"success":true' | wc -l | tr -d ' ')"
if [[ "${SUCCESS_COUNT}" != "2" ]]; then
  echo "Bitcoin Core rejected the recovery descriptors." >&2
  echo "${IMPORT}" >&2
  exit 1
fi

BALANCE="$(bitcoin_cli -rpcwallet="${WALLET}" getbalance)"
if ! awk -v balance="${BALANCE}" 'BEGIN { exit !(balance + 0 > 0) }'; then
  echo "Imported the escrow, and it has no spendable balance yet." >&2
  echo "Deposit address: ${LEFT_address}" >&2
  exit 1
fi

echo "Loan ${LEFT_loan} on ${NETWORK}"
echo "Sending ${BALANCE} BTC to ${DESTINATION}"
bitcoin_cli -rpcwallet="${WALLET}" sendall "[\"${DESTINATION}\"]"
