# WinForge IT Installer
# Written by Lorenzo Boschi

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ======================
# AUTO-ELEVAZIONE ADMIN
# ======================
$currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ======================
# RISOLUZIONE PERCORSO REALE WINGET
# ======================
# L'alias in WindowsApps non sempre funziona con stdout rediretti sotto admin.
# Cerca il vero winget.exe sotto Program Files\WindowsApps.
function Get-WingetPath {
    # Metodo affidabile: AppxPackage restituisce InstallLocation accessibile
    try {
        $pkg = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg) {
            $exe = Join-Path $pkg.InstallLocation "winget.exe"
            if (Test-Path $exe) { return $exe }
        }
    } catch {}
    # Fallback: alias (potrebbe fallire con stdout rediretto)
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
$script:WingetExe = Get-WingetPath
if (-not $script:WingetExe) {
    [System.Windows.Forms.MessageBox]::Show(
        "winget.exe non trovato sul sistema.`nInstalla 'App Installer' dal Microsoft Store e riprova.",
        "Errore winget", "OK", "Error")
    exit
}

# ======================
# LOG
# ======================

$logFile = "$env:USERPROFILE\Desktop\WinForge_install_log.txt"

function WriteLog($msg) {
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
}

WriteLog "=== Avvio Installer ==="

# ======================
# SISTEMA
# ======================

$sys          = Get-CimInstance Win32_ComputerSystem
$manufacturer = $sys.Manufacturer
$model        = $sys.Model

switch -Regex ($manufacturer) {
    "Dell"   { $vendor = "Dell"    }
    "HP"     { $vendor = "HP"      }
    "Lenovo" { $vendor = "Lenovo"  }
    default  { $vendor = "Generic" }
}

# ======================
# CONTROLLO CONNESSIONE
# ======================

function CheckInternet {
    try {
        return Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue
    } catch {
        return $false
    }
}

if (-not (CheckInternet)) {
    WriteLog "ATTENZIONE: nessuna connessione internet rilevata all'avvio"
    do {
        $scelta = [System.Windows.Forms.MessageBox]::Show(
            "Nessuna connessione internet rilevata.`n`n" +
            "L'installer richiede internet per scaricare le applicazioni tramite winget.`n`n" +
            "Connetti il PC alla rete e clicca Riprova,`n" +
            "oppure clicca Continua per procedere lo stesso.",
            "Attenzione - Nessuna Connessione",
            [System.Windows.Forms.MessageBoxButtons]::RetryCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($scelta -eq [System.Windows.Forms.DialogResult]::Retry) {
            $ok = CheckInternet
        } else {
            $ok = $true
        }
    } while (-not $ok)
}

# ======================
# COLORI / FONT
# ======================

$bgDark  = [System.Drawing.Color]::FromArgb(30, 30, 30)
$bgMenu  = [System.Drawing.Color]::FromArgb(17, 17, 17)
$bgBtn   = [System.Drawing.Color]::FromArgb(50, 50, 50)
$fgWhite = [System.Drawing.Color]::White
$fgCyan  = [System.Drawing.Color]::Cyan
$fgLime  = [System.Drawing.Color]::Lime
$fgRed   = [System.Drawing.Color]::FromArgb(255, 80, 80)
$fgGold  = [System.Drawing.Color]::Gold
$font    = New-Object System.Drawing.Font("Consolas", 10)
$fontBig = New-Object System.Drawing.Font("Consolas", 12, [System.Drawing.FontStyle]::Bold)

# ======================
# AGGIORNAMENTO WINGET
# ======================

$wingetForm                  = New-Object System.Windows.Forms.Form
$wingetForm.Text             = "WinForge - Preparazione"
$wingetForm.Size             = New-Object System.Drawing.Size(500, 160)
$wingetForm.StartPosition    = "CenterScreen"
$wingetForm.BackColor        = $bgDark
$wingetForm.ForeColor        = $fgWhite
$wingetForm.Font             = $font
$wingetForm.TopMost          = $true
$wingetForm.FormBorderStyle  = "FixedSingle"
$wingetForm.MaximizeBox      = $false
$wingetForm.ControlBox       = $false

$wingetLbl           = New-Object System.Windows.Forms.Label
$wingetLbl.Text      = "Aggiornamento winget in corso - non toccare l'installer."
$wingetLbl.Location  = New-Object System.Drawing.Point(20, 22)
$wingetLbl.Size      = New-Object System.Drawing.Size(455, 26)
$wingetLbl.ForeColor = $fgGold
$wingetLbl.TextAlign = "MiddleCenter"
$wingetForm.Controls.Add($wingetLbl)

$wingetSub           = New-Object System.Windows.Forms.Label
$wingetSub.Text      = "L'installer si aprira' automaticamente al termine."
$wingetSub.Location  = New-Object System.Drawing.Point(20, 55)
$wingetSub.Size      = New-Object System.Drawing.Size(455, 22)
$wingetSub.ForeColor = $fgWhite
$wingetSub.TextAlign = "MiddleCenter"
$wingetForm.Controls.Add($wingetSub)

$wingetPb          = New-Object System.Windows.Forms.ProgressBar
$wingetPb.Location = New-Object System.Drawing.Point(20, 90)
$wingetPb.Size     = New-Object System.Drawing.Size(455, 20)
$wingetPb.Style    = "Marquee"
$wingetForm.Controls.Add($wingetPb)

$wingetForm.Show()
$wingetForm.Refresh()

# Helper: avvia un processo con timeout, mantenendo la UI reattiva
function Wait-ProcWithTimeout($proc, [int]$timeoutSec) {
    $start = Get-Date
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()
        if ((Get-Date) - $start -gt [TimeSpan]::FromSeconds($timeoutSec)) {
            try { $proc.Kill() } catch {}
            return $false
        }
    }
    return $true
}

