#requires -Version 5.1
<#
  Betlify daily tips generator.

  Pulls real fixtures and bookmaker odds from ESPN's public scoreboard API
  (football, basketball, tennis), turns them into tips, settles finished
  matches and writes tips.json, which the Betlify app downloads.

  - A tip is created before kick-off and never changed afterwards (only its
    status/score), so the track record is honest.
  - Football/basketball confidence = bookmaker probability with the margin removed.
  - Tennis has no odds in the feed: probability and odds are estimated from
    ATP/WTA rankings, and the analysis says so.

  Runs on Windows PowerShell 5.1 and PowerShell 7 (GitHub Actions).
#>
param(
    [string]$Out = (Join-Path $PSScriptRoot 'tips.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Inv = [Globalization.CultureInfo]::InvariantCulture

$Base = 'https://site.api.espn.com/apis/site/v2/sports'

# ESPN league slug -> name shown in the app
$FootballLeagues = [ordered]@{
    'uefa.champions'   = 'Champions League'
    'uefa.europa'      = 'Europa League'
    'uefa.europa.conf' = 'Conference League'
    'eng.1'            = 'Premier League'
    'esp.1'            = 'La Liga'
    'ita.1'            = 'Serie A'
    'ger.1'            = 'Bundesliga'
    'fra.1'            = 'Ligue 1'
    'ned.1'            = 'Eredivisie'
    'por.1'            = 'Primeira Liga'
    'tur.1'            = 'Super Lig'
    'gre.1'            = 'Super League Greece'
}
$BasketballLeagues = [ordered]@{
    'nba'        = 'NBA'
    'euroleague' = 'EuroLeague'
}
$TennisTours = [ordered]@{
    'atp' = 'ATP'
    'wta' = 'WTA'
}

$MaxFreePerDay = 10
$MaxExtraPerDay = 15
$KeepDays = 30          # settled tips older than this are dropped
$AheadHours = 60        # create tips for matches starting within this window

# ---------- helpers ----------

function Get-Zone {
    foreach ($id in 'Europe/Belgrade', 'Central Europe Standard Time') {
        try { return [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { }
    }
    throw 'Belgrade time zone not found.'
}
$Zone = Get-Zone

function ConvertTo-Utc([string]$iso) {
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    [DateTime]::Parse($iso, $Inv, $styles)
}

function Format-Local([DateTime]$utc) {
    [TimeZoneInfo]::ConvertTimeFromUtc($utc, $Zone).ToString('yyyy-MM-dd HH:mm', $Inv)
}

function Get-Json([string]$url) {
    for ($i = 0; $i -lt 3; $i++) {
        try { return Invoke-RestMethod -Uri $url -TimeoutSec 30 -UserAgent 'betlify-tips' }
        catch { Start-Sleep -Seconds 2 }
    }
    Write-Warning "Request failed: $url"
    $null
}

# American odds ("+255", "-130", "EVEN") -> decimal odds
function ConvertTo-Decimal($american) {
    if ($null -eq $american) { return $null }
    $s = "$american".Trim().ToUpperInvariant()
    if ($s -eq 'EVEN') { return 2.0 }
    $a = 0.0
    if (-not [double]::TryParse($s.Replace('+', ''), [Globalization.NumberStyles]::Float, $Inv, [ref]$a)) { return $null }
    if ($a -gt 0) { return 1 + $a / 100 }
    if ($a -lt 0) { return 1 + 100 / [Math]::Abs($a) }
    $null
}

# Closing price if present, otherwise the opening one
function Get-Price($side) {
    if ($null -eq $side) { return $null }
    if ($side.close -and $side.close.odds) { return ConvertTo-Decimal $side.close.odds }
    if ($side.open -and $side.open.odds) { return ConvertTo-Decimal $side.open.odds }
    $null
}

function Get-Line($side) {
    if ($null -eq $side) { return $null }
    $text = if ($side.close -and $side.close.line) { $side.close.line } elseif ($side.open) { $side.open.line } else { $null }
    if (-not $text) { return $null }
    $v = 0.0
    if ([double]::TryParse(("$text" -replace '^[ou]', ''), [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { return $v }
    $null
}

# Bookmaker margin removed: implied probabilities that sum to 1
function Get-FairProbabilities([double[]]$odds) {
    $sum = 0.0
    foreach ($o in $odds) { $sum += 1 / $o }
    , @($odds | ForEach-Object { (1 / $_) / $sum })
}

function Pct([double]$p) { [int][Math]::Round($p * 100) }
function Round2([double]$x) { [Math]::Round($x, 2) }

function Get-Side($comp, [string]$homeAway) {
    $comp.competitors | Where-Object { $_.homeAway -eq $homeAway } | Select-Object -First 1
}

function New-Tip($ctx, [string]$pick, [double]$odds, [double]$p, [string]$analysis, [string]$market, [string]$side, $line) {
    [ordered]@{
        id         = "espn-$($ctx.Comp.id)"
        sport      = $ctx.Sport
        league     = $ctx.League
        home       = $ctx.Home
        away       = $ctx.Away
        kickoff    = Format-Local $ctx.Kickoff
        pick       = $pick
        odds       = Round2 $odds
        confidence = Pct $p
        analysis   = $analysis
        tier       = 'FREE'
        status     = 'PENDING'
        score      = $null
        # used by the generator to settle the tip; the app ignores them
        eventId    = "$($ctx.Comp.id)"
        espn       = $ctx.Path
        market     = $market
        side       = $side
        line       = $line
    }
}

# ---------- tip builders ----------

function New-FootballTip($ctx) {
    $o = @($ctx.Comp.odds)[0]
    if (-not $o -or -not $o.moneyline) { return $null }
    $oh = Get-Price $o.moneyline.home
    $od = Get-Price $o.moneyline.draw
    $oa = Get-Price $o.moneyline.away
    if (-not ($oh -and $od -and $oa)) { return $null }
    $p = Get-FairProbabilities @($oh, $od, $oa)
    $ph = $p[0]; $pd = $p[1]; $pa = $p[2]

    $cands = @(
        @{ pick = '1'; odds = $oh; p = $ph; market = 'ml'; side = 'home'; line = $null },
        @{ pick = '2'; odds = $oa; p = $pa; market = 'ml'; side = 'away'; line = $null }
    )
    if ($o.total -and $o.overUnder -eq 2.5) {
        $oo = Get-Price $o.total.over
        $ou = Get-Price $o.total.under
        if ($oo -and $ou) {
            $t = Get-FairProbabilities @($oo, $ou)
            $cands += @{ pick = '3+'; odds = $oo; p = $t[0]; market = 'total'; side = 'over'; line = 2.5 }
            $cands += @{ pick = '0-2'; odds = $ou; p = $t[1]; market = 'total'; side = 'under'; line = 2.5 }
        }
    }
    $best = $cands | Where-Object { $_.odds -ge 1.30 } |
        Sort-Object -Property @{ Expression = { $_.p }; Descending = $true } | Select-Object -First 1
    if (-not $best -or $best.p -lt 0.50) { return $null }

    $hs = $ctx.HomeShort; $as = $ctx.AwayShort
    $why = switch ($best.pick) {
        '1'   { "$hs are favourites at home." }
        '2'   { "$as are favourites even away from home." }
        '3+'  { "The goal line points to an open game: over 2.5 goals is rated $(Pct $best.p)%." }
        '0-2' { "A tight, low-scoring game is expected: under 2.5 goals is rated $(Pct $best.p)%." }
    }
    $text = "$why Bookmaker odds (margin removed): $hs $(Pct $ph)%, draw $(Pct $pd)%, $as $(Pct $pa)%."
    $hf = (Get-Side $ctx.Comp 'home').form
    $af = (Get-Side $ctx.Comp 'away').form
    if ($hf -and $af) { $text += " Recent form: $hs $hf, $as $af." }

    New-Tip $ctx $best.pick $best.odds $best.p $text $best.market $best.side $best.line
}

function New-BasketballTip($ctx) {
    $o = @($ctx.Comp.odds)[0]
    if (-not $o -or -not $o.moneyline) { return $null }
    $oh = Get-Price $o.moneyline.home
    $oa = Get-Price $o.moneyline.away
    if (-not ($oh -and $oa)) { return $null }
    $p = Get-FairProbabilities @($oh, $oa)
    $hs = $ctx.HomeShort; $as = $ctx.AwayShort

    $favHome = $p[0] -ge $p[1]
    $fav = if ($favHome) { $hs } else { $as }
    $favSide = if ($favHome) { 'home' } else { 'away' }
    $favOdds = if ($favHome) { $oh } else { $oa }
    $favP = if ($favHome) { $p[0] } else { $p[1] }
    $total = if ($o.overUnder) { " Game total: $($o.overUnder) points." } else { '' }

    if ($favOdds -ge 1.25) {
        $text = "$fav are $(Pct $favP)% favourites by the bookmaker odds (margin removed).$total"
        return New-Tip $ctx "$fav to win" $favOdds $favP $text 'ml' $favSide $null
    }

    # Heavy favourite: the handicap gives a playable price
    if (-not $o.pointSpread) { return $null }
    $sp = if ($favHome) { $o.pointSpread.home } else { $o.pointSpread.away }
    $other = if ($favHome) { $o.pointSpread.away } else { $o.pointSpread.home }
    $line = Get-Line $sp
    $so = Get-Price $sp
    $oo = Get-Price $other
    if ($null -eq $line -or -not $so -or -not $oo) { return $null }
    $sProb = (Get-FairProbabilities @($so, $oo))[0]
    $lineText = $line.ToString('+0.0;-0.0', $Inv)
    $text = "$fav win $(Pct $favP)% of the time by the odds, so the handicap is the value: $fav $lineText.$total"
    New-Tip $ctx "$fav $lineText" $so $sProb $text 'spread' $favSide $line
}

function New-TennisTip($ctx) {
    $hc = Get-Side $ctx.Comp 'home'
    $ac = Get-Side $ctx.Comp 'away'
    # The feed only ranks the top of the tour; a missing rank says nothing, so both must be ranked
    if (-not ($hc.curatedRank -and $hc.curatedRank.current -and $ac.curatedRank -and $ac.curatedRank.current)) { return $null }
    $rh = [double]$hc.curatedRank.current
    $ra = [double]$ac.curatedRank.current

    # Ranking model: the better-ranked player wins with p = rOther^k / (rFav^k + rOther^k), capped at 85%
    $k = 0.6
    $ph = [Math]::Pow($ra, $k) / ([Math]::Pow($rh, $k) + [Math]::Pow($ra, $k))
    $favHome = $ph -ge 0.5
    $p = [Math]::Min(0.85, $(if ($favHome) { $ph } else { 1 - $ph }))
    if ($p -lt 0.62) { return $null }
    $fav = if ($favHome) { $ctx.Home } else { $ctx.Away }
    $odds = 1 / ($p * 1.05)

    $text = "$($ctx.Home) (#$([int]$rh)) vs $($ctx.Away) (#$([int]$ra)), $($ctx.Round). " +
        "$fav is rated $(Pct $p)% to win from the $($ctx.Tour) rankings. No bookmaker odds in the feed: the odds shown are an estimate."
    New-Tip $ctx "$fav to win" $odds $p $text 'ml' $(if ($favHome) { 'home' } else { 'away' }) $null
}

# ---------- settling ----------

function Get-Outcome($tip, $comp) {
    $type = $comp.status.type
    if ($type.name -match 'POSTPONED|CANCEL|ABANDON|FORFEIT') { return 'VOID' }
    if (-not $type.completed) { return $null }

    $hc = Get-Side $comp 'home'
    $ac = Get-Side $comp 'away'

    if ($tip.sport -eq 'Tennis') {
        $sets = @()
        $hl = @($hc.linescores); $al = @($ac.linescores)
        for ($i = 0; $i -lt [Math]::Min($hl.Count, $al.Count); $i++) { $sets += "$([int]$hl[$i].value)-$([int]$al[$i].value)" }
        $winnerSide = if ($hc.winner) { 'home' } elseif ($ac.winner) { 'away' } else { $null }
        if (-not $winnerSide) { return 'VOID' }
        return @{ status = $(if ($winnerSide -eq $tip.side) { 'WON' } else { 'LOST' }); score = ($sets -join ' ') }
    }

    $h = [int]$hc.score
    $a = [int]$ac.score
    $won = switch ($tip.market) {
        'ml'     { if ($tip.side -eq 'home') { $h -gt $a } else { $a -gt $h } }
        'total'  { if ($tip.side -eq 'over') { ($h + $a) -gt $tip.line } else { ($h + $a) -lt $tip.line } }
        'spread' {
            $mine = if ($tip.side -eq 'home') { $h } else { $a }
            $theirs = if ($tip.side -eq 'home') { $a } else { $h }
            ($mine + $tip.line) -gt $theirs
        }
        default  { $null }
    }
    if ($null -eq $won) { return $null }
    @{ status = $(if ($won) { 'WON' } else { 'LOST' }); score = "$h-$a" }
}

# ---------- load existing tips ----------

$tips = New-Object System.Collections.ArrayList
if (Test-Path $Out) {
    $old = Get-Content $Out -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in @($old.tips)) {
        $h = [ordered]@{}
        foreach ($prop in $t.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
        [void]$tips.Add($h)
    }
}
Write-Host "Loaded $($tips.Count) existing tips."

# ---------- fetch fixtures ----------

$nowUtc = [DateTime]::UtcNow
$dates = @(-3..2 | ForEach-Object { $nowUtc.AddDays($_).ToString('yyyyMMdd', $Inv) })

$contexts = @{}   # competition id -> context

function Add-Context($sport, $path, $league, $comp, $extra) {
    if (-not $comp -or $contexts.ContainsKey("$($comp.id)")) { return }
    $hc = Get-Side $comp 'home'
    $ac = Get-Side $comp 'away'
    if (-not $hc -or -not $ac) { return }
    $ctx = @{
        Sport = $sport; Path = $path; League = $league; Comp = $comp
        Kickoff = ConvertTo-Utc $comp.date
    }
    if ($sport -eq 'Tennis') {
        if (-not $hc.athlete -or -not $ac.athlete) { return }
        $ctx.Home = $hc.athlete.displayName; $ctx.Away = $ac.athlete.displayName
        $ctx.HomeShort = $ctx.Home; $ctx.AwayShort = $ctx.Away
    } else {
        $ctx.Home = $hc.team.displayName; $ctx.Away = $ac.team.displayName
        $ctx.HomeShort = $hc.team.shortDisplayName; $ctx.AwayShort = $ac.team.shortDisplayName
    }
    if (-not $ctx.Home -or -not $ctx.Away -or $ctx.Home -match '^TBD' -or $ctx.Away -match '^TBD') { return }
    foreach ($k in $extra.Keys) { $ctx[$k] = $extra[$k] }
    $contexts["$($comp.id)"] = $ctx
}

foreach ($slug in $FootballLeagues.Keys) {
    foreach ($d in $dates) {
        $j = Get-Json "$Base/soccer/$slug/scoreboard?dates=$d"
        foreach ($ev in @($j.events)) { Add-Context 'Football' "soccer/$slug" $FootballLeagues[$slug] @($ev.competitions)[0] @{} }
    }
}
foreach ($slug in $BasketballLeagues.Keys) {
    foreach ($d in $dates) {
        $j = Get-Json "$Base/basketball/$slug/scoreboard?dates=$d"
        foreach ($ev in @($j.events)) { Add-Context 'Basketball' "basketball/$slug" $BasketballLeagues[$slug] @($ev.competitions)[0] @{} }
    }
}
foreach ($tour in $TennisTours.Keys) {
    foreach ($d in $dates) {
        $j = Get-Json "$Base/tennis/$tour/scoreboard?dates=$d"
        foreach ($ev in @($j.events)) {
            foreach ($g in @($ev.groupings)) {
                if ("$($g.grouping.displayName)" -notmatch 'Singles') { continue }
                foreach ($comp in @($g.competitions)) {
                    Add-Context 'Tennis' "tennis/$tour" "$($TennisTours[$tour]) $($ev.name)" $comp @{ Tour = $TennisTours[$tour]; Round = "$($comp.round.displayName)" }
                }
            }
        }
    }
}
Write-Host "Fetched $($contexts.Count) matches."

# ---------- settle existing tips ----------

$void = @{}
foreach ($t in $tips) {
    if ($t.status -ne 'PENDING' -or -not $t.eventId) { continue }
    $ctx = $contexts["$($t.eventId)"]
    if (-not $ctx) { continue }
    $r = Get-Outcome $t $ctx.Comp
    if ($r -eq 'VOID') { $void[$t.id] = $true }
    elseif ($r) { $t.status = $r.status; $t.score = $r.score }
}

# ---------- create new tips ----------

$known = @{}
foreach ($t in $tips) { if ($t.eventId) { $known["$($t.eventId)"] = $true } }

$candidates = @()
foreach ($ctx in $contexts.Values) {
    if ($known.ContainsKey("$($ctx.Comp.id)")) { continue }
    if ($ctx.Kickoff -le $nowUtc.AddMinutes(10) -or $ctx.Kickoff -gt $nowUtc.AddHours($AheadHours)) { continue }
    if ($ctx.Comp.status.type.state -ne 'pre') { continue }
    $tip = switch ($ctx.Sport) {
        'Football'   { New-FootballTip $ctx }
        'Basketball' { New-BasketballTip $ctx }
        'Tennis'     { New-TennisTip $ctx }
    }
    if ($tip) { $candidates += , $tip }
}

function Get-Day($tip) { $tip.kickoff.Substring(0, 10) }

$perDay = @{}
foreach ($t in $tips) {
    $key = "$(Get-Day $t)|$($t.tier)"
    $perDay[$key] = 1 + [int]$perDay[$key]
}
$added = 0
# Bookmaker-priced picks first; tennis (estimated) is ranked 10 points lower for the Free tab
foreach ($tip in ($candidates | Sort-Object -Property @{ Expression = { $_.confidence - $(if ($_.sport -eq 'Tennis') { 10 } else { 0 }) }; Descending = $true })) {
    $day = Get-Day $tip
    $tier = $null
    if ($tip.confidence -ge 60 -and [int]$perDay["$day|FREE"] -lt $MaxFreePerDay) { $tier = 'FREE' }
    elseif ([int]$perDay["$day|EXTRA"] -lt $MaxExtraPerDay) { $tier = 'EXTRA' }
    if (-not $tier) { continue }
    $tip.tier = $tier
    $perDay["$day|$tier"] = 1 + [int]$perDay["$day|$tier"]
    [void]$tips.Add($tip)
    $added++
}
Write-Host "Added $added new tips."

# ---------- daily combo: three safest bookmaker-priced picks of the day ----------

$nowLocal = Format-Local $nowUtc
$combosByDay = @{}
foreach ($t in $tips) { if ($t.tier -eq 'COMBO') { $combosByDay[(Get-Day $t)] = $true } }
$days = $tips | Where-Object { $_.tier -ne 'COMBO' } | ForEach-Object { Get-Day $_ } | Sort-Object -Unique
foreach ($day in $days) {
    if ($combosByDay.ContainsKey($day)) { continue }
    $legs = $tips | Where-Object {
        (Get-Day $_) -eq $day -and $_.tier -ne 'COMBO' -and $_.status -eq 'PENDING' -and $_.sport -ne 'Tennis' -and
        $_.confidence -ge 60 -and $_.odds -ge 1.25 -and $_.odds -le 1.85 -and $_.kickoff -gt $nowLocal
    } | Sort-Object -Property @{ Expression = { $_.confidence }; Descending = $true } | Select-Object -First 3
    if (@($legs).Count -lt 3) { continue }
    foreach ($leg in $legs) {
        $copy = [ordered]@{}
        foreach ($k in $leg.Keys) { $copy[$k] = $leg[$k] }
        $copy.id = "$($leg.id)-combo"
        $copy.tier = 'COMBO'
        $copy.combo = "combo-$day"
        $copy.comboTitle = 'Daily Combo'
        [void]$tips.Add($copy)
    }
    Write-Host "Created combo for $day."
}

# ---------- prune and write ----------

$cutoff = Format-Local $nowUtc.AddDays(-$KeepDays)
$final = @($tips | Where-Object { -not $void.ContainsKey($_.id) -and -not $void.ContainsKey(($_.id -replace '-combo$', '')) -and $_.kickoff -ge $cutoff } |
    Sort-Object -Property @{ Expression = { $_.kickoff } }, @{ Expression = { $_.id } })

$doc = [ordered]@{
    updated = Format-Local $nowUtc
    source  = 'ESPN fixtures, DraftKings odds; tennis estimated from ATP/WTA rankings'
    tips    = $final
}
$json = ConvertTo-Json $doc -Depth 6
[IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))

$pending = @($final | Where-Object { $_.status -eq 'PENDING' }).Count
Write-Host "Wrote $($final.Count) tips ($pending pending) to $Out"
