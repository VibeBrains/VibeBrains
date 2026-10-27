# Внешний исполнитель бригадира для Windows: отдельный неинтерактивный `claude -p`,
# у которого только в его процессе подменён сервер на Anthropic-совместимый API провайдера
# Те же команды и тот же журнал, что у worker.sh
#
#   worker.ps1 set-key <провайдер>
#   worker.ps1 import-key <провайдер> [-FromFile <путь> | -FromLegacy]
#   worker.ps1 check [провайдер]
#   worker.ps1 run -Provider <имя> -Tier cheap|strong -Effort <уровень> -Mode read|write `
#                  -Dir <путь> -Brief <файл или -> [-Budget <usd>] [-BashAllow "<шаблон>",…] [-AllowMainTree]
#   (потолок цены запуска — maxRunUsd из профиля; -Budget переопределяет его вручную)
#
# Ключ хранится в Диспетчере учётных данных Windows (Credential Manager), в аргументы процессов не попадает

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command,
    [Parameter(Position = 1)] [string] $ProviderPos,
    [string] $Provider,
    [string] $Tier,
    [string] $Effort,
    [ValidateSet('read', 'write')] [string] $Mode,
    [string] $Dir,
    [string] $Budget,
    [string] $Brief,
    [string] $FromFile,
    [switch] $FromLegacy,
    [string[]] $BashAllow = @(),
    [switch] $AllowMainTree
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UserProvidersDir = if ($env:BRIGADIER_WORKER_PROVIDERS) { $env:BRIGADIER_WORKER_PROVIDERS } else { Join-Path $env:APPDATA 'brigadier-worker\providers' }
# Журнал: переменная окружения BRIGADIER_WORKER_LOG, затем logFile профиля, затем этот путь
$DefaultLogFile = Join-Path $env:LOCALAPPDATA 'brigadier-worker\runs.jsonl'
$CheckTimeoutSec = 30
$CheckMaxTokens = 64
$PricesStaleDays = 30
# Знаков на токен для оценки выхода по тексту потока (usage в потоке отдаёт output_tokens=0); берётся с запасом вниз
$CharsPerToken = 2.5
$DefaultEnvFile = if ($env:BRIGADIER_WORKER_ENV_FILE) { $env:BRIGADIER_WORKER_ENV_FILE } else { Join-Path $HOME '.vibe\.env' }
$LegacyServicePrefix = 'brigadir-'
$CurrentServicePrefix = 'brigadier-'
$ClaudeBin = if ($env:BRIGADIER_WORKER_CLAUDE) { $env:BRIGADIER_WORKER_CLAUDE } else { 'claude' }

# Каталог временных worktree режима write; ветка исполнителя — brigadier/<время>
$WorktreesRoot = if ($env:BRIGADIER_WORKER_WORKTREES) { $env:BRIGADIER_WORKER_WORKTREES } else { Join-Path ([IO.Path]::GetTempPath()) 'brigadier-worktrees' }
$BranchPrefix = 'brigadier'

$ReadAllowed = 'Read,Grep,Glob,Bash(ls *),Bash(pwd),Bash(wc *),Bash(rg *),Bash(grep *),Bash(git status*),Bash(git log*),Bash(git diff*),Bash(git show*),Bash(git ls-files*),Bash(git blame*)'
$ReadDenied = 'Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task'
$WriteAllowed = "$ReadAllowed,Edit,Write"
$WriteDenied = 'NotebookEdit,WebFetch,WebSearch,Agent,Task,Bash(git commit*),Bash(git push*),Bash(git reset*),Bash(git checkout*),Bash(git clean*),Bash(git rebase*),Bash(git merge*),Bash(rm *),Bash(del *),Bash(Remove-Item*)'
$WorkerPrompt = 'Ты внешний исполнитель: делай задачу из брифа сам, никому её не передавай и субагентов не запускай. Не коммить и не пушь. В конце дай короткий итог: что сделано, что проверено, что не удалось.'

function Stop-Worker([string] $Message) {
    [Console]::Error.WriteLine("ошибка: $Message")
    exit 1
}

