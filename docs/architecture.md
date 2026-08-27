# Arquitetura do CRM

## Visão geral

O CRM é uma aplicação estática em HTML, CSS e JavaScript, publicada em GitHub
Pages. Autenticação, persistência, RLS e regras transacionais ficam no
Supabase/PostgreSQL.

```text
Navegador
  -> módulos JavaScript
  -> supabase_store.js
  -> Supabase Auth / PostgREST / RPC
  -> PostgreSQL, RLS, triggers e auditoria
```

## Fronteiras

- `js/components`: apresentação reutilizável, sem Supabase.
- `js/supabase_store.js`: adaptação de persistência e RPCs.
- módulos de domínio: orquestração de tela e regras comerciais.
- migrations: regra transacional, fiscal, RLS e integridade.

O cálculo fiscal autoritativo continua no PostgreSQL. O frontend apenas envia
o contexto da operação e apresenta o resultado.

## Risco de reprodutibilidade

O banco de homologação possui migrations 001–054 aplicadas, mas o repositório
contém somente 043–054. Nenhuma migration anterior deve ser recriada por
suposição. O histórico deve ser recuperado ou documentado em um baseline antes
de mudanças estruturais adicionais.

## Evolução incremental

O projeto permanece sem framework e sem bundler nesta fase. Componentes novos
usam um namespace global único (`CrmUi`) para reduzir colisões enquanto os
módulos legados são extraídos gradualmente.
