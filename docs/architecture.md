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

O banco de homologação possui migrations 001–059 aplicadas, mas o repositório
contém somente 043–059. Nenhuma migration anterior deve ser recriada por
suposição. O histórico deve ser recuperado ou documentado em um baseline antes
de mudanças estruturais adicionais.

## Evolução incremental

O projeto permanece sem framework e sem bundler nesta fase. Componentes novos
usam um namespace global único (`CrmUi`) para reduzir colisões enquanto os
módulos legados são extraídos gradualmente.

## Integração de dados externa

A Central de Dados acrescenta uma fronteira de integração sem tornar o Excel
uma dependência de execução do CRM:

```text
origem -> adapter -> DTO Data Sync v1 -> Edge Function -> staging/RPCs -> tabelas canônicas
```

Estoque continua em `product_branch_stock`; preço-base continua em
`product_branch_prices`. `product_route_prices` guarda apenas o resultado fiscal
consolidado por rota, um conceito diferente. Detalhes operacionais e instruções
de extensão estão em [data-sync.md](data-sync.md).
