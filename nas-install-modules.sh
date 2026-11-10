#!/bin/sh
# nas-install-modules.sh - install the optional kernel modules (iptable_raw,
# ip6table_raw, optionally overlay) on a Synology NAS.
#
# Run without arguments for the guide, or `--help`.
set -eu

REPO="${REPO:-nhymxu/synology-kernelmodules}"
BRANCH="${BRANCH:-nhymxu}"
PLATFORM="${PLATFORM:-}"
KERNEL="${KERNEL:-}"
DSM="${DSM:-}"
LIBDIR="${LIBDIR:-/lib/modules}"
BOOT_SCRIPT="${BOOT_SCRIPT:-/usr/local/etc/rc.d/load-kernel-modules.sh}"
MODULES="iptable_raw ip6table_raw"
ACTION=""
DRY_RUN=0
DO_BOOT=0
DO_LOAD=1
NO_LOAD_EXPLICIT=0
WITH_OVERLAY=0

TMPDIR_ROOT="${TMPDIR:-/tmp}"
WORK=""
STATUS=0

usage() {
    cat <<EOF
nas-install-modules.sh - install the optional kernel modules on a Synology NAS

USAGE
  sudo ./nas-install-modules.sh --install       install and load the modules
  sudo ./nas-install-modules.sh --dry-run       download and verify, change nothing
  ./nas-install-modules.sh                      show this guide

WHAT IT DOES
  1. detects the platform (unique= in /etc.defaults/synoinfo.conf, with fallbacks)
     and the kernel (uname -r, keeping the '+' suffix)
  2. downloads the matching .ko files from ${REPO}@${BRANCH} at
     compiled_modules/dsm<version>/<kernel>/<platform>/
  3. verifies each file against the repo's SHA256SUMS and checks its vermagic
     against the running kernel - any mismatch aborts before anything is
     installed
  4. installs into ${LIBDIR} and loads with insmod

EXAMPLES
  sudo ./nas-install-modules.sh --install
      install and load them now
  sudo ./nas-install-modules.sh --install --boot
      ...and load them again at every boot
  sudo ./nas-install-modules.sh --dry-run
      download and verify only - use this first
  sudo ./nas-install-modules.sh --install --platform broadwellnk
      override platform detection (a DS3622xs+ is broadwellnk)
  sudo ./nas-install-modules.sh --install --with-overlay
      include overlay.ko as well

ACTIONS (exactly one is required)
  --install              download, verify, install into ${LIBDIR}, then insmod
  --dry-run              do everything except install and load
  -h, --help             show this guide

MODIFIERS
  --boot                 also write ${BOOT_SCRIPT}
                         so the modules load at every boot
  --with-overlay         include overlay.ko (absent on Linux 3.10 platforms)
  --no-load              install the files but do not insmod them
  --platform NAME        override platform detection, e.g. broadwellnk
  --kernel VER           override uname -r, e.g. 4.4.302+
  --dsm X.Y              override the DSM source directory, e.g. 7.4
  --repo OWNER/REPO      pull from another fork (default ${REPO})
  --branch NAME          pull from another branch (default ${BRANCH})
  --modules "A B"        choose the modules (default "${MODULES}")

NOTES
  - DSM updates replace /lib/modules: re-run --install after upgrading.
  - Modules load immediately; --boot is what makes them survive a reboot.
  - Full guide, including the manual procedure: INSTALL.md in the repo.

Environment equivalents: REPO, BRANCH, PLATFORM, KERNEL, DSM, LIBDIR.
EOF
    exit "${1:-0}"
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    if [ -n "$WORK" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

check_privileges() {
    [ "$(id -u)" = "0" ] && return 0
    if [ -d "$LIBDIR" ] && [ -w "$LIBDIR" ]; then
        warn "not running as root - installing into $LIBDIR but not loading modules"
        DO_LOAD=0
        return 0
    fi
    die "must run as root (try: sudo $0 --install)"
}

if [ $# -eq 0 ]; then
    usage 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --install)         ACTION=install ;;
        --dry-run)         DRY_RUN=1 ;;
        --boot)            DO_BOOT=1 ;;
        --with-overlay)    WITH_OVERLAY=1 ;;
        --no-load)         DO_LOAD=0; NO_LOAD_EXPLICIT=1 ;;
        --platform)        PLATFORM="${2:?--platform needs a value}"; shift ;;
        --kernel)          KERNEL="${2:?--kernel needs a value}"; shift ;;
        --dsm)             DSM="${2:?--dsm needs a value}"; shift ;;
        --repo)            REPO="${2:?--repo needs a value}"; shift ;;
        --branch)          BRANCH="${2:?--branch needs a value}"; shift ;;
        --modules)         MODULES="${2:?--modules needs a value}"; shift ;;
        -h|--help)         usage 0 ;;
        *)                 die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

