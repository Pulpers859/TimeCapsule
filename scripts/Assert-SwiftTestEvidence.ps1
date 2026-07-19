param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$requiredCases = @(
    'testClampsCorruptPreferenceValues',
    'testExactDayRangeEndsAtFollowingMidnight',
    'testWidenedRangeIncludesDaysOnBothSides',
    'testLeapDayIsRejectedInNonLeapAnniversaryYear',
    'testLeapDayIsAcceptedInLeapAnniversaryYear',
    'testNegativeDirectWindowInputProducesExactDayRange',
    'testWidenedRangeCrossesYearBoundary',
    'testDSTTransitionPreservesLocalCalendarDays',
    'testRangeAlsoClampsDirectWindowInput',
    'testSkipsTodaysPastFireTimeAndKeepsRequestedCount',
    'testIncludesTodaysFutureFireTime',
    'testZeroCountCreatesNoSlots',
    'testBodyHandlesExactAndNearbyWindows',
    'testPrunesSelectionAfterExternalLibraryChange',
    'testDeletingCurrentLastItemMovesToPreviousItem',
    'testDeletingOnlyItemEndsSession',
    'testSamplingPreservesFirstLastAndMaximum',
    'testShortRecapKeepsEveryItemInOrder',
    'testEmptyExactDayCanWidenThenScheduleAndDeleteSafely'
)

$log = Get-Content -LiteralPath $LogPath -Raw
$reported = [regex]::Matches($log, '(?:Executed|Test run with)\s+(\d+)\s+tests?') |
    ForEach-Object { [int]$_.Groups[1].Value } |
    Measure-Object -Maximum
$parallel = [regex]::Matches($log, '(?m)^\[[0-9]+/([0-9]+)\]\s+Testing\s+') |
    ForEach-Object { [int]$_.Groups[1].Value } |
    Measure-Object -Maximum
$executedEvidence = [Math]::Max([int]$reported.Maximum, [int]$parallel.Maximum)

if ($executedEvidence -lt $requiredCases.Count) {
    throw "Expected at least $($requiredCases.Count) tests, but found evidence for $executedEvidence."
}
foreach ($case in $requiredCases) {
    if ($log -notlike "*$case*") {
        throw "Required test case evidence missing: $case"
    }
}

Write-Output "Verified all $($requiredCases.Count) required XCTest cases."
