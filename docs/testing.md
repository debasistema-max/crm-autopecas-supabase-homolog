# Estratégia de testes

## Validações atuais

- `node --test tests/static-ui-contracts.test.cjs`: runner estático sem dependências,
  com sintaxe, referências, IDs e contratos de acessibilidade (não substitui browser);
- `node --check` para JavaScript não vendorizado;
- smoke pages em `tests/` para fiscal, importações e consulta CNPJ;
- smoke operacional em `tests/ui-operational-smoke.html`, selecionável por
  `?module=dashboard`, `?module=products` ou `?module=partners`;
- smoke de relatórios e edição comercial em
  `tests/ui-document-reports-smoke.html?kind=cotacoes` e `?kind=pedidos`;
- smoke de Transferências e Central de Importações em
  `tests/ui-operations-control-smoke.html`;
- regressões SQL em `supabase/tests/`;
- inspeção responsiva nos breakpoints definidos.

## Evidência SP → PR — 2026-09-12

- pedido real `000038`, item `6175522372`, quantidade 8: SP sem snapshot
  importado e PR com disponibilidade `50+`;
- o backend retornou `ESTOQUE_SP_NAO_IMPORTADO` e não criou transferência nem
  linha falsa de estoque zero;
- smoke de pedido aprovado em 390×844 e 1440×1000, sem overflow horizontal;
- cenário SP zero confirmado exibiu a futura solicitação PR→SP; cenário SP
  ausente exibiu o bloqueio e o saldo transferível PR 50; PR totalmente
  reservado não foi apresentado como disponível para transferência;
- 14 contratos Node e 15 testes Python aprovados.

## Evidência da Fase 2 — entrega 1

- Dashboard, Produtos e Parceiros inspecionados em 320, 360, 375, 390, 430,
  768, 1024 e 1440 px;
- nenhum overflow horizontal detectado nos 24 cenários;
- nenhum botão visível abaixo de 44 px nos cinco breakpoints mobile;
- alternância entre Clientes e Transportadoras validada;
- consulta CNPJ validada com resposta simulada da BrasilAPI, incluindo
  preenchimento e formatação dos campos;
- a página de smoke usa somente dados locais simulados e não grava no Supabase.

## Evidência da Fase 2 — entrega 2

- criação de Cotação e Pedido inspecionada em 320, 360, 375, 390, 430, 768,
  1024 e 1440 px;
- nenhum overflow da página detectado nos 16 cenários;
- nenhum botão visível abaixo de 44 px nos breakpoints mobile;
- abas Itens e Frete/Pagamento validadas com `aria-selected` sincronizado;
- item fiscal `6111032201`, PR→PR, validado com base de R$ 232,00, tributos de
  R$ 115,85446 e preço final de R$ 347,85446;
- Cotação e Pedido obrigatoriamente recebem o mesmo preço no smoke;
- `tests/ui-commercial-documents-smoke.html` não salva documentos nem acessa o
  Supabase.

## Evidência da Fase 2 — entrega 3

- relatórios e edição de Cotações e Pedidos inspecionados em 320, 360, 375,
  390, 430, 768, 1024 e 1440 px;
- nenhum overflow da página detectado nos 16 cenários;
- nenhum botão visível abaixo de 44 px até 980 px;
- tabela responsiva, filtros, métricas e abas da edição validados;
- snapshot do produto `6111032201` validado com NCM `8512.20.11`, base de
  R$ 232,00, tributos de R$ 115,85446 e preço final de R$ 347,85446;
- memória validada com IPI de R$ 22,62, ICMS próprio de R$ 27,84 e ICMS-ST de
  R$ 65,39446;
- o teste exige zero chamadas de recálculo fiscal e zero mutações ao abrir o
  documento;
- `tests/ui-document-reports-smoke.html` usa dados locais simulados e não grava
  no Supabase.

## Evidência da Fase 2 — entrega 4

- Transferências, nova importação, histórico, pendências fiscais e listas
  comerciais inspecionados em 320, 360, 375, 390, 430, 768, 1024 e 1440 px;
- nenhum overflow da página e nenhum botão visível abaixo de 44 px nos 40
  cenários avaliados;
- mapeamentos SAP existentes para preço, estoque, item, CEST e regras fiscais
  permaneceram aprovados;