# Доступ к Credential Manager через advapi32: ни одной команды с ключом в аргументах
if (-not ('BrigadierCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BrigadierCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public uint Flags; public uint Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
        public uint AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL cred, uint flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr cred);
    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;
    public static string Read(string target) {
        IntPtr p;
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out p)) return null;
        try {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize == 0) return null;
            return Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
        } finally { CredFree(p); }
    }
    public static void Write(string target, string user, string secret) {
        byte[] bytes = Encoding.Unicode.GetBytes(secret);
        IntPtr blob = Marshal.AllocHGlobal(bytes.Length);
        try {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            CREDENTIAL c = new CREDENTIAL();
            c.Type = CRED_TYPE_GENERIC; c.TargetName = target; c.UserName = user;
            c.CredentialBlobSize = (uint)bytes.Length; c.CredentialBlob = blob; c.Persist = CRED_PERSIST_LOCAL_MACHINE;
            if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(blob); }
    }
}
'@
}

function Find-Profile([string] $Name) {
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]*$') { Stop-Worker 'имя провайдера: строчные латинские буквы, цифры и дефис' }
    $user = Join-Path $UserProvidersDir "$Name.json"
    $own = Join-Path (Join-Path $ScriptDir 'providers') "$Name.json"
    if (Test-Path -LiteralPath $user) { return $user }
    if (Test-Path -LiteralPath $own) { return $own }
    Stop-Worker "нет профиля провайдера «$Name» (искал в $UserProvidersDir и $ScriptDir\providers)"
}

function Read-Profile([string] $Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Ключ: переменная окружения, затем Credential Manager
function Read-Key($Prof) {
    $fromEnv = [Environment]::GetEnvironmentVariable($Prof.secret.env)
    if ($fromEnv) { return $fromEnv }
    $stored = [BrigadierCred]::Read($Prof.secret.service)
    if ($stored) { return $stored }
    return ''
}

# Имя записи по прежней схеме (до переименования навыка); совпадает с текущим, если сервис профиля не по схеме навыка
function Get-LegacyService([string] $Service) {
    if ($Service.StartsWith($CurrentServicePrefix)) { return $LegacyServicePrefix + $Service.Substring($CurrentServicePrefix.Length) }
    return $Service
}

# Есть ли ключ под прежним именем: тогда он молча не читается, а владельцу говорится про import-key
function Write-LegacyKeyHint($Prof, [string] $Name) {
    $legacy = Get-LegacyService $Prof.secret.service
    if ($legacy -eq $Prof.secret.service) { return }
    if ([BrigadierCred]::Read($legacy)) {
        [Console]::Error.WriteLine("найден ключ под старым именем ($legacy) — выполни import-key: worker.ps1 import-key $Name")
    }
}

# Запись ключа в Credential Manager: значение идёт через память процесса, в аргументы не попадает
function Save-Key($Prof, [string] $Plain) {
    if (-not $Plain) { Stop-Worker 'пустой ключ' }
    [BrigadierCred]::Write($Prof.secret.service, $env:USERNAME, $Plain)
}

function Invoke-SetKey([string] $Name) {
    if (-not $Name) { Stop-Worker 'нужно имя провайдера: worker.ps1 set-key <провайдер>' }
    $prof = Read-Profile (Find-Profile $Name)
    $secure = Read-Host -AsSecureString 'Вставьте ключ и нажмите Enter (ввод не отображается)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        Save-Key $prof ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    Write-Output "ключ положен в Credential Manager ($($prof.secret.service))"
}

# Значение переменной из .env: KEY=value, export KEY=value, кавычки снимаются, комментарии пропускаются
function Read-EnvFileValue([string] $Path, [string] $KeyName) {
    $value = $null
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^export\s+') { $line = $line -replace '^export\s+', '' }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1 -or $line.Substring(0, $eq).Trim() -ne $KeyName) { continue }
        $val = $line.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and $val[0] -eq $val[$val.Length - 1] -and ($val[0] -eq '"' -or $val[0] -eq "'")) {
            $val = $val.Substring(1, $val.Length - 2)
        } else {
            $cut = $val.IndexOf(' #')
            if ($cut -ge 0) { $val = $val.Substring(0, $cut).TrimEnd() }
        }
        $value = $val
    }
    return $value
}

