// FFmpeg-GUI launcher.
// Deliberately does NOT embed or host the PowerShell script: it only starts
// powershell.exe with -ExecutionPolicy Bypass on the Video-Audio-Tool.ps1 that
// sits next to this exe, so script updates never require rebuilding the launcher.
//
// It also draws the loading splash (the app icon with a gold ring orbiting it).
// PowerShell takes seconds to start, check for updates and build the window, and
// with a hidden console there was nothing on screen for that whole time. The
// launcher is a tiny native-fast exe, so it can show something at once; it stays
// alive only until the app's own window appears, then fades the splash and exits.
//
// Rebuild (run from the src folder, where Launcher.exe lives):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe
//     /win32icon:"assets\Icon.ico" /r:System.Windows.Forms.dll /r:System.Drawing.dll
//     /out:Launcher.exe "assets\Launcher Source.cs"

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

static class Launcher
{
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

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

        // Hidden window + CreateNoWindow: the app is a WPF window now, and a console
        // flashing up behind it would give away that this is a script.
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"",
            WorkingDirectory = dir,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        Process child;
        try
        {
            child = Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Failed to start PowerShell:\n" + ex.Message,
                "FFmpeg GUI Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        // The splash is decoration: if anything about it fails, the app is already
        // starting and must not be taken down or blocked by its loading screen.
        try
        {
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.Run(new SplashForm(child, dir));
        }
        catch { }
    }
}

// A per-pixel-alpha layered window: the only way to get antialiased edges on a
// frameless shape (TransparencyKey gives a hard, fringed cut-out). Nothing is ever
// painted the normal way; each frame is composed into a 32bpp bitmap and handed to
// UpdateLayeredWindow, which also carries the whole-window fade.
//
// Frames are paced by the desktop compositor, not by a timer. A WinForms Timer is
// built on WM_TIMER, which rounds to the ~15.6ms system tick and waits behind every
// other message, so "16ms" really delivered an uneven 30-odd frames a second.
// DwmFlush returns once per screen refresh, so the ring advances exactly once for
// every frame the monitor shows: 60 a second on a 60Hz screen, more on a faster one.
// The ring's angle comes from the clock, so its speed is the same either way.
sealed class SplashForm : Form
{
    const int WS_EX_TOPMOST = 0x00000008;
    const int WS_EX_TOOLWINDOW = 0x00000080;   // no taskbar button to flicker at hand-over
    const int WS_EX_LAYERED = 0x00080000;
    const int WS_EX_NOACTIVATE = 0x08000000;   // never steals focus from what the user is doing

    const int LogicalSize = 196;
    const int IconSize = 112;
    const float RingRadius = 86f;
    const float RingStroke = 4f;
    const double SpinSeconds = 1.1;
    const double FadeInSeconds = 0.20;
    const double FadeOutSeconds = 0.25;
    const double TimeoutSeconds = 90;

    static readonly Color Gold = Color.FromArgb(0xD3, 0xA2, 0x4C);

    readonly Process child;
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly float scale;
    readonly int size;
    readonly Bitmap backdrop;   // glow + icon + faint ring: drawn once
    // The frame lives in a DIB section that stays selected into memDc for the life of
    // the splash, and the Bitmap is a view onto those same pixels: GDI+ draws straight
    // into what UpdateLayeredWindow reads. The first version made a fresh HBITMAP copy
    // of the frame on every tick, which was most of the per-frame cost.
    readonly Bitmap frame;
    readonly IntPtr memDc;
    readonly IntPtr hDib;
    readonly IntPtr oldBitmap;
    double fadeOutStart = -1;
    volatile bool appUp;
    volatile bool running;

