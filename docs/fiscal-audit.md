# Auditoria fiscal inicial — homologação

Data da auditoria: 02/09/2026

Escopo: código, migrations disponíveis, testes, fluxos de importação, cotação e pedido e consultas somente leitura ao Supabase de homologação.

Ambiente autorizado: `mtwvxyvpnbgwgltelozw` — nenhuma ação foi executada em produção.

## 1. Conclusão executiva

O CRM já possui uma base fiscal melhor que um cálculo disperso no frontend: preço base e estoque são separados por filial, o cálculo principal está no PostgreSQL, os documentos recebem um snapshot fiscal e a conversão de cotação em pedido copia esse snapshot. Os testes conhecidos da planilha estão formalizados em SQL.

O módulo, porém, ainda não pode ser classificado como uma engine fiscal validada para produção. Há riscos bloqueantes:

1. duas RPCs fiscais com `SECURITY DEFINER` responderam sem usuário autenticado na homologação;
2. cotação/pedido continuam sendo gravados com preço legado quando o cálculo fiscal falha;
3. o perfil `LEGACY_REVENDA` foi inferido de um único exemplo comercial e altera todas as regras SP→SP com ST;
4. regras vigentes são atualizadas no mesmo registro, sem versão histórica imutável nem fundamento legal obrigatório;
5. campos fiscais ausentes ainda podem virar zero no editor/importador legado;
6. não existe prevenção comprovável de períodos de vigência sobrepostos;
7. migrations 001–042 e a definição de `resolve_fiscal_tax_rule` não estão no repositório.

Portanto, a próxima implementação deve começar por segurança e integridade, mantendo os cálculos atuais congelados como baseline até validação fiscal formal.

### Atualização após a Fase 5A

As migrations 055–057 foram aplicadas somente na homologação e mitigaram
`FISC-SEC-001`, `FISC-INT-002`, `FISC-DATA-006`, `FISC-IMPORT-007`,
`FISC-CONFLICT-008`, parte de `FISC-VALID-015` e `FISC-STOCK-012`. A decisão de
ST também deixou de ser inferida como exceção PR→SC na interface de importação.

Os nove testes SQL disponíveis passaram sem persistir dados. As fórmulas e os
golden cases não foram alterados. Permanecem bloqueantes para certificação fiscal
o perfil `LEGACY_REVENDA` sem validação externa, histórico mutável, baseline
001–042 ausente e status `OK` com componentes tributários não definidos.

## 2. Limites e evidências

### Evidência analisada

- migrations locais 043–054;
- regressões SQL em `supabase/tests`;
- `js/tax_rules.js`, `js/imports.js`, `js/products.js`, `js/quotes.js`, `js/orders.js` e `js/supabase_store.js`;
- carregador `scripts/load_reference_workbook_homolog.mjs`;
- documentação e hash da planilha de referência;
- três consultas somente leitura às RPCs públicas da homologação.

### Limitação da planilha

O arquivo recebido tem SHA-256 `19918D547BEB8DA80EAD65F365F1908183FAFB7FCB0454341E4D33D00AE5E03D`, igual ao hash registrado nos testes e na documentação existente. A importação estruturada direta com a ferramenta obrigatória de planilhas não concluiu dentro da janela operacional e foi interrompida sem editar o arquivo. Esta auditoria não substituiu silenciosamente a biblioteca e não reinterpretou células por outra ferramenta.

As contagens e os valores atribuídos à planilha nesta análise vêm de evidências já versionadas no repositório, principalmente `050_reference_workbook_regression.sql`, `fiscal-engine-homologacao.md` e o carregador. Uma releitura estruturada independente da planilha permanece pendente antes de certificar a equivalência completa.

### Estado aplicado da homologação

