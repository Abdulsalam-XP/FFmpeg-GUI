# FFmpeg GUI: WPF Frontend Redesign

## Goal

Replace the console menu (`Read-Host` loop in `Video-Audio-Tool.ps1`) with a native WPF window. The backend stays 100% PowerShell — the existing modules (`VideoProcessing.psm1`, `AudioProcessing.psm1`, `VideoTrimmer.psm1`, `YouTubeDownload.psm1`, `Settings.psm1`) keep their core logic; only the layer that talks to the user changes, from console prompts/`Write-Host` to a WPF window with real controls.

The console window itself is hidden entirely (launched with no visible terminal), so the app looks and behaves like any compiled native Windows app, even though PowerShell is still the runtime driving it.

## Non-goals (for this pass)

- No rewrite in Electron, Tauri, or Python — ruled out because it would mean re-implementing all ffmpeg/yt-dlp/GPU-detection/self-update logic from scratch, for a payload-size and startup-time regression (Electron bundles its own Chromium+Node runtime; WPF has none to bundle).
- No dual-mode "keep the old console menu too" — the GUI fully replaces it. One frontend to maintain, not two.
- No boot-intro animation, page-wipe transitions, custom cursor, or particle-text dissolve in v1. These were explored as inspiration (from the user's portfolio site) and confirmed technically feasible in WPF, but are explicitly deferred to a later pass. v1 ships with: sliding sidebar highlight, hover states, and the drifting glassmorphism glow only.
- "Convert File to MP4" stays a disabled/greyed nav item, same as today's console menu — no new functionality there.

## Requirement: bundle ffmpeg/ffprobe/yt-dlp

To minimize setup friction, ship `ffmpeg.exe`, `ffprobe.exe`, and `yt-dlp.exe` inside the release zip under a `bin/` folder, and call them by full path (`Join-Path $scriptRoot "bin\ffmpeg.exe"`) instead of relying on the user having them on `PATH` via winget. This removes the entire "Installation" section of the current README as a prerequisite. This change is orthogonal to the WPF rewrite and should land as part of the same effort since it directly serves the "zero setup" goal driving this redesign.

## Architecture

- **Runtime**: PowerShell, same as today. `Video-Audio-Tool.ps1` remains the entry point.
- **UI technology**: WPF, loaded via `[System.Windows.Markup.XamlReader]::Load()` from a XAML string/file, controls retrieved with `FindName()`, events wired with `.Add_Click({...})` / `.Add_Loaded({...})` etc. — the standard PowerShell+WPF pattern. No compiled `.xaml.cs`, no separate build step.
- **Launch without a console window**: `Launcher.exe` (and the `.bat` fallback) invoke `powershell.exe` with a hidden window style so no terminal is ever visible to the user; only the WPF window shows.
- **Module boundary stays the same, adapted at the edges**: `Get-VideoProperties`, `Get-SystemSpecs`, `Get-CompressionSuggestions`'s data (not its console printing), `Compress-Video`, `Merge-AudioStreams`, `Split-Video`, `Save-YouTubeMP3`, `Save-YouTubeMP4` keep their core ffmpeg/yt-dlp argument-building and process logic. What changes in each is the I/O seam:
  - Anything that did `Read-Host` (file selection, preset choice, volume adjustment, timestamp entry, YouTube URL entry) becomes a value passed in from a WPF control instead.
  - Anything that did `Write-Host`/`Write-AnimatedLine` for status becomes a bound property or a direct control update instead.
- **New module: `UI-WPF.psm1`** replaces the console-only pieces of `UI.psm1` for the GUI build:
  - Builds/exposes the main `Window` and named controls.
  - `Update-ProgressUI` replaces `Update-ProgressBar` — sets a WPF `ProgressBar.Value` and text blocks for percent/ETA instead of writing `\r`-prefixed console text.
  - `Invoke-FFmpegProcessAsync` replaces `Invoke-FFmpegProcess`'s **blocking** `while (-not $process.HasExited) { ReadLine() }` loop. WPF is single-threaded on the UI thread, so a blocking read loop there would freeze the window (no drag, no Cancel button, no window repaint). Instead: use `$process.add_ErrorDataReceived(...)` + `BeginErrorReadLine()` so ffmpeg's stderr is read asynchronously, and marshal each progress update back to the UI thread via `$window.Dispatcher.Invoke(...)`. Same idea applies to yt-dlp's stdout progress-template parsing in `YouTubeDownload.psm1`.
  - Adds a **Cancel button** capability (shown in the mockups) that calls `$process.Kill()` — this is new: the console version has no mid-run cancellation today.
- `Select-VideoFile`'s job (listing local `.mp4`s + the `MP4 Downloads` folder) becomes a file list bound to a WPF list/dropdown instead of a numbered console prompt, but the underlying `Get-ChildItem` logic is unchanged.
- `Import-Config`/`Save-Settings` (`Settings.psm1`) are unchanged — `ShowAnimations` still gates whether the fancier motion (pill glide, glow drift, hover transitions) plays, same as it already gates console animations today.
- **Self-update flow**: `Test-ScriptUpdates`'s GitHub-check/download logic is unchanged; only its WinForms "Update Available" dialog is restyled to match the new visual system in a later pass — not blocking for v1 (a plain dialog is acceptable initially).

## Navigation & Layout

Persistent left sidebar + content panel on the right (validated against two alternatives — top tabs and a card-based home grid — before settling here). Sidebar items: Compress, Merge Audio, Trim, YouTube MP3, YouTube MP4, Settings, plus a disabled "Convert to MP4 (Coming Soon)" entry. Selecting an item swaps the right-hand panel's content.

The active-item highlight is a gradient pill that **glides** to the newly-selected item (spring-ish ease, ~280ms) rather than snapping — this was chosen over a floating-dock nav and a home-grid nav specifically because it's the least disruptive to the already-approved sidebar structure while still reading as fluid.

## Visual Design System — "Midnight Gold"

Established and validated interactively across multiple mockup rounds:

- **Background**: a gradient mesh, not a flat/linear fill — four soft, blurred radial tones layered at the corners (gold top-left, navy top-right, plum bottom-left, deep navy bottom-right) over a `#090D1A` base, so empty space still has depth.
- **Accent gradient**: navy → navy → gold (`#152C61 → #1F3F7A → #D3A24C`), used consistently on: the active sidebar pill, the primary/selected button state, the progress bar fill, and highlighted numeric values.
- **Borders**: gold at ~18–22% opacity (`rgba(211,162,76,0.18–0.22)`) for dividers, panel edges, and card outlines.
- **Glow**: present but restrained — an early pass with heavy glow/shadow on every element was walked back by half; glow should read as an accent (sidebar pill, active button, drifting dropzone highlight) not a general lighting effect on everything.
- **Glassmorphism** (dropzone and similar "drop target" surfaces): semi-transparent dark fill + backdrop blur (`BlurEffect` behind a translucent panel in WPF terms, equivalent to `backdrop-filter` in the web mockup), a single soft gold-tinted glow blooming from one corner (not a moving diagonal shine bar — that was tried and explicitly rejected as looking like a stray shadow), a crisp 1px light border, and a drop shadow for lift. The corner glow **slowly drifts left-right** on a loop (~6s ease-in-out) rather than sitting static.
- **Cards**: gradient-border technique — a gradient-filled outer shape with a solid dark inner panel on top, giving a thin gradient outline without a flat gradient fill.
- **Typography split**:
  - **Plus Jakarta Sans** — nav labels, sidebar items, screen titles, and all buttons (anything clickable).
  - **JetBrains Mono** — file metadata line, the codec/size/output value table, percentage + ETA readouts (anything read as data/output, not acted on).

## Screens (v1 scope)

Each maps directly to an existing console menu option and its module function:

1. **Compress** → `Get-VideoProperties` / `Get-SystemSpecs` / `Get-CompressionSuggestions` / `Compress-Video`. File drop/browse, GPU-mode toggle (only shown if NVIDIA detected, same as today), 3 preset buttons, progress + cancel.
2. **Merge Audio** → `Merge-AudioStreams`. File pick, detected-stream list, optional volume adjustment controls, progress + cancel.
3. **Trim** → `Split-Video`. File pick, Before/After mode, timestamp entry (validated against duration same as today), progress + cancel.
4. **YouTube MP3** → `Save-YouTubeMP3`. URL entry, progress + cancel.
5. **YouTube MP4** → `Save-YouTubeMP4`. URL entry, resolution list (only resolutions actually available, same filtering logic as today), progress + cancel.
6. **Settings** → `Import-Config` / `Save-Settings`. Animations on/off toggle (same setting, now a real toggle control instead of a text menu).

## Error Handling

Existing `Write-ErrorDetails`-style error surfacing (video analysis failures, missing output file, ffmpeg non-zero exit) moves from `Write-Host`-red-text to an in-panel error state (e.g., a red-bordered message area within the current screen) rather than a modal, so the user isn't blocked from immediately retrying. Cancellation via the new Cancel button is treated as a normal (non-error) stopped state, not a failure.

## Testing

- Manual verification per screen against real files: compress (CPU and, if available, NVIDIA), merge-audio on a multi-stream file, trim before/after, YouTube MP3/MP4 download against a real URL — mirroring the manual verification the console version already relies on (this codebase has no automated test suite today).
- Specifically verify the window stays responsive (draggable, Cancel clickable) *during* an active ffmpeg/yt-dlp run, since this is the behavior that requires moving off the old blocking read loop.
- Verify `ShowAnimations = false` in `settings.json` disables the pill glide / glow drift / hover transitions, matching how it already disables console animations.
