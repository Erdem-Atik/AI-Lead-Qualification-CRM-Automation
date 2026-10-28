<#
  AI Lead CRM - butunlesik test seti
  ----------------------------------
  Ne yapar:
    1) Katman katman on kontrol: n8n -> Ollama -> webhook (hangisi kirikse orada durur)
    2) Senaryolari sirayla gonderir, API yanitini OTOMATIK dogrular (PASS / FAIL)
    3) Onay (Approve/Reject) testlerinde sana rehberlik eder, sonucu sorar
    4) Sonunda test-report-<zaman>.md raporu yazar (video ve README icin kanit)

  Kullanim:
    .\lead-test-suite.ps1 -BaseEmail senin@gmail.com
    .\lead-test-suite.ps1 -BaseEmail senin@gmail.com -Only T03,T04
    .\lead-test-suite.ps1 -BaseEmail senin@gmail.com -SkipManual
    .\lead-test-suite.ps1 -BaseEmail senin@gmail.com -Resilience

  Onkosul: n8n'de 09 workflow'u AKTIF olmali. Bu betik canli adresi (/webhook/) kullanir,
           "Listen for test event" butonuna basmana gerek yok.

  Test e-postalari  isim+tag-zaman@gmail.com  seklinde uretilir, hepsi senin gelen kutuna duser.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$BaseEmail,
    [string[]]$Only,
    [switch]$SkipManual,
    [switch]$Resilience,
    [string]$BaseUrl = "http://localhost:5678",
    [string]$OllamaUrl = "http://localhost:11434"
)

$ErrorActionPreference = "Stop"
$RunId      = Get-Date -Format "yyyyMMdd-HHmmss"
$WebhookUrl = "$BaseUrl/webhook/lead-intake"
$ReportDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Local      = $BaseEmail.Split('@')[0].Split('+')[0]
$Domain     = $BaseEmail.Split('@')[1]

$script:Results = New-Object System.Collections.ArrayList
$script:Details = New-Object System.Collections.ArrayList
$script:Emails  = [ordered]@{}
$script:Saved   = @{}

# ---------------------------------------------------------------- yardimcilar
function New-TestEmail([string]$Tag) {
    return ("{0}+{1}-{2}@{3}" -f $Local, $Tag.ToLower(), $RunId, $Domain)
}

function Should-Run([string]$Id) {
    if (-not $Only -or $Only.Count -eq 0) { return $true }
    return ($Only -contains $Id)
}

function Add-Result($Id, $Test, $Result, $Detail = "", $Attempts = 1, $Seconds = 0) {
    [void]$script:Results.Add([pscustomobject]@{
        Id = $Id; Test = $Test; Result = $Result; Detail = $Detail; Attempts = $Attempts; Seconds = $Seconds
    })
    $color = switch ($Result) {
        'PASS'  { 'Green' }
        'FAIL'  { 'Red' }
        'KNOWN' { 'Yellow' }
        'INFO'  { 'Cyan' }
        default { 'DarkGray' }
    }
    Write-Host ("  [{0}] {1} {2}" -f $Result, $Id, $Detail) -ForegroundColor $color
}

function Read-ResponseBody($Response) {
    try { return [Text.Encoding]::UTF8.GetString($Response.RawContentStream.ToArray()) }
    catch { return [string]$Response.Content }
}

