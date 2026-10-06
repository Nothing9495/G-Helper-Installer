using System.Reflection;
using System.Runtime.InteropServices;

namespace GHelper.Helpers
{
    /// <summary>
    /// Headless command line entry points used by the installer.
    ///
    /// Invoked from Program.Main before any UI exists, so this must never touch
    /// settingsForm, trayIcon or anything else that expects a message loop.
    /// </summary>
    public static class ServiceCli
    {
        private const int ATTACH_PARENT_PROCESS = -1;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeConsole();

        private static readonly string[] Help =
        {
            "G-Helper command line",
            "",
            "  --disable-services [--ac]  Stop and disable ASUS services.",
            "                              --ac also covers Armoury Crate services.",
            "  --enable-services           Re-enable and start ASUS services.",
            "  --install-startup           Register the auto start scheduled task.",
            "  --uninstall-startup         Remove the auto start scheduled task.",
            "  --version                   Print the version and exit.",
            "  --help                      Show this help.",
        };

        /// <summary>
        /// Handles a command line invocation.
        /// Returns true when the arguments were consumed and the tray application
        /// should not start.
        /// </summary>
        public static bool TryRun(string[] args)
        {
            // Upstream uses bare words ("charge", "services", "cpu"...), so every
            // command added here is "--" prefixed and can never collide with them.
            if (args.Length == 0 || !args[0].StartsWith("--", StringComparison.Ordinal)) return false;

            string action = args[0].ToLowerInvariant();
            bool includeArmouryCrate = args.Any(a => a.Equals("--ac", StringComparison.OrdinalIgnoreCase));

            // Every mutating command restarts elevated rather than degrading quietly,
            // which is what Extra.ButtonServices_Click does for the same operations.
            bool mutating = action is "--disable-services" or "--enable-services"
                                or "--install-startup" or "--uninstall-startup";

            if (mutating && !ProcessHelper.IsUserAdministrator())
            {
                Logger.WriteLine($"{action} needs elevation, restarting with the same arguments");
                ProcessHelper.RunAsAdmin(string.Join(" ", args));
                return true;
            }

            switch (action)
            {
                case "--disable-services":
                    // AsusService picks its service list via AppConfig.IsStopAC(), so the
                    // flag has to be set before StopAsusServices() reads it.
                    if (includeArmouryCrate) AppConfig.Set("stop_ac", 1);
                    try
                    {
                        AsusService.StopAsusServices();
                    }
                    catch (Exception ex)
                    {
                        // StopAsusServices() ends in AllyControl.ApplyMode(), which is not
                        // guarded upstream and can throw on unexpected hardware. A failure
                        // here must not fail the installation.
                        Logger.WriteLine("Disable services failed: " + ex);
                    }
                    return Finish();

                case "--enable-services":
                    try
                    {
                        AsusService.StartAsusServices();
                    }
                    catch (Exception ex)
                    {
                        Logger.WriteLine("Enable services failed: " + ex);
                    }
                    return Finish();

                case "--install-startup":
                    // quiet: the installer runs this hidden, so a modal error would hang it.
                    Startup.Schedule(quiet: true);
                    return Finish();

                case "--uninstall-startup":
                    Startup.UnSchedule(quiet: true);
                    return Finish();

                case "--version":
                    WriteOutput("G-Helper " + Assembly.GetExecutingAssembly().GetName().Version);
                    return true;

                default:
                    // --help and any unrecognised "--" argument.
                    foreach (string line in Help) WriteOutput(line);
                    return true;
            }
        }

        /// <summary>
        /// Persists pending config changes and exits. AppConfig debounces writes by two
        /// seconds, so without this the headless process would die before services_disabled
        /// / stop_ac reached disk and G-Helper would forget its state on next launch.
        /// </summary>
        private static bool Finish()
        {
            AppConfig.Flush();
            Application.Exit();
            return true;
        }

        /// <summary>
        /// This is a WinExe and owns no console, so borrow the caller's for the
        /// few commands that produce output. Silently does nothing under the
        /// installer, which runs these hidden.
        /// </summary>
        private static void WriteOutput(string text)
        {
            if (!AttachConsole(ATTACH_PARENT_PROCESS)) return;
            Console.WriteLine(text);
            Console.Out.Flush();
            FreeConsole();
        }
    }
}