# Changelog

## 1.0.7

### Fixes
- **Player / pet / nearby portraits:** combat events on your nameplate, warlock/hunter pet plates, and nearby in-combat players no longer steal a mob row. Only world NPCs are tracked. Recycled nameplate tokens cannot overwrite the portrait or name.
- **Timer disappeared in combat:** a Lua error on every leash reset (`PersistableUnit` called helpers before they existed) silently killed pulls. Forever secret `UnitExists` / `UnitCanAttack` on `target` is no longer treated as “not a mob.”
- **Same-name packs:** killing one leopard (or any duplicate name) while still fighting another used to keep the dead row until the last one died. Each line is bound to one creature; the dead row drops immediately.
- **Pack leash:** hitting any mob you are fighting now refreshes the leash on the **whole pack**, matching Classic linked groups (Vanilla hotfix). After you kill one and run, the survivors keep a full timer instead of counting down from an old per-mob hit.

### Features
- **Previsualize:** options toggle (and `/leash preview`) shows the real on-screen timer so you can drag it into place, even if Lock is on. Turn it off when you are done.
- **Debug log:** `/leash debug` (or the options checkbox) opens a copyable snapshot of why timers show or hide. Ctrl+A, Ctrl+C, paste if something looks wrong.

## 1.0.2

- New option **Disable in dungeons** (on by default). Leash timers stay off in 5-man dungeons; uncheck it if you want them inside.

## 1.0.1

- Leash list only tracks hostile NPCs you engage. Player characters, your own character, pets, and party/raid members are never shown.

## 1.0.0

- First public release
- Per-mob estimated leash countdown (not a single shared fight timer)
- Timer drops when that mob leaves combat, even if you are still in combat with others
- Compact one-line display: portrait, name, countdown
- Live preview in options; font, sizes, portraits, and names
- Forever-safe: no combat-log register under secret restrictions
