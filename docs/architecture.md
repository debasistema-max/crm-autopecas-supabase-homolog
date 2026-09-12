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

Para as rotas comerciais aprovadas, o preço final autoritativo é o resultado
consolidado pelo Excel e persistido no PostgreSQL. O motor fiscal interno do
PostgreSQL permanece como contingência identificada quando a origem não entrega
um resultado aprovado. O frontend apenas envia o contexto e apresenta o valor.

## Portal B2B

O portal de clientes é uma superfície separada do shell interno. A identidade
`auth.users` é ligada a exatamente um `clients` por
`customer_portal_accounts`; RPCs `SECURITY DEFINER` retornam somente catálogo e
documentos daquele vínculo. A administração de convites e acessos passa por uma
Edge Function que exige sessão ADMIN. Consulte [b2b-portal.md](b2b-portal.md).

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
consolidado por rota, um conceito diferente. Cotações e pedidos consultam essa
tabela primeiro para PR→PR, PR→SC e SP→SP. Detalhes operacionais e instruções de
extensão estão em [data-sync.md](data-sync.md).
