<#
    Convert-PalworldSave.ps1
    Moves a Palworld dedicated-server world onto this PC as a local co-op save.

    Turn-key behaviour:
      - Finds your server download by itself (zip or folder) in the usual places
      - Picks your Steam save slot by itself when there is only one
      - Watches your Downloads folder and picks up the converted zip automatically
      - Backs up anything it would replace, then offers to launch the game

    The conversion itself runs in your browser (the converters are WebAssembly,
    because current saves use Oodle/PlM compression). Everything else is here.

    Run via "Run Palworld Save Converter.cmd", or:
        powershell -ExecutionPolicy Bypass -File .\Convert-PalworldSave.ps1
#>

[CmdletBinding()]
param([switch]$Relaunched)

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $Relaunched) {
    $self = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($self)) { $self = $MyInvocation.MyCommand.Definition }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"", '-Relaunched'
    ) | Out-Null
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()

$CONVERTER_URL = 'https://hub.tcno.co/games/palworld/converter/'
$STEAM_LAUNCH  = 'steam://rungameid/1623730'

$script:SourceWorld  = $null
$script:SlotPath     = $null
$script:ZipPath      = $null
$script:ImportedPath = $null
$script:BackupNote   = ''
$script:Step         = 0
$script:Candidates   = @()
$script:Slots        = @()
$script:WatchSince   = [datetime]::Now

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------
function Get-DownloadDirs {
    $dirs = @()
    foreach ($d in @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'OneDrive\Downloads'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop')
    )) {
        if ($d -and (Test-Path -LiteralPath $d)) { $dirs += $d }
    }
    return ($dirs | Select-Object -Unique)
}

function Test-ZipHasWorld {
    param([string]$Path)
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $hit = $false
        foreach ($e in $zip.Entries) {
            if ($e.FullName -match '(^|/)Level\.sav$') { $hit = $true; break }
        }
        $zip.Dispose()
        return $hit
    } catch {
        return $false
    }
}

function Find-WorldFolders {
    param([string]$Root)
    $results = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $results }
    $levels = Get-ChildItem -LiteralPath $Root -Filter 'Level.sav' -Recurse -File -Depth 8 -ErrorAction SilentlyContinue
    foreach ($lv in $levels) {
        $dir = $lv.Directory
        $playersDir = Join-Path $dir.FullName 'Players'
        $playerCount = 0
        if (Test-Path -LiteralPath $playersDir) {
            $playerCount = @(Get-ChildItem -LiteralPath $playersDir -Filter '*.sav' -File -ErrorAction SilentlyContinue).Count
        }
        $results += [pscustomobject]@{
            Path        = $dir.FullName
            Name        = $dir.Name
            PlayerCount = $playerCount
            HasPlayers  = (Test-Path -LiteralPath $playersDir)
        }
    }
    return $results
}

function Get-SaveSlots {
    $base = Join-Path $env:LOCALAPPDATA 'Pal\Saved\SaveGames'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Path    = $_.FullName
            Name    = $_.Name
            IsSteam = ($_.Name -match '^\d{17}$')
            Worlds  = @(Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue).Count
        }
    }
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Recurse -Force | ForEach-Object {
        $rel = $_.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $rel
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        } else {
            $parent = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 22, [switch]$Bold, [double]$Size = 10)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    return $l
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 110, [int]$H = 30)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    return $b
}

function Set-Status {
    param([System.Windows.Forms.Label]$Label, [string]$Text, [string]$Kind = 'info')
    $Label.Text = $Text
    switch ($Kind) {
        'ok'    { $Label.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 60) }
        'warn'  { $Label.ForeColor = [System.Drawing.Color]::FromArgb(170, 90, 0) }
        'error' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(180, 30, 30) }
        default { $Label.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70) }
    }
}

