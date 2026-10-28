# Polaroid ZIP Bluetooth protocol notes

These notes describe what ZIP Print talks to. They come from probing a real
Polaroid ZIP (POLMP01) from a Mac, plus public code for sibling printers on the
same ZINK platform.

## Discovery

The printer is a Bluetooth Classic (BR/EDR) device. It doesn't need to be
paired before printing.

| Field | Value seen |
|---|---|
| Name | `Polaroid ZIP(5D:16)`. The suffix is the last two bytes of the address. |
| Address prefix | `70:2C:1F` (Wisol, the Bluetooth module maker) |
| Class of Device | `0x042680`: Rendering service, Imaging major class, Printer minor class |

## SDP services

| RFCOMM channel | Service UUID | Purpose |
|---|---|---|
| 1 | `00000000-DECA-FADE-DECA-DEAFDECACAFF` | Vendor control channel (status, firmware). Not needed to print. |
| 2 | `0x1101` Serial Port | Serial port. Not needed to print. |
| 4 | `0x1105` OBEX Object Push | **Printing.** Push a JPEG here. |

ZIP Print looks up the Object Push channel over SDP. It falls back to channel 4.

## Printing: OBEX Object Push

Printing is a standard OBEX `PUT` of a JPEG. These bytes were captured from a ZIP:

```
→ 80 00 07 10 00 FF FF                CONNECT, OBEX 1.0, max packet 0xFFFF
← A0 00 07 10 00 FF 00                Success, printer max packet 0xFF00

→ 02 LL LL                            PUT
     01 ..  Name   "zipprint.jpg" (UTF-16BE, null terminated)
     42 ..  Type   "image/jpeg\0"
     C3 xx xx xx xx  Length (JPEG size)
     48 ..  Body   (first chunk)
← 90 00 03                            Continue
   … more PUT packets with Body headers …
→ 82 LL LL  49 ..                     PUT-final with End-of-Body
← A0 00 03                            Success, printing starts

→ 81 00 03                            DISCONNECT
← A0 00 03
```

ZIP Print sends 8 KB packets. That's well under the printer's maximum, and it
keeps the progress bar moving.

### Error responses

If the printer can't print, it answers the final `PUT` with a vendor-specific
code instead of `A0`. LG's Pocket Photo SDK, which shares this platform, uses
this mapping:

| Code | Meaning |
|---|---|
| `C0` | Busy |
| `C1` | Data error (couldn't decode the JPEG) |
| `C2` | Paper jam |
| `C5` | Out of paper |
| `C7` | Battery low |
| `C8` | System error |
| `C9` | Cover open |
| `CB` | Too hot |
| `CC` | Too cold |
| `CD` | Wrong paper |
| `CF` | Cooling down |

## Image format

The ZIP prints 2×3" at 313×400 dpi, a grid of 640×1224 non-square dots. The
firmware decodes and scales whatever JPEG it receives. LG's SDK pushes photos
completely unprocessed.

ZIP Print sends a portrait, baseline sRGB JPEG of **640×960** pixels. That's
exactly 2:3 with square pixels, as wide as the print head, and made of whole
16×16 JPEG blocks. The firmware stretches it to 640×1224 dots, so it lands on
the 2×3" sheet with the right proportions. Landscape photos are rotated 90° so
they fill the sheet.

### The receive buffer overflows

The printer sends `Continue` as soon as a packet lands in its receive buffer.
It then decodes the JPEG from that buffer while more data arrives. If data
arrives faster than it decodes, new packets overwrite bytes it hasn't read yet.
Nothing reports an error.

This is what happened with a 162 KB, 816×1224 test JPEG sent in 8 KB packets
as fast as the link allowed:

- Packets 11–16 (body bytes ~81.8K–130.9K, about 48 KB) were lost.
- The encoder's restart markers let the decoder resync, so the print showed the
  top half of the image, a clean seam, then the bottom sixth.
- The sheet was printed bottom-aligned, leaving the top third blank.

ZIP Print avoids this in two ways:

- It keeps files to **45 KB or less**, lowering JPEG quality as needed. That's
  under the roughly 48 KB the printer lost.
- It sends 4 KB packets at about **12 KB/s**.

Some JPEGs are reportedly rejected silently: the LED turns red and nothing
prints. Re-encoding through ZIP Print avoids this.

## References

- Raspberry Pi forum: a Polaroid ZIP printing via `ussp-push` (OBEX) on channel 4.
  https://forums.raspberrypi.com/viewtopic.php?t=186183
- LG Pocket Photo Android SDK sample (OBEX client and error mapping).
  https://github.com/rickpage/PocketPhoto_Example
- Canon Ivy 1, which uses the same OBEX approach.
  https://github.com/LeonardoFerrisi/ivy-print-program
