#!/usr/bin/env bash
# Default-Deny-Egress für den Loop-Container.
#
# Das ist die Grenze, die im Konzept "die eigentliche Sicherheitsgrenze"
# heisst. Der Loop läuft mit --dangerously-skip-permissions; Hooks und
# deny-Listen fangen bekannte Muster ab, aber nur die Netzgrenze begrenzt,
# wohin eine Prompt-Injection etwas schicken kann.
#
# Erlaubt wird genau das, was der Loop braucht: die Anthropic-API, GitHub und
# die npm-Registry. Alles andere wird verworfen.

set -euo pipefail
IFS=$'\n\t'

if [[ "$(id -u)" != "0" ]]; then
  echo "init-firewall.sh muss als root laufen (sudo init-firewall.sh)." >&2
  exit 1
fi

# Sauber anfangen.
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy erlaubte-ziele 2>/dev/null || true

# DNS und Loopback müssen vor allem anderen stehen, sonst lässt sich die
# Allowlist unten nicht auflösen.
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT

# SSH nach aussen, damit der Container per Remote-Container erreichbar bleibt.
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

ipset create erlaubte-ziele hash:net

aufnehmen() {
  local host="$1" ip
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    ipset add erlaubte-ziele "$ip" 2>/dev/null || true
  done < <(dig +short A "$host" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
}

# GitHub veröffentlicht seine Netzbereiche selbst. Der Aufruf geht bewusst
# VOR dem Setzen der Default-Policy raus.
echo "GitHub-Netzbereiche holen ..."
curl -fsSL https://api.github.com/meta \
  | jq -r '(.web + .api + .git)[]' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
  | aggregate -q \
  | while read -r netz; do ipset add erlaubte-ziele "$netz" 2>/dev/null || true; done

for HOST in \
  api.anthropic.com \
  console.anthropic.com \
  statsig.anthropic.com \
  sentry.io \
  registry.npmjs.org \
  cli.github.com
do
  echo "Aufloesen: $HOST"
  aufnehmen "$HOST"
done

# Bestehende Verbindungen und das Host-Netz des Containers durchlassen.
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

HOSTNETZ=$(ip route | grep '^default' | cut -d' ' -f3)
if [[ -n "$HOSTNETZ" ]]; then
  HOSTBEREICH=$(ip route | grep -F "$HOSTNETZ" | grep -E 'src' | cut -d' ' -f1 | head -1)
  [[ -n "$HOSTBEREICH" ]] && {
    iptables -A INPUT  -s "$HOSTBEREICH" -j ACCEPT
    iptables -A OUTPUT -d "$HOSTBEREICH" -j ACCEPT
  }
fi

iptables -A OUTPUT -m set --match-set erlaubte-ziele dst -j ACCEPT

# Erst jetzt zumachen.
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

echo "Firewall steht. Gegenprobe:"
if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
  echo "  FEHLER: example.com ist erreichbar, der Egress ist NICHT dicht." >&2
  exit 1
fi
echo "  example.com blockiert."

if ! curl -fsS --max-time 5 https://api.github.com/zen >/dev/null 2>&1; then
  echo "  FEHLER: api.github.com ist nicht erreichbar, der Loop koennte keinen PR oeffnen." >&2
  exit 1
fi
echo "  api.github.com erreichbar."
