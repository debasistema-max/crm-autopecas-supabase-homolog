# Fase 3 — auditoria mobile, concluída em 02/09/2026

Status: **validada e publicada em homologação**.
Commit funcional publicado: `df20913`.

## Escopo e dependências

Revisados `index.html`, login, templates de Usuários, Logs, Cadastros,
Controle do Portal, Configurações e Impostos; CSS compartilhado; controles
de formulário; renderização de tabelas e seus listeners. A estrutura e CSS
do portal público também foram inventariados, sem alteração.

- Login: `auth.js` → Supabase → sessão → `app.html`; sem alteração de lógica.
- Usuários/Logs: `users.js` → adaptadores existentes; IDs e handlers preservados.
- Cadastros/Controle do Portal: `cadastros.js` → consultas, atualização,
  exportação e anexos; verificação ADMIN preservada.
- Configurações: `company_settings.js` → identidade e persistência; somente
  classe de apresentação adicionada.
- Impostos: `tax_rules.js` → adaptadores/RPCs existentes; somente classes,
  rótulo de textarea e cabeçalho de ações alterados.
- Tabelas: `CrmUi.observeResponsiveTables` continua fornecendo `data-label`.
- Portal público: CSS próprio, cinco etapas, consulta CNPJ, anexos e envio;
  as cinco etapas foram navegadas com dados fictícios, sem submissão.

Não foi necessário criar componente, dependência, tabela, migration ou RPC.

## Achados de código e correções locais

| Achado | Correção preparada |
| --- | --- |
| Grade de 12 colunas mantida em tablet, incluindo campos de uma coluna | Grade de duas colunas somente em `.admin-panel`, entre 681 e 1200 px |
| `span-5` do filtro fiscal sem definição | Definição restrita aos painéis administrativos |
| Campos editáveis de cadastros sem nome acessível | `aria-label` contextual com protocolo, escapado por `escapeHtml` |
| Colunas de ações com cabeçalho vazio | Cabeçalho textual, utilizado também pelos rótulos mobile |
| Anexos com botões de altura apenas textual | Área de toque mínima de 44 px e quebra de textos longos |
| Busca comercial, períodos do dashboard e ações de produtos abaixo de 44 px no tablet | Alvos elevados a 44 px até 980 px |
| Formulários mobile com fonte herdada de 13 px | Fonte de 16 px em controles administrativos e login |
| Login com `overflow: hidden` | Rolagem vertical permitida e altura mínima `100svh` em telas menores |
| Campos editáveis em células dividiam espaço com rótulos | Rótulo acima do controle nas tabelas administrativas mobile |
| Prévia da empresa com texto longo e logo flexível | Contenção de texto e tamanho de logo preservado |

Os achados foram verificados no navegador integrado. A validação cobre o motor
de renderização responsiva, não aparelhos físicos nem o teclado virtual real.

## Riscos fiscais observados — não corrigidos nesta fase

1. `normalizeFiscalImportRecord` usa `|| 0` em impostos não informados.
2. `showFiscalTaxRuleEditor` e `formatPercent` também representam alguns campos
   ausentes como zero. A fixture visual com taxas nulas não valida esse comportamento.
3. `importFiscalTaxRulesFromText` salva uma regra por chamada, sem commit único
   para o arquivo nesta camada. Pode haver gravação parcial se uma chamada falhar.

Requerem auditoria da cadeia completa de adaptadores, RPCs, versões e dados
antes de qualquer alteração. Não são constatações sobre alíquotas legais.
Não utilizar esta revisão mobile como aprovação fiscal.

## Testes executados

`node --test tests/static-ui-contracts.test.cjs`: **7 aprovados, 0 falhas**.

- sintaxe de JavaScript da aplicação e portal público;
- sintaxe dos scripts inline de HTML;
- existência das referências locais a JS/CSS;
- preservação dos IDs críticos dos formulários;
- nomes acessíveis dos controles editáveis de cadastro;
- isolamento do smoke administrativo, sem cliente real de persistência;
- atributos de autofill e alerta do login preservados.

`git diff --check`: aprovado. Nenhuma execução de importação, salvamento,
cálculo fiscal ou autenticação real foi feita nesta entrega.

O runner inicialmente foi bloqueado por `spawn EPERM`; a repetição autorizada
fora da restrição executou os sete testes com sucesso.

## Matriz visual executada

Página: `tests/ui-mobile-admin-smoke.html`.
Parâmetros: `module=users|logs|cadastros|portal|settings|fiscal`;
`scenario=loaded|empty|error`; `editor=true` em Usuários/Impostos;
`role=ADMIN|SUPERVISOR|VENDEDOR` para verificar o guard local do Controle do Portal.

| Superfície | Cobertura executada | Situação |
| --- | --- | --- |
| 6 módulos administrativos | 48 telas carregadas nos 8 breakpoints | Aprovado |
| Estados e editores | 18 cenários de vazio, erro, roles e edição | Aprovado |
| Portal administrativo | SUPERVISOR/VENDEDOR bloqueados sem leitura simulada | Aprovado |
| Login | 7 viewports, incluindo 320×568; sem enviar credenciais | Aprovado |
| Portal público | 7 viewports e navegação das 5 etapas; sem submissão | Aprovado |
| Fluxos comerciais existentes | 48 cenários em 390, 768 e 1440 px | Aprovado |

Resultados: nenhum overflow da página; tabelas extensas permaneceram contidas
em rolagem própria no tablet; nenhum botão abaixo de 44 px após correções;
smokes funcionais aprovados; nenhum erro/warning no console do portal testado.

## Retomada

O navegador esteve indisponível em 28/08. Em 02/09, a conexão foi restabelecida
e a matriz foi executada sem recorrer a outra automação.

Publicação validada em 390, 768 e 1440 px: 21 cenários de módulos/smokes e
4 entradas de login/portal, sem overflow ou falha funcional. Produção e ambos
os bancos permaneceram intocados nesta entrega.