function Send-Lead([hashtable]$Body) {
    $json  = $Body | ConvertTo-Json -Depth 5
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sw    = [Diagnostics.Stopwatch]::StartNew()
    $status = 0
    $raw    = ""
    try {
        $r = Invoke-WebRequest -Uri $WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" `
             -Body $bytes -UseBasicParsing -TimeoutSec 180
        $status = [int]$r.StatusCode
        $raw    = Read-ResponseBody $r
    }
    catch {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $raw = $_.ErrorDetails.Message }
        else { $raw = $_.Exception.Message }
    }
    $sw.Stop()
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    return [pscustomobject]@{ Status = $status; Raw = $raw; Json = $parsed; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Invoke-AutoTest {
    param([string]$Id, [string]$Name, [hashtable]$Body, [scriptblock]$Check, [int]$MaxAttempts = 1)
    Write-Host ("`n{0}  {1}" -f $Id, $Name) -ForegroundColor White
    if ($Body.email -like '*+*') { $script:Emails[$Id] = $Body.email }

    $attempt = 0
    $res     = $null
    $fail    = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        $res  = Send-Lead $Body
        $fail = & $Check $res
        if (-not $fail) { break }
        if ($attempt -lt $MaxAttempts) { Write-Host ("  ... tutmadi ({0}), tekrar deneniyor" -f $fail) -ForegroundColor DarkYellow }
    }

    $info = "HTTP $($res.Status) / $($res.Seconds) sn"
    if ($res.Json -and $res.Json.status)     { $info += " / status=$($res.Json.status)" }
    if ($res.Json -and $res.Json.lead_score) { $info += " / skor=$($res.Json.lead_score.total_score)" }
    if ($res.Json -and $res.Json.extraction) { $info += " / guven=$($res.Json.extraction.confidence_score)" }

    $pretty = if ($res.Json) { $res.Json | ConvertTo-Json -Depth 8 } else { $res.Raw }
    [void]$script:Details.Add(("### {0} - {1}`nDeneme: {2}, e-posta: {3}`n``````json`n{4}`n``````" -f $Id, $Name, $attempt, $Body.email, $pretty))

    if ($fail) {
        Add-Result $Id $Name 'FAIL' ("{0} [{1}]" -f $fail, $info) $attempt $res.Seconds
    }
    elseif ($attempt -gt 1) {
        Add-Result $Id $Name 'PASS' ("[flaky: {0}. denemede gecti] {1}" -f $attempt, $info) $attempt $res.Seconds
    }
    else {
        Add-Result $Id $Name 'PASS' $info $attempt $res.Seconds
    }
    return [pscustomobject]@{ Pass = (-not $fail); Res = $res }
}

function Ask-YesNo([string]$Question) {
    while ($true) {
        $a = (Read-Host ("  ? {0}  (e=evet / h=hayir / a=atla)" -f $Question)).Trim().ToLower()
        if ($a -in @('e', 'h', 'a')) { return $a }
    }
}

function Add-ManualResult($Id, $Test, [string]$Answer) {
    switch ($Answer) {
        'e' { Add-Result $Id $Test 'PASS' 'elle dogrulandi' }
        'h' { Add-Result $Id $Test 'FAIL' 'elle kontrolde beklenen gorulmedi' }
        default { Add-Result $Id $Test 'SKIP' 'atlandi' }
    }
}

function Stop-Preflight([string]$Message, [string]$Hint) {
    Write-Host ("  [X] {0}" -f $Message) -ForegroundColor Red
    Write-Host ("      Ipucu: {0}" -f $Hint) -ForegroundColor Yellow
    Write-Host "`nTestler baslamadi: once bu katmani duzelt." -ForegroundColor Red
    exit 2
}

# ------------------------------------------------------------ 1) katman kontrolu
function Invoke-Preflight {
    Write-Host "`n== Katman kontrolu ==" -ForegroundColor Cyan

    try { [void](Invoke-WebRequest -Uri "$BaseUrl/healthz" -UseBasicParsing -TimeoutSec 10); Write-Host "  [OK] 1/3 n8n ayakta ($BaseUrl)" -ForegroundColor Green }
    catch { Stop-Preflight "1/3 n8n'e ulasilamadi ($BaseUrl)" "Docker Desktop acik mi? 'docker ps' icinde n8n container'i gorunuyor mu?" }

    try {
        $tags  = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 10
        $names = @($tags.models | ForEach-Object { $_.name })
    }
    catch { Stop-Preflight "2/3 Ollama'ya ulasilamadi ($OllamaUrl)" "Sistem tepsisinde Ollama ikonu var mi? Yoksa Ollama uygulamasini baslat." }
    if ($names -notcontains "llama3.1:8b") { Stop-Preflight "2/3 Ollama calisiyor ama llama3.1:8b modeli yok" "ollama pull llama3.1:8b" }
    Write-Host "  [OK] 2/3 Ollama ayakta, llama3.1:8b yuklu" -ForegroundColor Green

    $probe = Send-Lead @{ email = "preflight"; message = "x" }
    if ($probe.Status -eq 400) { Write-Host "  [OK] 3/3 Webhook kayitli ve aktif (gecersiz istege 400 dondu)" -ForegroundColor Green }
    elseif ($probe.Status -eq 404) { Stop-Preflight "3/3 Webhook kayitli degil (404)" "09 workflow'u AKTIF mi? Eski 07/08 surumleri kapali mi? (ikisi ayni yolu kullanir)" }
    else { Stop-Preflight ("3/3 Webhook beklenmeyen yanit verdi (HTTP {0})" -f $probe.Status) "n8n'de Executions sekmesine bak, ilk hata orada yazar." }
}

