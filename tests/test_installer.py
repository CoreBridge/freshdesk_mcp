"""Static checks on the Windows installer that run anywhere, plus the PowerShell checks where pwsh exists.

The full checks (parse, PSScriptAnalyzer, Pester) live in tests/installer/Invoke-InstallerChecks.ps1.
"""

import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install-corebridge-freshdesk-mcp.ps1"
CHECKS = ROOT / "tests" / "installer" / "Invoke-InstallerChecks.ps1"


def param_block(text):
    match = re.search(r"\[CmdletBinding\(\)\]\s*param\((.*?)\n\)", text, re.S)
    assert match, "installer has no top-level param block"
    return match.group(1)


def function_body(text, name):
    match = re.search(rf"function {name} \{{(.*?)\n\}}", text, re.S)
    assert match, f"{name} not found"
    return match.group(1)


class InstallerStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = INSTALLER.read_text(encoding="utf-8")

    def test_defaults_to_gateway_mode_on_prod_with_the_gateway_client(self):
        params = param_block(self.text)
        self.assertIn('[string]$GatewayEnv = "prod"', params)
        self.assertIn('[ValidateSet("dev", "qa", "preview", "prod")]', params)
        self.assertIn('[string]$ClientId = "b00e08ff-9e23-42f4-97b2-da02455ae39b"', params)
        self.assertRegex(params, r'\[string\]\$GatewayUrl = "https://')
        self.assertIn("[switch]$ApiKeyMode", params)
        self.assertIn('[string]$ApiKey = ""', params)

    def test_gateway_entry_never_carries_an_api_key(self):
        body = function_body(self.text, "New-FreshdeskMcpEntry")
        gateway_branch = body.split('if ($Mode -eq "gateway") {', 1)[1].split("} else {", 1)[0]
        self.assertNotIn("FRESHDESK_API_KEY", gateway_branch)
        self.assertIn('"FRESHDESK_AUTH_MODE"] = "entra"', gateway_branch)
        self.assertIn('"FRESHDESK_GATEWAY_ENV"', gateway_branch)

    def test_api_key_prompt_only_happens_in_api_key_mode(self):
        prompt = self.text.index('Read-Host "Paste your Freshdesk API key"')
        guard = self.text.rindex('if ($Mode -eq "apikey") {', 0, prompt)
        self.assertGreater(prompt, guard)

    def test_installer_is_ascii(self):
        # Windows PowerShell 5.1 reads a BOM-less script as ANSI: keep it pure ASCII.
        INSTALLER.read_bytes().decode("ascii")

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 (pwsh) not installed")
    def test_powershell_parse_lint_and_pester(self):
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(CHECKS)],
            capture_output=True, text=True, timeout=600,
        )
        self.assertEqual(result.returncode, 0, result.stdout[-4000:] + result.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
