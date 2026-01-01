# Robocurse Roadmap

This document tracks potential improvements and enhancements identified during code review.

## Completed

### Code Organization
- [x] **Split Orchestration.ps1** - Divided 1,751-line file into focused modules:
  - `OrchestrationCore.ps1` - C# type definition, state initialization, circuit breaker
  - `JobManagement.ps1` - Chunk job execution, retry logic, profile management
  - `HealthCheck.ps1` - Health monitoring endpoint functions

### Documentation
- [x] **Document complex regex patterns in Logging.ps1** - Added inline comments explaining path redaction regex patterns

### Testing
- [x] **GUI Config Save/Load Integration Test** - Test that simulates load → modify → save → reload → verify values match

---

## Planned Improvements

### Performance & Telemetry

#### Add Performance Metrics Collection
**Priority:** Medium
**Effort:** Medium

Add instrumentation to collect performance metrics for analysis:
- Throughput rates per chunk/profile
- Queue wait times
- Robocopy process CPU/memory usage
- Network utilization correlation

```powershell
# Example metric collection
$metrics = @{
    ChunkId = $chunk.ChunkId
    QueueWaitMs = (Get-Date) - $chunk.EnqueuedAt
    ProcessingMs = $duration.TotalMilliseconds
    ThroughputMbps = ($stats.BytesCopied / $duration.TotalSeconds) / 1MB * 8
}
```

**Benefits:**
- Identify bottlenecks in replication pipeline
- Tune MaxConcurrentJobs and chunk sizes based on data
- Historical trend analysis

---

#### SIEM Event Rate Limiting
**Priority:** Low
**Effort:** Low

During high-volume operations (thousands of chunks), SIEM events can overwhelm logging infrastructure.

**Proposed solution:**
- Batch chunk completion events when rate exceeds threshold
- Aggregate statistics over time windows (e.g., 10 chunks completed in last 5s)
- Maintain detailed logging for errors/warnings only

```powershell
# Example rate limiting
if ($siemEventCount -gt $script:SiemRateLimitThreshold) {
    # Batch events instead of individual writes
    Add-SiemEventBatch -Events $pendingEvents
}
```

---

### Configuration

#### Configurable Robocopy Performance Settings
**Priority:** Medium
**Effort:** Medium

Expose robocopy performance settings in config and GUI for per-profile tuning:

- **Unbuffered I/O (`/J`)**: Currently enabled by default. Allow per-profile toggle for WAN scenarios where buffered I/O may perform better.
- **Threads per job (`/MT:n`)**: Currently global setting (default 8). Consider per-profile override for profiles with different characteristics (many small files vs few large files).
- **Chunk size thresholds**: Currently hardcoded (50GB size, 200K files). Allow per-profile configuration for fine-tuning based on source characteristics.

```json
{
  "profiles": {
    "LargeFiles": {
      "robocopy": {
        "unbufferedIO": true,
        "threadsPerJob": 16
      },
      "chunking": {
        "maxSizeGB": 100,
        "maxFiles": 500000
      }
    }
  }
}
```

**Benefits:**
- Optimize for different workload types (many small files vs few large files)
- Allow WAN-optimized profiles to disable `/J` if needed
- Fine-tune parallelism based on storage/network capabilities

---

### Code Quality

#### Debounce Config Saves
**Priority:** Medium
**Effort:** Low

Every LostFocus triggers disk write. Add dirty flag + debounce, or save only on window close.

---

#### Unified Logging Levels
**Priority:** Medium
**Effort:** Medium

Consolidate `Write-Host`, `Write-Verbose`, `Write-GuiLog`, `Write-RobocurseLog` into single path with DEBUG/INFO/WARN/ERROR levels.

---

#### Document GUI Initialization Order
**Priority:** Low
**Effort:** Low

Add comment block in `Initialize-RobocurseGui` showing sequence: handler wiring → config load → profile list → state restore → `GuiInitializing = $false`.

---

#### Pipeline Support for Functions
**Priority:** Low
**Effort:** Low

Some functions could benefit from pipeline input for composability:

```powershell
# Current
$profiles | ForEach-Object { Start-ProfileReplication -Profile $_ }

# With pipeline support
$profiles | Start-ProfileReplication
```

**Candidates:**
- `Start-ProfileReplication`
- `New-Chunk` / `New-SmartChunks`
- `Test-SourcePathAccessible`

---

#### Additional Input Validation
**Priority:** Medium
**Effort:** Low

Add JSON schema validation for config to prevent malformed input:
- Validate JSON structure against schema before parsing
- Check for unexpected properties that might indicate configuration errors
- Validate path formats before attempting operations

---

### Testing

#### Mutation Testing
**Priority:** Low
**Effort:** High

Current test coverage is good (1.45:1 ratio), but mutation testing would verify test quality:
- Use Stryker.NET or similar tool
- Identify tests that don't catch mutations
- Improve assertion specificity

---

#### Performance Benchmarks
**Priority:** Low
**Effort:** Medium

Add automated performance benchmarks:
- Chunk creation performance with various directory structures
- Robocopy log parsing throughput
- GUI responsiveness under load

---

### Operations

#### Prometheus/OpenTelemetry Metrics Export
**Priority:** Low
**Effort:** High

Export metrics in standard formats for observability platforms:
- Prometheus endpoint (HTTP /metrics)
- OpenTelemetry traces for distributed tracing
- Grafana dashboard templates

---

#### Enhanced Checkpoint Format
**Priority:** Low
**Effort:** Medium

Current checkpoint format is functional but could be enhanced:
- Add version field for future format changes
- Include partial chunk progress (files completed within chunk)
- Store robocopy process state for true resume

---

## Contributing

When implementing roadmap items:
1. Create feature branch from `main`
2. Update tests alongside code changes
3. Update this roadmap to move item to Completed
4. Submit PR with reference to roadmap item