- importação simulada de estoque PR preservou `50+` como quantidade 50 com
  indicador de limite;
- linha com disponibilidade vazia não incluiu o campo no payload normalizado;
- staging e preview simulados foram executados, mantendo zero chamadas de
  aprovação e zero chamadas de commit;
- leitura de histórico, pendências e lista PR-PR validada sem gravação;
- atualização de transferência permaneceu condicionada à ação explícita
  `Salvar` e registrou zero chamadas durante a abertura do smoke.

## Antes de publicar homologação

1. verificar worktree e diff;
2. executar sintaxe JavaScript;
3. abrir login e shell autenticado;
4. testar menu expandido, recolhido e drawer;
5. testar permissões de ADMIN, SUPERVISOR e VENDEDOR;
6. testar tabelas em 320 e 768 px;
7. executar regressões SQL somente em banco descartável ou transação controlada;
8. confirmar que nenhuma migration de produção foi acionada.

## Portal B2B — 2026-09-12

- contratos estáticos verificam identidade exclusiva, políticas internas,
  catálogo, documentos, idempotência, transferência SP→PR e ausência de chave
  privilegiada no navegador;
- `tests/ui-b2b-smoke.html` valida login simulado, rota PR→SC, catálogo, carrinho
  e criação de cotação em mobile, tablet e desktop;
- `tests/ui-b2b-admin-smoke.html` valida convite, revogação e análise de alteração
  cadastral no painel ADMIN;
- chamadas anônimas às RPCs B2B devem retornar 401;
- `b2b-admin` deve recusar chamadas sem sessão e chamadas de não-ADMIN;
- aprovação cadastral e vínculo de documentos internos são cobertos pela
  migration 071 com trava concorrente e auditoria.
- resultado final: 15/15 contratos Node, 15/15 testes Python, 30 arquivos com
  sintaxe JavaScript válida e 6/6 cenários visuais B2B aprovados, sem overflow;
- migrations 069–072 estão registradas na homologação e o lint remoto não aponta
  erros nas funções B2B. Os avisos restantes pertencem a funções legadas fora
  deste escopo;
- o arquivo SQL 071 foi preparado, mas o runner `pg_prove` da CLI não pôde ser
  iniciado porque o Docker Desktop não está instalado. A compilação das quatro
  migrations e os testes externos de negação anônima foram concluídos.

## Catálogo B2B — linhas e fotos — 2026-09-17

- migration 076 aplicada exclusivamente na homologação;
- regressão SQL 074 executada dentro de transação com `ROLLBACK`, validando
  busca por todas as palavras, filtro de linha, preço aprovado e foto oficial;
- carga pública processou 1.743 registros: 1.735 códigos correspondentes e 8
  ignorados; nenhum preço, estoque ou cadastro operacional foi alterado;
- snapshot final: 1.735 produtos com foto, 10 linhas e 1.701 produtos com ao
  menos uma rota de preço aprovada;
- a busca `caixa hilux` encontrou 5 produtos com preço aprovado;
- contratos Node e testes Python incluem o snapshot, idempotência, fallback de
  imagem, filtro de linha e abertura da foto ampliada.

## Desconto comercial por cliente — 2026-09-17

- migration 078 aplicada exclusivamente na homologação;
- desconto padrão criado no cadastro canônico do cliente, com alteração
  restrita a ADMIN e limite herdado de `max_discount_percent()` (10% no teste);
- regressão SQL transacional confirmou preço de R$ 100,00 convertido em R$ 92,50
  para cliente com 7,5%, além do bloqueio de valor acima do limite;
- criação B2B recalcula no banco e grava preço de tabela, percentual, preço
  líquido, desconto total e total do documento;
- criação interna de cotação/pedido recebe o percentual padrão ao selecionar o
  cliente, mantendo a edição por item já existente e o mesmo limite global.

## Lacunas

Há um runner estático mínimo, mas ainda não há runner visual/integração,
lint, typecheck ou CI. A centralização fiscal v2 exige regressões adicionais.

## Fase 3 — validação local concluída

Em 02/09/2026, os 7 testes estáticos passaram. O smoke administrativo
`tests/ui-mobile-admin-smoke.html` foi preparado com dados simulados,
cenários de erro/vazio, edição e guard do portal. Foram aprovados 66 cenários
administrativos, 7 de login, 7 viewports do portal público, a navegação das
cinco etapas sem submissão e 48 regressões dos módulos já entregues.

