# Closerfy Media Edge

Stack de infraestrutura pra capturar e gravar **calls de voz do WhatsApp Business Calling API**. Roda numa VPS dedicada que termina TLS pra Meta + atravessa NAT/firewall via Coturn + grava áudio Opus via Janus + envia gravações finalizadas pro backend Closerfy.

```
WhatsApp Cloud API (Meta)
         │ SIP + WebRTC (DTLS+SRTP)
         ▼
┌─────────────────────────────────────┐
│  Closerfy Media Edge (esta VPS)     │
│  ┌─────────┐  ┌─────────┐  ┌──────┐ │
│  │  Caddy  │  │  Janus  │  │Coturn│ │
│  │(TLS 443)│──│ (8088)  │──│(3478)│ │
│  └─────────┘  └────┬────┘  └──────┘ │
│                    │ .mjr            │
│              ┌─────▼──────┐          │
│              │ recorder-  │          │
│              │  watcher   │──┐       │
│              └────────────┘  │       │
└──────────────────────────────┼───────┘
                               │ POST .ogg
                               ▼
                  api.closerfy.ai/api/v1/
                whatsapp/calls/internal/
                     recording-ready
                               │
                               ▼
                  Pipeline existente
                  (Deepgram + GPT-4o)
```

## Pré-requisitos

