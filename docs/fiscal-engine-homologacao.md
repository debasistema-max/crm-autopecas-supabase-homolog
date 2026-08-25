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

## Segurança

- Vendedor: consulta preço, estoque e usa o motor em cotações/pedidos.
- Supervisor: importa estoque/preço somente com as permissões de módulo existentes.
- Admin: importa e aprova todos os tipos, configura regra fiscal, consulta auditoria e pendências.
- O commit executa em uma única função PostgreSQL; qualquer exceção desfaz todo o lote.

## Aplicação em homologação

As migrations `043` a `047` pertencem exclusivamente ao projeto Supabase de homologação. Não reutilize arquivo `.env`, link do CLI ou senha do projeto de produção ao aplicá-las.

Testes SQL são transacionais e terminam com `ROLLBACK`, preservando a base:

- `047_fiscal_engine_regression.sql`;
- `048_sap_import_center_regression.sql`;
- `049_all_import_types_regression.sql`.

