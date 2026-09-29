# Changelog

## 1.0.12

- **Rows no longer stay on screen at 0.** A row is removed when its timer runs out, when that mob dies, or when it leaves combat. Pack refresh only touches mobs that are still visible, alive and in combat, so a missed death can no longer keep a dead mob's row alive.
- **Same-name mobs are tracked separately.** Rows are matched by GUID, then by nameplate, then by target/focus token — never by name.
- **Your character, party members and pets are never shown.** A unit must be provably a hostile NPC (not a player, not player-controlled, attackable). Getting hit no longer resets whatever you are targeting unless it is actually attacking your group. Each row keeps its own portrait, painted once from a verified token, instead of being re-read from recycled nameplates.
- **No double row for one mob.** When GUIDs are hidden, your target and its nameplate are linked by the nameplate frame itself, and any leftover duplicate is merged on the next tick.
- **An evading mob is not kept alive by the next pull.** Pack refresh skips mobs that have dropped their target (running home).
- **Mob names in dungeons.** Forever hides names there as secret values; they are now passed straight to the display instead of being replaced by "Mob".

## 1.0.11

- **Live timer no longer deleted by “mob died” heuristics.** Death is only `UnitIsDead` on that exact mob (your target, or combat-log GUID). Nameplates, health 0, and plate recycle no longer wipe the row mid-fight.
- **Leash does not start when you press the key / finish the cast.** Entering combat from a Fireball in the air is ignored. The timer starts when the mob is hit, takes aggro, or runs at you.

## 1.0.10

- **Leash starts on hit or aggro, not on cast.** A Fireball in the air no longer starts the timer; it starts when the mob is hit or starts running at you.
- **Timer no longer vanishes mid-fight.** Empty nameplates were treated as corpses (`health == 0`), which deleted the live row. Only a confirmed dead mob drops its line.

## 1.0.9

- **Dead mobs drop instantly.** Killing a boar no longer leaves a leftover row with a question-mark portrait for half a second. The line is removed as soon as the mob dies.

## 1.0.8

- **DoTs do not refresh leash.** Fireball burn, Ignite, Corruption, Immolate, SW:P, Serpent Sting, and other periodic ticks no longer reset the timer. Only the initial cast/hit does, like Classic.

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
