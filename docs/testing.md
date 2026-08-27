# Estratégia de testes

## Validações atuais

- `node --check` para JavaScript não vendorizado;
- smoke pages em `tests/` para fiscal, importações e consulta CNPJ;
- regressões SQL em `supabase/tests/`;
- inspeção responsiva nos breakpoints definidos.

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
