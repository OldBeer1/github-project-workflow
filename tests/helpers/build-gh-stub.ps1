param([string]$Output)
$ErrorActionPreference='Stop'
$code=@'
using System;
using System.IO;
public class Stub {
    public static int Main(string[] args) {
        string state=Environment.GetEnvironmentVariable("GH_TEST_STATE");
        string log=Environment.GetEnvironmentVariable("GH_TEST_LOG");
        if (args.Length>0 && args[0]=="api") {
            if (Array.IndexOf(args,"user")>=0) {Console.WriteLine("TestOwner"); return 0;}
            if (Environment.GetEnvironmentVariable("GH_TEST_FAILURE")=="1") {Console.Error.WriteLine("gh: Unavailable (HTTP 503)");return 1;}
            if (!File.Exists(state)) {Console.Error.WriteLine("gh: Not Found (HTTP 404)");return 1;}
            string permission=Environment.GetEnvironmentVariable("GH_TEST_DENY")=="1"?"false":"true";
            Console.WriteLine("{\"full_name\":\"TestOwner/demo\",\"permissions\":{\"push\":"+permission+"},\"default_branch\":\"main\",\"private\":true}");
            return 0;
        }
        if (args.Length>1 && args[0]=="repo" && args[1]=="create") {
            File.AppendAllText(log,string.Join(" ",args)+Environment.NewLine);
            File.WriteAllText(state,"exists");
            Console.WriteLine("https://github.com/TestOwner/demo");return 0;
        }
        Console.Error.WriteLine("Unsupported stub operation");return 2;
    }
}
'@
Add-Type -TypeDefinition $code -OutputAssembly $Output -OutputType ConsoleApplication
