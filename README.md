# DictC

Dictate into any Mac app using Claude's voice typing.

DictC is a small menu bar app. Press a shortcut, speak, press another shortcut, and your words are pasted into whatever text field you were in. The transcription is done by claude.ai's own Dictate feature, shown in a popover under the menu bar icon.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- A Claude account

## Install

```sh
cd DictC
./build.sh install
```

This builds `DictC.app`, moves it to `/Applications` and opens it. A mic icon appears in the menu bar; there is no Dock icon.

To build and run from this folder without installing, use plain `./build.sh`.

## First run

1. Press **Control+Option+Space** and sign in to Claude in the popover. Use the email login code: Google sign-in is usually blocked inside embedded web views.
2. The first time dictation starts, macOS asks for **microphone** access. Allow it.
3. The first time you paste, macOS asks for **Accessibility** access. Open System Settings from the prompt and turn on DictC. Until you do, the text is left on the clipboard and you press Cmd+V yourself.

Both permissions are asked for once and carry over when you rebuild.

## Use

| Shortcut | What it does |
|---|---|
| **Control+Option+Space** | Open the popover and start dictating. Press again to close it. |
| **Control+Option+Return** | Finish dictating and paste into the app you were in. |
| **Esc** | Discard the recording and text, and return to the app you were in. |

The popover also has **Paste into last app** and **Discard** buttons, and clicking the menu bar mic does the same as Control+Option+Space.

Right-click the menu bar mic for:

- **Paste into last app**
- **New chat**: load a fresh Claude page
- **Reload**: reload the current page
- **Open at login**: on by default once installed in `/Applications`
- **Quit DictC**

## How it works

DictC is one Swift file (`Sources/main.swift`) built with `swiftc`; there is no Xcode project.

**The popover.** The popover holds a `WKWebView` showing `https://claude.ai/new`. The page is loaded when DictC launches, so it is ready the first time you open it, and your sign-in is kept between launches.

**Remembering where you were.** DictC watches which app is in front. When you paste or discard, it switches back to the last app that was not DictC.

**Starting dictation.** When the popover opens, DictC runs a short script in the page that finds Claude's **Dictate** button by its accessibility label and clicks it. It then waits for the **Finish dictation** button to appear before showing "Listening". If the button can't be found, the status line asks you to click it yourself.

**Pasting.** Control+Option+Return does this in order:

1. Clicks **Finish dictation** and waits for the words to appear in Claude's text box.
2. Puts the cursor in the text box, then sends Select All and Cut, so the text moves to the clipboard and the box is left empty.
3. Closes the popover and switches back to the app you were in.
4. Sends Cmd+V to that app. This is the step that needs Accessibility access.

If the text box was empty, nothing is pasted and the status line says so.

**Discarding.** Esc or Discard loads a fresh Claude page, which ends the recording and clears the text, then closes the popover and returns to your app.

**Microphone choice.** Claude's page records from the system input device. While the popover is open, DictC makes the Mac's built-in microphone the system input, so Bluetooth earbuds are not switched into their low-quality call mode. Once the popover is closed and recording has stopped, it puts your previous input back. The switch is system-wide while it lasts, so another app recording at the same moment also uses the built-in mic.

**Leaving a recording running.** If you close the popover while dictation is still going, DictC finishes it after one minute so the mic is not left on. The words stay in Claude's text box for the next paste.

**Signing.** `build.sh` signs the app ad hoc, but names it by its bundle identifier (`local.dictc.app`) instead of by the hash of the build. That is what lets macOS keep the microphone and Accessibility permissions when the app is rebuilt.

## Troubleshooting

- **The shortcut does nothing, but clicking the mic works.** Another app is using Control+Option+Space.
- **"Couldn't start the mic."** Claude's page had not finished loading, or Claude has renamed its Dictate button. Click the mic in Claude's text box yourself.
- **"Nothing copied."** Claude's text box was empty. Dictate something first, or click in the box and try again.
- **macOS keeps asking for Accessibility access even though DictC is switched on.** The entry belongs to an older build. Run `tccutil reset Accessibility local.dictc.app`, then paste once and allow it again.
- **Sound input stays on the built-in mic after DictC is force-quit.** Pick your usual input again in System Settings > Sound.

DictC keeps a log at `~/Library/Logs/DictC.log`, which records each dictation start, paste and microphone switch.

## Limits

- DictC depends on the labels of Claude's buttons ("Dictate", "Finish dictation"). If Claude changes them, starting and finishing dictation automatically will stop working until the script in `main.swift` is updated.
- Esc always discards while the popover is open, including when you only meant to close a menu inside Claude's page.
- Pasting replaces whatever was on your clipboard with the dictated text.
