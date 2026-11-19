# Ragnarök

![Ragnarök — Twilight of the Gods](meta/ragnarok.gif)

A Ring-0 x86_64 operating system written in freestanding Odin, booting directly via UEFI (OVMF) with a custom shell language.

## Quick Start

```sh
./build.sh          # Compile kernel/ -> build/esp/EFI/BOOT/BOOTX64.EFI
./build.sh run      # Boot Ragnarök in QEMU/KVM
./build.sh usb      # Build UEFI-bootable GPT/FAT32 USB image (build/ragnarok.img)
./build.sh test     # Headless smoke test via COM1 serial
```

## Architecture
- **Boot**: Direct UEFI (`freestanding_amd64_win64` + `lld-link /subsystem:efi_application`)
- **Execution model**: Ring-0 single identity-mapped 64-bit address space
- **Memory**: UEFI memory-map 4 KiB page-frame bitmap PMM (contiguous DMA allocations) + growable 64 KiB PMM-backed Arena allocator (`context.allocator`)
- **Graphics**: Logical `640×480` 16-color indexed canvas with mutable LUT, integer-scaled to UEFI GOP
- **Storage**: Unified `Block_Device` with polling AHCI (SATA) & NVMe SSD drivers + GPT/FAT32 reader
- **Shell & Input**: Unified 17-command pipe shell (`|`, `"quotes"`, `# comments`, `--help`, per-stage arena cleanup) + polling xHCI (USB 3.0) HID Boot keyboard + PS/2 i8042 + COM1 UART + 80×60 console
