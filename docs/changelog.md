# Changelog técnico

## 2026-09-02 — Fase 3: administração, login e regressão mobile

- Motivo: preparar formulários e tabelas administrativas para mobile/tablet.
- Antes: grade de 12 colunas em tablet, controles de cadastro sem nome acessível,
  ações de anexo pequenas e login com overflow oculto.
- Depois: grade administrativa em duas
  colunas no tablet; rótulos de ação/controles; áreas de toque; fonte mobile;
  rolagem vertical do login. Fórmulas, handlers e persistência preservados.
- Arquivos: `app.html`, `index.html`, `css/app.css`, `css/login.css`,
  `js/users.js`, `js/cadastros.js`, `js/company_settings.js`, `js/tax_rules.js`,
  `tests/ui-mobile-admin-smoke.html`, `tests/static-ui-contracts.test.cjs`,
  `docs/mobile-audit.md`, `docs/mobile-guidelines.md`, `docs/testing.md` e este arquivo.
- Banco alterado: não. Migration: nenhuma. RPC/RLS: sem alteração.
- Testes: 7 estáticos, 66 administrativos, 7 login, 7 portal público,
  navegação das 5 etapas e 48 regressões gerais aprovados.
- Regressão corrigida: busca de cliente em cotações/pedidos, períodos do
  dashboard e ações rápidas de produtos tinham alvo inferior a 44 px no tablet.
- Risco: roles são simuladas e não comprovam RLS; teclado virtual e aparelhos
  físicos não foram controlados pelo navegador de teste.
- Achados fiscais: defaults de zero e importação legada por linha registrados
  em `mobile-audit.md`; nenhuma correção fiscal presumida.
- Publicação: commit funcional `df20913` aprovado no GitHub Pages de homologação;
  25 verificações públicas aprovadas. Produção não alterada.

## 2026-08-27 — Fase 2, entrega 4: importações e transferências

- Central de Importações recebeu cabeçalho, navegação semântica e indicador das
  cinco etapas: upload, detecção, validação, preview e confirmação;
- nova importação, histórico, pendências fiscais e listas comerciais passaram a
  usar estados e tabelas responsivas do design system;
- listas comerciais agora exibem loading, vazio e erro de forma explícita, sem
  alterar a RPC que calcula preço, tributos e disponibilidade;
- Transferências recebeu filtros, métricas, tabela e controles responsivos;
- corrigido o comportamento visual de elementos com atributo `hidden`, evitando
  exibição de campos e painéis condicionais;
- criado smoke operacional que comprova que campo vazio não entra no payload
  normalizado e que preview não aprova nem confirma um lote automaticamente;
- nenhuma migration, RPC, RLS, transição de estoque ou permissão foi alterada.

Risco remanescente: os testes de interface usam RPCs simuladas para impedir
gravações. As regressões SQL existentes continuam sendo a evidência do commit
atômico, idempotência e auditoria no banco.

## 2026-08-27 — Fase 2, entrega 3: relatórios e edição comercial

- relatórios de cotações e pedidos passaram a usar cabeçalho, filtros, métricas,
  estados e tabelas do design system;
- edição de documentos foi integrada ao layout comercial responsivo sem alterar
  as rotinas existentes de salvar, efetivar, cancelar, duplicar ou converter;
- memória fiscal histórica passou a identificar explicitamente o snapshot e a
  exibir a composição disponível de IPI, ICMS próprio e ICMS-ST;
- abertura de cotação e pedido possui regressão que garante ausência de novo
  cálculo fiscal e ausência de mutações no banco;
- corrigida contenção de largura das tabelas no grid, eliminando overflow entre
  320 e 1440 px;
- controles touch da edição passaram a respeitar no mínimo 44 px;
- nenhuma migration, RPC, permissão, status ou fórmula fiscal foi alterada.

Risco remanescente: a edição continua refletindo apenas os campos fiscais já
armazenados no snapshot. Documentos legados sem detalhes fiscais permanecem
identificados como preço legado e não recebem valores presumidos.

## 2026-08-27 — Fase 2, entrega 2: cotações e pedidos

- criação de cotação e pedido passou a usar cabeçalho e estados do design system;
- dados gerais, itens, frete, totais e ações receberam hierarquia visual própria
  para operação comercial;
- abas agora expõem estado selecionado para tecnologias assistivas;
- tabelas de itens mantêm alta densidade no desktop e apresentação em cartões
  estruturados no celular;
- botões de busca receberam ícone consistente e nomes acessíveis;
- criado smoke conjunto que exige igualdade entre o preço fiscal da cotação e do
  pedido para o produto `6111032201` na rota PR→PR;
- nenhuma fórmula, RPC, payload de salvamento, snapshot, regra de estoque ou
  permissão foi alterada.

Risco remanescente: os relatórios e a edição de documentos ainda utilizam parte
do visual legado e serão tratados em uma entrega posterior.

## 2026-08-26 — Fase 2, entrega 1: módulos operacionais

- Dashboard, Parceiros e Produtos passaram a usar cabeçalhos e estados do
  design system compartilhado;
- filtros do dashboard foram separados da apresentação dos indicadores;
- cadastros de clientes e transportadoras receberam abas semânticas, hierarquia
  de formulário e barra de pesquisa responsiva;
- consulta gratuita de CNPJ foi preservada e revalidada nos dois cadastros;
- catálogo de produtos recebeu hierarquia consistente para pesquisa, filtros,
  resultados e detalhe;
- corrigidos alvos de toque dos períodos do dashboard e favoritos de produtos;
- criado smoke operacional isolado com dados simulados para os três módulos;
- nenhuma consulta, permissão, regra comercial, migration ou fórmula fiscal foi
  alterada.

Risco remanescente: as telas SAP de cotação e pedido possuem layout e regras
próprias. Serão migradas separadamente, com regressões fiscais antes de qualquer
mudança de comportamento.

## 2026-08-26 — Fase 1: fundação visual

- ampliados os tokens de design e estados semânticos;
- sidebar reorganizada por contexto e recolhível no desktop;
- topbar compactada com módulo, usuário e perfil;
- criado namespace `CrmUi` para componentes compartilhados;
- tabelas genéricas passaram a receber rótulos no mobile;
- adicionadas diretrizes de arquitetura, design, mobile e testes;
- nenhuma alteração de banco, migration ou fórmula fiscal.

Risco principal: módulos legados ainda possuem HTML próprio e serão migrados
progressivamente. A camada compartilhada foi adicionada sem remover contratos
anteriores.