# ---------------------------------------------------------------------------
# Form shell
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Palworld Save Converter'
$form.Size = New-Object System.Drawing.Size(720, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

$header = New-Object System.Windows.Forms.Panel
$header.Size = New-Object System.Drawing.Size(720, 58)
$header.BackColor = [System.Drawing.Color]::FromArgb(32, 46, 66)
$form.Controls.Add($header)

$titleLabel = New-Label -Text '' -X 22 -Y 10 -W 660 -H 26 -Bold -Size 14
$titleLabel.ForeColor = [System.Drawing.Color]::White
$header.Controls.Add($titleLabel)

$stepLabel = New-Label -Text '' -X 22 -Y 36 -W 660 -H 16 -Size 8
$stepLabel.ForeColor = [System.Drawing.Color]::FromArgb(165, 185, 210)
$header.Controls.Add($stepLabel)

$body = New-Object System.Windows.Forms.Panel
$body.Size = New-Object System.Drawing.Size(704, 400)
$body.Location = New-Object System.Drawing.Point(0, 64)
$form.Controls.Add($body)

$footer = New-Object System.Windows.Forms.Panel
$footer.Size = New-Object System.Drawing.Size(720, 56)
$footer.Location = New-Object System.Drawing.Point(0, 465)
$footer.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)
$form.Controls.Add($footer)

$btnBack   = New-Button -Text 'Back'  -X 400 -Y 12 -W 110
$btnNext   = New-Button -Text 'Next'  -X 520 -Y 12 -W 150
$btnCancel = New-Button -Text 'Close' -X 20  -Y 12 -W 90
$btnNext.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$footer.Controls.AddRange(@($btnBack, $btnNext, $btnCancel))
$btnCancel.Add_Click({ $form.Close() })

# ---------------------------------------------------------------------------
# Pane 0 - Start
# ---------------------------------------------------------------------------
$p0 = New-Object System.Windows.Forms.Panel
$p0.Size = $body.Size