# ------------------------------------------------------------ 2) test verileri
$B = @{}
$B.T01 = @{ email = "not-an-email"; message = "short" }
$B.T02 = @{ email = (New-TestEmail "t02"); contact_name = "No Message" }
$B.T03 = @{
    email = (New-TestEmail "t03"); contact_name = "Jane Doe"; company_name = "Acme Fiber"
    message = "We are a large telecom operator and need a 50km fiber optic backbone buildout in Istanbul this quarter. Budget is approved, around 500k USD. Please send a quotation as soon as possible."
}
$B.T04 = @{
    email = (New-TestEmail "t04"); contact_name = "John Small"; company_name = "Small Shop"
    message = "We are a small family business. Just exploring options for internet cabling in our shop, no fixed timeline and very limited budget."
}
$B.T05 = @{
    email = (New-TestEmail "t05"); contact_name = "Ay$([char]0x015F)e Y$([char]0x0131)lmaz"; company_name = "Bo$([char]0x011F)azi$([char]0x00E7)i Telekom"
    message = "$([char]0x0130)stanbul'da 50 km fiber optik altyap$([char]0x0131) kurulumu i$([char]0x00E7)in kurumsal teklif istiyoruz. B$([char]0x00FC)t$([char]0x00E7)emiz onayland$([char]0x0131) (yakla$([char]0x015F)$([char]0x0131)k 500 bin USD) ve bu $([char]0x00E7)eyrekte ba$([char]0x015F)lamak istiyoruz."
}
$msgT06 = @'
We need a 30 km fiber optic backbone in Izmir. Budget is approved (about 250k USD) and we start this quarter. Please reply to our "engineering" team, O'Brien's group - ASAP. Reference: '); -- harmless test text \ / <b>bold</b>
'@
$B.T06 = @{
    email = (New-TestEmail "t06"); contact_name = "Se$([char]0x00E1)n O'Brien"; company_name = "O'Brien & Sons"
    message = $msgT06.Trim()
}
$B.T07 = @{ email = (New-TestEmail "t07"); message = "Hello, we would like to get a price for a project. We will discuss the details later." }
$B.T08 = @{ email = (New-TestEmail "t08"); message = "Hi, we want something built, how much would it cost? Let us know." }
$B.T10 = @{ email = (New-TestEmail "t10"); contact_name = "Resilience Test"; company_name = "Down Co"; message = "We need a 10km fiber optic link between two offices, budget approved, start next month." }

