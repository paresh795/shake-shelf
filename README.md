# Shake Shelf

<p align="center">
  <img src="docs/assets/app-icon.png" width="104" alt="Shake Shelf icon">
</p>

A tiny free Mac shelf for moving files around.

Pick up a file in Finder, shake left and right, and a small floating shelf appears. Drop files there. Drag the stack out when you want all of them, or click the list button and drag one file at a time.

That's it. No account, no subscription, no artificial delay.

## See It Working

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/assets/screenshots/stack.png" alt="Shake Shelf stack mode">
      <br>
      <strong>Stack mode</strong>
      <br>
      <sub>Drop files onto the shelf, then drag the stack out when you want all of them.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="docs/assets/screenshots/overview.png" alt="Shake Shelf overview mode">
      <br>
      <strong>Space overview</strong>
      <br>
      <sub>Press Space to spread files out. Drag one tile, remove one tile, or collapse back to the stack.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/assets/screenshots/list.png" alt="Shake Shelf list mode">
      <br>
      <strong>List mode</strong>
      <br>
      <sub>Use the list when filenames matter: scroll, drag one file, copy one file, Quick Look, or remove it.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="docs/assets/screenshots/web-drop.png" alt="Dragging an image from the web into Shake Shelf">
      <br>
      <strong>Web and app drops</strong>
      <br>
      <sub>Drop images from browsers and apps when macOS provides a real file, image data, or file promise.</sub>
    </td>
  </tr>
</table>

## What works

- Summon the shelf by shaking while dragging a file.
- Drop files, folders, images, videos, PDFs, and apps.
- Drop images from apps and the web when macOS provides image data or a promised file.
- See image thumbnails, plus Quick Look thumbnails for videos, PDFs, and other supported files.
- Drag the whole stack out together.
- Press Space or double-click the stack to expand a thumbnail overview; drag any tile out as a single file, then press Space again or Escape to collapse it.
- Open list mode, scroll through larger shelves, and drag a single file out.
- Press Command-C to copy the stack, or select a row in list mode and press Command-C to copy one file.
- In list mode, select or double-click a row to Quick Look one file.
- Remove one file from the shelf using the small X in overview/list mode, Delete/Backspace on a selected file, or right-click "Remove This File from Shelf".
- Right-click the shelf for overview, Quick Look, copy, and clear actions.
- Move the shelf by dragging its top header.
- Close the shelf with X to clear the current shelf and start fresh on the next shake.
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