- VPS com:
  - **2 vCPU + 4GB RAM** mínimo (recomendado: Hetzner CCX13 — €13/mês)
  - **Ubuntu 22.04 LTS** ou similar
  - **IP público estático**
  - Portas abertas no firewall:
    - **TCP 80, 443** (Caddy / Let's Encrypt)
    - **UDP 3478, 5349** (Coturn STUN/TURN)
    - **UDP 20000-40000** (Janus RTP range)
    - **UDP 49152-65535** (Coturn relay range)
- DNS:
  - Registro **A** apontando `media.closerfy.ai` → IP da VPS
- Docker + Docker Compose v2 instalados

## Deploy passo a passo

### 1. Provisionar VPS

```bash
# Hetzner Cloud (exemplo) — pode ser outra cloud
# CCX13 (2 vCPU dedicado, 8GB RAM, 80GB SSD) ~€13/mês
# Localização: Ashburn (US East) — menor latência pra Meta US
```

### 2. Apontar DNS

No painel do seu DNS (Cloudflare / Registro.br):
- Tipo: **A**
- Nome: **media** (vai virar `media.closerfy.ai`)
- Valor: **IP público da VPS**
- TTL: **300s** (durante setup); pode aumentar depois
- Proxy (Cloudflare): **DNS only** (cinza, NÃO laranja — Cloudflare proxy não passa WebRTC)

### 3. Abrir firewall na VPS

```bash
# Ubuntu UFW
sudo ufw allow 22/tcp           # SSH (limita IP se possível)
sudo ufw allow 80/tcp           # Let's Encrypt challenge
sudo ufw allow 443/tcp          # HTTPS
sudo ufw allow 443/udp          # HTTP/3
sudo ufw allow 3478/udp         # STUN
sudo ufw allow 3478/tcp         # STUN over TCP
sudo ufw allow 5349/tcp         # TURN over TLS
sudo ufw allow 20000:40000/udp  # Janus RTP
sudo ufw allow 49152:65535/udp  # Coturn relay
sudo ufw enable
```

Hetzner / DigitalOcean: liberar as mesmas portas no firewall externo do painel.

### 4. Instalar Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# logout + login pra aplicar grupo
```

### 5. Clonar essa pasta na VPS

```bash
ssh root@media.closerfy.ai
mkdir -p /opt/closerfy && cd /opt/closerfy
git clone https://github.com/MednovaHub/closerfy-code.git .
cd infra/media-edge
```

(Ou copiar só os arquivos dessa pasta via scp se preferir não clonar repo todo.)

### 6. Configurar `.env`

```bash
cp .env.example .env
nano .env
```

Gerar secrets:
```bash
echo "JANUS_ADMIN_SECRET=$(openssl rand -hex 32)"
echo "COTURN_SHARED_SECRET=$(openssl rand -hex 32)"
echo "CLOSERFY_INGEST_TOKEN=$(openssl rand -hex 32)"
echo "PUBLIC_IP=$(curl -s ifconfig.me)"
```

Cola os 4 valores em `.env`. Também cola `MEDIA_HOSTNAME=media.closerfy.ai`.

### 7. Substituir placeholders nos configs

```bash
# Janus admin secret
sed -i "s/REPLACE_WITH_JANUS_ADMIN_SECRET_FROM_ENV/$(grep JANUS_ADMIN_SECRET .env | cut -d= -f2)/" janus-config/janus.jcfg

# Coturn shared secret
sed -i "s/REPLACE_WITH_COTURN_SHARED_SECRET/$(grep COTURN_SHARED_SECRET .env | cut -d= -f2)/g" janus-config/janus.jcfg coturn.conf

# Public IP
sed -i "s|<PUBLIC_IP>|$(grep PUBLIC_IP .env | cut -d= -f2)|" coturn.conf
```

### 8. Subir o stack

```bash
docker compose pull
docker compose up -d
docker compose logs -f
```

Esperado:
- **Caddy:** `obtained certificate for media.closerfy.ai` (~30s no first boot)
- **Janus:** `Janus instance ready`
- **Coturn:** `Listener address: <PUBLIC_IP>:3478`
- **Recorder-watcher:** `[start] watching /recordings → POST https://api.closerfy.ai`

### 9. Validar

```bash
# Janus info (deve retornar versão + plugins)
curl https://media.closerfy.ai/janus/info

# Caddy health
curl https://media.closerfy.ai/health

# Coturn STUN binding test (de outra máquina)
# Use turnutils_uclient se tiver coturn-utils instalado
```

### 10. Configurar backend Closerfy

No Portainer (env do `closerfy-backend`), adicionar:

```
JANUS_ADMIN_URL=https://media.closerfy.ai/admin
JANUS_ADMIN_SECRET=<mesmo do .env>
CLOSERFY_INGEST_TOKEN=<mesmo do .env>
```

Redeploy o serviço backend. A partir daqui, `JanusClientService.isMockMode()` retorna `false` e calls reais começam a funcionar.

## Operação

### Logs

```bash
# Tudo
docker compose logs -f

# Só um serviço
docker compose logs -f janus
docker compose logs -f recorder-watcher

# Últimas N linhas
docker compose logs --tail 100 janus
```

### Restart

```bash
# Tudo (sem perder gravações em andamento — volume persiste)
docker compose restart

# Só um serviço
docker compose restart janus
```

### Update

```bash
cd /opt/closerfy
git pull
cd infra/media-edge
docker compose pull
docker compose up -d  # reinicia só serviços com imagem nova
```

### Backup das gravações

Janus grava em volume `closerfy_janus_recordings`. Esses `.mjr` são apagados após o `recorder-watcher` converter pra `.ogg` e enviar pro backend. Se quiser preservar `.mjr` originais como auditoria:

```bash
# Exemplo: backup diário pra S3
docker run --rm -v closerfy_janus_recordings:/src amazon/aws-cli s3 sync /src s3://closerfy-backup/janus/$(date +%F)/
```

### Métricas / monitoramento

UptimeRobot ou similar:
- HTTPS check: `https://media.closerfy.ai/health` (esperado `200 ok`)
- Frequência: 1min
- Alerta: email/Slack/Resend

## Troubleshooting

### Janus reclamando de DTLS cert

Janus precisa de cert + key auto-assinado pra DTLS de WebRTC (separado do TLS público do Caddy):

```bash
docker compose exec janus openssl req -x509 -newkey rsa:2048 -keyout /usr/local/etc/janus/janus.key -out /usr/local/etc/janus/janus.pem -days 365 -nodes -subj "/CN=media.closerfy.ai"
docker compose restart janus
```

### Calls da Meta não conectam

Possíveis causas:
1. **Firewall bloqueando UDP** — checar se portas RTP (20000-40000) estão liberadas
2. **PUBLIC_IP errado em coturn.conf** — Coturn anuncia IP errado nas candidatas ICE
3. **Cloudflare proxy ON** — DNS deve ser "DNS only" pra `media.closerfy.ai`
4. **TLS cert ainda obtendo** — esperar 1-2min após primeiro boot

Debug:
```bash
# Ver candidatas ICE que Janus oferece
docker compose logs janus | grep -i ice

# Ver requests batendo no Caddy
docker compose logs caddy
```

### Gravações não chegam no backend

```bash
# Confirma que .mjr está sendo criado
docker compose exec janus ls -la /var/lib/janus/recordings

# Confirma que recorder-watcher está vendo
docker compose logs recorder-watcher | tail -50

# Confirma que ffmpeg conversor instalado
docker compose exec recorder-watcher ffmpeg -version
```

### Aumentar verbosidade

`janus-config/janus.jcfg` → `debug_level = 7` (max). Restart janus.

## Custos

| Item | Custo |
|---|---|
| Hetzner CCX13 (2 vCPU dedicado, 8GB RAM) | ~€13/mês ≈ R$ 75 |
| Tráfego (incluído até 20TB) | grátis |
| TLS Let's Encrypt | grátis |
| DNS (já tem domínio) | 0 |
| **Total infra mensal** | **~R$ 75** |

Por minuto de call: só Meta cobra (~R$ 0,12/min).

## Segurança

- **NÃO** commitar `.env` (gitignored)
- Firewall mínimo: só portas necessárias
- Admin endpoint do Janus protegido por `admin_secret` + `admin_acl=127.0.0.1`
- Caddy adiciona HSTS + X-Frame-Options
- Recorder-watcher autentica com `X-Ingest-Token` (HMAC futuro?)
- TLS Let's Encrypt renova auto a cada 60 dias

Pra produção real, considerar adicionar:
- WAF (Cloudflare na frente, mas em "DNS only" pra preservar WebRTC)
- Fail2ban no SSH
- Backup automatizado das gravações

## Pra HA (próxima iteração)

MVP é single-VPS. Pra alta disponibilidade:
- 2 VPS atrás de DNS round-robin OU
- Health-check + failover via Cloudflare Load Balancer
- Volume `janus_recordings` em filesystem compartilhado (NFS) ou S3-compat
