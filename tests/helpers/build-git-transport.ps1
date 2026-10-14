param([string]$Output)
$ErrorActionPreference='Stop'
$code=@'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
public class SafeGit {
    static string Quote(string value) {
        StringBuilder result=new StringBuilder("\""); int slash=0;
        foreach(char c in value) {
            if(c=='\\') {slash++;continue;}
            if(c=='"') {result.Append('\\',2*slash+1);result.Append('"');slash=0;continue;}
            result.Append('\\',slash);slash=0;result.Append(c);
        }
        result.Append('\\',2*slash);result.Append('"');return result.ToString();
    }
    public static int Main(string[] args) {
        string source=Environment.GetEnvironmentVariable("GH_TEST_ADVANCE_SOURCE");
        string marker=Environment.GetEnvironmentVariable("GH_TEST_ADVANCE_MARKER");
        if(Array.IndexOf(args,"push")>=0 && !string.IsNullOrEmpty(source) && !File.Exists(marker)) {
            File.WriteAllText(marker,"once");
            ProcessStartInfo advance=new ProcessStartInfo(Environment.GetEnvironmentVariable("GH_TEST_REAL_GIT"),
                "-C "+Quote(source)+" commit --allow-empty -m "+Quote("Concurrent fixture commit"));
            advance.UseShellExecute=false;
            using(Process process=Process.Start(advance)) {process.WaitForExit();if(process.ExitCode!=0) return process.ExitCode;}
        }
        bool transport=Array.IndexOf(args,"push")>=0 || Array.IndexOf(args,"fetch")>=0 || Array.IndexOf(args,"ls-remote")>=0;
        List<string> values=new List<string>();
        if(transport && Array.IndexOf(args,"--get-url")<0) {
            string bare=Environment.GetEnvironmentVariable("GH_TEST_BARE");
            values.Add("-c");values.Add("url."+new Uri(bare).AbsoluteUri+".insteadOf=https://github.com/TestOwner/demo.git");
        }
        values.AddRange(args);
        List<string> quoted=new List<string>();foreach(string value in values) quoted.Add(Quote(value));
        ProcessStartInfo info=new ProcessStartInfo(Environment.GetEnvironmentVariable("GH_TEST_REAL_GIT"),string.Join(" ",quoted.ToArray()));
        info.UseShellExecute=false;
        using(Process process=Process.Start(info)) {process.WaitForExit();return process.ExitCode;}
    }
}
'@
Add-Type -TypeDefinition $code -OutputAssembly $Output -OutputType ConsoleApplication
