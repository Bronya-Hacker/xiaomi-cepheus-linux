#!/bin/sh
# ---------------------------------------------------------------------------
# mi9-charge-guard.sh -- soft charge limit for Xiaomi Mi 9 (cepheus / SM8150)
#
# Why this exists
#   The mainline PM8150B charger driver (qcom_smbx) exposes no charge
#   termination threshold. What it does expose is a *writable* `status`:
#
#       echo Unknown  > /sys/class/power_supply/pm8150b-charger/status
#           -> sets USBIN_SUSPEND_BIT: the phone stops drawing power from USB
#              (verified: online goes 1 -> 0, battery current goes negative)
#       echo Charging > /sys/class/power_supply/pm8150b-charger/status
#           -> clears it (verified: online 0 -> 1, charging resumes)
#
#   So we implement a hysteresis window around configurable limits:
#   stop at MI9_CHARGE_LIMIT, resume at MI9_CHARGE_RESUME. A battery temp
#   above MI9_CHARGE_MAX_TEMP stops charging regardless of capacity.
#
#   The USB *data* path (RNDIS / NCM / ttyGS0) is not affected, only the
#   charging input path, so SSH over USB keeps working while suspended.
#
# Usage
#   mi9-charge-guard.sh            run the loop (systemd unit)
#   mi9-charge-guard.sh --status   print one-shot status (ASCII)
#   mi9-charge-guard.sh --stop     force stop charging now
#   mi9-charge-guard.sh --resume   force resume charging now
#
# Config: /etc/default/mi9-charge-guard
# State : /run/mi9-charge-guard.state   (resumed | suspended)
#
# All human output is ASCII: it is also shown on tty1 / the serial console.
# ---------------------------------------------------------------------------
set -u

BAT=/sys/class/power_supply/qcom-battery
CHG=/sys/class/power_supply/pm8150b-charger
CONF=/etc/default/mi9-charge-guard
STATE=/run/mi9-charge-guard.state

LIMIT=80
RESUME=75
MAXTEMP=45
INTERVAL=60
[ -r "$CONF" ] && . "$CONF"

# 用户可能在 /etc/default 里写成 MI9_CHARGE_*，这里统一映射
LIMIT=${MI9_CHARGE_LIMIT:-$LIMIT}
RESUME=${MI9_CHARGE_RESUME:-$RESUME}
MAXTEMP=${MI9_CHARGE_MAX_TEMP:-$MAXTEMP}
INTERVAL=${MI9_CHARGE_INTERVAL:-$INTERVAL}

rd() { [ -r "$1" ] && cat "$1" 2>/dev/null; }
log() { logger -t mi9-charge-guard -- "$*" 2>/dev/null || true; }
state() { cat "$STATE" 2>/dev/null || echo resumed; }

set_state() {			# set_state <Charging|Unknown> <resumed|suspended> <reason>
	[ -w "$CHG/status" ] || { log "cannot write $CHG/status"; return 1; }
	if ! printf '%s\n' "$1" > "$CHG/status" 2>/dev/null; then
		log "write '$1' to $CHG/status failed"
		return 1
	fi
	printf '%s\n' "$2" > "$STATE" 2>/dev/null || true
	log "$2 ($3)"
}

status_report() {
	_cap=$(rd "$BAT/capacity"); _st=$(rd "$BAT/status")
	_t=$(rd "$BAT/temp"); _v=$(rd "$BAT/voltage_now"); _i=$(rd "$BAT/current_now")
	_on=$(rd "$CHG/online"); _icl=$(rd "$CHG/current_max"); _ut=$(rd "$CHG/usb_type")
	[ -n "${_t:-}" ] || _t=0
	[ -n "${_cap:-}" ] || _cap=?
	case "${_v:-}" in ''|'?') _vs=? ;; *) _vs="$(printf '%d.%02dV' "$(( _v / 1000000 ))" "$(( (_v % 1000000) / 10000 ))")" ;; esac
	case "${_i:-}" in
		''|'?') _is=? ;;
		*) if [ "$_i" -lt 0 ]; then _is="-$(( (0 - _i) / 1000 ))mA"; else _is="+$(( _i / 1000 ))mA"; fi ;;
	esac
	case "${_icl:-}" in ''|'?') _icls=? ;; *) _icls="$(( _icl / 1000 ))mA" ;; esac
	printf 'battery  %s%%  %s  %s  %s  %s.%sC\n' "$_cap" "${_vs}" "${_is}" "${_st:-?}" \
		"$(( _t / 10 ))" "$(( _t % 10 ))"
	printf 'charger  online=%s  icl=%s  type=%s\n' "${_on:-?}" "$_icls" "${_ut:-?}"
	printf 'guard    limit=%s%%  resume=%s%%  maxtemp=%sC  state=%s\n' \
		"$LIMIT" "$RESUME" "$MAXTEMP" "$(state)"
}

case "${1:-}" in
	--status) status_report; exit 0 ;;
	--stop)   set_state Unknown suspended "manual"; exit 0 ;;
	--resume) set_state Charging resumed "manual"; exit 0 ;;
esac

if [ ! -r "$BAT/capacity" ] || [ ! -w "$CHG/status" ]; then
	echo "mi9-charge-guard: power_supply not present (kernel/DTB without cepheus-chg?)" >&2
	log "power_supply not present, exiting"
	exit 0
fi

# Boot: never inherit a suspended input from a previous run.
if [ "$(state)" = suspended ]; then
	set_state Charging resumed "boot reset"
fi

log "started: limit=${LIMIT}% resume=${RESUME}% maxtemp=${MAXTEMP}C interval=${INTERVAL}s"

last=""
while :; do
	cap=$(rd "$BAT/capacity")
	temp=$(rd "$BAT/temp")
	if [ -z "${cap:-}" ]; then
		sleep "$INTERVAL"
		continue
	fi
	tc=$(( ${temp:-0} / 10 ))
	cur=$(state)

	if [ "$tc" -ge "$MAXTEMP" ]; then
		want=suspended; why="temp ${tc}C >= ${MAXTEMP}C"
	elif [ "$cap" -ge "$LIMIT" ]; then
		want=suspended; why="capacity ${cap}% >= ${LIMIT}%"
	elif [ "$cap" -le "$RESUME" ]; then
		want=resumed; why="capacity ${cap}% <= ${RESUME}%"
	else
		want=$cur; why="window ${cap}%"
	fi

	if [ "$want" != "$cur" ]; then
		if [ "$want" = suspended ]; then
			set_state Unknown suspended "$why"
		else
			set_state Charging resumed "$why"
		fi
	elif [ "$why" != "$last" ]; then
		log "hold $cur ($why)"
	fi
	last=$why

	sleep "$INTERVAL"
done
