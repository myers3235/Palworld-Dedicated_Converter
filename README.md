# Palworld Dedicated → Local Save Converter

A guided Windows wizard that moves a Palworld world off a rented dedicated
server and onto your own PC as a normal local / co-op save. Your character,
pals, guild and bases come with it.

For when you want to stop paying for hosting but keep the world.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

## Download

**[Download the latest release](../../releases/latest)** → grab
`Palworld-Save-Converter.zip`, extract it anywhere, and double-click
**`Run Palworld Save Converter.cmd`**.

That's it. The wizard explains everything else as you go.

Windows will show *"Windows protected your PC"* the first time — click
**More info → Run anyway**. That warning appears for any script that isn't
code-signed, and code signing costs a few hundred dollars a year.

## ⚠️ The one thing everybody gets wrong

The converter website works in **both** directions, and it opens in the wrong
one. Before you touch anything on that page, click **"Dedicated to Co-op"** in
the top right of the Save converter box.

You got it right when Step 1 reads *"Choose your dedicated server save."*

If it says *"Choose your co-op save"*, or asks for a **dedicated player ID** or
a **SteamID64**, you're pointed backwards. The giveaway error is:

> The selected character already uses 308722BA00000000000000000000000000

In the correct direction there is no player ID to enter at all — you pick the
folder, pick your character, and convert. The wizard puts this warning on
screen at the right moment, but it's worth knowing before you start.

## What the wizard does for you

- **Finds your download by itself.** Scans Downloads and Desktop, opens each
  zip and checks whether there's actually a `Level.sav` inside. You pick from a
  list instead of hunting for a path. A zip works as-is — no need to extract it.
- **Finds your save slot by itself.** Detects your Steam save folder; you only
  get asked if there's genuinely more than one.
- **Catches the converted file by itself.** After it opens the converter, it
  watches your Downloads folder and picks up the converted zip the moment it
  lands. You never go looking for it.
- **Backs up before it writes.** If a world folder of the same name already
  exists, it's renamed to `.bak-<timestamp>`, never deleted.
- **Verifies the result** and offers to launch the game.

Your server download is opened read-only throughout.

## Steps

| | |
| --- | --- |
| Welcome | What this does, what you need |
| 1 | Download your world from the host panel — stop the server first |
| 2 | Your download — found automatically |
| 3 | Convert it, in your browser |
| 4 | Add it to your game |
| Done | Launch Palworld |

## Why is the conversion done in a browser?

Because that's the only part that can't be scripted. Palworld 0.6 switched the
save container from `PlZ` (zlib) to `PlM`, which is Oodle/Kraken compressed.
Windows and PowerShell have zlib built in; they have nothing for Oodle. The
open decoders are thousands of lines of C, which is exactly why the working
converters compile one to WebAssembly and run it in the browser.

That's also the good news: the conversion happens **on your machine**, inside
your browser. Nothing is uploaded. This script makes no network requests of its
own — it opens a page in your default browser and waits.

The wizard uses the
[TroubleChute converter](https://hub.tcno.co/games/palworld/converter/), which
is not affiliated with this project.

## Requirements

- Windows with PowerShell 5.1 (built in) or newer
- Palworld installed and launched at least once, so a save folder exists
- Access to your server host's file manager

## Troubleshooting

**"The selected character already uses 308722BA…"** — wrong direction on the
converter site. See the warning above.

**It can't find my download** — click *Find it myself*, or drag the zip onto
the box. Unextracted zips are fine.

**"Palworld has not made a save on this PC yet"** — launch the game, load any
world, quit, then click *Change*.

**The map is black / my explored area is gone** — map discovery lives per
player in `LocalData.sav` and isn't part of the world. Copy `LocalData.sav`
from the world folder you used while playing on the server into the new world
folder.

**Something looks wrong in the world** — stop playing, delete the imported
folder, and convert again from your original download. That's why you keep it.

## Contributing

Issues and pull requests welcome — especially corrections if the converter site
changes its layout or wording.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Pocketpair, Inc. Palworld is their trademark.
