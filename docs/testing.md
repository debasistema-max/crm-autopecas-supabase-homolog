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
