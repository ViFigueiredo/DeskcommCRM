#!/usr/bin/env bash
# Setup único para instalação via Portainer (swarm/stack).
#
# O install.sh do kit faz, na ordem: clona, gera segredos, APLICA o schema e
# cria o 1º dono — e só então sobe o compose. Quem deploya pelo Portainer não
# roda o install.sh: o compose sobe, e o worker morre no boot com
# "schema do harness ausente no banco" (tabelas job_queue, lead_checkpoints,
# agent_inbox_items, send_ledger) e/ou sem admin para logar.
#
# Este script encapsula os dois passos de banco que faltam, uma única vez:
#   1. aplica o supabase/baseline.sql (idempotente — cria o schema inteiro)
#   2. cria o 1º dono no Auth + promove a super-admin de plataforma
#
# Uso (a partir da raiz do repo, ou em qualquer máquina com Docker):
#   SUPABASE_DB_URL='postgresql://postgres.<projeto>:<senha>@aws-0-<regiao>.pooler.supabase.com:6543/postgres' \
#   NEXT_PUBLIC_SUPABASE_URL='https://<projeto>.supabase.co' \
#   SUPABASE_SERVICE_ROLE_KEY='sb_secret_...' \
#   OWNER_EMAIL='dono@seudominio.com.br' \
#   OWNER_PASSWORD='senha-forte' \
#   ./scripts/setup-portainer.sh
#
# Vars opcionais: OWNER_ORG_NAME (default "Minha Empresa"), AI_PROVIDER
# (anthropic|openrouter|openai), BASELINE_SQL (path do arquivo local; se
# ausente, baixa do GitHub). Também lê de .env/.env.local se existirem.
#
# Requer: Docker (usa `docker run postgres:17-alpine` para o psql — não precisa
# instalar psql no host). Sem Docker, defina PSQL_CMD='psql' para usar o psql
# local (major >= 17 recomendado).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── leitura de env: processo primeiro, .env/.env.local como fallback ────────
load_env() {
  local key="$1"
  local val="${!key:-}"
  [ -n "$val" ] && { echo "$val"; return; }
  for f in "$ROOT/.env.local" "$ROOT/.env"; do
    [ -f "$f" ] || continue
    val=$(grep -E "^${key}=" "$f" | head -1 | cut -d= -f2- || true)
    [ -n "$val" ] && { echo "$val"; return; }
  done
}

SUPABASE_DB_URL="$(load_env SUPABASE_DB_URL)"
NEXT_PUBLIC_SUPABASE_URL="$(load_env NEXT_PUBLIC_SUPABASE_URL)"
SUPABASE_SERVICE_ROLE_KEY="$(load_env SUPABASE_SERVICE_ROLE_KEY)"
OWNER_EMAIL="$(load_env OWNER_EMAIL)"
OWNER_PASSWORD="$(load_env OWNER_PASSWORD)"
OWNER_ORG_NAME="${OWNER_ORG_NAME:-$(load_env OWNER_ORG_NAME)}"
OWNER_ORG_NAME="${OWNER_ORG_NAME:-Minha Empresa}"
AI_PROVIDER="${AI_PROVIDER:-$(load_env AI_PROVIDER)}"
AI_PROVIDER="${AI_PROVIDER:-}"

MISSING=""
for v in SUPABASE_DB_URL NEXT_PUBLIC_SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY OWNER_EMAIL OWNER_PASSWORD; do
  [ -n "${!v:-}" ] || MISSING="$MISSING $v"
done
if [ -n "$MISSING" ]; then
  echo "FALTA(M):$MISSING" >&2
  echo "Defina no ambiente ou no .env/.env.local (veja o cabeçalho do script)." >&2
  exit 1
fi

# psql via Docker (default) ou local se PSQL_CMD definido
run_psql() { # args do psql
  if [ -n "${PSQL_CMD:-}" ]; then
    "$PSQL_CMD" "$SUPABASE_DB_URL" "$@"
  else
    docker run --rm -i postgres:17-alpine psql "$SUPABASE_DB_URL" "$@"
  fi
}

