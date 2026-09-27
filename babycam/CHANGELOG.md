# Changelog

## 0.1.0

- First version: browser camera page, browser and Home Assistant sidebar viewers, noise/camera/sound sensors, MJPEG camera endpoint, automatic Let's Encrypt certificate via Cloudflare DNS.

## 0.1.1

- Build on the official Node.js image (Docker Hub) instead of the Home Assistant base image.

## 0.1.2

- Drop deprecated build.yaml; install Node.js on the Home Assistant base image.

## 0.2.0

- New `/stream.ts`: H.264 + AAC stream with sound for Home Assistant (Generic Camera, go2rtc) and HomeKit Bridge. Runs only while watched, and keeps going with a blank frame if the camera phone disconnects.
