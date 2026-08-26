# Motor fiscal e importações SAP — homologação

## Diagnóstico preservado

O CRM é uma aplicação web estática em HTML, CSS e JavaScript que acessa o Supabase diretamente. A evolução reutiliza os contratos existentes de autenticação, perfis, permissões, produtos, filiais, estoque e preços por filial, cotações, pedidos, lotes de importação e auditoria.

Estruturas preexistentes reutilizadas:

- `products`, `branches`, `product_branch_stock` e `product_branch_prices`;
- `products_import_batches`, `products_import_stage` e `products_import_audit`;
- `fiscal_tax_rules`;
- `quotations`, `quotation_items`, `orders` e `order_items`;
- `profiles`, `role_permissions`, RLS e funções de autorização.

Problemas corrigidos:

- cálculo anterior dependia do preço global do produto e não da filial;
- fórmula de ICMS-ST não representava a sequência observada na planilha;
- não havia configuração explícita `has_st` por rota;
- importação não recebia as oito listas SAP, XLSX ou abas múltiplas;
- documento comercial não preservava toda a memória fiscal recalculável;
- preços monetários dos itens guardavam somente quatro casas decimais.

## Arquitetura implementada

```text
Arquivo SAP / CSV / TSV / XLSX / dados colados
  -> lote idempotente
  -> staging
  -> normalização e validação
  -> preview antes/depois
  -> aprovação por perfil
  -> commit RPC transacional
  -> produtos / SAP / estoque / preço base / regras fiscais
  -> motor fiscal PostgreSQL
  -> preço comercial por rota
  -> produto / cotação / pedido / lista comercial
```

Tipos aceitos: cadastro comercial, Cadastro Item SAP, estoque PR/SP, preço base PR/SP e dados fiscais com origem PR/SP.

O hash SHA-256 do conteúdo, tipo, filial/origem e aba compõe a chave de idempotência. Campos ausentes ou vazios não removem dados fiscais ou cadastrais existentes. A limpeza por vazio não é habilitada no fluxo operacional.

## Fonte de verdade fiscal

O preço final não é uma coluna definitiva de produto. Ele é calculado a partir de preço base por filial, NCM/CEST/IPI do produto, regra vigente e rota. O resultado pode ser consultado individualmente ou em lote.

Para rota com ST:

```text
IPI = base * aliquota_ipi
ICMS proprio = base * aliquota_interestadual
base_ST = (base + IPI) * (1 + MVA) * (1 - reducao_base)
ICMS_ST = max(0, base_ST * aliquota_interna_destino - ICMS proprio)
tributos = IPI + ICMS proprio + ICMS_ST + PIS + COFINS + FCP
preco_final = base + tributos + frete + seguro + outras despesas
```

Quando `has_st=false`, ICMS-ST é zero e o status é `OK_SEM_ST`. PIS, COFINS e FCP não recebem valores presumidos: ausência de definição gera pendência/aviso. Valores são calculados com `numeric`, mantidos com seis casas no snapshot e exibidos com duas no frontend.

### Perfil comercial de Revenda

As listas comerciais continuam usando o perfil `PRICE_LIST_MVA`, que reproduz a planilha de referência. Cotações e pedidos cuja utilização principal seja `REVENDA` podem usar o perfil configurável `LEGACY_REVENDA`, compatível com a composição observada no portal atual da empresa.

Para regras configuradas como `RATE_DIFFERENCE`:

```text
IPI = base * aliquota_ipi
ICMS-ST Revenda = base * aliquota_efetiva_revenda
tributos cobrados = IPI + ICMS-ST + impostos/despesas efetivamente definidos
preco_final = base + tributos cobrados
```

O ICMS próprio permanece na memória de cálculo como referência, mas só integra o total quando `resale_include_own_icms=true`. Se a alíquota efetiva não estiver configurada, o fallback é `ICMS interno - ICMS interestadual`. A tela administrativa de impostos permite alterar o método, a alíquota efetiva e a inclusão do ICMS próprio sem mudança de código.

Regressão observada no portal atual para o produto `7175526020`, NCM `8708.94.83`, SP→SP, Revenda: base R$ 580,00; IPI R$ 18,85; ICMS-ST R$ 81,17; final R$ 680,02. A lista SP→SP do mesmo produto permanece em R$ 816,10.

## Segurança

- Vendedor: consulta preço, estoque e usa o motor em cotações/pedidos.
- Supervisor: importa estoque/preço somente com as permissões de módulo existentes.
- Admin: importa e aprova todos os tipos, configura regra fiscal, consulta auditoria e pendências.
- O commit executa em uma única função PostgreSQL; qualquer exceção desfaz todo o lote.

## Aplicação em homologação

As migrations `043` a `052` pertencem exclusivamente ao projeto Supabase de homologação. Não reutilize arquivo `.env`, link do CLI ou senha do projeto de produção ao aplicá-las.

Testes SQL são transacionais e terminam com `ROLLBACK`, preservando a base:

- `047_fiscal_engine_regression.sql`;
- `048_sap_import_center_regression.sql`;
- `049_all_import_types_regression.sql`;
- `050_reference_workbook_regression.sql`.

## Carga da planilha de referência em 25/08/2026

Arquivo validado: `1-calculos-impostos.xlsx`, SHA-256 `19918d547beb8da80ead65f365f1908183fafb7fcb0454341e4d33d00ae5e03d`.

Foram confirmados em uma única transação global sete lotes v3: 4.238 itens SAP, 3.387 produtos comerciais, 3.177 posições de estoque PR, 3.385 preços base PR, 3.385 preços base SP, 48 regras fiscais de origem PR e 23 regras fiscais de origem SP. A aba `PORTAL ESTOQUE SP` está vazia e, por isso, nenhum estoque SP foi inventado ou gravado como zero.

A linha fiscal SAP de origem SP `Code 80`, NCM `84149020`, veio sem ICMS interno e MVA. Ela está registrada no lote rejeitado `f5aabdcb-88df-419e-97c0-8256b616b367` e não foi ativada. PIS, COFINS e FCP não existem nas listas de origem; permanecem `NULL` com avisos explícitos.

Regressão real do produto `6111032201`:

- PR→PR: base 232,000000; tributos 115,854460; final 347,854460; `OK`;
- SP→SP: base 232,000000; tributos 114,791931; final 346,791931; `OK`, com estoque `ESTOQUE_NAO_IMPORTADO`;
- PR→SC: base 232,000000; tributos 31,900000; final 263,900000; `OK_SEM_ST`.
