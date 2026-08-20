#!/usr/bin/env bash
#
# custom-linux-builder.sh
# ------------------------------------------------------------------
# Takes the ISO of any Linux distribution, lets you chroot into it
# to customize it, and repacks your changes into a new ISO.
#
# This improved, backwards-compatible version adds:
# - Simple CLI options for output file, label and workdir.
# - Non-interactive automation support via --run-script.
# - Safer root handling (re-exec with sudo if not root).
# - Better detection when multiple squashfs images exist (picks largest).
# - Bind mounts use --rbind/--make-rslave for more reliable unmounting.
# - Cleanup reliably unmounts and removes temp dirs.
# - Minimal, clear changes only — no extra complexity.
#
# Usage:
#   sudo ./custom-linux-builder.sh /path/to/original.iso [--output out.iso] [--label LABEL] [--workdir ./build]
#   Optional flags:
#     --no-chroot       Don't drop into interactive chroot (useful with --run-script).
#     --run-script PATH Copy and execute PATH inside the chroot (non-interactive customization).
#     --keep-build      Don't remove the build directory after completion.
#     --help            Show this help and exit.
#
# Requirements (on Debian/Ubuntu-based systems):
#   sudo apt install squashfs-tools xorriso rsync file
#
# WARNING: This script performs loop-mount and chroot operations on
# your system. Make sure you understand the code before running it.
# No responsibility is accepted for data loss or system issues.
# ------------------------------------------------------------------

set -euo pipefail

# ============================================================
# DEFAULT CONFIGURATION
# ============================================================
SOURCE_ISO=""                    # Input ISO path (positional or set by --source)
BUILD_DIR="./build"               # Working directory
OUTPUT_ISO="./custom.iso"         # Output ISO file
VOLUME_LABEL="CustomLinux"        # Volume label for the ISO
NO_CHROOT=0                        # If set, skip interactive chroot
RUN_SCRIPT=""                     # Script on host to copy into chroot and run
KEEP_BUILD=0                       # If set, keep build directory after completion

# Tracked so cleanup() can safely unmount them on exit.
ISO_MOUNT_DIR=""
ROOTFS_DIR=""
SQUASHFS_PATH=""

# ============================================================
# HELPER FUNCTIONS (English comments for public use)
# ============================================================

log() {
    echo -e "\n==> $1"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [options] /path/to/original.iso
Options:
  --output PATH     Output ISO (default: $OUTPUT_ISO)
  --label LABEL     Volume label for the ISO (default: $VOLUME_LABEL)
  --workdir DIR     Working directory (default: $BUILD_DIR)
  --no-chroot       Don't drop into interactive chroot (use with --run-script)
  --run-script PATH Copy and execute PATH inside the chroot (non-interactive)
  --keep-build      Keep the build directory after completion
  --help            Show this help and exit

Examples:
  sudo $0 ./ubuntu.iso --output my-custom.iso --label MyUbuntu
  sudo $0 ./arch.iso --run-script ./customize.sh --no-chroot
EOF
    exit 1
}

# Ensure the script runs as root. If not, re-exec using sudo to preserve simplicity.
ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "Re-running with sudo to obtain required privileges..."
        exec sudo bash "$0" "$@"
    fi
}

