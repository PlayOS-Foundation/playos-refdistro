$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
Set-Location $Root

docker build -t playos-alpine-builder -f docker/Dockerfile .
