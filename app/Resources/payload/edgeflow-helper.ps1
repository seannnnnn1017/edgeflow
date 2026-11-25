# Edgeflow helper for Windows. Started at login (wscript + this script, no console window).
# One process does it all:
#   - runs the Deskflow client (portable deskflow-core.exe) and keeps it running
#   - polls the Mac every few seconds for settings (signed with this computer's device key),
#     fetches new sounds, runs commands (preview, restart, update, uninstall)
#   - edge glow + ripple + arrival sound when the cursor comes in, charge sound at the edge
#   - Mac habits: ⌘⇧3/4/5 (arrive as Ctrl+Shift+3/4/5) take screenshots; Caps Lock toggles
#     中/英 (sent to the IME as a Shift tap) when that's the chosen input switch key
#   - a tray icon with the connection status
# Clipboard images need nothing here: Deskflow on Windows carries bitmaps natively.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$cs = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Media;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public static class EF
{
    public const string Version = "1.2.2";
    static string Dir, CoreExe, CoreDir, ConfPath, LogPath;
    static Dictionary<string, object> Dev;
    static Dictionary<string, object> Cfg = new Dictionary<string, object>();
    static readonly object CfgLock = new object();
    static Process Core;
    static bool LocalPause, Active, Armed, Connected;
    static long LogPos;
    static DateTime? EdgeSince;
    static SoundPlayer ChargePlayer, EnterPlayer;
    static NotifyIcon Tray;
    static ToolStripMenuItem StatusItem, PauseItem;
    static SynchronizationContext UI;
    static HotkeyWindow Hotkeys;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static bool Zh = System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh");

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("winmm.dll")] static extern int waveOutSetVolume(IntPtr h, uint v);

    public static void Run(string dir)
    {
        bool fresh;
        var mutex = new Mutex(true, "EdgeflowHelper", out fresh);
        if (!fresh) return;
        SetProcessDPIAware();
        Dir = dir;
        CoreDir = Path.Combine(dir, "deskflow");
        CoreExe = Path.Combine(CoreDir, "deskflow-core.exe");
        ConfPath = Path.Combine(CoreDir, "settings", "Deskflow.conf");
        LogPath = Path.Combine(CoreDir, "deskflow.log");
        Dev = Load("device.json") ?? new Dictionary<string, object>();
        Cfg = Load("config.json") ?? new Dictionary<string, object>();
        try { LogPos = new FileInfo(LogPath).Length; } catch { LogPos = 0; }

        Application.EnableVisualStyles();
        var ctx = new WindowsFormsSynchronizationContext();
        SynchronizationContext.SetSynchronizationContext(ctx);
        UI = ctx;
        BuildTray();
        Hotkeys = new HotkeyWindow();
        ApplyKeys();
        KeyHook.Install();
        LoadSounds();

        var poll = new Thread(PollLoop);
        poll.IsBackground = true;
        poll.Start();
        var tick = new System.Windows.Forms.Timer();
        tick.Interval = 16;
        tick.Tick += delegate { Tick(); };
        tick.Start();
        var sup = new System.Windows.Forms.Timer();
        sup.Interval = 2000;
        sup.Tick += delegate { Supervise(); };
        sup.Start();
        Supervise();
        Application.Run();
        StopCore();
        mutex.ReleaseMutex();
    }

    // ---- settings ---------------------------------------------------------------------
    static Dictionary<string, object> Load(string name)
    {
        try { return Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Dir, name), Encoding.UTF8)); }
        catch { return null; }
    }
    static object Get(string k) { lock (CfgLock) { object v; return Cfg.TryGetValue(k, out v) ? v : null; } }
    static bool B(string k, bool def) { var v = Get(k); return v is bool ? (bool)v : def; }
    static double D(string k, double def) { var v = Get(k); try { return v == null ? def : Convert.ToDouble(v); } catch { return def; } }
    static string S(string k, string def) { var v = Get(k) as string; return v ?? def; }
    static string DevS(string k) { object v; return Dev.TryGetValue(k, out v) ? (v as string ?? "") : ""; }
    static bool Paused { get { return LocalPause || B("paused", false); } }

    // ---- Deskflow client --------------------------------------------------------------
    static bool CoreRunning { get { try { return Core != null && !Core.HasExited; } catch { return false; } } }

    static void StartCore()
    {
        if (CoreRunning || Paused || !File.Exists(CoreExe)) return;
        foreach (var p in Process.GetProcessesByName("deskflow-core")) { try { p.Kill(); } catch { } }
        UpdateServerAddress();
        var si = new ProcessStartInfo(CoreExe, "client");
        si.WorkingDirectory = CoreDir;
        si.UseShellExecute = false;
        si.CreateNoWindow = true;
        try { Core = Process.Start(si); } catch { Core = null; }
    }

    static void StopCore()
    {
        try { if (CoreRunning) Core.Kill(); } catch { }
        foreach (var p in Process.GetProcessesByName("deskflow-core")) { try { p.Kill(); } catch { } }
        Core = null; Connected = false; Active = false;
    }

    /// The Mac's DHCP address may change: look it up by its mDNS name and fix remoteHost.
    static void UpdateServerAddress()
    {
        try
        {
            string ip = null;
            foreach (var a in Dns.GetHostAddresses(DevS("serverHost")))
                if (a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork) { ip = a.ToString(); break; }
            if (ip == null) return;
            var lines = File.ReadAllLines(ConfPath);
            for (int i = 0; i < lines.Length; i++) if (lines[i].StartsWith("remoteHost=")) lines[i] = "remoteHost=" + ip;
            File.WriteAllLines(ConfPath, lines, new UTF8Encoding(false));
        }
        catch { }
    }

    static void Supervise()
    {
        if (Paused) { if (CoreRunning) StopCore(); }
        else if (!CoreRunning) StartCore();
        UpdateTray();
    }

    // ---- Deskflow log: connected? cursor here? ----------------------------------------
    static int tickCount;
    static void Tick()
    {
        if (++tickCount % 12 == 0) ReadLog();
        ChargeTick();
    }

    static void ReadLog()
    {
        try
        {
            var fi = new FileInfo(LogPath);
            if (!fi.Exists) return;
            if (fi.Length < LogPos) LogPos = 0;
            if (fi.Length == LogPos) return;
            using (var fs = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                fs.Seek(LogPos, SeekOrigin.Begin);
                var text = new StreamReader(fs, Encoding.UTF8).ReadToEnd();
                LogPos = fi.Length;
                foreach (var line in text.Split('\n'))
                {
                    if (line.Contains("connected to server") || line.Contains("connected to secure socket")) Connected = true;
                    else if (line.Contains("disconnected from server") || line.Contains("failed to connect")) { Connected = false; Active = false; }
                    else if (line.Contains("entering computer")) { Active = true; Armed = false; EdgeSince = null; Arrive(false); }
                    else if (line.Contains("leaving computer")) { Active = false; }
                }
            }
            UpdateTray();
        }
        catch { }
    }

    // ---- sounds + charge -----------------------------------------------------------------
    static void LoadSounds()
    {
        try { ChargePlayer = new SoundPlayer(Path.Combine(Dir, "charge.wav")); ChargePlayer.Load(); } catch { ChargePlayer = null; }
        try { EnterPlayer = new SoundPlayer(Path.Combine(Dir, "enter.wav")); EnterPlayer.Load(); } catch { EnterPlayer = null; }
        uint v = (uint)(Math.Max(0, Math.Min(1, D("volume", 0.6))) * 0xFFFF);
        waveOutSetVolume(IntPtr.Zero, v | (v << 16));
    }

    static bool AtEdge(Point p)
    {
        var b = Screen.FromPoint(p).Bounds;
        // only the part of the edge that leads to the Mac (several screens: see the Mac's layout)
        var v = SystemInformation.VirtualScreen;
        string edge = S("edge", "bottom");
        double f = (edge == "top" || edge == "bottom") ? (p.X - v.Left) / (double)v.Width : (p.Y - v.Top) / (double)v.Height;
        if (f < D("edgeLo", 0) - 0.002 || f > D("edgeHi", 1) + 0.002) return false;
        switch (edge)
        {
            case "top": return p.Y <= b.Top + 1;
            case "left": return p.X <= b.Left + 1;
            case "right": return p.X >= b.Right - 2;
            default: return p.Y >= b.Bottom - 2;
        }
    }

    static ChargeGlow Glow;
    static bool Spent;   // this push already charged fully (the cursor crossed)

    static Color Accent()
    {
        var col = Color.FromArgb(89, 217, 255);
        var c = Get("color") as IList;
        if (c != null && c.Count == 3)
            col = Color.FromArgb((int)(Convert.ToDouble(c[0]) * 255), (int)(Convert.ToDouble(c[1]) * 255), (int)(Convert.ToDouble(c[2]) * 255));
        return col;
    }

    static void ChargeTick()
    {
        double delay = D("delay", 0.25);
        bool baseOn = delay >= 0.05 && !Paused && Active;
        bool soundOn = baseOn && B("chargeSound", true) && B("soundEnabled", true);
        bool glowOn = baseOn && B("chargeGlow", true) && B("effectEnabled", true);
        var pos = Cursor.Position;
        if ((soundOn || glowOn) && AtEdge(pos))
        {
            if (EdgeSince == null && Armed)
            {
                EdgeSince = DateTime.Now; Armed = false;
                if (soundOn && ChargePlayer != null) { try { ChargePlayer.Stop(); ChargePlayer.Play(); } catch { } }
            }
            if (EdgeSince != null && glowOn && !Spent)
            {
                if (Glow == null) Glow = new ChargeGlow();
                double p = (DateTime.Now - EdgeSince.Value).TotalSeconds / delay;
                if (p >= 1.1) { Glow.Hide(); Spent = true; }   // fully charged: that's the crossing
                else Glow.Show(pos, S("edge", "bottom"), Math.Min(1, p), Accent(), Math.Max(40, D("glow", 48)));
            }
        }
        else
        {
            if (EdgeSince != null && (DateTime.Now - EdgeSince.Value).TotalSeconds < Math.Max(0.08, delay * 0.8))
                if (ChargePlayer != null) ChargePlayer.Stop();
            if (Glow != null) Glow.Hide();   // no-op when already hidden
            EdgeSince = null; Spent = false;
            if (Active) Armed = true;
        }
    }

    // ---- arrival effect ----------------------------------------------------------------
    static void Arrive(bool preview)
    {
        if (B("soundEnabled", true) && EnterPlayer != null) { try { EnterPlayer.Play(); } catch { } }
        if (!B("effectEnabled", true)) return;
        var col = Accent();
        new Arrival(Cursor.Position, S("edge", "bottom"), col, D("duration", 0.6), (int)D("glow", 48), B("ripple", true)).Start();
    }

    // ---- talking to the Mac ------------------------------------------------------------
    static string Hex(byte[] b) { var sb = new StringBuilder(); foreach (var x in b) sb.Append(x.ToString("x2")); return sb.ToString(); }
    static byte[] FromHex(string h) { var b = new byte[h.Length / 2]; for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(h.Substring(i * 2, 2), 16); return b; }
    static string Sha(byte[] b) { using (var s = SHA256.Create()) return Hex(s.ComputeHash(b)); }
    static string ShaFile(string p) { try { return Sha(File.ReadAllBytes(p)); } catch { return ""; } }

    static string Signed(string path, string extra)
    {
        string ts = ((long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds).ToString();
        string sig;
        using (var h = new HMACSHA256(FromHex(DevS("deviceKey")))) sig = Hex(h.ComputeHash(Encoding.UTF8.GetBytes(DevS("deviceId") + ":" + ts)));
        return path + "?ts=" + ts + "&sig=" + sig + (extra ?? "");
    }

    static byte[] Fetch(string path, int timeout)
    {
        string pair = DevS("pairUrl");
        string port = pair.Substring(pair.LastIndexOf(':') + 1);
        Exception last = null;
        foreach (var b in new[] { "http://" + DevS("serverHost") + ":" + port, pair })
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(b + path);
                req.Timeout = timeout; req.ReadWriteTimeout = timeout;
                using (var resp = req.GetResponse())
                using (var ms = new MemoryStream()) { resp.GetResponseStream().CopyTo(ms); return ms.ToArray(); }
            }
            catch (Exception e) { last = e; }
        }
        throw last;
    }

    // "x,y,w,h,primary;…" so the Mac can draw this computer's screens and line them up
    static string Monitors()
    {
        var parts = new List<string>();
        foreach (var s in Screen.AllScreens)
            parts.Add(s.Bounds.X + "," + s.Bounds.Y + "," + s.Bounds.Width + "," + s.Bounds.Height + "," + (s.Primary ? "1" : "0"));
        return string.Join(";", parts.ToArray());
    }

    static void PollLoop()
    {
        while (true)
        {
            try
            {
                string extra = "&v=" + Version + "&cv=" + Uri.EscapeDataString(S("cv", "")) + "&active=" + (Active ? "1" : "0") + "&mon=" + Uri.EscapeDataString(Monitors());
                var data = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(Fetch(Signed("/c/" + DevS("deviceId"), extra), 6000)));
                bool sounds = false;
                var files = data.ContainsKey("files") ? data["files"] as Dictionary<string, object> : null;
                if (files != null)
                    foreach (var kv in files)
                    {
                        string want = kv.Value as string, p = Path.Combine(Dir, kv.Key);
                        if (ShaFile(p) == want) continue;
                        try   // one failed sound must not hold up the settings
                        {
                            var blob = Fetch(Signed("/d/" + DevS("deviceId") + "/" + kv.Key, ""), 20000);
                            if (Sha(blob) == want) { File.WriteAllBytes(p, blob); sounds = true; }
                        }
                        catch { }
                    }
                var cmds = data.ContainsKey("commands") ? data["commands"] as IList : null;
                data.Remove("commands");
                bool changed = (data.ContainsKey("cv") ? data["cv"] as string : "") != S("cv", "");
                if (changed)
                {
                    File.WriteAllText(Path.Combine(Dir, "config.json"), Json.Serialize(data), new UTF8Encoding(false));
                    lock (CfgLock) Cfg = data;
                }
                if (changed || sounds) UI.Post(delegate { LoadSounds(); ApplyKeys(); Supervise(); }, null);
                if (cmds != null)
                    foreach (var c in cmds) { var cmd = c as string; var d = data; UI.Post(delegate { Command(cmd, d); }, null); }
            }
            catch { }
            Thread.Sleep(3000);
        }
    }

    static void Command(string cmd, Dictionary<string, object> data)
    {
        if (cmd == "preview") Arrive(true);
        else if (cmd == "restart") StopCore();
        else if (cmd == "update") SelfUpdate(data);
        else if (cmd == "uninstall") Uninstall();
    }

    static void SelfUpdate(Dictionary<string, object> data)
    {
        var files = data.ContainsKey("helperFiles") ? data["helperFiles"] as Dictionary<string, object> : null;
        if (files == null) return;
        try
        {
            string name = "edgeflow-helper.ps1";
            object want;
            if (files.TryGetValue(name, out want) && ShaFile(Path.Combine(Dir, name)) != (string)want)
            {
                var blob = Fetch("/f/" + name, 30000);
                if (Sha(blob) == (string)want) File.WriteAllBytes(Path.Combine(Dir, name), blob);
            }
        }
        catch { return; }
        Restart();
    }

    static void Restart()
    {
        StopCore();
        Tray.Visible = false;
        Process.Start("wscript.exe", "\"" + Path.Combine(Dir, "edgeflow.vbs") + "\"");
        Application.Exit();
        Environment.Exit(0);
    }

    static void Uninstall()
    {
        StopCore();
        try { using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)) k.DeleteValue("Edgeflow", false); } catch { }
        Tray.Visible = false;
        var si = new ProcessStartInfo("cmd.exe", "/c timeout /t 3 >nul & rmdir /s /q \"" + Dir + "\"");
        si.CreateNoWindow = true; si.UseShellExecute = false;
        Process.Start(si);
        Application.Exit();
        Environment.Exit(0);
    }

    // ---- keys -------------------------------------------------------------------------
    public static bool KeysOn { get { return B("keys", true); } }
    public static bool CapsSwitch { get { return KeysOn && S("ime", "caps") == "caps"; } }

    static void ApplyKeys()
    {
        Hotkeys.UnregisterAll();
        if (!KeysOn) return;
        const int CTRL = 2, SHIFT = 4, WIN = 8;
        Hotkeys.Add(CTRL | SHIFT, Keys.D3, FullScreenshot);
        Hotkeys.Add(CTRL | SHIFT, Keys.D4, Snip);
        Hotkeys.Add(CTRL | SHIFT, Keys.D5, Snip);
        Hotkeys.Add(CTRL | WIN | SHIFT, Keys.D4, Snip);
    }

    static void Snip() { try { Process.Start("ms-screenclip:"); } catch { } }

    static void FullScreenshot()
    {
        var v = SystemInformation.VirtualScreen;
        using (var bmp = new Bitmap(v.Width, v.Height))
        {
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(v.Left, v.Top, 0, 0, v.Size);
            Clipboard.SetImage(bmp);
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");
            Directory.CreateDirectory(dir);
            bmp.Save(Path.Combine(dir, "Screenshot " + DateTime.Now.ToString("yyyy-MM-dd HHmmss") + ".png"), ImageFormat.Png);
        }
    }

    // ---- tray -------------------------------------------------------------------------
    static void BuildTray()
    {
        Tray = new NotifyIcon();
        Tray.Icon = MakeIcon();
        Tray.Text = "Edgeflow";
        var menu = new ContextMenuStrip();
        StatusItem = new ToolStripMenuItem("Edgeflow"); StatusItem.Enabled = false;
        PauseItem = new ToolStripMenuItem(Zh ? "暫停分享" : "Pause Sharing");
        PauseItem.Click += delegate { LocalPause = !LocalPause; PauseItem.Checked = LocalPause; Supervise(); };
        var quit = new ToolStripMenuItem(Zh ? "結束 Edgeflow" : "Quit Edgeflow");
        quit.Click += delegate { StopCore(); Tray.Visible = false; Application.Exit(); };
        menu.Items.Add(StatusItem); menu.Items.Add(new ToolStripSeparator()); menu.Items.Add(PauseItem); menu.Items.Add(quit);
        Tray.ContextMenuStrip = menu;
        Tray.Visible = true;
    }

    static void UpdateTray()
    {
        string mac = DevS("serverHost").Replace(".local", "");
        string s = Paused ? (Zh ? "已暫停" : "Paused")
            : Active ? (Zh ? "游標在這台" : "Cursor is here")
            : Connected ? (Zh ? "已連線 " : "Connected to ") + mac
            : (Zh ? "等待 " : "Waiting for ") + mac + "…";
        StatusItem.Text = "● " + s;
        var t = "Edgeflow · " + s;
        Tray.Text = t.Length > 63 ? t.Substring(0, 63) : t;
    }

    /// Two screens, the front one lit — the app icon, drawn small.
    static Icon MakeIcon()
    {
        var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var bg = new LinearGradientBrush(new Rectangle(0, 0, 32, 32), Color.FromArgb(243, 94, 82), Color.FromArgb(106, 61, 158), 60f))
                FillRound(g, bg, new RectangleF(0, 0, 32, 32), 7);
            using (var back = new SolidBrush(Color.FromArgb(110, 255, 255, 255))) FillRound(g, back, new RectangleF(5, 7, 15, 11), 2);
            FillRound(g, Brushes.White, new RectangleF(12, 13, 15, 11), 2);
            using (var cy = new SolidBrush(Color.FromArgb(89, 217, 255))) g.FillRectangle(cy, 13.5f, 14.5f, 1.5f, 8);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    public static void FillRound(Graphics g, Brush b, RectangleF r, float rad)
    {
        using (var p = new GraphicsPath())
        {
            float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            g.FillPath(b, p);
        }
    }
}