$p0.Controls.Add((New-Label -Text 'Moves your world off a rented server onto this PC.' -X 28 -Y 46 -W 650 -H 32 -Bold -Size 13))
$p0.Controls.Add((New-Label -Text @'
Your character, pals, guild and bases come with it.

Takes about 10 minutes. Nothing of yours gets deleted.
'@ -X 28 -Y 90 -W 650 -H 70 -Size 11))
$p0.Controls.Add((New-Label -Text 'You need your server host login, and Palworld launched at least once on this PC.' -X 28 -Y 190 -W 650 -H 30 -Size 10))
$body.Controls.Add($p0)

# ---------------------------------------------------------------------------
# Pane 1 - Get it off the server
# ---------------------------------------------------------------------------
$p1 = New-Object System.Windows.Forms.Panel
$p1.Size = $body.Size
$p1.Visible = $false

$p1.Controls.Add((New-Label -Text 'On your server host''s website:' -X 28 -Y 22 -W 650 -H 26 -Bold -Size 11))
$p1.Controls.Add((New-Label -Text @'
1.   Stop the server. Wait until it shows offline.

2.   Open File Manager, go to:   Pal\Saved\SaveGames

3.   Download that folder. Use "zip" or "compress" if offered.
'@ -X 28 -Y 60 -W 650 -H 130 -Size 11))
$p1.Controls.Add((New-Label -Text 'Save it to your Downloads folder and I will find it on the next screen.' -X 28 -Y 206 -W 650 -H 26 -Size 10))
$p1.Controls.Add((New-Label -Text 'Cancel your hosting only after the download is safely on this PC.' -X 28 -Y 236 -W 650 -H 26 -Size 10))
$body.Controls.Add($p1)

# ---------------------------------------------------------------------------
# Pane 2 - Your save (auto-detected)
# ---------------------------------------------------------------------------
$p2 = New-Object System.Windows.Forms.Panel
$p2.Size = $body.Size
$p2.Visible = $false

$lblFoundHdr = New-Label -Text 'Looking for your download...' -X 28 -Y 20 -W 650 -H 26 -Bold -Size 11
$p2.Controls.Add($lblFoundHdr)

$lstCand = New-Object System.Windows.Forms.ListBox
$lstCand.Location = New-Object System.Drawing.Point(28, 54)
$lstCand.Size = New-Object System.Drawing.Size(645, 120)
$lstCand.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$p2.Controls.Add($lstCand)

$btnUseSel  = New-Button -Text 'Use this one' -X 28  -Y 184 -W 150 -H 32
$btnRescan  = New-Button -Text 'Look again'   -X 188 -Y 184 -W 120 -H 32
$btnPickZip = New-Button -Text 'Find it myself...' -X 318 -Y 184 -W 160 -H 32
$p2.Controls.AddRange(@($btnUseSel, $btnRescan, $btnPickZip))

$lblSourceStatus = New-Label -Text '' -X 28 -Y 228 -W 645 -H 60 -Size 10
$p2.Controls.Add($lblSourceStatus)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(28, 296)
$txtSource.Size = New-Object System.Drawing.Size(645, 24)
$txtSource.ReadOnly = $true
$txtSource.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$txtSource.AllowDrop = $true
$p2.Controls.Add($txtSource)

$p2.Controls.Add((New-Label -Text 'or drag your zip or folder onto the box above' -X 28 -Y 322 -W 645 -H 20 -Size 9))
$body.Controls.Add($p2)

function Set-SourceFromWorldFolder {
    param([string]$SearchRoot)
    $worlds = @(Find-WorldFolders -Root $SearchRoot)
    if ($worlds.Count -eq 0) {
        Set-Status $lblSourceStatus 'No Palworld world in there - no Level.sav found.' 'error'
        $script:SourceWorld = $null
        return $false
    }
    $w = $worlds | Sort-Object PlayerCount -Descending | Select-Object -First 1
    $script:SourceWorld = $w.Path
    if ($w.HasPlayers) {
        Set-Status $lblSourceStatus ('Ready - found your world with {0} character file(s).' -f $w.PlayerCount) 'ok'
    } else {
        Set-Status $lblSourceStatus 'Found a world, but it has no Players folder. The converter needs that.' 'warn'
    }
    return $true
}

function Use-SourceZip {
    param([string]$ZipFile)
    $base = Join-Path (Split-Path $ZipFile -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($ZipFile) + '_unzipped')
    $dest = $base
    if (Test-Path -LiteralPath $dest) { $dest = $base + '-' + (Get-Date -Format 'HHmmss') }
    try {
        Set-Status $lblSourceStatus 'Unzipping - this can take a minute on a big world...' 'info'
        $form.Refresh()
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $dest)
    } catch {
        Set-Status $lblSourceStatus ('Could not unzip that: {0}' -f $_.Exception.Message) 'error'
        return
    }
    [void](Set-SourceFromWorldFolder -SearchRoot $dest)
}

function Use-SourcePath {
    param([string]$Path)
    $txtSource.Text = $Path
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and ($Path -match '\.zip$')) {
        Use-SourceZip -ZipFile $Path
    } elseif (Test-Path -LiteralPath $Path -PathType Container) {
        Set-Status $lblSourceStatus 'Looking...' 'info'
        $form.Refresh()
        [void](Set-SourceFromWorldFolder -SearchRoot $Path)
    } else {
        Set-Status $lblSourceStatus 'That is not a zip or a folder.' 'error'
    }
}

$scanSources = {
    $lstCand.Items.Clear()
    $script:Candidates = @()
    $lblFoundHdr.Text = 'Looking for your download...'
    Set-Status $lblSourceStatus '' 'info'
    $form.Refresh()

    foreach ($dir in (Get-DownloadDirs)) {
        foreach ($z in (Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 25)) {
            if (Test-ZipHasWorld -Path $z.FullName) {
                $script:Candidates += [pscustomobject]@{
                    Path    = $z.FullName
                    Display = ('{0}   ({1:N0} MB, {2:d})' -f $z.Name, ($z.Length / 1MB), $z.LastWriteTime)
                }
            }
        }
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15)) {
            $hit = Get-ChildItem -LiteralPath $d.FullName -Filter 'Level.sav' -Recurse -File -Depth 5 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                $script:Candidates += [pscustomobject]@{
                    Path    = $d.FullName
                    Display = ('{0}   (folder, {1:d})' -f $d.Name, $d.LastWriteTime)
                }
            }
        }
    }

    if ($script:Candidates.Count -eq 0) {
        $lblFoundHdr.Text = 'I could not find it automatically.'
        Set-Status $lblSourceStatus 'Click "Find it myself" and point me at the zip or folder you downloaded, or drag it onto the box below.' 'warn'
        return
    }

    foreach ($c in $script:Candidates) { $lstCand.Items.Add($c.Display) | Out-Null }
    $lstCand.SelectedIndex = 0
    if ($script:Candidates.Count -eq 1) {
        $lblFoundHdr.Text = 'Found this - is it the right one?'
    } else {
        $lblFoundHdr.Text = ('Found {0}. Pick the one from your server:' -f $script:Candidates.Count)
    }
    Set-Status $lblSourceStatus 'Select it, then click "Use this one".' 'info'
}

