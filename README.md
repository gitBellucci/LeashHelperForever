# LeashHelperForever

<p align="center">
  <img src="Media/icon.png" alt="LeashHelperForever" width="200">
</p>

Estimated Classic **leash timer** for [WoW Forever](https://worldofforever.com/). Shows a countdown on each mob you are fighting so you can refresh the leash before they run home.

Inspired by the [Leash helper](https://wago.io/f1tzlceQj) WeakAura. Forever blocks combat-log registration under secret restrictions, so this is an estimate from public events — not a hidden server value.

![In-game leash timers](docs/ingame.png)

![Options preview](docs/options.png)

## Install

Prefer the [release zip](https://github.com/gitBellucci/LeashHelperForever/releases/latest) (`LeashHelper.zip`). Do **not** use GitHub’s green **Code → Download ZIP** unless you rename the folder.

1. Extract so the folder is named exactly **`LeashHelper`** (not `LeashHelper-main` or `LeashHelperForever-main`)
2. Put that folder in `World of Warcraft\_classic_beta_\Interface\AddOns\`
3. Restart WoW (a `/reload` is not enough the first time)
4. Enable **LeashHelperForever** in the addon list

If it does not appear: the folder name must match the `.toc` file. Rename `LeashHelper-main` → `LeashHelper`.

## Use

- `/leash` — options (preview, font, sizes, portraits, names, disable in dungeons)
- `/leash lock` — lock or unlock dragging
- `/leash preview` — show the timer on screen so you can drag it
- `/leash debug` — copyable log of why timers show or hide
- `/leash test` — sample timer
- `/leash reset` — reset position
- `/leash help` — command list

Each row is one mob. Hitting any of them refreshes the leash on the whole pack (Classic linked groups). When that mob dies or leaves combat, only that row disappears.

Duration by mob level: 1–29 **11s**, 30–39 **12s**, 40–44 **13s**, 45–49 **14s**, 50+ **15s**. Refreshes on damage, Auto Shot / wand / harmful spells, and a melee hit while you are standing still. Pauses while the mob is CC’d.

## Game versions

- Classic Forever (`Interface` 16001 / 11601)

## License

MIT