# Runs no matter how the script exits (success, error, Ctrl+C) and
# safely unmounts anything that might still be mounted.
cleanup() {
    log "Cleaning up..."

    # Unmount mountpoints inside rootfs if set. Use lazy umount to avoid blocking.
    if [ -n "${ROOTFS_DIR:-}" ]; then
        for mp in tmp run dev proc sys; do
            if mountpoint -q "$ROOTFS_DIR/$mp" 2>/dev/null; then
                umount -l "$ROOTFS_DIR/$mp" 2>/dev/null || true
            fi
        done
    fi

    # Unmount the ISO mount dir if set
    if [ -n "${ISO_MOUNT_DIR:-}" ] && mountpoint -q "$ISO_MOUNT_DIR" 2>/dev/null; then
        umount -l "$ISO_MOUNT_DIR" 2>/dev/null || true
    fi

    # Remove temporary iso mount dir if it exists and is empty
    if [ -n "${ISO_MOUNT_DIR:-}" ] && [ -d "$ISO_MOUNT_DIR" ]; then
        rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
    fi

    # Optionally remove build dir unless KEEP_BUILD is set
    if [ "$KEEP_BUILD" -eq 0 ] && [ -n "${BUILD_DIR:-}" ] && [ -d "$BUILD_DIR" ]; then
        # Keep the build directory for inspection if requested
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

check_dependencies() {
    local missing=()
    for cmd in unsquashfs mksquashfs xorriso rsync file; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing commands: ${missing[*]}. Install with 'sudo apt install squashfs-tools xorriso rsync file'."
    fi
}

check_input() {
    [ -n "$SOURCE_ISO" ] || die "Usage: $0 <iso-path>"
    [ -f "$SOURCE_ISO" ] || die "ISO not found: $SOURCE_ISO"
}

# Detect the original compression algorithm of the squashfs using unsquashfs's summary
get_original_comp() {
    local squashfs="$1"
    # unsquashfs -s prints a line like "Compression: xz" on many systems
    unsquashfs -s "$squashfs" 2>/dev/null | awk -F': *' '/Compression/ {print $2; exit}' || true
}

# ============================================================
# 1. EXTRACT THE ISO AND COPY ITS FILES
# ============================================================
extract_iso() {
    log "Extracting ISO..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/iso"

    ISO_MOUNT_DIR="$(mktemp -d)"
    mount -o loop,ro "$SOURCE_ISO" "$ISO_MOUNT_DIR"
    rsync -a "$ISO_MOUNT_DIR/" "$BUILD_DIR/iso/"
    umount -l "$ISO_MOUNT_DIR"
    ISO_MOUNT_DIR=""
}

# ============================================================
# 2. LOCATE AND UNPACK THE SQUASHFS
#    - If multiple squashfs images exist, pick the largest (best-effort)
# ============================================================
extract_rootfs() {
    log "Looking for the root filesystem (squashfs)..."

    # Search common paths quickly first
    local possible_paths=(
        "$BUILD_DIR/iso/casper/filesystem.squashfs"
        "$BUILD_DIR/iso/live/filesystem.squashfs"
        "$BUILD_DIR/iso/LiveOS/squashfs.img"
        "$BUILD_DIR/iso/images/rootfs.img"
        "$BUILD_DIR/iso/rootfs.squashfs"
        "$BUILD_DIR/iso/system.squashfs"
        "$BUILD_DIR/iso/livecd.squashfs"
        "$BUILD_DIR/iso/rootfs.img"
        "$BUILD_DIR/iso/filesystem.squashfs"
    )

    SQUASHFS_PATH=""
    for p in "${possible_paths[@]}"; do
        if [ -f "$p" ]; then
            SQUASHFS_PATH="$p"
            break
        fi
    done

    # If none found, fallback to scanning for common candidate files and pick the largest
    if [ -z "$SQUASHFS_PATH" ]; then
        # find files with names commonly used for squash/root images
        SQUASHFS_PATH=$(find "$BUILD_DIR/iso" -type f \( -iname "*.squashfs" -o -iname "squashfs.img" -o -iname "rootfs.img" -o -iname "filesystem.squashfs" \) -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | awk '{ $1=""; sub(/^ +/,""); print }') || true
    fi

    ROOTFS_DIR="$BUILD_DIR/rootfs"

    if [ -n "$SQUASHFS_PATH" ] && [ -f "$SQUASHFS_PATH" ]; then
        log "Found squashfs/root image: $SQUASHFS_PATH"
        # Verify it's actually a squashfs file
        if file "$SQUASHFS_PATH" | grep -qi squashfs; then
            mkdir -p "$ROOTFS_DIR"
            unsquashfs -d "$ROOTFS_DIR" "$SQUASHFS_PATH"
        else
            # Not a squashfs — fallback to copying ISO contents into rootfs
            log "Found image does not appear to be a squashfs; using a file copy fallback."
            mkdir -p "$ROOTFS_DIR"
            rsync -a "$BUILD_DIR/iso/" "$ROOTFS_DIR/"
            SQUASHFS_PATH=""
        fi
    else
        log "No squashfs found, using the ISO contents directly."
        mkdir -p "$ROOTFS_DIR"
        rsync -a "$BUILD_DIR/iso/" "$ROOTFS_DIR/"
    fi
}

# ============================================================
# 3. PREPARE THE CHROOT ENVIRONMENT
#    - Use recursive bind mounts and make mounts rslave to avoid mount propagation issues
# ============================================================
enter_chroot() {
    log "Preparing chroot environment..."

    mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run" "$ROOTFS_DIR/tmp"

    mount --rbind /dev "$ROOTFS_DIR/dev"
    mount --rbind /proc "$ROOTFS_DIR/proc"
    mount --rbind /sys "$ROOTFS_DIR/sys"
    mount --rbind /run "$ROOTFS_DIR/run"
    mount --rbind /tmp "$ROOTFS_DIR/tmp"

    # Prevent mounts from propagating back to the host
    mount --make-rslave "$ROOTFS_DIR/dev" || true
    mount --make-rslave "$ROOTFS_DIR/proc" || true
    mount --make-rslave "$ROOTFS_DIR/sys" || true
    mount --make-rslave "$ROOTFS_DIR/run" || true
    mount --make-rslave "$ROOTFS_DIR/tmp" || true

    if [ "$NO_CHROOT" -eq 1 ]; then
        if [ -n "$RUN_SCRIPT" ]; then
            log "Running non-interactive script inside chroot: $RUN_SCRIPT"
            # Copy the script into the chroot and run it
            cp "$RUN_SCRIPT" "$ROOTFS_DIR/tmp/customizer.sh"
            chmod +x "$ROOTFS_DIR/tmp/customizer.sh"
            chroot "$ROOTFS_DIR" /bin/bash -c "/tmp/customizer.sh; rm -f /tmp/customizer.sh" || true
        else
            log "--no-chroot specified but no --run-script provided; skipping interactive chroot."
        fi
    else
        log "Entering interactive chroot. Type 'exit' to leave."
        chroot "$ROOTFS_DIR" /bin/bash || true
    fi

    # Unmount in reverse order (lazy unmount)
    umount -l "$ROOTFS_DIR/tmp" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
}

# ============================================================
# 4. REPACK THE MODIFIED ROOT FILESYSTEM
#    - If we had a squashfs originally, try to detect compression and reuse it
#    - Otherwise copy files back into ISO folder
# ============================================================
repack_rootfs() {
    if [ -n "$SQUASHFS_PATH" ]; then
        log "Rebuilding squashfs..."

        local comp
        comp="$(get_original_comp "$SQUASHFS_PATH" || true)"

        if [ -z "$comp" ]; then
            comp="gzip"
            log "Could not detect original compression, using gzip as fallback."
        else
            log "Detected compression: $comp"
            # Verify that the current mksquashfs supports this algorithm
            if ! mksquashfs -version 2>/dev/null | grep -qi "$comp" && ! mksquashfs -help 2>/dev/null | grep -qi "$comp"; then
                log "WARNING: $comp may not be supported by this mksquashfs. Falling back to gzip."
                comp="gzip"
            fi
        fi

        tmp_out="$SQUASHFS_PATH.new"
        mksquashfs "$ROOTFS_DIR" "$tmp_out" -comp "$comp" -noappend -root-owned -all-root >/dev/null 2>&1 || mksquashfs "$ROOTFS_DIR" "$tmp_out" -comp "$comp" -noappend
        mv -f "$tmp_out" "$SQUASHFS_PATH"
    else
        log "Copying changes back into the ISO folder..."
        rsync -a --delete "$ROOTFS_DIR/" "$BUILD_DIR/iso/"
    fi
}

# ============================================================
# 5. BUILD THE NEW ISO
# ============================================================
build_iso() {
    log "Reading the original ISO's boot configuration..."
    local boot_opts_file="$BUILD_DIR/boot_opts.txt"
    xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null | grep '^-' | grep -v "^-V " > "$boot_opts_file" || true

    log "Building new ISO: $OUTPUT_ISO"
    if [ -s "$boot_opts_file" ]; then
        log "Reproducing the original boot record (BIOS/UEFI as applicable)"
        local esc_label
        printf -v esc_label '%q' "$VOLUME_LABEL"
        # shellcheck disable=SC2046,SC2086
        eval xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$esc_label" -r -J "$(tr '\n' ' ' < "$boot_opts_file")" "$BUILD_DIR/iso/"
    else
        log "Source ISO has no El Torito boot record; building a data-only ISO"
        xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$VOLUME_LABEL" -r -J "$BUILD_DIR/iso/"
    fi

    # If script was run under sudo, set file owner back to the original user
    if [ -n "${SUDO_USER:-}" ]; then
        chown "${SUDO_USER}" "$OUTPUT_ISO" || true
    fi
    log "Done: $OUTPUT_ISO"
}

# ============================================================
# MAIN FLOW
# ============================================================
main() {
    # Parse simple CLI options
    if [ "$#" -eq 0 ]; then
        usage
    fi

    # Temporary array handling for options (POSIX-friendly)
    args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output)
                OUTPUT_ISO="$2"; shift 2;;
            --label)
                VOLUME_LABEL="$2"; shift 2;;
            --workdir)
                BUILD_DIR="$2"; shift 2;;
            --no-chroot)
                NO_CHROOT=1; shift;;
            --run-script)
                RUN_SCRIPT="$2"; shift 2;;
            --keep-build)
                KEEP_BUILD=1; shift;;
            --help)
                usage; shift;;
            --*)
                die "Unknown option: $1";;
            *)
                # first non-option argument is SOURCE_ISO
                if [ -z "$SOURCE_ISO" ]; then
                    SOURCE_ISO="$1"
                else
                    args+=("$1")
                fi
                shift;;
        esac
    done

    ensure_root "$@"

    check_dependencies
    check_input

    extract_iso
    extract_rootfs
    enter_chroot
    repack_rootfs
    build_iso

    log "All done."
}

main "$@"