- o histórico do banco confirma migrations 001–057 aplicadas;
- o repositório contém somente 043–057;
- o comportamento real comprova que a engine e o perfil introduzido na migration 053 estão ativos;
- as migrations 055–057 foram registradas e revalidadas no histórico da homologação;
- o golden case `6111032201`, PR→PR, retornou `OK`, com preço base e regra;
- o caso `7175526020`, SP→SP, `REVENDA`, retornou perfil `LEGACY_REVENDA`, IPI 18,85, ICMS-ST 81,170002 e final 680,020002.

## 3. Arquitetura fiscal atual

```text
XLSX / CSV / TSV / colagem
  -> normalização JavaScript
  -> products_import_batches
  -> products_import_stage
  -> validate_sap_import_batch
  -> preview_sap_import_batch
  -> approve_sap_import_batch
  -> commit_sap_import_batch
  -> products / product_sap_data
     / product_branch_stock / product_branch_prices
     / fiscal_tax_rules
  -> resolve_fiscal_tax_rule (definição ausente no repositório)
  -> calculate_product_price
  -> get_product_commercial_price
  -> Produtos / listas / cotações / pedidos
  -> fiscal_details no item do documento
```

### Fonte dos dados

| Dado | Fonte atual | Persistência | Observação |
|---|---|---|---|
| Produto/NCM/CEST/IPI | Cadastro Item SAP e MATRIZ | `products`, `product_sap_data` | `ipi_defined` distingue ausente de zero apenas em parte dos caminhos |
| Estoque | lista SAP por filial | `product_branch_stock` | PR carregado; fonte SP da planilha está documentada como vazia |
| Preço base | MATRIZ no carregador de referência | `product_branch_prices` | o mesmo conjunto é usado para PR e SP |
| Regra fiscal | listas fiscais SAP PR/SP e edição manual | `fiscal_tax_rules` | SAP não fornece PIS, COFINS e FCP no arquivo observado |
| Rota | filial faturadora + UF do cliente | RPC comercial | `regiao` é convertida diretamente em UF de origem |
| Tipo de cliente | utilização da tela | `customer_type` | valores práticos: `GERAL`, `REVENDA`, `CONSUMO` |
| Snapshot | resultado da RPC no momento da gravação | `fiscal_details` + colunas do item | cotação é copiada ao pedido sem recálculo |

## 4. Fórmulas localizadas

### Motor principal (`calculate_product_price`)

Para o perfil `PRICE_LIST_MVA`:

```text
IPI = base * ipi_rate
ICMS_proprio = base * interstate_icms_rate
base_ST = (base + IPI) * (1 + MVA)
ICMS_ST = max(0, base_ST * (1 - reducao) * icms_interno - ICMS_proprio)
PIS = base * pis_rate
COFINS = base * cofins_rate
FCP = base_ST * fcp_rate
despesas = base * (frete + seguro + outras)
total_tributos = IPI + ICMS_proprio + ICMS_ST + PIS + COFINS + FCP
preco_final = base + total_tributos + despesas
```

As parcelas são arredondadas a seis casas. Taxas ausentes resultam em parcela `NULL`, mas são convertidas em zero ao compor o total.

Para o perfil `LEGACY_REVENDA` com `RATE_DIFFERENCE`:

```text
base_ST = base
ICMS_ST = base * taxa_efetiva_revenda
taxa_efetiva_revenda = regra explícita ou max(0, interno - próprio)
ICMS_proprio só entra no total se resale_include_own_icms = true
```

### Duplicação

`calculate_taxed_unit_price` continua criada e concedida a usuários autenticados, mas não possui chamador no código atual. Ela implementa uma versão anterior da fórmula e retorna `OK`/`OK_SEM_ST` sem validar a completude. Deve ser retirada de exposição somente após provar que nenhum consumidor externo a utiliza.

### Documentos

`commercial_create_document` e `commercial_update_document_items` recalculam no banco. O frontend calcula apenas a apresentação. O desconto é aplicado depois do preço fiscal, com quatro casas no preço unitário final e duas casas no total do item/documento.

