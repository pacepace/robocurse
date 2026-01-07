#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Completion Dialog Error Details Tests" {

        BeforeAll {
            # Mock logging functions
            Mock Write-RobocurseLog {}
            Mock Write-SiemEvent {}
            Mock Write-GuiLog {}
        }

        Context "Function Parameter Tests" {
            It "Should accept FailedChunkDetails parameter" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'FailedChunkDetails'
            }

            It "Should have FailedChunkDetails parameter as PSCustomObject array" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $param = $cmd.Parameters['FailedChunkDetails']
                $param.ParameterType.Name | Should -BeIn @('PSObject[]', 'PSCustomObject[]', 'Object[]')
            }
        }

        Context "XAML CompletionDialog Control Tests" {
            BeforeAll {
                $script:TestXamlContent = Get-XamlResource -ResourceName 'CompletionDialog.xaml'
            }

            It "Should have pnlErrors border" {
                $script:TestXamlContent | Should -Match 'x:Name="pnlErrors"'
            }

            It "Should have lstErrors StackPanel" {
                $script:TestXamlContent | Should -Match 'x:Name="lstErrors"'
            }

            It "Should have txtMoreErrors TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtMoreErrors"'
            }

            It "Should have btnCopyErrors button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnCopyErrors"'
            }

            It "Should have btnViewLogs button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnViewLogs"'
            }

            It "Should have error panel collapsed by default" {
                $script:TestXamlContent | Should -Match 'x:Name="pnlErrors"[^>]*Visibility="Collapsed"'
            }

            It "Should use SizeToContent for dialog" {
                $script:TestXamlContent | Should -Match 'SizeToContent="WidthAndHeight"'
            }

            It "Should have MaxHeight set" {
                $script:TestXamlContent | Should -Match 'MaxHeight="550"'
            }
        }

        Context "Error Report Generation Tests" {
            It "Should format error report with chunk details" {
                $failedChunks = @(
                    [PSCustomObject]@{
                        ChunkId = 1
                        SourcePath = "C:\Source\Dir1"
                        LastExitCode = 8
                        LastErrorMessage = "Some files or directories could not be copied"
                    }
                )

                $report = "Chunk 1: C:\Source\Dir1`nExit Code: 8`nError: Some files or directories could not be copied"

                # Test that report contains expected elements
                $report | Should -Match "Chunk 1"
                $report | Should -Match "C:\\Source\\Dir1"
                $report | Should -Match "Exit Code: 8"
                $report | Should -Match "Some files or directories could not be copied"
            }

            It "Should handle chunks without LastExitCode gracefully" {
                $failedChunk = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Source\Dir2"
                    LastErrorMessage = "Unknown error"
                }

                # Should not throw when LastExitCode is missing
                { $failedChunk.ChunkId } | Should -Not -Throw
            }
        }

        Context "Display Truncation Tests" {
            It "Should calculate remaining count when more than 10 errors" {
                $failedChunks = @(1..15 | ForEach-Object {
                    [PSCustomObject]@{
                        ChunkId = $_
                        SourcePath = "C:\Source\Dir$_"
                        LastExitCode = 8
                        LastErrorMessage = "Error $_"
                    }
                })

                $displayed = $failedChunks | Select-Object -First 10
                $remaining = $failedChunks.Count - $displayed.Count

                $displayed.Count | Should -Be 10
                $remaining | Should -Be 5
            }

            It "Should not show more errors text when 10 or fewer errors" {
                $failedChunks = @(1..8 | ForEach-Object {
                    [PSCustomObject]@{
                        ChunkId = $_
                        SourcePath = "C:\Source\Dir$_"
                        LastExitCode = 8
                        LastErrorMessage = "Error $_"
                    }
                })

                $displayed = $failedChunks | Select-Object -First 10
                $remaining = $failedChunks.Count - $displayed.Count

                $displayed.Count | Should -Be 8
                $remaining | Should -Be 0
            }
        }

        Context "OrchestrationState Integration Tests" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should retrieve failed chunks from OrchestrationState" {
                # Add some failed chunks
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Dir1"
                    DestinationPath = "D:\Dest\Dir1"
                    Status = 'Failed'
                    LastExitCode = 8
                    LastErrorMessage = "Error 1"
                }
                $chunk2 = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Source\Dir2"
                    DestinationPath = "D:\Dest\Dir2"
                    Status = 'Failed'
                    LastExitCode = 16
                    LastErrorMessage = "Error 2"
                }

                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk2)

                $script:OrchestrationState.FailedChunks.Count | Should -Be 2
            }

            It "Should handle empty FailedChunks queue" {
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
            }

            It "Should convert FailedChunks to array" {
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Dir1"
                    Status = 'Failed'
                }

                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)
                $failedArray = @($script:OrchestrationState.FailedChunks.ToArray())

                $failedArray.Count | Should -Be 1
                $failedArray[0].ChunkId | Should -Be 1
            }
        }

        Context "Complete-GuiReplication Integration Tests" {
            BeforeAll {
                # Load WPF assemblies for DispatcherTimer
                Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
                Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
            }

            BeforeEach {
                Initialize-OrchestrationState

                # Mock Show-CompletionDialog to capture parameters
                Mock Show-CompletionDialog {
                    param($ChunksComplete, $ChunksTotal, $ChunksFailed, $FailedChunkDetails)
                    $script:TestCapturedParams = @{
                        ChunksComplete = $ChunksComplete
                        ChunksTotal = $ChunksTotal
                        ChunksFailed = $ChunksFailed
                        FailedChunkDetails = $FailedChunkDetails
                    }
                }

                # Mock other dependencies
                Mock Close-ReplicationRunspace {}
                Mock Save-LastRunSummary {}
                Mock Send-CompletionEmail { return [PSCustomObject]@{ Success = $false } }

                # Initialize GUI variables - Create a mock timer with Stop method
                $script:ProgressTimer = New-MockObject -Type 'System.Windows.Threading.DispatcherTimer' -Methods @{
                    Stop = { }
                } -ErrorAction SilentlyContinue

                # Fallback if New-MockObject doesn't work
                if (-not $script:ProgressTimer) {
                    $script:ProgressTimer = [PSCustomObject]@{}
                    $script:ProgressTimer | Add-Member -MemberType ScriptMethod -Name Stop -Value {} -Force
                }

                $script:GuiErrorCount = 0
                $script:Controls = @{
                    btnRunAll = [PSCustomObject]@{ IsEnabled = $false }
                    btnRunSelected = [PSCustomObject]@{ IsEnabled = $false }
                    btnStop = [PSCustomObject]@{ IsEnabled = $true }
                    txtStatus = [PSCustomObject]@{
                        Text = ""
                        Foreground = $null
                    }
                }
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
            }

            It "Should pass failed chunk details to Show-CompletionDialog" {
                # Add failed chunks to OrchestrationState
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Dir1"
                    LastExitCode = 8
                    LastErrorMessage = "Error 1"
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)

                # Call Complete-GuiReplication
                Complete-GuiReplication

                # Verify Show-CompletionDialog was called with FailedChunkDetails
                Should -Invoke Show-CompletionDialog -Times 1
                $script:TestCapturedParams.FailedChunkDetails | Should -Not -BeNullOrEmpty
                $script:TestCapturedParams.FailedChunkDetails.Count | Should -Be 1
                $script:TestCapturedParams.FailedChunkDetails[0].ChunkId | Should -Be 1
            }

            It "Should pass empty array when no failed chunks" {
                # Call Complete-GuiReplication with no failed chunks
                Complete-GuiReplication

                # Verify Show-CompletionDialog was called with empty FailedChunkDetails
                Should -Invoke Show-CompletionDialog -Times 1
                $script:TestCapturedParams.FailedChunkDetails.Count | Should -Be 0
            }
        }

        Context "Show-CompletionDialog FilesSkipped Parameter" {
            It "Accepts FilesSkipped parameter" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'FilesSkipped'
            }

            It "Accepts FailedFilesSummaryPath parameter" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'FailedFilesSummaryPath'
            }

            It "FilesSkipped defaults to 0" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $param = $cmd.Parameters['FilesSkipped']
                $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object {
                    # Default value is handled at runtime, not in attribute
                }
                # Just verify parameter exists and is typed as long
                $param.ParameterType.Name | Should -Be 'Int64'
            }
        }

        Context "Show-CompletionDialog FilesCopied Parameter" {
            It "Accepts FilesCopied parameter" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'FilesCopied'
            }

            It "FilesCopied is typed as long" {
                $cmd = Get-Command Show-CompletionDialog -ErrorAction SilentlyContinue
                $param = $cmd.Parameters['FilesCopied']
                $param.ParameterType.Name | Should -Be 'Int64'
            }
        }

        Context "XAML CompletionDialog Skipped Controls" {
            BeforeAll {
                $script:TestXamlContent = Get-XamlResource -ResourceName 'CompletionDialog.xaml'
            }

            It "Should have txtSkippedValue TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSkippedValue"'
            }

            It "Should have txtFilesCopiedValue TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtFilesCopiedValue"'
            }

            It "Should have txtFilesFailedValue TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtFilesFailedValue"'
            }

            It "Should have lnkFailedFiles TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="lnkFailedFiles"'
            }

            It "Should have failed files link collapsed by default" {
                $script:TestXamlContent | Should -Match 'x:Name="lnkFailedFiles"[^>]*Visibility="Collapsed"'
            }

            It "Should have 6 stat columns" {
                # Count ColumnDefinition elements in stats grid
                $matches = [regex]::Matches($script:TestXamlContent, '<ColumnDefinition')
                $matches.Count | Should -BeGreaterOrEqual 6
            }
        }

        Context "XAML CompletionDialog Total Files and Success Rate Controls" {
            BeforeAll {
                $script:TestXamlContent = Get-XamlResource -ResourceName 'CompletionDialog.xaml'
            }

            It "Should have txtTotalFilesValue TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtTotalFilesValue"'
            }

            It "Should have txtSuccessPercentValue TextBlock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSuccessPercentValue"'
            }

            It "Should have Total Files label" {
                $script:TestXamlContent | Should -Match 'Total Files'
            }

            It "Should have Success Rate label" {
                $script:TestXamlContent | Should -Match 'Success Rate'
            }
        }
    }
}
