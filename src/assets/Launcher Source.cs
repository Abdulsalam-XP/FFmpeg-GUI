// FFmpeg-GUI launcher.
// Deliberately does NOT embed or host the PowerShell script: it only starts
// powershell.exe with -ExecutionPolicy Bypass on the Video-Audio-Tool.ps1 that
// sits next to this exe, so script updates never require rebuilding the launcher.
//
// Rebuild (run from the src folder, where Launcher.exe lives):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe
//     /win32icon:"assets\Icon.ico" /r:System.Windows.Forms.dll /out:Launcher.exe "assets\Launcher Source.cs"

using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "Video-Audio-Tool.ps1");

        if (!File.Exists(script))
        {
            MessageBox.Show(
                "Video-Audio-Tool.ps1 was not found next to Launcher.exe.\n\n" +
                "Make sure you extracted the whole folder and are running the launcher from inside it.",
                "FFmpeg GUI Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"",
            WorkingDirectory = dir,
            UseShellExecute = false
        };

        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Failed to start PowerShell:\n" + ex.Message,
                "FFmpeg GUI Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