$btnRescan.Add_Click($scanSources)

$btnUseSel.Add_Click({
    if ($lstCand.SelectedIndex -lt 0) {
        Set-Status $lblSourceStatus 'Pick one from the list first.' 'warn'
        return
    }
    Use-SourcePath -Path $script:Candidates[$lstCand.SelectedIndex].Path
})

$lstCand.Add_DoubleClick({
    if ($lstCand.SelectedIndex -ge 0) { Use-SourcePath -Path $script:Candidates[$lstCand.SelectedIndex].Path }
})

$btnPickZip.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Save download (*.zip)|*.zip|All files (*.*)|*.*'
    $dlg.Title = 'Find the zip you downloaded from your server'
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path -LiteralPath $dl) { $dlg.InitialDirectory = $dl }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Use-SourcePath -Path $dlg.FileName
    } else {
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Or select the folder you downloaded'
        $fb.ShowNewFolderButton = $false
        if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Use-SourcePath -Path $fb.SelectedPath }
    }
})

$txtSource.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$txtSource.Add_DragDrop({
    param($sender, $e)
    $paths = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    if ($paths.Count -gt 0) { Use-SourcePath -Path $paths[0] }
})

# ---------------------------------------------------------------------------
# Pane 3 - Convert in the browser
# ---------------------------------------------------------------------------
$p3 = New-Object System.Windows.Forms.Panel
$p3.Size = $body.Size
$p3.Visible = $false

$warnBox = New-Object System.Windows.Forms.Panel
$warnBox.Location = New-Object System.Drawing.Point(28, 16)
$warnBox.Size = New-Object System.Drawing.Size(645, 74)
$warnBox.BackColor = [System.Drawing.Color]::FromArgb(255, 246, 219)
$p3.Controls.Add($warnBox)

$warnBox.Controls.Add((New-Label -Text 'The one thing everybody gets wrong:' -X 12 -Y 8 -W 620 -H 22 -Bold -Size 10.5))
$warnBox.Controls.Add((New-Label -Text 'On the page, click "Dedicated to Co-op" in the TOP RIGHT of the Save converter box, before anything else.' -X 12 -Y 32 -W 620 -H 36 -Size 10))

$btnConv      = New-Button -Text 'Open the converter' -X 28  -Y 100 -W 190 -H 34
$btnCopyPath  = New-Button -Text 'Copy folder path'   -X 228 -Y 100 -W 165 -H 34
$btnShowSrc   = New-Button -Text 'Show me the folder' -X 403 -Y 100 -W 175 -H 34
$p3.Controls.AddRange(@($btnConv, $btnCopyPath, $btnShowSrc))

$txtConvertPath = New-Object System.Windows.Forms.TextBox
$txtConvertPath.Location = New-Object System.Drawing.Point(28, 142)
$txtConvertPath.Size = New-Object System.Drawing.Size(645, 24)
$txtConvertPath.ReadOnly = $true
$txtConvertPath.Font = New-Object System.Drawing.Font('Consolas', 9)
$p3.Controls.Add($txtConvertPath)