/// Global hotkeys (RegisterHotKey) on a hidden window.
public class HotkeyWindow : NativeWindow
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, int mods, int vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    readonly Dictionary<int, Action> actions = new Dictionary<int, Action>();
    int next = 1;
    public HotkeyWindow() { CreateHandle(new CreateParams()); }
    public void Add(int mods, Keys key, Action a)
    {
        int id = next++;
        if (RegisterHotKey(Handle, id, mods | 0x4000, (int)key)) actions[id] = a;
    }
    public void UnregisterAll() { foreach (var id in actions.Keys) UnregisterHotKey(Handle, id); actions.Clear(); }
    protected override void WndProc(ref Message m)
    {
        Action a;
        if (m.Msg == 0x0312 && actions.TryGetValue(m.WParam.ToInt32(), out a)) { try { a(); } catch { } }
        base.WndProc(ref m);
    }
}

/// Caps Lock → a Shift tap, which toggles 中/英 in Microsoft Bopomofo/Pinyin, like the Mac.
public static class KeyHook
{
    delegate IntPtr Proc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    static Proc keep;
    static IntPtr hook;
    public static void Install()
    {
        keep = Hook;
        hook = SetWindowsHookEx(13, keep, GetModuleHandle(null), 0);
    }
    static IntPtr Hook(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0 && EF.CapsSwitch)
        {
            int vk = Marshal.ReadInt32(l);
            int flags = Marshal.ReadInt32(l, 8);
            bool ours = (Marshal.ReadIntPtr(l, 16) == (IntPtr)0xEF);
            if (vk == 0x14 && !ours)
            {
                if ((int)w == 0x101 || (int)w == 0x105)
                {
                    keybd_event(0x10, 0, 0, (UIntPtr)0xEF);
                    keybd_event(0x10, 0, 2, (UIntPtr)0xEF);
                }
                return (IntPtr)1;   // swallow Caps Lock itself
            }
        }
        return CallNextHookEx(hook, code, w, l);
    }
}

