# Canonical source for the Codex Windows hook command.
#
# This file is NOT executed by path. It is compiled into the -EncodedCommand payload
# in hooks.codex.json, and tests/win_compat.sh asserts the payload still decodes to
# exactly this text, so the two cannot drift apart.
#
# Why encoded at all: Codex's Windows hook runtime wraps the whole command line in a
# literal pair of double quotes for `cmd.exe /C` (openai/codex#38168, open at the time
# of writing), so any command containing embedded quotes is mis-parsed and silently
# does nothing -- the host still reports the hook as completed. A base64 payload has
# no quotes and no spaces, so it survives that wrapping.
#
# Why the absolute powershell path: a bare `powershell.exe` is resolved by cmd's own
# search, which includes the current directory -- a planted powershell.exe in the
# workspace would run instead. The path is taken from %SystemRoot%, which the hook
# host supplies.
$ErrorActionPreference = 'Stop'
# Three encodings, not one. [Console]::InputEncoding/OutputEncoding govern this
# process's own console streams, but $OutputEncoding is what Windows PowerShell 5.1
# uses when piping to a NATIVE command -- and it defaults to ASCII, so without it a
# non-ASCII hook payload reaches Python as question marks.
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$root = $env:CLAUDE_PLUGIN_ROOT
if (-not $root) { $root = $env:CODEX_PLUGIN_ROOT }
if (-not $root) {
  [Console]::Error.WriteLine('sdp precompact hook: plugin root is not set')
  exit 127
}
$script = Join-Path (Join-Path $root 'scripts') 'precompact_hook.py'
if (-not (Test-Path -LiteralPath $script)) {
  [Console]::Error.WriteLine("sdp precompact hook: script not found at $script")
  exit 127
}

# Probe each candidate rather than trusting the first name that resolves: `python`
# can still be 2.x, and a crash inside the hook is the same invisible failure as not
# running at all.
$exe = $null
$pre = @()
foreach ($name in @('py', 'python3', 'python')) {
  $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
  if (-not $found) { continue }
  $candPre = @()
  if ($name -eq 'py') { $candPre = @('-3') }
  & $found.Source @candPre -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>$null
  if ($LASTEXITCODE -eq 0) { $exe = $found.Source; $pre = $candPre; break }
}
if (-not $exe) {
  [Console]::Error.WriteLine('sdp precompact hook: no Python >= 3.9 found (tried py -3, python3, python)')
  exit 127
}

$payload = [Console]::In.ReadToEnd()
$payload | & $exe @pre $script '__SDP_VERB__'
exit $LASTEXITCODE
