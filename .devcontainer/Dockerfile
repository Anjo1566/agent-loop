FROM node:22-bookworm

# Werkzeuge, die loop.sh und die Guards voraussetzen, plus alles, was
# init-firewall.sh für einen Default-Deny-Egress braucht.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      jq \
      curl \
      ca-certificates \
      less \
      iptables \
      ipset \
      iproute2 \
      dnsutils \
      aggregate \
      sudo \
      procps \
  && rm -rf /var/lib/apt/lists/*

# GitHub CLI aus dem offiziellen Repository.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# Der Loop läuft mit --dangerously-skip-permissions. Claude Code verweigert den
# Start, wenn dieser Schalter als root ausserhalb einer erkannten Sandbox
# gesetzt ist — der Container muss also einen normalen Benutzer haben. Das
# node-Image bringt "node" (UID 1000) bereits mit.
#
# Genau ein sudo-Recht: das Firewall-Skript. Sonst wäre der Egress-Deckel für
# den Agenten selbst abschaltbar.
RUN echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
      > /etc/sudoers.d/init-firewall \
  && chmod 0440 /etc/sudoers.d/init-firewall

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

RUN npm install -g @anthropic-ai/claude-code

USER node
WORKDIR /workspace