/// Layered, click-through, never-activating window showing a premultiplied bitmap.
public class Layered : Form
{
    [StructLayout(LayoutKind.Sequential)] struct PT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct SZ { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLEND { public byte op, flags, alpha, format; }
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref PT pos, ref SZ size, IntPtr src, ref PT srcPos, int key, ref BLEND b, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

    public Layered(Rectangle r)
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
        Bounds = r; TopMost = true;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x8 | 0x08000000; return cp; }
    }
    public void SetBitmap(Bitmap bmp, byte alpha)
    {
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), hb = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            hb = bmp.GetHbitmap(Color.FromArgb(0)); old = SelectObject(mem, hb);
            var size = new SZ { cx = bmp.Width, cy = bmp.Height }; var src = new PT(); var pos = new PT { x = Left, y = Top };
            var bl = new BLEND { op = 0, flags = 0, alpha = alpha, format = 1 };
            UpdateLayeredWindow(Handle, screen, ref pos, ref size, mem, ref src, 0, ref bl, 2);
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, screen);
            if (hb != IntPtr.Zero) { SelectObject(mem, old); DeleteObject(hb); }
            DeleteDC(mem);
        }
    }
}

/// While the cursor pushes against the edge toward the Mac: a glow at that spot that grows
/// and slowly brightens over the switch delay (same look as on the Mac).
public class ChargeGlow
{
    Layered win;
    Rectangle rect;
    string edge = "bottom";
    double lastP; int lastAlong; Color lastCol; double lastDepth;
    DateTime? fadeFrom;
    System.Windows.Forms.Timer fadeTimer;
    readonly float k;