Quando o status não é `OK` nem `OK_SEM_ST`, o banco usa `products.preco_pr` ou `products.preco_sp`, grava o documento e mantém o status fiscal inválido. Esse fallback impede a garantia de preço fiscal confiável.

## 5. Golden cases existentes

| Caso | Base | IPI | ICMS próprio | ICMS-ST | Total fiscal | Final | Status |
|---|---:|---:|---:|---:|---:|---:|---|
| 6111032201 PR→PR | 232,000000 | 22,620000 | 27,840000 | 65,394460 | 115,854460 | 347,854460 | `OK` |
| 6111032201 SP→SP | 232,000000 | 22,620000 | 9,280000 | 82,891931 | 114,791931 | 346,791931 | `OK` |
| 6111032201 PR→SC | 232,000000 | 22,620000 | 9,280000 | 0 | 31,900000 | 263,900000 | `OK_SEM_ST` |
| 7175526020 SP→SP Revenda | 580,000000 | 18,850000 | memória apenas | 81,170002 | 100,020002 | 680,020002 | `OK` |

Os três primeiros casos comprovam reprodução da referência interna, não correção legal. O caso SP→SP usa 4% no campo chamado `interstate_icms_rate` apesar de ser uma rota interna. A Resolução do Senado 13/2012 prevê 4% para hipóteses de operações **interestaduais** com bens importados; a classificação desse 4% no cenário SP→SP precisa ser explicada e validada. Status: `REQUIRES_FISCAL_VALIDATION`.

O último caso reproduz um print do portal legado. A taxa efetiva foi criada por `81,17 / 580`, arredondada a oito casas, motivo do resultado interno 81,170002 antes da exibição com duas casas. Ele comprova compatibilidade visual com um exemplo, não uma regra tributária geral.

## 6. Achados priorizados

### Críticos

#### FISC-SEC-001 — RPCs fiscais acessíveis anonimamente

`get_product_commercial_price` e `get_fiscal_pending` responderam com a chave anônima e sem sessão de usuário. Ambas usam `SECURITY DEFINER` e validam permissões apenas quando `auth.uid()` não é nulo. Os `GRANT ... TO authenticated` não revogam automaticamente o privilégio padrão de `PUBLIC`.

Impacto: exposição de preço, estoque, regra aplicada e métricas de pendência. Correção proposta: revogar execução de `PUBLIC`/`anon`, exigir identidade em todas as RPCs e conceder explicitamente apenas aos papéis necessários. Revalidar todos os RPCs `SECURITY DEFINER`.

#### FISC-INT-002 — documento aceita cálculo fiscal inválido

Em erro fiscal, criação/edição usa preço legado global e conclui o documento. Isso permite pedido com `REGRA_FISCAL_AUSENTE`, `NCM_AUSENTE` ou regra incompleta, sem preço fiscal confiável.

Correção proposta: política configurável e explícita. Por padrão, bloquear finalização; se a empresa autorizar exceção, exigir permissão, justificativa e snapshot marcado `MANUAL_OVERRIDE`, nunca mascarar como cálculo normal.

#### FISC-RULE-003 — perfil de revenda extrapolado de um único caso

A migration 053 muda todas as regras ativas SP→SP com ST para `RATE_DIFFERENCE`. Apenas o NCM `8708.94.83` recebe a taxa observada; os demais usam a diferença entre alíquotas. Não há fundamento legal, versão de política comercial ou aprovação fiscal armazenada.

Status: `REQUIRES_FISCAL_VALIDATION`. Preservar temporariamente o comportamento para não alterar vendas, mas impedir expansão automática e identificar todos os NCM afetados.

#### FISC-HIST-004 — regra vigente é sobrescrita

O `UPSERT` usa a mesma linha para a mesma chave e data inicial. `rule_version` aumenta, porém a versão anterior não permanece como registro fiscal imutável. Logs manuais e auditoria de importação registram antes/depois, mas não compõem uma tabela de versões consumível pela engine.

