#!/usr/bin/env bash
# Closerfy Media Edge — setup automático
# Uso (dentro da VPS, na pasta do repo clonado):
#   bash setup.sh
#
# Idempotente: pode rodar várias vezes sem quebrar.
# Faz: firewall (UFW), Docker, gera secrets, configura, sobe stack.

set -euo pipefail

# ─── Cores pra UX ─────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step() { echo -e "\n${BLUE}${BOLD}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
info() { echo -e "  $1"; }

# ─── Pré-checks ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Rode como root (sudo bash setup.sh ou direto como root via SSH)"
[[ -f docker-compose.yml ]] || fail "Não estou na pasta do repo. Rode 'cd /opt/closerfy/closerfy-media-edge' primeiro."

MEDIA_HOSTNAME="${MEDIA_HOSTNAME:-media.closerfy.ai}"
CLOSERFY_BACKEND_URL="${CLOSERFY_BACKEND_URL:-https://api.closerfy.ai}"

echo -e "${BOLD}Closerfy Media Edge — setup automatizado${NC}"
echo "Hostname: $MEDIA_HOSTNAME"
echo "Backend:  $CLOSERFY_BACKEND_URL"
echo ""

# ─── 1. Apt update + upgrade ──────────────────────────────────────────
step "Atualizando pacotes do sistema"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >/dev/null
ok "Pacotes atualizados"

# ─── 2. UFW Firewall ──────────────────────────────────────────────────
step "Configurando firewall (UFW)"
if ! command -v ufw >/dev/null; then
  apt-get install -y -qq ufw >/dev/null
fi
# Defaults
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
# Regras (idempotentes — UFW dedupe automático)
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP/Lets Encrypt' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw allow 3478/tcp comment 'STUN/TURN TCP' >/dev/null
ufw allow 3478/udp comment 'STUN/TURN UDP' >/dev/null
ufw allow 5349/tcp comment 'TURN TLS' >/dev/null
ufw allow 20000:40000/udp comment 'Janus RTP' >/dev/null
ufw allow 10000:20000/udp comment 'Asterisk RTP' >/dev/null
ufw allow 49152:65535/udp comment 'Coturn relay' >/dev/null
ufw --force enable >/dev/null
ok "Firewall ativo (9 regras de entrada)"

# ─── 3. Docker ────────────────────────────────────────────────────────
step "Instalando Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
fi
docker --version >/dev/null || fail "Docker não instalou direito"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 não disponível"
ok "$(docker --version)"
ok "$(docker compose version | head -1)"

