# Banco de dados — homologação

## Contexto

O backend é PostgreSQL/Supabase. Regras transacionais, RLS, importações e o
cálculo fiscal autoritativo ficam no banco; o navegador não é fonte de verdade
para preço ou imposto.

Ambiente auditado: `mtwvxyvpnbgwgltelozw`. Produção não foi acessada.

## Baseline e migrations

O histórico remoto confirma migrations 001–059. O Git contém 043–059; os
arquivos originais 001–042 ainda precisam ser recuperados da fonte histórica.
Não devem ser recriados por inferência nem marcados artificialmente como
aplicados.

A definição real de `resolve_fiscal_tax_rule` foi recuperada por introspecção
somente leitura e considerada nos testes de resolução histórica. Um dump de
schema pode servir como referência, mas não substitui os arquivos originais do
histórico.

## Estruturas fiscais principais

- `fiscal_tax_rules`: estado operacional atual de cada regra e sua vigência;
- `fiscal_tax_rule_versions`: snapshots imutáveis por `rule_id` e
  `rule_version`;
- `products_import_batches`, `products_import_stage` e
  `products_import_audit`: staging, idempotência e auditoria da importação;
- `quotation_items` e `order_items`: memória fiscal usada na operação;
- `logs`: auditoria administrativa antes/depois.

## Integridade da Fase 5B

- regra em uso não pode ser editada diretamente;
- nova versão nasce como `DRAFT` e fora do cálculo;
- ativação encerra a vigência anterior dentro da mesma transação;
- regra anterior permanece resolvível para datas históricas;
- `DELETE` administrativo foi substituído por desativação auditada;
- histórico rejeita `UPDATE` e `DELETE` por trigger;
- conflito de períodos ativos continua bloqueado;
- funções administrativas não possuem `EXECUTE` para `anon`/`PUBLIC`.

## Estado observado após aplicação

- 76 regras existentes;
- 76 classificadas como `REVIEW_REQUIRED` e mantidas em uso por continuidade;
- 76 snapshots de baseline em `fiscal_tax_rule_versions`;
- migrations 058 e 059 registradas;
- nenhuma alíquota, MVA, NCM, CEST, rota ou fórmula alterada.

## Rollback seguro

Não apagar a tabela de histórico nem os metadados para reverter comportamento.
Caso seja necessário suspender a governança, criar migration posterior que
desative os triggers/RPCs novos, preservando os snapshots. Nunca editar as
migrations já aplicadas.
