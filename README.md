# MouseRemap

A small menu-bar app for remapping the extra buttons on a TeckNet MG2511 (or any regular mouse) on macOS 13 Ventura or later.

- **Side buttons** work as Back / Forward out of the box (macOS doesn't do anything with them by default).
- Each side button, the wheel click, and **tilting the wheel left / right** can be set to: Back, Forward, tab switching, Mission Control, App Exposé, Show Desktop, switching Desktops, Copy / Paste / Undo, screenshot, Spotlight, media keys, middle click, nothing at all, or **any keyboard shortcut you record**.
- **Reverse scroll** for the mouse wheel only, so your trackpad keeps natural scrolling.
- Press a mouse button in Settings and its row lights up, so you know which physical button is which.
- Optional "Open at login".

## Install

1. Unzip, then open **Terminal** and run (adjust the path if you unzipped somewhere else):

   ```
   bash ~/Downloads/MouseRemap/build.sh
   ```

   The first time, macOS may ask to install its free Command Line Tools — accept, wait for it to finish, then run the command again.

2. The app installs itself in **/Applications** and starts. A mouse icon appears in the menu bar.

3. When asked, go to **System Settings → Privacy & Security → Accessibility** and switch **MouseRemap** on. (This is what lets it see and change mouse clicks.) The Settings window notices automatically once it's allowed.

## Use

Click the mouse icon in the menu bar → **Settings…** and pick an action for each button.

To use your own shortcut, choose **Custom shortcut…** and press the key combination. Esc cancels.

## Notes

- The **DPI button** is handled inside the mouse itself; macOS never receives it, so no app can remap it.
- Mappings apply to any regular mouse you plug in, not only the TeckNet (macOS doesn't say which mouse a click came from to apps like this).
- If a side button doesn't light up its row in Settings, the mouse is sending it in a way macOS doesn't treat as a button.
- If you rebuild the app, macOS will ask for Accessibility permission again — that's expected.
- To remove it: quit from the menu bar icon, delete `/Applications/MouseRemap.app`, and remove it from the Accessibility list.