    public ChargeGlow() { using (var g = Graphics.FromHwnd(IntPtr.Zero)) k = g.DpiX / 96f; }

    public void Show(Point cur, string edge, double p, Color col, double depth)
    {
        fadeFrom = null;
        if (fadeTimer != null) { fadeTimer.Stop(); fadeTimer = null; }
        this.edge = edge;
        var mon = Screen.FromPoint(cur).Bounds;
        int d = (int)(depth * 1.4 * k);
        Rectangle r;
        if (edge == "top") r = new Rectangle(mon.Left, mon.Top, mon.Width, d);
        else if (edge == "left") r = new Rectangle(mon.Left, mon.Top, d, mon.Height);
        else if (edge == "right") r = new Rectangle(mon.Right - d, mon.Top, d, mon.Height);
        else r = new Rectangle(mon.Left, mon.Bottom - d, mon.Width, d);
        if (win == null || r != rect)
        {
            if (win != null) win.Close();
            win = new Layered(r); rect = r;
            win.Show();
        }
        bool horizontal = edge == "top" || edge == "bottom";
        lastP = p; lastCol = col; lastDepth = depth;
        lastAlong = horizontal ? cur.X - r.Left : cur.Y - r.Top;
        Render(1.0);
    }

    public void Hide()
    {
        if (win == null || fadeFrom != null) return;
        fadeFrom = DateTime.Now;
        fadeTimer = new System.Windows.Forms.Timer();
        fadeTimer.Interval = 16;
        fadeTimer.Tick += delegate
        {
            if (fadeFrom == null) return;
            double q = (DateTime.Now - fadeFrom.Value).TotalSeconds / 0.18;
            if (q >= 1)
            {
                fadeTimer.Stop(); fadeTimer = null; fadeFrom = null;
                win.Close(); win = null;
                return;
            }
            Render(1 - q);
        };
        fadeTimer.Start();
    }

