# Fiscal Engine

## Entrada e fonte de verdade

O motor recebe produto, filial/UF de origem, UF de destino, preço base, data e
tipo de cliente. Produto/NCM, preço por filial e regra vigente são resolvidos no
PostgreSQL. A implementação e as fórmulas atuais estão detalhadas em
[fiscal-engine-homologacao.md](fiscal-engine-homologacao.md).

## Governança da regra

O cálculo continua congelado como engine v2 nesta fase. A Fase 5B acrescentou
governança sem alterar a matemática:

```text
Regra por rota/data
  -> lifecycle_status
  -> rule_version
  -> cálculo numeric
  -> snapshot do item
     + status da regra
     + fundamento registrado
     + alerta REQUIRES_FISCAL_VALIDATION quando aplicável
```

Regra `REVIEW_REQUIRED` permanece calculável para continuidade, mas o snapshot
da cotação/pedido registra a pendência. Regra `DRAFT`, `VALIDATED` ou `DISABLED`
fica fora da resolução porque `active=false`.

## Memória e histórico

`fiscal_details` guarda valores, rota, NCM/CEST, regra, versão, vigência, data do
cálculo e governança capturada no momento. A conversão de cotação para pedido
copia o snapshot sem recalcular.

`fiscal_tax_rule_versions` permite responder qual conteúdo estava persistido em
cada versão. O histórico é imutável e separado dos logs administrativos.

## Limite atual

A entrada ainda não cobre regime, contribuinte, consumidor final, finalidade,
frete real e outros elementos necessários para uma engine brasileira geral. A
engine v3 deve ser implementada em paralelo e comparada aos golden cases antes
de substituir a versão atual.