$p3.Controls.Add((New-Label -Text @'
Then:   Choose folder  ->  the folder above
           Pick your character
           Tick the backup box, click Convert, save the zip
'@ -X 28 -Y 178 -W 645 -H 86 -Size 10.5))

$lblWatch = New-Label -Text '' -X 28 -Y 278 -W 645 -H 60 -Size 10.5 -Bold
$p3.Controls.Add($lblWatch)

$btnFindZipManual = New-Button -Text 'I saved it somewhere else...' -X 28 -Y 344 -W 230 -H 30
$p3.Controls.Add($btnFindZipManual)

$body.Controls.Add($p3)

$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 2000

function Set-ConvertedZip {
    param([string]$Path)
    $script:ZipPath = $Path
    $watchTimer.Stop()
    Set-Status $lblWatch ("Got it: {0}`r`nClick Next." -f (Split-Path $Path -Leaf)) 'ok'
}

$watchTimer.Add_Tick({
    foreach ($dir in (Get-DownloadDirs)) {
        $zips = Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $script:WatchSince } |
                Sort-Object LastWriteTime -Descending
        foreach ($z in $zips) {
            if (Test-ZipHasWorld -Path $z.FullName) {
                Set-ConvertedZip -Path $z.FullName
                return
            }
        }
    }
})

$btnConv.Add_Click({
    $script:WatchSince = [datetime]::Now
    Set-Status $lblWatch 'Waiting for your converted zip to land in Downloads...' 'info'
    $watchTimer.Start()
    Start-Process $CONVERTER_URL
})
$btnCopyPath.Add_Click({
    if ($script:SourceWorld) { Set-Clipboard -Value $script:SourceWorld }
})
$btnShowSrc.Add_Click({
    if ($script:SourceWorld -and (Test-Path -LiteralPath $script:SourceWorld)) {
        Start-Process explorer.exe $script:SourceWorld
    }
})
$btnFindZipManual.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Converted save (*.zip)|*.zip|All files (*.*)|*.*'
    $dlg.Title = 'Find the converted zip'
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path -LiteralPath $dl) { $dlg.InitialDirectory = $dl }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    if (Test-ZipHasWorld -Path $dlg.FileName) {
        Set-ConvertedZip -Path $dlg.FileName
    } else {
        Set-Status $lblWatch 'No world inside that zip. Is it the one the converter made?' 'error'
    }
})

# ---------------------------------------------------------------------------
# Pane 4 - Install
# ---------------------------------------------------------------------------
$p4 = New-Object System.Windows.Forms.Panel
$p4.Size = $body.Size
$p4.Visible = $false

$p4.Controls.Add((New-Label -Text 'Ready to add it to your game.' -X 28 -Y 20 -W 650 -H 26 -Bold -Size 11.5))

$p4.Controls.Add((New-Label -Text 'Converted world:' -X 28 -Y 58 -W 200 -H 20 -Size 9 -Bold))
$lblZipName = New-Label -Text '' -X 28 -Y 78 -W 645 -H 22 -Size 10
$p4.Controls.Add($lblZipName)

$p4.Controls.Add((New-Label -Text 'Goes into:' -X 28 -Y 112 -W 200 -H 20 -Size 9 -Bold))
$lblSlotName = New-Label -Text '' -X 28 -Y 132 -W 500 -H 22 -Size 10
$p4.Controls.Add($lblSlotName)

$btnChangeSlot = New-Button -Text 'Change' -X 540 -Y 128 -W 100 -H 28
$p4.Controls.Add($btnChangeSlot)

$lstSlots = New-Object System.Windows.Forms.ListBox
$lstSlots.Location = New-Object System.Drawing.Point(28, 162)
$lstSlots.Size = New-Object System.Drawing.Size(645, 84)
$lstSlots.Font = New-Object System.Drawing.Font('Consolas', 9)
$lstSlots.Visible = $false
$p4.Controls.Add($lstSlots)

$btnImport = New-Button -Text 'Add it to my game' -X 28 -Y 258 -W 240 -H 40
$btnImport.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$p4.Controls.Add($btnImport)

$lblImportStatus = New-Label -Text '' -X 28 -Y 306 -W 645 -H 70 -Size 10
$p4.Controls.Add($lblImportStatus)

$body.Controls.Add($p4)

$refreshSlots = {
    $script:Slots = @(Get-SaveSlots)
    $lstSlots.Items.Clear()
    foreach ($s in $script:Slots) {
        $tag = if ($s.IsSteam) { 'your Steam account' } else { 'other' }
        $lstSlots.Items.Add(('{0}   ({1}, {2} worlds)' -f $s.Name, $tag, $s.Worlds)) | Out-Null
    }
}

