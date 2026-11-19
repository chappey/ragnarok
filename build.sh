#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
BUILD_DIR="$SCRIPT_DIR/build"
ESP_DIR="$BUILD_DIR/esp"
EFI_OUT="$ESP_DIR/EFI/BOOT/BOOTX64.EFI"
OVMF="/usr/share/edk2/ovmf/OVMF_CODE.fd"

require_cmd() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: required command '$cmd' not found in PATH." >&2
            exit 1
        fi
    done
}

build() {
    require_cmd odin nasm lld-link
    mkdir -p "$ESP_DIR/EFI/BOOT"

    echo "[1/3] Assembling kernel/arch.asm..."
    nasm -f win64 "$SCRIPT_DIR/kernel/arch.asm" -o "$BUILD_DIR/arch.obj"

    echo "[2/3] Compiling kernel/ (freestanding_amd64_win64)..."
    odin build "$SCRIPT_DIR/kernel" \
        -target:freestanding_amd64_win64 \
        -build-mode:obj \
        -use-single-module \
        -no-crt \
        -no-entry-point \
        -default-to-nil-allocator \
        -disable-red-zone \
        -out:"$BUILD_DIR/kernel.obj"

    echo "[3/3] Linking UEFI image -> $EFI_OUT..."
    lld-link \
        /subsystem:efi_application \
        /entry:efi_main \
        /nodefaultlib \
        /out:"$EFI_OUT" \
        "$BUILD_DIR/kernel.obj" \
        "$BUILD_DIR/arch.obj"

    echo "Built $EFI_OUT ($(stat -c%s "$EFI_OUT") bytes)"
}

qemu_base_args() {
    QEMU_ARGS=(
        -enable-kvm
        -cpu host
        -m 512M
        -smp 2
        -nodefaults
        -vga std
        -boot menu=off
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF"
        -drive "if=none,id=esp,format=raw,file=fat:rw:$ESP_DIR"
        -device "ide-hd,drive=esp,bootindex=1"
    )
}

run_vm() {
    require_cmd qemu-system-x86_64
    build
    qemu_base_args
    echo "Booting Ragnarök fullscreen (Ctrl+Alt+F toggle fullscreen, Ctrl+Alt+G ungrab, Ctrl+Alt+3 COM1 serial, Ctrl+Alt+1 display)..."
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -display sdl,gl=off \
        -full-screen \
        -serial vc
}

test_vm() {
    require_cmd qemu-system-x86_64 python3
    build
    qemu_base_args
    python3 - "${QEMU_ARGS[@]}" <<'PY'
import select, subprocess, sys, time

cmd = ["qemu-system-x86_64", *sys.argv[1:], "-display", "none", "-serial", "stdio"]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

buf = b""
sent = False
deadline = time.monotonic() + 15.0
try:
    while time.monotonic() < deadline:
        r, _, _ = select.select([proc.stdout], [], [], 0.2)
        if r:
            chunk = proc.stdout.read1(4096)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            buf += chunk
            if not sent and b"RAGNAROK_READY" in buf:
                sent = True
                # First newline exits live animated splash into shell
                proc.stdin.write(b"\ninfo\nhalt\n")
                proc.stdin.flush()
        if proc.poll() is not None:
            break
finally:
    if proc.poll() is None:
        proc.terminate()
    proc.wait(timeout=5)

if b"RAGNAROK_READY" not in buf or b"Ragnarok OS v0.1" not in buf:
    print("FAIL: expected boot banner and 'info' output", file=sys.stderr)
    sys.exit(1)
print("\nPASS: Ragnarök booted via Direct UEFI -> Ring-0 -> Shell -> ACPI poweroff")
PY
}

build_usb() {
    require_cmd sfdisk mformat mmd mcopy truncate
    build
    local img="$BUILD_DIR/ragnarok.img"
    rm -f "$img"
    truncate -s 64M "$img"
    # GPT with a single EFI System Partition starting at 1 MiB (sector 2048)
    printf 'label: gpt\nstart=2048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="RAGNAROK_ESP"\n' \
        | sfdisk -q "$img"
    mformat -i "$img@@1M" -F -v RAGNAROK ::
    mmd     -i "$img@@1M" ::/EFI ::/EFI/BOOT
    mcopy   -i "$img@@1M" "$EFI_OUT" ::/EFI/BOOT/BOOTX64.EFI
    echo "Built bootable UEFI USB image -> $img ($(stat -c%s "$img") bytes)"
    echo "Flash to USB (replace /dev/sdX carefully!):"
    echo "  sudo dd if=$img of=/dev/sdX bs=4M status=progress conv=fsync"
}

case "${1:-build}" in
    build) build ;;
    usb)   build_usb ;;
    run)   run_vm ;;
    test)  test_vm ;;
    clean) rm -rf "$BUILD_DIR" ;;
    *)
        echo "Usage: $0 [build|usb|run|test|clean]" >&2
        exit 1
        ;;
esac
