# Palworld Dedicated → Local Save Converter

A guided Windows wizard that moves a Palworld world off a rented dedicated server
and onto your own PC as a normal local / co-op save. Your character, pals, guild
and bases come with it.

Built for the case where you want to stop paying for hosting but keep the world.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)

## Why this exists

A dedicated-server save and a local save are stored differently — mainly in how
your character is bound to the world — so the files cannot simply be copied
across. A converter fixes that, but the steps around it (stopping the server,
pulling the right folder, finding your local save slot, putting the result in the
right place without destroying an existing world) are fiddly and easy to get
wrong.

This wizard handles all of that. It does not reimplement the conversion itself —
that is done by an existing in-browser converter, which is the part it hands off to.

## Getting started

1. Download this repository (green **Code** button → **Download ZIP**) and extract it.
2. Double-click **`Run Palworld Save Converter.cmd`**.
3. Follow the wizard.

If Windows shows a *"Windows protected your PC"* box, click **More info → Run
anyway**. That appears for any unsigned script.

Everything else is explained inside the wizard — there is nothing you need to
know in advance.

## What the wizard walks you through

| Step | What happens |
| --- | --- |
| Welcome | What this does, what you need |
| 1 | Downloading your world from the host control panel — stop the server first |
| 2 | Locating that download; it searches for `Level.sav` and validates the world |
| 3 | Choosing your local save slot; auto-detects your SteamID64 folder |
| 4 | The conversion, in your browser (the one manual step) |
| 5 | Importing the converted ZIP, with automatic backup of anything replaced |
| Done | Where it landed, and how to load it in game |

## Safety

- Your server download is opened **read-only** and is never modified.
- If importing would replace an existing world folder, the old one is renamed to
  `.bak-<timestamp>` rather than deleted.
- The conversion runs as WebAssembly inside your own browser. Your save is never
  uploaded anywhere. This script makes no network requests of its own; it only
  opens a converter page in your default browser.

Keep your original server download until you have loaded the converted world and
confirmed it looks right.

## Requirements

- Windows with PowerShell 5.1 (built in) or newer
- Palworld installed, and launched at least once so a save folder exists
- A web browser
- Access to your server host's file manager

## Converters used

The wizard offers a choice of two; both run entirely client-side:

- [TroubleChute Palworld Save Converter](https://hub.tcno.co/games/palworld/converter/)
- [Physgun Palworld Save Converter](https://physgun.com/tools/palworld-save-converter/)

Neither is affiliated with this project. If their page layout changes, the
wizard's step 4 instructions may describe buttons slightly differently than what
you see — the flow is the same: select folder, choose dedicated → co-op, pick
your character, convert, download.

## Troubleshooting

**"No Level.sav found"** — wrong folder, or you pointed it at a `.zip` that has
not been extracted. Extract it first, then select the extracted folder.

**"No save slots found"** — Palworld has never written a save on this PC. Launch
the game, load any world, quit to desktop, then click Refresh.

**Converted world does not appear in game** — confirm it landed in the folder
named with a 17-digit number (your Steam ID). The wizard's final screen has a
button that opens it.

## Files

| File | Purpose |
| --- | --- |
| `Run Palworld Save Converter.cmd` | Launcher — double-click this |
| `Convert-PalworldSave.ps1` | The wizard |
| `READ ME FIRST.txt` | Offline version of the quick-start, for people who download the ZIP |

Both scripts must stay in the same folder.

## Contributing

Issues and pull requests welcome — particularly corrections to the step 4
instructions if a converter's interface has changed.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Pocketpair, Inc. Palworld is their trademark.