# Aggiorna sorgenti winget (timeout 30s)
$wingetLbl.Text = "Aggiornamento sorgenti winget..."
$wingetForm.Refresh()
$proc1 = Start-Process $script:WingetExe -ArgumentList "source update --disable-interactivity" `
    -NoNewWindow -PassThru
$ok = Wait-ProcWithTimeout $proc1 30
if (-not $ok) { WriteLog "Timeout su source update, saltato" }

WriteLog "Winget aggiornato"
$wingetForm.Close()

# ======================
# FORM
# ======================

$form = New-Object System.Windows.Forms.Form
$form.Text            = "WinForge IT Installer"
$form.Size            = New-Object System.Drawing.Size(1000, 560)
$form.StartPosition   = "CenterScreen"
$form.BackColor       = $bgDark
$form.ForeColor       = $fgWhite
$form.Font            = $font
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false

# ======================
# MENU LATERALE
# ======================

$menu           = New-Object System.Windows.Forms.Panel
$menu.Width     = 200
$menu.Dock      = "Left"
$menu.BackColor = $bgMenu
$form.Controls.Add($menu)

$menuTitle           = New-Object System.Windows.Forms.Label
$menuTitle.Text      = "WinForge"
$menuTitle.Font      = $fontBig
$menuTitle.ForeColor = $fgCyan
$menuTitle.Size      = New-Object System.Drawing.Size(180, 40)
$menuTitle.Location  = New-Object System.Drawing.Point(10, 15)
$menuTitle.TextAlign = "MiddleCenter"
$menu.Controls.Add($menuTitle)

# ======================
# TAB CONTROL (nascosto)
# ======================

$tabs            = New-Object System.Windows.Forms.TabControl
$tabs.Location   = New-Object System.Drawing.Point(200, 0)
$tabs.Size       = New-Object System.Drawing.Size(784, 534)
$tabs.Appearance = "FlatButtons"
$tabs.ItemSize   = New-Object System.Drawing.Size(0, 1)
$tabs.SizeMode   = "Fixed"
$tabs.BackColor  = $bgDark
$form.Controls.Add($tabs)

# ======================
# HELPER FUNCTIONS
# ======================

function MakeLabel($text, $x, $y, $w, $color) {
    $l           = New-Object System.Windows.Forms.Label
    $l.Text      = $text
    $l.Location  = New-Object System.Drawing.Point($x, $y)
    $l.Size      = New-Object System.Drawing.Size($w, 28)
    $l.ForeColor = $color
    $l.BackColor = $bgDark
    return $l
}

function MakeButton($text, $x, $y, $w, $h) {
    $b                            = New-Object System.Windows.Forms.Button
    $b.Text                       = $text
    $b.Location                   = New-Object System.Drawing.Point($x, $y)
    $b.Size                       = New-Object System.Drawing.Size($w, $h)
    $b.BackColor                  = $bgBtn
    $b.ForeColor                  = $fgCyan
    $b.FlatStyle                  = "Flat"
    $b.FlatAppearance.BorderColor = $fgCyan
    return $b
}

function MakeSeparator($x, $y, $w) {
    $sep           = New-Object System.Windows.Forms.Label
    $sep.Location  = New-Object System.Drawing.Point($x, $y)
    $sep.Size      = New-Object System.Drawing.Size($w, 2)
    $sep.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    return $sep
}

function AddInfoRow($parent, $label, $value, $y, $color) {
    $lbl = MakeLabel "$label : $value" 40 $y 400 $color
    $parent.Controls.Add($lbl)

    $btn = MakeButton ([char]0xE8C8) 450 ($y + 2) 34 22
    $btn.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 10)
    $btn.Tag = "$value"
    $btn.Add_Click({ Set-Clipboard -Value $this.Tag })
    $parent.Controls.Add($btn)
    return $lbl
}

# ======================
# TAB 1 - DISPOSITIVO
# ======================

$pageDevice           = New-Object System.Windows.Forms.TabPage
$pageDevice.BackColor = $bgDark
$tabs.TabPages.Add($pageDevice)

$pageDevice.Controls.Add((MakeLabel "INFORMAZIONI DISPOSITIVO" 40 30 400 $fgCyan))

$osWmi  = Get-CimInstance Win32_OperatingSystem
$cpuWmi = Get-CimInstance Win32_Processor | Select-Object -First 1
$diskWmi = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq "C:" }
$biosWmi = Get-CimInstance Win32_BIOS
$pcName  = $env:COMPUTERNAME

$osInfo    = $osWmi.Caption
$cpuInfo   = $cpuWmi.Name.Trim()
$ramGB     = [math]::Round($osWmi.TotalVisibleMemorySize / 1MB, 1)
$diskGB    = [math]::Round($diskWmi.Size / 1GB, 0)
$diskFreeGB = [math]::Round($diskWmi.FreeSpace / 1GB, 1)
$serialNum = $biosWmi.SerialNumber.Trim()

# IP Privato
$privateIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notmatch "^127\." -and $_.PrefixOrigin -ne "WellKnown"
} | Select-Object -First 1).IPAddress

if (-not $privateIP) { $privateIP = "Non rilevato" }

# IP Pubblico
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$publicIP = $null
foreach ($url in @("https://api.ipify.org", "https://ifconfig.me/ip", "https://checkip.amazonaws.com")) {
    if ($publicIP) { break }
    try {
        $wc  = New-Object System.Net.WebClient
        $raw = $wc.DownloadString($url).Trim()
        if ($raw -match "^\d{1,3}(\.\d{1,3}){3}$") { $publicIP = $raw }
    } catch {}
}
if (-not $publicIP) { $publicIP = "Non raggiungibile" }

# ---- Tabella Informazioni Dispositivo ----
$grid                               = New-Object System.Windows.Forms.DataGridView
$grid.Location                      = New-Object System.Drawing.Point(40, 65)
$grid.Size                          = New-Object System.Drawing.Size(640, 320)
$grid.BackgroundColor               = $bgDark
$grid.GridColor                     = [System.Drawing.Color]::FromArgb(60, 60, 60)
$grid.BorderStyle                   = "None"
$grid.RowHeadersVisible             = $false
$grid.AllowUserToAddRows            = $false
$grid.AllowUserToDeleteRows         = $false
$grid.AllowUserToResizeRows         = $false
$grid.AllowUserToResizeColumns      = $false
$grid.MultiSelect                   = $false
$grid.ReadOnly                      = $true
$grid.EnableHeadersVisualStyles     = $false
$grid.Font                          = $font
$grid.ColumnHeadersDefaultCellStyle.BackColor = $bgMenu
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $fgCyan
$grid.ColumnHeadersDefaultCellStyle.Font      = $fontBig
$grid.ColumnHeadersHeight           = 32
$grid.DefaultCellStyle.BackColor          = $bgDark
$grid.DefaultCellStyle.ForeColor          = $fgWhite
$grid.DefaultCellStyle.SelectionBackColor = $bgBtn
$grid.DefaultCellStyle.SelectionForeColor = $fgWhite
$grid.RowTemplate.Height            = 26

$colCampo               = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCampo.HeaderText    = "Campo"
$colCampo.Width         = 160
$colCampo.SortMode      = "NotSortable"
$grid.Columns.Add($colCampo) | Out-Null

$colValore              = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colValore.HeaderText   = "Valore"
$colValore.Width        = 400
$colValore.SortMode     = "NotSortable"
$grid.Columns.Add($colValore) | Out-Null

$colCopia                           = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colCopia.HeaderText                = ""
$colCopia.UseColumnTextForButtonValue = $false
$colCopia.Width                     = 60
$colCopia.FlatStyle                 = "Flat"
$colCopia.DefaultCellStyle.Font     = New-Object System.Drawing.Font("Segoe MDL2 Assets", 10)
$colCopia.DefaultCellStyle.BackColor = $bgBtn
$colCopia.DefaultCellStyle.ForeColor = $fgCyan
$colCopia.DefaultCellStyle.SelectionBackColor = $bgBtn
$colCopia.DefaultCellStyle.SelectionForeColor = $fgCyan
$grid.Columns.Add($colCopia) | Out-Null

$iconCopy  = [char]0xE8C8
$iconCheck = [char]0xE73E

$grid.Rows.Add("Produttore",  $manufacturer, $iconCopy) | Out-Null
$grid.Rows.Add("Modello",     $model,        $iconCopy) | Out-Null
$grid.Rows.Add("Vendor",      $vendor,       $iconCopy) | Out-Null
$grid.Rows.Add("Sistema OS",  $osInfo,       $iconCopy) | Out-Null
$grid.Rows.Add("CPU",         $cpuInfo,                              $iconCopy) | Out-Null
$grid.Rows.Add("RAM",         "$ramGB GB",                           $iconCopy) | Out-Null
$grid.Rows.Add("Disco",       "$diskGB GB ($diskFreeGB GB liberi)",  $iconCopy) | Out-Null
$grid.Rows.Add("S/N",         $serialNum,                            $iconCopy) | Out-Null
$grid.Rows.Add("Nome PC",     $pcName,       $iconCopy) | Out-Null
$grid.Rows.Add("IP Privato",  $privateIP,    $iconCopy) | Out-Null
$grid.Rows.Add("IP Pubblico", $publicIP,     $iconCopy) | Out-Null

$grid.Add_CellClick({
    param($sender, $e)
    if ($e.ColumnIndex -eq 2 -and $e.RowIndex -ge 0) {
        $val = $sender.Rows[$e.RowIndex].Cells[1].Value
        if ($val) {
            Set-Clipboard -Value "$val"
            $cell = $sender.Rows[$e.RowIndex].Cells[2]
            $cell.Value = [char]0xE73E
            $cell.Style.ForeColor = [System.Drawing.Color]::Lime

            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 1200
            $timer.Tag = $cell
            $timer.Add_Tick({
                $c = $this.Tag
                $c.Value = [char]0xE8C8
                $c.Style.ForeColor = [System.Drawing.Color]::Cyan
                $this.Stop()
                $this.Dispose()
            })
            $timer.Start()
        }
    }
})

$grid.ClearSelection()
$pageDevice.Controls.Add($grid)

# ---- Dominio / Workgroup ----
$btnDomain = MakeButton "Gestione dominio / workgroup" 40 400 280 34
$btnDomain.Add_Click({ Start-Process "sysdm.cpl" -ArgumentList ",1" })
$pageDevice.Controls.Add($btnDomain)

# ======================
# TAB 2 - AGGIORNAMENTI
# ======================

$pageUpdate           = New-Object System.Windows.Forms.TabPage
$pageUpdate.BackColor = $bgDark
$tabs.TabPages.Add($pageUpdate)

$pageUpdate.Controls.Add((MakeLabel "AGGIORNAMENTI SISTEMA E DRIVER" 40 15 500 $fgCyan))

# ---------- SEZIONE WINDOWS ----------

$pageUpdate.Controls.Add((MakeLabel "--- WINDOWS UPDATE ---" 40 52 400 $fgGold))

$lblOsStatus           = New-Object System.Windows.Forms.Label
$lblOsStatus.Location  = New-Object System.Drawing.Point(40, 82)
$lblOsStatus.Size      = New-Object System.Drawing.Size(680, 24)
$lblOsStatus.ForeColor = $fgWhite
$lblOsStatus.BackColor = $bgDark
$lblOsStatus.Text      = "Stato aggiornamenti Windows: non verificato"
$pageUpdate.Controls.Add($lblOsStatus)

$btnWU = MakeButton "Apri Windows Update" 40 112 220 36
$btnWU.Add_Click({ Start-Process "ms-settings:windowsupdate" })
$pageUpdate.Controls.Add($btnWU)

# ---------- SEPARATORE ----------

$pageUpdate.Controls.Add((MakeSeparator 40 162 680))

# ---------- SEZIONE DRIVER ----------

$pageUpdate.Controls.Add((MakeLabel "--- DRIVER ($vendor) ---" 40 175 400 $fgGold))

$lblDriverStatus           = New-Object System.Windows.Forms.Label
$lblDriverStatus.Location  = New-Object System.Drawing.Point(40, 205)
$lblDriverStatus.Size      = New-Object System.Drawing.Size(680, 24)
$lblDriverStatus.ForeColor = $fgWhite
$lblDriverStatus.BackColor = $bgDark
$lblDriverStatus.Text      = "Stato driver: non verificato"
$pageUpdate.Controls.Add($lblDriverStatus)

if ($vendor -eq "Dell") {
    # --- Bottone 1: .NET Desktop Runtime 8.0 ---
    $btnRuntime = MakeButton ".NET Desktop Runtime 8.0" 40 235 240 36
    $btnRuntime.Add_Click({
        WriteLog "Installazione Runtime avviata"
        $dotnet8Key  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        $dotnet8Key2 = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        $dotnet8Found = (Get-ChildItem $dotnet8Key, $dotnet8Key2 -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "Microsoft .NET Desktop Runtime 8\." }) -ne $null

        if ($dotnet8Found) {
            $lblDriverStatus.Text      = ".NET Desktop Runtime 8.0 gia presente."
            $lblDriverStatus.ForeColor = $fgLime
            $form.Refresh()
            WriteLog ".NET Desktop Runtime 8.0 gia presente, installazione saltata"
            return
        }

        if ([System.Environment]::Is64BitOperatingSystem) {
            $dotnetUrl = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.25/windowsdesktop-runtime-8.0.25-win-x64.exe"
        } else {
            $dotnetUrl = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.25/windowsdesktop-runtime-8.0.25-win-x86.exe"
        }
        $dotnetTmp = "$env:TEMP\dotnet8-desktop.exe"
        $lblDriverStatus.Text      = "Download .NET Desktop Runtime 8.0..."
        $lblDriverStatus.ForeColor = $fgGold
        $form.Refresh()
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object System.Net.WebClient).DownloadFile($dotnetUrl, $dotnetTmp)
            $lblDriverStatus.Text      = "Installazione .NET Desktop Runtime 8.0..."
            $lblDriverStatus.ForeColor = $fgGold
            $form.Refresh()
            Start-Process $dotnetTmp -ArgumentList "/quiet /norestart" -Wait
            $lblDriverStatus.Text      = ".NET Desktop Runtime 8.0 installato."
            $lblDriverStatus.ForeColor = $fgLime
            WriteLog "Installato .NET Desktop Runtime 8.0"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Errore durante il download di .NET Desktop Runtime 8.0:`n$_", "Errore", "OK", "Error")
            WriteLog "ERRORE: download Runtime fallito"
        } finally {
            Remove-Item $dotnetTmp -Force -ErrorAction SilentlyContinue
        }
    })
    $pageUpdate.Controls.Add($btnRuntime)

    # --- Bottone 2: Dell Command Update ---
    $btnDcu = MakeButton "Scarica Dell Command Update" 290 235 240 36
    $btnDcu.Add_Click({
        WriteLog "Apertura pagina Dell Command Update"
        $lblDriverStatus.Text      = "Apertura pagina download Dell Command Update..."
        $lblDriverStatus.ForeColor = $fgGold
        $form.Refresh()
        try {
            Start-Process "https://www.dell.com/support/home/it-it/drivers/driversdetails?driverid=FGK9X"
            [System.Windows.Forms.MessageBox]::Show(
                "Si e' aperta la pagina ufficiale Dell per scaricare Dell Command Update.`n`n" +
                "1. Clicca 'Scarica' sulla pagina`n" +
                "2. Esegui l'installer scaricato`n" +
                "3. Al termine, apri Dell Command Update dal Menu Start",
                "Download Dell Command Update",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            $lblDriverStatus.Text      = "Pagina Dell aperta nel browser."
            $lblDriverStatus.ForeColor = $fgLime
            WriteLog "Pagina download Dell Command Update aperta nel browser"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Errore apertura pagina Dell:`n$_", "Errore", "OK", "Error")
            WriteLog "ERRORE: apertura pagina Dell fallita"
        }
    })
    $pageUpdate.Controls.Add($btnDcu)

    # --- Bottone 3: Dell SupportAssist (download diretto Dell) ---
    $btnSA = MakeButton "Installa Dell SupportAssist" 40 285 490 36
    $btnSA.Add_Click({
        WriteLog "Download Dell SupportAssist avviato"
        $lblDriverStatus.Text      = "Download Dell SupportAssist..."
        $lblDriverStatus.ForeColor = $fgGold
        $form.Refresh()
        $saUrl = "https://downloads.dell.com/serviceability/Catalog/SupportAssistInstaller.exe"
        $saTmp = "$env:TEMP\SupportAssistInstaller.exe"
        try {
            & curl.exe -L -o $saTmp $saUrl 2>$null
            if (Test-Path $saTmp) {
                $header = [System.IO.File]::ReadAllBytes($saTmp)[0..1]
                if ($header[0] -eq 0x4D -and $header[1] -eq 0x5A) {
                    $lblDriverStatus.Text      = "Avvio installer Dell SupportAssist..."
                    $form.Refresh()
                    Start-Process $saTmp
                    $lblDriverStatus.Text      = "Dell SupportAssist: installer avviato."
                    $lblDriverStatus.ForeColor = $fgLime
                    WriteLog "Dell SupportAssist installer avviato"
                } else {
                    throw "File scaricato non valido"
                }
            } else {
                throw "Download fallito"
            }
        } catch {
            # Fallback: apri pagina Dell nel browser
            Start-Process "https://www.dell.com/support/contents/it-it/article/product-support/self-support-knowledgebase/software-and-downloads/supportassist"
            $lblDriverStatus.Text      = "Apertura pagina Dell SupportAssist nel browser."
            $lblDriverStatus.ForeColor = $fgGold
            WriteLog "Dell SupportAssist: fallback browser - $_"
        }
    })
    $pageUpdate.Controls.Add($btnSA)
} else {
    $btnDriversLabel = if ($vendor -eq "Generic") { "Nessun driver trovato" } else { "Aggiorna Driver ($vendor)" }
    $btnDrivers = MakeButton $btnDriversLabel 40 235 240 36
    $btnDrivers.Add_Click({
        WriteLog "Driver update avviato per $vendor"

        if ($vendor -eq "HP") {
        & $script:WingetExe install HP.SupportAssistant --source winget --silent --accept-package-agreements --accept-source-agreements
        $hpsa = "C:\Program Files (x86)\HP\HP Support Framework\HP Support Assistant.exe"
        if (Test-Path $hpsa) {
            Start-Process $hpsa
        }
    } elseif ($vendor -eq "Lenovo") {
        & $script:WingetExe install Lenovo.SystemUpdate --source winget --silent --accept-package-agreements --accept-source-agreements
        # Percorsi possibili di Lenovo System Update
        $lsu1 = "C:\Program Files (x86)\Lenovo\System Update\tvsu.exe"
        $lsu2 = "C:\Program Files\Lenovo\System Update\tvsu.exe"
        if (Test-Path $lsu1) {
            Start-Process $lsu1 -ArgumentList "/CM -search A -action INSTALL -includerebootpackages 3 -noicon" -Wait
        } elseif (Test-Path $lsu2) {
            Start-Process $lsu2 -ArgumentList "/CM -search A -action INSTALL -includerebootpackages 3 -noicon" -Wait
        }
    } else {
        $lblDriverStatus.Text      = "Nessun driver trovato."
        $lblDriverStatus.ForeColor = $fgGold
        $form.Refresh()
    }
})
    $pageUpdate.Controls.Add($btnDrivers)
}

# ======================
# TAB 3 - APPLICAZIONI
# ======================

$pageApps           = New-Object System.Windows.Forms.TabPage
$pageApps.BackColor = $bgDark
$tabs.TabPages.Add($pageApps)

$pageApps.Controls.Add((MakeLabel "INSTALLAZIONE APPLICAZIONI" 40 10 400 $fgCyan))

$apps = @(
    @{Name="Google Chrome";        Id="Google.Chrome";                 Default=$true},
    @{Name="Mozilla Firefox";      Id="Mozilla.Firefox";               Default=$true},
    @{Name="7-Zip";                Id="7zip.7zip";                     Default=$true},
    @{Name="VLC Media Player";     Id="VideoLAN.VLC";                  Default=$true},
    @{Name="Adobe Acrobat Reader"; Id="Adobe.Acrobat.Reader.64-bit";   Default=$true},
    @{Name="Notepad++";            Id="Notepad++.Notepad++";           Default=$true},
    @{Name="TeamViewer";           Id="TeamViewer.TeamViewer";         Default=$true},
    @{Name="Visual C++ Runtime";   Id="Microsoft.VCRedist.2015+.x64";  Default=$true},
    @{Name="OpenVPN";              Id="OpenVPNTechnologies.OpenVPN";   Default=$true},
    @{Name="Microsoft 365";        Id="Microsoft.Office";              Default=$true}
)

$checkboxes = @()
$y = 45

foreach ($app in $apps) {
    $cb           = New-Object System.Windows.Forms.CheckBox
    $cb.Text      = $app.Name
    $cb.Tag       = $app.Id
    $cb.Checked   = $app.Default
    $cb.ForeColor = $fgLime
    $cb.BackColor = $bgDark
    $cb.Location  = New-Object System.Drawing.Point(40, $y)
    $cb.Size      = New-Object System.Drawing.Size(280, 24)
    $pageApps.Controls.Add($cb)
    $checkboxes += $cb
    $y += 26
}

$appInstallPaths = @{
    "Google.Chrome"                = @("C:\Program Files\Google\Chrome\Application\chrome.exe", "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe")
    "Mozilla.Firefox"              = @("C:\Program Files\Mozilla Firefox\firefox.exe", "C:\Program Files (x86)\Mozilla Firefox\firefox.exe")
    "7zip.7zip"                    = @("C:\Program Files\7-Zip\7zFM.exe", "C:\Program Files (x86)\7-Zip\7zFM.exe")
    "VideoLAN.VLC"                 = @("C:\Program Files\VideoLAN\VLC\vlc.exe", "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe")
    "Adobe.Acrobat.Reader.64-bit"  = @("C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe", "C:\Program Files (x86)\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe")
    "Notepad++.Notepad++"          = @("C:\Program Files\Notepad++\notepad++.exe", "C:\Program Files (x86)\Notepad++\notepad++.exe")
    "TeamViewer.TeamViewer"        = @("C:\Program Files\TeamViewer\TeamViewer.exe", "C:\Program Files (x86)\TeamViewer\TeamViewer.exe")
    "Microsoft.VCRedist.2015+.x64" = @()
    "OpenVPNTechnologies.OpenVPN"  = @("C:\Program Files\OpenVPN\bin\openvpn-gui.exe", "C:\Program Files (x86)\OpenVPN\bin\openvpn-gui.exe")
    "Microsoft.Office"             = @("C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE", "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE")
}

$btnCheck = MakeButton "Verifica installate" 360 45 220 40
$btnCheck.Add_Click({
    $lblStatus.Text      = "Controllo in corso..."
    $lblStatus.ForeColor = $fgGold
    $form.Refresh()

    # Esegue winget list scrivendo su file, polling con DoEvents per non bloccare la UI
    $listFile = "$env:TEMP\winget_list.log"
    $procL = Start-Process $script:WingetExe -ArgumentList "list --source winget --accept-source-agreements" `
        -NoNewWindow -PassThru -RedirectStandardOutput $listFile -RedirectStandardError "$listFile.err"
    while (-not $procL.HasExited) {
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()
    }
    $installed = if (Test-Path $listFile) { Get-Content $listFile -Raw } else { "" }
    Remove-Item $listFile, "$listFile.err" -Force -ErrorAction SilentlyContinue

    foreach ($cb in $checkboxes) {
        # Evita di ri-processare checkbox gia marcati
        if ($cb.Text -match "\[gia installata\]") { continue }

        $found = $false
        if ($installed -match [regex]::Escape($cb.Tag)) { $found = $true }
        if (-not $found -and $appInstallPaths.ContainsKey($cb.Tag)) {
            foreach ($p in $appInstallPaths[$cb.Tag]) {
                if (Test-Path $p) { $found = $true; break }
            }
        }
        if ($found) {
            $cb.Checked   = $false
            $cb.Enabled   = $false
            $cb.Text      = $cb.Text + " [gia installata]"
            $cb.ForeColor = [System.Drawing.Color]::Gray
        }
    }

    $lblStatus.Text      = "Verifica completata."
    $lblStatus.ForeColor = $fgCyan
})
$pageApps.Controls.Add($btnCheck)

$btnDeselect = MakeButton "Deseleziona tutto" 360 155 220 40
$btnDeselect.Add_Click({
    foreach ($cb in $checkboxes) {
        if ($cb.Enabled) { $cb.Checked = $false }
    }
    $lblStatus.Text      = "Selezione azzerata."
    $lblStatus.ForeColor = $fgCyan
})
$pageApps.Controls.Add($btnDeselect)

$btnInstall = MakeButton "Installa selezionate" 360 100 220 40
$btnInstall.Add_Click({
    $selected = $checkboxes | Where-Object { $_.Checked }

    if ($selected.Count -eq 0) {
        $lblStatus.Text      = "Nessuna applicazione selezionata."
        $lblStatus.ForeColor = $fgRed
        return
    }

    $exePaths = @{
        "Google.Chrome"                = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        "Mozilla.Firefox"              = $null
        "7zip.7zip"                    = "C:\Program Files\7-Zip\7zFM.exe"
        "VideoLAN.VLC"                 = "C:\Program Files\VideoLAN\VLC\vlc.exe"
        "Adobe.Acrobat.Reader.64-bit"  = $null
        "Notepad++.Notepad++"          = "C:\Program Files\Notepad++\notepad++.exe"
        "TeamViewer.TeamViewer"        = "C:\Program Files\TeamViewer\TeamViewer.exe"
        "Microsoft.VCRedist.2015+.x64" = $null
    }

    $desktopPath = [Environment]::GetFolderPath("CommonDesktopDirectory")
    $shell       = New-Object -ComObject WScript.Shell

    $progress.Maximum = $selected.Count
    $progress.Value   = 0

    foreach ($cb in $selected) {
        $lblStatus.Text      = "Installazione: $($cb.Text)"
        $lblStatus.ForeColor = $fgGold
        $form.Refresh()
        WriteLog "Installazione: $($cb.Tag)"

        if ($cb.Tag -eq "TeamViewer.TeamViewer") {
            $tvTmp = "$env:TEMP\TeamViewer_Setup.exe"
            $lblStatus.Text = "Download TeamViewer..."
            $form.Refresh()
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                (New-Object System.Net.WebClient).DownloadFile("https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe", $tvTmp)
                $lblStatus.Text = "Installazione TeamViewer..."
                $form.Refresh()
                Start-Process $tvTmp -ArgumentList "/S" -Wait
                WriteLog "TeamViewer installato"
            } catch {
                Start-Process "https://www.teamviewer.com/it/download/windows/"
                WriteLog "TeamViewer: fallback browser - $_"
            } finally {
                Remove-Item $tvTmp -Force -ErrorAction SilentlyContinue
            }
        }
        elseif ($cb.Tag -eq "Microsoft.Office") {
            $officeTmp = "$env:TEMP\Microsoft365Setup.exe"
            $lblStatus.Text = "Download Microsoft 365..."
            $form.Refresh()
            try {
                & curl.exe -L -o $officeTmp "https://go.microsoft.com/fwlink/?linkid=2264705&clcid=0x409&culture=en-us&country=us" 2>$null
                if (Test-Path $officeTmp) {
                    $header = [System.IO.File]::ReadAllBytes($officeTmp)[0..1]
                    if ($header[0] -eq 0x4D -and $header[1] -eq 0x5A) {
                        $lblStatus.Text = "Avvio installer Microsoft 365..."
                        $form.Refresh()
                        Start-Process $officeTmp
                        WriteLog "Microsoft 365: installer avviato"
                    } else {
                        throw "File non valido"
                    }
                }
            } catch {
                Start-Process "https://go.microsoft.com/fwlink/?linkid=2264705&clcid=0x409&culture=en-us&country=us"
                WriteLog "Microsoft 365: fallback browser - $_"
            }
        } else {
            # Installa con Start-Process + polling DoEvents (UI reattiva, niente Start-Job)
            $attempts = 0
            $exitCode = 0
            do {
                $attempts++
                $proc = Start-Process $script:WingetExe `
                    -ArgumentList "install --id $($cb.Tag) --source winget --silent --accept-package-agreements --accept-source-agreements" `
                    -NoNewWindow -PassThru

                while (-not $proc.HasExited) {
                    Start-Sleep -Milliseconds 200
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $exitCode = $proc.ExitCode
                WriteLog "winget $($cb.Tag) exit=$exitCode"

                if ($exitCode -eq 1618 -and $attempts -lt 3) {
                    $lblStatus.Text = "Installer occupato, attesa 20s e riprovo ($($cb.Text))..."
                    $form.Refresh()
                    WriteLog "Exit 1618 su $($cb.Tag), retry $attempts"
                    Start-Sleep -Seconds 20
                } else {
                    break
                }
            } while ($attempts -lt 3)
        }

        $exePath = $exePaths[$cb.Tag]
        if ($exePath -and (Test-Path $exePath)) {
            $shortcutPath        = Join-Path $desktopPath "$($cb.Text).lnk"
            $shortcut            = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $exePath
            $shortcut.Save()
            WriteLog "Collegamento creato: $($cb.Text)"
        }

        $progress.Value++
    }

    $lblStatus.Text      = "Installazione completata."
    $lblStatus.ForeColor = $fgLime
    WriteLog "Tutte le installazioni completate."
})
$pageApps.Controls.Add($btnInstall)

$progress          = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(40, 410)
$progress.Size     = New-Object System.Drawing.Size(540, 22)
$progress.Style    = "Continuous"
$pageApps.Controls.Add($progress)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point(40, 440)
$lblStatus.Size      = New-Object System.Drawing.Size(650, 28)
$lblStatus.ForeColor = $fgCyan
$lblStatus.BackColor = $bgDark
$lblStatus.Text      = "Pronto."
$pageApps.Controls.Add($lblStatus)

# ======================
# TAB 4 - APP PIU COMUNI
# ======================

$pageCommon           = New-Object System.Windows.Forms.TabPage
$pageCommon.BackColor = $bgDark
$tabs.TabPages.Add($pageCommon)

$pageCommon.Controls.Add((MakeLabel "APP PIU' COMUNI" 40 10 400 $fgCyan))

$commonApps = @(
    @{Name="Malwarebytes";        Id="Malwarebytes.Malwarebytes";  Source="winget"},
    @{Name="Mozilla Thunderbird"; Id="Mozilla.Thunderbird";        Source="winget"},
    @{Name="GIMP";                Id="GIMP.GIMP";                  Source="winget"},
    @{Name="App Dispositivi Apple"; Id="Apple.AppleDevicesApp";    Source="winget"},
    @{Name="Transwiz (Windows)";   Id="TRANSWIZ_WIN";             Source="direct"},
    @{Name="Transwiz (XP)";        Id="TRANSWIZ_XP";              Source="direct"},
    @{Name="Dike GoSign";          Id="DIKE_GOSIGN";              Source="direct"}
)

$commonCheckboxes = @()
$yc = 45

foreach ($app in $commonApps) {
    $cb           = New-Object System.Windows.Forms.CheckBox
    $cb.Text      = $app.Name
    $cb.Tag       = $app.Id
    $cb.Checked   = $false
    $cb.ForeColor = $fgLime
    $cb.BackColor = $bgDark
    $cb.Location  = New-Object System.Drawing.Point(40, $yc)
    $cb.Size      = New-Object System.Drawing.Size(280, 24)
    $cb.AccessibleDescription = $app.Source
    $pageCommon.Controls.Add($cb)
    $commonCheckboxes += $cb
    $yc += 26
}

$commonInstallPaths = @{
    # Aggiungi qui i path di verifica:
    # "winget.id" = @("C:\percorso\app.exe")
}

$btnCommonCheck = MakeButton "Verifica installate" 360 45 220 40
$btnCommonCheck.Add_Click({
    $lblCommonStatus.Text      = "Controllo in corso..."
    $lblCommonStatus.ForeColor = $fgGold
    $form.Refresh()

    $listFileC = "$env:TEMP\winget_list_common.log"
    $procLC = Start-Process $script:WingetExe -ArgumentList "list --source winget --accept-source-agreements" `
        -NoNewWindow -PassThru -RedirectStandardOutput $listFileC -RedirectStandardError "$listFileC.err"
    while (-not $procLC.HasExited) {
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.Application]::DoEvents()
    }
    $installedC = if (Test-Path $listFileC) { Get-Content $listFileC -Raw } else { "" }
    Remove-Item $listFileC, "$listFileC.err" -Force -ErrorAction SilentlyContinue

    foreach ($cb in $commonCheckboxes) {
        if ($cb.Text -match "\[gia installata\]") { continue }

        $found = $false
        if ($installedC -match [regex]::Escape($cb.Tag)) { $found = $true }
        if (-not $found -and $commonInstallPaths.ContainsKey($cb.Tag)) {
            foreach ($p in $commonInstallPaths[$cb.Tag]) {
                if (Test-Path $p) { $found = $true; break }
            }
        }
        if ($found) {
            $cb.Checked   = $false
            $cb.Enabled   = $false
            $cb.Text      = $cb.Text + " [gia installata]"
            $cb.ForeColor = [System.Drawing.Color]::Gray
        }
    }

    $lblCommonStatus.Text      = "Verifica completata."
    $lblCommonStatus.ForeColor = $fgCyan
})
$pageCommon.Controls.Add($btnCommonCheck)

$btnCommonDeselect = MakeButton "Deseleziona tutto" 360 155 220 40
$btnCommonDeselect.Add_Click({
    foreach ($cb in $commonCheckboxes) {
        if ($cb.Enabled) { $cb.Checked = $false }
    }
    $lblCommonStatus.Text      = "Selezione azzerata."
    $lblCommonStatus.ForeColor = $fgCyan
})
$pageCommon.Controls.Add($btnCommonDeselect)

$btnCommonInstall = MakeButton "Installa selezionate" 360 100 220 40
$btnCommonInstall.Add_Click({
    $selected = $commonCheckboxes | Where-Object { $_.Checked }

    if ($selected.Count -eq 0) {
        $lblCommonStatus.Text      = "Nessuna applicazione selezionata."
        $lblCommonStatus.ForeColor = $fgRed
        return
    }

    $commonProgress.Maximum = $selected.Count
    $commonProgress.Value   = 0

    foreach ($cb in $selected) {
        $lblCommonStatus.Text      = "Installazione: $($cb.Text)"
        $lblCommonStatus.ForeColor = $fgGold
        $form.Refresh()
        WriteLog "Installazione comune: $($cb.Tag)"

        # --- Download diretti: apri nel browser e prosegui ---
        if ($cb.Tag -eq "TRANSWIZ_WIN") {
            $lblCommonStatus.Text = "Transwiz (Windows): download dal browser"
            $form.Refresh()
            Start-Process "https://www.forensit.com/Downloads/Transwiz.msi"
            WriteLog "Transwiz Windows: aperta pagina download"
            $commonProgress.Value++
            continue
        }
        if ($cb.Tag -eq "TRANSWIZ_XP") {
            $lblCommonStatus.Text = "Transwiz (XP): download dal browser"
            $form.Refresh()
            Start-Process "https://www.forensit.com/Downloads/Transwiz_XP.zip"
            WriteLog "Transwiz XP: aperta pagina download"
            $commonProgress.Value++
            continue
        }
        if ($cb.Tag -eq "DIKE_GOSIGN") {
            $lblCommonStatus.Text = "Dike GoSign: download dal browser"
            $form.Refresh()
            Start-Process "https://rinnovofirma.infocert.it/gosign/download/win32/latest/"
            WriteLog "Dike GoSign: aperta pagina download"
            $commonProgress.Value++
            continue
        }

        $srcArg = if ($cb.AccessibleDescription -eq "msstore") { "--source msstore" } else { "--source winget" }

        $attempts = 0
        $exitCode = 0
        do {
            $attempts++
            $proc = Start-Process $script:WingetExe `
                -ArgumentList "install --id $($cb.Tag) $srcArg --silent --accept-package-agreements --accept-source-agreements" `
                -NoNewWindow -PassThru

            while (-not $proc.HasExited) {
                Start-Sleep -Milliseconds 200
                [System.Windows.Forms.Application]::DoEvents()
            }
            $exitCode = $proc.ExitCode
            WriteLog "winget $($cb.Tag) exit=$exitCode"

            if ($exitCode -eq 1618 -and $attempts -lt 3) {
                $lblCommonStatus.Text = "Installer occupato, attesa 20s e riprovo ($($cb.Text))..."
                $form.Refresh()
                WriteLog "Exit 1618 su $($cb.Tag), retry $attempts"
                Start-Sleep -Seconds 20
            } else {
                break
            }
        } while ($attempts -lt 3)

        $commonProgress.Value++
    }

    $lblCommonStatus.Text      = "Installazione completata."
    $lblCommonStatus.ForeColor = $fgLime
    WriteLog "Installazioni comuni completate."
})
$pageCommon.Controls.Add($btnCommonInstall)

$commonProgress          = New-Object System.Windows.Forms.ProgressBar
$commonProgress.Location = New-Object System.Drawing.Point(40, 410)
$commonProgress.Size     = New-Object System.Drawing.Size(540, 22)
$commonProgress.Style    = "Continuous"
$pageCommon.Controls.Add($commonProgress)

$lblCommonStatus           = New-Object System.Windows.Forms.Label
$lblCommonStatus.Location  = New-Object System.Drawing.Point(40, 440)
$lblCommonStatus.Size      = New-Object System.Drawing.Size(650, 28)
$lblCommonStatus.ForeColor = $fgCyan
$lblCommonStatus.BackColor = $bgDark
$lblCommonStatus.Text      = "Pronto."
$pageCommon.Controls.Add($lblCommonStatus)

# ======================
# MENU BOTTONI LATERALI
# ======================

$menuItems = @(
    @{Label="Dispositivo";   Index=0; Y=70},
    @{Label="Aggiornamenti"; Index=1; Y=125},
    @{Label="Applicazioni";  Index=2; Y=180},
    @{Label="App Comuni";    Index=3; Y=235}
)

foreach ($item in $menuItems) {
    $btn                            = New-Object System.Windows.Forms.Button
    $btn.Text                       = $item.Label
    $btn.Size                       = New-Object System.Drawing.Size(180, 42)
    $btn.Location                   = New-Object System.Drawing.Point(10, $item.Y)
    $btn.BackColor                  = $bgBtn
    $btn.ForeColor                  = $fgCyan
    $btn.FlatStyle                  = "Flat"
    $btn.FlatAppearance.BorderColor = $fgCyan
    $btn.Tag                        = $item.Index

    $btn.Add_Click({
        $tabs.SelectedIndex = $this.Tag
    })

    $menu.Controls.Add($btn)
}

# ======================
# AVVIO
# ======================

$tabs.SelectedIndex = 0
$form.TopMost = $false
[void]$form.ShowDialog()

# --- Pulizia automatica: cancella C:\WinForge\ dopo la chiusura ---
# Usa un processo cmd separato con delay per aspettare che PowerShell sia uscito
Start-Process "cmd" -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"C:\WinForge`" & del /f /q `"%USERPROFILE%\Desktop\WinForge_install_log.txt`"" -WindowStyle Hidden
