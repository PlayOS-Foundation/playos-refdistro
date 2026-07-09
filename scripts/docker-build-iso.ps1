$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
Set-Location $Root

if (!(Test-Path "$Root\out")) {
    New-Item -ItemType Directory -Path "$Root\out" | Out-Null
}

docker run --rm -it --privileged `
  -v "${Root}:/workspace" `
  playos-arch-builder `
  /workspace/scripts/build-iso-docker.sh