if [ "$DRY_RUN" = 1 ]; then
    [ "$ACTION" = "install" ] && warn "--install ignored: this is a dry run"
    ACTION=dryrun
fi

if [ -z "$ACTION" ]; then
    printf 'error: no action given - nothing to do\n\n' >&2
    usage 1
fi

[ "$WITH_OVERLAY" = 1 ] && MODULES="$MODULES overlay"

RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}/compiled_modules"

# ---------------------------------------------------------------- detect host

detect_kernel() {
    [ -n "$KERNEL" ] && return 0
    KERNEL="$(uname -r)"
    [ -n "$KERNEL" ] || die "could not read kernel version from uname -r"
}

# The authoritative platform name lives in the unique= line. Some DSM builds
# return a bare model name from syno_hw_version instead of synology_<platform>_<model>.
detect_platform() {
    [ -n "$PLATFORM" ] && return 0

    for f in /etc.defaults/synoinfo.conf /etc/synoinfo.conf; do
        [ -r "$f" ] || continue
        v=$(sed -n 's/^unique="\([^"]*\)".*/\1/p' "$f" | head -n 1)
        [ -n "$v" ] || continue
        p=$(printf '%s\n' "$v" | sed -n 's/^synology_\([a-z0-9]*\)_.*/\1/p')
        if [ -n "$p" ]; then
            PLATFORM="$p"
            return 0
        fi
    done

    v=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || true)
    p=$(printf '%s\n' "$v" | sed -n 's/^synology_\([a-z0-9]*\)_.*/\1/p')
    if [ -n "$p" ]; then
        PLATFORM="$p"
        return 0
    fi

    # Bare model name (DS3622xs+, DS2422+, ...) - map the common ones.
    if [ -n "$v" ]; then
        p=$(platform_for_model "$v" || true)
        if [ -n "$p" ]; then
            PLATFORM="$p"
            log "note: syno_hw_version reported model '$v' - using platform '$PLATFORM'"
            return 0
        fi
        warn "syno_hw_version reported '$v', which is a model name, not a platform"
    fi

    die "could not detect the platform. Re-run with --platform <name>, e.g. --platform broadwellnk
       Look it up with: grep unique= /etc.defaults/synoinfo.conf"
}

platform_for_model() {
    case "$1" in
        DS918+|DS1019+)                          echo apollolake ;;
        DS920+|DS1520+|DS220+|DS420+|DS720+)     echo geminilake ;;
        DS1621+|DS1821+|DS2422+|RS1221+|RS822+)  echo v1000 ;;
        DS3622xs+|RS3621xs+|RS4021xs+)           echo broadwellnk ;;
        DS3617xs|RS3617xs+)                      echo broadwell ;;
        DS1618+|DS3018xs)                        echo denverton ;;
        RS1619xs+|FS6400|FS3400)                 echo purley ;;
        DS923+|DS1522+|DS723+|RS2423+)           echo r1000 ;;
        DS1823xs+)                               echo v1000nk ;;
        DS1515+|DS1815+|DS415+)                  echo avoton ;;
        DS916+|DS416play|DS216+)                 echo braswell ;;
        *)                                       return 1 ;;
    esac
}

detect_dsm() {
    [ -n "$DSM" ] && return 0
    [ -r /etc/VERSION ] || die "could not read /etc/VERSION; re-run with --dsm X.Y"
    major=$(sed -n 's/^majorversion="\([^"]*\)".*/\1/p' /etc/VERSION | head -n 1)
    minor=$(sed -n 's/^minorversion="\([^"]*\)".*/\1/p' /etc/VERSION | head -n 1)
    [ -n "$major" ] && [ -n "$minor" ] || die "could not parse /etc/VERSION; re-run with --dsm X.Y"
    DSM="${major}.${minor}"
}