# ------------------------------------------------------------ 3) onay (Approve/Reject) testi
function Invoke-ApprovalTest {
    param([string]$Id, [string]$Name, [hashtable]$Body, [ValidateSet('Approve', 'Reject')][string]$Decision)

    $t = Invoke-AutoTest -Id $Id -Name "$Name - API: pending_review donmeli" -Body $Body -MaxAttempts 2 -Check {
        param($r)
        if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
        if ($r.Json.status -ne 'pending_review') { return "beklenen status=pending_review, gelen '$($r.Json.status)' (guven=$($r.Json.extraction.confidence_score))" }
        if ([double]$r.Json.extraction.confidence_score -ge 0.75) { return "guven 0.75 veya ustu: $($r.Json.extraction.confidence_score)" }
        return $null
    }
    if (-not $t.Pass) { Add-Result "$Id-b" "$Name - elle adimlar" 'SKIP' 'API adimi gecmedigi icin atlandi'; return }
    if ($SkipManual)  { Add-Result "$Id-b" "$Name - elle adimlar" 'SKIP' '-SkipManual'; return }

    $expectPage   = if ($Decision -eq 'Approve') { "Lead onaylandi" } else { "Lead reddedildi" }
    $expectStatus = if ($Decision -eq 'Approve') { "converted" } else { "rejected" }
    Write-Host ""
    Write-Host "  ELLE ADIMLAR ($Decision)" -ForegroundColor Cyan
    Write-Host "   1) Reviewer gelen kutusunda 'Onay bekleyen lead' konulu maili ac (arama: $($Body.email))" -ForegroundColor Cyan
    Write-Host "   2) 'Incele ve karar ver' butonuna tikla, Decision = $Decision sec, gonder" -ForegroundColor Cyan
    Write-Host "   3) Sonra asagidaki sorulari yanitla" -ForegroundColor Cyan

    Add-ManualResult "$Id-b" "$Name - reviewer'a onay maili geldi" (Ask-YesNo "Onay maili geldi mi?")
    Add-ManualResult "$Id-c" "$Name - sonuc sayfasi" (Ask-YesNo "Sonuc sayfasinda '$expectPage' yazdi mi?")
    Add-ManualResult "$Id-d" "$Name - Supabase leads.status" (Ask-YesNo "Supabase 'leads' tablosunda bu e-posta icin status = $expectStatus mi?")
    if ($Decision -eq 'Approve') {
        Add-ManualResult "$Id-e" "$Name - HubSpot Deal olustu" (Ask-YesNo "HubSpot'ta bu kisi icin Deal olustu mu?")
    }
    else {
        Add-ManualResult "$Id-e" "$Name - HubSpot'a yazilmadi" (Ask-YesNo "HubSpot'ta bu e-posta icin kisi/Deal YOK mu?")
    }
}

