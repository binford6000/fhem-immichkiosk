# FHEM ImmichKiosk

FHEM module to control an [immich-kiosk](https://github.com/damongolding/immich-kiosk) slideshow:
album selection, virtual albums and automatic album rotation via URL parameters. Optional: push the
URL to a Fully Kiosk Browser via its REST API.

No SSH, no scripts on the kiosk host, no changes to `config.yaml`.

> **Note:** This module was and is developed with AI assistance ("vibe coded", Claude by Anthropic).
> It is tested in the maintainer's own setup; use at your own risk.

## Requirements

- Immich API key with permissions `album.read` and `asset.read` (the latter only for layout calculation)
- immich-kiosk reachable from the display device
- optional: Fully Kiosk Browser with Remote Admin enabled

## Installation

```
update add https://raw.githubusercontent.com/binford6000/fhem-immichkiosk/main/controls_immichkiosk.txt
update
shutdown restart
```

## Quick start

```
define kiosk ImmichKiosk http://immich.lan:2283 http://kiosk.lan:3000
set kiosk apiKey <immich-api-key>
attr kiosk fullyUrl http://10.3.3.50:2323
set kiosk fullyPassword <fully-password>
set kiosk album <name>
set kiosk rotation on
```

Full documentation: `help ImmichKiosk` in FHEM.