# Перенос уже имеющегося ключа в хранилище: из переменной окружения keyEnv и файлов .env
function Invoke-ImportKey([string] $Name) {
    if (-not $Name) { Stop-Worker 'нужно имя провайдера: worker.ps1 import-key <провайдер> [-FromFile <путь> | -FromLegacy]' }
    $prof = Read-Profile (Find-Profile $Name)
    $keyEnv = $prof.keyEnv
    if (-not $keyEnv) { Stop-Worker 'в профиле нет keyEnv (имя переменной, под которой ключ обычно лежит)' }
    if ($FromFile -and $FromLegacy) { Stop-Worker '-FromFile и -FromLegacy вместе не задаются' }
    $sources = @()
    if ($FromFile) {
        if (-not (Test-Path -LiteralPath $FromFile -PathType Leaf)) { Stop-Worker "нет файла $FromFile" }
        $v = Read-EnvFileValue $FromFile $keyEnv
        if ($v) { $sources += [pscustomobject]@{ Label = "$FromFile ($keyEnv)"; Value = $v } }
    } else {
        $v = [Environment]::GetEnvironmentVariable($keyEnv)
        if ($v -and -not $FromLegacy) { $sources += [pscustomobject]@{ Label = "переменная окружения $keyEnv"; Value = $v } }
        if ((Test-Path -LiteralPath $DefaultEnvFile -PathType Leaf) -and -not $FromLegacy) {
            $v = Read-EnvFileValue $DefaultEnvFile $keyEnv
            if ($v) { $sources += [pscustomobject]@{ Label = "$DefaultEnvFile ($keyEnv)"; Value = $v } }
        }
        $legacy = Get-LegacyService $prof.secret.service
        if ($legacy -ne $prof.secret.service) {
            $v = [BrigadierCred]::Read($legacy)
            if ($v) { $sources += [pscustomobject]@{ Label = "старая запись хранилища ($legacy)"; Value = $v } }
        }
    }
    $distinct = @($sources | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($distinct.Count -eq 0) {
        $where = if ($FromFile) { "в $FromFile нет $keyEnv" } elseif ($FromLegacy) { 'старой записи хранилища нет' } else { "ключ $keyEnv не найден ни в переменной окружения, ни в $DefaultEnvFile, ни в старой записи хранилища" }
        [Console]::Error.WriteLine("import-key: $where")
        [Console]::Error.WriteLine("Положите ключ вручную: worker.ps1 set-key $Name")
        exit 1
    }
    if ($distinct.Count -gt 1) {
        [Console]::Error.WriteLine('import-key: найдено несколько разных значений ключа, источники:')
        foreach ($src in $sources) { [Console]::Error.WriteLine("  $($src.Label)") }
        [Console]::Error.WriteLine("Укажите нужный файл (-FromFile <путь>) или прежнюю запись хранилища (-FromLegacy): worker.ps1 import-key $Name …")
        exit 1
    }
    Save-Key $prof $distinct[0]
    Write-Output "import-key: источник — $($sources[0].Label); ключ положен в Credential Manager ($($prof.secret.service))"
    Invoke-Check $Name
}

# Предупреждение, если цены в профиле не проверялись дольше PricesStaleDays
function Write-PricesAgeWarning($Prof, [string] $Name) {
    if (-not $Prof.prices) { Write-Output "check: $Name — в профиле нет prices, стоимость будет неизвестна"; return }
    $checked = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$Prof.pricesCheckedAt, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$checked)) {
        Write-Output "check: $Name — нет корректной pricesCheckedAt — обнови цены"; return
    }
    $age = [int]((Get-Date).Date - $checked.Date).TotalDays
    if ($age -gt $PricesStaleDays) { Write-Output "check: $Name — цены проверены $age дней назад — обнови" }
}

# Короткий запрос напрямую к API: проверяет и ключ, и адрес, и модель
function Invoke-Check([string] $Name) {
    if (-not $Name) { $Name = 'deepseek' }
    $prof = Read-Profile (Find-Profile $Name)
    $key = Read-Key $prof
    if (-not $key) {
        [Console]::Error.WriteLine("check: $Name — ключ не найден (Credential Manager или переменная окружения)")
        Write-LegacyKeyHint $prof $Name
        exit 1
    }
    $model = $prof.tiers.cheap.model
    $body = @{ model = $model; max_tokens = $CheckMaxTokens; messages = @(@{ role = 'user'; content = 'ответь одним словом: ок' }) } | ConvertTo-Json -Depth 5
    $headers = @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' }
    try {
        $null = Invoke-RestMethod -Method Post -Uri "$($prof.baseUrl)/v1/messages" -Headers $headers -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $CheckTimeoutSec
        Write-Output "check: $Name — ключ найден, сервер отвечает (модель $model)"
        Write-PricesAgeWarning $prof $Name
        exit 0
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        [Console]::Error.WriteLine("check: $Name — сервер не ответил успехом (HTTP $status)")
        exit 1
    }
}

