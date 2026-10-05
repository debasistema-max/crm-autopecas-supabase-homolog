# Retenção segura do pipeline de importação

## Objetivo

Evitar que as cópias temporárias de cada importação ocupem indefinidamente o
banco operacional. A política não remove produtos, estoque, preços, movimentos,
lotes ou auditoria.

## O que pode ser removido

Somente linhas de `products_import_stage` pertencentes a lotes terminais e
antigos. O padrão considera apenas `COMMITTED`; lotes `FAILED` exigem opção
explícita e retenção mínima maior.

Ao remover staging:

- `products_import_batches` permanece com arquivo, origem, contadores, datas e
  resultado;
- `products_import_audit` permanece integralmente; sua referência `stage_id`
  passa a `NULL` pela chave estrangeira já existente;
- dados operacionais e `stock_movements` não são alterados;
- lotes ativos (`DRAFT`, `PREVIEWED`, `APPROVED`, `COMMITTING` e
  `REVALIDATION_REQUIRED`) nunca são candidatos.

## Operação controlada

A migration `096_import_stage_retention.sql` cria a RPC administrativa
`maintain_products_import_stage`. Ela nasce sem agenda e com `dry_run=true`.

Simulação recomendada:

```sql
select public.maintain_products_import_stage();
```

Execução conservadora, no máximo um lote por chamada:

```sql
select public.maintain_products_import_stage(
  p_committed_retention_days => 14,
  p_failed_retention_days => 30,
  p_keep_recent_batches => 3,
  p_max_batches => 1,
  p_include_failed => false,
  p_dry_run => false
);
```

A execução exige ADMIN, `service_role` ou operador interno do banco. `anon` não
possui `EXECUTE`. A rotina bloqueia e revalida o estado do lote antes de apagar
o staging, preserva os lotes mais recentes por origem/tipo/filial/estado e
retorna contadores e IDs processados.

## Ativação futura

Não criar `pg_cron` nem agenda externa antes de:

1. aplicar a migration somente na homologação;
2. executar `096_import_stage_retention_regression.sql`;
3. observar uma simulação com lotes reais;
4. executar manualmente um lote por vez;
5. validar Central de Dados, histórico e auditoria;
6. aprovar formalmente a mesma política para produção.

Uma agenda futura deve chamar a mesma função com `p_include_failed=false` e
`p_max_batches=1`. A retenção de auditoria não faz parte desta migration; caso
se torne necessária, primeiro deve haver exportação verificável e uma política
de prazo aprovada.

## Rollback da migration

A migration não agenda jobs e não apaga dados ao ser aplicada. Para remover
somente a capacidade criada por ela:

```sql
drop function if exists public.maintain_products_import_stage(
  integer, integer, integer, integer, boolean, boolean
);
```

Staging já eliminado por uma execução confirmada só pode ser recuperado do
backup. Por isso a simulação e o limite por chamada são obrigatórios no processo
operacional.
