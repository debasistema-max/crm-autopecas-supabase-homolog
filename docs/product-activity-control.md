# Situacao administrativa dos produtos

Migration 109 preserva a decisao do ADMIN em `product_activity_overrides`, sem
dependencia de exclusao em cascata de products. A carga inicial copia apenas
itens atualmente inativos. Nao infere estados passados nem altera itens ativos.

`guard_product_activity` aplica a decisao persistida em INSERT e UPDATE.
Sincronizacoes Excel, SAP, catalogo e escritas genericas nao decidem ativo/inativo,
mesmo quando iniciadas por ADMIN. Novos codigos sem decisao sao ativos.

`set_product_active` mantem o contrato anterior, exige ADMIN interno com sessao
atual, compara o estado esperado, grava a decisao e altera o produto atomicamente.
Somente essa operacao administrativa pode reativar um produto inativado.
Auditoria registra antes/depois, solicitante e data/hora, sem duplicar logs em
tentativas de sincronizacao que mantem a situacao.

`deactivate_products(items jsonb)` aceita 1 a 200 codigos distintos com
`expected_active`. Bloqueia as linhas ordenadas, verifica todos os itens e usa
a mesma operacao administrativa individual. Erro em qualquer item reverte
produtos, decisoes e logs de todo o lote. Nao oferece ativacao em massa.

Em Produtos, apenas ADMIN ve checkboxes, Selecionar exibidos e Inativar
selecionados. A selecao pertence exclusivamente ao resultado atual, nao a todos
os produtos do banco. Trocar pesquisa/filtros ou entrar novamente limpa selecao.
Itens ja inativos nao sao selecionaveis. Ha confirmacao, bloqueio de duplo clique,
contador e atualizacao da pesquisa apos sucesso. Ativacao individual permanece
na ficha do produto. Busca, B2B e lista comercial continuam usando os filtros
de atividade existentes.

Testes SQL: `tests/product_activity_persistence.sql`, sempre em transacao com
ROLLBACK. Cobrem upsert de origem, exclusao/recriacao de uma fixture, permissao,
sessao, conflito, duplicidade, auditoria e falha forcada apos primeiro item.

Nao desabilitar o trigger nas sincronizacoes. Importacoes nao devem apagar ou
truncar `product_activity_overrides`. Backups completos devem incluir essa tabela.
Se um codigo for reutilizado comercialmente como outro produto, o ADMIN deve
revisar sua situacao explicitamente; a decisao anterior permanece por seguranca.
