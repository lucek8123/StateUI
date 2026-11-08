# SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
# SPDX-License-Identifier: Apache-2.0

# What the web view's backend lays beside a WinUI application linking it: the
# WebView2 package's component, whose classes WinUI's manifest names, and its
# loader - through them WinUI's WebView2 drives the system's WebView2 runtime.
# Run by .scripts/WinUI/tools.ps1 (Set-StateUISelfContained) for the directory
# it makes self-contained, for the architecture the application is built for;
# an application without the backend gets nothing.
param([string]$Directory, [string]$Architecture, [string]$Packages)

if (-not (Test-Path (Join-Path $Directory 'StateUIWebViewWinUI.dll'))) { return }

# The package folders the Swift tool fetched, as `id=path` entries. The old
# PowerShell flow defines this helper in tools.ps1; the Swift tool runs this
# script directly, so it carries the lookup itself when it passes -Packages.
if ($Packages) {
    function Get-StateUIPackage([string]$Id) {
        foreach ($entry in $Packages.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $pair = $entry.Split('=', 2)
            if ($pair.Length -eq 2 -and $pair[0] -eq $Id) { return $pair[1] }
        }
        throw "no package folder was named for $Id"
    }
}

$webview = Get-StateUIPackage 'microsoft.web.webview2'
Copy-Item (Join-Path $webview "runtimes\win-$Architecture\native_uap\Microsoft.Web.WebView2.Core.dll") $Directory -Force
Copy-Item (Join-Path $webview "runtimes\win-$Architecture\native\WebView2Loader.dll") $Directory -Force
