// OrthoTiler - converts a GeoTIFF orthomosaic into an MBTiles file for PasturePath.
// Built with the C# 5 compiler shipped with Windows (csc.exe), so no SDK is required.
//
// GUI:  OrthoTiler.exe
// CLI:  OrthoTiler.exe --cli <input.tif> <minZoom> <maxZoom> [--jpeg] [--out <file.mbtiles>]

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace OrthoTiler
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--cli")
            {
                return Cli.Run(args);
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
            return 0;
        }
    }

    /// <summary>Locates GDAL and configures child processes to find its data files.</summary>
    internal static class Gdal
    {
        public static string Home;

        public static bool Locate()
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string[] candidates = new string[]
            {
                Path.Combine(exeDir, "gdal"),
                @"C:\Program Files\GDAL",
                Environment.GetEnvironmentVariable("GDAL_HOME")
            };

            foreach (string c in candidates)
            {
                if (string.IsNullOrEmpty(c)) continue;
                if (File.Exists(Path.Combine(c, "gdal_translate.exe")))
                {
                    Home = c;
                    return true;
                }
            }
            return false;
        }

        public static string Exe(string name)
        {
            return Path.Combine(Home, name);
        }

        /// <summary>Applies PATH/PROJ/GDAL_DATA so GDAL can run from anywhere.</summary>
        public static void ApplyEnvironment(ProcessStartInfo psi)
        {
            string path = Environment.GetEnvironmentVariable("PATH");
            psi.EnvironmentVariables["PATH"] = Home + ";" + (path == null ? "" : path);

            string proj = Path.Combine(Home, "projlib");
            if (Directory.Exists(proj))
            {
                psi.EnvironmentVariables["PROJ_DATA"] = proj;
                psi.EnvironmentVariables["PROJ_LIB"] = proj;
            }
            string data = Path.Combine(Home, "gdal-data");
            if (Directory.Exists(data))
            {
                psi.EnvironmentVariables["GDAL_DATA"] = data;
            }
        }

        public static ProcessStartInfo StartInfo(string exeName, string arguments)
        {
            ProcessStartInfo psi = new ProcessStartInfo(Exe(exeName), arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            ApplyEnvironment(psi);
            return psi;
        }

        public static string Capture(string exeName, string arguments, out int exitCode)
        {
            ProcessStartInfo psi = StartInfo(exeName, arguments);
            using (Process p = Process.Start(psi))
            {
                string stdout = p.StandardOutput.ReadToEnd();
                string stderr = p.StandardError.ReadToEnd();
                p.WaitForExit();
                exitCode = p.ExitCode;
                return stdout + stderr;
            }
        }
    }

    // ---------------------------------------------------------------- metadata

    internal class SourceInfo
    {
        public int Width;
        public int Height;
        public double GsdX;
        public double GsdY;
        public int BandCount;
        public bool HasAlpha;
        public bool HasBounds;
        public double West;
        public double South;
        public double East;
        public double North;
        public double CenterLat;
        public double AreaHa;
        public string Crs = "";

        public double GroundAccuracy
        {
            get { return Math.Max(GsdX, GsdY); }
        }

        /// <summary>True ground size of one source pixel, in metres.</summary>
        public double GroundGsd
        {
            get
            {
                if (!HasBounds || Width <= 0) return GroundAccuracy;
                double widthM = (East - West) * 111320.0 *
                    Math.Cos(CenterLat * Math.PI / 180.0);
                double g = Math.Abs(widthM) / (double)Width;
                return g > 0 ? g : GroundAccuracy;
            }
        }
    }

    internal static class Geo
    {
        // Web Mercator resolution at the equator for zoom 0, metres per pixel.
        public const double EquatorResolution = 156543.03392804097;

        public static double ResolutionAtZoom(double latDeg, int zoom)
        {
            return EquatorResolution * Math.Cos(latDeg * Math.PI / 180.0) / Math.Pow(2, zoom);
        }

        /// <summary>Zoom the source resolution supports, NOT clamped to the 0-22 ceiling.</summary>
        public static int RawMaxZoomForGsd(double latDeg, double gsd)
        {
            if (gsd <= 0) return 22;
            double lon = EquatorResolution * Math.Cos(latDeg * Math.PI / 180.0) / gsd;
            double z = Math.Log(lon, 2);
            return (int)Math.Floor(z);
        }

        public static int MaxZoomForGsd(double latDeg, double gsd)
        {
            int zi = RawMaxZoomForGsd(latDeg, gsd);
            if (zi < 0) zi = 0;
            if (zi > 22) zi = 22;
            return zi;
        }

        public static void TileXY(double lon, double lat, int zoom, out int x, out int y)
        {
            int n = 1 << zoom;
            x = (int)Math.Floor((lon + 180.0) / 360.0 * n);

            double latRad = lat * Math.PI / 180.0;
            double merc = Math.Log(Math.Tan(latRad) + 1.0 / Math.Cos(latRad));
            y = (int)Math.Floor((1.0 - merc / Math.PI) / 2.0 * n);

            if (x < 0) x = 0;
            if (x > n - 1) x = n - 1;
            if (y < 0) y = 0;
            if (y > n - 1) y = n - 1;
        }

        /// <summary>
        /// Resolution, expressed in the source raster's own units, that yields the
        /// requested zoom after GDAL warps it to Web Mercator. Handles both
        /// projected (metre) and geographic (degree) sources.
        /// </summary>
        public static double SourceResolutionForZoom(SourceInfo s, int zoom)
        {
            if (s.GsdX <= 0) return 0;
            double groundGsd = s.GroundGsd;
            if (groundGsd <= 0) return 0;
            return ResolutionAtZoom(s.CenterLat, zoom) * (s.GsdX / groundGsd);
        }

        public static long EstimateTiles(SourceInfo s, int minZoom, int maxZoom)
        {
            if (!s.HasBounds) return 0;
            long total = 0;
            for (int z = minZoom; z <= maxZoom; z++)
            {
                int x0, y0, x1, y1;
                TileXY(s.West, s.North, z, out x0, out y0);
                TileXY(s.East, s.South, z, out x1, out y1);
                total += (long)(x1 - x0 + 1) * (long)(y1 - y0 + 1);
            }
            return total;
        }
    }

    internal static class Metadata
    {
        public static SourceInfo Read(string tifPath, out string error)
        {
            error = null;
            int exit;
            string json = Gdal.Capture("gdalinfo.exe", "-json \"" + tifPath + "\"", out exit);
            if (exit != 0)
            {
                error = json.Trim();
                if (error.Length > 800) error = error.Substring(0, 800);
                return null;
            }

            Dictionary<string, object> root;
            try
            {
                JavaScriptSerializer ser = new JavaScriptSerializer();
                ser.MaxJsonLength = 64 * 1024 * 1024;
                root = ser.DeserializeObject(json) as Dictionary<string, object>;
            }
            catch (Exception ex)
            {
                error = "Could not read gdalinfo output: " + ex.Message;
                return null;
            }
            if (root == null)
            {
                error = "Could not read gdalinfo output.";
                return null;
            }

            SourceInfo info = new SourceInfo();

            object[] size = Get(root, "size") as object[];
            if (size != null && size.Length >= 2)
            {
                info.Width = ToInt(size[0]);
                info.Height = ToInt(size[1]);
            }

            object[] gt = Get(root, "geoTransform") as object[];
            if (gt != null && gt.Length >= 6)
            {
                info.GsdX = Math.Abs(ToDouble(gt[1]));
                info.GsdY = Math.Abs(ToDouble(gt[5]));
            }

            object[] bands = Get(root, "bands") as object[];
            if (bands != null)
            {
                info.BandCount = bands.Length;
                foreach (object b in bands)
                {
                    Dictionary<string, object> bd = b as Dictionary<string, object>;
                    string ci = ToString(Get(bd, "colorInterpretation"));
                    if (ci.Equals("Alpha", StringComparison.OrdinalIgnoreCase)) info.HasAlpha = true;
                }
            }

            Dictionary<string, object> cs = Get(root, "coordinateSystem") as Dictionary<string, object>;
            string wkt = ToString(Get(cs, "wkt"));
            if (!string.IsNullOrEmpty(wkt))
            {
                // Last AUTHORITY/ID entry in the WKT is usually the EPSG code.
                Match m = Regex.Match(wkt, @"ID\[""EPSG"",\s*(\d+)\]");
                if (m.Success) info.Crs = "EPSG:" + m.Groups[1].Value;
                else if (wkt.IndexOf("WGS 84", StringComparison.OrdinalIgnoreCase) >= 0) info.Crs = "WGS 84";
            }

            // Prefer the lat/long extent; fall back to corner coordinates.
            Dictionary<string, object> extent = Get(root, "wgs84Extent") as Dictionary<string, object>;
            object coords = Get(extent, "coordinates");
            if (coords != null)
            {
                double w = double.MaxValue, e = double.MinValue, so = double.MaxValue, no = double.MinValue;
                CollectLonLat(coords, ref w, ref e, ref so, ref no);
                if (w <= e && so <= no)
                {
                    info.West = w;
                    info.East = e;
                    info.South = so;
                    info.North = no;
                    info.HasBounds = true;
                }
            }

            if (info.HasBounds)
            {
                info.CenterLat = (info.South + info.North) / 2.0;
                double widthM = (info.East - info.West) * 111320.0 * Math.Cos(info.CenterLat * Math.PI / 180.0);
                double heightM = (info.North - info.South) * 110574.0;
                info.AreaHa = Math.Abs(widthM * heightM) / 10000.0;
            }

            if (info.Width <= 0 || info.Height <= 0)
            {
                error = "This file does not look like a georeferenced raster.";
                return null;
            }
            if (!info.HasBounds)
            {
                error = "The file has no geographic bounds. Is it georeferenced?";
                return null;
            }
            return info;
        }

        private static void CollectLonLat(object node, ref double w, ref double e, ref double so, ref double no)
        {
            object[] arr = node as object[];
            if (arr == null) return;

            if (arr.Length >= 2 && IsNumber(arr[0]) && IsNumber(arr[1]))
            {
                double lon = Convert.ToDouble(arr[0], CultureInfo.InvariantCulture);
                double lat = Convert.ToDouble(arr[1], CultureInfo.InvariantCulture);
                if (lon < w) w = lon;
                if (lon > e) e = lon;
                if (lat < so) so = lat;
                if (lat > no) no = lat;
                return;
            }
            foreach (object child in arr) CollectLonLat(child, ref w, ref e, ref so, ref no);
        }

        private static bool IsNumber(object o)
        {
            return o is double || o is int || o is long || o is decimal || o is float;
        }

        private static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            if (d != null && d.TryGetValue(key, out v)) return v;
            return null;
        }

        private static string ToString(object o)
        {
            return o == null ? "" : o.ToString();
        }

        private static int ToInt(object o)
        {
            try { return Convert.ToInt32(o, CultureInfo.InvariantCulture); }
            catch { return 0; }
        }

        private static double ToDouble(object o)
        {
            try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); }
            catch { return 0; }
        }
    }

    // ---------------------------------------------------------------- conversion

    internal class ConversionOptions
    {
        public string InputPath;
        public string OutputPath;
        public int MinZoom = 15;
        public int MaxZoom = 21;
        public bool Jpeg;
        public bool DropAlpha;
        public bool BuildOverviews = true;
        public double CenterLat;
        public int BandCount = 3;

        /// <summary>Source-CRS resolution that produces [MaxZoom]; 0 disables resampling.</summary>
        public double TargetSourceResolution;
        /// <summary>Highest zoom the source resolution supports without downsampling.</summary>
        public int NativeMaxZoom = 22;
    }

    internal class ConversionResult
    {
        public bool Success;
        public string Error;
    }

    internal static class Converter
    {
        public static string BuildTranslateArguments(ConversionOptions o)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("-of MBTiles ");
            sb.Append("-co TILE_FORMAT=").Append(o.Jpeg ? "JPEG" : "PNG").Append(' ');
            if (o.Jpeg)
            {
                sb.Append("-co QUALITY=85 ");
                if (o.DropAlpha)
                {
                    sb.Append("-b 1 -b 2 -b 3 ");
                }
            }

            // The MBTiles driver ignores -co RESOLUTION and always tiles at the
            // raster's native resolution, so cap the zoom by resampling first.
            if (o.TargetSourceResolution > 0)
            {
                string res = o.TargetSourceResolution.ToString("0.############", CultureInfo.InvariantCulture);
                sb.Append("-tr ").Append(res).Append(' ').Append(res).Append(' ');
                sb.Append("-r average ");
            }
            sb.Append("--config GDAL_CACHEMAX 2048 ");
            sb.Append('"').Append(o.InputPath).Append('"').Append(' ');
            sb.Append('"').Append(o.OutputPath).Append('"');
            return sb.ToString();
        }

        public static string BuildAddoArguments(ConversionOptions o)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("-r average ");
            sb.Append('"').Append(o.OutputPath).Append('"').Append(' ');

            int levels = o.MaxZoom - o.MinZoom;
            for (int i = 1; i <= levels; i++)
            {
                sb.Append((1 << i).ToString(CultureInfo.InvariantCulture)).Append(' ');
            }
            return sb.ToString().TrimEnd();
        }

        /// <summary>
        /// Runs the conversion. Progress is reported as 0..100.
        /// Returns false only on failure; cancellation is reported via the token.
        /// </summary>
        public static ConversionResult Run(
            ConversionOptions o,
            Action<int, string> report,
            Func<bool> cancelled)
        {
            ConversionResult result = new ConversionResult();

            if (File.Exists(o.OutputPath))
            {
                try { File.Delete(o.OutputPath); }
                catch (Exception ex)
                {
                    result.Error = "Could not overwrite the existing output file: " + ex.Message;
                    return result;
                }
            }

            bool hasOverviews = o.BuildOverviews && o.MaxZoom > o.MinZoom;

            report(0, "Writing tiles (zoom " + o.MaxZoom + ")...");
            int exit;
            string output = RunStreaming(
                "gdal_translate.exe",
                BuildTranslateArguments(o),
                hasOverviews ? 0 : 0,
                hasOverviews ? 80 : 100,
                report,
                cancelled,
                out exit);

            if (cancelled != null && cancelled())
            {
                TryDelete(o.OutputPath);
                result.Error = "Cancelled.";
                return result;
            }
            if (exit != 0)
            {
                TryDelete(o.OutputPath);
                result.Error = Trim(output, 1500);
                if (result.Error.Length == 0) result.Error = "gdal_translate failed (exit code " + exit + ").";
                return result;
            }

            if (hasOverviews)
            {
                report(80, "Building zoom levels " + o.MinZoom + "-" + (o.MaxZoom - 1) + "...");
                output = RunStreaming(
                    "gdaladdo.exe",
                    BuildAddoArguments(o),
                    80, 100,
                    report,
                    cancelled,
                    out exit);

                if (cancelled != null && cancelled())
                {
                    TryDelete(o.OutputPath);
                    result.Error = "Cancelled.";
                    return result;
                }
                if (exit != 0)
                {
                    result.Error = Trim(output, 1500);
                    if (result.Error.Length == 0) result.Error = "gdaladdo failed (exit code " + exit + ").";
                    return result;
                }
            }

            report(100, "Done.");
            result.Success = true;
            return result;
        }

        private static string RunStreaming(
            string exe,
            string arguments,
            int pctFrom,
            int pctTo,
            Action<int, string> report,
            Func<bool> cancelled,
            out int exitCode)
        {
            exitCode = -1;

            ProcessStartInfo psi = Gdal.StartInfo(exe, arguments);
            StringBuilder stderr = new StringBuilder();
            StringBuilder tail = new StringBuilder();

            using (Process p = Process.Start(psi))
            {
                Thread errThread = new Thread(delegate ()
                {
                    try { stderr.Append(p.StandardError.ReadToEnd()); }
                    catch { }
                });
                errThread.IsBackground = true;
                errThread.Start();

                int lastPct = -1;
                try
                {
                    int ch;
                    while ((ch = p.StandardOutput.Read()) >= 0)
                    {
                        if (cancelled != null && cancelled())
                        {
                            try { p.Kill(); }
                            catch { }
                            break;
                        }

                        char c = (char)ch;
                        if (c == '\n' || c == '\r')
                        {
                            continue;
                        }

                        tail.Append(c);
                        char[] digit = new char[] { c };
                        if (c == '.' || c == ' ')
                        {
                            Match m = Regex.Match(tail.ToString(), @"(\d{1,3})\s*\.\.\.");
                            if (m.Success)
                            {
                                int pct = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                                int mapped = pctFrom + (pctTo - pctFrom) * pct / 100;
                                if (mapped != lastPct)
                                {
                                    lastPct = mapped;
                                    report(mapped, null);
                                }
                                tail.Length = 0;
                            }
                        }
                        if (tail.Length > 64) tail.Remove(0, tail.Length - 64);
                    }
                }
                catch { }

                p.WaitForExit(60000);
                errThread.Join(3000);
                try { exitCode = p.ExitCode; }
                catch { exitCode = -1; }
            }

            string err = stderr.ToString();
            return err;
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch { }
        }

        private static string Trim(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return "";
            s = s.Trim();
            if (s.Length > max) s = s.Substring(0, max) + "...";
            return s;
        }
    }

    // ---------------------------------------------------------------- CLI

    internal static class Cli
    {
        public static int Run(string[] args)
        {
            if (!Gdal.Locate())
            {
                Console.Error.WriteLine("GDAL not found. Install with: winget install GISInternals.GDAL");
                return 2;
            }
            if (args.Length < 4)
            {
                Console.Error.WriteLine("Usage: OrthoTiler.exe --cli <input.tif> <minZoom> <maxZoom> [--jpeg] [--out <file.mbtiles>]");
                return 2;
            }

            ConversionOptions o = new ConversionOptions();
            o.InputPath = args[1];
            o.MinZoom = int.Parse(args[2], CultureInfo.InvariantCulture);
            o.MaxZoom = int.Parse(args[3], CultureInfo.InvariantCulture);

            string outPath = null;
            for (int i = 4; i < args.Length; i++)
            {
                if (args[i] == "--jpeg") o.Jpeg = true;
                else if (args[i] == "--out" && i + 1 < args.Length) outPath = args[++i];
            }

            string error;
            SourceInfo info = Metadata.Read(o.InputPath, out error);
            if (info == null)
            {
                Console.Error.WriteLine(error);
                return 3;
            }

            o.CenterLat = info.CenterLat;
            o.BandCount = info.BandCount;
            o.DropAlpha = info.HasAlpha;
            // Resample whenever the source carries more detail than the requested
            // zoom, otherwise the driver picks a zoom of its own (and errors above 22).
            double targetRes = Geo.ResolutionAtZoom(info.CenterLat, o.MaxZoom);
            o.TargetSourceResolution = info.GroundGsd < targetRes * 1.02
                ? Geo.SourceResolutionForZoom(info, o.MaxZoom)
                : 0;
            o.NativeMaxZoom = Geo.RawMaxZoomForGsd(info.CenterLat, info.GroundGsd);
            if (outPath == null)
            {
                outPath = Path.Combine(
                    Path.GetDirectoryName(o.InputPath),
                    Path.GetFileNameWithoutExtension(o.InputPath) + ".mbtiles");
            }
            o.OutputPath = outPath;

            Console.WriteLine("Input : " + info.Width + " x " + info.Height + " px, " +
                info.GroundAccuracy.ToString("0.###", CultureInfo.InvariantCulture) + " m/px, " +
                info.AreaHa.ToString("0.#", CultureInfo.InvariantCulture) + " ha");
            Console.WriteLine("Output: " + o.OutputPath);
            Console.WriteLine("Zooms : " + o.MinZoom + "-" + o.MaxZoom);

            ConversionResult r = Converter.Run(
                o,
                delegate (int pct, string msg) { if (msg != null) Console.WriteLine(msg); },
                delegate () { return false; });

            if (!r.Success)
            {
                Console.Error.WriteLine("FAILED: " + r.Error);
                return 1;
            }

            FileInfo fi = new FileInfo(o.OutputPath);
            Console.WriteLine("OK: " + (fi.Length / 1048576.0).ToString("0.##", CultureInfo.InvariantCulture) + " MB");
            return 0;
        }
    }

    // ---------------------------------------------------------------- GUI

    internal class MainForm : Form
    {
        private TextBox _txtInput;
        private Button _btnBrowseInput;
        private Label _lblInfo;
        private TextBox _txtOutput;
        private Button _btnBrowseOutput;
        private NumericUpDown _numMin;
        private NumericUpDown _numMax;
        private ComboBox _cboFormat;
        private CheckBox _chkOverviews;
        private CheckBox _chkOpenWhenDone;
        private Label _lblEstimate;
        private Button _btnConvert;
        private Button _btnCancel;
        private ProgressBar _progress;
        private Label _lblStatus;
        private TextBox _txtLog;
        private Label _lblGdal;

        private SourceInfo _source;
        private Thread _worker;
        private volatile bool _cancelRequested;

        public MainForm()
        {
            Text = "OrthoTiler - GeoTIFF to MBTiles";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            ClientSize = new Size(760, 640);
            Font = new Font("Segoe UI", 9f);

            BuildUi();
            Load += delegate { OnLoad(); };
        }

        private void BuildUi()
        {
            int y = 12;

            GroupBox grpSource = new GroupBox();
            grpSource.Text = "1. Choose your orthomosaic (GeoTIFF)";
            grpSource.Location = new Point(12, y);
            grpSource.Size = new Size(736, 152);
            Controls.Add(grpSource);

            _txtInput = new TextBox();
            _txtInput.Location = new Point(12, 26);
            _txtInput.Size = new Size(596, 24);
            _txtInput.ReadOnly = true;
            grpSource.Controls.Add(_txtInput);

            _btnBrowseInput = new Button();
            _btnBrowseInput.Text = "Browse...";
            _btnBrowseInput.Location = new Point(618, 24);
            _btnBrowseInput.Size = new Size(104, 28);
            _btnBrowseInput.Click += delegate { BrowseInput(); };
            grpSource.Controls.Add(_btnBrowseInput);

            _lblInfo = new Label();
            _lblInfo.Location = new Point(12, 58);
            _lblInfo.Size = new Size(710, 84);
            _lblInfo.Text = "No file selected.";
            _lblInfo.ForeColor = Color.DimGray;
            grpSource.Controls.Add(_lblInfo);

            y += 164;

            GroupBox grpOut = new GroupBox();
            grpOut.Text = "2. Output and zoom levels";
            grpOut.Location = new Point(12, y);
            grpOut.Size = new Size(736, 196);
            Controls.Add(grpOut);

            Label lblOut = new Label();
            lblOut.Text = "Save as:";
            lblOut.Location = new Point(12, 29);
            lblOut.Size = new Size(60, 20);
            grpOut.Controls.Add(lblOut);

            _txtOutput = new TextBox();
            _txtOutput.Location = new Point(76, 26);
            _txtOutput.Size = new Size(532, 24);
            grpOut.Controls.Add(_txtOutput);

            _btnBrowseOutput = new Button();
            _btnBrowseOutput.Text = "Browse...";
            _btnBrowseOutput.Location = new Point(618, 24);
            _btnBrowseOutput.Size = new Size(104, 28);
            _btnBrowseOutput.Click += delegate { BrowseOutput(); };
            grpOut.Controls.Add(_btnBrowseOutput);

            Label lblMin = new Label();
            lblMin.Text = "Min zoom:";
            lblMin.Location = new Point(12, 70);
            lblMin.Size = new Size(64, 20);
            grpOut.Controls.Add(lblMin);

            _numMin = new NumericUpDown();
            _numMin.Minimum = 0;
            _numMin.Maximum = 22;
            _numMin.Value = 15;
            _numMin.Location = new Point(80, 68);
            _numMin.Size = new Size(60, 24);
            _numMin.ValueChanged += delegate { UpdateEstimate(); };
            grpOut.Controls.Add(_numMin);

            Label lblMax = new Label();
            lblMax.Text = "Max zoom:";
            lblMax.Location = new Point(160, 70);
            lblMax.Size = new Size(68, 20);
            grpOut.Controls.Add(lblMax);

            _numMax = new NumericUpDown();
            _numMax.Minimum = 0;
            _numMax.Maximum = 22;
            _numMax.Value = 21;
            _numMax.Location = new Point(232, 68);
            _numMax.Size = new Size(60, 24);
            _numMax.ValueChanged += delegate { UpdateEstimate(); };
            grpOut.Controls.Add(_numMax);

            Label lblFormat = new Label();
            lblFormat.Text = "Image format:";
            lblFormat.Location = new Point(316, 70);
            lblFormat.Size = new Size(84, 20);
            grpOut.Controls.Add(lblFormat);

            _cboFormat = new ComboBox();
            _cboFormat.DropDownStyle = ComboBoxStyle.DropDownList;
            _cboFormat.Location = new Point(402, 68);
            _cboFormat.Size = new Size(190, 24);
            _cboFormat.Items.Add("PNG - keeps transparency");
            _cboFormat.Items.Add("JPEG - smaller file");
            _cboFormat.SelectedIndex = 0;
            _cboFormat.SelectedIndexChanged += delegate { UpdateEstimate(); };
            grpOut.Controls.Add(_cboFormat);

            _chkOverviews = new CheckBox();
            _chkOverviews.Text = "Build lower zoom levels (recommended)";
            _chkOverviews.Location = new Point(12, 104);
            _chkOverviews.Size = new Size(300, 22);
            _chkOverviews.Checked = true;
            _chkOverviews.CheckedChanged += delegate { UpdateEstimate(); };
            grpOut.Controls.Add(_chkOverviews);

            _chkOpenWhenDone = new CheckBox();
            _chkOpenWhenDone.Text = "Open folder when finished";
            _chkOpenWhenDone.Location = new Point(330, 104);
            _chkOpenWhenDone.Size = new Size(220, 22);
            _chkOpenWhenDone.Checked = true;
            grpOut.Controls.Add(_chkOpenWhenDone);

            _lblEstimate = new Label();
            _lblEstimate.Location = new Point(12, 134);
            _lblEstimate.Size = new Size(710, 50);
            _lblEstimate.Text = "Select a file to see the estimate.";
            _lblEstimate.ForeColor = Color.DimGray;
            grpOut.Controls.Add(_lblEstimate);

            y += 208;

            _btnConvert = new Button();
            _btnConvert.Text = "Convert to MBTiles";
            _btnConvert.Location = new Point(12, y);
            _btnConvert.Size = new Size(180, 38);
            _btnConvert.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            _btnConvert.Click += delegate { StartConversion(); };
            Controls.Add(_btnConvert);

            _btnCancel = new Button();
            _btnCancel.Text = "Cancel";
            _btnCancel.Location = new Point(200, y);
            _btnCancel.Size = new Size(100, 38);
            _btnCancel.Enabled = false;
            _btnCancel.Click += delegate { CancelConversion(); };
            Controls.Add(_btnCancel);

            _progress = new ProgressBar();
            _progress.Location = new Point(312, y + 4);
            _progress.Size = new Size(436, 14);
            _progress.Minimum = 0;
            _progress.Maximum = 100;
            Controls.Add(_progress);

            _lblStatus = new Label();
            _lblStatus.Location = new Point(312, y + 19);
            _lblStatus.Size = new Size(436, 20);
            _lblStatus.Text = "Ready.";
            Controls.Add(_lblStatus);

            y += 46;

            _txtLog = new TextBox();
            _txtLog.Location = new Point(12, y);
            _txtLog.Size = new Size(736, 92);
            _txtLog.Multiline = true;
            _txtLog.ReadOnly = true;
            _txtLog.ScrollBars = ScrollBars.Vertical;
            _txtLog.Font = new Font("Consolas", 8.5f);
            Controls.Add(_txtLog);

            _lblGdal = new Label();
            _lblGdal.Location = new Point(12, y + 96);
            _lblGdal.Size = new Size(736, 20);
            _lblGdal.ForeColor = Color.DimGray;
            Controls.Add(_lblGdal);
        }

        private void OnLoad()
        {
            if (!Gdal.Locate())
            {
                _lblGdal.Text = "GDAL not found.";
                MessageBox.Show(
                    "GDAL was not found.\n\nInstall it once with:\n    winget install GISInternals.GDAL\n\nor copy the GDAL folder next to this program.",
                    "OrthoTiler",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                _btnConvert.Enabled = false;
                return;
            }
            _lblGdal.Text = "GDAL: " + Gdal.Home;
            AppendLog("Using GDAL at " + Gdal.Home);
        }

        private void BrowseInput()
        {
            OpenFileDialog dlg = new OpenFileDialog();
            dlg.Title = "Choose an orthomosaic";
            dlg.Filter = "GeoTIFF (*.tif;*.tiff)|*.tif;*.tiff|All files (*.*)|*.*";
            if (dlg.ShowDialog(this) != DialogResult.OK) return;

            _txtInput.Text = dlg.FileName;

            string error;
            SourceInfo info = Metadata.Read(dlg.FileName, out error);
            if (info == null)
            {
                _source = null;
                _lblInfo.Text = "Could not read this file.\n" + error;
                _lblInfo.ForeColor = Color.Firebrick;
                return;
            }

            _source = info;
            _lblInfo.ForeColor = Color.Black;
            _lblInfo.Text = string.Format(
                CultureInfo.InvariantCulture,
                "{0} x {1} px   |   {2} m per pixel   |   {3} ha   |   {4} bands{5}   |   {6}\r\n" +
                "Bounds: {7:0.00000} to {8:0.00000} E, {9:0.00000} to {10:0.00000} S",
                info.Width, info.Height,
                info.GroundAccuracy.ToString("0.###", CultureInfo.InvariantCulture),
                info.AreaHa.ToString("0.#", CultureInfo.InvariantCulture),
                info.BandCount,
                info.HasAlpha ? " (with transparency)" : "",
                string.IsNullOrEmpty(info.Crs) ? "unknown CRS" : info.Crs,
                info.West, info.East, info.South, info.North);

            string dir = Path.GetDirectoryName(dlg.FileName);
            string name = Path.GetFileNameWithoutExtension(dlg.FileName) + ".mbtiles";
            _txtOutput.Text = Path.Combine(dir, name);

            int recommended = Geo.MaxZoomForGsd(info.CenterLat, info.GroundAccuracy);
            _numMax.Value = recommended;
            _numMin.Value = Math.Max(0, Math.Min(recommended - 6, 15));

            UpdateEstimate();
            AppendLog("Loaded " + Path.GetFileName(dlg.FileName));
        }

        private void BrowseOutput()
        {
            SaveFileDialog dlg = new SaveFileDialog();
            dlg.Title = "Save MBTiles as";
            dlg.Filter = "MBTiles (*.mbtiles)|*.mbtiles";
            dlg.FileName = Path.GetFileName(_txtOutput.Text);
            string dir = Path.GetDirectoryName(_txtOutput.Text);
            if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir)) dlg.InitialDirectory = dir;
            if (dlg.ShowDialog(this) == DialogResult.OK) _txtOutput.Text = dlg.FileName;
        }

        private void UpdateEstimate()
        {
            if (_source == null) return;

            int min = (int)_numMin.Value;
            int max = (int)_numMax.Value;
            if (min > max)
            {
                _lblEstimate.Text = "Min zoom cannot be greater than max zoom.";
                _lblEstimate.ForeColor = Color.Firebrick;
                return;
            }

            long top = Geo.EstimateTiles(_source, max, max);
            long total = Geo.EstimateTiles(_source, min, _chkOverviews.Checked ? max : max);
            if (!_chkOverviews.Checked) total = top;

            bool jpeg = _cboFormat.SelectedIndex == 1;
            double bytesPerTile = jpeg ? 22000.0 : 70000.0;
            double estimateMb = total * bytesPerTile / 1048576.0;

            double res = Geo.ResolutionAtZoom(_source.CenterLat, max);
            _lblEstimate.ForeColor = Color.Black;
            _lblEstimate.Text = string.Format(
                CultureInfo.InvariantCulture,
                "Zoom {0}-{1}: about {2:N0} tiles, roughly {3:N0} MB. At zoom {1} each pixel is {4:0.##} m.\r\n" +
                "Recommended max zoom for {5:0.###} m source: {6}.",
                min, max, total, estimateMb, res,
                _source.GroundAccuracy, Geo.MaxZoomForGsd(_source.CenterLat, _source.GroundAccuracy));

            if (estimateMb > 3000)
            {
                _lblEstimate.Text += "\r\nThat is a very large file - consider lowering the max zoom.";
                _lblEstimate.ForeColor = Color.DarkOrange;
            }
            if (Geo.RawMaxZoomForGsd(_source.CenterLat, _source.GroundGsd) > 22)
            {
                _lblEstimate.Text += "\r\nThis source is finer than zoom 22 (the maximum supported); it will be resampled.";
                _lblEstimate.ForeColor = Color.DarkOrange;
            }
        }

        private void StartConversion()
        {
            if (_source == null)
            {
                MessageBox.Show("Choose an orthomosaic first.", "OrthoTiler");
                return;
            }
            if (string.IsNullOrWhiteSpace(_txtOutput.Text))
            {
                MessageBox.Show("Choose where to save the MBTiles file.", "OrthoTiler");
                return;
            }

            ConversionOptions o = new ConversionOptions();
            o.InputPath = _txtInput.Text;
            o.OutputPath = _txtOutput.Text;
            o.MinZoom = (int)_numMin.Value;
            o.MaxZoom = (int)_numMax.Value;
            o.Jpeg = _cboFormat.SelectedIndex == 1;
            o.DropAlpha = _source.HasAlpha;
            o.BuildOverviews = _chkOverviews.Checked;
            o.CenterLat = _source.CenterLat;
            o.BandCount = _source.BandCount;
            double targetRes = Geo.ResolutionAtZoom(_source.CenterLat, o.MaxZoom);
            o.TargetSourceResolution = _source.GroundGsd < targetRes * 1.02
                ? Geo.SourceResolutionForZoom(_source, o.MaxZoom)
                : 0;
            o.NativeMaxZoom = Geo.RawMaxZoomForGsd(_source.CenterLat, _source.GroundGsd);

            if (o.MinZoom > o.MaxZoom)
            {
                MessageBox.Show("Min zoom cannot be greater than max zoom.", "OrthoTiler");
                return;
            }

            _cancelRequested = false;
            SetBusy(true);
            AppendLog("--- starting conversion ---");
            AppendLog("gdal_translate " + Converter.BuildTranslateArguments(o));

            _worker = new Thread(delegate ()
            {
                ConversionResult r = Converter.Run(
                    o,
                    delegate (int pct, string msg) { PostProgress(pct, msg); },
                    delegate () { return _cancelRequested; });

                PostFinished(r, o);
            });
            _worker.IsBackground = true;
            _worker.Start();
        }

        private void CancelConversion()
        {
            _cancelRequested = true;
            _btnCancel.Enabled = false;
            _lblStatus.Text = "Cancelling...";
        }

        private void PostProgress(int pct, string message)
        {
            if (IsDisposed) return;
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    if (pct < _progress.Minimum) pct = _progress.Minimum;
                    if (pct > _progress.Maximum) pct = _progress.Maximum;
                    _progress.Value = pct;
                    if (!string.IsNullOrEmpty(message)) _lblStatus.Text = message;
                });
            }
            catch { }
        }

        private void PostFinished(ConversionResult r, ConversionOptions o)
        {
            if (IsDisposed) return;
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    SetBusy(false);

                    if (r.Success)
                    {
                        _progress.Value = 100;
                        FileInfo fi = new FileInfo(o.OutputPath);
                        double mb = Math.Round(fi.Length / 1048576.0, 1);
                        _lblStatus.Text = "Finished - " + mb + " MB";
                        AppendLog("Finished: " + o.OutputPath + " (" + mb + " MB)");

                        if (_chkOpenWhenDone.Checked)
                        {
                            try { Process.Start("explorer.exe", "/select,\"" + o.OutputPath + "\""); }
                            catch { }
                        }
                    }
                    else
                    {
                        _lblStatus.Text = "Failed.";
                        AppendLog(r.Error);
                        MessageBox.Show(r.Error, "Conversion failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                });
            }
            catch { }
        }

        private void SetBusy(bool busy)
        {
            _btnConvert.Enabled = !busy;
            _btnBrowseInput.Enabled = !busy;
            _btnBrowseOutput.Enabled = !busy;
            _btnCancel.Enabled = busy;
            _numMin.Enabled = !busy;
            _numMax.Enabled = !busy;
            _cboFormat.Enabled = !busy;
            _chkOverviews.Enabled = !busy;
            if (busy)
            {
                _progress.Value = 0;
                _lblStatus.Text = "Working...";
            }
        }

        private void AppendLog(string line)
        {
            if (string.IsNullOrEmpty(line)) return;
            _txtLog.AppendText(line + Environment.NewLine);
        }
    }
}