A matriz e os limites da evidência estão em [mobile-audit.md](mobile-audit.md).
O teste de roles simulado não comprova RLS ou permissões reais do Supabase.

## Fase 4 — evidência da auditoria fiscal

- `node --test tests/static-ui-contracts.test.cjs`: 7/7 aprovados;
- `node --check`: 25 arquivos JavaScript aprovados;
- o hash SHA-256 da planilha recebida coincide com o golden test versionado;
- regressões SQL existentes foram revisadas, mas não reexecutadas contra o banco
  vivo nesta fase de auditoria;
- consultas somente leitura confirmaram os casos PR→PR e SP→SP Revenda na
  homologação;
- teste sem sessão confirmou acesso anônimo indevido a
  `get_product_commercial_price` e `get_fiscal_pending`;
- PIS, COFINS e FCP permaneceram nulos, porém o status retornado foi `OK`;
- nenhuma função de escrita foi chamada e nenhum dado foi alterado;
- a releitura estruturada direta do XLSX permanece pendente: a ferramenta
  obrigatória não concluiu a importação e foi interrompida sem editar o arquivo.

O relatório detalhado e a matriz de riscos estão em
[fiscal-audit.md](fiscal-audit.md).

## Fase 5A — contenção fiscal e integridade

Em 02/09/2026, as migrations 055–057 foram validadas e aplicadas exclusivamente
no Supabase de homologação. A suíte SQL completa foi executada contra esse banco;
cada arquivo abre transação e termina com `ROLLBACK`:

- `047_fiscal_engine_regression.sql`: golden cases PR→PR, SP→SP e PR→SC;
- `048_sap_import_center_regression.sql`: permissões, Cadastro Item SAP,
  idempotência, campo vazio, estoque/preço PR, fiscal PR, cotação e pedido;
- `049_all_import_types_regression.sql`: cadastro comercial, estoque/preço SP e
  fiscal SP;
- `050_reference_workbook_regression.sql`: referência integral da planilha;
- `053_legacy_resale_profile_regression.sql`: compatibilidade do perfil Revenda;
- `054_resale_profile_admin_regression.sql`: administração do perfil Revenda;
- `055_fiscal_security_and_document_guard_regression.sql`: privilégios e bloqueio
  atômico de documento com cálculo inválido;
- `056_fiscal_rule_input_integrity_regression.sql`: UF inválida, distinção entre
  `NULL` e zero e conflito de vigência;
- `057_partial_stock_field_mask_regression.sql`: preservação das colunas omitidas
  em importação parcial de estoque.

Resultado: 9/9 arquivos SQL aprovados, 7/7 contratos estáticos aprovados e 22/22
arquivos JavaScript aprovados em `node --check`. O uso de `node --test` encontrou
uma restrição `spawn EPERM` do sandbox; o mesmo arquivo foi executado diretamente
com o runner nativo e os sete casos passaram.

Verificações adicionais:

- a tentativa anônima às RPCs protegidas retorna HTTP 401;
- `authenticated` mantém `EXECUTE` conforme regressão SQL;
- as três migrations respondem `ALREADY_APPLIED` no histórico da homologação;
- os valores fiscais esperados permaneceram inalterados.

Após autorização explícita, os commits foram publicados no GitHub de
homologação. O workflow `pages-build-deployment` 33703217362 terminou com
sucesso. O smoke público confirmou a tela de login sem erros de console e os
assets publicados contêm `taxRuleOpenImportCenter` e “Selecione explicitamente”,
sem as rotinas removidas `importFiscalTaxRulesFromText` e “Automático: PR→SC sem
ST”.

## Fase 5B — versionamento fiscal

Em 03/09/2026, migrations 058–059 foram primeiro executadas junto das 11
regressões dentro de uma única transação descartada. Após aprovação desse ensaio,
foram aplicadas somente na homologação e os mesmos 11 arquivos passaram outra
vez, cada um com `ROLLBACK`.

Os testes novos comprovam histórico imutável, incremento de versão, rascunho
fora do cálculo, fundamento obrigatório, bloqueio de edição de regra em uso,
criação de sucessora, ativação atômica, resolução histórica, desativação sem
delete, permissões e ausência de privilégios anônimos. A regressão 048 também
comprova que o snapshot comercial recebe `rule_lifecycle_status` e
`REQUIRES_FISCAL_VALIDATION`.