# ------------------------------------------------------------ 4) rapor
function Write-Report {
    $all   = @($script:Results)
    $nPass = @($all | Where-Object { $_.Result -eq 'PASS' }).Count
    $nFail = @($all | Where-Object { $_.Result -eq 'FAIL' }).Count
    $nKnown = @($all | Where-Object { $_.Result -eq 'KNOWN' }).Count
    $nSkip = @($all | Where-Object { $_.Result -eq 'SKIP' }).Count
    $nFlaky = @($all | Where-Object { $_.Attempts -gt 1 -and $_.Result -eq 'PASS' }).Count

    $md = New-Object System.Collections.ArrayList
    [void]$md.Add("# Test raporu - $RunId")
    [void]$md.Add("")
    [void]$md.Add("- Tarih: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$md.Add("- Webhook: $WebhookUrl")
    [void]$md.Add("- Sonuc: **$nPass PASS**, **$nFail FAIL**, $nKnown KNOWN (bilinen sorun), $nSkip SKIP, $nFlaky flaky (tekrar denemeyle gecti)")
    [void]$md.Add("")
    [void]$md.Add("| ID | Test | Sonuc | Detay |")
    [void]$md.Add("|---|---|---|---|")
    foreach ($r in $all) {
        $d = ([string]$r.Detail) -replace '\|', '/'
        $n = ([string]$r.Test) -replace '\|', '/'
        [void]$md.Add("| $($r.Id) | $n | $($r.Result) | $d |")
    }
    [void]$md.Add("")
    [void]$md.Add("## Bu kosuda kullanilan test e-postalari")
    [void]$md.Add("Supabase Table Editor ve HubSpot aramasinda bunlari kullan (gorsel kontrol rehberi: TEST_PLAN.md).")
    [void]$md.Add("")
    foreach ($k in $script:Emails.Keys) { [void]$md.Add("- $k : $($script:Emails[$k])") }
    [void]$md.Add("")
    [void]$md.Add("## Yanit ayrintilari")
    foreach ($d in $script:Details) { [void]$md.Add(""); [void]$md.Add($d) }

    $path = Join-Path $ReportDir "test-report-$RunId.md"
    Set-Content -Path $path -Value ($md -join "`r`n") -Encoding UTF8
    return [pscustomobject]@{ Path = $path; Pass = $nPass; Fail = $nFail; Known = $nKnown; Skip = $nSkip; Flaky = $nFlaky }
}

# ------------------------------------------------------------ ana akis
Write-Host "AI Lead CRM - test seti  (kosu: $RunId)" -ForegroundColor Cyan
Invoke-Preflight

Write-Host "`n== Dogrulama (validation) ==" -ForegroundColor Cyan
if (Should-Run 'T01') {
    [void](Invoke-AutoTest -Id 'T01' -Name 'Gecersiz e-posta + kisa mesaj -> 400, 2 hata' -Body $B.T01 -Check {
        param($r)
        if ($r.Status -ne 400) { return "beklenen HTTP 400, gelen $($r.Status)" }
        if (@($r.Json.errors).Count -lt 2) { return "en az 2 hata bekleniyordu, gelen: $($r.Raw)" }
        return $null
    })
}
if (Should-Run 'T02') {
    [void](Invoke-AutoTest -Id 'T02' -Name 'Mesaj alani eksik -> 400' -Body $B.T02 -Check {
        param($r)
        if ($r.Status -ne 400) { return "beklenen HTTP 400, gelen $($r.Status)" }
        if (@($r.Json.errors).Count -lt 1) { return "hata listesi bos: $($r.Raw)" }
        return $null
    })
}

Write-Host "`n== Puanlama ve yonlendirme (yapay zeka kullanir, her biri 10-60 sn surebilir) ==" -ForegroundColor Cyan
if (Should-Run 'T03') {
    $t = Invoke-AutoTest -Id 'T03' -Name 'Sicak lead (EN) -> accepted, skor > 70, satis bildirimi' -Body $B.T03 -MaxAttempts 2 -Check {
        param($r)
        if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
        if ($r.Json.status -ne 'accepted') { return "status='$($r.Json.status)' (guven=$($r.Json.extraction.confidence_score)); accepted bekleniyordu" }
        if ([double]$r.Json.lead_score.total_score -le 70) { return "skor 70 veya alti: $($r.Json.lead_score.total_score)" }
        if ($r.Json.notification_sent -ne 'sales_notification') { return "notification_sent='$($r.Json.notification_sent)'" }
        if (-not $r.Json.postgres.lead_id) { return "postgres.lead_id bos" }
        if (-not $r.Json.hubspot.deal_id)  { return "hubspot.deal_id bos" }
        return $null
    }
    if ($t.Res.Json -and $t.Res.Json.status -eq 'accepted') { $script:Saved.T03 = $t.Res.Json }
}
if (Should-Run 'T04') {
    [void](Invoke-AutoTest -Id 'T04' -Name 'Soguk lead (EN) -> accepted, skor <= 70, otomatik takip' -Body $B.T04 -MaxAttempts 2 -Check {
        param($r)
        if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
        if ($r.Json.status -ne 'accepted') { return "status='$($r.Json.status)' (guven=$($r.Json.extraction.confidence_score)); accepted bekleniyordu" }
        if ([double]$r.Json.lead_score.total_score -gt 70) { return "skor 70'in ustu: $($r.Json.lead_score.total_score)" }
        if ($r.Json.notification_sent -ne 'automated_followup') { return "notification_sent='$($r.Json.notification_sent)'" }
        return $null
    })
}
if (Should-Run 'T05') {
    [void](Invoke-AutoTest -Id 'T05' -Name 'Sicak lead (TR, Turkce karakterler) -> accepted, skor > 70' -Body $B.T05 -MaxAttempts 2 -Check {
        param($r)
        if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
        if ($r.Json.status -ne 'accepted') { return "status='$($r.Json.status)' (guven=$($r.Json.extraction.confidence_score)); accepted bekleniyordu" }
        if ([double]$r.Json.lead_score.total_score -le 70) { return "skor 70 veya alti: $($r.Json.lead_score.total_score)" }
        return $null
    })
}
if (Should-Run 'T06') {
    [void](Invoke-AutoTest -Id 'T06' -Name "Ozel karakterler (' `" \ <b> SQL benzeri metin) -> sistem cokmemeli" -Body $B.T06 -MaxAttempts 2 -Check {
        param($r)
        if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status): $($r.Raw)" }
        if (@('accepted', 'pending_review') -notcontains $r.Json.status) { return "beklenmeyen status='$($r.Json.status)'" }
        if ($r.Json.status -eq 'accepted' -and -not $r.Json.postgres.lead_id) { return "postgres.lead_id bos" }
        return $null
    })
}

