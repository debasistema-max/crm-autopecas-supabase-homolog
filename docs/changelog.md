# Changelog técnico

## 2026-09-12 — Portal B2B isolado por cliente

- criada uma área separada para o cliente consultar exclusivamente seu cadastro,
  catálogo, preço final da rota, último estoque importado, cotações e pedidos;
- contas B2B ficam vinculadas a um único `client_id` e não recebem perfil nem
  acesso às tabelas internas do CRM;
- ADMIN pode convidar, revogar ou reativar o acesso dentro de Parceiros;
- cliente cria cotação ou pedido sem escolher outro cadastro, rota ou desconto;
- pedido SP→SP preserva a consulta PR e a solicitação de transferência para a
  falta confirmada;
- reenvio usa idempotência, documentos internos são vinculados por SAP/CNPJ e
  alterações cadastrais dependem de aprovação administrativa auditada;
- o lint remoto identificou e a migration 072 corrigiu a ambiguidade de variável
  que impediria a busca do catálogo em execução;
- migrations e Edge Function preparadas somente para homologação; produção não
  foi alterada.

## 2026-09-12 — preço comercial por rota e Revenda

- o diagnóstico do pedido `000038` confirmou que o item `6175522372` tinha
  saldo PR `50+`, enquanto SP ainda não possuía snapshot importado; o backend
  preservou a regra “ausente não é zero” e registrou
  `ESTOQUE_SP_NAO_IMPORTADO`, sem criar uma transferência indevida;
- a criação do pedido agora destaca, acima dos itens, o resultado da verificação
  SP/PR e a busca de produtos mostra os dois saldos; o aviso usa o saldo
  transferível líquido de reservas, e zero confirmado continua diferente de
  estoque não importado;
- cotação e pedido passam a operar somente como Revenda, removendo a escolha de
  Consumo da criação e normalizando também rascunhos e payloads antigos;
- PR→PR, PR→SC e SP→SP passam a priorizar o preço final aprovado que o Excel já
  consolidou e sincronizou em `product_route_prices`;
- o motor fiscal interno permanece como contingência explicitamente marcada
  quando o preço da rota está ausente ou não aprovado;
- preço, tributos, origem, versão e lote do Excel são preservados no snapshot do
  item para auditoria;
- alteração preparada e validada somente para homologação; produção permanece
  fora do escopo.
- pedidos SP→SP com saldo SP insuficiente agora consultam PR, exibem o aviso no
  item e criam solicitação de transferência PR→SP ao salvar;
- a quantidade transferida corresponde somente à falta e fica limitada ao saldo
  disponível de PR, com aviso quando o atendimento for parcial;
- removida a criação técnica de estoque zero: snapshot SP/PR ausente permanece
  desconhecido e impede transferência automática até a próxima importação.

## 2026-09-10 — Central de Dados e sincronização Excel

- adicionada camada Excel/adapter → normalização → validação → lotes → Supabase, sem dependência do arquivo em tempo de execução do CRM;
- incluídos UPSERT parcial, diferenciação entre campo ausente e zero, idempotência, proteção contra lote antigo e concorrência otimista;
- estoque por filial continua em `product_branch_stock`, preço-base continua em `product_branch_prices` e resultados consolidados por rota foram isolados em `product_route_prices`;
- auditoria por campo e movimento `SYNC_ERP` identificam origem, lote, filial, rota, valor anterior e valor novo;
- criada Central de Dados administrativa e preservada a importação manual como “Importação e Integrações”;
- o adapter rejeita o lote se o OneDrive substituir o XLSX durante a leitura;
- a cópia oficial de 18 abas na raiz do OneDrive foi validada, incluindo o novo cabeçalho `PREÇO FINAL`;
- a Edge Function valida sessão e perfil ADMIN antes de contatar o adapter; chave anônima retorna 401;
- migrations 060–061 e Edge Function versão 2 aplicadas somente em homologação; produção não foi acessada;
- adicionados testes de contrato, integração, autorização e carga de 4.000 registros;
- rollback automático de lote não foi exposto nesta fase: a documentação descreve a reversão futura com verificação de versão para não apagar mudanças posteriores.

## 2026-09-03 — Fase 5B: versionamento e ciclo de vida fiscal

- Motivo: impedir alteração destrutiva de regras em uso e tornar cada mudança
  rastreável sem declarar como validados dados vindos de SAP/planilha.
- Banco: migrations 058–059 aplicadas somente em `mtwvxyvpnbgwgltelozw`.
- Regras existentes: 76 preservadas, classificadas `REVIEW_REQUIRED` e copiadas
  para 76 snapshots de baseline; alíquotas e fórmulas não foram alteradas.
- Novas regras: nascem `DRAFT`, fora do cálculo; validação exige fundamento,
  motivo, usuário e data; ativação é transacional.
- Versionamento: regra ativa é imutável; sucessora recebe novo ID e encerra a
  vigência anterior somente ao ser ativada.
- Histórico: `fiscal_tax_rule_versions` rejeita update/delete e é consultado por
  RPC administrativa; exclusão do painel virou desativação auditada.
- Snapshot comercial: cotação/pedido registra status, fundamento e alerta
  `REQUIRES_FISCAL_VALIDATION` quando usa regra legada pendente.
