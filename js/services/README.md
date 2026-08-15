# Services

Servicos coordenam casos de uso do frontend.

Uso esperado:

- combinam repositories, validacoes e formatacoes;
- preservam comportamento atual;
- nao renderizam HTML;
- nao acessam diretamente DOM.

Estado atual: as chamadas de servico ainda estao expostas em `public/js/supabase_store.js`.
