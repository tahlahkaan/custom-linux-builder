#!/usr/bin/env bash
#
# custom-linux-builder.sh
# ------------------------------------------------------------------
# Extracts the root filesystem of a Linux live/install ISO, opens a
# chroot so you can customize it, and rebuilds a bootable ISO with
# the original boot configuration (BIOS/UEFI/hybrid) preserved.
#
# Usage:
#   sudo ./custom-linux-builder.sh /path/to/original.iso
#
# Requirements:
#   sudo apt install squashfs-tools xorriso rsync file
#   Optional, only needed for EROFS-based ISOs (Fedora/RHEL 10+,
#   Arch "baseline" profile):
#   sudo apt install erofs-utils
#
# WARNING: This script performs loop-mount and chroot operations as
# root. Read and understand it before running it. chroot is NOT a
# security sandbox — see the "Security notes" section below.
# ------------------------------------------------------------------

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
readonly SOURCE_ISO="${1:-}"
readonly BUILD_DIR="./build"
readonly OUTPUT_ISO="./custom.iso"
readonly VOLUME_LABEL="CustomLinux"

# Optional: path to an image on the HOST machine to set as the default
# desktop wallpaper inside the customized ISO. Leave empty to skip this
# entirely. See apply_wallpaper() for which desktop environments this
# can configure automatically.
readonly CUSTOM_WALLPAPER=""

# ------------------------------------------------------------------
# Global state, tracked so cleanup() can always unwind it safely.
# Every one of these starts empty and is only ever set right before
# the matching resource is created.
# ------------------------------------------------------------------
ISO_MOUNT_DIR=""          # loop mount of the source ISO
ROOTFS_DIR=""             # final root filesystem directory (chroot target)
EXTRACTED_DIR=""          # where the outer image (squashfs/erofs) was unpacked
NESTED_LOOP_DEV=""        # loop device for a nested rootfs.img, if any
CHROOT_MOUNTS_ACTIVE=0    # 1 once /dev,/proc,/sys,/run are bound
RESOLV_CONF_BACKED_UP=0   # 1 if we saved the rootfs's original resolv.conf

IMAGE_PATH=""             # path of the detected outer root image (squashfs/erofs)
IMAGE_FORMAT=""           # "squashfs" or "erofs"
LAYOUT_NAME=""            # human-readable name of the detected layout

# ============================================================
# LOGGING / ERROR HELPERS
# ============================================================
log()  { echo -e "\n==> $1"; }
warn() { echo "WARNING: $1" >&2; }
die()  { echo "ERROR: $1" >&2; exit 1; }