- Interface: filtros de ciclo de vida, nova versão, validar/ativar, solicitar
  revisão, desativar e consultar histórico.
- Testes: 11/11 regressões SQL, 7/7 contratos estáticos e sintaxe JavaScript
  aprovados. Golden cases permaneceram idênticos.
- Risco preservado: importação que tentar sobrescrever regra ativa é bloqueada
  no commit; levar esse diagnóstico ao preview é pendência da próxima entrega.
- Produção: não acessada e não alterada.

## 2026-09-02 — Fase 5A: contenção fiscal e integridade

- Motivo: eliminar as exposições e gravações inseguras encontradas na auditoria,
  sem modificar os valores ou as fórmulas fiscais congeladas como baseline.
- Segurança: as RPCs fiscais, comerciais e de importação listadas na migration
  055 deixaram de herdar `EXECUTE` de `PUBLIC`/`anon`; `authenticated` recebeu
  somente a execução necessária. Teste externo sem sessão passou a responder 401.
- Documentos: cotação/pedido com snapshot fiscal inválido agora falham dentro da
  transação. Registros históricos sem snapshot não foram alterados.
- Regras: UF limitada às 27 unidades federativas, alíquotas obrigatórias validadas,
  `NULL` preservado como “não definido” e conflito de vigência ativa bloqueado
  por trigger com trava transacional.
- Importação: a gravação fiscal direta por linha foi removida da interface; o
  operador é encaminhado ao fluxo staging → validação → preview → aprovação →
  commit. A decisão de ST deve vir de uma coluna ou seleção explícita.
- Estoque: atualização parcial originada do staging preserva todas as colunas SAP
  ausentes na linha, mantendo a semântica de field mask.
- Banco alterado: somente homologação `mtwvxyvpnbgwgltelozw`, migrations 055–057.
  Produção não foi acessada.
- Testes: 9/9 regressões SQL executadas com `ROLLBACK`, 7/7 contratos estáticos
  e 22/22 arquivos JavaScript aprovados em verificação de sintaxe.
- Cálculos preservados: PR→PR 347,854460; SP→SP 346,791931; PR→SC 263,900000.
- Pendências: versionamento imutável, classificação de componentes tributários
  ausentes, validação legal do perfil `LEGACY_REVENDA` e recuperação do baseline
  001–042 continuam na Fase 5B/5C.
- Publicação do frontend: concluída após autorização explícita. O workflow
  `pages-build-deployment` 33703217362 terminou com sucesso; login público abriu
  sem erro de console e os assets publicados confirmaram a Central de
  Importações, seleção explícita de ST e remoção do importador fiscal direto.

## 2026-09-02 — Fase 4: auditoria fiscal

- Motivo: mapear integralmente regras, fórmulas, importações, seleção de preço,
  snapshots, segurança e evidências legais antes de modificar o motor fiscal.
- Antes: a documentação descrevia a implementação e os casos de regressão, mas
  não classificava riscos nem separava equivalência com planilha de validação
  tributária.
- Depois: `fiscal-audit.md` registra arquitetura, fórmulas, dependências,
  duplicações, riscos priorizados, golden cases e plano seguro para a engine v3.
- Banco alterado: não. Migration: nenhuma. Dados fiscais: nenhum valor alterado.
- Verificação real somente leitura: `get_product_commercial_price` e
  `get_fiscal_pending` responderam anonimamente na homologação; o perfil
  `LEGACY_REVENDA` ativo também foi confirmado.
- Testes locais: 7/7 contratos estáticos e 25/25 verificações de sintaxe
  JavaScript aprovados; regressões SQL não foram executadas no banco vivo.
- Riscos bloqueantes: execução anônima de RPCs, fallback de preço legado em
  documento fiscal inválido, perfil de revenda inferido de um caso, histórico
  mutável e baseline 001–042 ausente do Git.
- Planilha: hash confirmado; releitura estruturada independente ficou pendente
  porque a ferramenta obrigatória não concluiu a importação. Nenhuma biblioteca
  alternativa foi usada e o XLSX não foi alterado.
- Fontes legais: somente documentos oficiais de Senado/Planalto, Receita
  Federal, SEFAZ-SC e SEFAZ-SP. Cenários não certificados foram marcados
  `REQUIRES_FISCAL_VALIDATION`.
- Produção: não acessada e não alterada.

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

## 2026-09-12 — Acesso B2B sem e-mail

- ADMIN pode criar ou redefinir acesso por usuário/CNPJ e senha inicial;
- o cliente não precisa informar nem possuir e-mail;
- a primeira entrada exige troca de senha antes de liberar catálogo, estoque,
  preços, cotações ou pedidos;
- senha inicial não é gravada em logs e a identidade técnica permanece restrita
  ao backend/autenticação;
- convite por e-mail continua disponível como opção administrativa;
- migration 073 e Edge Function `b2b-admin` publicadas somente na homologação.

## 2026-09-17 — Busca combinada no catálogo B2B

- termos digitados são separados e pesquisados em código, OEM, descrição,
  marca, veículo e aplicação;
- correspondências com todas as palavras recebem prioridade;
- resultados relacionados por parte da busca aparecem em seguida;
- filtro de preço aprovado por rota é aplicado antes do limite de resultados;
- migration 074 aplicada e validada somente na homologação.