# Итог write-запуска: правки исполнителя — одним коммитом в ветку worktree, затем путь, ветка, дифф и команда уборки
# Worktree не удаляется: его принимает бригадир
function Write-WorktreeResult($wt, $branch, $base, $title, $repo) {
    $diffFile = "$wt.diff"
    if (& git -C $wt status --porcelain 2>$null) {
        & git -C $wt add -A *> $null
        & git -C $wt commit -q -m "brigadier: $title" *> $null
        if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("worktree: коммит правок не удался — правки лежат в $wt без коммита") }
    }
    $diffText = (& git -C $wt diff $base HEAD 2>$null) -join "`n"
    [IO.File]::WriteAllText($diffFile, $diffText, (New-Object Text.UTF8Encoding($false)))
    Write-Output '---'
    Write-Output "worktree: $wt"
    Write-Output "ветка: $branch (от $base)"
    Write-Output "полный дифф: $diffFile"
    & git -C $wt diff --stat $base HEAD 2>$null
    if (-not $diffText) { Write-Output 'изменений нет' }
    Write-Output "влить: git -C $repo merge $branch"
    Write-Output "убрать после приёмки: git -C $repo worktree remove --force $wt; git -C $repo branch -D $branch; Remove-Item $diffFile"
}

# Запуск claude с разбором потока и потолком цены в настоящих долларах провайдера
# Счётчик самого claude (--max-budget-usd) считает по ценам Claude и обрывает чужую модель в ~30 раз раньше, поэтому
# потолок считается здесь: вход — точный usage сообщений, выход — оценка по длине текста (usage потока отдаёт 0)
# Обрыв — taskkill всего дерева процессов (SIGTERM на Windows нет)
function Invoke-ClaudeStream([string] $Exe, [string] $ArgLine, [string] $BriefFile, $Price, $Cap, [string] $ErrFile) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $proc = [Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $briefBytes = [IO.File]::ReadAllBytes($BriefFile)
    $proc.StandardInput.BaseStream.Write($briefBytes, 0, $briefBytes.Length)
    $proc.StandardInput.Close()

    $msgs = @{}      # id сообщения -> @(вход с промахом кэша, вход из кэша); usage повторяется в каждом блоке сообщения
    $texts = [ordered]@{}
    $seen = @{}
    $outChars = 0
    $thinkTokens = 0
    $result = $null
    $over = $false
    function Get-Spent {
        $miss = 0; $hit = 0
        foreach ($v in $msgs.Values) { $miss += $v[0]; $hit += $v[1] }
        $out = [int]($outChars / $CharsPerToken) + $thinkTokens
        if (-not $Price) { return $null }
        return ($miss * [double]$Price.inputMiss + $hit * [double]$Price.inputHit + $out * [double]$Price.output) / 1e6
    }
    try {
        while ($null -ne ($ln = $proc.StandardOutput.ReadLine())) {
            try { $ev = $ln | ConvertFrom-Json } catch { continue }
            if (-not $ev) { continue }
            if ($ev.type -eq 'result') { $result = $ev; continue }
            if ($ev.type -eq 'assistant') {
                $m = $ev.message
                $mid = if ($m.id) { [string]$m.id } else { '?' }
                $u = $m.usage
                $msgs[$mid] = @(([int]$u.input_tokens + [int]$u.cache_creation_input_tokens), [int]$u.cache_read_input_tokens)
                foreach ($c in @($m.content)) {
                    $key = $mid + '|' + ($c | ConvertTo-Json -Compress -Depth 20)
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    if ($c.type -eq 'text') {
                        if (-not $texts.Contains($mid)) { $texts[$mid] = '' }
                        $texts[$mid] += [string]$c.text
                        $outChars += ([string]$c.text).Length
                    } elseif ($c.type -eq 'tool_use') {
                        $outChars += ($c.input | ConvertTo-Json -Compress -Depth 20).Length
                    }
                }
            } elseif ($ev.type -eq 'system' -and $ev.subtype -eq 'thinking_tokens') {
                $thinkTokens += [int]$ev.estimated_tokens_delta
            } else { continue }
            if ($null -ne $Cap -and -not $over -and -not $result) {
                $spent = Get-Spent
                if ($null -ne $spent -and $spent -gt $Cap) {
                    $over = $true
                    & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
                }
            }
        }
    } finally {
        if (-not $proc.HasExited) { & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null }
        $proc.WaitForExit()
    }
    [IO.File]::WriteAllText($ErrFile, [string]$errTask.Result, (New-Object Text.UTF8Encoding($false)))

    $miss = 0; $hit = 0
    foreach ($v in $msgs.Values) { $miss += $v[0]; $hit += $v[1] }
    $out = [int]($outChars / $CharsPerToken) + $thinkTokens
    $exact = $false; $counter = $null; $isError = $false
    $text = if ($texts.Count -gt 0) { [string]@($texts.Values)[-1] } else { '' }
    if ($result) {
        $u = $result.usage
        if ($u) {
            $miss = [int]$u.input_tokens + [int]$u.cache_creation_input_tokens
            $hit = [int]$u.cache_read_input_tokens
            $out = [int]$u.output_tokens
            $exact = $true
        }
        $counter = if ($result.total_cost_usd) { [double]$result.total_cost_usd } else { 0.0 }
        $isError = [bool]$result.is_error
        if ($result.result) { $text = [string]$result.result }
    }
    $verdict = if ($over) { 'упёрся в бюджет' } elseif (-not $result -or $isError) { 'ошибка' } else { 'успех' }
    $cost = $null
    if ($Price) { $cost = ($miss * [double]$Price.inputMiss + $hit * [double]$Price.inputHit + $out * [double]$Price.output) / 1e6 }
    return @{
        result = $text; verdict = $verdict; partial = ($over -or -not $result); tokMiss = $miss; tokHit = $hit; tokOut = $out
        exact = $exact; costUsd = $cost; counter = $counter; exitCode = $proc.ExitCode
    }
}

