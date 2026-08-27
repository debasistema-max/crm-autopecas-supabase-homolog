# Estratégia de testes

## Validações atuais

- `node --check` para JavaScript não vendorizado;
- smoke pages em `tests/` para fiscal, importações e consulta CNPJ;
- smoke operacional em `tests/ui-operational-smoke.html`, selecionável por
  `?module=dashboard`, `?module=products` ou `?module=partners`;
- regressões SQL em `supabase/tests/`;
- inspeção responsiva nos breakpoints definidos.

## Evidência da Fase 2 — entrega 1

- Dashboard, Produtos e Parceiros inspecionados em 320, 360, 375, 390, 430,
  768, 1024 e 1440 px;
- nenhum overflow horizontal detectado nos 24 cenários;
- nenhum botão visível abaixo de 44 px nos cinco breakpoints mobile;
- alternância entre Clientes e Transportadoras validada;
- consulta CNPJ validada com resposta simulada da BrasilAPI, incluindo
  preenchimento e formatação dos campos;
- a página de smoke usa somente dados locais simulados e não grava no Supabase.

## Antes de publicar homologação

1. verificar worktree e diff;
2. executar sintaxe JavaScript;
3. abrir login e shell autenticado;
4. testar menu expandido, recolhido e drawer;
5. testar permissões de ADMIN, SUPERVISOR e VENDEDOR;
6. testar tabelas em 320 e 768 px;
7. executar regressões SQL somente em banco descartável ou transação controlada;
8. confirmar que nenhuma migration de produção foi acionada.

## Lacunas

Ainda não há runner automatizado, lint, typecheck ou CI. A implantação de um
runner mínimo deve ocorrer antes da centralização fiscal v2.
