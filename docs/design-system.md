# Design system

## Princípios

- ferramenta de trabalho, não painel decorativo;
- hierarquia clara e densidade adequada;
- uma ação primária por contexto;
- estados fiscais e operacionais nunca dependem somente de cor;
- comportamento consistente entre módulos.

## Tokens

Os tokens ficam em `css/theme.css`:

- superfícies: `--bg`, `--surface`, `--surface-subtle`;
- texto: `--text`, `--text-strong`, `--muted`;
- semântica: `--primary`, `--success`, `--warning`, `--danger`, `--info`;
- estrutura: `--line`, `--radius-*`, `--space-*`, `--shadow-*`;
- acessibilidade: `--focus-ring` e redução de movimento.

Não adicionar cores ou sombras isoladas quando já existir token equivalente.

## Componentes fundamentais

- `.btn`: primário, secundário e neutro;
- `.status-pill`: `ok`, `warn`, `error` e `info`;
- `.page-header`: título, descrição e ações;
- `.ui-state`: vazio, erro, carregamento e sucesso;
- `.panel`: agrupamento de conteúdo, não um card decorativo;
- `CrmUi`: renderização e melhoria responsiva compartilhada.

## Navegação

A sidebar é organizada por Comercial, Catálogo, Operação, Gestão e Sistema.
No desktop ela pode ser recolhida; no tablet e celular torna-se drawer. Os
módulos continuam filtrados pelas permissões existentes.
