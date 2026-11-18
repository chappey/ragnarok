# Ragnarök

![Ragnarök — Twilight of the Gods](meta/ragnarok.gif)

A Ring-0 x86_64 operating system written in freestanding Odin, booting directly via UEFI (OVMF) with a custom shell language.

## Quick Start

```sh
./build.sh          # Compile kernel/ -> build/esp/EFI/BOOT/BOOTX64.EFI
./build.sh run      # Boot Ragnarök in QEMU/KVM (SDL + COM1 stdio)
./build.sh test     # Headless smoke test via COM1 serial (-display none)
```

## Architecture
- **Boot**: Direct UEFI (`freestanding_amd64_win64` + `lld-link /subsystem:efi_application`)
- **Execution model**: Ring-0 single identity-mapped 64-bit address space
- **Graphics**: UEFI GOP linear 32-bit framebuffer
- **Console**: COM1 UART (`0x3F8`) + framebuffer text console