Write-Host "`n== Tekrar eden e-posta (dedup) ==" -ForegroundColor Cyan
if (Should-Run 'T09') {
    if (-not $script:Saved.T03) {
        Add-Result 'T09' 'Ayni e-posta ikinci kez' 'SKIP' 'T03 basarili sonucu yok (T03 de calissin)'
    }
    else {
        $b9 = $B.T03.Clone()
        $b9.message = "Following up on our fiber backbone project in Istanbul. We would like to add 20km more of fiber optic cabling to the scope. Budget remains approved, same timeline."
        $t9 = Invoke-AutoTest -Id 'T09' -Name 'Ayni e-posta ikinci kez -> yeni lead, ayni HubSpot contact' -Body $b9 -MaxAttempts 2 -Check {
            param($r)
            $t3 = $script:Saved.T03
            if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
            if ($r.Json.status -ne 'accepted') { return "status='$($r.Json.status)'; accepted bekleniyordu" }
            if ([string]$r.Json.postgres.lead_id -eq [string]$t3.postgres.lead_id) { return "yeni lead acilmadi (ayni lead_id)" }
            if ([string]$r.Json.hubspot.contact_id -ne [string]$t3.hubspot.contact_id) { return "HubSpot'ta YENI contact acildi ($($t3.hubspot.contact_id) -> $($r.Json.hubspot.contact_id))" }
            return $null
        }
        if ($t9.Pass) {
            $c1 = [string]$script:Saved.T03.hubspot.company_id
            $c2 = [string]$t9.Res.Json.hubspot.company_id
            # gmail.com gibi ucretsiz posta domain'lerinde Company bilerek tekrar kullanilmaz (birbirinden bagimsiz firmalar karismasin).
            # Gercek dedup kurumsal domainle T11'de test edilir.
            if ($c1 -ne $c2) { Add-Result 'T09b' 'Ucretsiz posta domain: ayri Company (beklenen)' 'PASS' "yeni Company ($c1 -> $c2); ucretsiz posta icin bilerek tekrar kullanilmaz" }
            else { Add-Result 'T09b' 'Ucretsiz posta domain: ayri Company (beklenen)' 'INFO' "ayni company_id ($c1): ucretsiz posta domaini paylasildi; 09'da beklenmiyordu" }
        }
    }
}