    void Render(double fade)
    {
        double p = lastP;
        double level = (0.12 + 0.88 * Math.Pow(p, 1.8)) * fade;
        double reach = (90 + 300 * (1 - Math.Pow(1 - p, 2))) * k;
        double deep = lastDepth * (0.55 + 0.75 * p) * k;
        var hot = Color.FromArgb((int)(lastCol.R + (255 - lastCol.R) * 0.4 * p), (int)(lastCol.G + (255 - lastCol.G) * 0.4 * p),
                                 (int)(lastCol.B + (255 - lastCol.B) * 0.4 * p));
        bool horizontal = edge == "top" || edge == "bottom";
        float ox, oy;
        if (edge == "top") { ox = lastAlong; oy = 0; }
        else if (edge == "bottom") { ox = lastAlong; oy = rect.Height; }
        else if (edge == "left") { ox = 0; oy = lastAlong; }
        else { ox = rect.Width; oy = lastAlong; }
        using (var bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                Blob(g, ox, oy, horizontal, reach, deep, 0.9 * level, lastCol);           // soft halo
                Blob(g, ox, oy, horizontal, reach * 0.35, deep * 0.45, level, hot);    // hot core
                Blob(g, ox, oy, horizontal, reach * 0.9, 3 * k, Math.Min(1, level * 1.1), hot); // edge line
            }
            win.SetBitmap(bmp, 255);
        }
    }

    static void Blob(Graphics g, float ox, float oy, bool horizontal, double rx, double ry, double a, Color c)
    {
        float w = (float)(horizontal ? rx : ry), h = (float)(horizontal ? ry : rx);
        if (w < 1 || h < 1 || a <= 0.003) return;
        using (var path = new GraphicsPath())
        {
            path.AddEllipse(ox - w, oy - h, w * 2, h * 2);
            using (var br = new PathGradientBrush(path))
            {
                br.CenterPoint = new PointF(ox, oy);
                var blend = new ColorBlend(3);
                blend.Colors = new Color[] { Color.FromArgb(0, c), Color.FromArgb((int)(255 * a * 0.5), c), Color.FromArgb((int)(255 * Math.Min(1, a)), c) };
                blend.Positions = new float[] { 0f, 0.55f, 1f };
                br.InterpolationColors = blend;
                g.FillPath(br, path);
            }
        }
    }
}

