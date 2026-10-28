# ZIP Print

A small macOS app for printing photos to a **Polaroid ZIP** instant
printer (model POLMP01, 2×3" ZINK paper) over Bluetooth.

Polaroid only ships phone apps for the ZIP. ZIP Print lets a Mac find the
printer, connect and print an image or PDF. It needs no pairing and no extra
drivers.

<p align="center"><img src="Resources/AppIcon.png" width="128" alt="ZIP Print icon"></p>

## Features

- **Finds the printer automatically.** Switch the ZIP on and it appears. No
  Bluetooth pairing is needed.
- **Prints photos or PDFs.** Open any image (JPEG, PNG, HEIC, TIFF…) or a PDF.
  Drag it onto the window, onto the Dock icon, or use **File › Open**.
- **Frame the shot.** Choose **Fill** (crop to cover the sheet) or **Fit**
  (show the whole image with white borders). Drag the preview to reposition
  the crop, and rotate in 90° steps. Landscape photos are turned to fill the
  portrait sheet.
- **Shows printer status.** The window shows whether the printer is **Ready**
  or **Asleep**. The ZIP powers itself off after a few idle minutes. When you
  switch it back on, ZIP Print notices within 45 seconds.
- **Print from any app.** Turn on **Printer › Show in Print Dialog**. Then, in
  any app, choose **File › Print… › PDF ▾ › Print to Polaroid ZIP**.
- **Command line.**
  `open -a "ZIP Print" --args --print photo.jpg [--printer 70-2c-1f-xx-xx-xx] [--verbose]`
- **Clear errors.** If the printer refuses a photo, the app says why: out of
  paper, cover open, battery low, overheating, and so on.

## Requirements

- macOS 13 Ventura or later, on Apple silicon or Intel
- A Polaroid ZIP with ZINK 2×3" paper

Other ZINK printers that accept Bluetooth Object Push may also work, such as
the LG Pocket Photo and Canon Ivy (first generation). They're untested.

## Build and install

You need Xcode or the Xcode Command Line Tools (Swift 5.10 or later).

```bash
git clone https://github.com/ethanpierce/polaroid-zink-printer-driver.git
```

```bash
cd polaroid-zink-printer-driver && scripts/build-app.sh
```

```bash
cp -R "dist/ZIP Print.app" /Applications/
```

The build script makes a universal app. It signs the app with your Apple
Developer certificate if you have one, and ad-hoc otherwise.

The first time you print, macOS asks for Bluetooth access. Click **Allow**. If
you dismissed the prompt, turn ZIP Print on under **System Settings › Privacy &
Security › Bluetooth**.

> **Ad-hoc builds:** macOS ties the Bluetooth permission to the app's
> signature. An ad-hoc signed build therefore asks again after every rebuild.
> Signing with a real certificate avoids this.

## Using it

1. Switch the ZIP on and load paper with the blue Smart Sheet underneath.
2. Open ZIP Print. Your printer appears at the top. Click ↻ to search again.
3. Drop in a photo, adjust the framing, and click **Print** (⌘P).
4. The photo transfers in a few seconds. The print comes out about a minute
   later.

## How it works

The ZIP exposes the standard Bluetooth **OBEX Object Push** profile. ZIP Print
renders your image to a 640×960 JPEG of 45 KB or less. It then pushes the file
over RFCOMM, paced so the printer's small receive buffer never overflows. The
printer scales the image onto its 640×1224-dot print head and prints.

Everything is implemented directly on IOBluetooth, with no third-party code.
See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the services, the bytes on the
wire, and the error codes.

```
Sources/ZipPrinterKit/   Bluetooth discovery, RFCOMM, OBEX, image prep (reusable library)
Sources/ZipPrint/        SwiftUI app
Tests/                   Unit tests for the OBEX encoder and image pipeline
scripts/build-app.sh     Builds and signs dist/ZIP Print.app
```

Run the tests with `swift test`.

## Troubleshooting

- **The printer isn't found, or shows "Asleep".** Make sure it's on (the LED
  is lit) and within a few metres. Close the Polaroid app on your phone, which
  may be holding the connection. The ZIP switches itself off after a few idle
  minutes; press the power button to wake it. Nothing a Mac can send keeps it
  awake (see [docs/PROTOCOL.md](docs/PROTOCOL.md#idle-power-off)).
- **A thin unprinted sliver at one end.** This is the printer's paper
  registration. The whole image prints about 1.5 mm off along the sheet, so
  the far edge gets trimmed by the same amount. Keep important details away
  from the very top and bottom, or use **Fit**.
- **"The printer didn't respond."** The printer was probably asleep. Switch it
  on and print again.
- **The LED turns red and nothing prints.** Check the paper, the cover and the
  battery. The app shows the reason the printer reports.
- **For debugging,** run
  `"/Applications/ZIP Print.app/Contents/MacOS/ZipPrint" --print photo.jpg --verbose`.
  It logs every Bluetooth packet.

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Polaroid or ZINK Holdings.
Polaroid, Polaroid ZIP and ZINK are trademarks of their respective owners.
