$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
Set-Location $Root

docker build -t playos-arch-builder -f docker/Dockerfile .
