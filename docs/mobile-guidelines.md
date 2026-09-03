# Diretrizes mobile

Breakpoints de validação: 320, 360, 375, 390, 430, 768, 1024 e desktop.

## Contratos

- controles de operação com pelo menos 44 px;
- nenhuma ação depende exclusivamente de hover;
- sidebar vira drawer abaixo de 981 px;
- navegação rápida inferior abaixo de 681 px;
- ações finais devem permanecer acessíveis com teclado virtual;
- tabelas não devem apenas encolher.

## Tabelas

`CrmUi.observeResponsiveTables` adiciona o cabeçalho de cada coluna como
`data-label`. Abaixo de 681 px, linhas genéricas tornam-se listas rotuladas.
Cotações e pedidos mantêm o contrato próprio de `.sap-items-table`.

Ao criar uma tabela dinâmica, use `thead` e mantenha a mesma quantidade e ordem
de `th` e `td`. Isso permite melhoria automática sem duplicar marcação.

## Formulários

- usar labels visíveis;
- `input`, `select` e `textarea` ocupam a largura disponível;
- ações primárias devem aparecer antes das secundárias;
- mensagens devem explicar como corrigir o problema;
- não esconder contexto fiscal ou de filial em detalhes dependentes de hover.

## Painéis administrativos

Correções validadas no navegador na Fase 3:

- `.admin-panel` limita as regras novas aos módulos administrativos;
- entre 681 e 1200 px, formulários usam duas colunas; `span-12` ocupa ambas;
- abaixo de 681 px, manter uma coluna, inclusive o filtro `span-5`;
- no mobile, células editáveis mostram o rótulo acima do controle;
- controles usam fonte de 16 px até 980 px e ações/anexos têm alvo de 44 px;
- login permite rolagem vertical e controles de 46 px nas telas menores.
- busca de cliente, períodos do dashboard, atalhos e favoritos de produtos
  mantêm alvo mínimo de 44 px até 980 px.

Não usar `overflow: hidden` para mascarar conteúdo cortado. Verificar altura
curta e teclado virtual antes de aprovar uma tela. Consulte a matriz executada
em [mobile-audit.md](mobile-audit.md).
