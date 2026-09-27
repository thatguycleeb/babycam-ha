# BabyCam

A private baby monitor. A spare phone's browser becomes the camera, and you watch from Home Assistant or any browser on your Wi-Fi. There are no apps, accounts or cloud services, and the video never leaves your home network.

## How it works

- The **camera phone** opens `https://babycam.example.com:8443/camera` in Safari or Chrome and streams video and audio to this add-on.
- **Viewers** open `https://babycam.example.com:8443/` on your Wi-Fi, or use the **BabyCam** panel in the Home Assistant sidebar. The panel also works away from home, behind your HA login.
- The add-on publishes **sensors** you can use in automations: sound level, noise detected, and camera online.

Phones only allow a web page to use the camera over trusted HTTPS. The add-on gets a free Let's Encrypt certificate for your hostname using a Cloudflare DNS challenge. It then points that hostname at this machine's **local** IP with a DNS-only record. That record does nothing outside your home, and none of the traffic goes through Cloudflare or your tunnel.

## Setup

### 1. Create a Cloudflare API token

1. In Cloudflare, go to **My Profile › API Tokens › Create Token** and choose **Create Custom Token**.
2. Add these permissions:
   - **Zone › Zone › Read**
   - **Zone › DNS › Edit**
3. Under **Zone Resources**, choose **Include › Specific zone › your domain**.
4. Create the token and copy it.

### 2. Configure the add-on

| Option | What to put |
|---|---|
| `domain` | A **new** hostname just for BabyCam, e.g. `babycam.example.com`. Don't use a hostname that already routes through your Cloudflare tunnel. |
| `email` | Your email, used by Let's Encrypt for expiry notices. |
| `cloudflare_api_token` | The token from step 1. |
| `access_code` | 4–8 digits, used by the camera phone and browser viewers. Leave empty and one is generated and printed in the log. |
| `port` | HTTPS port, default `8443`. Change it if something else already uses 8443. |
| `noise_threshold_db` | How loud counts as "noise". The default is `-35`. Use a lower number, like `-45`, to make it more sensitive. |
| `create_dns_record` | Leave on. The add-on keeps `domain` pointed at this machine's LAN IP. |
| `lan_ip` | Optional. Set this only if the log says it couldn't detect your LAN IP, or picked the wrong one. |

Start the add-on and open the **Log** tab. After about a minute you'll see the camera address, the viewer address and the access code.

### 3. Set up the camera phone

1. On the nursery phone, connected to your home Wi-Fi, open the **Camera phone** address from the log in Safari.
2. Enter the access code, tap **Start camera**, and allow the camera and microphone.
3. Set **Settings › Display & Brightness › Auto-Lock** to **Never**, and keep the phone **plugged in**.
4. Tap **Go dark** and turn brightness down in Control Center. The camera keeps streaming.

Keep Safari open on this page. iPhones stop the camera if Safari goes to the background or the screen locks. If a call or notification interrupts it, the page recovers automatically when it's back in front.

### 4. Watch

- **Home Assistant:** click **BabyCam** in the sidebar and tap **Start watching**.
- **Computer:** open the **Viewer** address from the log. Press **M** to mute and **F** for full screen.

## Home Assistant entities

| Entity | Meaning |
|---|---|
| `binary_sensor.babycam_noise` | `on` while there's noise above your threshold. It turns off after 10 s of quiet. |
| `binary_sensor.babycam_camera` | `on` while the camera phone is connected. |
| `sensor.babycam_sound_level` | The loudest level in each 5 s window, in dB. |

These are updated by the add-on, so they aren't listed under a device, and they can't be renamed in the UI.

### Noise alert on your phone (gets through silent mode)

Replace `notify.mobile_app_your_iphone` with your phone's notify service:

```yaml
alias: BabyCam - noise alert
mode: single
triggers:
  - trigger: state
    entity_id: binary_sensor.babycam_noise
    to: "on"
actions:
  - action: notify.mobile_app_your_iphone
    data:
      title: BabyCam
      message: The baby is making noise.
      data:
        url: /hassio/ingress/local_babycam   # see note below
        push:
          sound:
            name: default
            critical: 1
            volume: 0.7
  - delay: "00:01:00"   # no more than one alert a minute
```

