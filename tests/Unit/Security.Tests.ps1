#Requires -Modules Pester

<#
.SYNOPSIS
    Security tests for Robocurse
.DESCRIPTION
    Tests for security-related features including:
    - Email header CRLF injection prevention
    - Robocopy switch validation whitelist
    - Credential logging redaction
#>

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Email Header Sanitization Tests" {

        Context "CRLF Injection Prevention" {
            It "Should remove CRLF characters from email header" {
                # Use explicit character codes for CRLF
                $cr = [char]13  # Carriage return
                $lf = [char]10  # Line feed
                $maliciousInput = "test@example.com${cr}${lf}Bcc: attacker@evil.com"
                $sanitized = Get-SanitizedEmailHeader -Value $maliciousInput -FieldName "From"

                $sanitized | Should -Not -Match [regex]::Escape([char]13)
                $sanitized | Should -Not -Match [regex]::Escape([char]10)
                $sanitized | Should -Be "test@example.comBcc: attacker@evil.com"
            }

            It "Should remove carriage return only" {
                $cr = [char]13
                $input = "test@example.com${cr}malicious"
                $sanitized = Get-SanitizedEmailHeader -Value $input -FieldName "Test"

                $sanitized | Should -Not -Match [regex]::Escape([char]13)
                $sanitized | Should -Be "test@example.commalicious"
            }

            It "Should remove line feed only" {
                $lf = [char]10
                $input = "test@example.com${lf}malicious"
                $sanitized = Get-SanitizedEmailHeader -Value $input -FieldName "Test"

                $sanitized | Should -Not -Match [regex]::Escape([char]10)
                $sanitized | Should -Be "test@example.commalicious"
            }

            It "Should remove null bytes" {
                $null_byte = [char]0
                $input = "test@example.com${null_byte}malicious"
                $sanitized = Get-SanitizedEmailHeader -Value $input -FieldName "Test"

                $sanitized.Contains([char]0) | Should -Be $false
            }

            It "Should pass through clean input unchanged" {
                $cleanInput = "user@example.com"
                $sanitized = Get-SanitizedEmailHeader -Value $cleanInput -FieldName "From"

                $sanitized | Should -Be $cleanInput
            }

            It "Should handle empty string" {
                $sanitized = Get-SanitizedEmailHeader -Value "" -FieldName "Test"
                $sanitized | Should -Be ""
            }
        }

        Context "Email Address Validation" {
            It "Should accept valid email address" {
                $result = Get-SanitizedEmailAddress -Email "user@example.com"
                $result | Should -Be "user@example.com"
            }

            It "Should accept email with subdomain" {
                $result = Get-SanitizedEmailAddress -Email "user@mail.example.com"
                $result | Should -Be "user@mail.example.com"
            }

            It "Should reject email with CRLF injection" {
                $cr = [char]13
                $lf = [char]10
                $malicious = "user@example.com${cr}${lf}Bcc: evil@attacker.com"
                $result = Get-SanitizedEmailAddress -Email $malicious

                # Should sanitize but then fail format validation
                # The sanitized version "user@example.comBcc: evil@attacker.com" is invalid
                $result | Should -BeNullOrEmpty
            }

            It "Should reject invalid email format" {
                $result = Get-SanitizedEmailAddress -Email "not-an-email"
                $result | Should -BeNullOrEmpty
            }

            It "Should reject email without domain extension" {
                $result = Get-SanitizedEmailAddress -Email "user@localhost"
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Describe "Robocopy Switch Validation Tests" {

        Context "Get-SanitizedRobocopySwitches Whitelist" {
            It "Should allow valid /COPY switch" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/COPY:DAT")
                $result | Should -Contain "/COPY:DAT"
            }

            It "Should allow /Z restartable mode" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/Z")
                $result | Should -Contain "/Z"
            }

            It "Should allow /ZB backup mode" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/ZB")
                $result | Should -Contain "/ZB"
            }

            It "Should allow /XO exclude older" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/XO")
                $result | Should -Contain "/XO"
            }

            It "Should allow /MAX size limit" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/MAX:1048576")
                $result | Should -Contain "/MAX:1048576"
            }

            It "Should reject unknown switch" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/UNKNOWN:VALUE")
                $result | Should -BeNullOrEmpty
            }

            It "Should reject potentially dangerous /PURGE switch (not in whitelist)" {
                # /PURGE is intentionally not whitelisted as it can delete files
                $result = Get-SanitizedRobocopySwitches -Switches @("/PURGE")
                $result | Should -BeNullOrEmpty
            }

            It "Should handle mixed valid and invalid switches" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/Z", "/BADSWITCH", "/XO")
                $result.Count | Should -Be 2
                $result | Should -Contain "/Z"
                $result | Should -Contain "/XO"
            }

            It "Should handle null input" {
                $result = Get-SanitizedRobocopySwitches -Switches $null
                $result | Should -BeNullOrEmpty
            }

            It "Should handle empty array" {
                $result = Get-SanitizedRobocopySwitches -Switches @()
                $result | Should -BeNullOrEmpty
            }

            It "Should skip whitespace-only strings" {
                # Empty strings are filtered by the function, not rejected at binding
                # Test with array containing whitespace-only strings
                $result = Get-SanitizedRobocopySwitches -Switches @("/Z", "   ", "/XO")
                $result.Count | Should -Be 2
                $result | Should -Contain "/Z"
                $result | Should -Contain "/XO"
            }

            It "Should allow multiple COPY attributes" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/COPY:DATSO")
                $result | Should -Contain "/COPY:DATSO"
            }

            It "Should allow /SEC security copy" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/SEC")
                $result | Should -Contain "/SEC"
            }

            It "Should allow junction handling switches" {
                $result = Get-SanitizedRobocopySwitches -Switches @("/XJ", "/XJD", "/XJF")
                $result.Count | Should -Be 3
            }
        }

        Context "Get-SanitizedChunkArgs Validation" {
            It "Should allow /LEV depth switch" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @("/LEV:1")
                $result | Should -Contain "/LEV:1"
            }

            It "Should allow /S subdirectory switch" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @("/S")
                $result | Should -Contain "/S"
            }

            It "Should allow /E empty subdirectory switch" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @("/E")
                $result | Should -Contain "/E"
            }

            It "Should reject arbitrary switches" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @("/ARBITRARY")
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Describe "Credential Redaction Tests" {

        Context "Username Redaction Pattern" {
            It "Should redact username longer than 3 characters" {
                $username = "administrator"
                $redacted = if ($username.Length -gt 3) { $username.Substring(0, 3) + "***" } else { "***" }

                $redacted | Should -Be "adm***"
                $redacted | Should -Not -Match "administrator"
            }

            It "Should fully redact short username" {
                $username = "ab"
                $redacted = if ($username.Length -gt 3) { $username.Substring(0, 3) + "***" } else { "***" }

                $redacted | Should -Be "***"
            }

            It "Should redact exactly 3 character username" {
                $username = "usr"
                $redacted = if ($username.Length -gt 3) { $username.Substring(0, 3) + "***" } else { "***" }

                $redacted | Should -Be "***"
            }

            It "Should redact 4 character username showing first 3" {
                $username = "user"
                $redacted = if ($username.Length -gt 3) { $username.Substring(0, 3) + "***" } else { "***" }

                $redacted | Should -Be "use***"
            }
        }
    }

    Describe "Circuit Breaker Tests" {

        BeforeAll {
            # Initialize log session to prevent Write-RobocurseLog from writing to stderr
            $script:TestLogDir = Join-Path $TestDrive "CircuitBreakerLogs"
            New-Item -ItemType Directory -Path $script:TestLogDir -Force | Out-Null
            Initialize-LogSession -LogRoot $script:TestLogDir | Out-Null
        }

        BeforeEach {
            # Reset circuit breaker before each test
            Reset-CircuitBreaker
        }

        Context "Circuit Breaker State Management" {
            It "Should start with circuit breaker not tripped" {
                Test-CircuitBreakerTripped | Should -Be $false
            }

            It "Should not trip on first failure" {
                Invoke-CircuitBreakerCheck -ChunkId "1" -ErrorMessage "Test error" | Out-Null
                Test-CircuitBreakerTripped | Should -Be $false
            }

            It "Should trip after threshold consecutive failures" {
                $threshold = $script:CircuitBreakerThreshold

                for ($i = 1; $i -le $threshold; $i++) {
                    Invoke-CircuitBreakerCheck -ChunkId "$i" -ErrorMessage "Error $i" | Out-Null
                }

                Test-CircuitBreakerTripped | Should -Be $true
            }

            It "Should reset after Reset-CircuitBreaker" {
                # Trip the breaker
                for ($i = 1; $i -le $script:CircuitBreakerThreshold; $i++) {
                    Invoke-CircuitBreakerCheck -ChunkId "$i" -ErrorMessage "Error $i" | Out-Null
                }
                Test-CircuitBreakerTripped | Should -Be $true

                Reset-CircuitBreaker
                Test-CircuitBreakerTripped | Should -Be $false
            }
        }

        Context "Circuit Breaker Success Reset" {
            It "Should reset consecutive failures on success" {
                # Add some failures (but not enough to trip)
                $script:CircuitBreakerConsecutiveFailures = 5

                Reset-CircuitBreakerOnSuccess

                $script:CircuitBreakerConsecutiveFailures | Should -Be 0
            }

            It "Should not affect state if already at 0" {
                $script:CircuitBreakerConsecutiveFailures = 0

                Reset-CircuitBreakerOnSuccess

                $script:CircuitBreakerConsecutiveFailures | Should -Be 0
            }
        }

        Context "Circuit Breaker Integration" {
            BeforeAll {
                # Initialize orchestration state
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState = [Robocurse.OrchestrationState]::new()
            }

            It "Should set StopRequested when tripped" {
                Reset-CircuitBreaker
                $script:OrchestrationState.StopRequested = $false

                # Trip the breaker
                for ($i = 1; $i -le $script:CircuitBreakerThreshold; $i++) {
                    Invoke-CircuitBreakerCheck -ChunkId "$i" -ErrorMessage "Error $i" | Out-Null
                }

                $script:OrchestrationState.StopRequested | Should -Be $true
            }

            It "Should enqueue error message when tripped" {
                Reset-CircuitBreaker
                $script:OrchestrationState.Reset()

                # Trip the breaker
                for ($i = 1; $i -le $script:CircuitBreakerThreshold; $i++) {
                    Invoke-CircuitBreakerCheck -ChunkId "$i" -ErrorMessage "Persistent error" | Out-Null
                }

                $errors = $script:OrchestrationState.DequeueErrors()
                $errors.Count | Should -BeGreaterThan 0
                $errors[-1] | Should -Match "Circuit breaker tripped"
            }
        }
    }

    Describe "Profile Cache Statistics Tests" {

        BeforeEach {
            # Reset cache and statistics
            Clear-ProfileCache
            Reset-ProfileCacheStatistics
        }

        Context "Cache Statistics Tracking" {
            It "Should return zero stats initially" {
                $stats = Get-ProfileCacheStatistics

                $stats.Hits | Should -Be 0
                $stats.Misses | Should -Be 0
                $stats.HitRatePercent | Should -Be 0
                $stats.EntryCount | Should -Be 0
            }

            It "Should track cache misses" {
                # Try to get a non-existent profile (will be a miss)
                $result = Get-CachedProfile -Path "C:\NonExistent\Path"

                $stats = Get-ProfileCacheStatistics
                $stats.Misses | Should -Be 1
                $stats.Hits | Should -Be 0
            }

            It "Should track cache hits" {
                # Create and cache a profile
                $profile = [PSCustomObject]@{
                    Path = "C:\Test\Path"
                    TotalSize = 1000
                    FileCount = 10
                    DirCount = 2
                    LastScanned = Get-Date
                }
                Set-CachedProfile -Profile $profile

                # Now retrieve it (should be a hit)
                $cached = Get-CachedProfile -Path "C:\Test\Path"

                $stats = Get-ProfileCacheStatistics
                $stats.Hits | Should -Be 1
            }

            It "Should calculate hit rate correctly" {
                # Create a profile
                $profile = [PSCustomObject]@{
                    Path = "C:\Test\Path"
                    TotalSize = 1000
                    FileCount = 10
                    DirCount = 2
                    LastScanned = Get-Date
                }
                Set-CachedProfile -Profile $profile

                # 1 miss
                Get-CachedProfile -Path "C:\NonExistent" | Out-Null
                # 1 hit
                Get-CachedProfile -Path "C:\Test\Path" | Out-Null

                $stats = Get-ProfileCacheStatistics
                $stats.HitRatePercent | Should -Be 50
            }

            It "Should reset statistics" {
                # Generate some stats
                Get-CachedProfile -Path "C:\NonExistent" | Out-Null

                Reset-ProfileCacheStatistics

                $stats = Get-ProfileCacheStatistics
                $stats.Hits | Should -Be 0
                $stats.Misses | Should -Be 0
            }
        }
    }
}
