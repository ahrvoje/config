# Total Commander profile

## New installation

1. In **Help → About Total Commander**, find the path to `wincmd.ini`. A standard per-user installation normally uses `%APPDATA%\GHISLER`. Close all Total Commander windows before changing the files.
2. For a fresh profile, copy the six `.ini` files from this folder into that settings folder. If the installer has already created a `wincmd.ini`, keep a backup. Follow the merge instructions below if it contains settings you want to keep.
3. Start Total Commander normally. It loads `usercmd.ini` automatically. On a machine with a G drive, press **Shift+G** in a file panel to switch to that drive. Right-click a file-panel column header to select **Size**, **Random** or **Created**.
4. For the three NTFS link colors, download the NTLinks ZIP and open it inside Total Commander. Accept the plugin installation and its default folder. Repeat this step on each new installation that lacks NTLinks. The same archive supports 32-bit and 64-bit Total Commander. [NTLinks 1.6.1.294](https://totalcmd.net/plugring/ntlinks.html)

To inspect the commands, open **Configuration → Options → Misc.** Under **Redefine hotkeys**, click the small down arrow beside **Hotkey** and choose the existing **Shift+G** binding. The **Command** field should show `em_GotoDriveG`. Click the magnifying glass beside that field to open **Choose command**. Near the bottom of its **Category** list, select **usercmd.ini** to see the drive commands from G through Y. Click **Cancel** when finished inspecting.

On reinstall, select the same settings folder in Setup. All six files are then available on the first launch. For a new PC or Windows user, include the six files in the per-user settings folder when preparing the installation. Keep a writable copy there so changes made in Total Commander stay local to that profile.

| File | Purpose |
| --- | --- |
| `wincmd.ini` | Directs each settings section to its file with `RedirectSection`. |
| `preferences.ini` | File panels, fonts, selection, confirmations, ZIP compression and Lister. |
| `file-colors.ini` | The palette, 23 ordered color rules and their named search definitions. |
| `shortcuts.ini` | F2 renames the item under the cursor. Shift+F2 edits the path above the active file panel. Ctrl+C copies full names. Shift+letter selects drives A and C through Z. |
| `columns.ini` | The Size, Random and Created column sets. All three use Total Commander's built-in fields. |
| `usercmd.ini` | Named drive commands for G through Y. Total Commander reads this file beside the active `wincmd.ini`. |

Total Commander writes plugin registrations to `plugins.ini`, the Start menu and directory hotlist to `user.ini`, and panel paths, tabs and histories to `history.ini` as needed. These files belong to the local profile. To use the previous profile's optional Notepad++ editor, select the installed executable under **Configuration → Options → Edit/View**.

## File colors

Total Commander uses the first matching rule. Symbolic links, junctions and hard-linked files keep their link colors at every age. Other items appear white for the first 15 minutes after modification, then light gray until one hour. After that, a video such as `.mkv` or `.mp4` appears bright cyan (`#00FFFF`). Subtitle files such as `.srt`, `.ass` and `.vtt` use the default gray (`#88959F`).

| Link | Color | What gets the color |
| --- | --- | --- |
| Symbolic link | Blue `#59AFFF` | The link to a file or directory. |
| Directory junction | Mint green `#50F0AC` | The junction itself, including Windows profile junctions such as `PrintHood`. Volume mount points have a separate NTLinks type. |
| Hard-linked file | Rose `#FFA6BE` | Every name of a regular file with more than one hard link. |

| Scientific file type | Examples | Color |
| --- | --- | --- |
| Source | Julia `.jl`, Wolfram `.wl`, Python `.py`, TypeScript `.ts` | Violet `#BE83FF` |
| Configuration and text data | `.json`, `.toml`, `.yaml`, `.ini` | Ice blue `#A8DFF3` |
| Notebook | Wolfram `.nb`, Jupyter and Google Colab `.ipynb` | Electric blue `#679FFF` |
| Dataset | NumPy `.npy` and `.npz`, Parquet `.parquet`, tables `.csv` and `.tsv` | Green `#78B89C` |
| Model | `.onnx`, `.gguf`, `.safetensors`, `.ckpt`, `.pt`, `.pth` | Lavender `#BDA2DB` |

Marimo notebooks saved as Python (`.py`) use the source color. Those saved as Markdown (`.md`) use the document color. A marimo notebook exported as `.ipynb` uses the notebook color. [Marimo file formats](https://docs.marimo.io/guides/editor_features/watching/) · [Google Colab FAQ](https://research.google.com/colaboratory/faq.html)

## Existing profile

Back up the active settings folder and close Total Commander. Each redirect selects an entire section for both reads and writes. For example, activating the supplied `[Shortcuts]` redirect makes `shortcuts.ini` the source of all custom shortcuts.

1. Merge existing keys you want to keep into the matching sections of the companion INIs. If your profile already uses redirects, read the values from their current destinations. Keep the order of any existing color rules and the numbering of any column sets referenced by your own view modes. Merge named `[em_...]` sections into an existing `usercmd.ini`.
2. In the active `wincmd.ini`, add or update the corresponding `RedirectSection` entries from the supplied file. When redirecting `[Configuration]`, keep `UseIniInProgramDir` and `AlternateUserIni` in the primary INI if your installation uses them. Carry other local settings, such as the editor or interface language, into `preferences.ini`.
3. Keep existing plugin, hotlist and history files. If these sections currently live in the main INI, either leave them there or move their contents before enabling their redirects. Restart Total Commander.

## Command files

The vendor's `TOTALCMD.INC` maps built-in command names to numbers. Its language-specific counterparts under `LANGUAGE\WCMD_*.INC` supply translated descriptions. Total Commander's standard file for language-independent user commands is `usercmd.ini`. For example, `[em_GotoDriveG]` calls command `2067`, the same drive action the old repository copy named `cm_GotoDriveG`. Shortcuts, menus and buttons can use the new name. If a personal menu or button still uses an old G–Y command name, change its prefix from `cm_` to `em_`. [Command catalogue](https://www.ghisler.ch/wiki/index.php/Totalcmd.inc) · [Command browser](https://www.ghisler.ch/wiki/index.php?title=Command_browser)
