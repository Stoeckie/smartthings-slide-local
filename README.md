# Slide Curtain (local) — SmartThings Edge driver

Local control of **Slide curtain motors** in SmartThings, over the Slide Local API on your own network. No cloud, no Slide app needed after setup, and it keeps working if the Slide servers ever disappear.

Which Slide? The **retrofit curtain motor "Slide" by Innovation in Motion (Amsterdam)**, since 2024 continued by Smart Innovation Partners (slide.store). It is the white box you clip onto an existing curtain rail, Wi-Fi only. It is **not** the Zemismart/Tuya "slide" curtain track, not SwitchBot Curtain, and not a Zigbee or Matter motor; those have their own drivers.

## What you get

Per Slide one SmartThings device with:

* Open / close / pause
* Position 0 to 100 % (100 = open)
* Refresh, online/offline state
* Works with API v2 firmware (no password) and API v1 firmware (Digest auth with the 8 character device code)

Everything runs on the hub. Commands go straight to the Slide over HTTP.

## Requirements

* SmartThings hub with Edge (v2, v3/Aeotec, Station, or a Samsung TV/monitor with hub)
* Slide on the same network as the hub, with the **local API switched on**:
  * Recent firmware (API v2, after Aug 2023): enable Local API in the Slide app. No password.
  * Old firmware (API v1): press the reset button twice. LED blinks 5x fast = local API on, cloud off; 2x slow = back to cloud. Enter the device code printed on the Slide in the device settings. Note: on old firmware the Slide app stops working while the local API is on.
* Give each Slide a fixed IP (DHCP reservation) so the hub always finds it.

## Install

1. Enroll your hub in the channel: https://bestow-regional.api.smartthings.com/invite/qWjBdybRNG2y (Stoeckie Edge Drivers) and install **Slide Curtain (local)**.
2. SmartThings app: Add device > Scan for nearby devices. The driver scans the hub's subnet and creates one device per Slide it finds, named `Slide <last 4 of MAC>` (or the zone name from the Slide app). The IP is stored on the device. A later scan updates the IP if it changed.
3. Only if a Slide is not found: open the device > Settings and fill in its IP address.

## Settings

| Setting | Meaning |
|---|---|
| Slide IP address | `auto` (found by scan) or a fixed IP |
| Device code | Only for API v1 firmware |
| Poll interval | Position refresh while idle, default 60 s |
| Invert position | If 100 % shows as closed instead of open |

## How it works

* Slide reports `pos` 0 = open, 1 = closed; SmartThings shows level 100 = open, 0 = closed.
* After a command the driver polls every 2 s until the curtain stops (max 45 s), then every poll interval.
* Level ≥ 95 = open, ≤ 5 = closed, in between "partially open" (a Slide rarely reports exactly 0 or 1).
* No answer from the Slide = device offline until the next successful poll.

## Build it yourself

```
smartthings edge:drivers:package . --channel <your channel> --hub <your hub>
```

`config.yaml` needs both `lan` and `discovery` permissions. Without `discovery` the hub never sends a scan to the driver and never even starts it. Permissions can not be changed on an existing driver id, so changing them means a new `packageKey`.

Files: `src/init.lua` (driver, discovery, commands, polling), `src/slide_api.lua` (HTTP client, JSON RPC, Digest auth), `src/md5.lua` (pure Lua MD5 for Digest, the hub has no md5 library).

## Slide Local API (for reference)

POST, JSON body, port 80:

* `/rpc/Slide.GetInfo` → `{"slide_id","mac","board_rev","device_name","zone_name","curtain_type","calib_time","pos","touch_go"}`
* `/rpc/Slide.SetPos` body `{"pos": 0.0..1.0}`
* `/rpc/Slide.Stop`
* `/rpc/Slide.Calibrate` (in `slide_api.lua`, not wired to a button)

API v1 answers 401 with a Digest challenge: user `user`, password = device code, MD5, qop auth.

Thanks to [ualex73/goslide-api](https://github.com/ualex73/goslide-api) (Home Assistant library) and [vdBrink's notes](https://vdbrink.github.io/projects/slide_smart_curtains.html) for documenting the API.

## Logs

`smartthings edge:drivers:logcat --hub-address <hub ip>`, lines start with `[slide]`.

## Terms

Free community driver, provided "as is" without warranty (Apache License 2.0). Not affiliated with Innovation in Motion, Smart Innovation Partners or Samsung SmartThings.
