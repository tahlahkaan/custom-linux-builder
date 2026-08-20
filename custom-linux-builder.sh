#!/usr/bin/env bash
#
# custom-linux-builder.sh
# ------------------------------------------------------------------
# A combined, feature-rich script to customize live/install ISOs.
# Features merged from prior versions:
# - CLI options: --output, --label, --workdir, --run-script, --no-chroot, --keep-build
# - Re-exec with sudo when necessary
# - EROFS and SquashFS support, including preservation of original SquashFS compression
# - Detects nested rootfs images (rootfs.img) and mounts them read-write
# - Safer bind mounts with --rbind and --make-rslave for reliable unmounting
# - Optional automatic wallpaper installation for GNOME/XFCE/KDE notes
# - Non-interactive automation via --run-script or interactive chroot
# - Rebuilds ISO preserving original El Torito boot record (BIOS/UEFI/hybrid)
# - SHA256 checksum generation for output ISO
#
# Usage examples:
#   sudo ./custom-linux-builder.sh /path/to/source.iso --output ./custom.iso --label MyLabel
#   sudo ./custom-linux-builder.sh /path/to/source.iso --output ./out.iso --run-script ./customize.sh
#
set -euo pipefail

# --------------------- DEFAULT CONFIG ----------------------------
SOURCE_ISO=""
BUILD_DIR="./build"
OUTPUT_ISO=""
VOLUME_LABEL="CustomLinux"
NO_CHROOT=1
RUN_SCRIPT=""
KEEP_BUILD=1
CUSTOM_WALLPAPER=""  # optional wallpaper on host to copy into image

# Global state for cleanup
ISO_MOUNT_DIR=""
EXTRACTED_DIR=""
ROOTFS_DIR=""
NESTED_LOOP_DEV=""
IMAGE_PATH=""
IMAGE_FORMAT=""  # squashfs or erofs
LAYOUT_NAME=""
CHROOT_MOUNTS_ACTIVE=0
RESOLV_CONF_BACKED_UP=0

# --------------------- LOGGING / HELPERS -------------------------
log() { echo -e "\n==> $1"; }
warn() { echo "WARNING: $1" >&2; }
die() { echo "ERROR: $1" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [options] /path/to/original.iso
Options:
  --output PATH     Output ISO (required)
  --label LABEL     Volume label for the ISO (default: $VOLUME_LABEL)
  --workdir DIR     Working directory (default: $BUILD_DIR)
  --no-chroot       Don't drop into interactive chroot (default)
  --run-script PATH Copy and execute PATH inside the chroot (non-interactive)
  --keep-build      Keep the build directory after completion (default)
  --wallpaper PATH  Install this image as default wallpaper (best-effort)
  --help            Show this help and exit

Examples:
  sudo $0 ./ubuntu.iso --output ./my-ubuntu-custom.iso --label MyUbuntu
  sudo $0 ./arch.iso --output ./arch-custom.iso --run-script ./customize.sh
EOF
    exit 1
}

# Ensure running as root; if not, re-exec with sudo preserving args
ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "Re-running with sudo to obtain required privileges..."
        exec sudo bash "$0" "$@"
    fi
}