Write-Host "`n== Kurumsal domain: Company tekrar kullanimi ==" -ForegroundColor Cyan
if (Should-Run 'T11') {
    $corp = "dedup-$RunId.example.com"
    $mk = { param($tag, $who, $msg) @{ email = ("{0}+{1}-{2}@{3}" -f $Local, $tag, $RunId, $corp); contact_name = $who; company_name = "Dedup Corp $RunId"; message = $msg } }
    $m1 = "We are a large telecom operator and need a 50km fiber optic backbone buildout in Istanbul this quarter. Budget is approved, around 500k USD. Please send a quotation as soon as possible."
    $m2 = "Second request from our regional office: another 30km fiber optic backbone route in Ankara this quarter. Budget approved, around 300k USD, please quote as soon as possible."
    $ra = Invoke-AutoTest -Id 'T11a' -Name 'Kurumsal domain, ilk istek -> yeni Company' -Body (& $mk 't11a' 'Kim Alpha' $m1) -MaxAttempts 2 -Check {
        param($r)
        if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
        if ($r.Json.status -ne 'accepted') { return "status='$($r.Json.status)'; accepted bekleniyordu" }
        if (-not $r.Json.hubspot.company_id) { return "company_id bos" }
        return $null
    }
    if ($ra.Pass) {
        $first = [string]$ra.Res.Json.hubspot.company_id
        $rb = Invoke-AutoTest -Id 'T11b' -Name 'Ayni domain, farkli kisi -> ayni Company, yeni Contact' -Body (& $mk 't11b' 'Lee Beta' $m2) -MaxAttempts 2 -Check {
            param($r)
            if ($r.Status -ne 200) { return "beklenen HTTP 200, gelen $($r.Status)" }
            if ($r.Json.status -ne 'accepted') { return "status='$($r.Json.status)'; accepted bekleniyordu" }
            if ([string]$r.Json.hubspot.company_id -ne $first) { return "yeni Company acildi ($first -> $($r.Json.hubspot.company_id))" }
            if ([string]$r.Json.hubspot.contact_id -eq [string]$ra.Res.Json.hubspot.contact_id) { return "farkli kisi icin ayni contact kullanildi" }
            return $null
        }
    }
    else { Add-Result 'T11b' 'Ayni domain, farkli kisi' 'SKIP' 'T11a basarisiz' }
}

Write-Host "`n== Insan onayi (Approve / Reject) ==" -ForegroundColor Cyan
if (Should-Run 'T07') { Invoke-ApprovalTest -Id 'T07' -Name 'Belirsiz lead -> Approve' -Body $B.T07 -Decision 'Approve' }
if (Should-Run 'T08') { Invoke-ApprovalTest -Id 'T08' -Name 'Belirsiz lead -> Reject'  -Body $B.T08 -Decision 'Reject' }

if ((Should-Run 'T10') -and $Resilience -and -not $SkipManual) {
    Write-Host "`n== Dayaniklilik: Ollama kapaliyken ==" -ForegroundColor Cyan
    [void](Read-Host "  Ollama'yi kapat (sistem tepsisi > Ollama > Quit). Kapattiktan sonra Enter'a bas")
    $still = $false
    try { [void](Invoke-WebRequest -Uri "$OllamaUrl/api/tags" -UseBasicParsing -TimeoutSec 5); $still = $true } catch { $still = $false }
    if ($still) { Write-Host "  Uyari: Ollama hala yanit veriyor, test anlamsiz olabilir." -ForegroundColor Yellow }
    $script:Emails['T10'] = $B.T10.email
    $r10 = Send-Lead $B.T10
    Add-Result 'T10' 'Ollama kapali -> sistem nasil davranir?' 'INFO' ("HTTP {0} / {1} sn / {2}" -f $r10.Status, $r10.Seconds, ([string]$r10.Raw).Substring(0, [math]::Min(120, ([string]$r10.Raw).Length)))
    [void](Read-Host "  Ollama'yi tekrar ac, hazir olunca Enter'a bas")
}

# ------------------------------------------------------------ ozet
$rep = Write-Report
Write-Host "`n== OZET ==" -ForegroundColor Cyan
foreach ($r in $script:Results) {
    $color = switch ($r.Result) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'KNOWN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'DarkGray' } }
    Write-Host ("{0,-6} {1,-6} {2}" -f $r.Id, $r.Result, $r.Test) -ForegroundColor $color
    if ($r.Result -eq 'FAIL') { Write-Host ("              -> {0}" -f $r.Detail) -ForegroundColor Red }
}
Write-Host ""
Write-Host ("PASS: {0}   FAIL: {1}   KNOWN: {2}   SKIP: {3}   flaky: {4}" -f $rep.Pass, $rep.Fail, $rep.Known, $rep.Skip, $rep.Flaky)
Write-Host ("Rapor: {0}" -f $rep.Path) -ForegroundColor Green
Write-Host "Gorsel kontrol (Supabase / HubSpot / Gmail) icin TEST_PLAN.md dosyasina bak; aranacak e-postalar raporun icinde." -ForegroundColor DarkGray
if ($rep.Fail -gt 0) { exit 1 } else { exit 0 }
