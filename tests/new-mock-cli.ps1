[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

# Builds the offline mock agent CLI used by both smoke suites. It is a real native
# executable because the wrappers deliberately refuse shims, and it is shared so the
# PowerShell and Git Bash suites exercise the same behaviour.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$mockSource = @'
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

public static class MockCli {
    static string Escape(string value) {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
    }

    static string Payload(string mode) {
        if (mode == "malformed") return "review finished without a terminator\n";
        if (mode == "revise-major") return "[F1.1] major | PLAN.md#D1 | A major-only claim.\n  Scenario: input -> wrong result.\nVERDICT: REVISE\n";
        if (mode == "revise-blocking") return "[F1.1] blocking | PLAN.md#D1 | A blocking claim.\n  Scenario: input -> wrong result.\nVERDICT: REVISE\n";
        if (mode == "revise-pseudo") return "[F1.1] blocking | PLAN.md#D1 | A blocking claim.\n  Scenario: input -> wrong result.\n[F5] Everything else reads fine.\nVERDICT: REVISE\n";
        if (mode == "approve-major") return "[F1.1] major | PLAN.md#D1 | A surviving observation.\n  Scenario: input -> wrong result.\nVERDICT: APPROVE\n";
        if (mode == "approve-pseudo") return "[F5] No blocking scenario survives in the replacement sections.\n\nVERDICT: APPROVE\n";
        if (mode == "approve-bracket-word") return "[Format] note: the plan reads cleanly.\nVERDICT: APPROVE\n";
        if (mode == "result-pass") return "build report\nRESULT: PASS\n";
        if (mode == "append-inbox" || mode == "rewrite-inbox") return "closeout steps completed\nRESULT: PASS\n";
        return "review complete\nVERDICT: APPROVE\n\n";
    }

    static void Sabotage(string mode) {
        // Generic strays let a suite point the mock at any path the wrapper is
        // supposed to protect, including one that merely looks like a sidecar.
        string strayFile = Environment.GetEnvironmentVariable("XLOOP_MOCK_STRAY_FILE");
        if (!String.IsNullOrEmpty(strayFile)) File.WriteAllText(strayFile, "stray payload\n");
        string strayDirectory = Environment.GetEnvironmentVariable("XLOOP_MOCK_STRAY_DIR");
        if (!String.IsNullOrEmpty(strayDirectory)) {
            Directory.CreateDirectory(strayDirectory);
            File.WriteAllText(Path.Combine(strayDirectory, "note.md"), "durable untrusted state\n");
        }

        if (mode == "mutate-core") {
            File.AppendAllText(Path.Combine(".loop", "STATE.md"), "phase: done\n");
            File.WriteAllText(Path.Combine(".loop", "rogue-note.md"), "unexpected addition\n");
        } else if (mode == "mutate-evidence") {
            File.WriteAllText(Path.Combine(".loop", "build", "evidence.diff"), "rewritten evidence\n");
            string second = Path.Combine(".loop", "build", "evidence-two.diff");
            if (File.Exists(second)) File.WriteAllText(second, "rewritten second evidence\n");
        } else if (mode == "append-inbox") {
            File.AppendAllText(Path.Combine(".loop", "wiki-inbox.md"), "- durable note from closeout\n");
        } else if (mode == "rewrite-inbox") {
            File.WriteAllText(Path.Combine(".loop", "wiki-inbox.md"), "clobbered\n");
        } else if (mode == "rewrite-ledger") {
            File.WriteAllText(Path.Combine(".loop", "LEDGER.md"), "# Usage ledger (counts only)\nprivate transcript text\n");
        }
    }

    public static int Main(string[] args) {
        string executable = Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        bool codex = executable.Contains("codex");
        string argsFile = Environment.GetEnvironmentVariable("XLOOP_MOCK_ARGS_FILE");
        if (!String.IsNullOrEmpty(argsFile) && Array.IndexOf(args, "--version") < 0 && Array.IndexOf(args, "--help") < 0) {
            File.WriteAllText(argsFile, String.Join("\n", args), new UTF8Encoding(false));
        }
        if (Array.IndexOf(args, "--version") >= 0) {
            if (Environment.GetEnvironmentVariable("XLOOP_MOCK_HANG_VERSION") == "1") Thread.Sleep(600000);
            Console.WriteLine(codex ? "codex 9.9.9-mock" : "claude 9.9.9-mock");
            return 0;
        }
        if (Array.IndexOf(args, "--help") >= 0) {
            if (codex) return 71;
            Console.WriteLine("  -p, --print\n  --output-format");
            return 0;
        }

        string providerMode = Environment.GetEnvironmentVariable(codex ? "XLOOP_MOCK_CODEX_MODE" : "XLOOP_MOCK_CLAUDE_MODE");
        string mode = providerMode ?? Environment.GetEnvironmentVariable("XLOOP_MOCK_MODE") ?? "approve";
        string callsFile = Environment.GetEnvironmentVariable("XLOOP_MOCK_CALLS_FILE");
        if (!String.IsNullOrEmpty(callsFile)) File.AppendAllText(callsFile, (codex ? "codex" : "claude") + ":" + mode + "\n");
        bool resume = Array.IndexOf(args, "resume") >= 0 || Array.IndexOf(args, "--resume") >= 0;
        if (mode == "resume-fail" && resume) return 9;
        if (mode == "resume-mutated-fail" && resume) return 13;
        if (mode == "resume-invalid" && resume) { Console.Error.WriteLine("session expired before turn"); return 9; }
        if (mode == "resume-requires-fresh") {
            if (resume) return 9;
            string invocationPrompt = codex && args.Length > 0 ? args[args.Length - 1] : "";
            if (!codex) {
                int promptIndex = Array.IndexOf(args, "-p");
                if (promptIndex >= 0 && promptIndex + 1 < args.Length) invocationPrompt = args[promptIndex + 1];
            }
            if (!invocationPrompt.Contains("FRESH PACKET")) return 12;
        }
        if (mode == "mutate-resume-fresh" && resume) { Sabotage("mutate-core"); return 9; }
        if (mode == "quota" || mode == "quota-mutate" || mode == "quota-append") {
            if (mode == "quota-mutate") Sabotage("mutate-core");
            if (mode == "quota-append") Sabotage("append-inbox");
            if (codex && mode == "quota-mutate") {
                string partialOutput = null;
                for (int i = 0; i + 1 < args.Length; i++) if (args[i] == "-o" || args[i] == "--output-last-message") partialOutput = args[i + 1];
                if (!String.IsNullOrEmpty(partialOutput)) File.WriteAllText(partialOutput, "partial provider output\n", new UTF8Encoding(false));
            }
            Console.Error.WriteLine("You've hit your usage limit; resets later.");
            return 29;
        }
        if (mode == "rate-limit") { Console.Error.WriteLine("429 rate limit exceeded; retry after 10 seconds."); return 30; }
        if (mode == "auth-fail") { Console.Error.WriteLine("authentication failed: invalid API key"); return 31; }
        if (mode == "tool-fail") return 7;
        if (mode == "timeout") { Thread.Sleep(5000); return 0; }
        if (mode == "resume-malformed-envelope" && resume && !codex) { Console.Write("truncated-json"); return 0; }
        Sabotage(mode);
        string payload = Payload(mode);
        string usage = mode == "usage"
            ? "{\"input_tokens\":1200,\"output_tokens\":340,\"cached_input_tokens\":800}"
            : null;

        if (codex) {
            string output = null;
            for (int i = 0; i + 1 < args.Length; i++) if (args[i] == "-o" || args[i] == "--output-last-message") output = args[i + 1];
            if (String.IsNullOrEmpty(output)) return 8;
            File.WriteAllText(output, (mode == "bom" ? "\ufeff" : "") + payload, new UTF8Encoding(false));
            Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"mock-thread\"}");
            if (usage != null) Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":" + usage + "}");
        } else {
            string envelope = "{\"session_id\":\"mock-session\",\"is_error\":false,"
                + (usage != null ? "\"usage\":" + usage + "," : "")
                + "\"result\":\"" + Escape((mode == "bom" ? "\ufeff" : "") + payload) + "\"}";
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Write((mode == "bom" ? "\ufeff" : "") + envelope);
        }
        return 0;
    }
}
'@

try {
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $compiled = Join-Path $OutputDirectory 'mock-cli.exe'
    Add-Type -TypeDefinition $mockSource -Language CSharp -OutputAssembly $compiled -OutputType ConsoleApplication
    $codexMock = Join-Path $OutputDirectory 'codex.exe'
    $claudeMock = Join-Path $OutputDirectory 'claude.exe'
    Copy-Item -LiteralPath $compiled -Destination $codexMock -Force
    Copy-Item -LiteralPath $compiled -Destination $claudeMock -Force
    Write-Output $OutputDirectory
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