Correção proposta: regra imutável por versão, status (`DRAFT`, `VALIDATED`, `ACTIVE`, `REVIEW_REQUIRED`, `EXPIRED`, `DISABLED`), fundamento legal obrigatório e ativação controlada.

#### FISC-REPO-005 — baseline incompleto

As migrations 001–042 e `resolve_fiscal_tax_rule` não estão no repositório. Não é possível reconstruir o banco ou provar constraints, RLS e precedência da seleção apenas pelo Git.

Correção proposta: exportar um baseline somente de schema da homologação, reconciliar com o histórico aplicado e versionar sem recriar migrations antigas por suposição.

### Altos

#### FISC-DATA-006 — vazio vira zero na administração fiscal

O formulário e a importação legada usam `|| 0`; `save_fiscal_tax_rule` também usa `coalesce(..., 0)`. Isso desfaz a semântica introduzida na migration 050: `NULL` significa não informado e zero significa informado como zero.

#### FISC-IMPORT-007 — importação fiscal paralela não transacional

`tax_rules.js` importa texto chamando `save_fiscal_tax_rule` uma linha por vez. Não há staging, preview, idempotência ou rollback do conjunto. Uma falha na linha N deixa as anteriores gravadas.

#### FISC-CONFLICT-008 — vigências sobrepostas não são impedidas

A unicidade observada considera a data inicial, não a interseção dos períodos. O relatório de pendências escolhe a regra mais recente com `LIMIT 1`, sem alertar sobre conflito. A função de resolução não está disponível para auditoria local.

#### FISC-STATUS-009 — `OK` com tributos desconhecidos

Na homologação, PR→PR retornou `OK`, embora PIS, COFINS e FCP fossem `NULL`; eles foram somados como zero e apareceram apenas em `warnings`. Isso não inventa os campos individuais, mas o preço final é numericamente fechado como se a ausência não impedisse a conclusão.

Correção proposta: distinguir `CALCULATED_WITH_PENDING_COMPONENTS` de `VALIDATED`, e definir por operação quais componentes são aplicáveis, não apenas se possuem número.

#### FISC-IMPORT-010 — `has_st` PR→SC hardcoded no carregador

O carregador define `has_st = false` para toda linha PR→SC. O valor termina configurável no banco, mas a decisão de origem é hardcoded e não vem do SAP nem de validação legal versionada.

#### FISC-PRICE-011 — mesma fonte de preço para PR e SP

O carregador gera `BASE_PRICE_PR` e `BASE_PRICE_SP` a partir da mesma coluna da aba MATRIZ. Isso preenche uma filial sem fonte independente e elimina a diferença conceitual entre preços por filial.

#### FISC-STOCK-012 — atualização parcial pode limpar colunas de estoque

No upsert de estoque, todos os campos SAP são substituídos pelo valor da linha, inclusive `NULL`. Como a normalização omite campos vazios, uma importação parcial pode apagar quantidades auxiliares válidas. `field_mask` e `clear_empty_fields` são armazenados no lote, mas não governam esse update.

#### FISC-PRICE-013 — seleção de preço pode ser ambígua

`get_product_commercial_price` busca uma linha válida sem `ORDER BY`/`LIMIT`. Se o schema permitir sobreposição de vigências, o resultado pode ser não determinístico.

#### FISC-CONTEXT-014 — entrada fiscal insuficiente

A engine recebe produto, origem, destino, base, data e tipo de cliente. Não recebe quantidade, desconto, regime tributário, contribuinte, finalidade, operação, indicador de consumidor final, frete real ou dados do estabelecimento. Não é suficiente para generalizar a todas as operações brasileiras solicitadas.

#### FISC-VALID-015 — validação de UF e alíquotas é permissiva

`normalize_fiscal_uf` aceita quaisquer duas letras. A constraint histórica permite algumas taxas até 1000%. O importador melhorou o limite para frações, mas o editor manual não tem o mesmo conjunto de validações.

### Médios

#### FISC-PENDING-016 — painel e rotas hardcoded

