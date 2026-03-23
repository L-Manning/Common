# Merge Request Skill

Create a GitLab Merge Request (MR) with a structured description summarising RTL design changes, simulation results, and timing data.

## Usage

```
/merge-request [options]
```

**Options (provide in your message):**
- `target=<branch>` — Target branch for the MR (default: `main` or `develop`).
- `draft=yes|no` — Create as a Draft MR (default: `no`).
- `assignee=<username>` — GitLab username to assign the MR.
- `reviewer=<username>` — GitLab username(s) to request review from.
- `milestone=<name>` — Associate with a project milestone.

---

## What This Skill Does

1. Reads the git log between the current branch and target branch.
2. Inspects available timing/utilization reports and simulation logs.
3. Generates a structured MR description.
4. Creates the MR using the `glab` CLI (GitLab CLI) or `gh` CLI (GitHub PR as fallback).

---

## Steps to Execute

### 1. Gather branch information

```bash
TARGET_BRANCH="main"  # or user-specified
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Commits in this branch not in target
git log origin/${TARGET_BRANCH}..HEAD --oneline

# Files changed
git diff origin/${TARGET_BRANCH}...HEAD --stat

# Full diff summary
git diff origin/${TARGET_BRANCH}...HEAD --name-only
```

### 2. Collect design metrics

```bash
# Timing summary (WNS, WHS)
grep -E "WNS|WHS|TNS|THS" reports/timing_summary.rpt 2>/dev/null | head -6

# Resource utilization
grep -E "Slice LUTs|Slice Registers|Block RAM Tile|DSPs|IO Locs" reports/utilization.rpt 2>/dev/null | head -8

# Simulation pass/fail
for log in sim/*.log; do
    status=$(grep -c "FAIL\|assertion.*failure" "$log" > /dev/null 2>&1 && echo "FAIL" || echo "PASS")
    echo "$log: $status"
done
```

### 3. Categorise changed files

Group changed files into:
- `rtl/` — RTL source changes
- `tb/` — Testbench changes
- `constraints/` — XDC changes
- `ip/` — IP core changes
- `scripts/` — Build script changes
- `docs/` — Documentation

### 4. Generate MR description

Use this template:

```markdown
## Summary

<!-- One paragraph describing the purpose of this MR -->

## Changes

### RTL
- `rtl/core/my_module.vhd` — <brief description>

### Constraints
- `constraints/timing.xdc` — <brief description>

### Testbenches
- `tb/tb_my_module.vhd` — <brief description>

---

## Simulation Results

| Testbench | Result | Notes |
|---|---|---|
| `tb_my_module` | PASS | 240/240 assertions pass |
| `tb_axi_master` | PASS | Burst and single-beat modes |

---

## Timing Summary

| Metric | Value | Status |
|---|---|---|
| WNS (setup) | +0.42 ns | OK |
| WHS (hold)  | +0.11 ns | OK |
| WPWS        | +0.00 ns | OK |

---

## Resource Utilization

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 12,450 | 230,400 | 5.4% |
| Slice Registers | 8,200 | 460,800 | 1.8% |
| Block RAM (36K) | 12 | 312 | 3.8% |
| DSPs | 24 | 1728 | 1.4% |

---

## Interface Changes

<!-- List any port additions, removals, renames, or generic changes.
     Breaking changes must be called out explicitly. -->

- None / Breaking: `<description>`

---

## Test Plan

- [ ] Functional simulation passes for all testbenches
- [ ] Timing clean (WNS ≥ 0, WHS ≥ 0) at target speed grade
- [ ] DRC clean (no errors)
- [ ] Reviewed XDC for new ports
- [ ] Peer code review completed
- [ ] Hardware test on <board> (if applicable)

---

## Related Issues

Closes #<issue_number>
```

### 5. Create the MR

**Using GitLab CLI (`glab`):**
```bash
glab mr create \
  --title "<type>(<scope>): <summary>" \
  --description "$(cat /tmp/mr_description.md)" \
  --target-branch "${TARGET_BRANCH}" \
  --assignee "<assignee>" \
  --reviewer "<reviewer>"
```

**Using GitHub CLI (`gh`) for Pull Requests:**
```bash
gh pr create \
  --title "<type>(<scope>): <summary>" \
  --body "$(cat /tmp/mr_description.md)" \
  --base "${TARGET_BRANCH}" \
  --reviewer "<reviewer>"
```

**If neither CLI is available**, output the full MR description as markdown for the user to paste manually.

---

## MR Title Format

Follow the same Conventional Commits format as `/commit-msg`:

```
<type>(<scope>): <imperative summary ≤72 chars>
```

Examples:
```
feat(dsp_chain): add 4-tap FIR filter with configurable coefficients
fix(uart_rx): correct stop-bit framing at baud rates above 115200
perf(axi_master): reduce LUT usage by 8% via burst path refactor
constraints(timing): resolve hold violations on gt_rxclk CDC paths
```

---

## Checklist Before Creating MR

- [ ] Branch is up to date with target: `git fetch origin && git rebase origin/<target>`
- [ ] All commits have clean messages (run `/commit-msg` for each)
- [ ] `/vhdl-lint` passes with no ERRORs
- [ ] `/vivado-sim` shows PASS for all affected testbenches
- [ ] `/vivado-impl` shows WNS ≥ 0 and WHS ≥ 0
- [ ] No `TODO`/`FIXME` comments left in changed RTL files
- [ ] Interface changes documented in the MR description
