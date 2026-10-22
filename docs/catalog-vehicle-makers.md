# Montadoras reais no catalogo e nas listas

## Fontes

O campo legado `products.montadora` contem codigos de fabricante/fornecedor SAP.
Ele nao e sobrescrito nem reutilizado como montadora do veiculo. O filtro usa
somente `product_catalog_metadata.catalog_details.applications[].automaker` e
as aplicacoes dentro do bloco fechado CATALOGO_IPS_INSTALADO em detalhes.
Nao inferir montadora por descricao da peca, modelo ou codigo SAP.
No bloco textual legado, campos vazios eram omitidos: a primeira coluna so e
aceita quando corresponde a uma montadora conhecida nas fontes conferidas.
Assim uma linha FORD sozinha continua valida, mas ASTRA nao vira montadora.
Nomes novos na origem estruturada `automaker` nao dependem dessa lista legada.

## Padronizacao

- VW/Volkswagen: VOLKSWAGEN.
- MB/M.Benz/Mercedes/Mercedes-Benz: MERCEDES-BENZ.
- Ssang Yong/Ssangyong: SSANGYONG.
- JAC Motors/JAC: JAC.
- GM permanece GM, sem transformar um grupo em outra marca por suposicao.
- Aplicacao universal tem opcao propria e nao corresponde a todas as marcas.
- Itens sem fonte reconhecida ficam em Nao informada, nao sao descartados.
- Pecas compativeis com varias montadoras participam de cada filtro aplicavel.

## Contratos

Migration114 adiciona `get_catalog_filter_options()` e helpers privados.
`get_product_filters()` e a chave legada `maker` continuam com a semantica
anterior para compatibilidade. A nova chave `vehicle_maker` e independente,
aplicada antes da paginacao na busca e lista comercial; valores desconhecidos
nao desativam silenciosamente o filtro. A busca textual inclui nomes canonicos.

Catalogo, ficha e XLSX mostram as montadoras reais. O codigo SAP fica separado
na ficha. As listas comerciais passam a oferecer o mesmo filtro e a coluna
MONTADORAS no HTML, CSV e XLSX. Filtros combinam com origem/destino, linha,
grupo e tipo de veiculo sem alterar o motor fiscal ou os dados importados.

O cache de opcoes passa a productFiltersV5, por dez minutos; precos nao recebem
cache. Nao ha fallback para ler milhares de fabricantes na tabela products.

## Validacao e publicacao controlada

1. Backup completo de homologacao; exigir predecessor113.
2. Ensaiar114 com rollback e executar a regressao SQL114.
3. Comparar hashes de produtos, metadados, precos, estoques e regras fiscais.
4. Aplicar114 em transacao e repetir os testes.
5. Publicar juntos app.html, format.js, products.js, imports.js e supabase_store.js.
6. Testar aliases, multimarca, nao informada, universal, paginacao e exportacoes.
7. Producao depende de autorizacao posterior e backup proprio.

Rollback operacional: republicar primeiro o frontend anterior. As APIs legadas
foram preservadas e os helpers novos nao alteram os valores SAP, permitindo
correcao posterior sem apagar dados. Se for preciso reverter as definicoes SQL,
restaurar somente as funcoes revisadas a partir do backup/schema anterior em
uma migration nova; nao restaurar o banco inteiro nem desativar RLS/triggers.
