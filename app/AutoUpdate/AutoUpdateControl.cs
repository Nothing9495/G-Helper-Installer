using GHelper.Helpers;
using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GHelper.AutoUpdate
{
    public class AutoUpdateControl
    {

        SettingsForm settings;

        public string versionUrl = "https://github.com/Nothing9495/G-Helper-Installer/releases";
        public bool update = false;

        static long lastUpdate;

        public AutoUpdateControl(SettingsForm settingsForm)
        {
            settings = settingsForm;
            var appVersion = new Version(Assembly.GetExecutingAssembly().GetName().Version.ToString());
            settings.SetVersionLabel(Properties.Strings.VersionLabel + $": {appVersion.Major}.{appVersion.Minor}.{appVersion.Build}");
        }

        public void CheckForUpdates()
        {
            // Run update once per 12 hours
            if (Math.Abs(DateTimeOffset.Now.ToUnixTimeSeconds() - lastUpdate) < 43200) return;
            lastUpdate = DateTimeOffset.Now.ToUnixTimeSeconds();

            Task.Run(async () =>
            {
                await Task.Delay(TimeSpan.FromSeconds(1));
                CheckForUpdatesAsync();
            });
        }

        public void Update()
        {
            if (update)
            {
                Task.Run(() =>
                {
                    CheckForUpdatesAsync(true);
                });
            } else
            {
                LoadReleases();
            }
        }

        public void LoadReleases()
        {
            try
            {
                Process.Start(new ProcessStartInfo(versionUrl) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Logger.WriteLine("Failed to open releases page:" + ex.Message);
            }
        }

        async void CheckForUpdatesAsync(bool force = false)
        {

            if (AppConfig.Is("skip_updates")) return;

            try
            {

                using (var httpClient = new HttpClient())
                {
                    httpClient.DefaultRequestHeaders.Add("User-Agent", "G-Helper App");
                    var json = await httpClient.GetStringAsync("https://api.github.com/repos/Nothing9495/G-Helper-Installer/releases/latest");
                    var config = JsonSerializer.Deserialize<JsonElement>(json);
                    var tagName = config.GetProperty("tag_name").ToString();
                    var tag = tagName.Replace("v", "");
                    var assets = config.GetProperty("assets");

                    // The release workflow names the asset deterministically, so match it
                    // exactly instead of guessing. Falling back to assets[0] could select a
                    // checksum file, and that must never be executed.
                    string expectedAsset = $"GHelper-{tagName}-Setup.exe";
                    string url = null;

                    for (int i = 0; i < assets.GetArrayLength(); i++)
                    {
                        var assetUrl = assets[i].GetProperty("browser_download_url").ToString();
                        if (assetUrl.EndsWith(expectedAsset, StringComparison.OrdinalIgnoreCase))
                            url = assetUrl;
                    }

                    if (url is null)
                    {
                        Logger.WriteLine($"No {expectedAsset} asset in release {tagName}");
                        LoadReleases();
                        return;
                    }

                    var gitVersion = new Version(tag);
                    var appVersion = new Version(Assembly.GetExecutingAssembly().GetName().Version.ToString());
                    //appVersion = new Version("0.50.0.0"); 

                    if (gitVersion.CompareTo(appVersion) > 0)
                    {
                        versionUrl = url;
                        update = true;
                        settings.SetVersionLabel(Properties.Strings.DownloadUpdate + $": {appVersion.Major}.{appVersion.Minor}.{appVersion.Build} → {tag}", true);

                        string[] args = Environment.GetCommandLineArgs();
                        if (force || args.Length > 1 && args[1] == "autoupdate")
                        {
                            AutoUpdate(url);
                            return;
                        }

                        if (AppConfig.GetString("skip_version") != tag)
                        {
                            DialogResult dialogResult = settings.ShowMessage(Properties.Strings.DownloadUpdate + ": G-Helper " + tag + "?", "Update", MessageBoxButtons.YesNo);
                            if (dialogResult == DialogResult.Yes)
                                AutoUpdate(url);
                            else
                                AppConfig.Set("skip_version", tag);
                        }

                    }
                    else
                    {
                        Logger.WriteLine($"Latest version {appVersion}");
                    }

                }
            }
            catch (Exception ex)
            {
                Logger.WriteLine("Failed to check for updates:" + ex.Message);
            }

        }

        public static string EscapeString(string input)
        {
            return Regex.Replace(Regex.Replace(input, @"\[|\]", "`$0"), @"\'", "''");
        }

        async void AutoUpdate(string requestUri)
        {

            string exeDir = Path.GetDirectoryName(Application.ExecutablePath) ?? ""; string setupLocation = Path.Combine(Path.GetTempPath(), "GHelper-Setup.exe");

            using (HttpClient client = new HttpClient())
            {

                client.DefaultRequestHeaders.Add("User-Agent", "G-Helper App");
                Logger.WriteLine(requestUri);
                Logger.WriteLine(exeDir);
                Logger.WriteLine(setupLocation);

                try
                {
                    var bytes = await client.GetByteArrayAsync(requestUri);
                    File.WriteAllBytes(setupLocation, bytes);
                    Logger.WriteLine($"Downloaded {bytes.Length}b: {setupLocation} (exists={File.Exists(setupLocation)}, size={new FileInfo(setupLocation).Length})");
                }
                catch (Exception ex)
                {
                    Logger.WriteLine(ex.Message);
                    if (!ProcessHelper.IsUserAdministrator())
                    {
                        ProcessHelper.RunAsAdmin("autoupdate");
                        Application.Exit();
                    } else
                    {
                        LoadReleases();
                    }
                    return;
                }

                try
                {
                    Process.Start(new ProcessStartInfo(setupLocation)
                    {
                        UseShellExecute = true,
                        Verb = "runas",
                        WorkingDirectory = exeDir
                    });
                }
                catch (Exception ex)
                {
                    Logger.WriteLine(ex.Message);
                    LoadReleases();
                }

                Application.Exit();
            }

        }

    }
}