/// The edge glow (a strip along the entry edge) and the ripple at the cursor.
public class Arrival
{
    readonly Point cur; readonly string edge; readonly Color col; readonly double dur; readonly int band; readonly bool ripple;
    readonly float k;
    Layered bandWin, ripWin;
    Bitmap bandBmp;
    System.Windows.Forms.Timer timer;
    DateTime start;
    const int Box = 180;

    public Arrival(Point cur, string edge, Color col, double dur, int band, bool ripple)
    {
        this.cur = cur; this.edge = edge; this.col = col; this.dur = Math.Max(0.2, dur); this.ripple = ripple;
        using (var g = Graphics.FromHwnd(IntPtr.Zero)) k = g.DpiX / 96f;
        this.band = (int)(band * k);
    }

    public void Start()
    {
        var mon = Screen.FromPoint(cur).Bounds;
        if (band > 0)
        {
            Rectangle r;
            bool vertical = edge == "left" || edge == "right";
            if (edge == "top") r = new Rectangle(mon.Left, mon.Top, mon.Width, band);
            else if (edge == "left") r = new Rectangle(mon.Left, mon.Top, band, mon.Height);
            else if (edge == "right") r = new Rectangle(mon.Right - band, mon.Top, band, mon.Height);
            else r = new Rectangle(mon.Left, mon.Bottom - band, mon.Width, band);
            bandBmp = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bandBmp))
            {
                PointF a, b;
                if (edge == "top") { a = new PointF(0, 0); b = new PointF(0, band); }
                else if (edge == "left") { a = new PointF(0, 0); b = new PointF(band, 0); }
                else if (edge == "right") { a = new PointF(band, 0); b = new PointF(0, 0); }
                else { a = new PointF(0, band); b = new PointF(0, 0); }
                using (var br = new LinearGradientBrush(a, b, Color.FromArgb(217, col), Color.FromArgb(0, col))) g.FillRectangle(br, 0, 0, r.Width, r.Height);
            }
            bandWin = new Layered(r);
            bandWin.Show();
            bandWin.SetBitmap(bandBmp, 255);
        }
        if (ripple)
        {
            int s = (int)(Box * k);
            ripWin = new Layered(new Rectangle(cur.X - s / 2, cur.Y - s / 2, s, s));
            ripWin.Show();
        }
        start = DateTime.Now;
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 16;
        timer.Tick += delegate { Frame(); };
        timer.Start();
    }

    void Frame()
    {
        double p = (DateTime.Now - start).TotalSeconds / dur;
        if (p >= 1)
        {
            timer.Stop();
            if (bandWin != null) bandWin.Close();
            if (ripWin != null) ripWin.Close();
            if (bandBmp != null) bandBmp.Dispose();
            return;
        }
        double fade = 1 - p * p;
        if (bandWin != null) bandWin.SetBitmap(bandBmp, (byte)(255 * fade));
        if (ripWin != null)
        {
            int s = ripWin.Width;
            using (var bmp = new Bitmap(s, s, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    float c = s / 2f;
                    double[] lags = { 0, 0.18 };
                    for (int i = 0; i < 2; i++)
                    {
                        double q = Math.Max(0, Math.Min(1, (p - lags[i]) / (1 - lags[i])));
                        if (q <= 0) continue;
                        float r = (float)((8 + 70 * (1 - Math.Pow(1 - q, 3))) * k);
                        int a = (int)(255 * (1 - q) * (i == 0 ? 0.9 : 0.55));
                        using (var pen = new Pen(Color.FromArgb(a, col), (float)((3 * (1 - q) + 1) * k))) g.DrawEllipse(pen, c - r, c - r, r * 2, r * 2);
                    }
                    using (var dot = new SolidBrush(Color.FromArgb((int)(153 * fade), col))) g.FillEllipse(dot, c - 6 * k, c - 6 * k, 12 * k, 12 * k);
                }
                ripWin.SetBitmap(bmp, 255);
            }
        }
    }
}
'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions
[EF]::Run($dir)
