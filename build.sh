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
        -debug \
        -no-crt \
        -no-entry-point \
        -default-to-nil-allocator \
        -no-thread-local \
        -disable-red-zone \
        -out:"$BUILD_DIR/kernel.obj"

    echo "[3/3] Linking UEFI image -> $EFI_OUT..."
    lld-link \
        /subsystem:efi_application \
        /entry:efi_main \
        /nodefaultlib \
        /debug \
        /pdb:"$BUILD_DIR/kernel.pdb" \
        /map:"$BUILD_DIR/kernel.map" \
        /out:"$EFI_OUT" \
        "$BUILD_DIR/kernel.obj" \
        "$BUILD_DIR/arch.obj"

    echo "Built $EFI_OUT ($(stat -c%s "$EFI_OUT") bytes)"
}

ensure_disk_imgs() {
    require_cmd sfdisk mformat mmd mcopy truncate
    local img="$BUILD_DIR/ragnarok.img"
    local nvme_img="$BUILD_DIR/nvme.img"

    # Rebuild bootable 64 MiB GPT/FAT32 ESP + WELCOME.TXT
    rm -f "$img"
    truncate -s 64M "$img"
    printf 'label: gpt\nstart=2048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="RAGNAROK_ESP"\n' \
        | sfdisk -q "$img"
    mformat -i "$img@@1M" -F -v RAGNAROK ::
    mmd     -i "$img@@1M" ::/EFI ::/EFI/BOOT
    mcopy   -i "$img@@1M" "$EFI_OUT" ::/EFI/BOOT/BOOTX64.EFI
    printf 'Welcome to Ragnarok OS (x86_64 Ring-0, Odin + Direct UEFI)!\nRead directly via AHCI/NVMe DMA + GPT + FAT32.\n' \
        | mcopy -i "$img@@1M" - ::/WELCOME.TXT

    # Small 16 MiB raw NVMe test disk (verified via NVMe Identify + Block_Device)
    if [[ ! -f "$nvme_img" ]]; then
        truncate -s 16M "$nvme_img"
    fi
}

qemu_base_args() {
    ensure_disk_imgs
    QEMU_ARGS=(
        -enable-kvm
        -cpu host
        -m 512M
        -smp 2
        -nodefaults
        -vga std
        -boot menu=off
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF"
        -device "ich9-ahci,id=ahci"
        -drive "if=none,id=esp,format=raw,file=$BUILD_DIR/ragnarok.img"
        -device "ide-hd,drive=esp,bus=ahci.0,bootindex=1"
        -drive "if=none,id=nvmedisk,format=raw,file=$BUILD_DIR/nvme.img"
        -device "nvme,serial=RAGNAROK0,drive=nvmedisk"
        -device "qemu-xhci,id=xhci"
        -device "usb-kbd,bus=xhci.0"
    )
}

run_vm() {
    require_cmd qemu-system-x86_64
    build
    qemu_base_args
    echo "Booting Ragnarök fullscreen (Ctrl+Alt+F toggle fullscreen, Ctrl+Alt+G ungrab)..."
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -display sdl,gl=off \
        -full-screen \
        -serial none
}

