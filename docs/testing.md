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