# --------------------- CLEANUP ----------------------------------
cleanup() {
    log "Cleaning up..."

    if [ "$CHROOT_MOUNTS_ACTIVE" = "1" ] && [ -n "$ROOTFS_DIR" ]; then
        restore_resolv_conf || true
        for d in run/systemd/resolve run dev/pts dev proc sys run tmp; do
            if mountpoint -q "$ROOTFS_DIR/$d" 2>/dev/null; then
                umount -l "$ROOTFS_DIR/$d" 2>/dev/null || warn "Could not unmount $ROOTFS_DIR/$d"
            fi
        done
        CHROOT_MOUNTS_ACTIVE=0
    fi

    if [ -n "$NESTED_LOOP_DEV" ]; then
        if mountpoint -q "$ROOTFS_DIR" 2>/dev/null; then
            umount -l "$ROOTFS_DIR" 2>/dev/null || warn "Could not unmount nested image at $ROOTFS_DIR"
        fi
        losetup -d "$NESTED_LOOP_DEV" 2>/dev/null || warn "Could not detach loop device $NESTED_LOOP_DEV"
        NESTED_LOOP_DEV=""
    fi

    if [ -n "$ISO_MOUNT_DIR" ] && mountpoint -q "$ISO_MOUNT_DIR" 2>/dev/null; then
        umount -l "$ISO_MOUNT_DIR" 2>/dev/null || warn "Could not unmount $ISO_MOUNT_DIR"
    fi
    if [ -n "$ISO_MOUNT_DIR" ] && [ -d "$ISO_MOUNT_DIR" ]; then
        rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
    fi

    if [ "$KEEP_BUILD" -eq 0 ] && [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --------------------- DEPENDENCIES / INPUT ----------------------
check_dependencies() {
    local missing=()
    for cmd in unsquashfs mksquashfs xorriso rsync file losetup mountpoint find grep awk sed chroot; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required commands: ${missing[*]}. Install with: sudo apt install squashfs-tools xorriso rsync file util-linux"
    fi
}

check_input() {
    [ -n "$SOURCE_ISO" ] || die "Usage: $0 <iso-path> --output /path/to/output.iso"
    [ -f "$SOURCE_ISO" ] || die "ISO not found: $SOURCE_ISO"
    [ -n "$OUTPUT_ISO" ] || die "You must provide an output ISO filename with --output /path/to/output.iso"
}

# --------------------- UTIL --------------------------------------
get_original_comp() {
    local squashfs="$1"
    unsquashfs -s "$squashfs" 2>/dev/null | awk -F': *' '/Compression/ {print $2; exit}' || true
}

# --------------------- STEP 1: EXTRACT ISO ----------------------
extract_iso() {
    log "Extracting ISO file tree..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/iso"

    ISO_MOUNT_DIR="$(mktemp -d)"
    mount -o loop,ro "$SOURCE_ISO" "$ISO_MOUNT_DIR"
    rsync -aHAX "$ISO_MOUNT_DIR/" "$BUILD_DIR/iso/"
    umount -l "$ISO_MOUNT_DIR"
    rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
    ISO_MOUNT_DIR=""
}

# --------------------- STEP 2: DETECT ROOT IMAGE -----------------
detect_root_image() {
    log "Detecting ISO layout..."
    local iso_root="$BUILD_DIR/iso"
    local candidate=""

    # Known distro paths (priority)
    for p in "casper/filesystem.squashfs" "live/filesystem.squashfs" "filesystem.squashfs" "live/filesystem.squashfs"; do
        if [ -f "$iso_root/$p" ]; then candidate="$iso_root/$p"; LAYOUT_NAME="Debian/Ubuntu (casper/live-boot)"; break; fi
    done

    if [ -z "$candidate" ]; then
        for p in "LiveOS/squashfs.img" "LiveOS/rootfs.img"; do
            if [ -f "$iso_root/$p" ]; then candidate="$iso_root/$p"; LAYOUT_NAME="dracut LiveOS (Fedora/RHEL-family)"; break; fi
        done
    fi

    if [ -z "$candidate" ]; then
        candidate="$(find "$iso_root/arch" -maxdepth 2 -type f -name "airootfs.sfs" -print -quit 2>/dev/null || true)"
        [ -n "$candidate" ] && LAYOUT_NAME="Arch Linux (archiso) or derivative"
    fi

    if [ -z "$candidate" ] && [ -f "$iso_root/image.squashfs" ]; then
        candidate="$iso_root/image.squashfs"; LAYOUT_NAME="Gentoo (minimal)"
    fi

    if [ -z "$candidate" ] && [ -f "$iso_root/nix-store.squashfs" ]; then
        candidate="$iso_root/nix-store.squashfs"; LAYOUT_NAME="NixOS"
        warn "NixOS detected. Package-manager changes inside chroot may not behave as expected."
    fi

    # Generic scan by magic if still not found — collect squashfs/erofs candidates and pick largest
    if [ -z "$candidate" ]; then
        warn "No known layout matched. Falling back to generic scan."
        mapfile -t found < <(find "$iso_root" -maxdepth 4 -type f \( -iname "*.squashfs" -o -iname "*.img" -o -iname "*.sfs" -o -iname "*.erofs" \) -print 2>/dev/null || true)
        if [ ${#found[@]} -eq 1 ]; then
            candidate="${found[0]}"; LAYOUT_NAME="Generic (auto-detected)"
        elif [ ${#found[@]} -gt 1 ]; then
            # pick largest file as best-effort; avoid guessing if multiples similar
            IFS=$'\n' sorted=( $(printf "%s\n" "${found[@]}" | xargs -I{} stat -c "%s %n" {} 2>/dev/null | sort -n -r) )
            candidate="$(echo "${sorted[0]}" | awk '{ $1=""; print substr($0,2) }')"
            LAYOUT_NAME="Generic (largest candidate picked)"
            warn "Multiple candidates found; picked the largest: $candidate"
        fi
    fi

    [ -n "$candidate" ] || die "Unsupported ISO layout: no recognizable root filesystem image found."

    IMAGE_PATH="$candidate"
    case "$(file -b --mime-type "$IMAGE_PATH")" in
        application/x-squashfs) IMAGE_FORMAT="squashfs" ;;
        application/x-erofs*|application/x-ecryptfs) IMAGE_FORMAT="erofs" ;;
        *)
            # file -b sometimes returns plain text; fallback to 'file -b' match
            case "$(file -b "$IMAGE_PATH")" in
                Squashfs*) IMAGE_FORMAT="squashfs" ;;
                EROFS*) IMAGE_FORMAT="erofs" ;;
                *) IMAGE_FORMAT="unknown" ;;
            esac
            ;;
    esac

    if [ "$IMAGE_FORMAT" = "unknown" ]; then
        warn "Could not determine image format by mime-type; attempting content-based detection..."
        case "$(file -b "$IMAGE_PATH")" in
            Squashfs*) IMAGE_FORMAT="squashfs" ;;
            EROFS*) IMAGE_FORMAT="erofs" ;;
            *) die "Detected image '$IMAGE_PATH' is neither SquashFS nor EROFS ($(file -b "$IMAGE_PATH")). Unsupported format." ;;
        esac
    fi

    log "Layout: $LAYOUT_NAME | Image: $IMAGE_PATH | Format: $IMAGE_FORMAT"
}

