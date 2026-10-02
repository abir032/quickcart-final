# Canary criteria — order service

Written **before** any canary release. The pipeline enforces these exactly, in
`scripts/canary-check.sh`. Changing them means changing this file in a pull
request, so the change is reviewed like any other.

## The canary

| Setting | Value | Why |
|---|---|---|
| Traffic to the new version | 10% | Small enough that a bad version affects few customers; large enough to measure |
| Canary tasks | 1 | Always running; it only gets traffic while the weight is above 0 |
| Watch window | 5 minutes | Long enough for a few hundred canary requests |
| Environment | production | 10% of real customers, for 5 minutes, before anyone else gets it |

## Abort — any one of these stops the release and returns all traffic to the stable version

1. **Canary error rate above 1%** — more than 1 in 100 canary responses is not a 200.
2. **More than 5 failures the load balancer answered itself** (502, 503, 504 with no app response) — the new tasks aren't serving at all.
3. **Fewer than 20 canary responses in the window** — too little evidence to judge. Not judging is treated as failing.

## Promote — only if none of the above happened

All traffic moves to the new version, the canary is switched off, and the
previous version is recorded so the rollback job can return to it in one click.

## What a person checks after promotion

- The smoke test passed on the promoted version.
- No new alarm fired in the 15 minutes after promotion.
- If either fails: run the **rollback** job with the default `previous`.