If you installed from a GitHub repository instead of as a local add-on, the panel URL will be `/hassio/ingress/<repo-id>_babycam`. To find it, open the BabyCam panel and copy the URL.

### Camera offline alert

```yaml
alias: BabyCam - camera offline
triggers:
  - trigger: state
    entity_id: binary_sensor.babycam_camera
    to: "off"
    for: "00:01:00"
actions:
  - action: notify.mobile_app_your_iphone
    data:
      title: BabyCam
      message: The camera phone has been disconnected for a minute.
```

## Camera entity with sound

The add-on provides a standard H.264 + AAC stream at `/stream.ts`. It's encoded only while something is watching. If the camera phone disconnects, the stream keeps running with a blank frame, so HA and HomeKit don't show errors.

Go to **Settings › Devices & services › Add integration › Generic Camera** and enter:

| Field | Value |
|---|---|
| Still image URL | `http://127.0.0.1:8098/snapshot.jpg` |
| Stream source | `http://127.0.0.1:8098/stream.ts` |
| Username / password | leave empty |

`127.0.0.1` is the mini PC itself. Only Home Assistant, running on the same machine, can reach it, so no password is needed. This works even before the Cloudflare setup is done.

For other devices on your network, such as an NVR, use `https://babycam.example.com:8443/stream.ts` with username `babycam` and your access code as the password.

Name the camera **BabyCam** so its entity is `camera.babycam`. The live view on dashboards includes sound.

## HomeKit (camera with sound, plus noise alerts)

Home Assistant recommends exposing cameras to HomeKit as their own accessory. Add this to `configuration.yaml` and restart Home Assistant. It's separate from any HomeKit Bridge you already have.

```yaml
homekit:
  - name: BabyCam
    port: 21065
    mode: accessory
    filter:
      include_entities:
        - camera.babycam
    entity_config:
      camera.babycam:
        name: BabyCam
        support_audio: true
        linked_motion_sensor: binary_sensor.babycam_noise
```

Then:

1. A pairing notification with a QR code appears in Home Assistant. In the Home app, tap **+ › Add Accessory** and scan it.
2. In the Home app, open the camera's settings, turn on **Activity Notifications**, and choose **Motion is detected**.

BabyCam's noise sensor acts as the camera's "motion" sensor, so the Home app sends a notification with a snapshot when the baby makes noise.

Home app notifications don't get through silent mode. For that, use the critical alert automation above.

HomeKit re-encodes the stream for each viewer. That's easy work for a mini PC. To save CPU, add `video_codec: copy` under `camera.babycam`; it usually works, but if the Home app shows a black picture, remove it.

### Keep the history small (optional)

The sound level sensor updates every 5 seconds. To keep it out of your database, add this to `configuration.yaml`:

```yaml
recorder:
  exclude:
    entities:
      - sensor.babycam_sound_level
```

## Troubleshooting

- **The camera address doesn't load on the phone.** Some routers block DNS answers that point to local IPs, a feature called "DNS rebinding protection". Allow your BabyCam hostname in the router, or add a local DNS entry for it, for example in AdGuard Home or Pi-hole.
- **"Certificate error" in the log.** Check the token's permissions and zone. The add-on retries every 15 minutes.
- **"already has a CNAME record".** That hostname is already used, probably by your tunnel. Choose a different `domain`.
- **Wrong access code too many times.** That device is blocked for 10 minutes.
- **No Light button on iPhone.** Safari doesn't let web pages control the flashlight. It works on Android phones in Chrome.
- **Night mode.** Phone cameras can't see in total darkness. A small night light makes a big difference.
- **The HA camera or HomeKit shows a black picture.** That's the blank frame, which means the camera phone isn't connected. Check that the camera page is open on the phone.
- **Portrait video has black bars.** The stream is 16:9 landscape. Stand the phone sideways and tap **Rotate** until the picture is upright.

## Privacy

- The stream only travels between devices on your home network, plus the HA panel through your own HA connection.
- HomeKit: at home, the Home app streams locally. Away from home, it goes through your Apple home hub and Apple's end-to-end encrypted relay.
- Your BabyCam hostname appears in public certificate transparency logs, as it does for every HTTPS certificate. It resolves to a private address that only works inside your home.
