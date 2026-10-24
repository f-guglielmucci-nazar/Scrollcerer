# MouseRemap

A small menu-bar app for remapping the extra buttons on a TeckNet MG2511 (or any regular mouse) on macOS 13 Ventura or later.

- **Side buttons** work as Back / Forward out of the box (macOS doesn't do anything with them by default).
- Each side button, the wheel click, and **tilting the wheel left / right** can be set to: Back, Forward, tab switching, Mission Control, App Exposé, Show Desktop, switching Desktops, Copy / Paste / Undo, screenshot, Spotlight, media keys, middle click, nothing at all, or **any keyboard shortcut you record**.
- **Windows-style autoscroll** on the wheel click (or any button): click and move the mouse to scroll, the further away the faster. Links, browser tabs and the Dock still get a normal middle click.
- **Reverse scroll**, **no scroll acceleration** and **lines per wheel notch** for the mouse wheel only, so your trackpad keeps working as it does.
- Press a mouse button in Settings and its row lights up, so you know which physical button is which.
- Optional "Open at login".

## Download

Get **MouseRemap-x.y.dmg** from the [Releases page](https://github.com/fguglielmuccinazar/MouseRemap/releases/latest), open it, drag MouseRemap into Applications and follow "Read Me First". The first time, macOS blocks it because it isn't from an identified developer: go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Build it yourself

1. Get the code (`git clone https://github.com/fguglielmuccinazar/MouseRemap.git`, or download the ZIP from GitHub and unzip it), then open **Terminal** and run (adjust the path to where the folder is):

   ```
   bash ~/Downloads/MouseRemap/build.sh
   ```

   The first time, macOS may ask to install its free Command Line Tools — accept, wait for it to finish, then run the command again.

2. The app installs itself in **/Applications** and starts. A mouse icon appears in the menu bar.

3. When asked, go to **System Settings → Privacy & Security → Accessibility** and switch **MouseRemap** on. (This is what lets it see and change mouse clicks.) The Settings window notices automatically once it's allowed.

## Share it

Run `bash make_dmg.sh`. It builds a version for both Apple silicon and Intel Macs and puts it in `dist/MouseRemap-<version>.dmg` (your installed copy isn't touched). Send that file.

The app isn't signed with an Apple Developer ID, so the first time someone opens it macOS blocks it. They go to **System Settings → Privacy & Security**, click **Open Anyway** next to the MouseRemap message, and confirm. The DMG includes a "Read Me First" file with these steps.

## Use

Click the mouse icon in the menu bar → **Settings…** and pick an action for each button.

To use your own shortcut, choose **Custom shortcut…** and press the key combination. Esc cancels.

## Autoscroll

The wheel click does **Autoscroll (Windows style)** out of the box (set it to "Default (no change)" to turn it off).

- **Click** the wheel over a page or list: a round marker appears. Move the mouse away from it to scroll; the further away, the faster. Inside a small circle around the marker nothing scrolls.
- **Hold** the wheel and move: scrolls while held, stops when you let go.
- Ends with any mouse click (that click is not passed on, as on Windows), Esc, any other key (which still types), turning the wheel, or switching apps.
- Middle-clicking a **link** (open in new tab), a **browser tab** (close it), the Dock or other non-scrolling UI still sends a normal middle click.
- Scrolling stays with the window you started in, even if the pointer wanders over another one.
- The speed slider is under **Scroll wheel** in Settings.
- **Firefox** has its own autoscroll (Settings → General → Browsing → "Use autoscrolling", off by default on Mac). Leave it off, or the two will fight.
- In Chrome, Edge, Brave, Arc and Electron apps (VS Code, Slack…) MouseRemap switches on their full accessibility info so it can tell links from pages. The very first wheel click after launching such an app may be a plain middle click.

## Notes

- The **DPI button** is handled inside the mouse itself; macOS never receives it, so no app can remap it.
- Mappings apply to any regular mouse you plug in, not only the TeckNet (macOS doesn't say which mouse a click came from to apps like this).
- If a side button doesn't light up its row in Settings, the mouse is sending it in a way macOS doesn't treat as a button.
- If you rebuild the app, macOS will ask for Accessibility permission again — that's expected.
- To remove it: quit from the menu bar icon, delete `/Applications/MouseRemap.app`, and remove it from the Accessibility list.
