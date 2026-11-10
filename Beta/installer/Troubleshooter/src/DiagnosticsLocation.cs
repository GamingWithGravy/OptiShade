using System;
using System.IO;

namespace OptiShade.TesterKit {
    public static class DiagnosticsLocation {
        public static string Root {
            get {
                string configured=Environment.GetEnvironmentVariable("OPTISHADE_DIAGNOSTICS_DIR");
                if(!String.IsNullOrWhiteSpace(configured))return Path.GetFullPath(configured);
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade","Diagnostics");
            }
        }
    }
}
