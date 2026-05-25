# Shake Shelf

A tiny free Mac shelf for moving files around.

Pick up a file in Finder, shake left and right, and a small floating shelf appears. Drop files there. Drag the stack out when you want all of them, or click the list button and drag one file at a time.

That's it. No account, no subscription, no artificial delay.

## What works

- Summon the shelf by shaking while dragging a file.
- Drop files, folders, images, videos, PDFs, and apps.
- Drop images from apps and the web when macOS provides image data or a promised file.
- See image thumbnails for common image files.
- Drag the whole stack out together.
- Open list mode and drag a single file out.
- Press Command-C to copy the stack, or select a row in list mode and press Command-C to copy one file.
- Right-click the shelf for copy actions.
- Move the shelf by dragging its top header.
- Runs as a background menu-bar utility.
- Shows a tiny first-run window so you know the app started; after that it lives in the menu bar.

For normal local files, Shake Shelf stores file references, not copies. If you delete or move the original file before dragging it back out, macOS may not be able to resolve it. For raw image drops and promised files from other apps, Shake Shelf saves a copy into `~/Library/Application Support/Shake Shelf/Incoming/` so the shelf has a real file to drag or copy later.

## Requirements

- macOS 14 or newer
- Apple Silicon or Intel Mac

## Install

Download the DMG from the GitHub Releases page, open it, and drag **Shake Shelf.app** to Applications.

The app is free and currently ad-hoc signed. On first launch, macOS may block a normal double-click. Use:

1. Open Finder.
2. Go to Applications.
3. Control-click **Shake Shelf.app**.
4. Click **Open**.
5. Confirm once.

If macOS asks for Accessibility permission, allow it. The shake detector needs to see drag events while you are dragging files in other apps.

On first launch, Shake Shelf shows a small "running" window with a test shelf button. Close it when you are done. You can reopen it later from the menu bar icon.

## Build Locally

```sh
swift test
./script/run_shakeshelf.sh --verify
./script/package_dmg.sh
```

The packaged app and DMG are written to `dist/`.

## Why

macOS drag-and-drop is great until the destination is buried behind windows, spaces, or apps. Shake Shelf is the small missing tray: temporarily put files somewhere, get to the destination, drag them out.

This is intentionally lean. It is not trying to become a productivity suite.