# ── passo 1: extensões que o schema usa ──────────────────────────────────────
echo "==> [1/3] Criando extensões (vector, citext, pg_trgm)..."
run_psql -v ON_ERROR_STOP=1 -c \
  'create extension if not exists vector with schema public;
   create extension if not exists citext with schema public;
   create extension if not exists pg_trgm with schema public;'
echo "    ok"

# ── passo 2: baseline.sql (schema completo, idempotente) ─────────────────────
BASELINE_SQL="${BASELINE_SQL:-$ROOT/supabase/baseline.sql}"
if [ ! -f "$BASELINE_SQL" ]; then
  echo "==> [2/3] Baixando baseline.sql do GitHub (arquivo local ausente)..."
  BASELINE_SQL="/tmp/baseline-setup-portainer.sql"
  curl -fsSL -o "$BASELINE_SQL" \
    "https://raw.githubusercontent.com/ViFigueiredo/DeskcommCRM/main/supabase/baseline.sql"
fi

echo "==> [2/3] Aplicando o schema (baseline.sql) — pode levar 1-2 minutos..."
if [ -n "${PSQL_CMD:-}" ]; then
  run_psql -v ON_ERROR_STOP=1 -f "$BASELINE_SQL"
else
  docker run --rm -i -v "$BASELINE_SQL:/baseline.sql:ro" postgres:17-alpine \
    psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /baseline.sql
fi
echo "    schema aplicado"

# ── passo 3: cria o 1º dono + promove a super-admin (idempotente) ────────────
echo "==> [3/3] Criando o primeiro admin (${OWNER_EMAIL})..."
# 1) Cria o usuário no Supabase Auth. Se já existe, a API responde 422 — ok.
curl -fsS -X POST "${NEXT_PUBLIC_SUPABASE_URL}/auth/v1/admin/users" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${OWNER_EMAIL}\",\"password\":\"${OWNER_PASSWORD}\",\"email_confirm\":true}" \
  >/dev/null 2>&1 || true

# 2) Resolve o uid dentro do SQL (funciona para usuário novo OU já existente) e
#    cria org + membership admin + platform_admin — espelho do install.sh.
SLUG="$(printf '%s' "$OWNER_ORG_NAME" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$OWNER_ORG_NAME")"
SLUG="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
SLUG="${SLUG:0:40}"
[ -n "$SLUG" ] || SLUG="minha-empresa"

docker run --rm -i postgres:17-alpine psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 <<SQL
do \$\$
declare v_org uuid; v_uid uuid;
begin
  select id into v_uid from auth.users where email = '${OWNER_EMAIL}';
  if v_uid is null then
    raise exception 'usuário % não encontrado no auth.users (a criação no Auth falhou?)', '${OWNER_EMAIL}';
  end if;
  select id into v_org from public.organizations where slug='${SLUG}';
  if v_org is null then
    insert into public.organizations (slug, display_name, legal_name, created_by)
    values ('${SLUG}','${OWNER_ORG_NAME}','${OWNER_ORG_NAME}', v_uid) returning id into v_org;
  end if;
  if '${AI_PROVIDER}' not in ('', 'anthropic') then
    update public.organizations
       set settings = jsonb_set(
             coalesce(settings, '{}'::jsonb), '{llm,provider}',
             to_jsonb('${AI_PROVIDER}'::text), true)
     where id = v_org;
  end if;
  insert into public.user_organizations (user_id, organization_id, role, accepted_at)
  values (v_uid, v_org, 'admin', now())
  on conflict (user_id, organization_id) do update set role='admin', revoked_at=null;
  if not exists (select 1 from public.platform_admins where user_id=v_uid and revoked_at is null) then
    insert into public.platform_admins (user_id, granted_by, scope, reason)
    values (v_uid, v_uid, 'full', 'Bootstrap inicial do self-host');
  end if;
end \$\$;
SQL
echo "    dono criado e promovido a super-admin"

echo ""
echo "✅ Setup completo. Re-deploye a stack no Portainer — o worker deve subir."
echo "   Login: ${OWNER_EMAIL} em https://<seu-dominio> e conclua o onboarding."