# ─── 4. Gerar / preservar secrets em .env ─────────────────────────────
# Detecta IPv4 público de forma robusta — força IPv4 (-4 no curl) pra evitar
# resolver pra IPv6 quando o servidor tem dual-stack.
detect_ipv4() {
  local ip
  ip=$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  fi
  if [[ -z "$ip" ]]; then
    # Fallback: pega da interface de rede principal
    ip=$(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  fi
  echo "$ip"
}

step "Configurando .env"
EXISTING_IP=""
if [[ -f .env ]]; then
  EXISTING_IP=$(grep '^PUBLIC_IP=' .env | cut -d= -f2- | tr -d '"' || true)
  # Detecta IP errado (vazio, IPv6 com ':', ou claramente inválido)
  if [[ -z "$EXISTING_IP" ]] || [[ "$EXISTING_IP" == *:* ]] || ! [[ "$EXISTING_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn ".env existente com PUBLIC_IP inválido ('$EXISTING_IP') — corrigindo"
    NEW_IP=$(detect_ipv4)
    [[ -n "$NEW_IP" ]] || fail "Não consegui detectar IPv4 público. Edita .env manualmente."
    sed -i "s|^PUBLIC_IP=.*|PUBLIC_IP=$NEW_IP|" .env
    ok ".env corrigido com IPv4: $NEW_IP"
  else
    warn ".env já existe — preservando secrets antigos (PUBLIC_IP=$EXISTING_IP)"
  fi
else
  PUBLIC_IP=$(detect_ipv4)
  [[ -n "$PUBLIC_IP" ]] || fail "Não consegui detectar IPv4 público. Defina PUBLIC_IP=... antes de rodar."
  cat > .env <<EOF
MEDIA_HOSTNAME=$MEDIA_HOSTNAME
JANUS_ADMIN_SECRET=$(openssl rand -hex 32)
COTURN_SHARED_SECRET=$(openssl rand -hex 32)
CLOSERFY_BACKEND_URL=$CLOSERFY_BACKEND_URL
CLOSERFY_INGEST_TOKEN=$(openssl rand -hex 32)
PUBLIC_IP=$PUBLIC_IP
ASTERISK_ARI_USER=closerfy
ASTERISK_ARI_PASSWORD=$(openssl rand -hex 32)
EOF
  chmod 600 .env
  ok "Secrets gerados em .env (chmod 600, PUBLIC_IP=$PUBLIC_IP)"
fi

# Carrega vars
set -a; source .env; set +a

# Idempotência: adiciona vars Asterisk ao .env existente se faltarem
if ! grep -q '^ASTERISK_ARI_USER=' .env; then
  echo "ASTERISK_ARI_USER=closerfy" >> .env
  echo "ASTERISK_ARI_PASSWORD=$(openssl rand -hex 32)" >> .env
  set -a; source .env; set +a
  ok "Adicionados secrets Asterisk ao .env existente"
fi

[[ -n "${PUBLIC_IP:-}" ]] || fail "PUBLIC_IP vazio em .env — edita manualmente e rode de novo"
[[ "${PUBLIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "PUBLIC_IP em .env não é IPv4 válido: $PUBLIC_IP"
[[ -n "${JANUS_ADMIN_SECRET:-}" ]] || fail "JANUS_ADMIN_SECRET vazio em .env"
[[ -n "${ASTERISK_ARI_PASSWORD:-}" ]] || fail "ASTERISK_ARI_PASSWORD vazio em .env"

ok "PUBLIC_IP IPv4: $PUBLIC_IP"

# ─── 5. Substituir placeholders nos configs ───────────────────────────
step "Aplicando secrets nos configs"
sed -i "s|REPLACE_WITH_JANUS_ADMIN_SECRET_FROM_ENV|$JANUS_ADMIN_SECRET|g" janus-config/janus.jcfg
sed -i "s|REPLACE_WITH_COTURN_SHARED_SECRET|$COTURN_SHARED_SECRET|g" janus-config/janus.jcfg coturn.conf
sed -i "s|REPLACE_WITH_PUBLIC_IP|$PUBLIC_IP|g" janus-config/janus.jcfg
sed -i "s|<PUBLIC_IP>|$PUBLIC_IP|g" coturn.conf

# Asterisk
sed -i "s|REPLACE_WITH_ASTERISK_ARI_PASSWORD|$ASTERISK_ARI_PASSWORD|g" asterisk-config/ari.conf
sed -i "s|REPLACE_WITH_PUBLIC_IP|$PUBLIC_IP|g" asterisk-config/pjsip.conf

# Validação: não pode sobrar placeholder
if grep -qE "REPLACE_WITH_|<PUBLIC_IP>" janus-config/janus.jcfg coturn.conf asterisk-config/*.conf 2>/dev/null; then
  fail "Sobrou placeholder não substituído nos configs"
fi
ok "Configs com secrets aplicados"

# ─── 6. DTLS cert pro Janus (auto-assinado) ───────────────────────────
step "Gerando cert DTLS pro Janus"
if [[ ! -f janus-config/janus.pem ]]; then
  openssl req -x509 -newkey rsa:2048 \
    -keyout janus-config/janus.key \
    -out janus-config/janus.pem \
    -days 3650 -nodes \
    -subj "/CN=$MEDIA_HOSTNAME" >/dev/null 2>&1
  chmod 600 janus-config/janus.key
  ok "Cert Janus auto-assinado gerado (válido 10 anos)"
else
  ok "Cert Janus já existe (preservado)"
fi

# ─── 6b. DTLS cert pro Asterisk (auto-assinado) ───────────────────────
# Meta valida fingerprint (não CA), então self-signed serve. Validado em
# spike 2026-05-06.
step "Gerando cert DTLS pro Asterisk"
mkdir -p asterisk-keys
if [[ ! -f asterisk-keys/asterisk.crt ]]; then
  openssl req -x509 -newkey rsa:2048 \
    -keyout asterisk-keys/asterisk.key \
    -out asterisk-keys/asterisk.crt \
    -days 3650 -nodes \
    -subj "/CN=$MEDIA_HOSTNAME" >/dev/null 2>&1
  # 644 (não 600) porque container roda como user 'asterisk' (não root) e
  # precisa ler. Self-signed key não é sensitive — Meta valida fingerprint
  # no SDP, não a CA, e o key fica em volume privado da VPS.
  chmod 644 asterisk-keys/asterisk.key
  chmod 644 asterisk-keys/asterisk.crt
  ok "Cert Asterisk auto-assinado gerado (válido 10 anos)"
else
  ok "Cert Asterisk já existe (preservado)"
fi

# ─── 7. Subir o stack ─────────────────────────────────────────────────
step "Baixando imagens Docker"
docker compose pull --quiet || fail "docker compose pull falhou"

step "Subindo containers"
docker compose up -d
sleep 3

# ─── 8. Aguardar saúde ────────────────────────────────────────────────
step "Aguardando Caddy obter TLS de Lets Encrypt (até 90s)..."
for i in {1..30}; do
  if curl -fsS --max-time 3 "https://$MEDIA_HOSTNAME/health" 2>/dev/null | grep -q "ok"; then
    ok "Caddy + TLS OK ($MEDIA_HOSTNAME respondeu)"
    HEALTH_OK=1
    break
  fi
  printf "."
  sleep 3
done
echo ""

if [[ -z "${HEALTH_OK:-}" ]]; then
  warn "Caddy ainda não respondeu via HTTPS — verifique:"
  info "1) DNS: dig +short $MEDIA_HOSTNAME (deve retornar $PUBLIC_IP)"
  info "2) Firewall externo da Hetzner liberando 80/443 (UFW interno já tá ok)"
  info "3) Logs: docker compose logs caddy"
fi

# Janus info via HTTPS (vai 401 sem admin secret — só checamos que respondeu)
if curl -fsS --max-time 3 "https://$MEDIA_HOSTNAME/janus/info" >/dev/null 2>&1; then
  ok "Janus respondendo via Caddy"
fi

step "Status dos containers"
docker compose ps

# ─── 9. Resumo final ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}✓ SETUP CONCLUÍDO${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}URLs públicas:${NC}"
echo "  Health:     https://$MEDIA_HOSTNAME/health"
echo "  Janus info: https://$MEDIA_HOSTNAME/janus/info"
echo "  Asterisk ARI: https://$MEDIA_HOSTNAME/ari/asterisk/info (Basic Auth)"
echo ""
# Grava secrets em arquivo gitignored chmod 600 — NÃO printa em stdout
# pra evitar vazamento por copy-paste (pra logs, chats, screenshots, etc).
SECRETS_FILE=".secrets-output.txt"
cat > "$SECRETS_FILE" <<EOF
# Secrets gerados em $(date -Iseconds)
# Cole estes valores no Portainer (env do backend closerfy-backend) e apague esse arquivo.

# Janus (legacy — manter enquanto Janus estiver rodando)
JANUS_ADMIN_URL=https://$MEDIA_HOSTNAME/admin
JANUS_ADMIN_SECRET=$JANUS_ADMIN_SECRET

# Recorder-watcher → Closerfy backend
CLOSERFY_INGEST_TOKEN=$CLOSERFY_INGEST_TOKEN

# Asterisk ARI (browser-direct + multi-party futuro)
ASTERISK_ARI_URL=https://$MEDIA_HOSTNAME/ari
ASTERISK_ARI_USER=$ASTERISK_ARI_USER
ASTERISK_ARI_PASSWORD=$ASTERISK_ARI_PASSWORD
ASTERISK_WS_URL=wss://$MEDIA_HOSTNAME/ws
EOF
chmod 600 "$SECRETS_FILE"

echo -e "${BOLD}${YELLOW}Secrets gerados em ${GREEN}$SECRETS_FILE${YELLOW} (chmod 600).${NC}"
echo "  Cola os valores no Portainer (env do backend) e apaga depois com:"
echo "    rm $SECRETS_FILE"
echo ""
echo -e "${BOLD}Comando pra ver os secrets:${NC}"
echo "  cat $SECRETS_FILE"
echo ""
echo "Depois redeploy o backend e teste uma call em /dashboard/whatsapp"
echo ""
echo -e "${BOLD}Comandos úteis:${NC}"
echo "  docker compose logs -f          # acompanha tudo"
echo "  docker compose logs -f janus    # só Janus"
echo "  docker compose restart          # reinicia tudo"
echo "  docker compose down             # para tudo"
echo "  docker compose up -d            # sobe tudo"
echo ""