test_vm() {
    require_cmd qemu-system-x86_64 python3
    build
    qemu_base_args
    python3 - "${QEMU_ARGS[@]}" <<'PY'
import re, select, subprocess, sys, time

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
                proc.stdin.write(
                    b"\nsys\nrtc\nuptime\nselftest\ndmesg | find PMM\ntime echo bench\nmem\npci | head 3\ndisks\ndf\nls\nls /EFI/BOOT\n"
                    b"mkdir TESTDIR\ncd TESTDIR\npwd\n"
                    b"write A.TXT subfile\ncopy A.TXT B.TXT\nmove B.TXT C.TXT\n"
                    b"read /TESTDIR/C.TXT\ndel A.TXT\ndel C.TXT\ncd ..\nrmdir TESTDIR\n"
                    b"read WELCOME.TXT | find AHCI\nread WELCOME.TXT | count\n"
                    b"echo hello | hex\n"
                    b"echo foo bar\x17baz\n"
                    b"\x1b[A\n"
                    b"history\n"
                    b"matrix\nqstarfield\nqspiro\nqc64\nq"
                    b"mem\nhalt\n"
                )
                proc.stdin.flush()
        if proc.poll() is not None:
            break
finally:
    if proc.poll() is None:
        proc.terminate()
    proc.wait(timeout=5)

required = [
    b"RAGNAROK_READY",
    b"USB=kbd",
    b"[TXT] WELCOME.TXT",
    b"BOOTX64.EFI",
    b"/TESTDIR",
    b"subfile",
    b"Read directly via AHCI/NVMe DMA",
    b"lines=2",
    b"68 65 6C 6C 6F",
    b"foo baz",
    b"UTC",
    b"[INFO]",
    b"tsc=",
    b"[time]",
    b"us (",
    b"IDT #BP test: PASS",
    b"PIT IRQ0",
    b"Arena test: PASS",
]
for needle in required:
    if needle not in buf:
        print(f"FAIL: missing expected output {needle!r}", file=sys.stderr)
        sys.exit(1)

used_matches = re.findall(rb"used=(\d+) pages", buf)
if len(used_matches) != 2 or used_matches[0] != used_matches[1]:
    print(f"FAIL: expected matching PMM used page counts across pipelines, got {used_matches!r}", file=sys.stderr)
    sys.exit(1)

print("\nPASS: Ragnarök booted via Direct UEFI -> Ring-0 -> Arena+Pipes+xHCI+AHCI+NVMe+FAT32 -> ACPI poweroff")
PY
}

build_usb() {
    build
    ensure_disk_imgs
    local img="$BUILD_DIR/ragnarok.img"
    echo "Built bootable UEFI USB image -> $img ($(stat -c%s "$img") bytes)"
    echo "Flash to USB (replace /dev/sdX carefully!):"
    echo "  sudo dd if=$img of=/dev/sdX bs=4M status=progress conv=fsync"
}

debug_vm() {
    require_cmd qemu-system-x86_64
    build
    qemu_base_args
    echo "QEMU paused at reset vector on gdbserver :1234 (COM1 on stdio)."
    echo "Attach with LLDB:"
    echo "  lldb -o 'target create $EFI_OUT' -o 'gdb-remote localhost:1234'"
    echo "  # Note ImageBase from COM1 [INFO] ImageBase=..., then slide PE sections:"
    echo "  #   target modules load --file $EFI_OUT --slide <ImageBase - 0x140000000>"
    echo "Or GDB:"
    echo "  gdb -ex 'target remote :1234'"
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -s -S -no-reboot \
        -display sdl,gl=off \
        -serial stdio
}

asm_dump() {
    require_cmd llvm-objdump rg
    if [[ ! -f "$EFI_OUT" ]]; then
        build
    fi
    local sym="${1:-}"
    if [[ -n "$sym" ]]; then
        llvm-objdump -d -M intel --demangle "$EFI_OUT" | rg -n -A 45 "$sym"
    else
        local out="$BUILD_DIR/kernel.asm"
        llvm-objdump -d -M intel --demangle "$EFI_OUT" > "$out"
        echo "Wrote disassembly -> $out ($(wc -l < "$out") lines)"
    fi
}

sym_dump() {
    if [[ ! -f "$BUILD_DIR/kernel.map" ]]; then
        build
    fi
    if command -v llvm-nm >/dev/null 2>&1 && [[ -f "$BUILD_DIR/kernel.obj" ]]; then
        llvm-nm --size-sort --reverse-sort "$BUILD_DIR/kernel.obj" | head -n 40
    else
        head -n 60 "$BUILD_DIR/kernel.map"
    fi
}

log_vm() {
    require_cmd qemu-system-x86_64
    build
    qemu_base_args
    local qlog="$BUILD_DIR/qemu.log"
    echo "Running QEMU with interrupt/reset tracing -> $qlog"
    qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -d int,cpu_reset -D "$qlog" -no-reboot \
        -display none \
        -serial stdio || true
    echo "Trace written to $qlog ($(wc -l < "$qlog") lines)"
}

case "${1:-build}" in
    build) build ;;
    usb)   build_usb ;;
    run)   run_vm ;;
    test)  test_vm ;;
    debug) debug_vm ;;
    asm)   asm_dump "${2:-}" ;;
    sym)   sym_dump ;;
    log)   log_vm ;;
    clean) rm -rf "$BUILD_DIR" ;;
    *)
        echo "Usage: $0 [build|usb|run|test|debug|asm [sym]|sym|log|clean]" >&2
        exit 1
        ;;
esac