# ---------------------------------------------------------------- http helpers

fetch() {
    url="$1"
    out="$2"
    if have curl; then
        curl -fsSL --connect-timeout 15 --retry 2 -o "$out" "$url" 2>/dev/null && return 0
    elif have wget; then
        wget -q -O "$out" "$url" 2>/dev/null && return 0
    fi
    return 1
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | cut -d' ' -f1
    elif have shasum; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif have openssl; then
        openssl dgst -sha256 "$1" | sed 's/^.*= *//'
    else
        return 1
    fi
}

vermagic_of() {
    if have strings; then
        strings "$1" | sed -n 's/^vermagic=//p' | head -n 1
    else
        tr -c '[:print:]' '\n' < "$1" | sed -n 's/^vermagic=//p' | head -n 1
    fi
}

module_loaded() {
    [ -r /proc/modules ] && awk -v m="$1" '$1 == m { found = 1 } END { exit !found }' /proc/modules
}

# ---------------------------------------------------------------- resolve paths

detect_kernel
detect_platform
detect_dsm

log "platform: $PLATFORM"
log "kernel:   $KERNEL"
log "dsm:      $DSM"
[ "$DRY_RUN" = 1 ] || check_privileges

WORK="$(mktemp -d "${TMPDIR_ROOT%/}/nas-install-modules.XXXXXX")" || die "could not create temp dir"

# Prefer the exact DSM build, then fall back to the ones this repo publishes.
DSM_CANDIDATES="$DSM"
case " $DSM " in
    *" 7.4 "*) : ;;
    *) DSM_CANDIDATES="$DSM_CANDIDATES 7.4" ;;
esac
case " $DSM " in
    *" 7.2 "*) : ;;
    *) DSM_CANDIDATES="$DSM_CANDIDATES 7.2" ;;
esac

REL_DIR=""
CHECKSUM_FILE=""
for d in $DSM_CANDIDATES; do
    rel="dsm${d}/${KERNEL}/${PLATFORM}"
    if fetch "$RAW/$rel/iptable_raw.ko" "$WORK/probe.ko"; then
        REL_DIR="$rel"
        [ "$d" = "$DSM" ] || warn "no modules for DSM $DSM - using $d" >&2
        break
    fi
done

checked=""
for d in $DSM_CANDIDATES; do
    checked="$checked dsm${d}/${KERNEL}/${PLATFORM}"
done

if [ -z "$REL_DIR" ]; then
    cat >&2 <<EOF
error: no build found for platform '$PLATFORM', kernel '$KERNEL', DSM '$DSM'.

Checked:$checked

Things to try:
  - Confirm the kernel: uname -r must match exactly, including the '+' suffix.
  - Confirm the platform: grep unique= /etc.defaults/synoinfo.conf
    (a model name such as DS3622xs+ is not a platform; it is broadwellnk)
  - See what this repo builds: python3 discover_platforms.py | jq -r 'keys[]'
EOF
    exit 1
fi

log "source:   ${REPO}@${BRANCH} / ${REL_DIR}"

fetch "$RAW/SHA256SUMS" "$WORK/SHA256SUMS" || die "could not download SHA256SUMS"
CHECKSUM_FILE="$WORK/SHA256SUMS"

# ------------------------------------------------------- download and verify

VERIFIED=""
for m in $MODULES; do
    rel="${REL_DIR}/${m}.ko"
    src="$WORK/${m}.ko"
    if ! fetch "$RAW/$rel" "$src"; then
        if [ "$m" = "overlay" ]; then
            warn "no ${m}.ko for this platform (expected on Linux 3.10) - skipping"
            continue
        fi
        die "could not download $rel"
    fi

    want=$(awk -v p="$rel" '$2 == p { print $1; exit }' "$CHECKSUM_FILE")
    if [ -z "$want" ]; then
        warn "$rel is not listed in SHA256SUMS - skipping checksum verification"
    else
        got=$(sha256_of "$src") || die "no sha256sum/shasum/openssl available to verify $m.ko"
        [ "$want" = "$got" ] || die "checksum mismatch for ${m}.ko
       expected $want
       got      $got
       The download is corrupt or the branch changed. Re-run to retry."
        log "checksum: ${m}.ko ok"
    fi

    vm=$(vermagic_of "$src")
    [ -n "$vm" ] || die "could not read vermagic from ${m}.ko (is it a valid module?)"
    vm_kernel=$(printf '%s\n' "$vm" | awk '{ print $1 }')
    if [ "$vm_kernel" != "$KERNEL" ]; then
        die "kernel mismatch for ${m}.ko
       module vermagic: $vm
       running kernel:  $KERNEL
       Wrong platform or kernel directory - nothing was installed."
    fi
    log "vermagic: ${m}.ko ok (${vm})"
    VERIFIED="$VERIFIED $m"
