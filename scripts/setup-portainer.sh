#!/usr/bin/env bash
# Setup único para instalação via Portainer (swarm/stack).
#
# O install.sh do kit faz, na ordem: clona, gera segredos, APLICA o schema e
# cria o 1º dono — e só então sobe o compose. Quem deploya pelo Portainer não
# roda o install.sh: o compose sobe, e o worker morre no boot com
# "schema do harness ausente no banco" (tabelas job_queue, lead_checkpoints,
# agent_inbox_items, send_ledger) e/ou sem admin para logar.
#
# Este script encapsula os dois passos de banco que faltam:
#   1. aplica o supabase/baseline.sql (idempotente — cria o schema inteiro)
#   2. cria o 1º dono no Auth + promove a super-admin de plataforma
#
# ⚠️ POSIX-sh COMPATÍVEL: roda tanto com `bash` (máquina local, via shebang)
# quanto com `sh` do busybox (container do serviço `setup` do swarm, que não
# tem bash). NADA de bashismo: sem ${!var}, sem ${var:0:40}.
#
# Ele roda em DOIS contextos, com o mesmo arquivo:
#   A) Manual, na sua máquina (raiz do repo):
#        SUPABASE_DB_URL='...pooler.supabase.com:6543/postgres' \
#        NEXT_PUBLIC_SUPABASE_URL='https://<projeto>.supabase.co' \
#        SUPABASE_SERVICE_ROLE_KEY='sb_secret_...' \
#        OWNER_EMAIL='dono@seudominio.com.br' \
#        OWNER_PASSWORD='senha-forte' \
#        ./scripts/setup-portainer.sh
#   B) Automático, no deploy GitOps: o serviço `setup` do docker-compose.swarm.yml
#      monta este arquivo (configs), roda com PSQL_CMD=psql dentro de um
#      postgres:17-alpine e sai. Redeploy = re-executa (idempotente; com o
#      schema já aplicado, pula os passos 1-2 e só garante o dono).
#
# Vars opcionais: OWNER_ORG_NAME (default "Minha Empresa"), AI_PROVIDER
# (anthropic|openrouter|openai), BASELINE_SQL (path do arquivo local; se
# ausente, baixa do GitHub). Também lê de .env/.env.local se existirem.
#
# Requer: Docker (usa `docker run postgres:17-alpine` para o psql — não precisa
# instalar psql no host). Dentro do container do setup, defina PSQL_CMD=psql
# (já vem no compose) para usar o psql local. curl se existir; senão wget do
# busybox (presente no postgres:17-alpine).
set -eu
set -o pipefail 2>/dev/null || true   # busybox ash suporta; senão segue sem

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── leitura de env: processo primeiro, .env/.env.local como fallback ────────
load_env() { # key → valor (stdout)
  local key="$1"
  local val
  val="$(printenv "$key" 2>/dev/null || true)"
  [ -n "$val" ] && { printf '%s\n' "$val"; return; }
  for f in "$ROOT/.env.local" "$ROOT/.env"; do
    [ -f "$f" ] || continue
    val="$(grep -E "^${key}=" "$f" | head -1 | cut -d= -f2- || true)"
    [ -n "$val" ] && { printf '%s\n' "$val"; return; }
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
  [ -n "$(printenv "$v" 2>/dev/null || true)" ] || MISSING="$MISSING $v"
done
if [ -n "$MISSING" ]; then
  echo "FALTA(M):$MISSING" >&2
  echo "Defina no ambiente ou no .env/.env.local (veja o cabeçalho do script)." >&2
  exit 1
fi

# psql (libpq) rejeita o parâmetro `pgbouncer=true` que o painel do Supabase
# acrescenta à string do TRANSACTION pooler (porta 6543): "invalid URI query
# parameter". E 6543 é modo transação — inadequado para o baseline (DDL e
# multi-statement). Para o psql, normaliza para o SESSION pooler: mesma
# credencial (postgres.<projeto>), sem query string e porta 5432.
# O app/worker NÃO usam esta normalização — o node-postgres aceita a string
# original com pgbouncer=true (a stack passa SUPABASE_DB_URL como está).
PSQL_URL="$(printf '%s' "$SUPABASE_DB_URL" | sed -E 's/\?.*$//; s#:6543/#:5432/#')"

# psql via Docker (default) ou local se PSQL_CMD definido
run_psql() { # args do psql
  if [ -n "${PSQL_CMD:-}" ]; then
    "$PSQL_CMD" "$PSQL_URL" "$@"
  else
    docker run --rm -i postgres:17-alpine psql "$PSQL_URL" "$@"
  fi
}

# Baixa arquivos: curl se existir, senão wget (busybox do alpine).
fetch_url() { # url outfile
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

# POST JSON (criação do dono no Auth): curl se existir, senão wget do busybox.
http_post_json() { # url json
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -X POST "$1" \
      -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      -H "Content-Type: application/json" \
      -d "$2" >/dev/null 2>&1
  else
    wget -q -O /dev/null \
      --header "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
      --header "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
      --header "Content-Type: application/json" \
      --post-data "$2" "$1"
  fi
}

# ── guarda: schema já aplicado? (redeploy rápido no GitOps) ──────────────────
# O worker confere exatamente estas quatro tabelas no boot (assertHarnessSchema).
if run_psql -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('job_queue','lead_checkpoints','agent_inbox_items','send_ledger') and c.relkind='r'" 2>/dev/null | grep -q '^4$'; then
  echo "==> schema já aplicado (tabelas do harness presentes) — pulando passos 1-2"
else
  # ── passo 1: extensões que o schema usa ────────────────────────────────────
  echo "==> [1/2] Criando extensões (vector, citext, pg_trgm)..."
  run_psql -v ON_ERROR_STOP=1 -c \
    'create extension if not exists vector with schema public;
     create extension if not exists citext with schema public;
     create extension if not exists pg_trgm with schema public;'
  echo "    ok"

  # ── passo 2: baseline.sql (schema completo, idempotente) ───────────────────
  BASELINE_SQL="${BASELINE_SQL:-$ROOT/supabase/baseline.sql}"
  if [ ! -f "$BASELINE_SQL" ]; then
    echo "==> [2/2] Baixando baseline.sql do GitHub (arquivo local ausente)..."
    BASELINE_SQL="/tmp/baseline-setup-portainer.sql"
    fetch_url \
      "https://raw.githubusercontent.com/ViFigueiredo/DeskcommCRM/main/supabase/baseline.sql" \
      "$BASELINE_SQL"
  fi

  echo "==> [2/2] Aplicando o schema (baseline.sql) — pode levar 1-2 minutos..."
  if [ -n "${PSQL_CMD:-}" ]; then
    run_psql -v ON_ERROR_STOP=1 -f "$BASELINE_SQL"
  else
    docker run --rm -i -v "$BASELINE_SQL:/baseline.sql:ro" postgres:17-alpine \
      psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /baseline.sql
  fi
  echo "    schema aplicado"
fi

# ── passo 3: cria o 1º dono + promove a super-admin (idempotente) ────────────
echo "==> [3] Criando o primeiro admin (${OWNER_EMAIL})..."
# 1) Cria o usuário no Supabase Auth. Se já existe, a API responde 422 — ok.
http_post_json "${NEXT_PUBLIC_SUPABASE_URL}/auth/v1/admin/users" \
  "{\"email\":\"${OWNER_EMAIL}\",\"password\":\"${OWNER_PASSWORD}\",\"email_confirm\":true}" \
  || true

# 2) Resolve o uid dentro do SQL (funciona para usuário novo OU já existente) e
#    cria org + membership admin + platform_admin — espelho do install.sh.
SLUG="$(printf '%s' "$OWNER_ORG_NAME" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$OWNER_ORG_NAME")"
SLUG="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
SLUG="$(printf '%s' "$SLUG" | cut -c1-40)"
[ -n "$SLUG" ] || SLUG="minha-empresa"

run_psql -v ON_ERROR_STOP=1 <<SQL
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
echo "✅ Setup completo. O worker sobe sozinho (tenta de novo até o schema existir)."
echo "   Login: ${OWNER_EMAIL} em https://<seu-dominio> e conclua o onboarding."
