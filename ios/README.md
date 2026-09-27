# BabyCam

A private baby monitor for iPhone. No ads, no accounts, no cloud: everything stays on your home Wi-Fi.

One app, two modes:

- **Camera**: the phone in the nursery. It streams video and audio, and also serves a web page so you can watch from any browser.
- **Viewer**: another iPhone watches and listens, even with its screen locked.
- **Browser**: on your computer, open the `http://…:8080` address shown on the camera phone.

Features: live video and audio, swap front/back camera, dim flashlight, night mode (brighter, black and white), rotate, noise alerts with adjustable sensitivity, a "go dark" black screen to save power on the camera phone, a pairing code so only your devices can watch, and auto-reconnect with a notification if the camera drops.

---

## Before Tuesday

1. **Decide on your Apple developer account.**
   - **Free (any Apple ID):** works, but **apps installed this way stop opening after 7 days**, and you have to reinstall from a Mac. If you only have Mac access occasionally, this will be a pain.
   - **Paid Apple Developer Program ($99/year):** installs last a year, and you can use TestFlight.
2. Bring **both iPhones** and their **USB cables**.
3. Copy this `BabyCam` folder to a USB stick or cloud drive, or bring the `BabyCam.zip`.

## On the Mac (about 30–45 min the first time)

1. Install **Xcode** from the Mac App Store. It's large, so start early if you can.
2. Open Terminal and install XcodeGen, which creates the Xcode project from `project.yml`:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install xcodegen
   ```
3. In Terminal, `cd` into the `BabyCam` folder (the one containing `project.yml`) and run:
   ```bash
   xcodegen
   open BabyCam.xcodeproj
   ```
4. In Xcode: **Settings › Accounts** and sign in with your Apple ID.
5. Click the **BabyCam** project, then the **BabyCam** target, then **Signing & Capabilities**:
   - **Team:** pick your name.
   - **Bundle Identifier:** change `com.yourname.babycam` to something unique, e.g. `com.calebbishop.babycam`.
6. Plug in iPhone #1. On the phone, tap **Trust**. If asked, turn on **Settings › Privacy & Security › Developer Mode** and restart.
7. Pick the phone from the device menu at the top of Xcode and press **▶ Run** (⌘R).
8. First launch with a free account: on the phone, go to **Settings › General › VPN & Device Management**, tap your Apple ID, then **Trust**.
9. Repeat steps 6–8 for iPhone #2.

### If you'd rather not install XcodeGen

In Xcode: **File › New › Project › iOS App**, name it `BabyCam`, with interface SwiftUI. Delete the generated `ContentView.swift` and `BabyCamApp.swift`, then drag the `App`, `Shared`, `Camera`, `Viewer` and `Web` folders into the project. In the target's **Build Settings**:
- set **Info.plist File** to `BabyCam/Info.plist`
- set **Generate Info.plist File** to No
- set **Swift Language Version** to 5
- set **Default Actor Isolation** to nonisolated

---

## Using it

1. **Camera phone:** open BabyCam, tap **Use as Camera**, and allow Camera, Microphone and Local Network. It shows a **pairing code** and a **web address**.
2. **Viewer iPhone:** tap **Use as Viewer**, allow Local Network and Notifications, enter the code, and tap the camera in the list.
3. **Computer:** type the web address (like `http://192.168.1.23:8080`) into your browser, enter the code, and click **Start watching**. Press **M** to mute and **F** for full screen.
4. On the camera phone, tap **Go dark** to turn the screen off. Tap the screen to wake it.

### Good to know

- **The camera app must stay open.** iOS doesn't let apps use the camera in the background. Leave it on the BabyCam screen and use **Go dark**. Don't press the side button or swipe home.
- **Keep the camera phone plugged in.** Streaming uses a lot of battery and the phone will get warm. If it gets hot, lower `framesPerSecond` in `CameraStreamer.swift` to `10`.
- The viewer iPhone keeps playing audio and sending alerts while locked. If the phone is on **silent**, notifications only vibrate.
- Noise alerts in the **browser** flash a red border. If you've muted sound, a chime plays and the tab title flashes. Browsers don't allow real notifications from local pages.
- **Night mode:** iPhones have no infrared camera, so in a pitch-dark room you'll see very little. A small night light, or the dim **Light** button, helps a lot.
- **Privacy:** anyone on your Wi-Fi who knows the 6-digit code can watch. Nothing is sent to the internet.

## How it works

| Piece | File |
|---|---|
| Camera capture, JPEG encoding, night mode, torch | `Camera/CameraStreamer.swift` |
| Microphone capture (16 kHz PCM) | `Camera/AudioCapture.swift` |
| HTTP (8080) and WebSocket (8081) server, Bonjour | `Camera/StreamServer.swift` |
| iPhone viewer (discovery, playback, alerts) | `Viewer/*.swift` |
| Browser viewer | `Web/viewer.html` |

WebSocket messages: binary messages start with `1` (a JPEG frame) or `2` (16-bit PCM audio). Text messages are JSON: the camera sends `status`, and viewers send commands like `{"cmd":"torch","value":true}`.
