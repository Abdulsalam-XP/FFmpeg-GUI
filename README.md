# 🎥 Video Audio Tool – Quick Start Guide

A Windows app for compressing video, mixing audio tracks, trimming clips, and downloading from YouTube. It wraps `ffmpeg` and `yt-dlp` behind a normal desktop window — no terminal, no commands to memorise.

---

## ⚙️ Installation

**Download the release zip, unzip it, and run `Launcher.exe`. That's it.**

`ffmpeg.exe`, `ffprobe.exe`, and `yt-dlp.exe` ship inside the zip in a `bin/` folder, so there is nothing to install and nothing to add to your PATH.

<details>
<summary>Running from a source checkout instead</summary>

The binaries are not committed to this repository, so a `git clone` gives you everything except `src/bin/*.exe`. Either:

- drop `ffmpeg.exe`, `ffprobe.exe`, and `yt-dlp.exe` into `src/bin/`, **or**
- install them system-wide and let the app fall back to your PATH:
  ```powershell
  winget install yt-dlp.yt-dlp
  winget install yt-dlp.FFmpeg
  ```

The app looks in `src/bin/` first and only then falls back to PATH, so a bundled copy always wins over an installed one.
</details>

---

## ▶️ Usage

Launch with **`Launcher.exe`** (or `assets/Launcher Config.bat`). Do **not** run the `.ps1` directly — Windows blocks downloaded PowerShell scripts by default, and you will get `...cannot be loaded because running scripts is disabled on this system.`

Pick a tool from the sidebar, then drag a video onto the drop area or click it to browse. Long jobs show live progress and can be cancelled mid-run.

---

## 🔧 Features

| Screen | What it does |
|---|---|
| **Compress** | Three quality presets. Uses your NVIDIA GPU (NVENC) if you have one — there is a toggle for it. |
| **Merge Audio** | Mixes a video's separate audio tracks (e.g. system + mic) into one, with per-track volume. The video is copied, not re-encoded. |
| **Trim** | Cuts everything before or after a timestamp. No re-encode, so it is near-instant. |
| **YouTube MP3** | Downloads a video's audio as MP3 into `MP3 Downloads/`. |
| **YouTube MP4** | Lists the qualities a video actually offers, then downloads into `MP4 Downloads/`. |
| **Settings** | Toggle animations; shows which `ffmpeg`/`ffprobe`/`yt-dlp` the app resolved. |

---

## 🆘 Support

1. **Nothing happens when you launch it.** Startup failures show a message box with the error. If even that does not appear, run the script directly to see the reason:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Video-Audio-Tool.ps1
   ```
2. **A job fails immediately.** Open **Settings** — it lists the exact `ffmpeg`, `ffprobe`, and `yt-dlp` paths in use. A bare name there rather than a full path means the app found no bundled copy and is relying on your PATH.
3. **`running scripts is disabled on this system`.** Launch with `Launcher.exe` or `assets/Launcher Config.bat` rather than the `.ps1`.
4. **A YouTube download fails.** YouTube changes often; replacing `yt-dlp.exe` in `bin/` with the latest release usually fixes it.

---

## ⚠️ Disclaimer

This tool is a user-friendly wrapper/interface for existing software. I do not own, develop, or maintain FFmpeg, yt-dlp, or any of the underlying technologies used in this project. FFmpeg is developed and maintained by the FFmpeg team and contributors; yt-dlp by the yt-dlp project and its contributors. This project simply aims to make them more accessible and user-friendly through a graphical interface.

Any bundled `ffmpeg.exe`, `ffprobe.exe`, and `yt-dlp.exe` are unmodified third-party builds distributed under their own respective licenses, which apply to those files rather than to this project's own code.

All credit for the core functionality goes to the respective developers and maintainers of FFmpeg, yt-dlp, and related technologies.