Pendências e preços do detalhe usam apenas PR→PR, SP→SP e PR→SC. O painel seleciona regra com lógica própria, sem reutilizar o resolvedor central e sem diferenciar tipo de cliente/operação.

#### FISC-ROUND-017 — política de arredondamento não documentada

Tributos arredondam por parcela a seis casas, desconto unitário a quatro e totais a duas. Falta uma política explícita por documento e comparação com a emissão fiscal/SAP.

#### FISC-IPI-018 — zero de IPI pode ser confundido com ausência

O trigger de compatibilidade usa, em parte, `ipi <> 0` para inferir definição. Importações novas usam presença do campo, mas registros legados podem classificar zero válido como não informado.

#### FISC-PERF-019 — lista comercial chama cálculo por produto

O batch de preços faz chamadas internas repetidas e a lista pode percorrer até 50 mil produtos. Não causa uma chamada de rede por produto, mas tende a degradar com crescimento e regras complexas.

#### FISC-FRONT-020 — `Number` no frontend

Cotação/pedido usam `Number` para preview e totais visuais. A gravação autoritativa recalcula em `numeric` no banco, o que reduz o risco, mas a tela pode exibir diferença momentânea. O frontend não deve ser fonte de verdade.

#### FISC-CLEAR-021 — opção de limpeza sem implementação coerente

`clear_empty_fields` é gravado no lote, mas os commits não implementam uma política uniforme baseada nele. A interface deve remover a opção ou o banco deve aplicá-la com autorização explícita e auditoria campo a campo.

## 7. Pontos fortes preservados

- cálculo principal centralizado em PostgreSQL;
- `numeric(16,6)` para dinheiro fiscal e taxas fracionárias no banco;
- preço e estoque por filial;
- `has_st` armazenado por regra, não na fórmula principal;
- staging, preview, aprovação, commit transacional e hash idempotente no fluxo SAP;
- campos cadastrais usam `coalesce` para não apagar dados em vários upserts;
- snapshot fiscal detalhado em cotação e pedido;
- conversão cotação→pedido copia o snapshot, evitando alteração retroativa;
- PIS/COFINS/FCP ausentes permanecem `NULL` nos campos de saída;
- linha fiscal SAP incompleta documentada como rejeitada;
- golden tests transacionais terminam em `ROLLBACK`.

## 8. Segurança, RLS e permissões

O código local demonstra autorização interna em RPCs administrativas e separação de Admin/Supervisor/Vendedor. Entretanto, RLS e grants completos de tabelas/funções dependem das migrations ausentes.

Checklist bloqueante para a próxima migration:

1. `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon` para RPCs fiscais e comerciais;
2. `GRANT EXECUTE` nominal a `authenticated` somente após validação interna obrigatória;
3. remover condições do tipo `if auth.uid() is not null and not (...)` e negar quando `auth.uid()` for nulo;
4. inventariar todas as funções `SECURITY DEFINER`, `search_path` e owner;
5. testar anon, VENDEDOR, SUPERVISOR, ADMIN e usuário inativo;
6. conferir RLS real no schema exportado, sem confiar apenas no frontend.

## 9. Validação fiscal oficial

Esta auditoria não certifica alíquotas. Ela confirma que a configuração precisa considerar, além do NCM, descrição/finalidade, origem da mercadoria, natureza da operação, perfil do contribuinte e vigência.

- A Resolução do Senado 22/1989 estabelece a estrutura das alíquotas interestaduais gerais; ela não valida uma alíquota para operação interna.
- A Resolução do Senado 13/2012 estabelece 4% em hipóteses interestaduais com bens importados e condições próprias.
- A Receita Federal informa que a TIPI é baseada na NCM e mantém publicação atualizada; o IPI deve ser obtido da classificação vigente, não congelado indefinidamente na planilha.
- Santa Catarina denunciou os Protocolos 41/08 e 97/10 e retirou autopeças do regime estadual indicado a partir de 01/04/2020. Isso sustenta investigar `has_st=false` para o contexto aplicável, mas não autoriza uma regra genérica sem validar produto e operação.
- São Paulo mantém regras temporais específicas para autopeças; a Portaria SRE 16/2023 está publicada com vigência até 30/09/2026 e substituição anunciada para 01/10/2026. Uma regra apenas `active=true` é insuficiente.

