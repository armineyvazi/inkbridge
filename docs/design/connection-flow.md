# Connection and pairing flow (UX)

## First time (Wi-Fi)

| Step | Mac | BOOX |
|---|---|---|
| 1 | InkBridge is running (menu-bar pen). Menu → **Connect Device…** (⌃⌥K) | Open InkBridge. Dashboard: "Not connected" or "Mac found" → **Connect to Mac** |
| 2 | The window shows steps, the code `K7QW-M3XP`, "Expires in 4:59 · works once", a QR code, and the paired tablets | "Macs on this network" lists the Mac by name and address |
| 3 | — | Tap the Mac, then type the code. Letters are uppercased and the dash is inserted as you type. Tap **Pair** |
| 4 | "✓ Paired with NoteAir2P". The code is now void | "● Connected to <Mac>" → **Start drawing** |

## Every later time

Open InkBridge on both, and the tablet connects by itself within a fraction of a second once Wi-Fi is up. The dashboard shows "Connected to <Mac> · Wi-Fi · 4 ms · Ready to draw".

## Error and loading states

| State | Title / message | Next step offered |
|---|---|---|
| Searching | "Searching… Make sure InkBridge is open on the Mac." | Search again · Enter address |
| Wi-Fi off | "Wi-Fi is off. Turn it on in the BOOX settings…" | — |
| Pairing | "Pairing…" under the code field | — |
| Wrong code | "Wrong code. Check the code shown on the Mac and try again." | Stays on the code screen |
| Code expired or closed | "Code expired. On the Mac, open InkBridge → Connect Device for a new code." | Pair again |
| Forgotten by the Mac | "Pair again. The Mac no longer recognises this tablet." The stored pairing is cleared | Pair again |
| Certificate changed | "Mac identity changed. … If you reinstalled InkBridge on the Mac, pair again." | Pair again |
| Link lost | "Reconnecting… Connection lost: no answer from the Mac." The canvas keeps working and strokes are queued | — |
| User disconnected | "Disconnected. Paired with X. Connect when you want to draw on the Mac." | Connect |
| Invalid or expired QR link | Explained on the Connect list | Choose the Mac from the list |

Socket errors are reworded (`ConnectionStatus.plain`). The raw text appears only in Diagnostics.

## USB (optional)

Connect → "Use a USB cable instead" gives the three steps (USB debugging, allow the computer, `adb reverse tcp:8765 tcp:8765`) and a **Use USB** button. Switching back to Wi-Fi is one tap, and the pairing is kept.
