#requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------
# Portable paths
# -----------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $ScriptRoot 'Data'
$EmployeesFile = Join-Path $DataDir 'employees.json'
$TasksFile = Join-Path $DataDir 'tasks.json'
$CurrentPlanFile = Join-Path $DataDir 'current-plan.json'
$HistoryFile = Join-Path $DataDir 'history.json'
$SettingsFile = Join-Path $DataDir 'settings.json'

if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir | Out-Null
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path
    )
    ConvertTo-Json -InputObject $Object -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        $DefaultValue
    )
    if (-not (Test-Path $Path)) { return $DefaultValue }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Datei konnte nicht gelesen werden:`n$Path`n`n$($_.Exception.Message)", 'Schichtplaner', 'OK', 'Warning') | Out-Null
        return $DefaultValue
    }
}

function Ensure-InitialFiles {
    if (-not (Test-Path $EmployeesFile)) { Write-JsonFile @() $EmployeesFile }
    if (-not (Test-Path $TasksFile)) { Write-JsonFile @() $TasksFile }
    if (-not (Test-Path $CurrentPlanFile)) { Write-JsonFile ([pscustomobject]@{ Week=''; GeneratedAt=''; Assignments=@(); BaselineAssignments=@(); Absences=@() }) $CurrentPlanFile }
    if (-not (Test-Path $HistoryFile)) { Write-JsonFile @() $HistoryFile }
    if (-not (Test-Path $SettingsFile)) {
        Write-JsonFile ([pscustomobject]@{
            HistoryWeeks = 8
            RecentTaskPenalty = 10
            TwoWeeksAgoPenalty = 5
            ThreeWeeksAgoPenalty = 3
            LoadFactor = 4
            MaxSoftLoad = 999
            BundleBonus = 12
            ShowShiftInOutput = $false
        }) $SettingsFile
    }
}

Ensure-InitialFiles

function As-Array($value) {
    if ($null -eq $value) { return @() }
    return @($value)
}

function Get-WeekKey {
    param([datetime]$Date = (Get-Date))
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $calendar = $culture.Calendar
    $week = $calendar.GetWeekOfYear($Date, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
    return ('{0}-KW{1:00}' -f $Date.Year, $week)
}

function Get-WeekLabel {
    param([datetime]$Date = (Get-Date))
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $calendar = $culture.Calendar
    $week = $calendar.GetWeekOfYear($Date, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
    return ('KW {0:00} / {1}' -f $week, $Date.Year)
}

function New-Id { return [guid]::NewGuid().Guid }

function Load-State {
    $script:Employees = @(Read-JsonFile $EmployeesFile @())
    $script:Tasks = @(Read-JsonFile $TasksFile @())
    # Abwärtskompatibilität: Aufgaben aus älteren Versionen hatten noch kein Enabled-Feld.
    # Solche Aufgaben gelten automatisch als aktiv.
    foreach ($task in $script:Tasks) {
        if ($null -eq $task.PSObject.Properties['Enabled']) {
            $task | Add-Member -NotePropertyName Enabled -NotePropertyValue $true
        }
        # Migration: Frühere Versionen nannten dieses Feld 'ConflictGroup'.
        # Vorhandene Gruppennamen werden übernommen, jetzt aber positiv als Bündelgruppe interpretiert.
        if ($null -eq $task.PSObject.Properties['BundleGroup']) {
            $oldGroup = ''
            if ($null -ne $task.PSObject.Properties['ConflictGroup']) { $oldGroup = [string]$task.ConflictGroup }
            $task | Add-Member -NotePropertyName BundleGroup -NotePropertyValue $oldGroup
        }
    }
    $script:CurrentPlan = Read-JsonFile $CurrentPlanFile ([pscustomobject]@{ Week=''; GeneratedAt=''; Assignments=@(); BaselineAssignments=@(); Absences=@() })
    if ($null -eq $script:CurrentPlan.PSObject.Properties['BaselineAssignments']) {
        # Alte Plaene hatten noch keinen Basisplan. Als bestmoegliche Migration wird der aktuell gespeicherte Plan verwendet.
        $script:CurrentPlan | Add-Member -NotePropertyName BaselineAssignments -NotePropertyValue @(As-Array $script:CurrentPlan.Assignments)
    }
    $script:History = @(Read-JsonFile $HistoryFile @())
    $script:Settings = Read-JsonFile $SettingsFile ([pscustomobject]@{ HistoryWeeks=8; RecentTaskPenalty=10; TwoWeeksAgoPenalty=5; ThreeWeeksAgoPenalty=3; LoadFactor=4; MaxSoftLoad=999; BundleBonus=12; ShowShiftInOutput=$false })
    if ($null -eq $script:Settings.PSObject.Properties['BundleBonus']) { $script:Settings | Add-Member -NotePropertyName BundleBonus -NotePropertyValue 12 }
    if ($null -eq $script:Settings.PSObject.Properties['ShowShiftInOutput']) { $script:Settings | Add-Member -NotePropertyName ShowShiftInOutput -NotePropertyValue $false }
    foreach ($task in $script:Tasks) {
        if ($null -eq $task.PSObject.Properties['MinEarly']) { $task | Add-Member -NotePropertyName MinEarly -NotePropertyValue 0 }
        if ($null -eq $task.PSObject.Properties['MinMiddle']) { $task | Add-Member -NotePropertyName MinMiddle -NotePropertyValue 0 }
        if ($null -eq $task.PSObject.Properties['MinLate']) { $task | Add-Member -NotePropertyName MinLate -NotePropertyValue 0 }
        if ($null -eq $task.PSObject.Properties['TargetAssignees']) { $task | Add-Member -NotePropertyName TargetAssignees -NotePropertyValue ($(if([bool]$task.SLA){2}else{1})) }
        if ($null -eq $task.PSObject.Properties['AssignToAllPresent']) { $task | Add-Member -NotePropertyName AssignToAllPresent -NotePropertyValue $false }
        if ($null -eq $task.PSObject.Properties['IncompatibleTaskIds']) { $task | Add-Member -NotePropertyName IncompatibleTaskIds -NotePropertyValue @() }
        else { $task.IncompatibleTaskIds = @(As-Array $task.IncompatibleTaskIds) }
    }
}

function Save-Employees { Write-JsonFile $script:Employees $EmployeesFile }
function Save-Tasks { Write-JsonFile $script:Tasks $TasksFile }
function Save-CurrentPlan { Write-JsonFile $script:CurrentPlan $CurrentPlanFile }
function Save-History { Write-JsonFile $script:History $HistoryFile }
function Save-Settings { Write-JsonFile $script:Settings $SettingsFile }

Load-State

# -----------------------------
# Planning helpers
# -----------------------------
function Get-HistoryPenalty {
    param(
        [string]$EmployeeId,
        [string]$TaskId,
        [switch]$SlaTask
    )

    $penalty = 0
    $currentWeek = Get-WeekKey
    $ordered = @($script:History | Where-Object { $_.Week -ne $currentWeek } | Sort-Object GeneratedAt -Descending)
    $max = [Math]::Min([int]$script:Settings.HistoryWeeks, $ordered.Count)

    for ($i = 0; $i -lt $max; $i++) {
        $entry = $ordered[$i]
        $assignment = @(As-Array $entry.Assignments | Where-Object { $_.EmployeeId -eq $EmployeeId }) | Select-Object -First 1
        if ($null -ne $assignment -and ((As-Array $assignment.TaskIds) -contains $TaskId)) {
            if ($i -eq 0) { $p = [int]$script:Settings.RecentTaskPenalty }
            elseif ($i -eq 1) { $p = [int]$script:Settings.TwoWeeksAgoPenalty }
            elseif ($i -eq 2) { $p = [int]$script:Settings.ThreeWeeksAgoPenalty }
            else { $p = 1 }

            if ($SlaTask) { $p = [Math]::Max(1, [Math]::Floor($p / 3)) }
            $penalty += $p
        }
    }
    return $penalty
}

function Get-EmployeeLoad {
    param([hashtable]$PlanMap, [string]$EmployeeId)
    if (-not $PlanMap.ContainsKey($EmployeeId)) { return 0 }
    $load = 0
    foreach ($taskId in @($PlanMap[$EmployeeId])) {
        $task = @($script:Tasks | Where-Object Id -eq $taskId) | Select-Object -First 1
        if ($task -and (Test-TaskEnabled $task)) { $load += [int]$task.Weight }
    }
    return $load
}

function Can-EmployeeDoTask {
    param($Employee, $Task)
    $excluded = As-Array $Employee.ExcludedTaskIds
    return -not ($excluded -contains $Task.Id)
}

function Test-TaskEnabled {
    param($Task)
    if ($null -eq $Task) { return $false }
    if ($null -eq $Task.PSObject.Properties['Enabled']) { return $true }
    return [bool]$Task.Enabled
}

function Remove-TaskFromCurrentPlan {
    param([string]$TaskId)
    if ($null -eq $script:CurrentPlan -or (As-Array $script:CurrentPlan.Assignments).Count -eq 0) { return }
    $changed = $false
    foreach ($assignment in (As-Array $script:CurrentPlan.Assignments)) {
        $oldIds = @(As-Array $assignment.TaskIds)
        $newIds = @($oldIds | Where-Object { $_ -ne $TaskId })
        if ($newIds.Count -ne $oldIds.Count) {
            $assignment.TaskIds = $newIds
            $changed = $true
        }
    }
    if ($changed) {
        $script:CurrentPlan.GeneratedAt = (Get-Date).ToString('s')
        Save-CurrentPlan
        Commit-PlanToHistory $script:CurrentPlan
    }
}

function Test-TaskPairCompatible {
    param($TaskA,$TaskB)
    if ($null -eq $TaskA -or $null -eq $TaskB) { return $true }
    if ($TaskA.Id -eq $TaskB.Id) { return $true }
    $aBlocks = @(As-Array $TaskA.IncompatibleTaskIds)
    $bBlocks = @(As-Array $TaskB.IncompatibleTaskIds)
    return (-not ($aBlocks -contains $TaskB.Id) -and -not ($bBlocks -contains $TaskA.Id))
}

function Test-EmployeeTaskCombinationAllowed {
    param([hashtable]$PlanMap,[string]$EmployeeId,$Task)
    foreach ($assignedTaskId in @(As-Array $PlanMap[$EmployeeId])) {
        $assignedTask = @($script:Tasks | Where-Object Id -eq $assignedTaskId) | Select-Object -First 1
        if ($assignedTask -and (Test-TaskEnabled $assignedTask)) {
            if (-not (Test-TaskPairCompatible $Task $assignedTask)) { return $false }
        }
    }
    return $true
}

function Get-BundleBonus {
    param(
        [hashtable]$PlanMap,
        [string]$EmployeeId,
        $Task
    )
    if ($null -eq $Task -or [string]::IsNullOrWhiteSpace([string]$Task.BundleGroup)) { return 0 }
    $group = ([string]$Task.BundleGroup).Trim()
    $matches = 0
    foreach ($assignedTaskId in @(As-Array $PlanMap[$EmployeeId])) {
        $assignedTask = @($script:Tasks | Where-Object Id -eq $assignedTaskId) | Select-Object -First 1
        if ($assignedTask -and (Test-TaskEnabled $assignedTask) -and -not [string]::IsNullOrWhiteSpace([string]$assignedTask.BundleGroup)) {
            if (([string]$assignedTask.BundleGroup).Trim() -ieq $group -and $assignedTask.Id -ne $Task.Id) { $matches++ }
        }
    }
    # Ein Bonus senkt den Score: Aufgaben derselben Bündelgruppe landen dadurch bevorzugt zusammen.
    # Es bleibt eine weiche Regel; hohe Last, SLA/Schicht oder Ausschlüsse können stärker sein.
    return ($matches * [int]$script:Settings.BundleBonus)
}

function Select-BestEmployee {
    param(
        [array]$Candidates,
        $Task,
        [hashtable]$PlanMap,
        [switch]$SlaTask
    )

    $best = $null
    $bestScore = [double]::PositiveInfinity

    foreach ($emp in $Candidates) {
        if (-not (Can-EmployeeDoTask $emp $Task)) { continue }
        if (-not (Test-EmployeeTaskCombinationAllowed -PlanMap $PlanMap -EmployeeId $emp.Id -Task $Task)) { continue }
        $load = Get-EmployeeLoad $PlanMap $emp.Id
        $history = Get-HistoryPenalty -EmployeeId $emp.Id -TaskId $Task.Id -SlaTask:$SlaTask
        $sameTaskAlready = if ((@($PlanMap[$emp.Id]) -contains $Task.Id)) { 1000 } else { 0 }
        $bundleBonus = Get-BundleBonus -PlanMap $PlanMap -EmployeeId $emp.Id -Task $Task
        $score = ($load * [int]$script:Settings.LoadFactor) + $history + $sameTaskAlready - $bundleBonus

        if ($score -lt $bestScore) {
            $best = $emp
            $bestScore = $score
        }
        elseif ($score -eq $bestScore -and $best) {
            $bestLoad = Get-EmployeeLoad $PlanMap $best.Id
            if ($load -lt $bestLoad) { $best = $emp }
            elseif ($load -eq $bestLoad -and (Get-Random -Minimum 0 -Maximum 2) -eq 1) { $best = $emp }
        }
    }
    return $best
}

function Add-TaskToPlan {
    param([hashtable]$PlanMap, [string]$EmployeeId, [string]$TaskId)
    if (-not $PlanMap.ContainsKey($EmployeeId)) { $PlanMap[$EmployeeId] = New-Object System.Collections.ArrayList }
    if (-not (@($PlanMap[$EmployeeId]) -contains $TaskId)) { [void]$PlanMap[$EmployeeId].Add($TaskId) }
}

function Get-TaskMinimumForShift {
    param($Task,[string]$Shift)
    $configured = 0
    if ($Shift -eq 'Früh') { $configured = [int]$Task.MinEarly }
    elseif ($Shift -eq 'Mitte') { $configured = [int]$Task.MinMiddle }
    elseif ($Shift -eq 'Spät') { $configured = [int]$Task.MinLate }
    if ([bool]$Task.SLA -and ($Shift -eq 'Früh' -or $Shift -eq 'Spät')) { return [Math]::Max(1,$configured) }
    return $configured
}

function Ensure-TaskCoverage {
    param([hashtable]$PlanMap,[array]$Available,$Task,[System.Collections.ArrayList]$Warnings)
    foreach($shift in @('Früh','Mitte','Spät')){
        $required=Get-TaskMinimumForShift $Task $shift
        if($required -le 0){continue}
        $already=@($Available | Where-Object { $_.Shift -eq $shift -and (@($PlanMap[$_.Id]) -contains $Task.Id) }).Count
        for($i=$already;$i -lt $required;$i++){
            $candidates=@($Available | Where-Object { $_.Shift -eq $shift -and -not (@($PlanMap[$_.Id]) -contains $Task.Id) })
            if($candidates.Count -eq 0){ [void]$Warnings.Add("Aufgabe '$($Task.Name)': Mindestabdeckung '$shift' ($required) nicht vollständig möglich."); break }
            $selected=Select-BestEmployee -Candidates $candidates -Task $Task -PlanMap $PlanMap -SlaTask:([bool]$Task.SLA)
            if($selected){Add-TaskToPlan $PlanMap $selected.Id $Task.Id}else{[void]$Warnings.Add("Aufgabe '$($Task.Name)' konnte für '$shift' nicht zugewiesen werden (Ausschluss oder 'Nicht kombinieren mit'-Sperre).");break}
        }
    }
    if ([bool]$Task.AssignToAllPresent) {
        $target = @($Available).Count
    } else {
        $target = [Math]::Max(1,[int]$Task.TargetAssignees)
    }
    $minTotal=(Get-TaskMinimumForShift $Task 'Früh')+(Get-TaskMinimumForShift $Task 'Mitte')+(Get-TaskMinimumForShift $Task 'Spät')
    $target=[Math]::Max($target,$minTotal)
    $current=@($Available | Where-Object { @($PlanMap[$_.Id]) -contains $Task.Id }).Count
    while($current -lt $target){
        $candidates=@($Available | Where-Object { -not (@($PlanMap[$_.Id]) -contains $Task.Id) })
        if($candidates.Count -eq 0){[void]$Warnings.Add("Aufgabe '$($Task.Name)': gewünschte Gesamtanzahl $target nicht vollständig möglich.");break}
        $selected=Select-BestEmployee -Candidates $candidates -Task $Task -PlanMap $PlanMap -SlaTask:([bool]$Task.SLA)
        if(-not $selected){[void]$Warnings.Add("Aufgabe '$($Task.Name)' konnte nicht weiter verteilt werden (Ausschluss oder 'Nicht kombinieren mit'-Sperre).");break}
        Add-TaskToPlan $PlanMap $selected.Id $Task.Id
        $current++
    }
}

function Generate-WeeklyPlan {
    param([array]$WeekEmployees)
    $available=@($WeekEmployees | Where-Object {$_.Present -eq $true})
    if($available.Count -eq 0){throw 'Es ist kein anwesender Mitarbeiter ausgewählt.'}
    $activeTasks=@($script:Tasks | Where-Object {Test-TaskEnabled $_})
    if($activeTasks.Count -eq 0){throw 'Es ist aktuell keine Aufgabe aktiviert.'}
    $plan=@{}; foreach($emp in $available){$plan[$emp.Id]=New-Object System.Collections.ArrayList}
    $warnings=New-Object System.Collections.ArrayList
    $ordered=@($activeTasks | Sort-Object @{Expression={if($_.SLA){0}else{1}}}, @{Expression={[int]$_.Weight};Descending=$true})
    foreach($task in $ordered){Ensure-TaskCoverage -PlanMap $plan -Available $available -Task $task -Warnings $warnings}
    $assignments=@()
    foreach($emp in $WeekEmployees){
        $taskIds=if($plan.ContainsKey($emp.Id)){@($plan[$emp.Id])}else{@()}
        $assignments += [pscustomobject]@{EmployeeId=$emp.Id;EmployeeName=$emp.Name;Shift=$emp.Shift;Present=[bool]$emp.Present;TaskIds=$taskIds}
    }
    return [pscustomobject]@{Assignments=$assignments;Warnings=@($warnings)}
}

function Rebalance-Availability {
    param([array]$WeekEmployees)

    $currentAssignments = @(As-Array $script:CurrentPlan.Assignments)
    if ($currentAssignments.Count -eq 0) { throw 'Es gibt noch keinen aktuellen Wochenplan.' }

    # Der Basisplan ist der urspruengliche Wochenplan. Dadurch kann eine nach Krankheit
    # zurueckgekehrte Person ihre urspruenglichen Aufgaben wiederbekommen, ohne dass die
    # komplette Woche neu gewuerfelt wird. Bei alten Dateien dient der aktuelle Plan als Basis.
    $baselineAssignments = @(As-Array $script:CurrentPlan.BaselineAssignments)
    if ($baselineAssignments.Count -eq 0) { $baselineAssignments = @($currentAssignments) }
    $sourceAssignments = $baselineAssignments

    # Die Anwesenheits-Haekchen im Hauptfenster sind die aktuelle Wahrheit.
    # Wir bauen den laufenden Plan aus dem stabilen Basisplan neu auf und reparieren nur
    # die Abdeckung, die durch aktuell abwesende Personen fehlt.
    $weekMap = @{}
    foreach ($emp in @(As-Array $WeekEmployees)) { $weekMap[$emp.Id] = $emp }

    $lostTasks = New-Object System.Collections.ArrayList
    $conflictRepairs = New-Object System.Collections.ArrayList
    $plan = @{}
    $availableEmployees = @()
    $newAssignments = @()
    $absences = New-Object System.Collections.ArrayList

    foreach ($a in $sourceAssignments) {
        $weekEmp = if ($weekMap.ContainsKey($a.EmployeeId)) { $weekMap[$a.EmployeeId] } else { $null }
        $isPresent = ($null -ne $weekEmp -and [bool]$weekEmp.Present)
        $shift = if ($null -ne $weekEmp) { [string]$weekEmp.Shift } else { [string]$a.Shift }
        if ([string]::IsNullOrWhiteSpace($shift)) { $shift = 'Früh' }

        if ($isPresent) {
            $list = New-Object System.Collections.ArrayList
            # Bestehende Basiszuweisungen werden gegen neue harte Kombinationssperren geprüft.
            # Höhere Priorität bleibt: SLA zuerst, danach höheres Gewicht.
            $baselineTasks = @()
            foreach ($tid in @(As-Array $a.TaskIds)) {
                $task = @($script:Tasks | Where-Object Id -eq $tid) | Select-Object -First 1
                if ($task -and (Test-TaskEnabled $task)) { $baselineTasks += $task }
            }
            $baselineTasks = @($baselineTasks | Sort-Object @{Expression={if($_.SLA){0}else{1}}}, @{Expression={[int]$_.Weight};Descending=$true}, @{Expression={$_.Name}})
            $tempPlan = @{}; $tempPlan[$a.EmployeeId] = $list
            foreach ($task in $baselineTasks) {
                if (Test-EmployeeTaskCombinationAllowed -PlanMap $tempPlan -EmployeeId $a.EmployeeId -Task $task) {
                    [void]$list.Add($task.Id)
                } else {
                    [void]$lostTasks.Add([pscustomobject]@{ TaskId=$task.Id; OriginShift=$shift })
                    [void]$conflictRepairs.Add("'$($task.Name)' wurde bei '$($a.EmployeeName)' wegen einer harten Kombinationssperre entfernt und neu verteilt.")
                }
            }
            $plan[$a.EmployeeId] = $list

            $empMaster = @($script:Employees | Where-Object Id -eq $a.EmployeeId) | Select-Object -First 1
            if ($empMaster) {
                $availableEmployees += [pscustomobject]@{
                    Id=$empMaster.Id; Name=$empMaster.Name; ExcludedTaskIds=(As-Array $empMaster.ExcludedTaskIds); Shift=$shift; Present=$true
                }
            }

            $newAssignments += [pscustomobject]@{
                EmployeeId=$a.EmployeeId; EmployeeName=$a.EmployeeName; Shift=$shift; Present=$true; TaskIds=@()
            }
        }
        else {
            foreach ($tid in @(As-Array $a.TaskIds)) {
                $task = @($script:Tasks | Where-Object Id -eq $tid) | Select-Object -First 1
                if ($task -and (Test-TaskEnabled $task)) {
                    [void]$lostTasks.Add([pscustomobject]@{ TaskId=$tid; OriginShift=$shift })
                }
            }
            if (-not (@($absences) -contains $a.EmployeeId)) { [void]$absences.Add($a.EmployeeId) }
            $newAssignments += [pscustomobject]@{
                EmployeeId=$a.EmployeeId; EmployeeName=$a.EmployeeName; Shift=$shift; Present=$false; TaskIds=@()
            }
        }
    }

    # Falls seit der Planerstellung ein Mitarbeiter im Hauptfenster auftaucht, der im
    # aktuellen Plan noch nicht enthalten war, kann er trotzdem als Kandidat helfen.
    foreach ($weekEmp in @(As-Array $WeekEmployees)) {
        if (-not [bool]$weekEmp.Present) { continue }
        if (@($newAssignments | Where-Object EmployeeId -eq $weekEmp.Id).Count -gt 0) { continue }

        $empMaster = @($script:Employees | Where-Object Id -eq $weekEmp.Id) | Select-Object -First 1
        if (-not $empMaster) { continue }
        $shift = [string]$weekEmp.Shift; if ([string]::IsNullOrWhiteSpace($shift)) { $shift='Früh' }
        $plan[$weekEmp.Id] = New-Object System.Collections.ArrayList
        $availableEmployees += [pscustomobject]@{
            Id=$empMaster.Id; Name=$empMaster.Name; ExcludedTaskIds=(As-Array $empMaster.ExcludedTaskIds); Shift=$shift; Present=$true
        }
        $newAssignments += [pscustomobject]@{
            EmployeeId=$empMaster.Id; EmployeeName=$empMaster.Name; Shift=$shift; Present=$true; TaskIds=@()
        }
    }

    $warnings = New-Object System.Collections.ArrayList
    foreach($msg in @($conflictRepairs)){[void]$warnings.Add($msg)}
    # Nach einem Ausfall bleiben bestehende Zuweisungen erhalten. Danach wird für jede aktive Aufgabe
    # nur fehlende Mindest-/Zielabdeckung ergänzt. So können auch mehrere Ausfälle gleichzeitig repariert werden.
    foreach($task in @($script:Tasks | Where-Object {Test-TaskEnabled $_} | Sort-Object @{Expression={if($_.SLA){0}else{1}}}, @{Expression={[int]$_.Weight};Descending=$true})){
        Ensure-TaskCoverage -PlanMap $plan -Available $availableEmployees -Task $task -Warnings $warnings
    }

    foreach ($a in $newAssignments) {
        if ($a.Present -eq $true -and $plan.ContainsKey($a.EmployeeId)) { $a.TaskIds = @($plan[$a.EmployeeId]) }
        else { $a.TaskIds = @() }
    }

    $script:CurrentPlan.Assignments = @($newAssignments)
    $script:CurrentPlan.Absences = @($absences)
    $script:CurrentPlan.GeneratedAt = (Get-Date).ToString('s')
    Save-CurrentPlan
    Commit-PlanToHistory $script:CurrentPlan

    if ($lostTasks.Count -eq 0) {
        [void]$warnings.Add('Es wurden keine Aufgaben von ausgefallenen Personen gefunden. Anwesenheit und Schichten wurden trotzdem aktualisiert.')
    }
    return @($warnings)
}

function Commit-PlanToHistory {
    param($PlanObject)
    $week = $PlanObject.Week
    $withoutSameWeek = @($script:History | Where-Object Week -ne $week)
    $script:History = @($withoutSameWeek + $PlanObject | Sort-Object GeneratedAt -Descending | Select-Object -First ([int]$script:Settings.HistoryWeeks))
    Save-History
}

function Format-PlanText {
    param($PlanObject)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("Wochenplan $(Get-WeekLabel)")
    [void]$lines.Add('')

    foreach ($a in (As-Array $PlanObject.Assignments)) {
        $taskObjects = @()
        foreach ($tid in (As-Array $a.TaskIds)) {
            $task = @($script:Tasks | Where-Object Id -eq $tid) | Select-Object -First 1
            if ($task -and (Test-TaskEnabled $task)) { $taskObjects += $task }
        }
        $taskObjects = @($taskObjects | Sort-Object @{Expression={if($_.SLA){0}else{1}}}, @{Expression={[int]$_.Weight};Descending=$true}, @{Expression={$_.Name}})
        $taskNames = @($taskObjects | ForEach-Object { $_.Name })
        if ($a.Present -eq $false) {
            [void]$lines.Add("$($a.EmployeeName): ABWESEND")
        } else {
            $displayName = $a.EmployeeName
            if ([bool]$script:Settings.ShowShiftInOutput) { $displayName = "$displayName ($($a.Shift))" }
            if ($taskNames.Count -eq 0) { [void]$lines.Add("${displayName}: keine feste Aufgabe") }
            else { [void]$lines.Add("${displayName}: $($taskNames -join ', ')") }
        }
    }
    return ($lines -join [Environment]::NewLine)
}

# -----------------------------
# UI helpers
# -----------------------------
function Show-InputDialog {
    param([string]$Title, [string]$Label, [string]$Default='')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.Width=430; $f.Height=170; $f.StartPosition='CenterParent'
    $l = New-Object System.Windows.Forms.Label; $l.Text=$Label; $l.Left=12; $l.Top=15; $l.Width=390
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Left=12; $tb.Top=42; $tb.Width=390; $tb.Text=$Default
    $ok = New-Object System.Windows.Forms.Button; $ok.Text='OK'; $ok.Left=245; $ok.Top=78; $ok.Width=75; $ok.DialogResult=[System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text='Abbrechen'; $cancel.Left=327; $cancel.Top=78; $cancel.Width=75; $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($l,$tb,$ok,$cancel)); $f.AcceptButton=$ok; $f.CancelButton=$cancel
    $r = $f.ShowDialog()
    if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text.Trim() }
    return $null
}

function Show-EmployeeManager {
    $form = New-Object System.Windows.Forms.Form
    $form.Text='Mitarbeiter verwalten'; $form.Width=720; $form.Height=430; $form.StartPosition='CenterParent'
    $list = New-Object System.Windows.Forms.ListView
    $list.View='Details'; $list.FullRowSelect=$true; $list.GridLines=$true; $list.Left=10; $list.Top=10; $list.Width=680; $list.Height=310
    [void]$list.Columns.Add('Name',260); [void]$list.Columns.Add('Ausgeschlossene Aufgaben',390)

    function Refresh-EmpList {
        $list.Items.Clear()
        foreach ($emp in $script:Employees) {
            $names = @()
            foreach ($tid in (As-Array $emp.ExcludedTaskIds)) {
                $t = @($script:Tasks | Where-Object Id -eq $tid) | Select-Object -First 1
                if ($t) { $names += $t.Name }
            }
            $it = New-Object System.Windows.Forms.ListViewItem($emp.Name)
            [void]$it.SubItems.Add(($names -join ', ')); $it.Tag=$emp.Id; [void]$list.Items.Add($it)
        }
    }

    $add = New-Object System.Windows.Forms.Button; $add.Text='Hinzufügen'; $add.Left=10; $add.Top=335; $add.Width=100
    $rename = New-Object System.Windows.Forms.Button; $rename.Text='Umbenennen'; $rename.Left=118; $rename.Top=335; $rename.Width=100
    $exclude = New-Object System.Windows.Forms.Button; $exclude.Text='Ausschlüsse'; $exclude.Left=226; $exclude.Top=335; $exclude.Width=100
    $remove = New-Object System.Windows.Forms.Button; $remove.Text='Entfernen'; $remove.Left=334; $remove.Top=335; $remove.Width=100
    $close = New-Object System.Windows.Forms.Button; $close.Text='Schließen'; $close.Left=590; $close.Top=335; $close.Width=100

    $add.Add_Click({
        $name = Show-InputDialog 'Mitarbeiter hinzufügen' 'Name:'
        if ($name) { $script:Employees = @($script:Employees) + [pscustomobject]@{ Id=(New-Id); Name=$name; ExcludedTaskIds=@() }; Save-Employees; Refresh-EmpList }
    })
    $rename.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $id=$list.SelectedItems[0].Tag; $emp=@($script:Employees | Where-Object Id -eq $id) | Select-Object -First 1
        $name=Show-InputDialog 'Mitarbeiter umbenennen' 'Name:' $emp.Name
        if ($name) { $emp.Name=$name; Save-Employees; Refresh-EmpList }
    })
    $remove.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $id=$list.SelectedItems[0].Tag
        if ([System.Windows.Forms.MessageBox]::Show('Mitarbeiter wirklich entfernen?','Bestätigen','YesNo','Question') -eq 'Yes') {
            $script:Employees=@($script:Employees | Where-Object Id -ne $id); Save-Employees; Refresh-EmpList
        }
    })
    $exclude.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $id=$list.SelectedItems[0].Tag; $emp=@($script:Employees | Where-Object Id -eq $id) | Select-Object -First 1
        $ef = New-Object System.Windows.Forms.Form; $ef.Text="Ausschlüsse - $($emp.Name)"; $ef.Width=450; $ef.Height=420; $ef.StartPosition='CenterParent'
        $clb=New-Object System.Windows.Forms.CheckedListBox; $clb.Left=10; $clb.Top=10; $clb.Width=410; $clb.Height=320
        foreach($t in $script:Tasks){ $idx=$clb.Items.Add($t.Name); if((As-Array $emp.ExcludedTaskIds) -contains $t.Id){$clb.SetItemChecked($idx,$true)} }
        $ok=New-Object System.Windows.Forms.Button; $ok.Text='Speichern'; $ok.Left=250; $ok.Top=340; $ok.Width=80
        $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='Abbrechen'; $cancel.Left=340; $cancel.Top=340; $cancel.Width=80
        $ok.Add_Click({
            $ids=@(); for($i=0;$i -lt $clb.Items.Count;$i++){ if($clb.GetItemChecked($i)){ $ids += $script:Tasks[$i].Id } }
            $emp.ExcludedTaskIds=$ids; Save-Employees; $ef.Close(); Refresh-EmpList
        }); $cancel.Add_Click({$ef.Close()})
        $ef.Controls.AddRange(@($clb,$ok,$cancel)); [void]$ef.ShowDialog($form)
    })
    $close.Add_Click({$form.Close()})
    $form.Controls.AddRange(@($list,$add,$rename,$exclude,$remove,$close)); Refresh-EmpList; [void]$form.ShowDialog()
}

function Show-TaskManager {
    $form=New-Object System.Windows.Forms.Form; $form.Text='Aufgaben verwalten'; $form.Width=1120; $form.Height=520; $form.StartPosition='CenterParent'
    $list=New-Object System.Windows.Forms.ListView; $list.View='Details'; $list.FullRowSelect=$true; $list.GridLines=$true; $list.Left=10; $list.Top=10; $list.Width=1080; $list.Height=370
    [void]$list.Columns.Add('Aufgabe',210);[void]$list.Columns.Add('Aktiv',50);[void]$list.Columns.Add('SLA',50);[void]$list.Columns.Add('Gew.',50);[void]$list.Columns.Add('Bündelgruppe',150);[void]$list.Columns.Add('Nicht kombinieren mit',250);[void]$list.Columns.Add('Früh min.',65);[void]$list.Columns.Add('Mitte min.',70);[void]$list.Columns.Add('Spät min.',65);[void]$list.Columns.Add('Ziel',55);[void]$list.Columns.Add('Alle',45)
    function Refresh-TaskList {
        $list.Items.Clear()
        foreach($t in $script:Tasks){
            $blockedNames=@()
            foreach($bid in @(As-Array $t.IncompatibleTaskIds)){
                $bt=@($script:Tasks|Where-Object Id -eq $bid)|Select-Object -First 1
                if($bt){$blockedNames += $bt.Name}
            }
            $it=New-Object System.Windows.Forms.ListViewItem($t.Name)
            [void]$it.SubItems.Add($(if(Test-TaskEnabled $t){'Ja'}else{'Nein'}));[void]$it.SubItems.Add($(if($t.SLA){'Ja'}else{'Nein'}));[void]$it.SubItems.Add([string]$t.Weight);[void]$it.SubItems.Add([string]$t.BundleGroup);[void]$it.SubItems.Add(($blockedNames -join ', '));[void]$it.SubItems.Add([string]$t.MinEarly);[void]$it.SubItems.Add([string]$t.MinMiddle);[void]$it.SubItems.Add([string]$t.MinLate);[void]$it.SubItems.Add([string]$t.TargetAssignees);[void]$it.SubItems.Add($(if([bool]$t.AssignToAllPresent){'Ja'}else{'Nein'}));$it.Tag=$t.Id;[void]$list.Items.Add($it)
        }
    }
    $add=New-Object System.Windows.Forms.Button;$add.Text='Hinzufügen';$add.Left=10;$add.Top=395;$add.Width=100
    $edit=New-Object System.Windows.Forms.Button;$edit.Text='Bearbeiten';$edit.Left=118;$edit.Top=395;$edit.Width=100
    $toggle=New-Object System.Windows.Forms.Button;$toggle.Text='Aktiv / Deaktiv';$toggle.Left=226;$toggle.Top=395;$toggle.Width=120
    $remove=New-Object System.Windows.Forms.Button;$remove.Text='Entfernen';$remove.Left=354;$remove.Top=395;$remove.Width=100
    $close=New-Object System.Windows.Forms.Button;$close.Text='Schließen';$close.Left=990;$close.Top=395;$close.Width=100

    function Edit-Task($task) {
        $tf=New-Object System.Windows.Forms.Form;$tf.Text=$(if($task){'Aufgabe bearbeiten'}else{'Aufgabe hinzufügen'});$tf.Width=660;$tf.Height=650;$tf.StartPosition='CenterParent'
        $l1=New-Object System.Windows.Forms.Label;$l1.Text='Name:';$l1.Left=12;$l1.Top=18;$l1.Width=110
        $name=New-Object System.Windows.Forms.TextBox;$name.Left=135;$name.Top=15;$name.Width=480;if($task){$name.Text=$task.Name}
        $enabled=New-Object System.Windows.Forms.CheckBox;$enabled.Text='Aufgabe aktiv';$enabled.Left=135;$enabled.Top=52;$enabled.Checked=$(if($task){Test-TaskEnabled $task}else{$true})
        $sla=New-Object System.Windows.Forms.CheckBox;$sla.Text='SLA-relevant';$sla.Left=285;$sla.Top=52;if($task){$sla.Checked=[bool]$task.SLA}
        $l2=New-Object System.Windows.Forms.Label;$l2.Text='Gewicht:';$l2.Left=12;$l2.Top=92;$l2.Width=110
        $weight=New-Object System.Windows.Forms.NumericUpDown;$weight.Left=135;$weight.Top=89;$weight.Minimum=1;$weight.Maximum=20;$weight.Value=$(if($task){[decimal]$task.Weight}else{1})
        $hint=New-Object System.Windows.Forms.Label;$hint.Text='1 = leicht, höhere Zahl = mehr Arbeitslast';$hint.Left=245;$hint.Top=92;$hint.Width=320
        $l3=New-Object System.Windows.Forms.Label;$l3.Text='Bündelgruppe:';$l3.Left=12;$l3.Top=133;$l3.Width=110
        $group=New-Object System.Windows.Forms.ComboBox;$group.Left=135;$group.Top=129;$group.Width=480;$group.DropDownStyle='DropDown';$existingGroups=@($script:Tasks|ForEach-Object{[string]$_.BundleGroup}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);if($existingGroups.Count){[void]$group.Items.AddRange([object[]]$existingGroups)};if($task){$group.Text=[string]$task.BundleGroup}
        $groupHint=New-Object System.Windows.Forms.Label;$groupHint.Text='Gleiche Bündelgruppe = bevorzugt zusammen (weiche Regel).';$groupHint.Left=135;$groupHint.Top=157;$groupHint.Width=480

        $blockLabel=New-Object System.Windows.Forms.Label;$blockLabel.Text='Nicht kombinieren mit:';$blockLabel.Left=12;$blockLabel.Top=195;$blockLabel.Width=120
        $blocked=New-Object System.Windows.Forms.CheckedListBox;$blocked.Left=135;$blocked.Top=190;$blocked.Width=480;$blocked.Height=120;$blocked.CheckOnClick=$true
        $otherTasks=@($script:Tasks|Where-Object{$null -eq $task -or $_.Id -ne $task.Id}|Sort-Object Name)
        foreach($ot in $otherTasks){$idx=$blocked.Items.Add($ot.Name);if($task -and ((As-Array $task.IncompatibleTaskIds)-contains $ot.Id)){$blocked.SetItemChecked($idx,$true)}}
        $blockHint=New-Object System.Windows.Forms.Label;$blockHint.Text='Harte Sperre: Diese Aufgaben dürfen nicht bei derselben Person liegen.';$blockHint.Left=135;$blockHint.Top=315;$blockHint.Width=480

        $cov=New-Object System.Windows.Forms.GroupBox;$cov.Text='Schichtabdeckung';$cov.Left=12;$cov.Top=350;$cov.Width=603;$cov.Height=145
        $le=New-Object System.Windows.Forms.Label;$le.Text='Früh min.';$le.Left=18;$le.Top=31;$le.Width=70
        $early=New-Object System.Windows.Forms.NumericUpDown;$early.Left=88;$early.Top=28;$early.Minimum=0;$early.Maximum=20;$early.Width=55;$early.Value=$(if($task){[decimal]$task.MinEarly}else{0})
        $lm=New-Object System.Windows.Forms.Label;$lm.Text='Mitte min.';$lm.Left=175;$lm.Top=31;$lm.Width=70
        $middle=New-Object System.Windows.Forms.NumericUpDown;$middle.Left=245;$middle.Top=28;$middle.Minimum=0;$middle.Maximum=20;$middle.Width=55;$middle.Value=$(if($task){[decimal]$task.MinMiddle}else{0})
        $ll=New-Object System.Windows.Forms.Label;$ll.Text='Spät min.';$ll.Left=330;$ll.Top=31;$ll.Width=65
        $late=New-Object System.Windows.Forms.NumericUpDown;$late.Left=395;$late.Top=28;$late.Minimum=0;$late.Maximum=20;$late.Width=55;$late.Value=$(if($task){[decimal]$task.MinLate}else{0})
        $lt=New-Object System.Windows.Forms.Label;$lt.Text='Gewünschte Mitarbeiter gesamt:';$lt.Left=18;$lt.Top=76;$lt.Width=205
        $target=New-Object System.Windows.Forms.NumericUpDown;$target.Left=225;$target.Top=73;$target.Minimum=1;$target.Maximum=50;$target.Width=60;$target.Value=$(if($task){[decimal]$task.TargetAssignees}else{1})
        $all=New-Object System.Windows.Forms.CheckBox;$all.Text='Allen anwesenden Mitarbeitern zuweisen';$all.Left=18;$all.Top=108;$all.Width=270;$all.Checked=$(if($task){[bool]$task.AssignToAllPresent}else{$false})
        $allHint=New-Object System.Windows.Forms.Label;$allHint.Text='Dann wird die Zielanzahl automatisch aus der aktuellen Anwesenheit berechnet.';$allHint.Left=300;$allHint.Top=109;$allHint.Width=285
        $all.Add_CheckedChanged({$target.Enabled=-not $all.Checked})
        $target.Enabled=-not $all.Checked
        $cov.Controls.AddRange(@($le,$early,$lm,$middle,$ll,$late,$lt,$target,$all,$allHint))

        $ok=New-Object System.Windows.Forms.Button;$ok.Text='Speichern';$ok.Left=445;$ok.Top=525;$ok.Width=80
        $cancel=New-Object System.Windows.Forms.Button;$cancel.Text='Abbrechen';$cancel.Left=535;$cancel.Top=525;$cancel.Width=80
        $ok.Add_Click({
            if([string]::IsNullOrWhiteSpace($name.Text)){return}
            $blockedIds=@()
            for($i=0;$i -lt $blocked.Items.Count;$i++){if($blocked.GetItemChecked($i)){$blockedIds += $otherTasks[$i].Id}}
            if($task){
                $wasEnabled=Test-TaskEnabled $task;$task.Name=$name.Text.Trim();$task.Enabled=[bool]$enabled.Checked;$task.SLA=[bool]$sla.Checked;$task.Weight=[int]$weight.Value;$task.BundleGroup=$group.Text.Trim();$task.IncompatibleTaskIds=@($blockedIds);$task.MinEarly=[int]$early.Value;$task.MinMiddle=[int]$middle.Value;$task.MinLate=[int]$late.Value;$task.TargetAssignees=[int]$target.Value;$task.AssignToAllPresent=[bool]$all.Checked;if($wasEnabled -and -not $task.Enabled){Remove-TaskFromCurrentPlan $task.Id}
            }else{
                $script:Tasks=@($script:Tasks)+[pscustomobject]@{Id=(New-Id);Name=$name.Text.Trim();Enabled=[bool]$enabled.Checked;SLA=[bool]$sla.Checked;Weight=[int]$weight.Value;BundleGroup=$group.Text.Trim();IncompatibleTaskIds=@($blockedIds);MinEarly=[int]$early.Value;MinMiddle=[int]$middle.Value;MinLate=[int]$late.Value;TargetAssignees=[int]$target.Value;AssignToAllPresent=[bool]$all.Checked}
            }
            Save-Tasks;$tf.Close();Refresh-TaskList
        })
        $cancel.Add_Click({$tf.Close()})
        $tf.Controls.AddRange(@($l1,$name,$enabled,$sla,$l2,$weight,$hint,$l3,$group,$groupHint,$blockLabel,$blocked,$blockHint,$cov,$ok,$cancel));[void]$tf.ShowDialog($form)
    }
    $add.Add_Click({Edit-Task $null})
    $edit.Add_Click({if($list.SelectedItems.Count){$id=$list.SelectedItems[0].Tag;$t=@($script:Tasks|Where-Object Id -eq $id)|Select-Object -First 1;Edit-Task $t}})
    $toggle.Add_Click({if($list.SelectedItems.Count){$id=$list.SelectedItems[0].Tag;$t=@($script:Tasks|Where-Object Id -eq $id)|Select-Object -First 1;if($t){$newState=-not(Test-TaskEnabled $t);$t.Enabled=$newState;if(-not $newState){Remove-TaskFromCurrentPlan $t.Id};Save-Tasks;Refresh-TaskList}}})
    $remove.Add_Click({if($list.SelectedItems.Count){$id=$list.SelectedItems[0].Tag;if([System.Windows.Forms.MessageBox]::Show('Aufgabe wirklich entfernen?','Bestätigen','YesNo','Question') -eq 'Yes'){$script:Tasks=@($script:Tasks|Where-Object Id -ne $id);foreach($e in $script:Employees){$e.ExcludedTaskIds=@(As-Array $e.ExcludedTaskIds|Where-Object{$_ -ne $id})};foreach($t in $script:Tasks){$t.IncompatibleTaskIds=@(As-Array $t.IncompatibleTaskIds|Where-Object{$_ -ne $id})};Save-Tasks;Save-Employees;Refresh-TaskList}}})
    $close.Add_Click({$form.Close()});$form.Controls.AddRange(@($list,$add,$edit,$toggle,$remove,$close));Refresh-TaskList;[void]$form.ShowDialog()
}

function Show-PlanOutput {
    param([string]$Text,[array]$Warnings)
    $f=New-Object System.Windows.Forms.Form; $f.Text='Wochenplan Ausgabe'; $f.Width=760; $f.Height=560; $f.StartPosition='CenterParent'
    $tb=New-Object System.Windows.Forms.TextBox; $tb.Multiline=$true; $tb.ScrollBars='Vertical'; $tb.ReadOnly=$true; $tb.Left=10; $tb.Top=10; $tb.Width=720; $tb.Height=390; $tb.Text=$Text
    $warn=New-Object System.Windows.Forms.Label; $warn.Left=10; $warn.Top=410; $warn.Width=720; $warn.Height=65
    if($Warnings.Count -gt 0){$warn.Text="Hinweise: " + ($Warnings -join ' | ')}else{$warn.Text='Keine Warnungen.'}
    $copy=New-Object System.Windows.Forms.Button; $copy.Text='In Zwischenablage kopieren'; $copy.Left=10; $copy.Top=485; $copy.Width=190
    $close=New-Object System.Windows.Forms.Button; $close.Text='Schließen'; $close.Left=640; $close.Top=485; $close.Width=90
    $copy.Add_Click({Set-Clipboard -Value $tb.Text;[System.Windows.Forms.MessageBox]::Show('Plan wurde in die Zwischenablage kopiert.','Schichtplaner')|Out-Null})
    $close.Add_Click({$f.Close()});$f.Controls.AddRange(@($tb,$warn,$copy,$close));[void]$f.ShowDialog()
}

# -----------------------------
# Main form
# -----------------------------
$main=New-Object System.Windows.Forms.Form
$main.Text='Schichtplaner'; $main.Width=860; $main.Height=690; $main.StartPosition='CenterScreen'
$main.MinimumSize=New-Object System.Drawing.Size(860,690)

$title=New-Object System.Windows.Forms.Label; $title.Text='Schichtplaner'; $title.Font=New-Object System.Drawing.Font('Segoe UI',18,[System.Drawing.FontStyle]::Bold); $title.Left=15; $title.Top=12; $title.Width=250
$weekLabel=New-Object System.Windows.Forms.Label; $weekLabel.Text=(Get-WeekLabel); $weekLabel.Left=650; $weekLabel.Top=20; $weekLabel.Width=170; $weekLabel.TextAlign='MiddleRight'

$grid=New-Object System.Windows.Forms.DataGridView
$grid.Left=15; $grid.Top=55; $grid.Width=810; $grid.Height=390; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.SelectionMode='FullRowSelect'
[void]$grid.Columns.Add('Name','Mitarbeiter')
$presentCol=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $presentCol.Name='Present'; $presentCol.HeaderText='Anwesend'; $presentCol.FillWeight=55; [void]$grid.Columns.Add($presentCol)
$shiftCol=New-Object System.Windows.Forms.DataGridViewComboBoxColumn; $shiftCol.Name='Shift'; $shiftCol.HeaderText='Schicht'; [void]$shiftCol.Items.AddRange(@('Früh','Mitte','Spät')); $shiftCol.FillWeight=70; [void]$grid.Columns.Add($shiftCol)
$grid.Columns['Name'].ReadOnly=$true

$status=New-Object System.Windows.Forms.Label; $status.Left=15; $status.Top=455; $status.Width=810; $status.Height=28
$chkShowShift=New-Object System.Windows.Forms.CheckBox; $chkShowShift.Text='Schicht in Ausgabe anzeigen'; $chkShowShift.Left=15; $chkShowShift.Top=480; $chkShowShift.Width=230; $chkShowShift.Checked=[bool]$script:Settings.ShowShiftInOutput
$chkShowShift.Add_CheckedChanged({$script:Settings.ShowShiftInOutput=[bool]$chkShowShift.Checked;Save-Settings})

$btnGenerate=New-Object System.Windows.Forms.Button; $btnGenerate.Text='Wochenplan generieren'; $btnGenerate.Left=15; $btnGenerate.Top=515; $btnGenerate.Width=180; $btnGenerate.Height=35
$btnAbsence=New-Object System.Windows.Forms.Button; $btnAbsence.Text='Krankheit / Ausfall'; $btnAbsence.Left=205; $btnAbsence.Top=515; $btnAbsence.Width=160; $btnAbsence.Height=35
$btnRegenerate=New-Object System.Windows.Forms.Button; $btnRegenerate.Text='Plan neu generieren'; $btnRegenerate.Left=375; $btnRegenerate.Top=515; $btnRegenerate.Width=160; $btnRegenerate.Height=35
$btnCurrent=New-Object System.Windows.Forms.Button; $btnCurrent.Text='Aktuellen Plan anzeigen'; $btnCurrent.Left=545; $btnCurrent.Top=515; $btnCurrent.Width=175; $btnCurrent.Height=35
$btnEmployees=New-Object System.Windows.Forms.Button; $btnEmployees.Text='Mitarbeiter'; $btnEmployees.Left=15; $btnEmployees.Top=563; $btnEmployees.Width=120
$btnTasks=New-Object System.Windows.Forms.Button; $btnTasks.Text='Aufgaben'; $btnTasks.Left=145; $btnTasks.Top=563; $btnTasks.Width=120
$btnReload=New-Object System.Windows.Forms.Button; $btnReload.Text='Neu laden'; $btnReload.Left=275; $btnReload.Top=563; $btnReload.Width=120
$btnOpenData=New-Object System.Windows.Forms.Button; $btnOpenData.Text='Datenordner'; $btnOpenData.Left=405; $btnOpenData.Top=563; $btnOpenData.Width=120
$btnExit=New-Object System.Windows.Forms.Button; $btnExit.Text='Beenden'; $btnExit.Left=705; $btnExit.Top=563; $btnExit.Width=120

function Refresh-MainGrid {
    Load-State
    $grid.Rows.Clear()
    $currentMap=@{}
    foreach($a in (As-Array $script:CurrentPlan.Assignments)){$currentMap[$a.EmployeeId]=$a}
    foreach($emp in $script:Employees){
        $idx=$grid.Rows.Add(); $row=$grid.Rows[$idx]; $row.Cells['Name'].Value=$emp.Name; $row.Tag=$emp.Id
        if($currentMap.ContainsKey($emp.Id) -and $script:CurrentPlan.Week -eq (Get-WeekKey)){
            $row.Cells['Present'].Value=[bool]$currentMap[$emp.Id].Present; $row.Cells['Shift'].Value=$currentMap[$emp.Id].Shift
        } else {
            $row.Cells['Present'].Value=$true; $row.Cells['Shift'].Value='Früh'
        }
    }
    $activeCount=@($script:Tasks | Where-Object { Test-TaskEnabled $_ }).Count
    $hasCurrentWeekPlan = (([string]$script:CurrentPlan.Week -eq (Get-WeekKey)) -and ((As-Array $script:CurrentPlan.Assignments).Count -gt 0))
    if ($hasCurrentWeekPlan) { $btnGenerate.Text='Wochenplan aktualisieren' } else { $btnGenerate.Text='Wochenplan generieren' }
    $status.Text="Mitarbeiter: $($script:Employees.Count)   |   Aufgaben: $($script:Tasks.Count) (aktiv: $activeCount)   |   Daten: $DataDir"
}

function Collect-WeekEmployees {
    $arr=@()
    foreach($row in $grid.Rows){
        $emp=@($script:Employees|Where-Object Id -eq $row.Tag)|Select-Object -First 1
        if(-not $emp){continue}
        $shift=[string]$row.Cells['Shift'].Value; if([string]::IsNullOrWhiteSpace($shift)){$shift='Früh'}
        $arr += [pscustomobject]@{Id=$emp.Id;Name=$emp.Name;ExcludedTaskIds=(As-Array $emp.ExcludedTaskIds);Present=[bool]$row.Cells['Present'].Value;Shift=$shift}
    }
    return $arr
}

$btnGenerate.Add_Click({
    try{
        $weekEmployees=Collect-WeekEmployees
        $hasCurrentWeekPlan = (([string]$script:CurrentPlan.Week -eq (Get-WeekKey)) -and ((As-Array $script:CurrentPlan.Assignments).Count -gt 0))

        if($hasCurrentWeekPlan){
            # Fuer eine bereits laufende Woche ist dieser Button absichtlich stabil:
            # Anwesenheit/Schichten aktualisieren und den Basisplan so weit wie moeglich erhalten.
            $warnings=Rebalance-Availability $weekEmployees
            Show-PlanOutput (Format-PlanText $script:CurrentPlan) $warnings
        } else {
            $result=Generate-WeeklyPlan $weekEmployees
            $plan=[pscustomobject]@{
                Week=(Get-WeekKey)
                GeneratedAt=(Get-Date).ToString('s')
                Assignments=@($result.Assignments)
                BaselineAssignments=@($result.Assignments)
                Absences=@($weekEmployees | Where-Object {-not $_.Present} | ForEach-Object {$_.Id})
            }
            $script:CurrentPlan=$plan
            Save-CurrentPlan
            Commit-PlanToHistory $plan
            Show-PlanOutput (Format-PlanText $plan) $result.Warnings
        }
        Refresh-MainGrid
    }catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Schichtplaner','OK','Error')|Out-Null}
})


$btnRegenerate.Add_Click({
    try{
        $weekEmployees=Collect-WeekEmployees
        $answer=[System.Windows.Forms.MessageBox]::Show(
            "Der aktuelle Wochenplan wird vollständig neu berechnet. Bestehende Zuweisungen dieser Woche werden dabei nicht beibehalten.`n`nDie Historie vorheriger Wochen, SLA, Gewichte, Ausschlüsse, Bündelgruppen und harte Kombinationssperren werden weiterhin berücksichtigt.`n`nFortfahren?",
            'Plan neu generieren','YesNo','Question')
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $result=Generate-WeeklyPlan $weekEmployees
        $plan=[pscustomobject]@{Week=(Get-WeekKey);GeneratedAt=(Get-Date).ToString('s');Assignments=$result.Assignments;BaselineAssignments=@($result.Assignments);Absences=@($weekEmployees | Where-Object {-not $_.Present} | ForEach-Object {$_.Id})}
        $script:CurrentPlan=$plan;Save-CurrentPlan;Commit-PlanToHistory $plan
        Show-PlanOutput (Format-PlanText $plan) $result.Warnings
        Refresh-MainGrid
    }catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Schichtplaner','OK','Error')|Out-Null}
})

$btnAbsence.Add_Click({
    try{
        if((As-Array $script:CurrentPlan.Assignments).Count -eq 0){throw 'Es gibt noch keinen aktuellen Wochenplan.'}
        $weekEmployees=Collect-WeekEmployees
        $absentNow=@($weekEmployees | Where-Object { -not $_.Present })
        $names=if($absentNow.Count -gt 0){($absentNow.Name -join ', ')}else{'keine'}
        $answer=[System.Windows.Forms.MessageBox]::Show(
            "Der bestehende Wochenplan wird anhand der Anwesenheits-Haekchen repariert.`n`nAktuell abwesend: $names`n`nAlle weiterhin anwesenden Personen behalten ihre bisherigen Aufgaben soweit moeglich. Nur Aufgaben der abwesenden Personen werden neu verteilt.`n`nFortfahren?",
            'Krankheit / Ausfall','YesNo','Question')
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $warnings=Rebalance-Availability $weekEmployees
        Show-PlanOutput (Format-PlanText $script:CurrentPlan) $warnings
        Refresh-MainGrid
    }catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Schichtplaner','OK','Error')|Out-Null}
})

$btnCurrent.Add_Click({Load-State;if((As-Array $script:CurrentPlan.Assignments).Count){Show-PlanOutput (Format-PlanText $script:CurrentPlan) @()}else{[System.Windows.Forms.MessageBox]::Show('Noch kein Plan vorhanden.','Schichtplaner')|Out-Null}})
$btnEmployees.Add_Click({Show-EmployeeManager;Refresh-MainGrid})
$btnTasks.Add_Click({Show-TaskManager;Refresh-MainGrid})
$btnReload.Add_Click({Refresh-MainGrid})
$btnOpenData.Add_Click({Start-Process explorer.exe $DataDir})
$btnExit.Add_Click({$main.Close()})

$main.Controls.AddRange(@($title,$weekLabel,$grid,$status,$chkShowShift,$btnGenerate,$btnAbsence,$btnRegenerate,$btnCurrent,$btnEmployees,$btnTasks,$btnReload,$btnOpenData,$btnExit))
Refresh-MainGrid
[void]$main.ShowDialog()
