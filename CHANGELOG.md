# Changelog

## 1.0.0 (2026-10-29)

First release.

- **Timing bar**: shows the time left until an enemy's hit lands, with the game's Perfect Block window
  in green. Read from the attack animation every frame (follows combos, play-rate changes and interrupted
  attacks); about 10 ms from the real hit in testing.
- **Every block is perfect** mode: makes the game's Perfect Block window very long on your character and
  puts it back when you switch modes.
- **In-game menu (F6)**: mode, bar lead time, bar size and bar position. Saved to `config.ini`.
- English and Brazilian Portuguese, following the game's language.
- Short preview of the bar when you enter a world.