Fontes oficiais:

- [Resolução do Senado 22/1989](https://www.planalto.gov.br/ccivil_03/congresso/rsf/rsf%2022-89.htm)
- [Resolução do Senado 13/2012](https://planalto.gov.br/ccivil_03/_ato2011-2014/2012/congresso/rsf-13-2012.htm)
- [TIPI atualizada — Receita Federal](https://www.gov.br/receitafederal/pt-br/acesso-a-informacao/legislacao/documentos-e-arquivos/tipi.pdf/view)
- [Decreto SC 479/2020](https://legislacao.sef.sc.gov.br/html/decretos/2020/dec_20_0479.htm)
- [Portaria SRE SP 16/2023](https://legislacao.fazenda.sp.gov.br/Paginas/Portaria-SRE-16-de-2023.aspx)
- [Portaria SRE SP 34/2026](https://legislacao.fazenda.sp.gov.br/Paginas/Portaria-SRE-34-de-2026.aspx)

## 10. Plano recomendado para a Fase 5

### 5A — contenção de segurança e integridade

1. criar migration incremental para fechar execução anônima;
2. remover o fallback silencioso de documento ou transformá-lo em override autorizado;
3. impedir vazio→zero no editor e desativar importação fiscal paralela;
4. corrigir update de estoque para respeitar campos fornecidos;
5. adicionar testes reais de papéis e anon.

### 5B — foundation versionada

1. recuperar baseline 001–042 e a função de resolução;
2. criar histórico imutável/versionado de regras;
3. adicionar status, fundamento legal, referência, responsável e data de validação;
4. impedir sobreposição com constraint/trigger transacional;
5. configurar rotas/filiais em tabela, removendo listas fixas.

### 5C — engine v3 em modo paralelo

1. definir contrato completo de entrada fiscal;
2. manter engine atual como baseline;
3. executar engine v3 em shadow mode, sem afetar preço vendido;
4. comparar por cenário e guardar memória estruturada;
5. promover somente cenários aprovados por responsável fiscal.

### 5D — painel e golden suite

1. simulador com data da operação e memória de cálculo;
2. painel de conflitos, vencimentos e `REQUIRES_FISCAL_VALIDATION`;
3. golden cases com origem documental, responsável e tolerância definida;
4. casos mínimos: PR→PR, SP→SP, SC→SC, PR→SP, PR→SC, SP→PR, SP→SC;
5. testes de quantidade, desconto, contribuinte, não contribuinte, revenda, consumo, origem importada e regras vencidas.

## 11. Decisões que dependem de validação externa

Antes de mudar valores ou ativar a engine v3, a empresa precisa fornecer/confirmar:

- regime tributário e enquadramento dos estabelecimentos PR/SP;
- natureza das operações e CFOPs efetivamente usados;
- perfil fiscal dos clientes e tratamento de consumidor final;
- critério de origem/conteúdo de importação por produto;
- fundamento do ICMS próprio de 4% no cenário SP→SP;
- justificativa tributária do perfil `LEGACY_REVENDA` e sua abrangência;
- regras de inclusão de frete, seguro, desconto e IPI nas bases;
- aplicabilidade de ST por NCM **e descrição/finalidade**, não apenas NCM;
- política para PIS, COFINS e FCP ausentes;
- fontes distintas de preço base PR e SP;
- regra de arredondamento esperada pelo SAP/documento fiscal.

Até essas confirmações, os cenários afetados devem permanecer classificados como `REQUIRES_FISCAL_VALIDATION`, mesmo quando reproduzem a planilha ou um print do portal legado.