done

[ -n "$VERIFIED" ] || die "no modules were downloaded"

# ---------------------------------------------------------- install and load

install_file() {
    src="$1"
    dest="$2"
    if install -m 0644 "$src" "$dest" 2>/dev/null; then
        :
    else
        cp "$src" "$dest" || return 1
    fi
    chown root:root "$dest" 2>/dev/null || true
    chmod 0644 "$dest"
}

[ "$DRY_RUN" = 1 ] || [ -d "$LIBDIR" ] || die "$LIBDIR does not exist - is this a DSM system?"

INSTALLED=""
for m in $VERIFIED; do
    dest="${LIBDIR}/${m}.ko"

    if [ "$DRY_RUN" = 1 ]; then
        log "dry-run: would install ${m}.ko -> $dest"
    else
        install_file "$WORK/${m}.ko" "$dest" || die "could not install $dest"
        log "installed: $dest"
    fi
    INSTALLED="$INSTALLED $m"
done

for m in $INSTALLED; do
    [ "$DO_LOAD" = 1 ] || break
    if module_loaded "$m"; then
        log "loaded:    ${m} (already in kernel)"
        continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log "dry-run: would insmod ${LIBDIR}/${m}.ko"
        continue
    fi

    out=$(insmod "${LIBDIR}/${m}.ko" 2>&1) && {
        log "loaded:    ${m}"
        continue
    }
    case "$out" in
        *"File exists"*|*"already"*)
            log "loaded:    ${m} (already in kernel)" ;;
        *)
            warn "insmod ${m}.ko failed: $out"
            STATUS=1 ;;
    esac
done

# ------------------------------------------------------------------- boot task

if [ "$DO_BOOT" = 1 ]; then
    body=""
    for m in $INSTALLED; do
        body="${body}load ${m}
"
    done
    if [ "$DRY_RUN" = 1 ]; then
        log "dry-run: would write $BOOT_SCRIPT"
    else
        cat > "$BOOT_SCRIPT" <<EOF
#!/bin/sh
# Load the optional kernel modules from the module directory at boot.
# Generated by nas-install-modules.sh - safe to edit or delete.
load() {
    [ -f "${LIBDIR}/\$1.ko" ] || return 0
    grep -q "^\$1 " /proc/modules && return 0
    /sbin/insmod "${LIBDIR}/\$1.ko" 2>/dev/null
}
${body}exit 0
EOF
        chmod 0755 "$BOOT_SCRIPT"
        log "boot:      $BOOT_SCRIPT"
    fi
fi

# --------------------------------------------------------------------- report

if [ "$DRY_RUN" = 1 ]; then
    log ""
    log "dry run complete - nothing was installed."
    exit 0
fi

log ""
if [ "$DO_LOAD" = 1 ]; then
    log "modules now loaded:"
elif [ "$NO_LOAD_EXPLICIT" = 1 ]; then
    log "modules installed (not loaded, --no-load):"
else
    log "modules installed (not loaded - re-run as root to load them):"
fi
for m in $INSTALLED; do
    if [ "$DO_LOAD" != 1 ]; then
        log "  $m"
        continue
    fi
    if module_loaded "$m"; then
        log "  $m"
    else
        log "  $m (NOT loaded)"
        STATUS=1
    fi
done

if [ "$DO_BOOT" != 1 ] && [ "$DO_LOAD" = 1 ]; then
    log ""
    log "These load now but will be gone after a reboot. Re-run with --install --boot"
    log "to install $BOOT_SCRIPT, or add the insmod lines to a Task Scheduler"
    log "boot-up task running as root."
fi

exit "$STATUS"
