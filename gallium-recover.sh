#!/usr/bin/env bash
# Mac and Linux entry point. The prompts and progress bar live in gallium_recover.py.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
target="${here}/gallium_recover.py"
release="${here}/python-release.txt"
if [[ ! -f "${target}" ]]; then
  echo "gallium_recover.py was not found next to this script." >&2
  exit 1
fi

python_is_3() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

read_python_release() {
  local system="$1"
  local machine="$2"
  local line sys rest mach file
  PYTHON_VERSION=""
  PYTHON_BASE=""
  PYTHON_FILE=""
  PYTHON_SHA=""
  if [[ ! -f "${release}" ]]; then
    echo "python-release.txt was not found next to this script." >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      version\ *)
        PYTHON_VERSION="${line#version }"
        ;;
      base\ *)
        PYTHON_BASE="${line#base }"
        ;;
      *)
        sys="${line%% *}"
        rest="${line#* }"
        mach="${rest%% *}"
        rest="${rest#* }"
        file="${rest%% *}"
        if [[ "${sys}" == "${system}" && "${mach}" == "${machine}" ]]; then
          PYTHON_FILE="${file}"
          PYTHON_SHA="${rest#* }"
        fi
        ;;
    esac
  done < "${release}"
}

install_python() {
  local system machine dest parent work archive url encoded got
  system="$(uname -s)"
  machine="$(uname -m)"
  read_python_release "${system}" "${machine}"
  if [[ -z "${PYTHON_FILE}" || -z "${PYTHON_SHA}" || -z "${PYTHON_VERSION}" || -z "${PYTHON_BASE}" ]]; then
    echo "Automatic Python install is not available for ${system} ${machine}." >&2
    echo "Install Python 3, then run this script again." >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download Python." >&2
    exit 1
  fi
  echo "Python 3 was not found."
  echo "The script will download Python ${PYTHON_VERSION} into your home folder at .gallium-recovery/python."
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to confirm: Install Python ${PYTHON_VERSION}?" >&2
    exit 1
  fi
  local answer
  read -r -p "Install Python ${PYTHON_VERSION}? [y/N] " answer </dev/tty
  if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
    echo "Stopped. Python was not installed." >&2
    exit 1
  fi
  dest="${HOME}/.gallium-recovery/python"
  parent="$(dirname "${dest}")"
  mkdir -p "${parent}"
  work="$(mktemp -d)"
  archive="${work}/python.tar.gz"
  encoded="${PYTHON_FILE//+/%2B}"
  url="${PYTHON_BASE}/${encoded}"
  echo "Downloading Python ${PYTHON_VERSION}..."
  curl -fL --progress-bar "${url}" -o "${archive}"
  got="$(sha256_of "${archive}")"
  if [[ "${got}" != "${PYTHON_SHA}" ]]; then
    rm -rf "${work}"
    echo "Python download did not match the published checksum." >&2
    exit 1
  fi
  tar -xzf "${archive}" -C "${work}"
  rm -rf "${dest}"
  mv "${work}/python" "${dest}"
  rm -rf "${work}"
  echo "Installed Python ${PYTHON_VERSION}."
}

python=""
if command -v python3 >/dev/null 2>&1 && python_is_3 python3; then
  python="python3"
elif command -v python >/dev/null 2>&1 && python_is_3 python; then
  python="python"
fi
bundled="${HOME}/.gallium-recovery/python/bin/python3"
if [[ -z "${python}" && -x "${bundled}" ]] && python_is_3 "${bundled}"; then
  python="${bundled}"
fi
if [[ -z "${python}" ]]; then
  install_python
  python="${HOME}/.gallium-recovery/python/bin/python3"
fi
if ! python_is_3 "${python}"; then
  echo "Python 3 is still not available." >&2
  exit 1
fi

exec "${python}" "${target}" "$@"