function Invoke-Run {
    foreach ($pair in @(@('Provider', $Provider), @('Tier', $Tier), @('Mode', $Mode), @('Dir', $Dir), @('Brief', $Brief))) {
        if (-not $pair[1]) { Stop-Worker 'обязательны -Provider -Tier -Mode -Dir -Brief' }
    }
    if (-not (Get-Command $ClaudeBin -ErrorAction SilentlyContinue)) { Stop-Worker "нет команды $ClaudeBin" }
    $prof = Read-Profile (Find-Profile $Provider)
    $tierNode = $prof.tiers.$Tier
    if (-not $tierNode) { Stop-Worker "в профиле нет ступени «$Tier»" }
    $model = $tierNode.model
    $cheapModel = $prof.tiers.cheap.model
    $efforts = @($prof.efforts)
    if (-not $Effort) { $Effort = $prof.defaultEffort }
    if (-not $Effort) { Stop-Worker 'не задан -Effort и нет defaultEffort' }
    if ($efforts -notcontains $Effort) { Stop-Worker "уровень «$Effort» не из списка провайдера: $($efforts -join ',')" }
    if ($Budget) {
        if ($Budget -notmatch '^[0-9]+(\.[0-9]+)?$') { Stop-Worker '-Budget — число в долларах, например 0.30' }
        $cap = [double]::Parse($Budget, [Globalization.CultureInfo]::InvariantCulture)
    } else {
        # Потолок по умолчанию — страховка от зацикливания, maxRunUsd профиля; нет поля — запуск без потолка
        $cap = $null
        if ($null -ne $prof.maxRunUsd) {
            if ("$($prof.maxRunUsd)" -notmatch '^[0-9]+(\.[0-9]+)?$') { Stop-Worker 'maxRunUsd в профиле — число в долларах' }
            $cap = [double]$prof.maxRunUsd
        }
    }
    # Без цен в профиле реальную стоимость не посчитать: потолок не применим
    $price = if ($prof.prices) { $prof.prices.$model } else { $null }
    $capNote = ''
    if (-not $price) { $cap = $null; $capNote = 'потолок не считается: в профиле нет цен' }
    elseif ($null -eq $cap) { $capNote = 'потолок не задан: в профиле нет maxRunUsd' }
    if ($env:BRIGADIER_WORKER_LOG) { $LogFile = $env:BRIGADIER_WORKER_LOG }
    elseif ($prof.logFile) {
        $LogFile = [Environment]::ExpandEnvironmentVariables([string]$prof.logFile)
        if ($LogFile -match '^~[\\/]') { $LogFile = Join-Path $HOME $LogFile.Substring(2) }
    } else { $LogFile = $DefaultLogFile }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { Stop-Worker "нет каталога $Dir" }
    $workDir = (Resolve-Path -LiteralPath $Dir).Path

    # Режим write: основное дерево репозитория не трогаем — worktree создаётся ниже, после проверок ключа и брифа
    $makeWorktree = $false
    if ($Mode -eq 'write' -and -not $AllowMainTree) {
        $gitDir = (& git -C $workDir rev-parse --absolute-git-dir 2>$null)
        if ($LASTEXITCODE -ne 0) { Stop-Worker "режим write: $workDir не в git-репозитории" }
        $commonDir = (& git -C $workDir rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($gitDir -eq $commonDir) { $makeWorktree = $true; $repoRoot = $workDir }
    }

    $key = Read-Key $prof
    if (-not $key) {
        Write-LegacyKeyHint $prof $Provider
        Stop-Worker "ключ провайдера «$Provider» не найден: worker.ps1 set-key $Provider"
    }

    if ($Mode -eq 'read') { $allowed = $ReadAllowed; $denied = $ReadDenied } else { $allowed = $WriteAllowed; $denied = $WriteDenied }
    foreach ($extra in $BashAllow) { $allowed = "$allowed,Bash($extra)" }

    if ($Brief -eq '-') { $briefText = [Console]::In.ReadToEnd() } else {
        if (-not (Test-Path -LiteralPath $Brief)) { Stop-Worker "нет файла брифа $Brief" }
        $briefText = Get-Content -LiteralPath $Brief -Raw -Encoding UTF8
    }
    $briefFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($briefFile, $briefText, (New-Object Text.UTF8Encoding($false)))

    # Первая строка брифа нужна для сообщения коммита
    $briefTitle = ($briefText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $briefTitle) { $briefTitle = 'задача исполнителя' }
    if ($briefTitle.Length -gt 100) { $briefTitle = $briefTitle.Substring(0, 100) }

    $wtPath = ''; $wtBranch = ''; $wtBase = ''
    if ($makeWorktree) {
        $wtBase = (& git -C $workDir rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { Stop-Worker "в репозитории $workDir нет коммитов: нечего брать за основу worktree" }
        $wtBranch = "$BranchPrefix/" + (Get-Date).ToString('yyyyMMdd-HHmmss')
        New-Item -ItemType Directory -Path $WorktreesRoot -Force | Out-Null
        $wtPath = Join-Path $WorktreesRoot ('wt.' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        & git -C $workDir worktree add -q -b $wtBranch $wtPath HEAD 2>&1 | ForEach-Object { [Console]::Error.WriteLine($_) }
        if ($LASTEXITCODE -ne 0) { Stop-Worker 'git worktree add не удался' }
        $workDir = $wtPath
    }

    # Подмена сервера живёт только в этом процессе и его детях, затем возвращается как было
    $names = @('CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_MODEL',
        'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
        'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'BRIGADIER_WORKER',
        'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')
    $extraEnv = @{}
    if ($prof.extraEnv) { foreach ($p in $prof.extraEnv.PSObject.Properties) { $extraEnv[$p.Name] = [string]$p.Value; $names += $p.Name } }
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

    $errFile = [IO.Path]::GetTempFileName()
    $started = Get-Date
    try {
        foreach ($n in @('CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')) {
            [Environment]::SetEnvironmentVariable($n, $null, 'Process')
        }
        $env:ANTHROPIC_BASE_URL = $prof.baseUrl
        $env:ANTHROPIC_AUTH_TOKEN = $key
        $env:ANTHROPIC_MODEL = $model
        $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $model
        $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $model
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $cheapModel
        $env:CLAUDE_CODE_SUBAGENT_MODEL = $model
        $env:CLAUDE_CODE_EFFORT_LEVEL = $Effort
        $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        $env:BRIGADIER_WORKER = '1'
        foreach ($k in $extraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $extraEnv[$k], 'Process') }

        $claudeArgs = @('-p', '--bare', '--no-session-persistence', '--output-format', 'stream-json', '--verbose',
            '--model', $model, '--permission-mode', 'dontAsk',
            '--allowedTools', $allowed, '--disallowedTools', $denied, '--append-system-prompt', $WorkerPrompt)
        # Аргументы собираются одной строкой: элементы с пробелами берём в кавычки сами (двойных кавычек внутри аргументов нет)
        $argLine = ($claudeArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $claudeExe = (Get-Command $ClaudeBin).Source
        Push-Location $workDir
        try {
            $run = Invoke-ClaudeStream $claudeExe $argLine $briefFile $price $cap $errFile
        } finally { Pop-Location }
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
        Remove-Item -LiteralPath $briefFile -Force -ErrorAction SilentlyContinue
    }

    $err = (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8)
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue

    $result = [string]$run.result; $verdict = $run.verdict; $partial = $run.partial
    $realCost = $run.costUsd; $counter = $run.counter; $exact = $run.exact
    $tokensIn = $run.tokMiss + $run.tokHit; $tokensOut = $run.tokOut
    if (-not $result -and $verdict -eq 'упёрся в бюджет') { $result = '(обрыв по потолку до первого текстового ответа исполнителя)' }
    elseif ($verdict -ne 'успех' -and -not $result) {
        $tail = if ($err) { $err.Substring(0, [Math]::Min(500, $err.Length)) } else { 'пусто' }
        $result = "(пустой ответ; stderr: $tail)"
    } elseif ($partial -and $result) { $result = "[частичный результат: последний ответ исполнителя до обрыва]`n" + $result }
    $seconds = [int]((Get-Date) - $started).TotalSeconds

    # Строка журнала без текста брифа
    $line = [ordered]@{
        ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); provider = $Provider; tier = $Tier; model = $model; effort = $Effort
        mode = $Mode; dir = $workDir; tokensIn = $tokensIn; tokensOut = $tokensOut
        costUsd = $(if ($null -eq $realCost) { $null } else { [math]::Round($realCost, 6) }); costExact = $exact; capUsd = $cap
        claudeCounterUsd = $(if ($null -eq $counter) { $null } else { [math]::Round($counter, 6) })
        seconds = $seconds; verdict = $verdict; partial = $partial
    } | ConvertTo-Json -Compress
    try {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        [IO.File]::AppendAllText($LogFile, $line + "`n", (New-Object Text.UTF8Encoding($false)))
    } catch { [Console]::Error.WriteLine("журнал не записан: $($_.Exception.Message)") }

    Write-Output $result
    Write-Output '---'
    Write-Output "исполнитель: провайдер=$Provider ступень=$Tier модель=$model уровень=$Effort режим=$Mode"
    $costText = if ($null -eq $realCost) { 'неизвестна (нет prices в профиле)' }
    elseif ($exact) { ('${0:N4}' -f $realCost) }
    else { ('~${0:N4} (оценка: выход по длине текста, итога от claude нет)' -f $realCost) }
    $counterText = if ($null -eq $counter) { 'нет итогового события' } else { ('${0:N4}' -f $counter) }
    Write-Output ("токены: вход={0} выход={1}; время: {2}с" -f $tokensIn, $tokensOut, $seconds)
    Write-Output ("стоимость: {0}; счётчик claude (справочно, по ценам Claude): {1}" -f $costText, $counterText)
    if ($null -ne $cap) { Write-Output ('потолок: ${0:N4} (в настоящих долларах провайдера)' -f $cap) }
    elseif ($capNote) { Write-Output $capNote }
    if ($partial) { Write-Output 'результат частичный' }
    Write-Output "итог: $verdict"
    if ($wtPath) { Write-WorktreeResult $wtPath $wtBranch $wtBase $briefTitle $repoRoot }
    switch ($verdict) { 'успех' { exit 0 } 'упёрся в бюджет' { exit 2 } default { exit 1 } }
}

switch ($Command) {
    'set-key' { Invoke-SetKey $(if ($Provider) { $Provider } else { $ProviderPos }) }
    'import-key' { Invoke-ImportKey $(if ($Provider) { $Provider } else { $ProviderPos }) }
    'check' { Invoke-Check $(if ($Provider) { $Provider } else { $ProviderPos }) }
    'run' { Invoke-Run }
    default { Get-Content -LiteralPath $MyInvocation.MyCommand.Path -TotalCount 14 | ForEach-Object { $_ -replace '^# ?', '' } | Write-Error; exit 1 }
}