function Resolve-Slot {
    & $refreshSlots
    $steam = @($script:Slots | Where-Object { $_.IsSteam })

    if ($script:Slots.Count -eq 0) {
        $script:SlotPath = $null
        $lblSlotName.Text = 'Palworld has not made a save on this PC yet.'
        $lblSlotName.ForeColor = [System.Drawing.Color]::FromArgb(180, 30, 30)
        Set-Status $lblImportStatus 'Launch Palworld, load any world, quit, then click Change to re-check.' 'warn'
        $btnImport.Enabled = $false
        return
    }

    $btnImport.Enabled = $true
    $lblSlotName.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)

    if ($steam.Count -eq 1) {
        $script:SlotPath = $steam[0].Path
        $lblSlotName.Text = ('Your Steam save  ({0})' -f $steam[0].Name)
        $lstSlots.Visible = $false
    } elseif ($script:Slots.Count -eq 1) {
        $script:SlotPath = $script:Slots[0].Path
        $lblSlotName.Text = $script:Slots[0].Name
        $lstSlots.Visible = $false
    } else {
        $lstSlots.Visible = $true
        $lblSlotName.Text = 'More than one - pick yours below:'
        $idx = 0
        for ($i = 0; $i -lt $script:Slots.Count; $i++) { if ($script:Slots[$i].IsSteam) { $idx = $i; break } }
        $lstSlots.SelectedIndex = $idx
        $script:SlotPath = $script:Slots[$idx].Path
    }
}

$btnChangeSlot.Add_Click({
    & $refreshSlots
    if ($script:Slots.Count -eq 0) { Resolve-Slot; return }
    $lstSlots.Visible = $true
    $lblSlotName.Text = 'Pick yours below:'
    if ($lstSlots.SelectedIndex -lt 0 -and $lstSlots.Items.Count -gt 0) { $lstSlots.SelectedIndex = 0 }
    $btnImport.Enabled = $true
})

$lstSlots.Add_SelectedIndexChanged({
    if ($lstSlots.SelectedIndex -ge 0) { $script:SlotPath = $script:Slots[$lstSlots.SelectedIndex].Path }
})