    public SplashForm(Process child, string dir)
    {
        this.child = child;

        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { scale = g.DpiX / 96f; }
        size = (int)Math.Round(LogicalSize * scale);

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Rectangle screen = Screen.PrimaryScreen.Bounds;
        Bounds = new Rectangle(screen.Left + (screen.Width - size) / 2,
                               screen.Top + (screen.Height - size) / 2, size, size);
        Cursor = Cursors.AppStarting;

        // Premultiplied throughout: it is what UpdateLayeredWindow wants, and copying
        // the backdrop into the frame is then a plain memory blit.
        backdrop = new Bitmap(size, size, PixelFormat.Format32bppPArgb);

        BITMAPINFOHEADER header = new BITMAPINFOHEADER();
        header.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        header.biWidth = size;
        header.biHeight = -size;        // negative = top-down, the row order Bitmap expects
        header.biPlanes = 1;
        header.biBitCount = 32;
        IntPtr bits;
        memDc = CreateCompatibleDC(IntPtr.Zero);
        hDib = CreateDIBSection(memDc, ref header, 0, out bits, IntPtr.Zero, 0);
        oldBitmap = SelectObject(memDc, hDib);
        frame = new Bitmap(size, size, size * 4, PixelFormat.Format32bppPArgb, bits);

        DrawBackdrop(dir);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Present(0);

        // Asking a process for its main window walks every top-level window on the
        // desktop. Done on the drawing thread it cost a visible hitch several times a
        // second, so it has a thread of its own and only raises a flag.
        Thread watcher = new Thread(WatchForApp);
        watcher.IsBackground = true;
        watcher.Start();

        BeginInvoke(new MethodInvoker(RunFrames));
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        running = false;
        base.OnFormClosed(e);
    }

    void WatchForApp()
    {
        while (!appUp)
        {
            if (AppIsUp()) { appUp = true; return; }
            Thread.Sleep(100);
        }
    }

    // One frame per screen refresh until the splash has faded out. DoEvents keeps the
    // window answering Windows in between, so it never shows as "not responding".
    void RunFrames()
    {
        running = true;
        while (running && !IsDisposed)
        {
            double now = clock.Elapsed.TotalSeconds;
            if (fadeOutStart < 0 && (appUp || now > TimeoutSeconds)) fadeOutStart = now;

            double alpha = Math.Min(1.0, now / FadeInSeconds);
            if (fadeOutStart >= 0)
            {
                double left = 1.0 - (now - fadeOutStart) / FadeOutSeconds;
                if (left <= 0) break;
                alpha = Math.Min(alpha, left);
            }

            Present((byte)(alpha * 255));

            // Blocks until the compositor has put a frame on screen. If composition
            // is somehow unavailable it returns at once, so fall back to a short nap
            // rather than spinning a core.
            if (DwmFlush() != 0) Thread.Sleep(8);
            Application.DoEvents();
        }
        running = false;
        if (!IsDisposed) Close();
    }

    // True once there is nothing left to wait for: the app has a visible window (the
    // main window, or the update prompt, or the could-not-start message box), or
    // PowerShell died without ever showing one.
    bool AppIsUp()
    {
        try
        {
            if (child.HasExited) return true;
            child.Refresh();
            return child.MainWindowHandle != IntPtr.Zero;
        }
        catch { return true; }
    }

    void DrawBackdrop(string dir)
    {
        float c = size / 2f;
        using (Graphics g = Graphics.FromImage(backdrop))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);

            // Soft gold glow, brightest behind the icon and gone by the ring.
            float glowR = 92f * scale;
            using (GraphicsPath glow = new GraphicsPath())
            {
                glow.AddEllipse(c - glowR, c - glowR, glowR * 2, glowR * 2);
                using (PathGradientBrush brush = new PathGradientBrush(glow))
                {
                    ColorBlend blend = new ColorBlend();
                    blend.Positions = new float[] { 0f, 0.35f, 1f };   // 0 = edge, 1 = centre
                    blend.Colors = new Color[] {
                        Color.FromArgb(0, Gold), Color.FromArgb(60, Gold), Color.FromArgb(150, Gold) };
                    brush.InterpolationColors = blend;
                    g.FillPath(brush, glow);
                }
            }

