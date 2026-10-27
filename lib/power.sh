# shellcheck shell=bash
# CPU performance during the install. Laptops often hold the CPU back
# (powersave governor, power-saving EPP hint, lowered frequency caps, or an
# ACPI low-power profile), which can make compiling many times slower. Every
# compile runs on the live system's kernel, so set these for the install and
# put the originals back afterwards.

PERF_SAVE=${RUNDIR:-/run/toboggan}/perf-saved   # "path<TAB>original value" lines

_perf_set() { # path value: remember the original once, then write
  local f=$1 v=$2 cur
  [[ -w $f ]] || return 1
  cur=$(<"$f") || return 1
  [[ $cur == "$v" ]] && return 0
  grep -q "^$f	" "$PERF_SAVE" 2>/dev/null || printf '%s\t%s\n' "$f" "$cur" >>"$PERF_SAVE"
  printf '%s' "$v" >"$f" 2>/dev/null
}

_perf_summary() {
  local govs mhz
  local f; govs=$(for f in "${PERF_SYS:-}"/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [[ -r $f ]] && echo "$(<"$f")"; done |
    sort | uniq -c | awk '{printf "%s%s x%s", (NR>1?", ":""), $2, $1}')
  mhz=$(awk -F: '/^cpu MHz/ {s+=$2; n++} END {if (n) printf "%d", s/n}' /proc/cpuinfo)
  printf 'governors: %s; average clock now %s MHz' "${govs:-none (no cpufreq)}" "${mhz:-?}"
}

# On battery? (any discharging battery, and no mains adapter online)
power_on_battery() {
  local s
  for s in ${PERF_SYS:-}/sys/class/power_supply/*; do
    [[ $(cat "$s/type" 2>/dev/null) == Mains && $(cat "$s/online" 2>/dev/null) == 1 ]] && return 1
  done
  for s in ${PERF_SYS:-}/sys/class/power_supply/*; do
    [[ $(cat "$s/type" 2>/dev/null) == Battery && $(cat "$s/status" 2>/dev/null) == Discharging ]] && return 0
  done
  return 1
}

perf_begin() {
  [[ $DRYRUN == 1 ]] && { echo "[dry-run] would set the CPU to performance mode"; return 0; }
  local c f prof changed=0 capped=""
  echo "Before: $(_perf_summary)"
  for c in ${PERF_SYS:-}/sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [[ -d $c ]] || continue
    if grep -qw performance "$c/scaling_available_governors" 2>/dev/null; then
      _perf_set "$c/scaling_governor" performance && changed=1
    fi
    # With intel_pstate/amd-pstate in active mode the performance governor
    # usually forces this already; set it where the kernel still allows it.
    if [[ -f $c/energy_performance_preference ]] && \
       grep -qw performance "$c/energy_performance_available_preferences" 2>/dev/null; then
      _perf_set "$c/energy_performance_preference" performance || true
    fi
    if [[ -r $c/cpuinfo_max_freq && -r $c/scaling_max_freq ]] && \
       (( $(<"$c/scaling_max_freq") < $(<"$c/cpuinfo_max_freq") )); then
      _perf_set "$c/scaling_max_freq" "$(<"$c/cpuinfo_max_freq")" && capped=1
    fi
    if [[ -r $c/bios_limit ]] && (( $(<"$c/bios_limit") < $(<"$c/cpuinfo_max_freq") )); then
      echo "Note: the firmware limits ${c%/cpufreq} to $(( $(<"$c/bios_limit") / 1000 )) MHz (bios_limit); toboggan can't change that."
    fi
  done
  f=${PERF_SYS:-}/sys/firmware/acpi/platform_profile
  if [[ -r $f ]] && grep -qw performance ${PERF_SYS:-}/sys/firmware/acpi/platform_profile_choices 2>/dev/null; then
    prof=$(<"$f")
    _perf_set "$f" performance && [[ $prof != performance ]] && echo "ACPI platform profile: $prof -> performance"
  fi
  # Turbo/boost switched off?
  [[ $(cat ${PERF_SYS:-}/sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null) == 1 ]] && _perf_set ${PERF_SYS:-}/sys/devices/system/cpu/intel_pstate/no_turbo 0
  [[ $(cat ${PERF_SYS:-}/sys/devices/system/cpu/cpufreq/boost 2>/dev/null) == 0 ]] && _perf_set ${PERF_SYS:-}/sys/devices/system/cpu/cpufreq/boost 1
  [[ -n $capped ]] && echo "Raised lowered frequency caps back to the CPU's maximum."
  if (( changed )) || [[ -s $PERF_SAVE ]]; then
    echo "After:  $(_perf_summary)"
    echo "These are put back when the install finishes."
  else
    echo "No CPU frequency controls to change (or already in performance mode)."
  fi
  return 0
}

# Restore everything perf_begin changed. Safe to call more than once.
perf_restore() {
  [[ -s $PERF_SAVE ]] || return 0
  local f v
  # Restore in reverse order (caps before governors etc. doesn't matter, but be tidy).
  while IFS=$'\t' read -r f v; do
    [[ -w $f ]] && printf '%s' "$v" >"$f" 2>/dev/null
  done < <(tac "$PERF_SAVE")
  rm -f "$PERF_SAVE"
  log "Restored CPU power settings."
}