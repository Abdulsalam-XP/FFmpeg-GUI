# 🎥 Video Audio Tool – Quick Start Guide

A handy PowerShell script for processing `.mp4` files using `ffmpeg`. Compress videos, extract audio, and more – all from the comfort of your terminal!

---

## ⚙️ Installation – `ffmpeg & Yt-dlp` (Skip if Already Installed)

1. **Open PowerShell as Administrator**  
   Right-click PowerShell and select **"Run as Administrator"**

2. **Install `ffmpeg & yt-dlp` via Winget**  
   Paste the following command into PowerShell:
   ```powershell
   winget install Gyan.FFmpeg
   ```

3. **Restart PowerShell**

4. **Verify Installation**  
   Run this command to check if ffmpeg is correctly installed:
   ```powershell
   ffmpeg -version
   ```
   Run this command to check if Yt-dlp is correctly installed:
   ```powershell
   yt-dlp -version
   ```

---

## ▶️ Usage Instructions

- ⚠️ **Important**: Make sure that there is atleast one video present in the directory of your folder


- ⚠️ **Important**: The script will not run if no `.mp4` files are present

---

## 🔧 Features

- Process multiple `.mp4` files in batch
- Video compression and optimization
- Audio extraction from video files
- Easy-to-use PowerShell interface

---

## 🆘 Support

If you encounter issues:
1. Check that FFmpeg is properly installed (`ffmpeg -version`)
2. Ensure you have `.mp4` files in the same directory as the script
3. Run PowerShell as Administrator if you get permission errors
4. If for whatever reason your script is executing for one second then closing, open powershell normally, navigate to your folder and execute the script to fetch the error message by typing:
   
   ```
   ./Video-Audio-Tool
   ```
   You can try showing the message to any AI model for any further assistance 
   

---

## ⚠️ Disclaimer

This tool is a user-friendly wrapper/interface for existing software. I do not own, develop, or maintain FFmpeg or any of the underlying technologies used in this script. FFmpeg is developed and maintained by the FFmpeg team and contributors. This project simply aims to make the process of using FFmpeg more accessible and user-friendly through a PowerShell interface.

All credit for the core functionality goes to the respective developers and maintainers of FFmpeg and related technologies.