# ============================================================
# CLEANUP
# Runs on any exit path: success, error (set -e), or interruption
# (Ctrl+C). Order matters: innermost mounts first.
# ============================================================
cleanup() {
    log "Cleaning up..."

    if [ "$CHROOT_MOUNTS_ACTIVE" = "1" ] && [ -n "$ROOTFS_DIR" ]; then
        restore_resolv_conf
        for d in run/systemd/resolve dev/pts dev proc sys run; do
            if mountpoint -q "$ROOTFS_DIR/$d" 2>/dev/null; then
                sudo umount -R "$ROOTFS_DIR/$d" 2>/dev/null || \
                    sudo umount -lR "$ROOTFS_DIR/$d" 2>/dev/null || \
                    warn "Could not unmount $ROOTFS_DIR/$d — you may need to unmount it manually."
            fi
        done
        CHROOT_MOUNTS_ACTIVE=0
    fi

    if [ -n "$NESTED_LOOP_DEV" ]; then
        if mountpoint -q "$ROOTFS_DIR" 2>/dev/null; then
            sudo umount "$ROOTFS_DIR" 2>/dev/null || sudo umount -l "$ROOTFS_DIR" 2>/dev/null || \
                warn "Could not unmount nested image at $ROOTFS_DIR."
        fi
        sudo losetup -d "$NESTED_LOOP_DEV" 2>/dev/null || \
            warn "Could not detach loop device $NESTED_LOOP_DEV — check 'losetup -a'."
        NESTED_LOOP_DEV=""
    fi

    if [ -n "$ISO_MOUNT_DIR" ] && mountpoint -q "$ISO_MOUNT_DIR" 2>/dev/null; then
        sudo umount "$ISO_MOUNT_DIR" 2>/dev/null || sudo umount -l "$ISO_MOUNT_DIR" 2>/dev/null || \
            warn "Could not unmount $ISO_MOUNT_DIR."
    fi
    if [ -n "$ISO_MOUNT_DIR" ]; then
        rmdir "$ISO_MOUNT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ============================================================
# DEPENDENCY / INPUT CHECKS
# ============================================================
check_dependencies() {
    local missing=()
    for cmd in unsquashfs mksquashfs xorriso rsync file losetup mountpoint; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required commands: ${missing[*]}. Install with: sudo apt install squashfs-tools xorriso rsync file util-linux"
    fi
    # erofs-utils is only required if we actually encounter an EROFS image;
    # checked lazily in extract_root_image() so it isn't a hard dependency
    # for the (more common) squashfs-only case.
}

check_input() {
    [ -n "$SOURCE_ISO" ] || die "Usage: $0 <iso-path>"
    [ -f "$SOURCE_ISO" ] || die "ISO not found: $SOURCE_ISO"
    [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1 || \
        die "This script needs root privileges (via sudo) for mount/chroot operations."
}

# ============================================================
# STEP 1 — EXTRACT THE ISO'S FILE TREE
# ============================================================
extract_iso() {
    log "Extracting ISO file tree..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/iso"

    ISO_MOUNT_DIR="$(mktemp -d)"
    sudo mount -o loop,ro "$SOURCE_ISO" "$ISO_MOUNT_DIR"
    # -H/-A/-X preserve hard links, ACLs and xattrs, not just owner/perms/symlinks.
    rsync -aHAX "$ISO_MOUNT_DIR/" "$BUILD_DIR/iso/"
    sudo umount "$ISO_MOUNT_DIR"
    rmdir "$ISO_MOUNT_DIR"
    ISO_MOUNT_DIR=""
}

# ============================================================
# STEP 2 — DETECT THE ROOT FILESYSTEM IMAGE
#
# We check a short list of well-known paths used by specific distro
# families FIRST (in priority order), and only fall back to a generic
# scan if none of them match. We never assume the first *.img/*.squashfs
# file found is the right one — on some ISOs there is more than one
# (e.g. an installer squashfs alongside the live one), and picking the
# wrong one silently produces a broken result.
# ============================================================
detect_root_image() {
    log "Detecting ISO layout..."
    local iso_root="$BUILD_DIR/iso"
    local candidate=""

    # Debian/Ubuntu (casper / live-boot)
    for p in "casper/filesystem.squashfs" "live/filesystem.squashfs"; do
        if [ -f "$iso_root/$p" ]; then
            candidate="$iso_root/$p"; LAYOUT_NAME="Debian/Ubuntu (casper/live-boot)"
            break
        fi
    done

    # Fedora / RHEL-family / openSUSE (Kiwi) / Void (all use dracut's
    # dmsquash-live module and its default /LiveOS directory)
    if [ -z "$candidate" ]; then
        for p in "LiveOS/squashfs.img" "LiveOS/rootfs.img"; do
            if [ -f "$iso_root/$p" ]; then
                candidate="$iso_root/$p"; LAYOUT_NAME="dracut LiveOS (Fedora/RHEL-family, openSUSE, or Void)"
                break
            fi
        done
    fi

    # Arch Linux (archiso) — path includes the architecture directory.
    # Manjaro, EndeavourOS, and other archiso-based derivatives use the
    # same layout since they build on the archiso tooling directly.
    if [ -z "$candidate" ]; then
        candidate="$(find "$iso_root/arch" -maxdepth 2 -type f -name "airootfs.sfs" -print -quit 2>/dev/null || true)"
        [ -n "$candidate" ] && LAYOUT_NAME="Arch Linux (archiso) or derivative"
    fi

    # Gentoo minimal/install media
    if [ -z "$candidate" ] && [ -f "$iso_root/image.squashfs" ]; then
        candidate="$iso_root/image.squashfs"; LAYOUT_NAME="Gentoo (minimal/install media)"
    fi

    # NixOS — single squashfs at the ISO root. NOTE: mechanically this
    # extracts/repacks like any other squashfs, but NixOS's root is mostly
    # symlinks into /nix/store; installing packages the usual way (apt/
    # pacman-style, imperatively, inside chroot) will NOT work as expected
    # without the Nix daemon and store machinery. We proceed but warn.
    if [ -z "$candidate" ] && [ -f "$iso_root/nix-store.squashfs" ]; then
        candidate="$iso_root/nix-store.squashfs"
        LAYOUT_NAME="NixOS"
        warn "NixOS detected. Its root filesystem is largely symlinks into /nix/store." \

        warn "Package changes made with normal package-manager commands inside the chroot are unlikely to persist or behave as expected."
    fi

    # Generic fallback: scan for squashfs/EROFS images by MAGIC BYTES, not
    # by filename or extension. If more than one candidate turns up we
    # refuse to guess — an incorrectly chosen image produces an ISO that
    # LOOKS built but silently doesn't boot into the right system.
    if [ -z "$candidate" ]; then
        warn "No known distro layout matched. Falling back to a generic scan."
        local found=()
        while IFS= read -r -d '' f; do
            case "$(file -b "$f")" in
                Squashfs*|EROFS*) found+=("$f") ;;
            esac
        done < <(find "$iso_root" -maxdepth 4 -type f \( -name "*.squashfs" -o -name "*.img" -o -name "*.sfs" -o -name "*.erofs" \) -print0 2>/dev/null)

        if [ ${#found[@]} -eq 1 ]; then
            candidate="${found[0]}"; LAYOUT_NAME="Generic (auto-detected by content)"
        elif [ ${#found[@]} -gt 1 ]; then
            die "Multiple candidate root images found and none match a known layout — refusing to guess: ${found[*]}"
        fi
    fi

    [ -n "$candidate" ] || die "Unsupported ISO layout: no recognizable root filesystem image found. This script supports Debian/Ubuntu (casper), Fedora/RHEL-family (LiveOS), Arch Linux (archiso), NixOS, and generic squashfs/EROFS layouts. Alpine (apkovl/modloop-based) and similarly non-squashfs live systems are not supported."

    IMAGE_PATH="$candidate"

    # Detect the ACTUAL format by content — never trust the extension.
    # Some modern Fedora/RHCOS ISOs ship an EROFS image named
    # "squashfs.img" for compatibility with older boot parameters.
    case "$(file -b "$IMAGE_PATH")" in
        Squashfs*) IMAGE_FORMAT="squashfs" ;;
        EROFS*)    IMAGE_FORMAT="erofs" ;;
        *) die "Detected image '$IMAGE_PATH' is neither SquashFS nor EROFS ($(file -b "$IMAGE_PATH")). Unsupported format." ;;
    esac

    log "Layout: $LAYOUT_NAME | Image: $IMAGE_PATH | Format: $IMAGE_FORMAT"
}

# ============================================================
# STEP 3 — EXTRACT THE ROOT IMAGE
# ============================================================
extract_root_image() {
    EXTRACTED_DIR="$BUILD_DIR/extracted"

    if [ "$IMAGE_FORMAT" = "squashfs" ]; then
        log "Unpacking SquashFS image..."
        sudo unsquashfs -d "$EXTRACTED_DIR" "$IMAGE_PATH"
    else
        command -v fsck.erofs >/dev/null 2>&1 || \
            die "This ISO uses EROFS, but 'fsck.erofs' is not installed. Install with: sudo apt install erofs-utils"
        log "Unpacking EROFS image..."
        sudo fsck.erofs --extract="$EXTRACTED_DIR" "$IMAGE_PATH"
    fi
}

# ============================================================
# STEP 4 — DETECT A NESTED ROOT IMAGE (Fedora/RHEL-style LiveOS)
#
# Older/some current Fedora & RHEL-family ISOs wrap the actual root
# filesystem in a SECOND image (rootfs.img, usually ext4) INSIDE the
# outer squashfs/erofs. We must not treat the outer extraction as the
# root filesystem in that case — /etc and /bin would be missing.
# ============================================================
detect_and_mount_nested() {
    # Fedora's LiveOS layout can carry MORE THAN ONE nested image at once —
    # e.g. rootfs.img (the actual root) alongside home.img (a separate
    # persistent /home overlay). Grabbing "the first *.img found" could
    # silently pick home.img instead of the real root. Always prefer an
    # exact "rootfs.img" match; only fall back to a generic scan if that
    # exact name isn't present, and refuse to guess between multiple
    # unnamed candidates.
    local nested=""
    if [ -f "$EXTRACTED_DIR/rootfs.img" ]; then
        nested="$EXTRACTED_DIR/rootfs.img"
    else
        local imgs=()
        while IFS= read -r -d '' f; do imgs+=("$f"); done < <(
            find "$EXTRACTED_DIR" -maxdepth 1 -type f -iname "*.img" -print0 2>/dev/null
        )
        if [ ${#imgs[@]} -eq 1 ]; then
            nested="${imgs[0]}"
        elif [ ${#imgs[@]} -gt 1 ]; then
            warn "Multiple nested images found and none is named rootfs.img (${imgs[*]}); not guessing. Using the outer extraction as root instead."
        fi
    fi

    if [ -z "$nested" ]; then
        ROOTFS_DIR="$EXTRACTED_DIR"
        return
    fi

    case "$(file -b "$nested")" in
        *ext2*|*ext3*|*ext4*|*XFS*|*Btrfs*)
            log "Nested root filesystem image found: $nested"
            NESTED_LOOP_DEV="$(sudo losetup --show -f "$nested")"
            ROOTFS_DIR="$BUILD_DIR/rootfs"
            mkdir -p "$ROOTFS_DIR"
            sudo mount "$NESTED_LOOP_DEV" "$ROOTFS_DIR"
            ;;
        *)
            # Some file at that path but not a filesystem image we recognize
            # (e.g. a kernel or firmware blob) — treat the outer tree as root.
            ROOTFS_DIR="$EXTRACTED_DIR"
            ;;
    esac
}

# ============================================================
# STEP 5 — VERIFY WE ACTUALLY HAVE A USABLE ROOT FILESYSTEM
# Fail loudly here rather than dropping the user into a broken chroot.
# ============================================================
verify_rootfs() {
    [ -d "$ROOTFS_DIR/etc" ] || die "Extracted tree has no /etc — this does not look like a valid root filesystem."
    [ -x "$ROOTFS_DIR/bin/sh" ] || [ -x "$ROOTFS_DIR/usr/bin/sh" ] || \
        die "Extracted tree has no /bin/sh or /usr/bin/sh — cannot chroot into it."
    log "Root filesystem verified at: $ROOTFS_DIR"
}

# ============================================================
# STEP 6 — PREPARE AND ENTER THE CHROOT
# ============================================================
backup_resolv_conf() {
    if [ -e "$ROOTFS_DIR/etc/resolv.conf" ] && [ ! -L "$ROOTFS_DIR/etc/resolv.conf" ]; then
        sudo cp "$ROOTFS_DIR/etc/resolv.conf" "$ROOTFS_DIR/etc/resolv.conf.custom-linux-builder.bak"
    fi
    # On systemd-resolved systems (default on Arch, Fedora, Ubuntu desktop),
    # /etc/resolv.conf is usually a symlink to the "stub" listener at
    # 127.0.0.53. That stub only works via a live socket under
    # /run/systemd/resolve — which our fresh tmpfs /run does not have. Use
    # systemd-resolved's own real-upstream-server file instead, if present;
    # it lists actual DNS IPs directly, with no socket dependency.
    local host_resolv="/etc/resolv.conf"
    [ -e /run/systemd/resolve/resolv.conf ] && host_resolv="/run/systemd/resolve/resolv.conf"
    sudo cp "$host_resolv" "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || \
        warn "Could not copy host DNS config; network access inside chroot may not work."
    RESOLV_CONF_BACKED_UP=1
}

restore_resolv_conf() {
    [ "$RESOLV_CONF_BACKED_UP" = "1" ] || return 0
    if [ -e "$ROOTFS_DIR/etc/resolv.conf.custom-linux-builder.bak" ]; then
        sudo mv -f "$ROOTFS_DIR/etc/resolv.conf.custom-linux-builder.bak" "$ROOTFS_DIR/etc/resolv.conf"
    else
        sudo rm -f "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
    fi
    RESOLV_CONF_BACKED_UP=0
}

# ============================================================
# OPTIONAL — CUSTOM WALLPAPER
#
# Desktop wallpaper defaults are stored differently by every desktop
# environment, and most of them (GNOME, KDE, XFCE...) normally expect a
# running session to change this — there is no single universal command.
# We handle the mechanisms that CAN be set offline, inside a chroot, and
# are honest about the ones that can't:
#
#   - GNOME / Cinnamon (dconf-based): fully automatic via a system-wide
#     dconf override, compiled with "dconf update".
#   - XFCE: fully automatic by writing its default per-channel XML config.
#   - KDE Plasma: the image is installed, but Plasma's default wallpaper
#     is defined per look-and-feel theme in a way that varies between
#     spins and Plasma versions — we do not attempt to guess the theme's
#     internal file layout. You'll need to set it once via System
#     Settings, or edit the active theme's defaults file yourself.
#   - Anything else (i3, sway, a minimal/server image, or an
#     unrecognized DE): the image is installed to a standard shared
#     path; reference it from your own WM config.
# ============================================================
apply_wallpaper() {
    [ -n "$CUSTOM_WALLPAPER" ] || return 0
    [ -f "$CUSTOM_WALLPAPER" ] || { warn "CUSTOM_WALLPAPER is set but the file doesn't exist: $CUSTOM_WALLPAPER — skipping."; return 0; }

    log "Installing custom wallpaper..."
    local ext="${CUSTOM_WALLPAPER##*.}"
    local rel_path="usr/share/backgrounds/custom-linux-builder/wallpaper.$ext"
    local in_chroot_path="/$rel_path"

    sudo mkdir -p "$ROOTFS_DIR/$(dirname "$rel_path")"
    sudo cp "$CUSTOM_WALLPAPER" "$ROOTFS_DIR/$rel_path"

    if [ -x "$ROOTFS_DIR/usr/bin/gsettings" ] || [ -x "$ROOTFS_DIR/usr/bin/dconf" ]; then
        log "GNOME/Cinnamon (dconf) detected — setting the default wallpaper system-wide."
        sudo mkdir -p "$ROOTFS_DIR/etc/dconf/db/local.d" "$ROOTFS_DIR/etc/dconf/profile"
        sudo tee "$ROOTFS_DIR/etc/dconf/db/local.d/00-custom-wallpaper" > /dev/null << EOF
[org/gnome/desktop/background]
picture-uri='file://$in_chroot_path'
picture-uri-dark='file://$in_chroot_path'
picture-options='zoom'
EOF
        printf 'user-db:user\nsystem-db:local\n' | sudo tee "$ROOTFS_DIR/etc/dconf/profile/user" > /dev/null
        sudo chroot "$ROOTFS_DIR" dconf update 2>/dev/null || \
            warn "'dconf update' failed inside the chroot; the wallpaper file is installed but the default may not apply."
    elif [ -x "$ROOTFS_DIR/usr/bin/plasmashell" ]; then
        warn "KDE Plasma detected. The wallpaper file was installed to $in_chroot_path, but Plasma's default is theme-specific and not set automatically — see System Settings > Appearance > Wallpaper, or your look-and-feel theme's defaults file."
    elif [ -d "$ROOTFS_DIR/etc/xdg/xfce4" ]; then
        log "XFCE detected — writing the default desktop settings."
        local xml_dir="$ROOTFS_DIR/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
        sudo mkdir -p "$xml_dir"
        sudo tee "$xml_dir/xfce4-desktop.xml" > /dev/null << EOF
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
        warn "No recognized desktop environment found. The wallpaper file was installed to $in_chroot_path — reference it from your WM/DE config manually."
    fi
}

enter_chroot() {
    log "Binding system directories for chroot..."
    # Real distro rootfs images always ship these as empty directories, but
    # we create them defensively in case of an unusual/stripped-down layout.
    mkdir -p "$ROOTFS_DIR"/{dev/pts,proc,sys,run}
    sudo mount --bind /dev "$ROOTFS_DIR/dev"
    sudo mount -t devpts devpts "$ROOTFS_DIR/dev/pts" 2>/dev/null || \
        sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    sudo mount -t proc proc "$ROOTFS_DIR/proc"
    sudo mount --bind /sys "$ROOTFS_DIR/sys"
    sudo mount -t tmpfs tmpfs "$ROOTFS_DIR/run"
    CHROOT_MOUNTS_ACTIVE=1

    # Bind-mount the live systemd-resolved socket directory into the chroot,
    # if the host runs it. Without this, the "resolve" NSS module (used by
    # default on Arch/Fedora/Ubuntu) gets UNAVAIL and — because nsswitch.conf
    # marks it "[!UNAVAIL=return]" — DNS lookups fail immediately instead of
    # falling back to plain DNS, even with a valid resolv.conf.
    if [ -d /run/systemd/resolve ]; then
        sudo mkdir -p "$ROOTFS_DIR/run/systemd/resolve"
        sudo mount --bind /run/systemd/resolve "$ROOTFS_DIR/run/systemd/resolve"
    fi

    backup_resolv_conf
    apply_wallpaper

    # --------------------------------------------------------
    # CUSTOMIZATION AREA
    # Add automated setup commands here if you want them applied every
    # run without typing them by hand. Example:
    #
    #   sudo chroot "$ROOTFS_DIR" bash -c '
    #       apt update
    #       apt install -y neofetch
    #   '
    # --------------------------------------------------------

    log "Entering chroot. Type 'exit' to leave."
    # "|| true": the exit status of your last command inside the chroot
    # becomes this line's exit status. Without "|| true", set -e would
    # abort the script here and skip the repack/rebuild steps below.
    sudo chroot "$ROOTFS_DIR" /usr/bin/env -i HOME=/root TERM="$TERM" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        bash --login || true

    log "Unmounting chroot directories..."
    # These MUST be unmounted before repacking: mksquashfs/mkfs.erofs must
    # never see the host's live /dev nodes or /proc entries baked into the
    # image. This also matters for security — see "Security notes" below.
    restore_resolv_conf
    sudo umount -R "$ROOTFS_DIR/run" 2>/dev/null || sudo umount -lR "$ROOTFS_DIR/run" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/sys" 2>/dev/null || sudo umount -lR "$ROOTFS_DIR/sys" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/proc" 2>/dev/null || sudo umount -lR "$ROOTFS_DIR/proc" 2>/dev/null || true
    sudo umount -R "$ROOTFS_DIR/dev" 2>/dev/null || sudo umount -lR "$ROOTFS_DIR/dev" 2>/dev/null || true
    CHROOT_MOUNTS_ACTIVE=0
}

# ============================================================
# STEP 7 — REPACK THE ROOT FILESYSTEM
# ============================================================
repack_root_image() {
    # If we mounted a nested image (rootfs.img) read-write, our changes
    # are already written directly into that file — nothing more to do
    # with it. We just need to unmount it before repacking the outer image.
    if [ -n "$NESTED_LOOP_DEV" ]; then
        log "Unmounting nested root image..."
        sudo umount "$ROOTFS_DIR"
        sudo losetup -d "$NESTED_LOOP_DEV"
        NESTED_LOOP_DEV=""
    fi

    log "Repacking $IMAGE_FORMAT image..."
    if [ "$IMAGE_FORMAT" = "squashfs" ]; then
        # Reuse the ORIGINAL compression algorithm and block size. Silently
        # switching (e.g. to zstd) can produce a squashfs the original
        # ISO's initramfs cannot decompress if its kernel/module set lacks
        # that codec — this is a real cause of "builds fine, won't boot".
        local comp block
        comp="$(unsquashfs -s "$IMAGE_PATH" | awk '/^Compression/{print $2}')"
        block="$(unsquashfs -s "$IMAGE_PATH" | awk '/^Block size/{print $3}')"
        [ -n "$comp" ] || die "Could not determine the original SquashFS compression algorithm."

        if ! sudo mksquashfs "$EXTRACTED_DIR" "$IMAGE_PATH.new" -comp "$comp" -b "${block:-131072}" -noappend; then
            die "mksquashfs failed to rebuild using the original compression ('$comp'). Refusing to silently fall back to a different codec, since that could produce an image the ISO's boot environment cannot mount."
        fi
        sudo mv "$IMAGE_PATH.new" "$IMAGE_PATH"
    else
        command -v mkfs.erofs >/dev/null 2>&1 || \
            die "This ISO uses EROFS, but 'mkfs.erofs' is not installed. Install with: sudo apt install erofs-utils"
        # erofs-utils has no equivalent of "unsquashfs -s" to introspect the
        # original compression parameters, so we cannot faithfully reproduce
        # them. We use a conservative, widely-supported default and say so.
        warn "Original EROFS compression settings cannot be introspected with available tools; using lz4hc as a safe, widely-supported default."
        sudo rm -f "$IMAGE_PATH"
        sudo mkfs.erofs -zlz4hc "$IMAGE_PATH" "$EXTRACTED_DIR"
    fi
}

# ============================================================
# STEP 8 — REBUILD THE ISO, PRESERVING THE ORIGINAL BOOT RECORD
#
# We ask xorriso to read the SOURCE ISO's own El Torito boot record and
# hand back the exact options needed to reproduce it, instead of
# guessing isolinux/GRUB/EFI paths ourselves. This is what makes BIOS,
# UEFI, and hybrid boot survive the rebuild regardless of which
# bootloader the distro uses or where it keeps its files.
# ============================================================
rebuild_iso() {
    log "Reading the original ISO's boot configuration..."
    local boot_opts_file="$BUILD_DIR/boot_opts.txt"
    xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null \
        | grep '^-' | grep -v "^-V " > "$boot_opts_file" || true

    log "Building new ISO: $OUTPUT_ISO"
    local esc_label
    printf -v esc_label '%q' "$VOLUME_LABEL"

    if [ -s "$boot_opts_file" ]; then
        log "Reproducing the original boot record (BIOS/UEFI/hybrid as applicable)"
        # The captured text is intentionally shell-quoted BY XORRISO ITSELF
        # for exactly this purpose (re-use via a shell). printf %q protects
        # VOLUME_LABEL the same way, so nothing user-controlled bypasses
        # quoting here.
        # shellcheck disable=SC2046,SC2086
        eval sudo xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$esc_label" -r -J \
            "$(tr '\n' ' ' < "$boot_opts_file")" \
            "$BUILD_DIR/iso/"
    else
        warn "Source ISO has no El Torito boot record; building a data-only (non-bootable) ISO."
        sudo xorriso -as mkisofs -o "$OUTPUT_ISO" -V "$esc_label" -r -J "$BUILD_DIR/iso/"
    fi
    sudo chown "${SUDO_USER:-$(id -un)}" "$OUTPUT_ISO"
}

# ============================================================
# STEP 9 — VALIDATE THE RESULT
# A build that "succeeds" but produces a non-bootable or truncated ISO
# is worse than one that fails loudly, so we check both.
# ============================================================
validate_output() {
    log "Validating output..."
    [ -s "$OUTPUT_ISO" ] || die "Build finished but $OUTPUT_ISO is missing or empty."

    if xorriso -indev "$OUTPUT_ISO" -report_el_torito as_mkisofs 2>/dev/null | grep -q '^-'; then
        log "Boot record present in the new ISO."
    else
        warn "Could not confirm a boot record in the new ISO. If the source ISO was bootable, verify this build in a VM before relying on it."
    fi

    log "Done: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
}

# ============================================================
# MAIN FLOW
# ============================================================
main() {
    check_dependencies
    check_input
    extract_iso
    detect_root_image
    extract_root_image
    detect_and_mount_nested
    verify_rootfs
    enter_chroot
    repack_root_image
    rebuild_iso
    validate_output
}

main