# --------------------- STEP 3: EXTRACT ROOT IMAGE ----------------
extract_root_image() {
    EXTRACTED_DIR="$BUILD_DIR/extracted"
    rm -rf "$EXTRACTED_DIR"
    mkdir -p "$EXTRACTED_DIR"

    if [ "$IMAGE_FORMAT" = "squashfs" ]; then
        log "Unpacking SquashFS image..."
        unsquashfs -d "$EXTRACTED_DIR" "$IMAGE_PATH"
    else
        command -v fsck.erofs >/dev/null 2>&1 || die "This ISO uses EROFS, but 'erofs-utils' is not installed. Install: sudo apt install erofs-utils"
        log "Unpacking EROFS image..."
        fsck.erofs --extract="$EXTRACTED_DIR" "$IMAGE_PATH"
    fi
}

# --------------------- STEP 4: NESTED IMAGE DETECTION -------------
detect_and_mount_nested() {
    # Some distros wrap the real root in a nested filesystem image like rootfs.img
    local nested=""
    if [ -f "$EXTRACTED_DIR/rootfs.img" ]; then
        nested="$EXTRACTED_DIR/rootfs.img"
    else
        mapfile -t imgs < <(find "$EXTRACTED_DIR" -maxdepth 1 -type f -iname "*.img" -print 2>/dev/null || true)
        if [ ${#imgs[@]} -eq 1 ]; then
            nested="${imgs[0]}"
        elif [ ${#imgs[@]} -gt 1 ]; then
            warn "Multiple nested images found and none named rootfs.img (${imgs[*]}); using outer extraction as rootfs."
        fi
    fi

    if [ -z "$nested" ]; then
        ROOTFS_DIR="$EXTRACTED_DIR"
        return
    fi

    case "$(file -b "$nested")" in
        *ext2*|*ext3*|*ext4*|*XFS*|*Btrfs*)
            log "Nested root filesystem image found: $nested"
            NESTED_LOOP_DEV="$(losetup --show -f "$nested")"
            ROOTFS_DIR="$BUILD_DIR/rootfs"
            mkdir -p "$ROOTFS_DIR"
            mount "$NESTED_LOOP_DEV" "$ROOTFS_DIR"
            ;;
        *)
            ROOTFS_DIR="$EXTRACTED_DIR"
            ;;
    esac
}

# --------------------- STEP 5: VERIFY ROOTFS ---------------------
verify_rootfs() {
    [ -d "$ROOTFS_DIR/etc" ] || die "Extracted tree has no /etc — this does not look like a valid root filesystem."
    [ -x "$ROOTFS_DIR/bin/sh" ] || [ -x "$ROOTFS_DIR/usr/bin/sh" ] || die "Extracted tree has no /bin/sh or /usr/bin/sh — cannot chroot into it."
    log "Root filesystem verified at: $ROOTFS_DIR"
}

# --------------------- CHROOT SUPPORT ----------------------------
backup_resolv_conf() {
    if [ -e "$ROOTFS_DIR/etc/resolv.conf" ] && [ ! -L "$ROOTFS_DIR/etc/resolv.conf" ]; then
        cp "$ROOTFS_DIR/etc/resolv.conf" "$ROOTFS_DIR/etc/resolv.conf.custom-linux-builder.bak" 2>/dev/null || true
    fi
    local host_resolv="/etc/resolv.conf"
    [ -e /run/systemd/resolve/resolv.conf ] && host_resolv="/run/systemd/resolve/resolv.conf"
    cp "$host_resolv" "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || warn "Could not copy host DNS config; network may not work inside chroot."
    RESOLV_CONF_BACKED_UP=1
}

restore_resolv_conf() {
    [ "$RESOLV_CONF_BACKED_UP" = "1" ] || return 0
    if [ -e "$ROOTFS_DIR/etc/resolv.conf.custom-linux-builder.bak" ]; then
        mv -f "$ROOTFS_DIR/etc/resolv.conf.custom-linux-builder.bak" "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
    else
        rm -f "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
    fi
    RESOLV_CONF_BACKED_UP=0
}

apply_wallpaper() {
    [ -n "$CUSTOM_WALLPAPER" ] || return 0
    [ -f "$CUSTOM_WALLPAPER" ] || { warn "CUSTOM_WALLPAPER set but file doesn't exist: $CUSTOM_WALLPAPER"; return 0; }

    log "Installing custom wallpaper..."
    local ext="${CUSTOM_WALLPAPER##*.}"
    local rel_path="usr/share/backgrounds/custom-linux-builder/wallpaper.$ext"
    local in_chroot_path="/$rel_path"

    mkdir -p "$ROOTFS_DIR/$(dirname "$rel_path")"
    cp "$CUSTOM_WALLPAPER" "$ROOTFS_DIR/$rel_path"

    if [ -x "$ROOTFS_DIR/usr/bin/gsettings" ] || [ -x "$ROOTFS_DIR/usr/bin/dconf" ]; then
        log "GNOME/Cinnamon (dconf) detected — setting the default wallpaper system-wide."
        mkdir -p "$ROOTFS_DIR/etc/dconf/db/local.d" "$ROOTFS_DIR/etc/dconf/profile"
        cat > "$ROOTFS_DIR/etc/dconf/db/local.d/00-custom-wallpaper" <<EOF
[org/gnome/desktop/background]
picture-uri='file://$in_chroot_path'
picture-uri-dark='file://$in_chroot_path'
picture-options='zoom'
EOF
        printf 'user-db:user\nsystem-db:local\n' > "$ROOTFS_DIR/etc/dconf/profile/user"
        chroot "$ROOTFS_DIR" dconf update 2>/dev/null || warn "'dconf update' failed inside chroot; wallpaper may not apply."
    elif [ -x "$ROOTFS_DIR/usr/bin/plasmashell" ]; then
        warn "KDE Plasma detected. Wallpaper file installed to $in_chroot_path but default theme may override it."
    elif [ -d "$ROOTFS_DIR/etc/xdg/xfce4" ]; then
        log "XFCE detected — writing default desktop settings."
        local xml_dir="$ROOTFS_DIR/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
        mkdir -p "$xml_dir"
        cat > "$xml_dir/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$in_chroot_path"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
    else
        warn "No recognized desktop environment found. Wallpaper installed to $in_chroot_path — set it in your WM/DE config."
    fi
}

enter_chroot() {
    log "Binding system directories for chroot..."
    mkdir -p "$ROOTFS_DIR"/dev/pts "$ROOTFS_DIR"/proc "$ROOTFS_DIR"/sys "$ROOTFS_DIR"/run "$ROOTFS_DIR"/tmp

    mount --rbind /dev "$ROOTFS_DIR/dev"
    mount --rbind /proc "$ROOTFS_DIR/proc"
    mount --rbind /sys "$ROOTFS_DIR/sys"
    mount --rbind /run "$ROOTFS_DIR/run"
    mount --rbind /tmp "$ROOTFS_DIR/tmp"

    mount --make-rslave "$ROOTFS_DIR/dev" || true
    mount --make-rslave "$ROOTFS_DIR/proc" || true
    mount --make-rslave "$ROOTFS_DIR/sys" || true
    mount --make-rslave "$ROOTFS_DIR/run" || true
    mount --make-rslave "$ROOTFS_DIR/tmp" || true

    # Bind systemd-resolved runtime dir if present to keep DNS working
    if [ -d /run/systemd/resolve ]; then
        mkdir -p "$ROOTFS_DIR/run/systemd/resolve"
        mount --bind /run/systemd/resolve "$ROOTFS_DIR/run/systemd/resolve" || true
    fi

    CHROOT_MOUNTS_ACTIVE=1
    backup_resolv_conf
    apply_wallpaper

    if [ "$NO_CHROOT" -eq 1 ]; then
        if [ -n "$RUN_SCRIPT" ]; then
            log "Running non-interactive script inside chroot: $RUN_SCRIPT"
            cp "$RUN_SCRIPT" "$ROOTFS_DIR/tmp/customizer.sh"
            chmod +x "$ROOTFS_DIR/tmp/customizer.sh"
            cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
            chroot "$ROOTFS_DIR" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -c "/tmp/customizer.sh; rm -f /tmp/customizer.sh" || true
        else
            log "Non-interactive mode selected but no --run-script provided; skipping customization step."
        fi
    else
        log "Entering interactive chroot. Type 'exit' to leave."
        chroot "$ROOTFS_DIR" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash --login || true
    fi

    log "Unmounting chroot directories (from inside enter_chroot)..."
    restore_resolv_conf || true
    umount -l "$ROOTFS_DIR/tmp" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
    CHROOT_MOUNTS_ACTIVE=0
}

# --------------------- STEP 7: REPACK ROOT IMAGE -----------------
repack_root_image() {
    if [ -n "$NESTED_LOOP_DEV" ]; then
        log "Unmounting nested root image..."
        umount -l "$ROOTFS_DIR" 2>/dev/null || true
        losetup -d "$NESTED_LOOP_DEV" 2>/dev/null || true
        NESTED_LOOP_DEV=""
    fi

    log "Repacking $IMAGE_FORMAT image..."
    if [ "$IMAGE_FORMAT" = "squashfs" ]; then
        local comp block
        comp="$(get_original_comp "$IMAGE_PATH")"
        block="$(unsquashfs -s "$IMAGE_PATH" 2>/dev/null | awk -F': *' '/Block size/ {print $2; exit}' || true)"
        [ -n "$comp" ] || die "Could not determine the original SquashFS compression algorithm."
        if ! mksquashfs "$EXTRACTED_DIR" "$IMAGE_PATH.new" -comp "$comp" -b "${block:-131072}" -noappend 2>/dev/null; then
            die "mksquashfs failed to rebuild using the original compression ('$comp'). Refusing to fall back to a different codec."
        fi
        mv -f "$IMAGE_PATH.new" "$IMAGE_PATH"
    else
        command -v mkfs.erofs >/dev/null 2>&1 || die "This ISO uses EROFS, but 'mkfs.erofs' is not installed. Install with: sudo apt install erofs-utils"
        warn "Original EROFS compression settings cannot be introspected; using lz4hc as a safe default."
        rm -f "$IMAGE_PATH"
        mkfs.erofs -zlz4hc "$IMAGE_PATH" "$EXTRACTED_DIR" || die "mkfs.erofs failed"
    fi
}

# --------------------- STEP 8: REBUILD ISO -----------------------
rebuild_iso() {
    log "Reading the original ISO's boot configuration..."
    local boot_opts_file="$BUILD_DIR/boot_opts.txt"
    xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null | grep '^-' | grep -v "^-V " > "$boot_opts_file" || true

    log "Building new ISO: $OUTPUT_ISO"
    mkdir -p "$(dirname "$OUTPUT_ISO")"
    local esc_label
    printf -v esc_label '%q' "$VOLUME_LABEL"

    if [ -s "$boot_opts_file" ]; then
        log "Reproducing the original boot record (BIOS/UEFI/hybrid as applicable)"
        # shellcheck disable=SC2046,SC2086
        eval xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$esc_label" -r -J "$(tr '\n' ' ' < "$boot_opts_file")" "$BUILD_DIR/iso/"
    else
        warn "Source ISO has no El Torito boot record; building a data-only (non-bootable) ISO."
        xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$VOLUME_LABEL" -r -J "$BUILD_DIR/iso/"
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        log "Generating SHA256 checksum..."
        sha256sum "$OUTPUT_ISO" > "$OUTPUT_ISO.sha256" || true
        if [ -n "${SUDO_USER:-}" ]; then
            chown "${SUDO_USER}" "$OUTPUT_ISO" "$OUTPUT_ISO.sha256" || true
        fi
    fi

    if [ -n "${SUDO_USER:-}" ]; then
        chown "${SUDO_USER}" "$OUTPUT_ISO" || true
    fi
}

# --------------------- MAIN FLOW --------------------------------
main() {
    if [ "$#" -eq 0 ]; then usage; fi

    args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output) OUTPUT_ISO="$2"; shift 2;;
            --label) VOLUME_LABEL="$2"; shift 2;;
            --workdir) BUILD_DIR="$2"; shift 2;;
            --no-chroot) NO_CHROOT=1; shift;;
            --run-script) RUN_SCRIPT="$2"; shift 2;;
            --keep-build) KEEP_BUILD=1; shift;;
            --wallpaper) CUSTOM_WALLPAPER="$2"; shift 2;;
            --help) usage; shift;;
            --*) die "Unknown option: $1";;
            *)
                if [ -z "$SOURCE_ISO" ]; then SOURCE_ISO="$1"; else args+=("$1"); fi
                shift;;
        esac
    done

    ensure_root "$@"
    check_dependencies
    check_input

    extract_iso
    detect_root_image
    extract_root_image
    detect_and_mount_nested
    verify_rootfs
    enter_chroot

    # If we performed changes directly in nested image, they are already applied.
    if [ -n "$EXTRACTED_DIR" ] && [ -d "$EXTRACTED_DIR" ]; then
        # If we mounted a nested image and changed ROOTFS_DIR directly, ensure EXTRACTED_DIR is the one used for repacking for squashfs/erofs.
        # For squashfs we repack EXTRACTED_DIR; for nested mounted images we already updated the image file itself.
        :
    fi

    repack_root_image
    # Copy updated outer tree back into iso dir if needed
    if [ -d "$EXTRACTED_DIR" ]; then
        # If IMAGE_PATH is inside the iso tree, overwrite it already
        rsync -a --delete "$BUILD_DIR/iso/" "$BUILD_DIR/iso/" >/dev/null 2>&1 || true
    fi

    rebuild_iso
    log "Validating output..."
    [ -s "$OUTPUT_ISO" ] || die "Build finished but $OUTPUT_ISO is missing or empty."
    log "Done: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
}

main "$@"
