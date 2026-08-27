# Components

Componentes visuais reutilizaveis do CRM.

Uso esperado:

- componentes sem acesso direto ao Supabase;
- recebem dados prontos por parametro;
- retornam HTML ou fazem binding de UI isolado;
- nao conhecem regras de negocio de Produtos, Pedidos, Cotacoes ou Importacao.

## Componentes disponíveis

`ui.js` expõe `window.CrmUi` com primitivas sem acesso ao Supabase:

- `renderPageHeader`;
- `renderState`;
- `renderStatusBadge`;
- `enhanceResponsiveTables`;
- `observeResponsiveTables`.

A melhoria de tabelas lê os cabeçalhos existentes e adiciona `data-label` às
células. No mobile, o CSS usa esse metadado para apresentar cada linha como
uma lista rotulada. `sap-items-table` continua com o contrato específico de
cotações e pedidos.

Os módulos legados devem ser migrados gradualmente. Não mover regras de
negócio ou chamadas Supabase para esta pasta.
