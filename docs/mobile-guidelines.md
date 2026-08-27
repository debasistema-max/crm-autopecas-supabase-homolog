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
