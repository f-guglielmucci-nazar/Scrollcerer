# Scrollmate

**The two things a regular mouse is missing on a Mac.** A small menu-bar app for macOS 13 Ventura or later.

### 1. Autoscroll, like on Windows

macOS has no autoscroll. On Windows you click the mouse wheel, move the mouse, and the page scrolls by itself, faster the further you move. Scrollmate brings that to every app on your Mac.

**It knows what you're clicking on.** Before it starts, Scrollmate checks what's under the pointer. Over a page, document or list it starts autoscrolling; over a link, a browser tab, the Dock or a toolbar it sends a normal middle-click instead. So you keep opening links in new tabs and closing tabs with the wheel, and get autoscroll everywhere else, without switching anything on or off.

- **Click** the wheel over a page or list: a round marker appears. Move away from it and the page scrolls that way; the further away, the faster. Nothing scrolls inside a small circle around the marker.
- **Hold** the wheel and move: scrolls while you hold, stops when you let go.
- It ends with any click (that click isn't passed on, as on Windows), Esc, any other key (which still types), turning the wheel, or switching apps.
- Scrolling stays with the window you started in, even if the pointer wanders over another one. The speed is adjustable.

### 2. Mouse wheel direction separate from the trackpad

On a Mac, the mouse wheel and the trackpad share one "Natural scrolling" switch. Choose the direction that feels right on the trackpad, and the mouse wheel goes the "wrong" way, and vice versa. Scrollmate fixes the wheel without touching the trackpad:

- **Reverse the wheel direction**, mouse only.
- **Turn off scroll acceleration**, so every notch scrolls the same amount however fast you spin.
- Choose **how many lines each notch scrolls**.

### Plus: remap the extra buttons

Side buttons work as Back / Forward out of the box. Each side button, the wheel click and **tilting the wheel left / right** can be set to: Back, Forward, tab switching, Mission Control, App Exposé, Show Desktop, switching Desktops, Copy / Paste / Undo, screenshot, Spotlight, media keys, middle click, nothing at all, or **any keyboard shortcut you record**. Press a button in Settings and its row lights up, so you know which physical button is which.

## Download

Get **Scrollmate-x.y.dmg** from the [Releases page](https://github.com/fguglielmuccinazar/Scrollmate/releases/latest), open it, drag Scrollmate into Applications and follow "Read Me First".

- The first time, macOS blocks it because it isn't from an identified developer. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
- When asked, switch Scrollmate on under **System Settings → Privacy & Security → Accessibility**. This is what lets it see and change mouse clicks and scrolling.

Works on Apple silicon and Intel Macs.

## Use

Click the mouse icon in the menu bar → **Settings…**.

- **Buttons:** pick an action for each button. Autoscroll is on the wheel click by default; set that row to "Default (no change)" to turn it off. For your own shortcut, choose **Custom shortcut…** and press the key combination (Esc cancels).
- **Scroll wheel:** reverse direction, turn off acceleration, lines per notch, and the autoscroll speed.

### Autoscroll notes

- **Firefox** has its own autoscroll (Settings → General → Browsing → "Use autoscrolling", off by default on Mac). Leave it off, or the two will fight.
- In Chrome, Edge, Brave, Arc and Electron apps (VS Code, Slack…) Scrollmate switches on their full accessibility info so it can tell links from pages. The very first wheel click after launching such an app may be a plain middle click.

## Build it yourself

1. Get the code (`git clone https://github.com/fguglielmuccinazar/Scrollmate.git`, or download the ZIP from GitHub and unzip it), then open **Terminal** and run (adjust the path to where the folder is):

   ```
   bash ~/Downloads/Scrollmate/build.sh
   ```

   The first time, macOS may ask to install its free Command Line Tools — accept, wait for it to finish, then run the command again.

2. The app installs itself in **/Applications** and starts. A mouse icon appears in the menu bar.

3. When asked, switch **Scrollmate** on under **System Settings → Privacy & Security → Accessibility**. The Settings window notices automatically once it's allowed.

To make a DMG to share, run `bash make_dmg.sh`. It builds for both Apple silicon and Intel and puts the result in `dist/Scrollmate-<version>.dmg`, without touching your installed copy.

## Notes

- Scrollmate used to be called **MouseRemap**. It brings over MouseRemap's settings the first time it runs and quits MouseRemap if it's open; you can then delete `/Applications/MouseRemap.app` and remove it from the Accessibility list.
- A **DPI button** is handled inside the mouse itself; macOS never receives it, so no app can remap it.
- Settings apply to any regular mouse you plug in (macOS doesn't tell apps like this which mouse a click came from).
- If a button doesn't light up its row in Settings, the mouse is sending it in a way macOS doesn't treat as a button.
- If you rebuild the app, macOS will ask for Accessibility permission again — that's expected.
- To remove it: quit from the menu bar icon, delete `/Applications/Scrollmate.app`, and remove it from the Accessibility list.

## License

MIT — see [LICENSE](LICENSE).