$btnImport.Add_Click({
    if (-not $script:SlotPath) {
        Set-Status $lblImportStatus 'No save folder chosen.' 'error'
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $temp = Join-Path $env:TEMP "PalConvert-$stamp"
    try {
        $btnImport.Enabled = $false
        Set-Status $lblImportStatus 'Working...' 'info'
        $form.Refresh()
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($script:ZipPath, $temp)

        $worlds = @(Find-WorldFolders -Root $temp)
        if ($worlds.Count -eq 0) {
            Set-Status $lblImportStatus 'No world inside that zip. Nothing was changed.' 'error'
            $btnImport.Enabled = $true
            return
        }
        $src = ($worlds | Sort-Object PlayerCount -Descending | Select-Object -First 1).Path
        $worldName = Split-Path $src -Leaf
        if ($src -eq $temp) { $worldName = ([guid]::NewGuid().ToString('N')).ToUpper() }

        $dest = Join-Path $script:SlotPath $worldName
        $script:BackupNote = ''
        if (Test-Path -LiteralPath $dest) {
            $bak = "$dest.bak-$stamp"
            Rename-Item -LiteralPath $dest -NewName (Split-Path $bak -Leaf)
            $script:BackupNote = "A world with that name was already there. It was kept, renamed to:`r`n$bak"
        }

        Copy-Tree -Source $src -Destination $dest

        if (-not (Test-Path -LiteralPath (Join-Path $dest 'Level.sav'))) {
            Set-Status $lblImportStatus 'Copied, but Level.sav is missing at the destination. Something went wrong.' 'error'
            $btnImport.Enabled = $true
            return
        }

        $script:ImportedPath = $dest
        Set-Status $lblImportStatus 'Done. Click Next.' 'ok'
    } catch {
        Set-Status $lblImportStatus ('Failed: {0}' -f $_.Exception.Message) 'error'
        $btnImport.Enabled = $true
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
})

# ---------------------------------------------------------------------------
# Pane 5 - Done
# ---------------------------------------------------------------------------
$p5 = New-Object System.Windows.Forms.Panel
$p5.Size = $body.Size
$p5.Visible = $false

$p5.Controls.Add((New-Label -Text 'Your world is on this PC.' -X 28 -Y 34 -W 650 -H 32 -Bold -Size 13))
$p5.Controls.Add((New-Label -Text 'Start Palworld, click Start Game, and it will be in your world list.' -X 28 -Y 78 -W 650 -H 26 -Size 11))

$btnLaunch = New-Button -Text 'Start Palworld' -X 28 -Y 116 -W 190 -H 38
$btnLaunch.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnShowFiles = New-Button -Text 'Show me the files' -X 232 -Y 116 -W 180 -H 38
$p5.Controls.AddRange(@($btnLaunch, $btnShowFiles))

$lblDone = New-Label -Text '' -X 28 -Y 172 -W 650 -H 80 -Size 9
$p5.Controls.Add($lblDone)

$p5.Controls.Add((New-Label -Text @'
Keep your server download until you have loaded the world and checked it.

If the map is dark again, that part is stored separately - see READ ME FIRST.
'@ -X 28 -Y 262 -W 650 -H 70 -Size 10))

$btnLaunch.Add_Click({ Start-Process $STEAM_LAUNCH })
$btnShowFiles.Add_Click({
    if ($script:ImportedPath -and (Test-Path -LiteralPath $script:ImportedPath)) {
        Start-Process explorer.exe $script:ImportedPath
    }
})
$body.Controls.Add($p5)

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
$panels = @($p0, $p1, $p2, $p3, $p4, $p5)
$titles = @(
    'Palworld Save Converter',
    'Get your world off the server',
    'Your download',
    'Convert it',
    'Add it to your game',
    'Finished'
)

function Show-Step {
    param([int]$Index)
    for ($i = 0; $i -lt $panels.Count; $i++) { $panels[$i].Visible = ($i -eq $Index) }
    $titleLabel.Text = $titles[$Index]
    $stepLabel.Text = ('Step {0} of {1}' -f ($Index + 1), $panels.Count)
    $btnBack.Enabled = ($Index -gt 0)
    $btnNext.Text = if ($Index -eq $panels.Count - 1) { 'Close' } else { 'Next' }

    if ($Index -ne 3) { $watchTimer.Stop() }

    if ($Index -eq 2 -and $lstCand.Items.Count -eq 0 -and -not $script:SourceWorld) { & $scanSources }
    if ($Index -eq 3) {
        $txtConvertPath.Text = $script:SourceWorld
        if (-not $script:ZipPath) { Set-Status $lblWatch 'Click "Open the converter" to start.' 'info' }
    }
    if ($Index -eq 4) {
        if ($script:ZipPath) { $lblZipName.Text = (Split-Path $script:ZipPath -Leaf) }
        Resolve-Slot
    }
    if ($Index -eq 5) {
        $msg = "Saved to:`r`n$($script:ImportedPath)"
        if ($script:BackupNote) { $msg += "`r`n`r`n$($script:BackupNote)" }
        $lblDone.Text = $msg
    }
    $script:Step = $Index
}

function Test-Step {
    param([int]$Index)
    switch ($Index) {
        2 {
            if (-not $script:SourceWorld) {
                [System.Windows.Forms.MessageBox]::Show('Pick your download first, then click "Use this one".', 'Palworld Save Converter', 'OK', 'Warning') | Out-Null
                return $false
            }
        }
        3 {
            if (-not $script:ZipPath) {
                [System.Windows.Forms.MessageBox]::Show('I have not seen the converted zip yet. Finish the conversion in your browser, or click "I saved it somewhere else".', 'Palworld Save Converter', 'OK', 'Warning') | Out-Null
                return $false
            }
        }
        4 {
            if (-not $script:ImportedPath) {
                [System.Windows.Forms.MessageBox]::Show('Click "Add it to my game" first.', 'Palworld Save Converter', 'OK', 'Warning') | Out-Null
                return $false
            }
        }
    }
    return $true
}

$btnNext.Add_Click({
    if ($script:Step -eq $panels.Count - 1) { $form.Close(); return }
    if (-not (Test-Step -Index $script:Step)) { return }
    Show-Step -Index ($script:Step + 1)
})
$btnBack.Add_Click({ if ($script:Step -gt 0) { Show-Step -Index ($script:Step - 1) } })
$form.Add_FormClosed({ $watchTimer.Stop(); $watchTimer.Dispose() })

Show-Step -Index 0
[void]$form.ShowDialog()
$form.Dispose()
