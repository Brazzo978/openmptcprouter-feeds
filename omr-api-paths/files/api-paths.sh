#!/bin/sh
# Shared VPS control-plane path selection. Probe every eligible path in parallel;
# execute the actual operation once. Even GET /config can have server side effects.

omr_api_interfaces() {
	multipath 2>/dev/null | awk '
		$2 == "is" && $3 == "in" && $5 == "mode" &&
		$4 ~ /^(default|backup|subflow|signal)$/ &&
		$1 ~ /^[[:alnum:]_][[:alnum:]_.:-]*$/ && !seen[$1]++ { print $1 }'
}

omr_api_base_url() {
	if [ "$(valid_subnet6 "$1")" = ok ]; then
		printf 'https://[%s]:%s' "$1" "$2"
	else
		printf 'https://%s:%s' "$1" "$2"
	fi
}

_omr_api_probe() {
	local url="$1" iface="$2" dir="$3" slot="$4" limit="$5" child="" rc code
	trap - EXIT
	trap '[ -z "$child" ] || { kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; }; exit 1' INT TERM
	set -- curl --max-time "$limit" --connect-timeout "$limit" -s -k \
		--max-filesize 4096 --output "$dir/$slot.body" --write-out '%{http_code}'
	[ "$iface" = @default ] || set -- "$@" --interface "$iface"
	"$@" "$url/" > "$dir/$slot.code" 2>/dev/null &
	child=$!
	wait "$child"; rc=$?; child=""
	code="$(cat "$dir/$slot.code" 2>/dev/null)"
	# The existing, unauthenticated OMR homepage is deliberately used here.
	# No token requests, serial registration, config generation or writes fan out.
	if [ "$rc" -eq 0 ] && [ "$code" = 200 ] &&
	   [ "$(cat "$dir/$slot.body" 2>/dev/null)" = '"Welcome to OpenMPTCProuter Server part"' ]; then
		if mkdir "$dir/winner" 2>/dev/null; then
			printf '%s\n' "$iface" > "$dir/winner/interface"
		fi
	fi
	: > "$dir/$slot.done"
}

omr_api_select_path() (
	local url="$1" limit="${2:-3}" exclude="${3:-}" dir pids="" iface slot=0 pid n done_count polls=0
	case "$limit" in ''|*[!0-9]*|0) limit=3;; esac
	[ "$limit" -le 10 ] || limit=10
	umask 077
	dir="$(mktemp -d "${OMR_API_TMPDIR:-/tmp}/omr-api.XXXXXX")" || exit 1
	# Stop outstanding probe workers and their curl children on success or signal.
	trap 'n=0; for pid in $pids; do n=$((n+1)); [ -f "$dir/$n.done" ] || kill "$pid" 2>/dev/null; done; for pid in $pids; do wait "$pid" 2>/dev/null; done; rm -rf "$dir"' EXIT
	trap 'exit 1' INT TERM
	for iface in @default $(omr_api_interfaces); do
		[ "$iface" = "$exclude" ] && continue
		slot=$((slot+1))
		_omr_api_probe "$url" "$iface" "$dir" "$slot" "$limit" &
		pids="$pids $!"
	done
	while [ "$polls" -le $((limit * 20 + 40)) ]; do
		if [ -s "$dir/winner/interface" ]; then
			cat "$dir/winner/interface"
			exit 0
		fi
		done_count=0; n=1
		while [ "$n" -le "$slot" ]; do
			[ ! -f "$dir/$n.done" ] || done_count=$((done_count+1))
			n=$((n+1))
		done
		if [ "$done_count" -ge "$slot" ]; then
			# A worker may publish its winner between the first check and
			# the done scan. Recheck before declaring all paths unreachable.
			[ ! -s "$dir/winner/interface" ] || { cat "$dir/winner/interface"; exit 0; }
			exit 1
		fi
		sleep 0.05
		polls=$((polls+1))
	done
	exit 1
)

_omr_api_http_error() {
	if [ "$(jsonfilter -q -i "$1" -t '@' 2>/dev/null)" = object ]; then
		cat "$1"
	else
		printf '{"error":"VPS returned an HTTP error; verify state before retrying","http_status":%s}\n' "$2"
	fi
}

# Return 10 for rejected authentication, 11 for an HTTP/application error and
# 12 for uncertain delivery. Only a pre-delivery failure returns 1 without a body.
omr_api_request() (
	local method="$1" base="$2" route="$3" auth="$4" payload="$5" secret="$6"
	local iface exclude="" dir code rc detail attempt=0 child=""
	umask 077
	dir="$(mktemp -d "${OMR_API_TMPDIR:-/tmp}/omr-api.XXXXXX")" || exit 1
	trap '[ -z "$child" ] || { kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; }; rm -rf "$dir"' EXIT
	trap 'exit 1' INT TERM
	while [ "$attempt" -lt 2 ]; do
		iface="$(omr_api_select_path "$base" 3 "$exclude")" || exit 1
		set -- curl --max-time 10 --connect-timeout 3 -s -k \
			--output "$dir/body" --write-out '%{http_code}' -H 'accept: application/json'
		[ "$iface" = @default ] || set -- "$@" --interface "$iface"
		[ -z "$auth" ] || set -- "$@" -H "Authorization: Bearer $auth"
		case "$method" in
			GET) ;;
			POST) set -- "$@" -H 'Content-Type: application/json' -X POST -d "$payload" ;;
			LOGIN) set -- "$@" -X POST --data-urlencode "username=$payload" --data-urlencode "password=$secret" ;;
			*) exit 1 ;;
		esac
		"$@" "$base/$route" > "$dir/code" 2>/dev/null &
		child=$!
		wait "$child"; rc=$?; child=""
		code="$(cat "$dir/code" 2>/dev/null)"
		case "$rc" in
			5|6|7|45) # Failed before an HTTP request could be delivered.
				exclude="$iface"; attempt=$((attempt+1)); continue ;;
			0) ;;
			*)
				# A timeout after upload may have applied a write. Do not replay it.
				logger -t OMR-VPS 'API response unavailable; operation not automatically replayed'
				printf '%s\n' '{"error":"API response lost; operation may have been applied. Read back state before retrying.","delivery_uncertain":true}'
				exit 12 ;;
		esac
		# The token endpoint uses HTTP 400 for bad credentials and can also
		# reject disabled users with other 4xx codes. Never try every VPS IP.
		case "$method:$code" in LOGIN:4??) exit 10 ;; esac
		case "$code" in
			401) exit 10 ;;
			403)
				detail="$(jsonfilter -q -i "$dir/body" -e '@.detail' 2>/dev/null)"
				case "$detail" in 'Could not validate credentials'|'Not authenticated') exit 10;; esac
				# Permission denial is not an expired token. Do not log in
				# again or repeat an operation that the user cannot perform.
				_omr_api_http_error "$dir/body" "$code"
				exit 11 ;;
			2??) ;;
			4??)
				_omr_api_http_error "$dir/body" "$code"
				exit 11 ;;
			*)
				_omr_api_http_error "$dir/body" "$code"
				exit 11 ;;
		esac
		if ! jsonfilter -q -i "$dir/body" -e '@' >/dev/null 2>&1; then
			printf '%s\n' '{"error":"API response is invalid; verify state before retrying.","delivery_uncertain":true}'
			exit 12
		fi
		cat "$dir/body"
		exit 0
	done
	exit 1
)
