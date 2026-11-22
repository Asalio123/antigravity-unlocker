$ErrorActionPreference = "Stop"

$Repo = "Asalio123/antigravity-unlocker"
$BinName = "ag-unlocker-windows-amd64.exe"
$DestDir = Join-Path $env:LOCALAPPDATA "ag-unlocker\bin"
$Dest = Join-Path $DestDir "ag-unlocker.exe"
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

$Url = "https://github.com/$Repo/releases/latest/download/$BinName"
Write-Host "[i] Скачиваю $BinName..." -ForegroundColor Cyan

try {
    Invoke-WebRequest -Uri $Url -OutFile "$Dest.tmp" -UseBasicParsing
    Move-Item -Force "$Dest.tmp" $Dest
    Write-Host "[OK] Установлено: $Dest" -ForegroundColor Green
} catch {
    Remove-Item -ErrorAction SilentlyContinue "$Dest.tmp"
    if (Get-Command go -ErrorAction SilentlyContinue) {
        Write-Host "[i] Релизный бинарь недоступен — собираю из исходников через Go..." -ForegroundColor Cyan
        $TmpDir = Join-Path $env:TEMP ("ag-unlocker-build-" + [guid]::NewGuid().ToString("N"))
        git clone --depth 1 "https://github.com/$Repo.git" $TmpDir
        Push-Location $TmpDir
        try {
            $env:CGO_ENABLED = "0"
            go build -trimpath -ldflags="-s -w" -o $Dest .\cmd\ag-unlocker
        } finally {
            Pop-Location
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $TmpDir
        }
        Write-Host "[OK] Собрано и установлено: $Dest" -ForegroundColor Green
    } else {
        Write-Host "[X] Не удалось скачать $Url, а Go не установлен." -ForegroundColor Red
        Write-Host "[i] Скачай ag-unlocker-windows-amd64.exe вручную со страницы https://github.com/$Repo/releases" -ForegroundColor Cyan
        exit 1
    }
}

# Добавляем %LOCALAPPDATA%\ag-unlocker\bin в пользовательский PATH (без прав администратора)
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $UserPath -or ($UserPath -split ";" | Where-Object { $_ -eq $DestDir }).Count -eq 0) {
    $NewPath = if ($UserPath) { "$UserPath;$DestDir" } else { $DestDir }
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    $env:Path = "$env:Path;$DestDir"
}

Write-Host "[i] Запускаю ag-unlocker..." -ForegroundColor Cyan
& $Dest @args
