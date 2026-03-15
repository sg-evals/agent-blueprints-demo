## Automated Investigation

**Failing test:**
`TestRetryBackoffZero` (`apps/worker-reconcile/reconcile_test.go:42`)

**Likely root cause:**
The guard in `RetryBackoff` (`libs/retry/backoff.go:30`) is `if attempt < 1`, which should clamp `attempt=0` to `1`. However, the failing test receives `-100ms` — exactly `-1 × BaseDelay`. This is the signature of the delay formula operating on `attempt=0` unclamped: `attempt - 1 = -1`, giving `time.Duration(-1) × 100ms = -100ms`. This means the guard condition was recently changed from `if attempt < 1` to `if attempt < 0`, allowing `attempt=0` to bypass the clamp. The formula then computes a negative delay for `attempt=0`, which is caught by the `delay < 0` check in `ReconcileWithBackoff` (`apps/worker-reconcile/reconcile.go:44`) and returned as an error.

**Relevant files:**
- `libs/retry/backoff.go:29–32` — `RetryBackoff` guard logic; the condition `if attempt < 1` must remain `< 1` (not `< 0`) to protect against `attempt=0`
- `libs/retry/backoff.go:33` — delay formula `time.Duration(math.Pow(2, float64(attempt-1))) * cfg.BaseDelay` produces negative intermediate if attempt is not clamped first
- `apps/worker-reconcile/reconcile.go:36–48` — `ReconcileWithBackoff` calls `retry.RetryBackoff(attempt, cfg)` and validates the result is non-negative
- `apps/worker-reconcile/reconcile_test.go:42–50` — `TestRetryBackoffZero` passes `attempt=0`, expects no error
- `libs/retry/backoff_test.go:34–47` — `TestRetryBackoffClampsZeroAttempt` independently confirms `RetryBackoff(0, cfg)` must return `cfg.BaseDelay` (not negative)

**Suggested fix:**
Ensure the guard in `libs/retry/backoff.go` reads:
```go
if attempt < 1 {
    attempt = 1
}
```
If it was changed to `if attempt < 0`, revert it to `if attempt < 1`. This ensures `attempt=0` is clamped to `1` before the formula runs, producing `math.Pow(2, 0) × 100ms = 100ms` (non-negative).

**Confidence:**
High