Estado remoto verificado: 76 regras `REVIEW_REQUIRED`, 76 snapshots de baseline
e migrations 058/059 registradas. Os três resultados da planilha não mudaram.

O smoke administrativo fiscal passou em 320, 768 e 1024 px: editor de rascunho,
rótulos, tabela responsiva e ausência de mutações automáticas foram aprovados,
sem overflow horizontal nos três breakpoints.

## Central de Dados

- `060_excel_data_sync_center_regression.sql`: permissões, código Excel,
  produto novo, atualização parcial, vazio, limpeza explícita, zero, filial,
  preço de rota, idempotência, lote antigo, concorrência, falha parcial,
  `SYNC_ERP`, auditoria e filtros de erro;
- `060_excel_data_sync_performance_regression.sql`: staging e validação de 4.000
  produtos em uma transação descartável;
- `061_excel_sync_edge_authorization_regression.sql`: `anon` sem execução do
  predicado, ADMIN autorizado e identidade autenticada sem perfil negada;
- `scripts/build_excel_sync_payload.py`: executado contra a referência real,
  sem salvar ou alterar o XLSX;
- o contrato estático verifica navegação, controles, Edge Function e ausência de
  service role/token no frontend.

Em 10/09/2026, as migrations 060–061 foram aplicadas somente na homologação. A
regressão 060 e o teste de 4.000 registros passaram novamente contra o schema
instalado com `ROLLBACK`; a carga levou 4,85 s. A Edge Function versão 2 ficou
ativa e respondeu HTTP 401 tanto sem credencial quanto com a chave anônima.

Em 12/09/2026, a migration 066 foi aplicada somente na homologação. A regressão
`066_excel_route_price_priority_regression.sql`, executada com `ROLLBACK`,
comprovou prioridade do preço final Excel, normalização de Consumo para Revenda,
snapshot de cotação e contingência identificada para rota ausente. Uma consulta
somente leitura confirmou `EXCEL_ROUTE_PRICE` para o produto `6111032201` em
PR→PR, PR→SC e SP→SP. Os 13 contratos JavaScript, 15 testes Python e o smoke de
cotação/pedido em 390 e 1440 px passaram sem overflow.

A migration 067 e sua regressão transacional comprovaram que um pedido SP→SP
com saldo SP zero e saldo PR disponível cria uma solicitação PR→SP com a
quantidade correta. Um segundo cenário sem snapshot SP comprovou ausência de
transferência e ausência de criação artificial de estoque zero. O aviso visual
foi validado em 390 e 1440 px sem overflow.

## Portal B2B sem e-mail

Em 12/09/2026, a migration 073 foi aplicada somente na homologação. Os 15
contratos estáticos, 15 testes Python e 6 cenários visuais do portal e painel
administrativo passaram em 390×844, 768×1024 e 1440×1000. A função `b2b-admin`
foi republicada e respondeu HTTP 401 sem autenticação. O lint remoto não apontou
erros no módulo B2B; os avisos exibidos pertencem a funções legadas já
existentes.

Os contratos verificam usuário/CNPJ normalizado, identidade técnica somente no
backend, ausência de senha na auditoria, bloqueio antes da troca da senha
inicial e manutenção do convite por e-mail como contingência opcional.

## Busca combinada do catálogo B2B

Em 17/09/2026, a migration 074 foi aplicada somente na homologação. A regressão
`074_b2b_catalog_search_regression.sql` passou dentro de transação encerrada com
`ROLLBACK`: produto contendo os dois termos ficou em primeiro lugar, produtos
relacionados por aplicação ou descrição também foram retornados e o produto sem
preço aprovado para a rota permaneceu oculto.

Na sequência, a migration 075 alinhou o contrato ao catálogo público Yokomitsu:
todas as palavras-chave passaram a ser obrigatórias, o filtro de linha foi
adicionado e somente linhas com preço aprovado para a rota são listadas. A mesma
regressão foi atualizada para exigir combinação completa, linha correta e preço
de rota; as imagens oficiais por código possuem fallback visual quando ausentes.
O smoke visual passou em 9/9 cenários: B2B, administração B2B e catálogo interno
em 390×844, 768×1024 e 1440×1000, sem overflow horizontal.