            float icon = IconSize * scale;
            float left = c - icon / 2f;
            using (Bitmap art = LoadIcon(dir, (int)Math.Ceiling(icon)))
            {
                if (art != null)
                {
                    // Filled through a texture brush rather than clipped: a clip region
                    // has hard edges, a filled path is antialiased.
                    using (GraphicsPath shape = RoundedRect(left, left, icon, icon, 22f * scale))
                    using (TextureBrush brush = new TextureBrush(art, WrapMode.Clamp))
                    {
                        brush.TranslateTransform(left, left);
                        g.FillPath(brush, shape);
                    }
                }
            }

            float r = RingRadius * scale;
            using (Pen faint = new Pen(Color.FromArgb(46, Gold), RingStroke * scale))
                g.DrawEllipse(faint, c - r, c - r, r * 2, r * 2);
        }
    }

    static Bitmap LoadIcon(string dir, int pixels)
    {
        Bitmap source = null;
        try
        {
            string path = Path.Combine(dir, "assets", "Icon.ico");
            if (File.Exists(path))
            {
                using (Icon ico = new Icon(path, 256, 256)) { source = ico.ToBitmap(); }
            }
        }
        catch { source = null; }

        if (source == null)
        {
            try
            {
                using (Icon ico = Icon.ExtractAssociatedIcon(Application.ExecutablePath)) { source = ico.ToBitmap(); }
            }
            catch { return null; }
        }

        Bitmap scaled = new Bitmap(pixels, pixels, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(scaled))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.DrawImage(source, new Rectangle(0, 0, pixels, pixels));
        }
        source.Dispose();
        return scaled;
    }

    static GraphicsPath RoundedRect(float x, float y, float w, float h, float radius)
    {
        float d = radius * 2;
        GraphicsPath path = new GraphicsPath();
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + w - d, y, d, d, 270, 90);
        path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        path.AddArc(x, y + h - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    void Present(byte opacity)
    {
        float c = size / 2f;
        float r = RingRadius * scale;
        float angle = (float)((clock.Elapsed.TotalSeconds / SpinSeconds * 360.0) % 360.0) - 90f;

        using (Graphics g = Graphics.FromImage(frame))
        {
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImageUnscaled(backdrop, 0, 0);
            g.CompositingMode = CompositingMode.SourceOver;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using (Pen arc = new Pen(Gold, RingStroke * scale))
            {
                arc.StartCap = LineCap.Round;
                arc.EndCap = LineCap.Round;
                g.DrawArc(arc, c - r, c - r, r * 2, r * 2, angle, 110f);
            }
        }

        GdiFlush();
        SIZE sz = new SIZE(); sz.cx = size; sz.cy = size;
        POINT src = new POINT();
        POINT dst = new POINT(); dst.x = Left; dst.y = Top;
        BLENDFUNCTION blend = new BLENDFUNCTION();
        blend.BlendOp = 0;                 // AC_SRC_OVER
        blend.SourceConstantAlpha = opacity;
        blend.AlphaFormat = 1;             // AC_SRC_ALPHA
        UpdateLayeredWindow(Handle, IntPtr.Zero, ref dst, ref sz, memDc, ref src, 0, ref blend, 2 /* ULW_ALPHA */);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            frame.Dispose();
            backdrop.Dispose();
        }
        if (memDc != IntPtr.Zero)
        {
            SelectObject(memDc, oldBitmap);
            if (hDib != IntPtr.Zero) DeleteObject(hDib);
            DeleteDC(memDc);
        }
        base.Dispose(disposing);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize;
        public int biWidth;
        public int biHeight;
        public short biPlanes;
        public short biBitCount;
        public int biCompression;
        public int biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public int biClrUsed;
        public int biClrImportant;
    }

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER pbmi, uint usage,
        out IntPtr ppvBits, IntPtr hSection, uint offset);

    [DllImport("gdi32.dll")]
    static extern bool GdiFlush();

    [DllImport("dwmapi.dll")]
    static extern int DwmFlush();

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    struct SIZE { public int cx; public int cy; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
        IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateCompatibleDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr hObject);
}
